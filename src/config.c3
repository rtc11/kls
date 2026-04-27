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
	bool enum_exhaustive_diagnostic;    // emit "non-exhaustive when on enum class" warnings
	bool useless_cast_diagnostic;       // emit "useless cast" warnings for `x as T` when typeOf(x) == T
	bool unused_parameter_diagnostic;   // emit hints for function PARAMs never referenced in body
	bool var_can_be_val_diagnostic;     // emit hints for local `var` never reassigned
	bool unnecessary_not_null_diagnostic; // emit warnings for `x!!` on non-null values
}

// Module-level global with defaults
ServerConfig g_config = {
	.hover_docs_from_source = true,
	.smart_cast_diagnostic = true,
	.sealed_exhaustive_diagnostic = true,
	.enum_exhaustive_diagnostic = true,
	.useless_cast_diagnostic = true,
	.unused_parameter_diagnostic = true,
	.var_can_be_val_diagnostic = true,
	.unnecessary_not_null_diagnostic = true,
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

	if (try val = opts.get("enumExhaustiveDiagnostic")) {
		if (val.is_bool()) {
			g_config.enum_exhaustive_diagnostic = val.b;
			log::debug("[kls] config: enumExhaustiveDiagnostic = %s",
				g_config.enum_exhaustive_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("uselessCastDiagnostic")) {
		if (val.is_bool()) {
			g_config.useless_cast_diagnostic = val.b;
			log::debug("[kls] config: uselessCastDiagnostic = %s",
				g_config.useless_cast_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unusedParameterDiagnostic")) {
		if (val.is_bool()) {
			g_config.unused_parameter_diagnostic = val.b;
			log::debug("[kls] config: unusedParameterDiagnostic = %s",
				g_config.unused_parameter_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("varCanBeValDiagnostic")) {
		if (val.is_bool()) {
			g_config.var_can_be_val_diagnostic = val.b;
			log::debug("[kls] config: varCanBeValDiagnostic = %s",
				g_config.var_can_be_val_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unnecessaryNotNullDiagnostic")) {
		if (val.is_bool()) {
			g_config.unnecessary_not_null_diagnostic = val.b;
			log::debug("[kls] config: unnecessaryNotNullDiagnostic = %s",
				g_config.unnecessary_not_null_diagnostic ? "true" : "false");
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
 * Whether to emit "non-exhaustive when on enum class" warnings when
 * a `when` over an enum-typed subject lacks an `else` arm and does
 * not list every entry.
 */
fn bool enum_exhaustive_diagnostic_enabled() {
	return g_config.enum_exhaustive_diagnostic;
}

/**
 * Whether to emit "useless cast" warnings for `x as T` where the source
 * type already conforms exactly to T (same name + null-safety).
 */
fn bool useless_cast_diagnostic_enabled() {
	return g_config.useless_cast_diagnostic;
}

/**
 * Whether to emit "Parameter 'x' is never used" hints for function
 * parameters that are never referenced in the body.
 */
fn bool unused_parameter_diagnostic_enabled() {
	return g_config.unused_parameter_diagnostic;
}

/**
 * Whether to emit "Variable 'x' can be 'val'" hints for local `var`
 * declarations that are never reassigned.
 */
fn bool var_can_be_val_diagnostic_enabled() {
	return g_config.var_can_be_val_diagnostic;
}

/**
 * Whether to emit "Unnecessary !! on non-null value" warnings when a
 * not-null assertion is applied to a value the type system or flow
 * analysis already knows is non-null.
 */
fn bool unnecessary_not_null_diagnostic_enabled() {
	return g_config.unnecessary_not_null_diagnostic;
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
