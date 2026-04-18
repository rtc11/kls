module kls::lsp::inlay_hints;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::definition;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::workspace;

// InlayHintKind constants (LSP 3.17)
const int HINT_KIND_TYPE = 1;
const int HINT_KIND_PARAMETER = 2;

/**
 * Handle textDocument/inlayHint request.
 * Returns a JSON array of InlayHint objects, or null if there are no hints.
 *
 * Produces two kinds of hints:
 * - Parameter name hints at call argument positions (kind=2)
 * - Type annotation hints for val/var without explicit types (kind=1)
 */
fn Object* handle_inlay_hints(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	// Extract the requested range
	Object* range_obj = params.get("range")!!;
	Object* range_start = range_obj.get("start")!!;
	Object* range_end = range_obj.get("end")!!;
	uint start_line = (uint)range_start.get_int("line")!!;
	uint end_line = (uint)range_end.get_int("line")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null || pr.node_count == 0) {
		return null;
	}

	TypeInfo* ti = store.get_types(uri) ?? null;

	Object* hints = object::new_obj(tmem);

	// Collect parameter name hints from CALL_EXPR nodes
	collect_parameter_hints(hints, pr, doc.content, start_line, end_line);

	// Collect type annotation hints from PROPERTY_DECL nodes
	collect_type_hints(hints, pr, ti, doc.content, start_line, end_line);

	// Collect return type hints from FUN_DECL nodes without explicit return type
	collect_return_type_hints(hints, pr, ti, doc.content, start_line, end_line);

	// Collect implicit `it` hints for lambdas without explicit params
	collect_lambda_it_hints(hints, pr, doc.content, start_line, end_line);

	// Collect chain type hints for long DOT_EXPR chains
	collect_chain_type_hints(hints, pr, ti, doc.content, start_line, end_line);

	// Collect smart cast hints after `is` checks
	collect_smart_cast_hints(hints, pr, doc.content, start_line, end_line);

	if (hints.get_len() == 0) {
		return null;
	}

	return hints;
}

// ── Parameter name hints ───────────────────────────────────────────

/**
 * Iterate all CALL_EXPR nodes in the AST. For each call within the
 * requested line range, resolve the declaration, extract parameter
 * names, and emit a hint at each argument position.
 */
fn void collect_parameter_hints(Object* hints, ParseResult* pr, String content, uint start_line, uint end_line) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != CALL_EXPR) continue;

		// Filter by range
		if (node.start_line > end_line || node.end_line < start_line) continue;

		// Must have a name to resolve
		if (node.name.len == 0) continue;

		// Resolve the called declaration
		AstNode* decl;
		if (try d = definition::find_definition_in_ast(pr, node.name, node.name_offset, true)) {
			decl = d;
		} else {
			continue;
		}

		// Only produce hints for function, constructor, and class declarations
		if (decl.kind != FUN_DECL && decl.kind != CONSTRUCTOR_DECL && decl.kind != CLASS_DECL) {
			continue;
		}

		// Collect parameter names from the declaration
		uint decl_idx = ast::node_index(pr, decl);
		String[32] param_names;
		uint param_count = 0;

		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != decl_idx) continue;
			if (child.kind != PARAM) continue;
			if (child.name.len == 0) continue;

			if (param_count < 32) {
				param_names[param_count] = child.name;
				param_count++;
			}
		}

		// No parameters -> no hints
		if (param_count == 0) continue;

		// Find the arguments of this call by locating the opening paren
		// and lexing through the argument list
		emit_parameter_hints_for_call(hints, pr, i, node, content, &param_names, param_count, start_line, end_line);
	}
}

/**
 * For a single CALL_EXPR, lex from the opening paren through the argument
 * list, identify the start position of each argument, and emit an inlay
 * hint with the corresponding parameter name.
 */
