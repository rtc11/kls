module kls::config;

import std::io;
import std::collections::object;
import kls::log;

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
	bool smart_cast_diagnostic;    // emit "smart cast to T is impossible" warnings
	bool sealed_exhaustive_diagnostic;  // emit "non-exhaustive when on sealed type" warnings
}

// Module-level global with defaults
ServerConfig g_config = {
	.hover_docs_from_source = true,
	.smart_cast_diagnostic = true,
	.sealed_exhaustive_diagnostic = true,
};

/**
 * Apply initializationOptions received from the client.
 * Unknown keys are silently ignored.
 */
fn void apply_init_options(Object* opts) {
	if (opts == null) return;

	if (try val = opts.get("hoverDocsFromSource")) {
		if (val.is_bool()) {
			g_config.hover_docs_from_source = val.b;
			log::debug("[kls] config: hoverDocsFromSource = %s",
				g_config.hover_docs_from_source ? "true" : "false");
		}
	}

	if (try val = opts.get("smartCastDiagnostic")) {
		if (val.is_bool()) {
			g_config.smart_cast_diagnostic = val.b;
			log::debug("[kls] config: smartCastDiagnostic = %s",
				g_config.smart_cast_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("sealedExhaustiveDiagnostic")) {
		if (val.is_bool()) {
			g_config.sealed_exhaustive_diagnostic = val.b;
			log::debug("[kls] config: sealedExhaustiveDiagnostic = %s",
				g_config.sealed_exhaustive_diagnostic ? "true" : "false");
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

/**
 * Whether to emit "smart cast to T is impossible" diagnostics when a
 * use site requests narrowing but the binding fails the stability gate
 * (e.g. captured local var, mutable property).
 */
fn bool smart_cast_diagnostic_enabled() {
	return g_config.smart_cast_diagnostic;
}

/**
 * Whether to emit "non-exhaustive when on sealed type" warnings when
 * a `when` over a sealed-class subject lacks an `else` arm and does
 * not cover every direct subtype.
 */
fn bool sealed_exhaustive_diagnostic_enabled() {
	return g_config.sealed_exhaustive_diagnostic;
}

/**
 * Handle workspace/didChangeConfiguration notification.
 * Expects params.settings with the same keys as initializationOptions.
 * Falls back to checking params directly for flat payloads.
 */
fn void apply_settings(Object* params) {
	if (params == null) return;

	// LSP spec: settings are under params.settings
	Object* settings = params.get("settings") ?? params;
	apply_init_options(settings);
	log::debug("[kls] Configuration updated");
}
