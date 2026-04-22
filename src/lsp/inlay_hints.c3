module kls::lsp::inlay_hints;

import std::io;
import std::collections::object;
import std::collections::list;
import kls::document;
import kls::lsp::definition;
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
fn Object*? handle_inlay_hints(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	// Extract the requested range
	Object* range_obj = params.get("range")!;
	Object* range_start = range_obj.get("start")!;
	Object* range_end = range_obj.get("end")!;
	uint start_line = (uint)range_start.get_int("line")!;
	uint end_line = (uint)range_end.get_int("line")!;

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

	// Collect type hints for explicit lambda params lacking annotations:
	//   { reply -> ... }   →   { reply: StatusReply -> ... }
	collect_lambda_param_type_hints(hints, pr, ti, workspace, uri, doc.content, start_line, end_line);

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
		if (try d = definition::find_declaration_in_file(pr, node.name, node.name_offset, true)) {
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
				if (try decl = definition::find_declaration_in_file(pr, init_expr.name, init_expr.name_offset, true)) {
					if (decl.type_text.len > 0) {
						return decl.type_text;
					}
				}
			}

		case NAME_EXPR:
			// Variable reference: look up declaration's type
			if (init_expr.name.len > 0) {
				if (try decl = definition::find_declaration_in_file(pr, init_expr.name, init_expr.name_offset, false)) {
					if (decl.type_text.len > 0) {
						return decl.type_text;
					}
				}
			}

		case STRING_TEMPLATE_EXPR:
			return "String";

		case IF_EXPR:
			// Try to infer from then-branch expression
			return infer_branch_type(pr, ti, init_expr, content);

		case WHEN_EXPR:
			// Try to infer from first entry's expression
			return infer_when_type(pr, ti, init_expr, content);

		case TYPE_CAST_EXPR:
			// Cast: `x as Foo` → Foo
			if (init_expr.type_text.len > 0) {
				return init_expr.type_text;
			}

		case DOT_EXPR:
			// Method chain: try TypeInfo on the DOT_EXPR node itself
			// or resolve the final call's return type
			return infer_dot_expr_type(pr, ti, ast::node_index(pr, init_expr), init_expr, content);

		default:
			break;
	}

	return ast::NOT_FOUND~;
}

/**
 * Infer type from an IF_EXPR by looking at the then-branch.
 */
fn String? infer_branch_type(ParseResult* pr, TypeInfo* ti, AstNode* if_node, String content) {
	uint if_idx = ast::node_index(pr, if_node);
	uint child_order = 0;

	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != if_idx) continue;
		child_order++;
		// Second child = then branch (first is condition)
		if (child_order == 2 && ast::is_expression(child.kind)) {
			return infer_expr_type_string(pr, ti, j, child, content);
		}
	}
	return ast::NOT_FOUND~;
}

/**
 * Infer type from a WHEN_EXPR by looking at the first entry's result.
 */
fn String? infer_when_type(ParseResult* pr, TypeInfo* ti, AstNode* when_node, String content) {
	uint when_idx = ast::node_index(pr, when_node);

	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != when_idx) continue;
		if (child.kind != WHEN_ENTRY) continue;

		// Find the last expression child of WHEN_ENTRY (the result body)
		uint last_expr_idx = pr.node_count;
		AstNode* last_expr = null;
		for (uint k = 0; k < pr.node_count; k++) {
			AstNode* entry_child = &pr.nodes[k];
			if (entry_child.parent != j) continue;
			if (ast::is_expression(entry_child.kind)) {
				last_expr_idx = k;
				last_expr = entry_child;
			}
		}
		if (last_expr != null) {
			return infer_expr_type_string(pr, ti, last_expr_idx, last_expr, content);
		}
		break; // only check first entry
	}
	return ast::NOT_FOUND~;
}

/**
 * Infer type from a DOT_EXPR chain.
 * Tries TypeInfo first, then checks if final segment is a known
 * stdlib/JDK method with a return type.
 */