fn void emit_parameter_hints_for_call(
	Object* hints, ParseResult* pr, uint call_idx, AstNode* call_node,
	String content, String[32]* param_names, uint param_count,
	uint start_line, uint end_line
) {
	// Find the opening paren
	uint open_paren;
	if (try p = find_open_paren(content, call_node)) {
		open_paren = p;
	} else {
		return;
	}

	uint scan_start = open_paren + 1; // skip past '('
	if (scan_start >= content.len) return;

	// Lex through the argument list to find each argument's start position
	// Track argument index, nesting depth, and whether we've seen a real token
	uint arg_index = 0;
	int depth = 0;
	bool seen_token_in_arg = false;
	uint arg_start_offset = 0;
	uint arg_start_line = 0;
	uint arg_start_col = 0;
	bool is_named_arg = false;
	String first_name_in_arg = "";

	Lexer lex = lexer::init(content[scan_start..]);

	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		uint abs_offset = scan_start + tok.offset;

		switch (tok.kind) {
			case LPAREN:
			case LSQUARE:
			case LCURL:
				depth++;
				if (depth == 0 && !seen_token_in_arg) {
					// Lambda as first/only token in argument
					seen_token_in_arg = true;
					arg_start_offset = abs_offset;
					arg_start_line = tok.line;
					arg_start_col = tok.col;
					// Compute absolute line from scan_start
					arg_start_line = offset_to_line(content, abs_offset);
					arg_start_col = offset_to_col(content, abs_offset);
				}
			case RPAREN:
				if (depth == 0) {
					// End of call -- emit hint for last argument if valid
					if (seen_token_in_arg && arg_index < param_count && !is_named_arg) {
						maybe_emit_param_hint(hints, arg_start_line, arg_start_col,
							(*param_names)[arg_index], first_name_in_arg, start_line, end_line);
					}
					return;
				}
				depth--;
			case RSQUARE:
			case RCURL:
				if (depth > 0) depth--;
			case COMMA:
				if (depth == 0) {
					// End of current argument -- emit hint
					if (seen_token_in_arg && arg_index < param_count && !is_named_arg) {
						maybe_emit_param_hint(hints, arg_start_line, arg_start_col,
							(*param_names)[arg_index], first_name_in_arg, start_line, end_line);
					}
					arg_index++;
					seen_token_in_arg = false;
					is_named_arg = false;
					first_name_in_arg = "";
				}
			default:
				if (depth == 0 && !seen_token_in_arg) {
					// First token of a new argument
					seen_token_in_arg = true;
					arg_start_offset = abs_offset;
					arg_start_line = offset_to_line(content, abs_offset);
					arg_start_col = offset_to_col(content, abs_offset);

					// Track the first identifier name (for suppression heuristic)
					if (tok.kind.is_identifier_or_soft_keyword()) {
						first_name_in_arg = tok.text;
					}
				} else if (depth == 0 && first_name_in_arg.len > 0 && !is_named_arg) {
					// Check if this argument is a named argument (name = expr)
					if (tok.kind == ASSIGNMENT) {
						is_named_arg = true;
					}
				}
		}
	}
}

/**
 * Emit a parameter name hint if it passes suppression heuristics.
 * Suppressed when:
 * - The argument is a simple identifier matching the parameter name
 * - The argument is a named argument (already handled by caller via is_named_arg)
 */
fn void maybe_emit_param_hint(Object* hints, uint line, uint col, String param_name,
	String arg_name, uint start_line, uint end_line) {
	// Range filter
	if (line < start_line || line > end_line) return;

	// Suppress if the argument name matches the parameter name exactly
	if (arg_name.len > 0 && arg_name == param_name) return;

	// Suppress if the argument name is a case-insensitive match
	// (e.g., argument 'name' for parameter 'name', or 'userName' for 'userName')
	// Already covered by exact match above.

	// Build the hint label: "paramName:"
	DString label;
	label.tinit();
	label.appendf("%s:", param_name);

	Object* hint = object::new_obj(tmem);

	// Position
	Object* position = object::new_obj(tmem);
	position.set("line", (int)line);
	position.set("character", (int)col);
	hint.set("position", position);

	// Label
	hint.set("label", label.str_view());

	// Kind
	hint.set("kind", HINT_KIND_PARAMETER);

	// Padding
	hint.set("paddingRight", true);

	hints.push(hint);
}

