module kls::lsp::signature_help;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::definition;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

/**
 * Handle textDocument/signatureHelp request.
 * Returns a SignatureHelp JSON object with the active function signature
 * and the active parameter index, or null if the cursor is not inside
 * a function call.
 */
fn Object* handle_signature_help(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	long byte_offset = hover::position_to_offset(doc.content, line, character);
	if (byte_offset < 0) {
		return null;
	}
	uint cursor = (uint)byte_offset;

	// Get cached AST
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	// Find the innermost CALL_EXPR whose argument list contains the cursor
	AstNode* call_node;
	if (try node = find_enclosing_call(pr, doc.content, cursor)) {
		call_node = node;
	} else {
		return null;
	}

	// Find the opening paren of the call
	uint open_paren;
	if (try p = find_open_paren(doc.content, call_node)) {
		open_paren = p;
	} else {
		return null;
	}

	// Resolve the function declaration
	AstNode* decl;
	if (try d = find_called_declaration(pr, call_node)) {
		decl = d;
	} else {
		return null;
	}

	// Count active parameter (commas before cursor at depth 0)
	int active_param = count_active_param(doc.content, open_paren, cursor);

	// Build the SignatureHelp response
	return build_signature_help(decl, pr, active_param);
}

/**
 * Find the innermost CALL_EXPR that contains the cursor within its
 * argument list (between the opening paren and closing paren/end).
 *
 * We check that the cursor is after the opening paren of the call,
 * not just within the node's full span (which includes the callee).
 */
fn AstNode*? find_enclosing_call(ParseResult* pr, String content, uint cursor) {
	AstNode* best = null;

	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CALL_EXPR) continue;

		// The cursor must be within the node's span
		if (cursor < n.start_offset || cursor > n.end_offset) continue;

		// Find the opening paren to ensure cursor is in the argument list
		if (try paren_off = find_open_paren(content, n)) {
			// Cursor must be after the opening paren
			if (cursor > paren_off) {
				// Pick the innermost (deepest) call -- later in the array
				// is generally deeper due to recursive descent order
				best = n;
			}
		}
	}

	if (best == null) return ast::NOT_FOUND~;
	return best;
}

/**
 * Find the byte offset of the opening '(' in a CALL_EXPR.
 * Lexes forward from the end of the call's name to locate LPAREN.
 */
fn uint? find_open_paren(String content, AstNode* call_node) {
	// Start scanning from after the function name
	uint scan_start = call_node.name_offset + call_node.name_len;
	if (scan_start >= content.len) return ast::NOT_FOUND~;

	// If there's no name (shouldn't happen for calls), scan from node start
	if (call_node.name_len == 0) {
		scan_start = call_node.start_offset;
	}

	Lexer lex = lexer::init(content[scan_start..]);
	// Scan forward looking for the LPAREN, skip generic type params
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
 * Resolve the called function's declaration from a CALL_EXPR node.
 * Uses the call node's name to find a matching FUN_DECL or CONSTRUCTOR_DECL.
 */
fn AstNode*? find_called_declaration(ParseResult* pr, AstNode* call_node) {
	String name = call_node.name;
	if (name.len == 0) return ast::NOT_FOUND~;

	// Use scope-aware definition lookup (is_call = true prefers FUN_DECL)
	return definition::find_definition_in_ast(pr, name, call_node.name_offset, true);
}

/**
 * Count the active parameter index by counting commas at nesting depth 0
 * between the opening paren and the cursor position.
 */
fn int count_active_param(String content, uint open_paren, uint cursor) {
	if (cursor <= open_paren) return 0;

	uint scan_start = open_paren + 1; // skip past '('
	if (scan_start >= content.len) return 0;

	// Calculate how far to scan
	uint scan_end = cursor;
	if (scan_end > content.len) scan_end = (uint)content.len;

	int param_index = 0;
	int depth = 0;

	Lexer lex = lexer::init(content[scan_start..]);

	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		uint abs_offset = scan_start + tok.offset;
		if (abs_offset >= scan_end) break;

		switch (tok.kind) {
			case LPAREN:
			case LSQUARE:
			case LCURL:
				depth++;
			case RPAREN:
				if (depth == 0) return param_index; // end of call
				depth--;
			case RSQUARE:
			case RCURL:
				if (depth > 0) depth--;
			case COMMA:
				if (depth == 0) param_index++;
			default:
				// skip
		}
	}

	return param_index;
}

