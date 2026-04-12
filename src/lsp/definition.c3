module kls::lsp::definition;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

/**
 * Handle textDocument/definition request.
 * Returns a Location JSON object pointing to the declaration of the
 * identifier under the cursor, or null if no definition is found.
 *
 * Uses the parser AST for scope-aware lookup: searches from the
 * innermost scope containing the cursor outward.
 * Only resolves definitions within the same document (no cross-file).
 */
fn Object* handle_definition(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	// Only navigate to definitions of identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Detect call context
	bool is_call = is_call_context(doc.content, tok);

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	// Find definition using scope-aware AST search
	if (try node = find_definition_in_ast(pr, target_name, tok.offset, is_call)) {
		return build_location_from_node(uri, node);
	}

	return null;
}

/**
 * Search the AST for a declaration matching the target name.
 * Starts from the innermost scope containing the cursor offset
 * and works outward. Prefers function declarations in call context.
 */
fn AstNode*? find_definition_in_ast(ParseResult* pr, String target_name, uint cursor_offset, bool is_call) {
	if (pr.node_count == 0) return ast::NOT_FOUND~;

	// Find the innermost scope containing the cursor.
	// Walk all nodes, tracking the deepest container that contains the cursor.
	usz scope_idx = 0; // FILE node
	for (usz i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!is_scope_node(n.kind)) continue;
		if (cursor_offset >= n.start_offset && cursor_offset < n.end_offset) {
			// Check if this is deeper than our current best
			// (further in the array = more deeply nested)
			scope_idx = i;
		}
	}

	// Search from innermost scope outward to FILE
	usz current = scope_idx;
	while (true) {
		AstNode* scope = &pr.nodes[current];

		// Search direct children of this scope for matching declarations
		AstNode* first_match = null;
		AstNode* func_match = null;

		for (usz i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.parent != current) continue;
			if (!ast::is_declaration(n.kind)) continue;
			if (n.name != target_name) continue;

			if (first_match == null) {
				first_match = n;
			}
			if (func_match == null && n.kind == FUN_DECL) {
				func_match = n;
			}
		}

		if (is_call && func_match != null) {
			return func_match;
		}
		if (first_match != null) {
			return first_match;
		}

		// Move to parent scope
		if (current == 0 || scope.parent == ast::NO_PARENT) {
			break; // Already at FILE level
		}
		current = scope.parent;
	}

	// ── Global fallback ───────────────────────────────────────────
	// The scope-walk didn't find a match. This happens when the
	// identifier refers to a member of a class/object that doesn't
	// contain the cursor (e.g. `nob.module { }` or `Nob.new(args)`).
	// Search ALL declarations in the entire AST as a fallback.
	{
		AstNode* first_match = null;
		AstNode* func_match = null;

		for (usz i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (!ast::is_declaration(n.kind)) continue;
			if (n.name != target_name) continue;

			if (first_match == null) {
				first_match = n;
			}
			if (func_match == null && n.kind == FUN_DECL) {
				func_match = n;
			}
		}

		if (is_call && func_match != null) {
			return func_match;
		}
		if (first_match != null) {
			return first_match;
		}
	}

	return ast::NOT_FOUND~;
}

/**
 * Check if a node kind represents a scope that can contain declarations.
 */
fn bool is_scope_node(NodeKind kind) {
	switch (kind) {
		case FILE:
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
			return true;
		default:
			return false;
	}
}

/**
 * Build an LSP Location object from an AST node's name position.
 */
fn Object* build_location_from_node(String uri, AstNode* node) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)node.name_line);
	start.set("character", (int)node.name_col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)node.name_line);
	end_pos.set("character", (int)(node.name_col + node.name_len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", uri);
	location.set("range", range);

	return location;
}

/**
 * Determine if an identifier token is in a call context by checking
 * the next non-whitespace token after it. Returns true if the next
 * token is `(`, `{` (trailing lambda), or `<` (generic invocation).
 */
fn bool is_call_context(String content, Token tok) {
	usz after_pos = (usz)tok.offset + (usz)tok.len;
	if (after_pos >= content.len) return false;

	// Lex from just after the cursor token to find the next token
	Lexer lex = lexer::init(content[after_pos..]);
	Token next = lex.next();

	return next.kind == LPAREN || next.kind == LCURL || next.kind == LANGLE;
}
