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
import kls::kotlin::types;
import kls::workspace;

/**
 * Handle textDocument/prepareRename request.
 * Returns a { range, placeholder } object if the identifier at the cursor
 * can be renamed, or null if renaming is not possible at this position.
 */
fn Object*? handle_prepare_rename(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

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
fn Object*? handle_rename(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	String new_name = params.get_string("newName")!;

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

	// Get cached AST + types for scope-aware rename
	ParseResult* pr = store.get_ast(uri) ?? null;
	TypeInfo* ti = store.get_types(uri) ?? null;

	// Detect call context for accurate definition resolution
	bool is_call = false;
	if (pr != null) {
		is_call = definition::is_call_context_ast(pr, tok.offset) || definition::is_call_context(doc.content, tok);
	}

	// ── Resolve the cursor's binding via the unified adapter ─────
	// Handles dot-member, qualified callable-ref (`Type::member`), and
	// bare-name scope walk uniformly. CROSS_FILE result tells us the
	// declaration lives outside this file → top-level for rename
	// purposes.
	TokenTarget target = definition::NO_TARGET;
	uint decl_idx = 0;
	bool has_decl = false;
	bool is_top_level = true;

	if (pr != null) {
		target = definition::resolve_token_binding(pr, ti, workspace, store, uri, target_name, tok.offset, is_call);
		if (target.kind == TargetKind.IN_FILE) {
			// Try to recover the AstNode from raw byte offset (when the
			// target came from scope walk). When it came from the dot-
			// member resolver, name_offset is encoded line/col — find
			// the matching AST node by line/col instead.
			has_decl = recover_decl_idx(pr, target_name, target.name_offset, &decl_idx);
			if (has_decl) {
				is_top_level = is_externally_visible_decl(pr, decl_idx);
			} else {
				// Encoded line/col: search by name + line/col
				uint enc = target.name_offset;
				uint t_line = enc >> 16;
				uint t_col = enc & 0xFFFF;
				for (uint i = 0; i < pr.node_count; i++) {
					AstNode* n = &pr.nodes[i];
					if (!ast::is_declaration(n.kind)) continue;
					if (n.name != target_name) continue;
					if (n.name_line != t_line || n.name_col != t_col) continue;
					decl_idx = i;
					has_decl = true;
					is_top_level = is_externally_visible_decl(pr, i);
					break;
				}
			}
		} else if (target.kind == TargetKind.CROSS_FILE) {
			// Declaration in another file — treat as top-level so the
			// cross-file scan runs. has_decl stays false; current file
			// uses adapter-based per-token verification instead of
			// scope restriction.
			is_top_level = true;
		}
	}

	// Build the changes map: uri -> [TextEdit, ...]
	Object* changes = object::new_obj(tmem);
	bool has_edits = false;

	// ── Current file edits ──────────────────────────────────────
	Object* edits;
	if (target.kind != TargetKind.NONE && pr != null) {
		// Adapter-based: any token whose binding equals `target` gets renamed.
		// Subsumes both same-file scope-aware and callable-ref/dot-member.
		edits = collect_target_edits(doc.content, pr, ti, workspace, store, uri,
			target, target_name, new_name, is_call, has_decl, decl_idx);
	} else {
		// No AST or no resolution: fall back to name-based rename.
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
 * Recover the AST node index of a declaration whose name identifier
 * starts at `byte_offset`. Returns true on success and writes the index
 * into `*out_idx`. Used when the rename target was sourced from a
 * scope-walk lookup (raw byte offset).
 */
fn bool recover_decl_idx(ParseResult* pr, String target_name, uint byte_offset, uint* out_idx) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != target_name) continue;
		if (n.name_offset != byte_offset) continue;
		*out_idx = i;
		return true;
	}
	return false;
}

/**
 * Returns true when the declaration at `decl_idx` is potentially
 * referenceable from outside the current file. Top-level (parent==0)
 * decls qualify, as do members of class/interface/object/companion
 * bodies (callable as `Type.member` or via `Type::member`). Locals
 * (decl inside a function body, block, or lambda) do not.
 */