// ── Type annotation hints ──────────────────────────────────────────

/**
 * Iterate PROPERTY_DECL nodes in the AST. For each property within
 * the requested range that lacks an explicit type annotation, try to
 * infer the type and emit a hint after the property name.
 */
fn void collect_type_hints(Object* hints, ParseResult* pr, TypeInfo* ti, String content, uint start_line, uint end_line) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != PROPERTY_DECL) continue;

		// Filter by range
		if (node.name_line > end_line || node.name_line < start_line) continue;

		// Skip if the property already has an explicit type annotation
		if (node.type_text.len > 0) continue;

		// Skip destructuring declarations
		if (node.name.len == 0 || node.name == "(destructuring)") continue;

		// Try to get the type from the TypeInfo cache (full type resolution)
		String type_display = "";
		bool found_type = false;

		if (ti != null && ti.has_type[i]) {
			TypeRef tr = ti.node_types[i];
			if (tr.kind != UNKNOWN) {
				if (tr.full_text.len > 0) {
					type_display = tr.full_text;
					found_type = true;
				} else if (tr.name.len > 0) {
					type_display = tr.name;
					found_type = true;
				}
			}
		}

		// Fallback: infer type from initializer expression heuristics
		if (!found_type) {
			if (try inferred = infer_type_from_initializer(pr, ti, i, content)) {
				type_display = inferred;
				found_type = true;
			}
		}

		if (!found_type) continue;

		// Build the hint label: ": Type"
		DString label;
		label.tinit();
		label.appendf(": %s", type_display);

		Object* hint = object::new_obj(tmem);

		// Position: after the property name
		Object* position = object::new_obj(tmem);
		position.set("line", (int)node.name_line);
		position.set("character", (int)(node.name_col + node.name_len));
		hint.set("position", position);

		// Label
		hint.set("label", label.str_view());

		// Kind
		hint.set("kind", HINT_KIND_TYPE);

		// Padding
		hint.set("paddingLeft", true);

		hints.push(hint);
	}
}

/**
 * Try to infer a type string from a property's initializer expression
 * using basic heuristics when TypeInfo hasn't resolved it.
 *
 * Supported patterns:
 * - Literal values: 42 -> Int, "hello" -> String, true -> Boolean, etc.
 * - Constructor calls: Foo() -> Foo, MyClass<Int>() -> MyClass<Int>
 * - Function calls where the FUN_DECL has a return type annotation
 */
fn String? infer_type_from_initializer(ParseResult* pr, TypeInfo* ti, uint prop_idx, String content) {
	// Find the first expression child of this property (the initializer)
	AstNode* init_expr = null;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != prop_idx) continue;
		// Skip TYPE_PARAM and TYPE_REF children -- look for expression nodes
		if (child.kind == TYPE_PARAM || child.kind == TYPE_REF || child.kind == PARAM) continue;
		init_expr = child;
		break;
	}

	if (init_expr == null) return ast::NOT_FOUND~;

	// Check TypeInfo for the initializer expression
	uint init_idx = ast::node_index(pr, init_expr);
	if (ti != null && ti.has_type[init_idx]) {
		TypeRef tr = ti.node_types[init_idx];
		if (tr.kind != UNKNOWN) {
			if (tr.full_text.len > 0) return tr.full_text;
			if (tr.name.len > 0) return tr.name;
		}
	}

	// Heuristic fallback based on expression kind
	switch (init_expr.kind) {
		case LITERAL_EXPR:
			return infer_literal_type(init_expr, content);

		case CALL_EXPR:
			// Constructor call: if name starts with uppercase, it's a type
			if (init_expr.name.len > 0) {
				char first = init_expr.name[0];
				if (first >= 'A' && first <= 'Z') {
					return init_expr.name;
				}
				// Function call: look up the FUN_DECL's return type
				if (try decl = definition::find_definition_in_ast(pr, init_expr.name, init_expr.name_offset, true)) {
					if (decl.type_text.len > 0) {
						return decl.type_text;
					}
				}
			}

		case NAME_EXPR:
			// Variable reference: look up declaration's type
			if (init_expr.name.len > 0) {
				if (try decl = definition::find_definition_in_ast(pr, init_expr.name, init_expr.name_offset, false)) {
					if (decl.type_text.len > 0) {
						return decl.type_text;
					}
				}
			}

		default:
			break;
	}

	return ast::NOT_FOUND~;
}

