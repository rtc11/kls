module kls::server;

import std::io;
import std::encoding::json;
import std::collections::object;
import std::thread;
import std::net;
import kls::log;
import kls::json_rpc;
import kls::document;
import kls::lsp::lifecycle;
import kls::lsp::sync;
import kls::lsp::hover;
import kls::lsp::completion;
import kls::lsp::definition;
import kls::lsp::declaration;
import kls::lsp::references;
import kls::lsp::document_highlight;
import kls::lsp::linked_editing_range;
import kls::lsp::document_link;
import kls::lsp::document_symbols;
import kls::lsp::signature_help;
import kls::lsp::semantic_tokens;
import kls::lsp::workspace_symbols;
import kls::lsp::rename;
import kls::lsp::type_definition;
import kls::lsp::implementation;
import kls::lsp::folding_range;
import kls::lsp::selection_range;
import kls::lsp::formatting;
import kls::lsp::code_actions;
import kls::lsp::code_lens;
import kls::lsp::inlay_hints;
import kls::lsp::call_hierarchy;
import kls::lsp::type_hierarchy;
import kls::lsp::execute_command;
import kls::lsp::diagnostics;
import kls::lsp::progress;
import kls::workspace;
import kls::config;
import kls::debug_socket;
import kls::deps::classpath;
import kls::deps::jar_index;
import kls::deps::jdk_index;
import kls::deps::kotlin_fallback;
import kls::kotlin::types;

// ── Async reindex state ────────────────────────────────────────────

struct ReindexState {
	Mutex mu;
	bool pending;           // build file change detected, debounce timer running
	bool in_progress;       // background thread is working
	bool complete;          // background thread finished, results ready to swap
	bool cancel;            // signal background thread to restart debounce
	Classpath* new_classpath;
	DependencyIndex* new_dep_index;
	String root_path;       // copy for background thread
	Classpath* old_classpath;  // for incremental diff
	DependencyIndex* old_dep_index;  // for incremental copy
}

const int REINDEX_DEBOUNCE_MS = 2000;

struct Server {
	bool is_running;
	bool is_initialized;
	bool is_shutdown;
	DocumentStore documents;
	WorkspaceIndex workspace;
	ReindexState reindex;
	DebugServer debug_server;
}

fn void Server.init(Server* self) {
	self.is_running = false;
	self.is_initialized = false;
	self.is_shutdown = false;
	self.documents.init();
	self.workspace.init();
	if (catch excuse = self.reindex.mu.init()) {
		log::err("[kls] Failed to init reindex mutex: %s", excuse);
	}
	self.reindex.pending = false;
	self.reindex.in_progress = false;
	self.reindex.complete = false;
	self.reindex.cancel = false;
	self.reindex.new_classpath = null;
	self.reindex.new_dep_index = null;
	self.reindex.old_classpath = null;
	self.reindex.old_dep_index = null;
	self.reindex.root_path = "";
}

fn void Server.run(Server* self) {
	self.is_running = true;
	log::info("[kls] Server ready, waiting for messages on stdin...");

	while (self.is_running) {
		@pool() {
			if (self.debug_server.active) {
				self.poll_loop_iteration();
			} else {
				// Before debug server: blocking stdin (pre-initialize)
				if (catch excuse = self.run_one_message()) {
					if (excuse == json_rpc::UNEXPECTED_EOF) {
						log::info("[kls] stdin closed, shutting down");
						self.is_running = false;
					} else {
						log::err("[kls] Error processing message: %s", excuse);
					}
				}
			}

			// Check if async reindex completed
			self.check_reindex_complete();
		};
	}

	// Cleanup debug server
	self.debug_server.stop();
}

/**
 * Poll stdin + debug socket with 50ms timeout.
 * Handles LSP messages from neovim and debug queries from external tools.
 */
