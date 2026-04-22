module kls::lsp::sync;

import std::io;
import std::collections::object;
import kls::document;
import kls::workspace;
import kls::lsp::diagnostics;
import kls::log;

/**
 * Handle textDocument/didOpen notification.
 * Stores the document content in the document store.
 * Also updates the workspace index with the latest symbols.
 */
fn void? handle_did_open(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;

	String uri = td.get_string("uri")!;
	String language_id = td.get_string("languageId")!;
	int version = td.get_int("version")!;
	String text = td.get_string("text")!;

	log::debug("[kls] Document opened: %s (lang=%s, v=%d)", uri, language_id, version);
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
 * Per LSP 3.17 spec: changes apply in array order, each referring to the
 * document state AFTER all prior changes in the same notification have
 * been applied. We resolve each range's positions against the current
 * (mutated) doc.content right before applying it.
 */
fn void? handle_did_change(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;

	String uri = td.get_string("uri")!;
	int version = td.get_int("version")!;

	Object* changes = params.get("contentChanges")!;
	// Guard against empty contentChanges array
	sz change_count = changes.get_len();
	if (change_count == 0) return;

	// Apply changes in array order (LSP spec: each refers to state after prior).
	// If any change lacks a range, it's a full-content replacement.
	for (sz i = 0; i < change_count; i++) {
		Object* change = changes.get_at(i);
		String text = change.get_string("text")!;

		if (try range = change.get("range")) {
			// Incremental change: apply range-based edit
			Object* start = range.get("start")!;
			Object* end = range.get("end")!;
			uint start_line = (uint)start.get_int("line")!;
			uint start_char = (uint)start.get_int("character")!;
			uint end_line = (uint)end.get_int("line")!;
			uint end_char = (uint)end.get_int("character")!;

			// Resolve line/character to byte offsets against current content
			Document* doc = store.get(uri) ?? null;
			if (doc == null) break;

			long s_off = document::position_to_byte_offset(doc.content, start_line, start_char);
			long e_off = document::position_to_byte_offset(doc.content, end_line, end_char);

			// position_to_byte_offset clamps per LSP spec, but be defensive
			uint s = s_off >= 0 ? (uint)s_off : (uint)doc.content.len;
			uint e = e_off >= 0 ? (uint)e_off : (uint)doc.content.len;
			if (e < s) e = s;

			log::debug("[didChange] v=%d range=(%d,%d)..(%d,%d) bytes=%d..%d text_len=%d",
				version, start_line, start_char, end_line, end_char, s, e, text.len);

			store.apply_change(uri, version, s, e, text);
		} else {
			log::debug("[didChange] v=%d FULL text_len=%d", version, text.len);
			// Full-content replacement (no range)
			store.update(uri, version, text);
		}
	}

	log::debug("[kls] Document changed: %s (v=%d)", uri, version);
	Document* doc = store.get(uri) ?? null;
	if (doc != null) {
		log::debug("[didChange] resulting content len=%d", doc.content.len);
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
fn void? handle_did_close(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	log::debug("[kls] Document closed: %s", uri);
	store.close(uri);
	// Publish empty diagnostics after closing (doc is gone, so content=""
	// and no AST, producing an empty diagnostics array to clear client-side)
	diagnostics::publish_diagnostics(store, uri);
}

/**
 * Handle textDocument/didSave notification.
 * Re-publishes diagnostics and refreshes the workspace index for the saved file.
 */
fn void? handle_did_save(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	log::debug("[kls] Document saved: %s", uri);

	// Re-index and re-publish diagnostics on save
	if (try doc = store.get(uri)) {
		workspace.index_file(uri, doc.content);
		diagnostics::publish_diagnostics(store, uri, workspace);
	}
}
