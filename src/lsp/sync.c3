module kls::lsp::sync;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::diagnostics;

/**
 * Handle textDocument/didOpen notification.
 * Stores the document content in the document store.
 */
fn void handle_did_open(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;

	String uri = td.get_string("uri")!!;
	String language_id = td.get_string("languageId")!!;
	int version = td.get_int("version")!!;
	String text = td.get_string("text")!!;

	io::eprintfn("[kls] Document opened: %s (lang=%s, v=%d)", uri, language_id, version);
	store.open(uri, language_id, version, text);
	diagnostics::publish_diagnostics(store, uri);
}

/**
 * Handle textDocument/didChange notification.
 * Updates the document content (full sync mode).
 */
fn void handle_did_change(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;

	String uri = td.get_string("uri")!!;
	int version = td.get_int("version")!!;

	// Full sync: take the first content change
	Object* changes = params.get("contentChanges")!!;
	Object* change = changes.get_at(0);
	String text = change.get_string("text")!!;

	io::eprintfn("[kls] Document changed: %s (v=%d, len=%d)", uri, version, text.len);
	store.update(uri, version, text);
	diagnostics::publish_diagnostics(store, uri);
}

/**
 * Handle textDocument/didClose notification.
 * Removes the document from the store.
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
