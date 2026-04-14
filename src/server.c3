module kls::server;

import std::io;
import std::encoding::json;
import std::collections::object;
import kls::json_rpc;
import kls::document;
import kls::lsp::lifecycle;
import kls::lsp::sync;
import kls::lsp::hover;
import kls::lsp::completion;
import kls::lsp::definition;
import kls::lsp::references;
import kls::lsp::document_highlight;
import kls::lsp::document_symbols;
import kls::lsp::signature_help;
import kls::lsp::semantic_tokens;
import kls::lsp::workspace_symbols;
import kls::workspace;
import kls::deps::classpath;
import kls::deps::jar_index;

struct Server {
	bool is_running;
	bool is_initialized;
	bool is_shutdown;
	DocumentStore documents;
	WorkspaceIndex workspace;
}

fn void Server.init(Server* self) {
	self.is_running = false;
	self.is_initialized = false;
	self.is_shutdown = false;
	self.documents.init();
	self.workspace.init();
}

fn void Server.run(Server* self) {
	self.is_running = true;
	io::eprintfn("[kls] Server ready, waiting for messages on stdin...");

	while (self.is_running) {
		@pool() {
			String raw = json_rpc::read_message()!!;

			Object* msg = json::tparse_string(raw)!!;

			self.dispatch(msg);
		};
	}
}

fn void Server.dispatch(Server* self, Object* msg) {
	String method = msg.get_string("method")!!;

	// Determine if this is a request (has id) or notification (no id)
	int request_id = -1;
	bool is_request = false;
	if (try id_val = msg.get_int("id")) {
		request_id = id_val;
		is_request = true;
	}

	// Check initialization state
	if (!self.is_initialized && method != "initialize" && method != "exit") {
		if (is_request) {
			json_rpc::send_error_response(request_id, json_rpc::SERVER_NOT_INITIALIZED, "Server not initialized");
		}
		return;
	}

	if (self.is_shutdown && method != "exit") {
		if (is_request) {
			json_rpc::send_error_response(request_id, json_rpc::INVALID_REQUEST, "Server is shutting down");
		}
		return;
	}

	Object* params = null;
	if (try p = msg.get("params")) {
		params = p;
	}

	io::eprintfn("[kls] -> %s (id=%d)", method, request_id);

	switch (method) {
		case "initialize":
			Object* result = lifecycle::handle_initialize(params, &self.workspace);
			json_rpc::send_response(request_id, result);
			self.is_initialized = true;

		case "initialized":
			io::eprintfn("[kls] Client initialized");
			self.workspace.scan_workspace();
			classpath::resolve_classpath(&self.workspace.classpath, self.workspace.root_path);
			self.workspace.dep_index.index_classpath(&self.workspace.classpath);

		case "shutdown":
			Object* result = lifecycle::handle_shutdown();
			json_rpc::send_response(request_id, result);
			self.is_shutdown = true;

		case "exit":
			self.is_running = false;

		case "textDocument/didOpen":
			if (params != null) {
				sync::handle_did_open(&self.documents, &self.workspace, params);
			}

		case "textDocument/didChange":
			if (params != null) {
				sync::handle_did_change(&self.documents, &self.workspace, params);
			}

		case "textDocument/didClose":
			if (params != null) {
				sync::handle_did_close(&self.documents, params);
			}

		case "textDocument/hover":
			if (params != null) {
				Object* result = hover::handle_hover(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/signatureHelp":
			if (params != null) {
				Object* result = signature_help::handle_signature_help(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/completion":
			if (params != null) {
				Object* result = completion::handle_completion(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/definition":
			if (params != null) {
				Object* result = definition::handle_definition(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/references":
			if (params != null) {
				Object* result = references::handle_references(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/documentHighlight":
			if (params != null) {
				Object* result = document_highlight::handle_document_highlight(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/documentSymbol":
			if (params != null) {
				Object* result = document_symbols::handle_document_symbol(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/semanticTokens/full":
			if (params != null) {
				Object* result = semantic_tokens::handle_semantic_tokens_full(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "workspace/didChangeWatchedFiles":
			if (params != null) {
				handle_did_change_watched_files(&self.workspace, params);
			}

		case "workspace/symbol":
			if (params != null) {
				Object* result = workspace_symbols::handle_workspace_symbol(&self.workspace, params);
				json_rpc::send_response(request_id, result);
			}

		default:
			io::eprintfn("[kls] Unknown method: %s", method);
			if (is_request) {
				json_rpc::send_error_response(request_id, json_rpc::METHOD_NOT_FOUND, "Method not found");
			}
	}
}

// ── workspace/didChangeWatchedFiles handler ────────────────────────

// FileChangeType constants (LSP spec)
const int FILE_CHANGE_CREATED = 1;
const int FILE_CHANGE_CHANGED = 2;
const int FILE_CHANGE_DELETED = 3;

fn void handle_did_change_watched_files(WorkspaceIndex* workspace, Object* params) {
	Object* changes = params.get("changes") ?? null;
	if (changes == null) return;

	bool build_file_changed = false;

	for (sz i = 0; i < changes.get_len(); i++) {
		Object* event = changes.get_at(i);
		String uri = event.get_string("uri") ?? "";
		int change_type = event.get_int("type") ?? 0;

		if (uri.len == 0) continue;

		// Check if this is a build file change
		if (is_build_file(uri)) {
			build_file_changed = true;
			continue;
		}

		switch (change_type) {
			case FILE_CHANGE_CREATED:
			case FILE_CHANGE_CHANGED:
				// Read file from disk and re-index
				String file_path = workspace::uri_to_path(uri);
				if (try content = workspace::read_file_content(file_path)) {
					workspace.index_file(uri, content);
					mem::free(content.ptr);
					io::eprintfn("[kls] Re-indexed: %s", uri);
				}

			case FILE_CHANGE_DELETED:
				workspace.remove_file(uri);
				io::eprintfn("[kls] Removed from index: %s", uri);

			default:
				break;
		}
	}

	// Re-resolve classpath if any build file changed
	if (build_file_changed) {
		io::eprintfn("[kls] Build file changed, re-resolving classpath...");
		workspace.classpath.free();
		workspace.classpath.init();
		classpath::resolve_classpath(&workspace.classpath, workspace.root_path);
		workspace.dep_index.free();
		workspace.dep_index.init();
		workspace.dep_index.index_classpath(&workspace.classpath);
	}
}

/**
 * Check if a URI refers to a build configuration file.
 */
fn bool is_build_file(String uri) {
	return uri.ends_with("/build.gradle.kts")
		|| uri.ends_with("/build.gradle")
		|| uri.ends_with("/pom.xml");
}