fn String? infer_dot_expr_type(ParseResult* pr, TypeInfo* ti, uint idx, AstNode* node, String content) {
	// TypeInfo might have resolved it
	if (ti != null && ti.has_type[idx]) {
		TypeRef tr = ti.node_types[idx];
		if (tr.kind != UNKNOWN) {
			if (tr.full_text.len > 0) return tr.full_text;
			if (tr.name.len > 0) return tr.name;
		}
	}

	// Check if the DOT_EXPR's right-side name resolves to a known decl
	if (node.name.len > 0) {
		if (try decl = definition::find_declaration_in_file(pr, node.name, node.name_offset, false)) {
			if (decl.type_text.len > 0) return decl.type_text;
		}
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
				if (try decl = definition::find_declaration_in_file(pr, node.name, node.name_offset, true)) {
					if (decl.type_text.len > 0) return decl.type_text;
				}
			}

		case NAME_EXPR:
			if (node.name.len > 0) {
				if (try decl = definition::find_declaration_in_file(pr, node.name, node.name_offset, false)) {
					if (decl.type_text.len > 0) return decl.type_text;
				}
			}

		case STRING_TEMPLATE_EXPR:
			return "String";

		case IF_EXPR:
			return infer_branch_type(pr, ti, node, content);

		case WHEN_EXPR:
			return infer_when_type(pr, ti, node, content);

		case TYPE_CAST_EXPR:
			if (node.type_text.len > 0) return node.type_text;

		case DOT_EXPR:
			return infer_dot_expr_type(pr, ti, idx, node, content);

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

// ── Lambda explicit-param type hints ──────────────────────────────

/**
 * Emit `: Type` hints for explicit lambda parameters that lack type
 * annotations. e.g. `.map { reply -> ... }` shows `reply: StatusReply`.
 *
 * Strategy: for each LAMBDA_EXPR with explicit PARAM children that have
 * no `type_text`, walk up to the enclosing CALL_EXPR. Resolve the callee
 * (in-file AST first, then workspace MemberDecl). The lambda corresponds
 * to a function-typed parameter on the callee; parse that function type
 * (e.g. `(StatusReply) -> String`) and emit a hint per lambda param.
 */
fn void collect_lambda_param_type_hints(Object* hints, ParseResult* pr, TypeInfo* ti,
	WorkspaceIndex* workspace, String current_uri, String content,
	uint start_line, uint end_line) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != LAMBDA_EXPR) continue;

		// Filter by range
		if (node.start_line > end_line || node.end_line < start_line) continue;

		// Find PARAM children with no explicit type annotation
		uint[8] param_indices;
		uint param_count = 0;
		for (uint j = 0; j < pr.node_count && param_count < 8; j++) {
			if (pr.nodes[j].parent != i) continue;
			if (pr.nodes[j].kind != PARAM) continue;
			if (pr.nodes[j].name.len == 0) continue;
			if (pr.nodes[j].type_text.len > 0) continue; // already has annotation
			param_indices[param_count++] = j;
		}

		if (param_count == 0) continue;

		// Walk up to find enclosing CALL_EXPR (lambda is either trailing-lambda
		// child of CALL_EXPR, or argument inside parens of CALL_EXPR).
		uint call_idx = ast::NO_PARENT;
		uint cur = i;
		while (cur < pr.node_count) {
			uint parent = pr.nodes[cur].parent;
			if (parent == ast::NO_PARENT || parent >= pr.node_count) break;
			if (pr.nodes[parent].kind == CALL_EXPR) {
				call_idx = parent;
				break;
			}
			cur = parent;
		}
		if (call_idx == ast::NO_PARENT) continue;

		String method_name = pr.nodes[call_idx].name;
		if (method_name.len == 0) continue;

		// Resolve callee → get function-type text of the parameter the lambda
		// corresponds to. For trailing lambda, that's the last param. The
		// helper returns the full function-type string.
		String func_type = resolve_lambda_callee_param_type(pr, ti, workspace,
			current_uri, call_idx, method_name);
		if (func_type.len == 0) continue;

		// Substitute class generic type parameters in the function type using
		// the receiver's actual type arguments. e.g. "(V) -> String" with
		// receiver MappedStream<String, StatusReply> → "(StatusReply) -> String".
		if (workspace != null && ti != null) {
			TypeRef recv = find_call_receiver_type_trailing(pr, ti, call_idx, method_name);
			if (recv.kind == GENERIC && recv.type_arg_count > 0 && recv.name.len > 0) {
				if (try tparams = workspace.lookup_class_type_params(recv.name)) {
					func_type = substitute_class_generics(func_type, tparams, &recv);
				}
			}
		}

		// Parse function type "(A, B, C) -> R" → param types
		String[8] arg_types;
		uint arg_count = parse_function_type_params(func_type, &arg_types);
		if (arg_count == 0) continue;

		// Emit a type hint after each lambda PARAM name
		for (uint p = 0; p < param_count && p < arg_count; p++) {
			AstNode* param = &pr.nodes[param_indices[p]];
			String t = arg_types[p];
			if (t.len == 0) continue;
			if (param.name_line < start_line || param.name_line > end_line) continue;

			DString label;
			label.tinit();
			label.appendf(": %s", t);

			Object* hint = object::new_obj(tmem);
			Object* position = object::new_obj(tmem);
			position.set("line", (int)param.name_line);
			position.set("character", (int)(param.name_col + param.name_len));
			hint.set("position", position);
			hint.set("label", label.str_view());
			hint.set("kind", HINT_KIND_TYPE);
			hint.set("paddingLeft", true);
			hints.push(hint);
		}
	}
}

