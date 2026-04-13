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
import kls::lsp::document_symbols;
import kls::lsp::semantic_tokens;

struct Server {
	bool is_running;
	bool is_initialized;
	bool is_shutdown;
	DocumentStore documents;
}

fn void Server.init(Server* self) {
	self.is_running = false;
	self.is_initialized = false;
	self.is_shutdown = false;
	self.documents.init();
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
			Object* result = lifecycle::handle_initialize(params);
			json_rpc::send_response(request_id, result);
			self.is_initialized = true;

		case "initialized":
			io::eprintfn("[kls] Client initialized");

		case "shutdown":
			Object* result = lifecycle::handle_shutdown();
			json_rpc::send_response(request_id, result);
			self.is_shutdown = true;

		case "exit":
			self.is_running = false;

		case "textDocument/didOpen":
			if (params != null) {
				sync::handle_did_open(&self.documents, params);
			}

		case "textDocument/didChange":
			if (params != null) {
				sync::handle_did_change(&self.documents, params);
			}

		case "textDocument/didClose":
			if (params != null) {
				sync::handle_did_close(&self.documents, params);
			}

		case "textDocument/hover":
			if (params != null) {
				Object* result = hover::handle_hover(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/completion":
			if (params != null) {
				Object* result = completion::handle_completion(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/definition":
			if (params != null) {
				Object* result = definition::handle_definition(&self.documents, params);
				json_rpc::send_response(request_id, result);
			}

		case "textDocument/references":
			if (params != null) {
				Object* result = references::handle_references(&self.documents, params);
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

		default:
			io::eprintfn("[kls] Unknown method: %s", method);
			if (is_request) {
				json_rpc::send_error_response(request_id, json_rpc::METHOD_NOT_FOUND, "Method not found");
			}
	}
}
