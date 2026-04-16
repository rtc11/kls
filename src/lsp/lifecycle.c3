module kls::lsp::lifecycle;

import std::io;
import std::collections::object;
import kls::config;
import kls::lsp::capabilities;
import kls::lsp::progress;
import kls::workspace;
import kls::log;

/**
 * Handle the "initialize" request.
 * Returns the InitializeResult with server capabilities.
 * Extracts rootUri and stores it in the workspace index.
 */
fn Object* handle_initialize(Object* params, WorkspaceIndex* workspace) {
	log::debug("[kls] Handling initialize");

	// #6: Check if the client supports UTF-8 position encoding
	bool client_supports_utf8 = false;

	// Extract client info if available
	if (params != null) {
		if (try client_info = params.get("clientInfo")) {
			if (try name = client_info.get_string("name")) {
				log::info("[kls] Client: %s", name);
			}
		}

		// Check client capabilities for position encoding support
		if (try caps = params.get("capabilities")) {
			if (try general = caps.get("general")) {
				if (try encodings = general.get("positionEncodings")) {
					for (sz i = 0; i < encodings.get_len(); i++) {
						Object* enc = encodings.get_at(i);
						if (enc.is_string() && enc.s == "utf-8") {
							client_supports_utf8 = true;
						}
					}
				}
			}

			// Check if client supports window/workDoneProgress
			if (try window = caps.get("window")) {
				if (try wdp = window.get("workDoneProgress")) {
					if (wdp.is_bool() && wdp.b) {
						progress::set_client_support(true);
						log::debug("[kls] Client supports workDoneProgress");
					}
				}
			}
		}

		// Apply client-supplied settings
		if (try init_opts = params.get("initializationOptions")) {
			config::apply_init_options(init_opts);
		}

		// Extract workspace root URI
		if (try root_uri = params.get_string("rootUri")) {
			log::info("[kls] rootUri: %s", root_uri);
			workspace.set_root(root_uri);
		} else {
			log::info("[kls] rootUri not found in initialize params");
			// Fallback to rootPath (deprecated but still used by some clients)
			if (try root_path = params.get_string("rootPath")) {
				DString uri;
				uri.tinit();
				uri.appendf("file://%s", root_path);
				workspace.set_root(uri.str_view());
			} else {
				// Fallback to workspaceFolders (modern LSP clients)
				if (try folders = params.get("workspaceFolders")) {
					if (folders.is_array() && folders.get_len() > 0) {
						Object* first = folders.get_at(0);
						if (try folder_uri = first.get_string("uri")) {
							log::info("[kls] workspace root from workspaceFolders: %s", folder_uri);
							workspace.set_root(folder_uri);
						}
					}
				}
			}
		}
	}

	// Build result
	Object* result = object::new_obj(tmem);
	result.set("capabilities", capabilities::build_capabilities(client_supports_utf8));

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
	log::debug("[kls] Handling shutdown");
	return null;
}