/**
 * Resolve the inferred type-text for a single lambda PARAM node.
 *
 * Used by hover (and reuses the same resolution as collect_lambda_param_type_hints).
 * Returns an empty string when the type can't be resolved (e.g. callee not in
 * AST/workspace, or PARAM is not actually a lambda param).
 */
fn String resolve_lambda_param_type(ParseResult* pr, TypeInfo* ti,
	WorkspaceIndex* workspace, String current_uri, uint param_idx) {
	if (param_idx >= pr.node_count) return "";
	AstNode* param = &pr.nodes[param_idx];
	if (param.kind != PARAM) return "";

	// Param's parent should be a LAMBDA_EXPR
	uint lambda_idx = param.parent;
	if (lambda_idx >= pr.node_count) return "";
	if (pr.nodes[lambda_idx].kind != LAMBDA_EXPR) return "";

	// Determine this param's index among lambda's PARAM children
	uint param_pos = 0;
	bool found = false;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != lambda_idx) continue;
		if (pr.nodes[j].kind != PARAM) continue;
		if (j == param_idx) { found = true; break; }
		param_pos++;
	}
	if (!found) return "";

	// Walk up to enclosing CALL_EXPR
	uint call_idx = ast::NO_PARENT;
	uint cur = lambda_idx;
	while (cur < pr.node_count) {
		uint parent = pr.nodes[cur].parent;
		if (parent == ast::NO_PARENT || parent >= pr.node_count) break;
		if (pr.nodes[parent].kind == CALL_EXPR) {
			call_idx = parent;
			break;
		}
		cur = parent;
	}
	if (call_idx == ast::NO_PARENT) return "";

	String method_name = pr.nodes[call_idx].name;
	if (method_name.len == 0) return "";

	String func_type = resolve_lambda_callee_param_type(pr, ti, workspace,
		current_uri, call_idx, method_name);
	if (func_type.len == 0) return "";

	// Substitute class generics
	if (workspace != null && ti != null) {
		TypeRef recv = find_call_receiver_type_trailing(pr, ti, call_idx, method_name);
		if (recv.kind == GENERIC && recv.type_arg_count > 0 && recv.name.len > 0) {
			if (try tparams = workspace.lookup_class_type_params(recv.name)) {
				func_type = substitute_class_generics(func_type, tparams, &recv);
			}
		}
	}

	String[8] arg_types;
	uint arg_count = parse_function_type_params(func_type, &arg_types);
	if (arg_count == 0) return "";
	if (param_pos >= arg_count) return "";

	return arg_types[param_pos];
}

/**
 * Resolve the function-type text of the parameter that a trailing lambda
 * occupies on the called function. Tries in-file AST first, then workspace
 * member cache (extension functions and top-level functions across files).
 *
 * Returns an empty string if the callee or its function-type param can't
 * be resolved.
 */
fn String resolve_lambda_callee_param_type(ParseResult* pr, TypeInfo* ti,
	WorkspaceIndex* workspace, String current_uri, uint call_idx, String method_name) {
	// 1. In-file AST lookup
	uint name_offset = pr.nodes[call_idx].name_offset;
	if (try decl = definition::find_declaration_in_file(pr, method_name, name_offset, true, ti)) {
		if (decl.kind == FUN_DECL) {
			// Last PARAM whose type_text looks like a function type
			uint decl_idx = ast::node_index(pr, decl);
			String last_func = "";
			for (uint k = 0; k < pr.node_count; k++) {
				if (pr.nodes[k].parent != decl_idx) continue;
				if (pr.nodes[k].kind != PARAM) continue;
				String t = pr.nodes[k].type_text;
				if (is_function_type(t)) last_func = t;
			}
			if (last_func.len > 0) return last_func;
		}
	}

	// 2. Workspace lookup: check member_cache for any receiver type that has
	// this extension method, and top-level functions via name_index.
	if (workspace == null) return "";

	// Try direct name lookup — finds top-level functions and extension
	// functions cached across the workspace.
	if (try indices = workspace.lookup_by_name(method_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			usz sym_idx = (*indices)[i];
			WorkspaceSymbol* sym = workspace.get_symbol(sym_idx);
			// Look up MemberDecl for this symbol in member_cache
			String key = sym.receiver.len > 0 ? sym.receiver : "";
			if (key.len == 0) continue;
			if (try members = workspace.lookup_members(key)) {
				for (usz m = 0; m < members.len(); m++) {
					MemberDecl* md = &(*members)[m];
					if (md.name != method_name) continue;
					// Find last function-type param
					for (usz p = md.param_count; p > 0; p--) {
						String t = md.param_types[p - 1];
						if (is_function_type(t)) return t;
					}
				}
			}
		}
	}

	// Also scan all member_cache entries for the method (covers cases where
	// receiver field on WorkspaceSymbol is empty but member_cache has it).
	@pool() {
		foreach (key : workspace.member_cache.tkeys()) {
			if (try members = workspace.member_cache.get_ref(key)) {
				for (usz m = 0; m < members.len(); m++) {
					MemberDecl* md = &(*members)[m];
					if (md.name != method_name) continue;
					for (usz p = md.param_count; p > 0; p--) {
						String t = md.param_types[p - 1];
						if (is_function_type(t)) return t;
					}
				}
			}
		};
	};

	return "";
}

