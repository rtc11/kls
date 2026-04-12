module kls::lsp::lifecycle;

import std::io;
import std::collections::object;
import kls::lsp::capabilities;

/**
 * Handle the "initialize" request.
 * Returns the InitializeResult with server capabilities.
 */
fn Object* handle_initialize(Object* params) {
	io::eprintfn("[kls] Handling initialize");

	// Extract client info if available
	if (params != null) {
		if (try client_info = params.get("clientInfo")) {
			if (try name = client_info.get_string("name")) {
				io::eprintfn("[kls] Client: %s", name);
			}
		}
	}

	// Build result
	Object* result = object::new_obj(tmem);
	result.set("capabilities", capabilities::build_capabilities());

	Object* server_info = object::new_obj(tmem);
	server_info.set("name", "kls");
	server_info.set("version", "0.1.0");
	result.set("serverInfo", server_info);

	return result;
}

/**
 * Handle the "shutdown" request.
 * Returns null result (success).
 */
fn Object* handle_shutdown() {
	io::eprintfn("[kls] Handling shutdown");
	return null;
}