/**
 * Infer the type of a literal expression from its text.
 */
fn String? infer_literal_type(AstNode* node, String content) {
	// Get the literal text from the source
	if (node.start_offset >= content.len) return ast::NOT_FOUND~;
	uint len = node.end_offset - node.start_offset;
	if (len == 0 || node.start_offset + len > content.len) return ast::NOT_FOUND~;

	String text = content[node.start_offset:len];

	if (text == "true" || text == "false") return "Boolean";
	if (text == "null") return ast::NOT_FOUND~; // can't infer type from null

	// String literals
	if (text.len >= 2 && text[0] == '"') return "String";
	if (text.len >= 6 && text[..5] == `"""`) return "String";

	// Character literals
	if (text.len >= 2 && text[0] == '\'') return "Char";

	// Numeric literals
	if (text.len > 0) {
		char last = text[text.len - 1];
		// Long suffix
		if (last == 'L' || last == 'l') return "Long";
		// Float suffix
		if (last == 'f' || last == 'F') return "Float";
		// UInt/ULong
		if (text.len >= 2) {
			String last2 = text[text.len - 2..];
			if (last2 == "uL" || last2 == "UL") return "ULong";
		}
		if (last == 'u' || last == 'U') return "UInt";

		// Check if it's a floating-point literal (has '.' or 'e'/'E')
		for (usz i = 0; i < text.len; i++) {
			if (text[i] == '.' || text[i] == 'e' || text[i] == 'E') return "Double";
		}

		// Otherwise it's an integer
		if (text[0] >= '0' && text[0] <= '9') return "Int";
		// Hex/binary
		if (text.len >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X' || text[1] == 'b' || text[1] == 'B')) return "Int";
	}

	return ast::NOT_FOUND~;
}

// ── Return type hints ──────────────────────────────────────────

/**
 * Emit return type hints for FUN_DECL nodes without explicit return type.
 * Infers from expression body or single return statement.
 */
fn void collect_return_type_hints(Object* hints, ParseResult* pr, TypeInfo* ti, String content, uint start_line, uint end_line) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != FUN_DECL) continue;

		// Filter by range
		if (node.start_line > end_line || node.end_line < start_line) continue;

		// Skip if already has explicit return type
		if (node.type_text.len > 0) continue;

		// Skip if no name (anonymous functions handled separately)
		if (node.name.len == 0) continue;

		// Try to infer return type from body
		String return_type = "";
		if (try rt = infer_fun_return_type(pr, ti, i, content)) {
			return_type = rt;
		} else {
			continue;
		}

		// Skip Unit — not useful to show
		if (return_type == "Unit") continue;

		// Find position: after closing ')' of parameter list
		uint hint_line;
		uint hint_col;
		if (try pos = find_fun_paren_close(content, node)) {
			hint_line = pos.line;
			hint_col = pos.col + 1; // after ')'
		} else {
			continue;
		}

		// Range filter
		if (hint_line < start_line || hint_line > end_line) continue;

		DString label;
		label.tinit();
		label.appendf(": %s", return_type);

		Object* hint = object::new_obj(tmem);
		Object* position = object::new_obj(tmem);
		position.set("line", (int)hint_line);
		position.set("character", (int)hint_col);
		hint.set("position", position);
		hint.set("label", label.str_view());
		hint.set("kind", HINT_KIND_TYPE);
		hint.set("paddingLeft", true);

		hints.push(hint);
	}
}