/**
 * Quick check: does a type string look like a function type, i.e. contains
 * "->" outside of nested generics? (Function types in Kotlin look like
 * "(A, B) -> R" or "Receiver.(A) -> R" or "suspend (A) -> R".)
 */
fn bool is_function_type(String s) {
	int angle = 0;
	int paren = 0;
	for (usz i = 0; i + 1 < s.len; i++) {
		char c = s[i];
		if (c == '<') { angle++; }
		else if (c == '>') { if (angle > 0) { angle--; } }
		else if (c == '(') { paren++; }
		else if (c == ')') { if (paren > 0) { paren--; } }
		else if (c == '-' && s[i + 1] == '>' && angle == 0 && paren == 0) {
			return true;
		}
	}
	return false;
}

/**
 * Parse the parameter list of a function type into individual type strings.
 * Examples:
 *   "(StatusReply) -> String"        → ["StatusReply"]
 *   "(K, V) -> Boolean"               → ["K", "V"]
 *   "Receiver.(A, B) -> Unit"         → ["A", "B"]
 *   "suspend (Foo<Int, Int>) -> Bar" → ["Foo<Int, Int>"]
 *
 * Returns the number of types extracted (capped at the slot count of the
 * provided buffer).
 */
fn uint parse_function_type_params(String sig, String[8]* out) {
	// Find the parameter list: outermost "(...)" that precedes "->"
	usz arrow_pos = 0;
	bool found_arrow = false;
	int angle = 0;
	int paren = 0;
	for (usz i = 0; i + 1 < sig.len; i++) {
		char c = sig[i];
		if (c == '<') { angle++; }
		else if (c == '>') { if (angle > 0) { angle--; } }
		else if (c == '(') { paren++; }
		else if (c == ')') { if (paren > 0) { paren--; } }
		else if (c == '-' && sig[i + 1] == '>' && angle == 0 && paren == 0) {
			arrow_pos = i;
			found_arrow = true;
			break;
		}
	}
	if (!found_arrow) return 0;

	// Walk back from arrow to find the matching "(...)" before it
	usz close_paren = 0;
	bool found_close = false;
	for (usz i = arrow_pos; i > 0; i--) {
		if (sig[i - 1] == ')') {
			close_paren = i - 1;
			found_close = true;
			break;
		}
		if (sig[i - 1] != ' ' && sig[i - 1] != '\t') {
			// Non-whitespace before arrow — malformed for our purposes
			return 0;
		}
	}
	if (!found_close) return 0;

	// Find matching open paren
	int depth = 1;
	usz open_paren = 0;
	bool found_open = false;
	for (usz i = close_paren; i > 0; i--) {
		char c = sig[i - 1];
		if (c == ')') { depth++; }
		else if (c == '(') {
			depth--;
			if (depth == 0) {
				open_paren = i - 1;
				found_open = true;
				break;
			}
		}
	}
	if (!found_open) return 0;

	String params = sig[open_paren + 1..close_paren - 1];

	// Split on top-level commas
	uint count = 0;
	usz start = 0;
	angle = 0;
	paren = 0;
	for (usz i = 0; i < params.len; i++) {
		char c = params[i];
		if (c == '<') { angle++; }
		else if (c == '>') { if (angle > 0) { angle--; } }
		else if (c == '(') { paren++; }
		else if (c == ')') { if (paren > 0) { paren--; } }
		else if (c == ',' && angle == 0 && paren == 0) {
			if (count < 8) {
				(*out)[count] = strip_param_name(trim_ws(params[start..i - 1]));
				count++;
			}
			start = i + 1;
		}
	}
	if (start < params.len && count < 8) {
		(*out)[count] = strip_param_name(trim_ws(params[start..params.len - 1]));
		count++;
	}
	return count;
}

