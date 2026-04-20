module kls::lsp::linked_editing_range;

import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::lsp::definition;
import kls::lsp::references;

/**
 * Handle textDocument/linkedEditingRange request.
 * Returns a LinkedEditingRanges object containing all same-name identifier
 * ranges in the document, enabling rename-as-you-type for the identifier
 * under the cursor.
 *
 * Only applies to IDENTIFIER tokens. Returns null for keywords or non-identifiers.
 */
fn Object* handle_linked_editing_range(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	// Find token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	if (tok.kind != IDENTIFIER) return null;

	String target_name = tok.text;

	// Use AST for scope-aware binding resolution
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Resolve cursor's identifier to its declaration
	uint decl_offset = uint.max;
	if (pr != null) {
		if (try decl_node = definition::find_definition_in_ast(pr, target_name, tok.offset, false)) {
			decl_offset = decl_node.name_offset;
		}
		if (decl_offset == uint.max && references::is_declaration_name(pr, tok.offset)) {
			decl_offset = tok.offset;
		}
	}

	// Collect matching IDENTIFIER tokens that resolve to same declaration
	Object* ranges = object::new_obj(tmem); // JSON array

	Lexer lex = lexer::init(doc.content);
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;
		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		// Scope-aware filtering via binding resolution
		if (pr != null && decl_offset != uint.max) {
			if (t.offset == decl_offset) {
				// Declaration itself — include
			} else if (try candidate = definition::find_definition_in_ast(pr, target_name, t.offset, false)) {
				if (candidate.name_offset != decl_offset) continue;
			} else {
				continue;
			}
		} else if (pr != null) {
			// Fallback: enclosing scope comparison
			uint cursor_scope = find_enclosing_scope(pr, tok.offset);
			uint tok_scope = find_enclosing_scope(pr, t.offset);
			if (tok_scope != cursor_scope) continue;
		}

		Object* start_pos = object::new_obj(tmem);
		start_pos.set("line", (int)t.line);
		start_pos.set("character", (int)t.col);

		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", (int)t.line);
		end_pos.set("character", (int)(t.col + t.len));

		Object* range = object::new_obj(tmem);
		range.set("start", start_pos);
		range.set("end", end_pos);

		ranges.push(range);
	}

	if (ranges.get_len() == 0) return null;

	// LSP LinkedEditingRanges response
	Object* result = object::new_obj(tmem);
	result.set("ranges", ranges);
	// wordPattern: Kotlin identifier pattern
	result.set("wordPattern", "[a-zA-Z_][a-zA-Z0-9_]*");

	return result;
}

/**
 * Find the enclosing scope node index for a byte offset.
 * Scopes are: BLOCK, FUN_DECL, CLASS_DECL, OBJECT_DECL, FILE.
 * Returns the innermost scope containing the offset.
 */
fn uint find_enclosing_scope(ParseResult* pr, uint offset) {
	uint best = 0; // FILE (root)
	uint best_size = uint.max;

	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != BLOCK && n.kind != FUN_DECL && n.kind != CLASS_DECL
			&& n.kind != OBJECT_DECL && n.kind != FILE) continue;

		if (offset >= n.start_offset && offset < n.end_offset) {
			uint size = n.end_offset - n.start_offset;
			if (size < best_size) {
				best = i;
				best_size = size;
			}
		}
	}

	return best;
}
