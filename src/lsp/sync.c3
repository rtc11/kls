module kls::lsp::sync;

import std::io;
import std::collections::object;
import kls::document;
import kls::workspace;
import kls::lsp::diagnostics;

/**
 * Handle textDocument/didOpen notification.
 * Stores the document content in the document store.
 * Also updates the workspace index with the latest symbols.
 */
fn void handle_did_open(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;

	String uri = td.get_string("uri")!!;
	String language_id = td.get_string("languageId")!!;
	int version = td.get_int("version")!!;
	String text = td.get_string("text")!!;

	io::eprintfn("[kls] Document opened: %s (lang=%s, v=%d)", uri, language_id, version);
	store.open(uri, language_id, version, text);
	workspace.index_file(uri, text);
	diagnostics::publish_diagnostics(store, uri, workspace);
}

/**
 * Handle textDocument/didChange notification.
 * Supports both incremental (range-based) and full-content changes.
 * Each contentChanges entry is either:
 *   - Incremental: { range: { start, end }, text: "..." }
 *   - Full:        { text: "..." }  (no range field)
 *
 * When multiple incremental changes arrive, they must be applied in
 * reverse order so that earlier byte offsets remain valid.
 */
fn void handle_did_change(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;

	String uri = td.get_string("uri")!!;
	int version = td.get_int("version")!!;

	Object* changes = params.get("contentChanges")!!;
	// Guard against empty contentChanges array
	sz change_count = changes.get_len();
	if (change_count == 0) return;

	// Apply changes in reverse order for incremental edits.
	// If any change lacks a range, it's a full-content replacement.
	for (sz i = change_count - 1; i >= 0; i--) {
		Object* change = changes.get_at(i);
		String text = change.get_string("text")!!;

		if (try range = change.get("range")) {
			// Incremental change: apply range-based edit
			Object* start = range.get("start")!!;
			Object* end = range.get("end")!!;
			uint start_line = (uint)start.get_int("line")!!;
			uint start_char = (uint)start.get_int("character")!!;
			uint end_line = (uint)end.get_int("line")!!;
			uint end_char = (uint)end.get_int("character")!!;

			// Resolve line/character to byte offsets against current content
			Document* doc = store.get(uri) ?? null;
			if (doc == null) break;

			long s_off = document::position_to_byte_offset(doc.content, start_line, start_char);
			long e_off = document::position_to_byte_offset(doc.content, end_line, end_char);

			// If either position is invalid, clamp to end of content
			uint s = s_off >= 0 ? (uint)s_off : (uint)doc.content.len;
			uint e = e_off >= 0 ? (uint)e_off : (uint)doc.content.len;

			store.apply_change(uri, version, s, e, text);
		} else {
			// Full-content replacement (no range)
			store.update(uri, version, text);
		}
	}

	io::eprintfn("[kls] Document changed: %s (v=%d)", uri, version);
	Document* doc = store.get(uri) ?? null;
	if (doc != null) {
		workspace.index_file(uri, doc.content);
	}
	diagnostics::publish_diagnostics(store, uri, workspace);
}

/**
 * Handle textDocument/didClose notification.
 * Removes the document from the store.
 * Note: We do NOT remove from workspace index -- the file still exists on disk.
 * The workspace index retains the last-known symbols for cross-file features.
 */
fn void handle_did_close(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	io::eprintfn("[kls] Document closed: %s", uri);
	store.close(uri);
	// Publish empty diagnostics after closing (doc is gone, so content=""
	// and no AST, producing an empty diagnostics array to clear client-side)
	diagnostics::publish_diagnostics(store, uri);
}
