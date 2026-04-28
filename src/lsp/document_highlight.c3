module kls::lsp::document_highlight;

import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::references;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::lsp::definition;
import kls::workspace;

// DocumentHighlightKind (LSP 3.17)
const int TEXT  = 1;
const int READ  = 2;
const int WRITE = 3;

/**
 * Handle textDocument/documentHighlight request.
 * Returns a JSON array of DocumentHighlight objects for all occurrences
 * of the identifier under the cursor, or null if nothing is found.
 *
 * Uses the lexer token stream to find all matching IDENTIFIER tokens,
 * then classifies each as Write (declaration sites) or Read (usage sites)
 * using the AST.
 */
fn Object*? handle_document_highlight(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

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

	// Only highlight identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Get cached AST + types for scope-aware filtering and decl classification
	ParseResult* pr = store.get_ast(uri) ?? null;
	TypeInfo* ti = store.get_types(uri) ?? null;

	// Resolve cursor's identifier via the unified binding adapter.
	// Handles dot-member, qualified callable-ref, and bare-name uniformly.
	bool is_call = false;
	if (pr != null) {
		is_call = definition::is_call_context_ast(pr, tok.offset) || definition::is_call_context(doc.content, tok);
	}
	TokenTarget target = definition::NO_TARGET;
	if (pr != null) {
		target = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, tok.offset, is_call);
		if (target.kind == TargetKind.NONE) {
			uint decl_idx_self = 0;
			if (references::find_decl_idx_at_offset(pr, target_name, tok.offset, &decl_idx_self)) {
				target = definition::make_ast_target(uri, decl_idx_self);
			}
		}
	}

	// Precompute the in-file decl token offset (if AST_NODE points at this file).
	bool target_in_this_file = (target.kind == TargetKind.AST_NODE && pr != null && target.uri == uri);
	uint decl_byte_offset = uint.max;
	if (target_in_this_file && target.decl_idx < pr.node_count) {
		decl_byte_offset = pr.nodes[target.decl_idx].name_offset;
	}

	// Collect IDENTIFIER tokens matching target_name, scope-filtered
	Object* highlights = object::new_obj(tmem); // JSON array

	Lexer lex = lexer::init(doc.content);
	bool in_package_or_import = false;
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		// Skip package/import paths
		if (t.kind == KW_PACKAGE || t.kind == KW_IMPORT) {
			in_package_or_import = true;
			continue;
		}
		if (in_package_or_import) {
			if (t.kind == IDENTIFIER || t.kind == DOT || t.kind == MULT) continue;
			in_package_or_import = false;
		}

		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		// Adapter-based scope filter when AST + target available.
		if (pr != null && target_in_this_file) {
			// Same-file declaration site
			if (decl_byte_offset != uint.max && t.offset == decl_byte_offset) {
				Object* highlight = build_highlight(t, WRITE);
				highlights.push(highlight);
				continue;
			}
			if (!definition::token_binds_to_target(target, pr, ti, workspace, store, uri, target_name, t.offset, is_call)) {
				continue;
			}
		} else if (pr != null && target.kind != TargetKind.NONE) {
			// Cross-file / dep / external target.
			TokenTarget cand = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, t.offset, is_call);
			if (!definition::target_equals(target, cand)) continue;
		}

		// Classify: declaration names are Write, everything else is Read
		int kind = READ;
		if (pr != null && references::is_declaration_name(pr, t.offset)) {
			kind = WRITE;
		}

		Object* highlight = build_highlight(t, kind);
		highlights.push(highlight);
	}

	// Return null if no highlights found
	if (highlights.get_len() == 0) {
		return null;
	}

	return highlights;
}

/**
 * Build an LSP DocumentHighlight object from a token and highlight kind.
 */
fn Object* build_highlight(Token tok, int kind) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* highlight = object::new_obj(tmem);
	highlight.set("range", range);
	highlight.set("kind", kind);

	return highlight;
}
