module kls::lsp::linked_editing_range;

import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::lsp::definition;
import kls::lsp::references;
import kls::workspace;

/**
 * Handle textDocument/linkedEditingRange request.
 * Returns a LinkedEditingRanges object containing all same-name identifier
 * ranges in the document, enabling rename-as-you-type for the identifier
 * under the cursor.
 *
 * Only applies to IDENTIFIER tokens. Returns null for keywords or non-identifiers.
 */
fn Object*? handle_linked_editing_range(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

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

	// Use AST + types for binding-aware filtering
	ParseResult* pr = store.get_ast(uri) ?? null;
	TypeInfo* ti = store.get_types(uri) ?? null;

	bool is_call = false;
	if (pr != null) {
		is_call = definition::is_call_context_ast(pr, tok.offset) || definition::is_call_context(doc.content, tok);
	}

	// Resolve cursor's identifier via the unified binding adapter.
	TokenTarget target = definition::NO_TARGET;
	if (pr != null) {
		target = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, tok.offset, is_call);
		if (target.kind == TargetKind.NONE && references::is_declaration_name(pr, tok.offset)) {
			target = (TokenTarget){
				.kind = TargetKind.IN_FILE,
				.uri = uri,
				.name_offset = tok.offset,
			};
		}
	}

	// For decoded line/col targets (sourced from dot-member resolver), prepare
	// alternative comparison.
	bool target_is_encoded = false;
	uint enc_line = 0;
	uint enc_col = 0;
	if (pr != null && target.kind == TargetKind.IN_FILE) {
		bool is_byte_offset = false;
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.name_offset == target.name_offset && n.name == target_name && ast::is_declaration(n.kind)) {
				is_byte_offset = true;
				break;
			}
		}
		if (!is_byte_offset) {
			target_is_encoded = true;
			enc_line = target.name_offset >> 16;
			enc_col = target.name_offset & 0xFFFF;
		}
	}

	// Collect matching IDENTIFIER tokens that bind to the same target
	Object* ranges = object::new_obj(tmem); // JSON array

	Lexer lex = lexer::init(doc.content);
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;
		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		if (pr != null && target.kind == TargetKind.IN_FILE) {
			bool is_decl_site = (!target_is_encoded && t.offset == target.name_offset)
				|| (target_is_encoded && t.line == enc_line && t.col == enc_col);
			if (!is_decl_site) {
				if (!definition::token_binds_to_target(target, pr, ti, workspace, store, uri, target_name, t.offset, is_call)) {
					continue;
				}
			}
		} else if (pr != null && target.kind == TargetKind.CROSS_FILE) {
			TokenTarget cand = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, t.offset, is_call);
			if (cand.kind != TargetKind.CROSS_FILE || cand.uri != target.uri) continue;
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
