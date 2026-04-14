module kls::lsp::code_actions;

import std::collections::object;
import kls::document;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::lsp::hover;
import kls::workspace;

faultdef NO_RECEIVER;

/**
 * Handle textDocument/codeAction request.
 *
 * Examines the diagnostics provided in the request context and returns
 * applicable code actions (quick fixes and source actions).
 *
 * Supported actions:
 *   - "Remove unused import" (quickfix) for each unused import diagnostic
 *   - "Remove all unused imports" (source.organizeImports) computed from full document
 *   - "Replace '&' with '&&'" / "'|' with '||'" (quickfix) for operator errors
 *   - "Insert missing '<delim>'" (quickfix) for Expected ')', '}', '>' errors
 *   - "Import <pkg>.<name>" (quickfix) for unresolved references
 */
fn Object* handle_code_action(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* context = params.get("context")!!;
	Object* client_diagnostics = context.get("diagnostics")!!;

	// Check if the client is filtering by kind
	String[8] only_kinds;
	usz only_count = 0;
	if (try only = context.get("only")) {
		if (only.is_array()) {
			for (sz i = 0; i < only.get_len() && only_count < 8; i++) {
				if (try kind_str = only.get_string_at(i)) {
					only_kinds[only_count] = kind_str;
					only_count++;
				}
			}
		}
	}

	Document* doc = store.get(uri) ?? null;

	Object* actions = object::new_obj(tmem); // JSON array

	ParseResult* ast = store.get_ast(uri) ?? null;

	// ── Process each diagnostic from the client context ──────────
	for (sz i = 0; i < client_diagnostics.get_len(); i++) {
		Object* diag = client_diagnostics.get_at(i);
		String message = diag.get_string("message") ?? "";

		// Quick fix: remove this one unused import
		if (message.starts_with("Unused import:") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_unused_import(uri, doc, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: replace & with && or | with ||
		if (message.starts_with("Unexpected character:") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_fix_operator(uri, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: insert missing delimiter
		if (message.starts_with("Expected '") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_insert_delimiter(uri, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: add missing import for unresolved reference
		if (message.starts_with("Unresolved reference: '") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			add_import_actions_for_diagnostic(actions, uri, doc, ast, workspace, diag, message);
		}
	}

	// ── Source action: remove ALL unused imports (computed server-side) ──
	// Don't rely on client-provided diagnostics for this — compute from
	// the full document so it works regardless of cursor position.
	if (doc != null && is_kind_wanted("source.organizeImports", only_kinds[:only_count])) {
		Object* all_diags = diagnostics::build_diagnostics_array(doc.content, ast);

		Object*[128] all_unused;
		usz all_unused_count = 0;
		if (all_diags.is_array()) {
			for (sz j = 0; j < all_diags.get_len() && all_unused_count < 128; j++) {
				Object* d = all_diags.get_at(j);
				String msg = d.get_string("message") ?? "";
				if (msg.starts_with("Unused import:")) {
					all_unused[all_unused_count] = d;
					all_unused_count++;
				}
			}
		}

		if (all_unused_count >= 1) {
			Object* action = build_organize_imports_action(uri, all_unused[:all_unused_count]);
			if (action != null) {
				actions.push(action);
			}
		}
	}

	// ── Cursor-context: add import for identifier under cursor ───
	// Independent of diagnostics — works even if the client didn't
	// send an "Unresolved reference" diagnostic for this position.
	if (doc != null && workspace != null && ast != null
		&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
		add_import_actions_at_cursor(actions, uri, doc, ast, workspace, params);
	}

	return actions;
}

// ── Quick fix: remove a single unused import ──────────────────────

/**
 * Build a "Remove unused import" code action for a single unused-import
 * diagnostic. Deletes the entire import line (from line start through
 * the next line start, consuming the trailing newline).
 */
fn Object* try_remove_unused_import(String uri, Document* doc, Object* diag) {
	if (doc == null) return null;

	Object* range = diag.get("range")!!;
	int start_line = range.get("start")!!.get_int("line")!!;
	int end_line = range.get("end")!!.get_int("line")!!;

	// Build a range that covers the full line(s) of the import, including newline
	Object* delete_range = build_line_delete_range(start_line, end_line);

	Object* edit = object::new_obj(tmem);
	edit.set("range", delete_range);
	edit.set("newText", "");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	// Build the code action
	Object* action = object::new_obj(tmem);
	action.set("title", "Remove unused import");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	// Link to the diagnostic
	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Source action: remove all unused imports ──────────────────────

/**
 * Build an "Organize imports: remove all unused" action that deletes
 * all unused import lines in one edit operation.
 */
fn Object* build_organize_imports_action(String uri, Object*[] diags) {
	if (diags.len == 0) return null;

	Object* edits = object::new_obj(tmem);

	for (usz i = 0; i < diags.len; i++) {
		Object* range = diags[i].get("range")!!;
		int start_line = range.get("start")!!.get_int("line")!!;
		int end_line = range.get("end")!!.get_int("line")!!;

		Object* delete_range = build_line_delete_range(start_line, end_line);

		Object* edit = object::new_obj(tmem);
		edit.set("range", delete_range);
		edit.set("newText", "");
		edits.push(edit);
	}

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove all unused imports");
	action.set("kind", "source.organizeImports");
	action.set("edit", workspace_edit);

	// Link all diagnostics
	Object* action_diags = object::new_obj(tmem);
	for (usz i = 0; i < diags.len; i++) {
		action_diags.push(diags[i]);
	}
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quick fix: replace & with && or | with || ────────────────────

/**
 * If the diagnostic message indicates a lone '&' or '|', offer to
 * replace it with '&&' or '||' respectively.
 */
fn Object* try_fix_operator(String uri, Object* diag, String message) {
	// Messages look like: "Unexpected character: '&'" or "Unexpected character: '|'"
	String replacement;
	String title;

	if (message.contains("'&'")) {
		replacement = "&&";
		title = "Replace '&' with '&&'";
	} else if (message.contains("'|'")) {
		replacement = "||";
		title = "Replace '|' with '||'";
	} else {
		return null;
	}

	Object* range = diag.get("range")!!;

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", replacement);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", title);
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quick fix: insert missing delimiter ──────────────────────────

/**
 * If the diagnostic message matches "Expected ')', got ..." (or '}', '>'),
 * offer to insert the missing delimiter at the diagnostic position.
 */
fn Object* try_insert_delimiter(String uri, Object* diag, String message) {
	// Parse the expected token from "Expected '<tok>', got '<actual>'"
	String delimiter = extract_expected_token(message);
	if (delimiter.len == 0) return null;

	// Only offer insertion for closing delimiters
	if (delimiter != ")" && delimiter != "}" && delimiter != ">") return null;

	Object* range = diag.get("range")!!;
	Object* start = range.get("start")!!;

	// Build an insert range (zero-width at the start of the diagnostic)
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", start.get_int("line")!!);
	insert_start.set("character", start.get_int("character")!!);

	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", start.get_int("line")!!);
	insert_end.set("character", start.get_int("character")!!);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", delimiter);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	DString title;
	title.tinit();
	title.appendf("Insert missing '%s'", delimiter);

	Object* action = object::new_obj(tmem);
	action.set("title", title.str_view());
	action.set("kind", "quickfix");
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Build a Range that covers from the start of start_line to the start
 * of (end_line + 1), effectively deleting the entire line(s) including
 * the trailing newline.
 */
fn Object* build_line_delete_range(int start_line, int end_line) {
	Object* start = object::new_obj(tmem);
	start.set("line", start_line);
	start.set("character", 0);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", end_line + 1);
	end_pos.set("character", 0);

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	return range;
}

/**
 * Extract the expected token from a parser error message.
 * Messages have the form: "Expected '<tok>', got '<actual>'"
 * Returns the token string (e.g., ")", "}", ">") or "" if not found.
 */
fn String extract_expected_token(String message) {
	// Find "Expected '" and extract up to the next "'"
	String prefix = "Expected '";
	if (!message.starts_with(prefix)) return "";

	String rest = message[prefix.len..];
	// Find the closing single quote
	for (usz i = 0; i < rest.len; i++) {
		if (rest[i] == '\'') {
			return rest[:i];
		}
	}
	return "";
}

/**
 * Check if a given code action kind is wanted based on the client's
 * "only" filter. If no filter is set (empty slice), all kinds are wanted.
 * Uses prefix matching per LSP spec (e.g., "source" matches
 * "source.organizeImports").
 */
fn bool is_kind_wanted(String kind, String[] only_kinds) {
	if (only_kinds.len == 0) return true; // no filter = all wanted

	for (usz i = 0; i < only_kinds.len; i++) {
		String filter = only_kinds[i];
		// Exact match
		if (kind == filter) return true;
		// Filter is a prefix of kind: "source" matches "source.organizeImports"
		if (kind.len > filter.len && kind.starts_with(filter) && kind[filter.len] == '.') return true;
		// Kind is a prefix of filter: kind "quickfix" matches filter "quickfix.import"
		if (filter.len > kind.len && filter.starts_with(kind) && filter[kind.len] == '.') return true;
	}
	return false;
}

// ── Import action helpers ────────────────────────────────────────

/**
 * Find the line where a new import should be inserted.
 * Returns the line number where the import text should be placed.
 * If there are existing imports, inserts after the last import line.
 * If no imports exist but there's a package declaration, inserts after
 * the package line + 1 blank line.
 * Otherwise inserts at line 0.
 *
 * `needs_newline_before` is set to true when a blank line should be
 * inserted before the import (e.g. after a package declaration with
 * no existing imports).
 */
fn uint find_import_insertion_line(ParseResult* ast, bool* needs_newline_before) {
	*needs_newline_before = false;

	// Find the last IMPORT_DECL's end_line at FILE level
	bool found_import = false;
	uint last_import_end_line = 0;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.parent != 0) continue;
		found_import = true;
		if (n.end_line >= last_import_end_line) {
			last_import_end_line = n.end_line;
		}
	}

	if (found_import) {
		return last_import_end_line + 1; // line after last import
	}

	// No imports -- look for PACKAGE_DECL
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind == PACKAGE_DECL && n.parent == 0) {
			*needs_newline_before = true;
			return n.end_line + 1; // line after package declaration
		}
	}

	// No package, no imports: insert at line 0
	return 0;
}

/**
 * Check if an import for the given path already exists in the AST.
 * Returns true if there's an IMPORT_DECL with the exact path, or a
 * wildcard import covering the package.
 */
fn bool is_already_imported(ParseResult* ast, String import_path, String package_name) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.parent != 0) continue;

		String path = n.extra_text;
		// Exact match
		if (path == import_path) return true;

		// Wildcard match: import foo.bar.* covers foo.bar.Baz
		if (path.len >= 2 && path[path.len - 1] == '*' && path[path.len - 2] == '.') {
			String pkg_prefix = path[:path.len - 2];
			if (pkg_prefix == package_name) return true;
		}
	}
	return false;
}

/**
 * Build a code action that inserts `import <import_path>` at the
 * appropriate position in the file.
 */
fn Object* build_import_action(String uri, ParseResult* ast, String import_path, Object* diag) {
	bool needs_newline_before = false;
	uint insert_line = find_import_insertion_line(ast, &needs_newline_before);

	// Build the import text to insert
	DString import_text;
	import_text.tinit();
	if (needs_newline_before) {
		import_text.append("\n");
	}
	import_text.appendf("import %s\n", import_path);

	// Build zero-width insert range at the start of the insertion line
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", (int)insert_line);
	insert_start.set("character", 0);

	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", (int)insert_line);
	insert_end.set("character", 0);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", import_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	DString title;
	title.tinit();
	title.appendf("Import '%s'", import_path);

	Object* action = object::new_obj(tmem);
	action.set("title", title.str_view());
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	// Link to the diagnostic if provided
	if (diag != null) {
		Object* action_diags = object::new_obj(tmem);
		action_diags.push(diag);
		action.set("diagnostics", action_diags);
	}

	return action;
}

/**
 * Extract the identifier name from an "Unresolved reference: '<name>'" message.
 */
fn String extract_unresolved_name(String message) {
	String prefix = "Unresolved reference: '";
	if (!message.starts_with(prefix)) return "";
	String rest = message[prefix.len..];
	for (usz i = 0; i < rest.len; i++) {
		if (rest[i] == '\'') {
			return rest[:i];
		}
	}
	return "";
}

/**
 * Add "Import '<pkg>.<name>'" code actions for an unresolved reference diagnostic.
 */
fn void add_import_actions_for_diagnostic(Object* actions, String uri, Document* doc,
	ParseResult* ast, WorkspaceIndex* workspace, Object* diag, String message) {
	if (workspace == null || ast == null) return;

	String name = extract_unresolved_name(message);
	if (name.len == 0) return;

	String[16] import_paths;
	String[16] packages;
	usz count = diagnostics::find_import_candidates(name, workspace, &import_paths, &packages);

	for (usz i = 0; i < count; i++) {
		if (is_already_imported(ast, import_paths[i], packages[i])) continue;
		Object* action = build_import_action(uri, ast, import_paths[i], diag);
		if (action != null) {
			actions.push(action);
		}
	}
}

/**
 * When the cursor is on a dot member (e.g. `randomUUID` in `UUID.randomUUID()`),
 * walk backward in the source to find the receiver identifier before the `.` or `?.`.
 * Returns the receiver name, or a fault if the token is not a dot member.
 */
fn String? find_dot_receiver(String content, Token tok) {
	if (tok.offset == 0) return NO_RECEIVER~;
	usz pos = (usz)tok.offset;

	// Walk backward over whitespace before the current token
	while (pos > 0 && (content[pos - 1] == ' ' || content[pos - 1] == '\t'
			|| content[pos - 1] == '\n' || content[pos - 1] == '\r')) {
		pos--;
	}

	// Check for '.' or '?.' (safe call)
	if (pos == 0) return NO_RECEIVER~;
	if (content[pos - 1] == '.') {
		pos--;
		// Check for '?.' (safe call) — skip the '?' too
		if (pos > 0 && content[pos - 1] == '?') {
			pos--;
		}
	} else {
		return NO_RECEIVER~;
	}

	// Walk backward over whitespace before the dot
	while (pos > 0 && (content[pos - 1] == ' ' || content[pos - 1] == '\t'
			|| content[pos - 1] == '\n' || content[pos - 1] == '\r')) {
		pos--;
	}

	// The receiver should end here — find the start of the identifier
	if (pos == 0) return NO_RECEIVER~;
	usz end = pos;

	// Walk backward over identifier chars ([a-zA-Z0-9_])
	while (pos > 0) {
		char c = content[pos - 1];
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
				|| (c >= '0' && c <= '9') || c == '_') {
			pos--;
		} else {
			break;
		}
	}

	if (pos == end) return NO_RECEIVER~;  // no identifier chars found

	// Verify the first char is not a digit (valid identifier start)
	char first = content[pos];
	if (first >= '0' && first <= '9') return NO_RECEIVER~;

	return content[pos..end - 1];
}

/**
 * Offer import actions for a given identifier name. Shared logic between
 * the direct-token path and the dot-receiver fallback path.
 */
fn void offer_import_actions(Object* actions, String uri, ParseResult* ast,
	WorkspaceIndex* workspace, String name, uint offset) {
	// Skip if already imported or locally declared
	if (diagnostics::is_name_in_scope(ast, name, offset)) return;
	if (diagnostics::is_auto_imported(name)) return;

	// Look up candidates
	String[16] import_paths;
	String[16] packages;
	usz count = diagnostics::find_import_candidates(name, workspace, &import_paths, &packages);

	for (usz i = 0; i < count; i++) {
		if (is_already_imported(ast, import_paths[i], packages[i])) continue;

		// Check we haven't already added an action for this import path
		// (from the diagnostic-driven path)
		bool already_offered = false;
		for (sz j = 0; j < actions.get_len(); j++) {
			String title = actions.get_at(j).get_string("title") ?? "";
			DString expected_title;
			expected_title.tinit();
			expected_title.appendf("Import '%s'", import_paths[i]);
			if (title == expected_title.str_view()) {
				already_offered = true;
				break;
			}
		}
		if (already_offered) continue;

		Object* action = build_import_action(uri, ast, import_paths[i], null);
		if (action != null) {
			actions.push(action);
		}
	}
}

/**
 * Add "Import '<pkg>.<name>'" code actions based on the cursor position,
 * independent of diagnostics. Inspects the token at the cursor and offers
 * import suggestions if it's an unresolved identifier.
 *
 * When the cursor is on a dot member (e.g. `randomUUID` in `UUID.randomUUID()`),
 * walks back to the receiver (`UUID`) and offers its import instead.
 */
fn void add_import_actions_at_cursor(Object* actions, String uri, Document* doc,
	ParseResult* ast, WorkspaceIndex* workspace, Object* params) {
	// Get cursor position from the request range
	Object* range = params.get("range") ?? null;
	if (range == null) return;
	Object* start = range.get("start") ?? null;
	if (start == null) return;
	uint line = (uint)(start.get_int("line") ?? 0);
	uint character = (uint)(start.get_int("character") ?? 0);

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return;
	}

	if (tok.kind != IDENTIFIER) return;

	String name = tok.text;
	uint offset = tok.offset;

	// Track how many actions existed before we start
	sz count_before = actions.get_len();

	// Try direct token first
	offer_import_actions(actions, uri, ast, workspace, name, offset);

	// If no import actions were added and the token is a dot member, try the receiver
	if (actions.get_len() == count_before) {
		if (try receiver = find_dot_receiver(doc.content, tok)) {
			offer_import_actions(actions, uri, ast, workspace, receiver, offset);
		}
	}
}