struct LineCol {
	uint line;
	uint col;
}

/**
 * Find the closing ')' of a FUN_DECL's parameter list.
 */
fn LineCol? find_fun_paren_close(String content, AstNode* fun_node) {
	uint scan_start = fun_node.name_offset + fun_node.name_len;
	if (scan_start >= content.len) return ast::NOT_FOUND~;

	Lexer lex = lexer::init(content[scan_start..]);
	int depth = 0;
	bool found_open = false;

	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		uint abs_offset = scan_start + tok.offset;

		if (tok.kind == LANGLE && !found_open) {
			// Skip generic type params
			depth++;
		} else if (tok.kind == RANGLE && !found_open && depth > 0) {
			depth--;
		} else if (tok.kind == LPAREN && depth == 0) {
			found_open = true;
			depth = 1;
		} else if (tok.kind == LPAREN && found_open) {
			depth++;
		} else if (tok.kind == RPAREN && found_open) {
			depth--;
			if (depth == 0) {
				return {
					.line = offset_to_line(content, abs_offset),
					.col = offset_to_col(content, abs_offset)
				};
			}
		} else if (tok.kind == LCURL && !found_open) {
			// Hit function body before finding parens (e.g., `fun main { }`)
			break;
		}
	}

	return ast::NOT_FOUND~;
}

/**
 * Infer return type of a FUN_DECL from its body.
 * Handles expression body (`= expr`) and single return statement.
 */
fn String? infer_fun_return_type(ParseResult* pr, TypeInfo* ti, uint fun_idx, String content) {
	// Look for children: BLOCK or expression body
	AstNode* block = null;
	AstNode* expr_child = null;

	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != fun_idx) continue;
		if (child.kind == PARAM || child.kind == TYPE_PARAM || child.kind == TYPE_REF) continue;

		if (child.kind == BLOCK) {
			block = child;
		} else if (ast::is_expression(child.kind)) {
			expr_child = child;
		}
	}

	// Expression body: `fun foo() = expr`
	if (expr_child != null) {
		uint expr_idx = ast::node_index(pr, expr_child);
		return infer_expr_type_string(pr, ti, expr_idx, expr_child, content);
	}

	// Block body: look for single RETURN_EXPR
	if (block != null) {
		uint block_idx = ast::node_index(pr, block);
		AstNode* return_expr = null;
		uint return_count = 0;

		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != block_idx) continue;
			if (child.kind == RETURN_EXPR) {
				return_expr = child;
				return_count++;
			}
		}

		// Only infer if single return
		if (return_count == 1 && return_expr != null) {
			// Find the expression child of RETURN_EXPR
			uint ret_idx = ast::node_index(pr, return_expr);
			for (uint j = 0; j < pr.node_count; j++) {
				AstNode* child = &pr.nodes[j];
				if (child.parent != ret_idx) continue;
				if (ast::is_expression(child.kind)) {
					uint child_idx = ast::node_index(pr, child);
					return infer_expr_type_string(pr, ti, child_idx, child, content);
				}
			}
		}

		// No return → Unit (but we skip Unit in caller)
		if (return_count == 0) {
			return "Unit";
		}
	}

	return ast::NOT_FOUND~;
}

/**
 * Get type string for an expression node, using TypeInfo or heuristics.
 */
