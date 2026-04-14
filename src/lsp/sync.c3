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
	diagnostics::publish_diagnostics(store, uri);
}

/**
 * Handle textDocument/didChange notification.
 * Updates the document content (full sync mode).
 * Also updates the workspace index with the latest symbols.
 */
fn void handle_did_change(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;

	String uri = td.get_string("uri")!!;
	int version = td.get_int("version")!!;

	// Full sync: take the first content change
	Object* changes = params.get("contentChanges")!!;
	// #12: Guard against empty contentChanges array
	if (changes.get_len() == 0) return;
	Object* change = changes.get_at(0);
	String text = change.get_string("text")!!;

	io::eprintfn("[kls] Document changed: %s (v=%d, len=%d)", uri, version, text.len);
	store.update(uri, version, text);
	workspace.index_file(uri, text);
	diagnostics::publish_diagnostics(store, uri);
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