/**
 * Substitute class type-parameter names in a type-text string with the
 * actual type arguments from a receiver TypeRef.
 *
 * Example: type_text="(V) -> String", tparams=["K","V"],
 *   recv.type_arg_names=["String","StatusReply"]  →  "(StatusReply) -> String"
 *
 * Substitution is whole-token (identifier boundary) so "Value" is NOT
 * replaced when looking for "V". Allocated via tmem.
 */
/**
 * Like types::find_call_receiver_type but also handles the trailing-lambda
 * AST shape where the outer CALL_EXPR has structure:
 *
 *   CALL_EXPR "name"            ← outer, with trailing lambda
 *     CALL_EXPR "name"          ← inner, with args + DOT_EXPR receiver
 *       DOT_EXPR
 *         NAME_EXPR (receiver)
 *     LAMBDA_EXPR
 *
 * Falls through to the normal lookup first; if that yields UNKNOWN, recurses
 * into a same-named inner CALL_EXPR child to find the receiver.
 */
fn TypeRef find_call_receiver_type_trailing(ParseResult* pr, TypeInfo* ti, uint call_idx, String method_name) {
	TypeRef recv = types::find_call_receiver_type(pr, ti, call_idx);
	if (recv.kind != UNKNOWN) return recv;
	for (uint c = 0; c < pr.node_count; c++) {
		if (pr.nodes[c].parent != call_idx) continue;
		if (pr.nodes[c].kind != CALL_EXPR) continue;
		if (pr.nodes[c].name != method_name) continue;
		recv = types::find_call_receiver_type(pr, ti, c);
		if (recv.kind != UNKNOWN) return recv;
	}
	return recv;
}

fn String substitute_class_generics(String type_text, List{String}* tparams, TypeRef* recv) {
	if (type_text.len == 0 || tparams.len() == 0) return type_text;

	DString out;
	out.tinit();

	usz i = 0;
	while (i < type_text.len) {
		char c = type_text[i];
		// Identifier start
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
			usz start = i;
			while (i < type_text.len) {
				char cc = type_text[i];
				if ((cc >= 'a' && cc <= 'z') || (cc >= 'A' && cc <= 'Z') ||
					(cc >= '0' && cc <= '9') || cc == '_') {
					i++;
				} else {
					break;
				}
			}
			String word = type_text[start..i - 1];
			// Check if word matches any tparam → replace with corresponding arg
			bool replaced = false;
			for (usz t = 0; t < tparams.len() && t < recv.type_arg_count; t++) {
				if ((*tparams)[t] == word) {
					out.appendf("%s", recv.type_arg_names[t]);
					if (recv.type_arg_nullable[t]) out.appendf("?");
					replaced = true;
					break;
				}
			}
			if (!replaced) {
				out.appendf("%s", word);
			}
		} else {
			out.append_char(c);
			i++;
		}
	}

	return out.str_view();
}

/**
 * Trim leading/trailing ASCII whitespace from a slice.
 */
fn String trim_ws(String s) {
	usz a = 0;
	usz b = s.len;
	while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\r')) a++;
	while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\n' || s[b - 1] == '\r')) b--;
	if (a >= b) return "";
	return s[a..b - 1];
}

/**
 * Drop a "name:" prefix from a function-type parameter slot.
 * Kotlin function types may be written as `(name: Type)` — we want just `Type`.
 * Skips a colon at top-level (no nested generics/parens).
 */
fn String strip_param_name(String s) {
	int angle = 0;
	int paren = 0;
	for (usz i = 0; i < s.len; i++) {
		char c = s[i];
		if (c == '<') { angle++; }
		else if (c == '>') { if (angle > 0) { angle--; } }
		else if (c == '(') { paren++; }
		else if (c == ')') { if (paren > 0) { paren--; } }
		else if (c == ':' && angle == 0 && paren == 0) {
			return trim_ws(s[i + 1..s.len - 1]);
		}
	}
	return s;
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

/**
 * Handle inlayHint/resolve request.
 * Adds tooltip detail to an inlay hint. Currently returns the hint as-is
 * since tooltips are computed eagerly. This handler exists so clients
 * that send resolve requests don't get errors.
 */
fn Object*? handle_inlay_hint_resolve(Object* hint) {
	return hint;
}