fn String? infer_expr_type_string(ParseResult* pr, TypeInfo* ti, uint idx, AstNode* node, String content) {
	// Try TypeInfo first
	if (ti != null && ti.has_type[idx]) {
		TypeRef tr = ti.node_types[idx];
		if (tr.kind != UNKNOWN) {
			if (tr.full_text.len > 0) return tr.full_text;
			if (tr.name.len > 0) return tr.name;
		}
	}

	// Heuristic fallback
	switch (node.kind) {
		case LITERAL_EXPR:
			return infer_literal_type(node, content);

		case CALL_EXPR:
			if (node.name.len > 0) {
				char first = node.name[0];
				if (first >= 'A' && first <= 'Z') return node.name;
				if (try decl = definition::find_definition_in_ast(pr, node.name, node.name_offset, true)) {
					if (decl.type_text.len > 0) return decl.type_text;
				}
			}

		case NAME_EXPR:
			if (node.name.len > 0) {
				if (try decl = definition::find_definition_in_ast(pr, node.name, node.name_offset, false)) {
					if (decl.type_text.len > 0) return decl.type_text;
				}
			}

		case STRING_TEMPLATE_EXPR:
			return "String";

		default:
			break;
	}

	return ast::NOT_FOUND~;
}

// ── Smart cast hints ───────────────────────────────────────────

/**
 * Show smart cast type hints on variable usages after `is` checks.
 * For `if (x is Foo) { x.bar() }`, shows `(Foo)` before `x` in the body.
 */
fn void collect_smart_cast_hints(Object* hints, ParseResult* pr, String content, uint start_line, uint end_line) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != IF_EXPR) continue;

		// Filter by range
		if (node.start_line > end_line || node.end_line < start_line) continue;

		// Find TYPE_CHECK_EXPR child (condition)
		// IF_EXPR children: [condition, then_block, (else_block)]
		uint condition_idx = pr.node_count; // sentinel
		uint then_block_idx = pr.node_count;
		uint child_order = 0;

		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != i) continue;
			if (child_order == 0) {
				condition_idx = j;
			} else if (child_order == 1) {
				then_block_idx = j;
			}
			child_order++;
		}

		if (condition_idx >= pr.node_count || then_block_idx >= pr.node_count) continue;

		// Condition must be TYPE_CHECK_EXPR with "is" (not "!is")
		AstNode* cond = &pr.nodes[condition_idx];
		String var_name = "";
		String cast_type = "";

		if (cond.kind == TYPE_CHECK_EXPR && cond.extra_text == "is") {
			cast_type = cond.type_text;
			// Find subject NAME_EXPR child
			for (uint j = 0; j < pr.node_count; j++) {
				if (pr.nodes[j].parent != condition_idx) continue;
				if (pr.nodes[j].kind == NAME_EXPR && pr.nodes[j].name.len > 0) {
					var_name = pr.nodes[j].name;
					break;
				}
			}
		}

		if (var_name.len == 0 || cast_type.len == 0) continue;

		// Find NAME_EXPR references to var_name inside then_block
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* ref_node = &pr.nodes[j];
			if (ref_node.kind != NAME_EXPR) continue;
			if (ref_node.name != var_name) continue;

			// Must be descendant of then_block
			if (!is_descendant_of(pr, j, then_block_idx)) continue;

			// Filter by range
			if (ref_node.name_line < start_line || ref_node.name_line > end_line) continue;

			DString label;
			label.tinit();
			label.appendf("(%s)", cast_type);

			Object* hint = object::new_obj(tmem);
			Object* position = object::new_obj(tmem);
			position.set("line", (int)ref_node.name_line);
			position.set("character", (int)ref_node.name_col);
			hint.set("position", position);
			hint.set("label", label.str_view());
			hint.set("kind", HINT_KIND_TYPE);
			hint.set("paddingRight", true);

			hints.push(hint);
		}
	}
}

// ── Chain type hints ───────────────────────────────────────────