fn bool is_externally_visible_decl(ParseResult* pr, uint decl_idx) {
	if (decl_idx >= pr.node_count) return false;
	AstNode* decl = &pr.nodes[decl_idx];
	if (decl.parent == 0 || decl.parent == ast::NO_PARENT) return true;
	AstNode* parent = &pr.nodes[decl.parent];
	switch (parent.kind) {
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
 * Collect TextEdit objects for tokens that bind to `target` in the
 * current file. Each candidate IDENTIFIER token (matching name) is
 * passed through `definition::token_binds_to_target` for verification.
 *
 * For IN_FILE targets with a recovered AstNode (`has_decl == true`):
 *   - non-top-level decls restrict scanning to the declaration's
 *     enclosing scope range (avoids per-token resolver cost on
 *     unrelated tokens).
 *   - the declaration site itself is matched by raw byte offset.
 *
 * For IN_FILE targets sourced from the dot-member resolver (no AstNode
 * recovered, name_offset is encoded line/col): the declaration site is
 * matched by line/col equality with the candidate token.
 *
 * For CROSS_FILE targets: every same-name candidate is verified against
 * the foreign URI; declaration site is in another file (not in this
 * scan).
 */
fn Object* collect_target_edits(String content, ParseResult* pr, TypeInfo* ti,
		WorkspaceIndex* workspace, DocumentStore* store, String current_uri,
		TokenTarget target, String target_name, String new_name, bool is_call,
		bool has_decl, uint decl_idx) {
	Object* edits = object::new_obj(tmem);  // JSON array

	// Optional scope restriction for in-file local decls.
	// Only restrict when the declaration is truly local — i.e., its parent
	// is a function body, block, or lambda. Members of classes/objects/
	// interfaces/companion objects are accessible anywhere via member
	// access (incl. callable refs `Type::member`); restricting them to
	// the class body would skip valid call sites.
	bool restrict_to_scope = false;
	uint scope_start = 0;
	uint scope_end = 0;
	if (has_decl) {
		AstNode* decl = &pr.nodes[decl_idx];
		uint scope_idx = decl.parent;
		if (scope_idx != 0) {
			AstNode* scope = &pr.nodes[scope_idx];
			NodeKind sk = scope.kind;
			bool is_class_like_body =
				sk == CLASS_DECL ||
				sk == INTERFACE_DECL ||
				sk == OBJECT_DECL ||
				sk == COMPANION_OBJECT_DECL;
			if (!is_class_like_body) {
				scope_start = scope.start_offset;
				scope_end = scope.end_offset;
				restrict_to_scope = true;
			}
		}
	}

	// Encoded line/col path: when target.name_offset is encoded, decode for
	// declaration-site comparison by token line/col. We always compute the
	// declaration's line/col when an AstNode is known (whether discovered
	// by raw byte offset or by encoded line/col), so the lexer pass can
	// match the decl site by line/col regardless of the recovery path.
	bool target_is_in_file = (target.kind == TargetKind.IN_FILE);
	uint enc_line = 0;
	uint enc_col = 0;
	uint decl_byte_offset = uint.max;
	if (target_is_in_file) {
		if (has_decl) {
			enc_line = pr.nodes[decl_idx].name_line;
			enc_col = pr.nodes[decl_idx].name_col;
			decl_byte_offset = pr.nodes[decl_idx].name_offset;
		} else {
			enc_line = target.name_offset >> 16;
			enc_col = target.name_offset & 0xFFFF;
		}
	}

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

		// Local decl: skip tokens outside the scope range.
		if (restrict_to_scope) {
			if (t.offset < scope_start || t.offset >= scope_end) continue;
		}

		// Same-file declaration site: include directly.
		if (target_is_in_file) {
			if (decl_byte_offset != uint.max && t.offset == decl_byte_offset) {
				Object* edit = build_text_edit(t, new_name);
				edits.push(edit);
				continue;
			}
			if (t.line == enc_line && t.col == enc_col) {
				Object* edit = build_text_edit(t, new_name);
				edits.push(edit);
				continue;
			}
		}

		// Verify per-token binding. Skip tokens that resolve elsewhere
		// (handles shadowing + name collisions).
		if (!definition::token_binds_to_target(target, pr, ti, workspace, store,
				current_uri, target_name, t.offset, is_call)) {
			continue;
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