/**
 * Build the SignatureHelp JSON response from a function/constructor declaration.
 */
fn Object* build_signature_help(AstNode* decl, ParseResult* pr, int active_param) {
	// Build the signature label and collect parameter label offsets
	DString label;
	label.tinit();

	// Modifiers
	hover::append_modifiers(&label, decl.mod_flags);

	// Parameter info tracking
	// Store up to 32 parameter offset pairs
	int[64] param_offsets; // pairs of [start, end]
	int param_count = 0;

	if (decl.kind == FUN_DECL) {
		label.appendf("fun %s(", decl.name);
		param_count = append_params(&label, &param_offsets, decl, pr);
		label.appendf(")");
		if (decl.type_text.len > 0) {
			label.appendf(": %s", decl.type_text);
		}
	} else if (decl.kind == CONSTRUCTOR_DECL) {
		label.appendf("constructor(");
		param_count = append_params(&label, &param_offsets, decl, pr);
		label.appendf(")");
	} else if (decl.kind == CLASS_DECL) {
		// Class used as constructor call (e.g., MyClass(...))
		// Look for a CONSTRUCTOR_DECL child or primary constructor params
		label.appendf("%s(", decl.name);
		usz decl_idx = ast::node_index(pr, decl);
		// Check for PARAM children (primary constructor params)
		param_count = append_params(&label, &param_offsets, decl, pr);
		label.appendf(")");
	} else {
		// Other declaration types -- provide basic label
		label.appendf("%s", decl.name);
	}

	String label_str = label.str_view();

	// Build ParameterInformation array
	Object* params_array = object::new_obj(tmem);
	for (int i = 0; i < param_count; i++) {
		Object* param_info = object::new_obj(tmem);
		Object* label_range = object::new_obj(tmem);
		label_range.push(object::new_int(param_offsets[i * 2], tmem));
		label_range.push(object::new_int(param_offsets[i * 2 + 1], tmem));
		param_info.set("label", label_range);
		params_array.push(param_info);
	}

	// Build SignatureInformation
	Object* sig_info = object::new_obj(tmem);
	sig_info.set("label", label_str);
	sig_info.set("parameters", params_array);

	// Build SignatureHelp
	Object* signatures = object::new_obj(tmem);
	signatures.push(sig_info);

	// Clamp active param to valid range
	int clamped_param = active_param;
	if (param_count > 0 && clamped_param >= param_count) {
		clamped_param = param_count - 1;
	}

	Object* result = object::new_obj(tmem);
	result.set("signatures", signatures);
	result.set("activeSignature", 0);
	result.set("activeParameter", clamped_param);

	return result;
}

/**
 * Append parameter list to the label DString and record the byte offset
 * of each parameter name+type within the label for ParameterInformation.
 * Returns the number of parameters appended.
 */
fn int append_params(DString* label, int[64]* offsets, AstNode* decl, ParseResult* pr) {
	usz decl_idx = ast::node_index(pr, decl);
	int count = 0;
	bool first = true;

	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != decl_idx) continue;
		if (child.kind != PARAM) continue;

		if (!first) {
			label.appendf(", ");
		}
		first = false;

		// Record the start offset of this parameter in the label
		int start = (int)label.len();

		label.appendf("%s", child.name);
		if (child.type_text.len > 0) {
			label.appendf(": %s", child.type_text);
		}

		// Record the end offset
		int end = (int)label.len();

		if (count < 32) {
			(*offsets)[count * 2] = start;
			(*offsets)[count * 2 + 1] = end;
		}
		count++;
	}

	return count;
}