/**
 * Show intermediate type hints on method chains of 3+ calls.
 * For `a.b().c().d()`, shows type after `.b()` and `.c()`.
 */
fn void collect_chain_type_hints(Object* hints, ParseResult* pr, TypeInfo* ti, String content, uint start_line, uint end_line) {
	if (ti == null) return;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != DOT_EXPR) continue;

		// Filter by range
		if (node.start_line > end_line || node.end_line < start_line) continue;

		// Only show hints for intermediate DOT_EXPRs in chains of 3+.
		// A DOT_EXPR is "intermediate" if:
		// 1. Its parent is a CALL_EXPR whose parent is another DOT_EXPR (chain continues up)
		// 2. It has a child that is a CALL_EXPR/DOT_EXPR (chain continues down)
		// Count chain depth from this node downward
		uint depth = count_chain_depth(pr, i);
		if (depth < 3) continue;

		// This DOT_EXPR is intermediate if parent chain goes up further
		// (i.e., it's NOT the outermost DOT_EXPR in the chain)
		if (node.parent < pr.node_count) {
			AstNode* parent = &pr.nodes[node.parent];
			// Parent should be CALL_EXPR
			if (parent.kind == CALL_EXPR && parent.parent < pr.node_count) {
				AstNode* grandparent = &pr.nodes[parent.parent];
				if (grandparent.kind != DOT_EXPR) {
					// This is the outermost — skip (final result type is obvious)
					continue;
				}
			} else {
				continue; // Not in a call chain
			}
		}

		// Get the type of this DOT_EXPR's enclosing CALL_EXPR
		uint call_idx = node.parent;
		if (call_idx >= pr.node_count) continue;
		if (!ti.has_type[call_idx]) continue;

		TypeRef tr = ti.node_types[call_idx];
		if (tr.kind == UNKNOWN) continue;

		String type_name = "";
		if (tr.full_text.len > 0) {
			type_name = tr.full_text;
		} else if (tr.name.len > 0) {
			type_name = tr.name;
		} else {
			continue;
		}

		// Position: after the closing ')' of the call
		AstNode* call_node = &pr.nodes[call_idx];
		uint hint_line = call_node.end_line;
		uint hint_col = call_node.end_col;

		if (hint_line < start_line || hint_line > end_line) continue;

		DString label;
		label.tinit();
		label.appendf(": %s", type_name);

		Object* hint = object::new_obj(tmem);
		Object* position = object::new_obj(tmem);
		position.set("line", (int)hint_line);
		position.set("character", (int)hint_col);
		hint.set("position", position);
		hint.set("label", label.str_view());
		hint.set("kind", HINT_KIND_TYPE);
		hint.set("paddingLeft", true);

		hints.push(hint);
	}
}

/**
 * Count chain depth starting from a DOT_EXPR node going downward.
 * Returns number of dot segments in the chain.
 */
fn uint count_chain_depth(ParseResult* pr, uint dot_idx) {
	uint depth = 1;

	// Walk down: find child that is CALL_EXPR or NAME_EXPR
	// If child is CALL_EXPR, look for its DOT_EXPR child
	uint current = dot_idx;
	while (current < pr.node_count) {
		bool found_next = false;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != current) continue;

			if (pr.nodes[j].kind == CALL_EXPR) {
				// Look for DOT_EXPR child of this CALL_EXPR
				for (uint k = 0; k < pr.node_count; k++) {
					if (pr.nodes[k].parent != j) continue;
					if (pr.nodes[k].kind == DOT_EXPR) {
						depth++;
						current = k;
						found_next = true;
						break;
					}
				}
				break;
			} else if (pr.nodes[j].kind == DOT_EXPR) {
				depth++;
				current = j;
				found_next = true;
				break;
			}
		}
		if (!found_next) break;
	}

	// Also walk up
	current = dot_idx;
	while (current < pr.node_count) {
		uint parent = pr.nodes[current].parent;
		if (parent >= pr.node_count) break;
		if (pr.nodes[parent].kind == CALL_EXPR) {
			uint gp = pr.nodes[parent].parent;
			if (gp < pr.node_count && pr.nodes[gp].kind == DOT_EXPR) {
				depth++;
				current = gp;
				continue;
			}
		}
		break;
	}

	return depth;
}

