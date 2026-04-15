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
