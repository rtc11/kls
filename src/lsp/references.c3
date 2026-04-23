module kls::lsp::references;

import std::io;
import std::io::file;
import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::lsp::definition;
import kls::workspace;

/**
 * Handle textDocument/references request.
 * Returns a JSON array of Location objects for all occurrences of the
 * identifier under the cursor, or null if nothing is found.
 *
 * Scans the lexer token stream for all IDENTIFIER tokens matching the
 * target name. When context.includeDeclaration is false, filters out
 * locations that correspond to AST declaration name positions.
 * Also scans workspace files for cross-file references.
 */
fn Object*? handle_references(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	// Check context.includeDeclaration (default true per LSP spec)
	bool include_declaration = true;
	if (try ctx = params.get("context")) {
		if (try incl = ctx.get_bool("includeDeclaration")) {
			include_declaration = incl;
		}
	}

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

	// Only find references for identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Get cached AST + types for scope-aware filtering
	ParseResult* pr = store.get_ast(uri) ?? null;
	TypeInfo* ti = store.get_types(uri) ?? null;

	// Resolve cursor's identifier to a stable target identity. Handles
	// dot-member, qualified callable-ref (`Type::member`), and bare-name
	// scope walk. CROSS_FILE targets fall back to name-based scope filter
	// (declaration not in this file → can't compare per-token offsets).
	bool is_call = false;
	if (pr != null) {
		is_call = definition::is_call_context_ast(pr, tok.offset) || definition::is_call_context(doc.content, tok);
	}
	TokenTarget target = definition::NO_TARGET;
	if (pr != null) {
		target = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, tok.offset, is_call);
		// If cursor IS on a declaration and resolution failed, treat
		// the declaration site itself as the target.
		if (target.kind == TargetKind.NONE && is_declaration_name(pr, tok.offset)) {
			target = (TokenTarget){
				.kind = TargetKind.IN_FILE,
				.uri = uri,
				.name_offset = tok.offset,
			};
		}
	}

	// Collect IDENTIFIER tokens matching target_name,
	// skipping identifiers inside package/import paths.
	// When AST available, filter to tokens that resolve to same declaration.
	Object* locations = object::new_obj(tmem);  // JSON array

	Lexer lex = lexer::init(doc.content);
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

		// If not including declarations, check if this token is a declaration name
		if (!include_declaration && pr != null) {
			if (is_declaration_name(pr, t.offset)) {
				continue;
			}
		}

		// Scope-aware filtering: when target is in this file, verify each
		// candidate token resolves to the same target. CROSS_FILE targets
		// skip per-token verification (current file shouldn't have decl);
		// matches by name only — same as the existing fallback.
		if (pr != null && target.kind == TargetKind.IN_FILE) {
			// Cursor's own declaration site (raw byte offset path)
			if (t.offset == target.name_offset) {
				if (include_declaration) {
					Object* location = build_location(uri, t);
					locations.push(location);
				}
				continue;
			}
			if (!definition::token_binds_to_target(target, pr, ti, workspace, store, uri, target_name, t.offset, is_call)) {
				continue;
			}
		} else if (pr != null && target.kind == TargetKind.CROSS_FILE) {
			// Verify candidate also resolves cross-file to the same URI.
			TokenTarget cand = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, t.offset, is_call);
			if (cand.kind != TargetKind.CROSS_FILE || cand.uri != target.uri) continue;
		}

		// Build Location for this occurrence
		Object* location = build_location(uri, t);
		locations.push(location);
	}

	// ── Cross-file references via workspace index ────────────────
	if (workspace != null) {
		add_cross_file_references(locations, workspace, store, target_name, uri);
	}

	// Return null if no references found
	if (locations.get_len() == 0) {
		return null;
	}

	return locations;
}

/**
 * Check if a given byte offset corresponds to a declaration's name position
 * in the AST. Used to filter out declaration sites when includeDeclaration
 * is false.
 */
fn bool is_declaration_name(ParseResult* pr, uint offset) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name_offset == offset && n.name_len > 0) {
			return true;
		}
	}
	return false;
}

/**
 * Build an LSP Location object from a token's position.
 */
fn Object* build_location(String uri, Token tok) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", uri);
	location.set("range", range);

	return location;
}

// ── Cross-file reference scanning ─────────────────────────────────

/**
 * Scan workspace files (other than current_uri) for IDENTIFIER tokens
 * matching target_name, and add them as Location objects.
 * Checks the document store first for open files, falls back to disk.
 */
fn void add_cross_file_references(Object* locations, WorkspaceIndex* workspace, DocumentStore* store, String target_name, String current_uri) {
	// Collect unique URIs to scan from two sources:
	// 1. Workspace index: files that declare a symbol with the target name
	// 2. Open documents: files that might use (but not declare) the name
	String[256] uris_to_scan;
	usz uri_count = 0;

	// Source 1: workspace index — files with matching symbol declarations
	if (try indices = workspace.lookup_by_name(target_name)) {
		for (usz i = 0; i < indices.len() && uri_count < 256; i++) {
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

	// Source 2: all open documents — catches files that USE but don't DECLARE the name
	foreach (doc_uri : store.docs.tkeys()) {
		if (doc_uri == current_uri) continue;
		if (uri_count >= 256) break;

		// Dedup against workspace URIs already added
		bool already_have = false;
		for (usz j = 0; j < uri_count; j++) {
			if (uris_to_scan[j] == doc_uri) {
				already_have = true;
				break;
			}
		}
		if (!already_have) {
			uris_to_scan[uri_count] = doc_uri;
			uri_count++;
		}
	}

	// Scan each file for all IDENTIFIER tokens matching target_name
	for (usz f = 0; f < uri_count; f++) {
		String file_uri = uris_to_scan[f];

		// Check if the file is open in the document store first
		if (try doc = store.get(file_uri)) {
			scan_file_for_references(locations, file_uri, doc.content, target_name);
			continue;
		}

		// Fall back to reading from disk
		String file_path = workspace::uri_to_path(file_uri);
		if (try content = workspace::read_file_content(file_path)) {
			defer mem::free(content.ptr);
			scan_file_for_references(locations, file_uri, content, target_name);
		}
	}
}

/**
 * Lex a file's content and add Location objects for every IDENTIFIER
 * token matching the target name. Skips identifiers inside package/import paths.
 */
fn void scan_file_for_references(Object* locations, String uri, String content, String target_name) {
	Lexer lex = lexer::init(content);
	bool in_package_or_import = false;
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

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

		Object* location = build_location(uri, t);
		locations.push(location);
	}
}