// ── Lambda `it` hints ──────────────────────────────────────────

/**
 * Emit an `it` parameter hint for lambdas without explicit parameters.
 * Shows "it" hint at the opening `{` of the lambda.
 */
fn void collect_lambda_it_hints(Object* hints, ParseResult* pr, String content, uint start_line, uint end_line) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != LAMBDA_EXPR) continue;

		// Filter by range
		if (node.start_line > end_line || node.end_line < start_line) continue;

		// Check if lambda has explicit PARAM children
		bool has_params = false;
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.kind == PARAM) {
				has_params = true;
				break;
			}
		}

		// Only show hint for implicit `it` lambdas
		if (has_params) continue;

		// Check that lambda body references `it` (avoid noise on empty lambdas)
		bool uses_it = false;
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i && !is_descendant_of(pr, j, i)) continue;
			if (child.kind == NAME_EXPR && child.name == "it") {
				uses_it = true;
				break;
			}
		}

		if (!uses_it) continue;

		// Position: after the opening '{', before body
		// Hint at start_line, start_col + 1 (after '{')
		uint hint_line = node.start_line;
		uint hint_col = node.start_col + 1;

		if (hint_line < start_line || hint_line > end_line) continue;

		Object* hint = object::new_obj(tmem);
		Object* position = object::new_obj(tmem);
		position.set("line", (int)hint_line);
		position.set("character", (int)hint_col);
		hint.set("position", position);
		hint.set("label", "it");
		hint.set("kind", HINT_KIND_PARAMETER);
		hint.set("paddingLeft", true);
		hint.set("paddingRight", true);

		hints.push(hint);
	}
}

/**
 * Check if node at `child_idx` is a descendant of node at `ancestor_idx`.
 */
fn bool is_descendant_of(ParseResult* pr, uint child_idx, uint ancestor_idx) {
	uint current = child_idx;
	while (current < pr.node_count) {
		uint parent = pr.nodes[current].parent;
		if (parent == ancestor_idx) return true;
		if (parent == ast::NO_PARENT || parent >= current) return false;
		current = parent;
	}
	return false;
}

// ── Utility helpers ────────────────────────────────────────────────

/**
 * Find the byte offset of the opening '(' in a CALL_EXPR.
 * Same approach as signature_help::find_open_paren.
 */
fn uint? find_open_paren(String content, AstNode* call_node) {
	uint scan_start = call_node.name_offset + call_node.name_len;
	if (scan_start >= content.len) return ast::NOT_FOUND~;

	if (call_node.name_len == 0) {
		scan_start = call_node.start_offset;
	}

	Lexer lex = lexer::init(content[scan_start..]);
	int angle_depth = 0;
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		if (tok.kind == LANGLE) {
			angle_depth++;
		} else if (tok.kind == RANGLE && angle_depth > 0) {
			angle_depth--;
		} else if (tok.kind == LPAREN && angle_depth == 0) {
			return scan_start + tok.offset;
		}
	}

	return ast::NOT_FOUND~;
}

/**
 * Compute the 0-based line number for a byte offset in content.
 */
fn uint offset_to_line(String content, uint offset) {
	uint line = 0;
	for (usz i = 0; i < content.len && i < offset; i++) {
		if (content[i] == '\n') line++;
	}
	return line;
}

/**
 * Compute the 0-based column for a byte offset in content.
 */
fn uint offset_to_col(String content, uint offset) {
	uint col = 0;
	for (usz i = offset; i > 0; i--) {
		if (content[i - 1] == '\n') break;
		col++;
	}
	return col;
}
