module kls::config;

import std::io;
import std::collections::object;

// ── Server configuration ──────────────────────────────────────────
//
// Populated from the client's initializationOptions in the
// "initialize" request.  Every field has a sensible default so the
// server works out of the box when no options are supplied.
//
// Neovim example:
//   require('lspconfig').kls.setup {
//     init_options = {
//       hoverDocsFromSource = true,
//     },
//   }

struct ServerConfig {
	bool hover_docs_from_source;   // extract Javadoc/KDoc from src.zip / -sources.jar
}

// Module-level global with defaults
ServerConfig g_config = { .hover_docs_from_source = true };

/**
 * Apply initializationOptions received from the client.
 * Unknown keys are silently ignored.
 */
fn void apply_init_options(Object* opts) {
	if (opts == null) return;

	if (try val = opts.get("hoverDocsFromSource")) {
		if (val.is_bool()) {
			g_config.hover_docs_from_source = val.b;
			io::eprintfn("[kls] config: hoverDocsFromSource = %s",
				g_config.hover_docs_from_source ? "true" : "false");
		}
	}
}

/**
 * Whether real-time Javadoc/KDoc extraction from source archives
 * is enabled for hover.
 */
fn bool hover_docs_enabled() {
	return g_config.hover_docs_from_source;
}
