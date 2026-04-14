module kls::lsp::rename;

import std::io;
import std::io::file;
import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::definition;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::workspace;

/**
 * Handle textDocument/prepareRename request.
 * Returns a { range, placeholder } object if the identifier at the cursor
 * can be renamed, or null if renaming is not possible at this position.
 */
fn Object* handle_prepare_rename(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	// Only identifiers can be renamed
	if (tok.kind != IDENTIFIER) return null;

	// Reject identifiers inside package/import paths
	if (is_in_package_or_import(doc.content, tok.offset)) return null;

	// Build { range, placeholder } response
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* result = object::new_obj(tmem);
	result.set("range", range);
	result.set("placeholder", tok.text);

	return result;
}

/**
 * Handle textDocument/rename request.
 * Returns a WorkspaceEdit with text edits for all occurrences of the
 * identifier under the cursor, scoped to the declaration it refers to.
 *
 * Uses the AST to resolve the declaration, then only renames references
 * that resolve to the same declaration node. Local declarations (inside
 * functions, blocks, lambdas) are renamed only within their scope.
 * Top-level declarations are also renamed across workspace files.
 *
 * The WorkspaceEdit uses the "changes" map format:
 *   { "changes": { "uri1": [TextEdit, ...], "uri2": [...] } }
 */
fn Object* handle_rename(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	String new_name = params.get_string("newName")!!;

	// #17: Validate that the new name is a legal Kotlin identifier
	if (new_name.len == 0) return null;
	if (!lexer::is_ident_start(new_name[0])) return null;
	for (usz i = 1; i < new_name.len; i++) {
		if (!lexer::is_ident_part(new_name[i])) return null;
	}
	// Reject hard keywords as new names
	Lexer name_lex = lexer::init(new_name);
	Token name_tok = name_lex.next();
	if (name_tok.kind != IDENTIFIER && !name_tok.kind.is_identifier_or_soft_keyword()) return null;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	// Only identifiers can be renamed
	if (tok.kind != IDENTIFIER) return null;

	String target_name = tok.text;

	// If the new name is the same as the old name, nothing to do
	if (target_name == new_name) return null;

	// Get cached AST for scope-aware rename
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Detect call context for accurate definition resolution
	bool is_call = false;
	if (pr != null) {
		is_call = definition::is_call_context_ast(pr, tok.offset) || definition::is_call_context(doc.content, tok);
	}

	// ── Resolve the declaration this identifier refers to ────────
	// This uses the scope-aware lookup from definition.c3:
	// finds the innermost scope, walks outward to find the declaration.
	uint decl_idx = 0;
	bool has_decl = false;
	bool is_top_level = true;

	if (pr != null) {
		if (try decl_node = definition::find_definition_in_ast(pr, target_name, tok.offset, is_call)) {
			decl_idx = ast::node_index(pr, decl_node);
			has_decl = true;
			// A declaration is top-level if its parent is the FILE node (index 0)
			is_top_level = (decl_node.parent == 0);
		}
	}

	// Build the changes map: uri -> [TextEdit, ...]
	Object* changes = object::new_obj(tmem);
	bool has_edits = false;

	// ── Current file edits ──────────────────────────────────────
	Object* edits;
	if (has_decl && pr != null) {
		// Scope-aware: only rename tokens that resolve to the same declaration
		edits = collect_scoped_edits(doc.content, pr, decl_idx, target_name, new_name, is_call);
	} else {
		// No AST or no declaration found: fall back to name-based rename
		edits = collect_edits_in_file(doc.content, target_name, new_name);
	}
	if (edits.get_len() > 0) {
		changes.set(uri, edits);
		has_edits = true;
	}

	// ── Cross-file edits via workspace index ────────────────────
	// Only for top-level declarations (local vars/params can't be
	// referenced from other files)
	if (workspace != null && is_top_level) {
		if (add_cross_file_edits(changes, workspace, store, target_name, new_name, uri)) {
			has_edits = true;
		}
	}

	// If no edits were found, return null
	if (!has_edits) return null;

	// Build WorkspaceEdit
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	return workspace_edit;
}

// ── Scope-aware file scanning ─────────────────────────────────────

/**
 * Collect TextEdit objects for identifiers that resolve to a specific
 * declaration in the AST. For each matching IDENTIFIER token, verifies
 * that definition::find_definition_in_ast resolves it to the same
 * declaration node (decl_idx). This correctly handles shadowing:
 * if an inner scope redeclares the same name, its references won't
 * resolve to the outer declaration and will be excluded.
 */