fn void Server.poll_loop_iteration(Server* self) {
	NativeSocket stdin_sock = (NativeSocket)io::stdin().fd();
	NativeSocket debug_sock = self.debug_server.native_socket();

	Poll[2] polls;
	polls[0].socket = stdin_sock;
	polls[0].events = net::SUBSCRIBE_ANY_READ;
	polls[0].revents = (PollEvent)0;
	polls[1].socket = debug_sock;
	polls[1].events = net::SUBSCRIBE_ANY_READ;
	polls[1].revents = (PollEvent)0;

	ulong ready = net::poll_ms(polls[..], 50) ?? 0;

	// Check stdin for LSP messages
	if (ready > 0 && ((ushort)polls[0].revents & (ushort)net::SUBSCRIBE_ANY_READ) != 0) {
		if (catch excuse = self.run_one_message()) {
			if (excuse == json_rpc::UNEXPECTED_EOF) {
				log::info("[kls] stdin closed, shutting down");
				self.is_running = false;
				return;
			} else {
				log::err("[kls] Error processing message: %s", excuse);
			}
		}
	}

	// Check debug socket for incoming connections
	if (ready > 0 && ((ushort)polls[1].revents & (ushort)net::SUBSCRIBE_ANY_READ) != 0) {
		self.debug_server.accept_and_handle(&self.documents, &self.workspace);
	}
}

fn void? Server.run_one_message(Server* self) {
	String raw = json_rpc::read_message()!;

	Object* msg;
	if (try m = json::tparse_string(raw)) {
		msg = m;
	} else {
		log::err("[kls] JSON parse error");
		json_rpc::send_error_response(null, json_rpc::PARSE_ERROR, "Parse error");
		return;
	}

	self.dispatch(msg);
}

// Stamp DocumentStore.last_cursor_* whenever a request arrives that carries
// a cursor position in its params. Called from `dispatch` once per message;
// keeps every individual handler free of bookkeeping.
fn void record_cursor_from_params(DocumentStore* store, String method, Object* params) {
	switch (method) {
		case "textDocument/hover":
		case "textDocument/completion":
		case "textDocument/signatureHelp":
		case "textDocument/definition":
		case "textDocument/declaration":
		case "textDocument/typeDefinition":
		case "textDocument/implementation":
		case "textDocument/references":
		case "textDocument/documentHighlight":
		case "textDocument/prepareRename":
		case "textDocument/rename":
		case "textDocument/prepareCallHierarchy":
		case "textDocument/prepareTypeHierarchy":
		case "textDocument/selectionRange":
		case "textDocument/linkedEditingRange":
			break;
		default:
			return;
	}
	Object* td = params.get("textDocument") ?? null;
	if (td == null) return;
	String uri = td.get_string("uri") ?? "";
	if (uri.len == 0) return;
	Object* pos = params.get("position") ?? null;
	if (pos == null) return;
	int line = pos.get_int("line") ?? -1;
	int character = pos.get_int("character") ?? -1;
	store.record_cursor(uri, line, character);
}

