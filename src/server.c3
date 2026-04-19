module kls::server;

import std::io;
import std::encoding::json;
import std::collections::object;
import kls::log;
import kls::json_rpc;
import kls::document;
import kls::lsp::lifecycle;
import kls::lsp::sync;
import kls::lsp::hover;
import kls::lsp::completion;
import kls::lsp::definition;
import kls::lsp::references;
import kls::lsp::document_highlight;
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
import kls::deps::classpath;
import kls::deps::jar_index;
import kls::deps::jdk_index;
import kls::deps::kotlin_fallback;

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
	log::info("[kls] Server ready, waiting for messages on stdin...");

	while (self.is_running) {
		@pool() {
			// #1: Gracefully handle read/parse failures instead of panicking
			if (catch excuse = self.run_one_message()) {
				if (excuse == json_rpc::UNEXPECTED_EOF) {
					log::info("[kls] stdin closed, shutting down");
					self.is_running = false;
				} else {
					log::err("[kls] Error processing message: %s", excuse);
				}
			}
		};
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

		// #3: All request handlers send error response when params is null
		case "textDocument/hover":
			if (params != null) {
				Object* result = hover::handle_hover(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/signatureHelp":
			if (params != null) {
				Object* result = signature_help::handle_signature_help(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/completion":
			if (params != null) {
				Object* result = completion::handle_completion(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "completionItem/resolve":
			if (params != null) {
				Object* result = completion::handle_completion_resolve(&self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/definition":
			if (params != null) {
				Object* result = definition::handle_definition(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/typeDefinition":
			if (params != null) {
				Object* result = type_definition::handle_type_definition(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/implementation":
			if (params != null) {
				Object* result = implementation::handle_implementation(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/references":
			if (params != null) {
				Object* result = references::handle_references(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/documentHighlight":
			if (params != null) {
				Object* result = document_highlight::handle_document_highlight(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/documentLink":
			if (params != null) {
				Object* result = document_link::handle_document_link(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/documentSymbol":
			if (params != null) {
				Object* result = document_symbols::handle_document_symbol(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/foldingRange":
			if (params != null) {
				Object* result = folding_range::handle_folding_range(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/selectionRange":
			if (params != null) {
				Object* result = selection_range::handle_selection_range(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/formatting":
			if (params != null) {
				Object* result = formatting::handle_formatting(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/rangeFormatting":
			if (params != null) {
				Object* result = formatting::handle_range_formatting(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/onTypeFormatting":
			if (params != null) {
				Object* result = formatting::handle_on_type_formatting(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/codeAction":
			if (params != null) {
				Object* result = code_actions::handle_code_action(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/codeLens":
			if (params != null) {
				Object* result = code_lens::handle_code_lens(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/semanticTokens/full":
			if (params != null) {
				Object* result = semantic_tokens::handle_semantic_tokens_full(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/semanticTokens/full/delta":
			if (params != null) {
				Object* result = semantic_tokens::handle_semantic_tokens_delta(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/semanticTokens/range":
			if (params != null) {
				Object* result = semantic_tokens::handle_semantic_tokens_range(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/inlayHint":
			if (params != null) {
				Object* result = inlay_hints::handle_inlay_hints(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/prepareRename":
			if (params != null) {
				Object* result = rename::handle_prepare_rename(&self.documents, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/rename":
			if (params != null) {
				Object* result = rename::handle_rename(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/prepareCallHierarchy":
			if (params != null) {
				Object* result = call_hierarchy::handle_prepare(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "callHierarchy/incomingCalls":
			if (params != null) {
				Object* result = call_hierarchy::handle_incoming_calls(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "callHierarchy/outgoingCalls":
			if (params != null) {
				Object* result = call_hierarchy::handle_outgoing_calls(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "textDocument/prepareTypeHierarchy":
			if (params != null) {
				Object* result = type_hierarchy::handle_prepare(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "typeHierarchy/supertypes":
			if (params != null) {
				Object* result = type_hierarchy::handle_supertypes(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "typeHierarchy/subtypes":
			if (params != null) {
				Object* result = type_hierarchy::handle_subtypes(&self.documents, &self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "workspace/didChangeWatchedFiles":
			if (params != null) {
				handle_did_change_watched_files(&self.workspace, params);
			}

		case "workspace/symbol":
			if (params != null) {
				Object* result = workspace_symbols::handle_workspace_symbol(&self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "workspace/executeCommand":
			if (params != null) {
				Object* result = execute_command::handle_execute_command(&self.workspace, params);
				json_rpc::send_response(request_id, result);
			} else {
				json_rpc::send_error_response(request_id, json_rpc::INVALID_PARAMS, "Missing params");
			}

		case "$/cancelRequest":
			// Silently ignore — we don't support cancellation yet but must not error
			log::debug("[kls] Cancel request received (ignored)");

		case "textDocument/didSave":
			if (params != null) {
				sync::handle_did_save(&self.documents, &self.workspace, params);
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
					log::debug("[kls] Re-indexed: %s", uri);
				}

			case FILE_CHANGE_DELETED:
				workspace.remove_file(uri);
				log::debug("[kls] Removed from index: %s", uri);

			default:
				break;
		}
	}

	// Re-resolve classpath if any build file changed
	if (build_file_changed) {
		log::info("[kls] Build file changed, re-resolving classpath...");
		progress::create("kls-reindex");
		progress::begin("kls-reindex", "Kotlin Language Server", 0);

		progress::report("kls-reindex", "Re-resolving classpath...", 20);
		workspace.classpath.free();
		workspace.classpath.init();
		classpath::resolve_classpath(&workspace.classpath, workspace.root_path, "kls-reindex");

		// Re-scan workspace with updated module source roots
		progress::report("kls-reindex", "Re-scanning workspace...", 40);
		workspace.scan_workspace();

		progress::report("kls-reindex", "Re-indexing dependencies...", 60);
		workspace.dep_index.free();
		workspace.dep_index.init();
		workspace.dep_index.index_classpath(&workspace.classpath, "kls-reindex", 60, 75);

		progress::report("kls-reindex", "Indexing JDK...", 75);
		jdk_index::index_jdk(&workspace.dep_index, "kls-reindex", 75, 90);

		// Fallback: if no build system resolved any JARs, try system Kotlin stdlib
		if (workspace.classpath.jar_count == 0) {
			progress::report("kls-reindex", "Indexing Kotlin stdlib...", 90);
			kotlin_fallback::index_system_kotlin(&workspace.dep_index);
		}

		progress::end("kls-reindex", "Ready");
	}
}

/**
 * Check if a URI refers to a build configuration file.
 */
fn bool is_build_file(String uri) {
	return uri.ends_with("/build.gradle.kts")
		|| uri.ends_with("/build.gradle")
		|| uri.ends_with("/settings.gradle.kts")
		|| uri.ends_with("/settings.gradle")
		|| uri.ends_with("/pom.xml");
}