fn Object* collect_scoped_edits(String content, ParseResult* pr, usz decl_idx, String target_name, String new_name, bool is_call) {
	Object* edits = object::new_obj(tmem);  // JSON array

	AstNode* decl = &pr.nodes[decl_idx];
	uint scope_idx = decl.parent;

	// For non-top-level declarations, restrict scanning to the scope range
	// to avoid unnecessary definition lookups on unrelated tokens.
	uint scope_start = 0;
	uint scope_end = 0;
	bool restrict_to_scope = (scope_idx != 0);
	if (restrict_to_scope) {
		AstNode* scope = &pr.nodes[scope_idx];
		scope_start = scope.start_offset;
		scope_end = scope.end_offset;
	}

	Lexer lex = lexer::init(content);
	bool in_package_or_import = false;
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		// Enter skip mode when we see a package or import keyword
		if (t.kind == KW_PACKAGE || t.kind == KW_IMPORT) {
			in_package_or_import = true;
			continue;
		}

		// While inside a package/import path, skip path segments
		if (in_package_or_import) {
			if (t.kind == IDENTIFIER || t.kind == DOT || t.kind == MULT) continue;
			in_package_or_import = false;
		}

		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		// For local declarations, skip tokens outside the scope range
		if (restrict_to_scope) {
			if (t.offset < scope_start || t.offset >= scope_end) continue;
		}

		// Verify this token resolves to our target declaration.
		// This handles shadowing: if an inner scope declares the same
		// name, find_definition_in_ast will resolve to the inner one
		// instead, and the index won't match.
		if (try found = definition::find_definition_in_ast(pr, target_name, t.offset, is_call)) {
			uint found_idx = ast::node_index(pr, found);
			if (found_idx != decl_idx) continue;  // different declaration (shadowed)
		}

		Object* edit = build_text_edit(t, new_name);
		edits.push(edit);
	}

	return edits;
}

// ── Name-based file scanning (for cross-file edits) ───────────────

/**
 * Lex a file's content and collect TextEdit objects for every IDENTIFIER
 * token matching the target name. Skips identifiers that appear inside
 * package or import paths. Used for cross-file edits where no AST is
 * available for scope resolution.
 */
fn Object* collect_edits_in_file(String content, String target_name, String new_name) {
	Object* edits = object::new_obj(tmem);  // JSON array

	Lexer lex = lexer::init(content);
	bool in_package_or_import = false;
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		// Enter skip mode when we see a package or import keyword
		if (t.kind == KW_PACKAGE || t.kind == KW_IMPORT) {
			in_package_or_import = true;
			continue;
		}

		// While inside a package/import path, skip path segments
		if (in_package_or_import) {
			if (t.kind == IDENTIFIER || t.kind == DOT || t.kind == MULT) continue;
			in_package_or_import = false;
		}

		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		Object* edit = build_text_edit(t, new_name);
		edits.push(edit);
	}

	return edits;
}

// ── Helpers ───────────────────────────────────────────────────────

/**
 * Build a TextEdit object { range, newText } from a token.
 */
fn Object* build_text_edit(Token tok, String new_text) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", new_text);

	return edit;
}

/**
 * Check if a byte offset falls inside a package or import path by
 * lexing from the start and tracking package/import state.
 */
fn bool is_in_package_or_import(String content, uint target_offset) {
	Lexer lex = lexer::init(content);
	bool in_path = false;
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		if (t.kind == KW_PACKAGE || t.kind == KW_IMPORT) {
			in_path = true;
			continue;
		}

		if (in_path) {
			if (t.kind == IDENTIFIER || t.kind == DOT || t.kind == MULT) {
				if (t.offset == target_offset) return true;
				continue;
			}
			in_path = false;
		}

		// If we've passed the target offset, no point continuing
		if (t.offset > target_offset) break;
	}
	return false;
}

// ── Cross-file rename ─────────────────────────────────────────────

/**
 * Scan workspace files (other than current_uri) for IDENTIFIER tokens
 * matching target_name, and add TextEdit arrays to the changes map.
 * Uses the workspace index to find candidate files, then lexes each.
 * Returns true if any edits were added.
 */
fn bool add_cross_file_edits(Object* changes, WorkspaceIndex* workspace, DocumentStore* store, String target_name, String new_name, String current_uri) {
	// Collect unique URIs that have at least one symbol with this name
	String[128] uris_to_scan;
	usz uri_count = 0;

	if (try indices = workspace.lookup_by_name(target_name)) {
		for (usz i = 0; i < indices.len() && uri_count < 128; i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.name.len == 0) continue;
			if (sym.uri == current_uri) continue;

			// Dedup URIs
			bool already_have = false;
			for (usz j = 0; j < uri_count; j++) {
				if (uris_to_scan[j] == sym.uri) {
					already_have = true;
					break;
				}
			}
			if (!already_have) {
				uris_to_scan[uri_count] = sym.uri;
				uri_count++;
			}
		}
	}

	// Scan each file and add edits to the changes map
	bool added_any = false;
	for (usz f = 0; f < uri_count; f++) {
		String file_uri = uris_to_scan[f];

		// Check if the file is open in the document store first
		if (try doc = store.get(file_uri)) {
			Object* edits = collect_edits_in_file(doc.content, target_name, new_name);
			if (edits.get_len() > 0) {
				changes.set(file_uri, edits);
				added_any = true;
			}
			continue;
		}

		// Fall back to reading from disk
		String file_path = workspace::uri_to_path(file_uri);
		if (try content = workspace::read_file_content(file_path)) {
			defer mem::free(content.ptr);
			Object* edits = collect_edits_in_file(content, target_name, new_name);
			if (edits.get_len() > 0) {
				changes.set(file_uri, edits);
				added_any = true;
			}
		}
	}

	return added_any;
}