fn void Server.dispatch(Server* self, Object* msg) {
	// #2: Gracefully handle missing "method" field (e.g., JSON-RPC responses)
	String method = msg.get_string("method") ?? "";
	if (method.len == 0) {
		log::debug("[kls] Ignoring message without method field");
		return;
	}

	// #4: Support both integer and string JSON-RPC IDs
	Object* request_id = null;
	bool is_request = false;
	if (try id_obj = msg.get("id")) {
		// id can be int, string, or null per JSON-RPC 2.0
		if (!id_obj.is_null()) {
			request_id = id_obj;
			is_request = true;
		}
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

	log::debug("[kls] -> %s", method);

	if (params != null) record_cursor_from_params(&self.documents, method, params);

	switch (method) {
		case "initialize":
			Object* result = lifecycle::handle_initialize(params, &self.workspace);
			json_rpc::send_response(request_id, result);
			self.is_initialized = true;

		case "initialized":
			log::info("[kls] Client initialized");
			progress::create("kls-indexing");
			progress::begin("kls-indexing", "Kotlin Language Server", 0);

			// Resolve classpath first so module source roots are available
			// for scan_workspace() to use and for index_file() to assign module_name
			progress::report("kls-indexing", "Resolving classpath...", 20);
			classpath::resolve_classpath(&self.workspace.classpath, self.workspace.root_path, "kls-indexing");

			progress::report("kls-indexing", "Scanning workspace...", 40);
			self.workspace.scan_workspace();

			progress::report("kls-indexing", "Indexing dependencies...", 60);
			self.workspace.dep_index.index_classpath(&self.workspace.classpath, "kls-indexing", 60, 80);

			progress::report("kls-indexing", "Indexing JDK...", 80);
			jdk_index::index_jdk(&self.workspace.dep_index, "kls-indexing", 80, 90);

			// Fallback: if no build system resolved any JARs, try system Kotlin stdlib
			if (self.workspace.classpath.jar_count == 0) {
				progress::report("kls-indexing", "Indexing Kotlin stdlib...", 90);
				kotlin_fallback::index_system_kotlin(&self.workspace.dep_index);
			}

			progress::end("kls-indexing", "Ready");

			// Wire workspace into document store for cross-file type resolution
			self.documents.workspace = &self.workspace;

			// Start debug TCP server for external index queries
			self.debug_server.start(self.workspace.root_path);

		case "shutdown":
			Object* result = lifecycle::handle_shutdown();
			json_rpc::send_response(request_id, result);
			self.is_shutdown = true;
			self.debug_server.stop();

		case "exit":
			self.is_running = false;

		case "textDocument/didOpen":
			if (params != null) {
				if (catch excuse = sync::handle_did_open(&self.documents, &self.workspace, params)) {
					log::err("[kls] didOpen failed: %s", excuse);
				}
			}

		case "textDocument/didChange":
			if (params != null) {
				if (catch excuse = sync::handle_did_change(&self.documents, &self.workspace, params)) {
					log::err("[kls] didChange failed: %s", excuse);
				}
			}

		case "textDocument/didClose":
			if (params != null) {
				if (catch excuse = sync::handle_did_close(&self.documents, params)) {
					log::err("[kls] didClose failed: %s", excuse);
				}
			}

		// All request handlers: catch faults from malformed params, return error response
		case "textDocument/hover":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = hover::handle_hover(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/signatureHelp":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = signature_help::handle_signature_help(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/completion":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = completion::handle_completion(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "completionItem/resolve":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = completion::handle_completion_resolve(&self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/definition":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = definition::handle_definition(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/declaration":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = declaration::handle_declaration(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/typeDefinition":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = type_definition::handle_type_definition(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/implementation":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = implementation::handle_implementation(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/references":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = references::handle_references(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/documentHighlight":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = document_highlight::handle_document_highlight(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/linkedEditingRange":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = linked_editing_range::handle_linked_editing_range(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/documentLink":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = document_link::handle_document_link(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/documentSymbol":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = document_symbols::handle_document_symbol(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/foldingRange":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = folding_range::handle_folding_range(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/selectionRange":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = selection_range::handle_selection_range(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/formatting":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = formatting::handle_formatting(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/rangeFormatting":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = formatting::handle_range_formatting(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/onTypeFormatting":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = formatting::handle_on_type_formatting(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/codeAction":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = code_actions::handle_code_action(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "codeAction/resolve":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = code_actions::handle_code_action_resolve(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/codeLens":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = code_lens::handle_code_lens(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "codeLens/resolve":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = code_lens::handle_code_lens_resolve(params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/semanticTokens/full":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = semantic_tokens::handle_semantic_tokens_full(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/semanticTokens/full/delta":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = semantic_tokens::handle_semantic_tokens_delta(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/semanticTokens/range":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = semantic_tokens::handle_semantic_tokens_range(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/inlayHint":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = inlay_hints::handle_inlay_hints(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "inlayHint/resolve":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = inlay_hints::handle_inlay_hint_resolve(params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/prepareRename":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = rename::handle_prepare_rename(&self.documents, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/rename":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = rename::handle_rename(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/prepareCallHierarchy":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = call_hierarchy::handle_prepare(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "callHierarchy/incomingCalls":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = call_hierarchy::handle_incoming_calls(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "callHierarchy/outgoingCalls":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = call_hierarchy::handle_outgoing_calls(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "textDocument/prepareTypeHierarchy":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = type_hierarchy::handle_prepare(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "typeHierarchy/supertypes":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = type_hierarchy::handle_supertypes(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "typeHierarchy/subtypes":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = type_hierarchy::handle_subtypes(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "workspace/didChangeWatchedFiles":
			if (params != null) {
				handle_did_change_watched_files(self, params);
			}

		case "workspace/symbol":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = workspace_symbols::handle_workspace_symbol(&self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "workspace/executeCommand":
			if (params == null) {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			} else if (try result = execute_command::handle_execute_command(&self.documents, &self.workspace, params)) {
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Invalid params");
			}

		case "$/cancelRequest":
			// Silently ignore — we don't support cancellation yet but must not error
			log::debug("[kls] Cancel request received (ignored)");

		case "textDocument/didSave":
			if (params != null) {
				if (catch excuse = sync::handle_did_save(&self.documents, &self.workspace, params)) {
					log::err("[kls] didSave failed: %s", excuse);
				}
			}

		case "workspace/didChangeConfiguration":
			if (params != null) {
				config::apply_settings(params);
			}

		default:
			log::debug("[kls] Unknown method: %s", method);
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

fn void handle_did_change_watched_files(Server* server, Object* params) {
	Object* changes = params.get("changes") ?? null;
	if (changes == null) return;

	WorkspaceIndex* workspace = &server.workspace;
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
					log::debug("[kls] Re-indexed: %s", uri);
				}

			case FILE_CHANGE_DELETED:
				workspace.remove_file(uri);
				log::debug("[kls] Removed from index: %s", uri);

			default:
				break;
		}
	}

	// Schedule async reindex if any build file changed
	if (build_file_changed) {
		schedule_reindex(server);
	}
}

// ── Async reindex with debounce ────────────────────────────────────

fn void schedule_reindex(Server* server) {
	server.reindex.mu.lock();
	defer server.reindex.mu.unlock();

	if (server.reindex.in_progress) {
		// Already reindexing — signal restart (debounce reset)
		server.reindex.cancel = true;
		log::info("[kls] Build file changed again, will restart reindex after current debounce");
		return;
	}

	if (server.reindex.pending) {
		// Debounce thread already sleeping — signal it to restart timer
		server.reindex.cancel = true;
		log::info("[kls] Build file changed again, resetting debounce timer");
		return;
	}

	server.reindex.pending = true;
	server.reindex.cancel = false;
	server.reindex.root_path = server.workspace.root_path;

	// Spawn debounce + reindex thread
	Thread thr;
	if (catch excuse = thr.create(&reindex_thread_fn, server)) {
		log::err("[kls] Failed to spawn reindex thread: %s", excuse);
		server.reindex.pending = false;
		return;
	}
	thr.detach()!!;
	log::info("[kls] Scheduled async reindex (debounce %d ms)", REINDEX_DEBOUNCE_MS);
}

fn int reindex_thread_fn(void* arg) {
	@pool_init(mem, 1024 * 256) {
		reindex_thread_body((Server*)arg);
	};
	return 0;
}

fn void reindex_thread_body(Server* server) {
	ReindexState* state = &server.reindex;

	// Debounce loop: sleep, then check if cancelled (more changes arrived)
	while (true) {
		thread::sleep_ms(REINDEX_DEBOUNCE_MS);

		state.mu.lock();
		if (state.cancel) {
			// More changes arrived during debounce — restart timer
			state.cancel = false;
			state.mu.unlock();
			log::debug("[kls] Reindex debounce reset, sleeping again");
			continue;
		}
		state.in_progress = true;
		state.pending = false;
		state.mu.unlock();
		break;
	}

	log::info("[kls] Async reindex starting...");

	// Resolve new classpath
	Classpath* new_cp = mem::new(Classpath);
	new_cp.init();
	classpath::resolve_classpath(new_cp, state.root_path, "");

	// Build new dep index with incremental diff
	DependencyIndex* new_idx = mem::new(DependencyIndex);
	new_idx.init();

	// Compute which JARs are new vs unchanged
	DependencyIndex* old_idx = &server.workspace.dep_index;
	Classpath* old_cp = &server.workspace.classpath;

	// Build set of old JAR paths for fast lookup
	usz copied_count = 0;
	usz new_jar_count = 0;

	for (usz i = 0; i < new_cp.jar_count; i++) {
		String new_path = new_cp.jars[i].path;
		bool found_in_old = false;
		for (usz j = 0; j < old_cp.jar_count; j++) {
			if (old_cp.jars[j].path == new_path) {
				found_in_old = true;
				break;
			}
		}
		if (found_in_old) {
			// Copy symbols from old index (no disk I/O)
			new_idx.copy_symbols_from_jar(old_idx, new_path);
			copied_count++;
		} else {
			// New JAR — must parse from disk
			@pool() {
				new_idx.index_jar(new_path);
			};
			new_jar_count++;
		}
	}

	log::info("[kls] Incremental reindex: %d JARs copied, %d JARs newly parsed",
		(int)copied_count, (int)new_jar_count);

	// Index JDK into new index
	jdk_index::index_jdk(new_idx, "", 0, 0);

	// Fallback: if no JARs, try system Kotlin stdlib
	if (new_cp.jar_count == 0) {
		kotlin_fallback::index_system_kotlin(new_idx);
	}

	// Store results for main thread to swap in
	state.mu.lock();
	state.new_classpath = new_cp;
	state.new_dep_index = new_idx;
	state.in_progress = false;
	state.complete = true;
	state.mu.unlock();

	log::info("[kls] Async reindex complete, waiting for main thread to swap");
}

/**
 * Called from main loop after each message. If background reindex finished,
 * swap in new classpath/dep_index, re-scan workspace, invalidate doc caches.
 */
fn void Server.check_reindex_complete(Server* self) {
	self.reindex.mu.lock();
	bool complete = self.reindex.complete;
	if (!complete) {
		self.reindex.mu.unlock();
		return;
	}

	Classpath* new_cp = self.reindex.new_classpath;
	DependencyIndex* new_idx = self.reindex.new_dep_index;
	self.reindex.complete = false;
	self.reindex.new_classpath = null;
	self.reindex.new_dep_index = null;
	self.reindex.mu.unlock();

	log::info("[kls] Swapping in new classpath and dependency index");

	progress::create("kls-reindex");
	progress::begin("kls-reindex", "Kotlin Language Server", 0);
	progress::report("kls-reindex", "Applying updated dependencies...", 50);

	// Free old, swap in new
	self.workspace.classpath.free();
	self.workspace.classpath = *new_cp;
	mem::free(new_cp);

	self.workspace.dep_index.free();
	self.workspace.dep_index = *new_idx;
	mem::free(new_idx);
	types::clear_dep_member_cache();

	// Re-scan workspace with updated module source roots
	progress::report("kls-reindex", "Re-scanning workspace...", 70);
	self.workspace.scan_workspace();

	// Invalidate all open document caches so cross-file resolution uses new deps
	progress::report("kls-reindex", "Invalidating caches...", 90);
	self.documents.invalidate_all_caches();

	// Re-publish diagnostics for all open docs
	@pool() {
		foreach (&doc : self.documents.docs.tvalues()) {
			diagnostics::publish_diagnostics(&self.documents, doc.uri, &self.workspace);
		}
	};

	progress::end("kls-reindex", "Ready");
	log::info("[kls] Reindex swap complete");
}

/**
 * Check if a URI refers to a build configuration file.
 */
fn bool is_build_file(String uri) {
	return uri.ends_with("/build.gradle.kts")
		|| uri.ends_with("/build.gradle")
		|| uri.ends_with("/settings.gradle.kts")
		|| uri.ends_with("/settings.gradle")
		|| uri.ends_with("/pom.xml")
		|| uri.ends_with("/gradle.properties")
		|| uri.ends_with("/libs.versions.toml")
		|| uri.ends_with("/gradle-wrapper.properties");
}
