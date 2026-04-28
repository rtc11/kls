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
	bool redundant_null_check_diagnostic; // emit warnings for `x == null` / `x != null` on non-null values
	bool unreachable_catch_diagnostic;  // emit warnings for catch clauses shadowed by an earlier supertype catch
	bool unnecessary_safe_call_diagnostic; // emit warnings for `x?.foo` where x is statically non-null
	bool redundant_if_bool_diagnostic;  // emit warnings for `if (cond) true else false` and `if (cond) false else true`
	bool unnecessary_elvis_diagnostic;  // emit warnings for `x ?: y` where x is statically non-null
	bool empty_catch_diagnostic;        // emit hints for catch clauses with empty bodies
	bool redundant_override_diagnostic; // emit warnings for `override fun foo() = super.foo()`
	bool redundant_else_when_diagnostic; // emit warnings for `else` arm in already-exhaustive `when`
	bool catch_swallows_diagnostic; // emit hints for non-empty catch blocks that ignore the exception
	bool redundant_bool_comparison_diagnostic; // emit warnings for `b == true` / `b != false` etc.
	bool redundant_type_check_diagnostic; // emit warnings for `x is T` / `x !is T` where typeof(x) <: T
	bool unused_private_diagnostic; // emit warnings for unused private top-level fns/properties/classes
	bool redundant_explicit_type_diagnostic; // emit hints for `val x: Int = 1` where init type matches declared type
	bool unsafe_nullable_call_diagnostic; // emit warnings for `x.foo` / `x.bar` where x is nullable and not narrowed
	bool unit_typed_decl_diagnostic; // emit warnings for `x: Unit` on params and val/var (Unit carries no info)
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
	.redundant_null_check_diagnostic = true,
	.unreachable_catch_diagnostic = true,
	.unnecessary_safe_call_diagnostic = true,
	.redundant_if_bool_diagnostic = true,
	.unnecessary_elvis_diagnostic = true,
	.empty_catch_diagnostic = true,
	.redundant_override_diagnostic = true,
	.redundant_else_when_diagnostic = true,
	.catch_swallows_diagnostic = true,
	.redundant_bool_comparison_diagnostic = true,
	.redundant_type_check_diagnostic = true,
	.unused_private_diagnostic = true,
	.redundant_explicit_type_diagnostic = true,
	.unsafe_nullable_call_diagnostic = true,
	.unit_typed_decl_diagnostic = true,
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

	if (try val = opts.get("redundantNullCheckDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_null_check_diagnostic = val.b;
			log::debug("[kls] config: redundantNullCheckDiagnostic = %s",
				g_config.redundant_null_check_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unreachableCatchDiagnostic")) {
		if (val.is_bool()) {
			g_config.unreachable_catch_diagnostic = val.b;
			log::debug("[kls] config: unreachableCatchDiagnostic = %s",
				g_config.unreachable_catch_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unnecessarySafeCallDiagnostic")) {
		if (val.is_bool()) {
			g_config.unnecessary_safe_call_diagnostic = val.b;
			log::debug("[kls] config: unnecessarySafeCallDiagnostic = %s",
				g_config.unnecessary_safe_call_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("redundantIfBoolDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_if_bool_diagnostic = val.b;
			log::debug("[kls] config: redundantIfBoolDiagnostic = %s",
				g_config.redundant_if_bool_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unnecessaryElvisDiagnostic")) {
		if (val.is_bool()) {
			g_config.unnecessary_elvis_diagnostic = val.b;
			log::debug("[kls] config: unnecessaryElvisDiagnostic = %s",
				g_config.unnecessary_elvis_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("emptyCatchDiagnostic")) {
		if (val.is_bool()) {
			g_config.empty_catch_diagnostic = val.b;
			log::debug("[kls] config: emptyCatchDiagnostic = %s",
				g_config.empty_catch_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("redundantOverrideDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_override_diagnostic = val.b;
			log::debug("[kls] config: redundantOverrideDiagnostic = %s",
				g_config.redundant_override_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("redundantElseWhenDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_else_when_diagnostic = val.b;
			log::debug("[kls] config: redundantElseWhenDiagnostic = %s",
				g_config.redundant_else_when_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("catchSwallowsDiagnostic")) {
		if (val.is_bool()) {
			g_config.catch_swallows_diagnostic = val.b;
			log::debug("[kls] config: catchSwallowsDiagnostic = %s",
				g_config.catch_swallows_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("redundantBoolComparisonDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_bool_comparison_diagnostic = val.b;
			log::debug("[kls] config: redundantBoolComparisonDiagnostic = %s",
				g_config.redundant_bool_comparison_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("redundantTypeCheckDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_type_check_diagnostic = val.b;
			log::debug("[kls] config: redundantTypeCheckDiagnostic = %s",
				g_config.redundant_type_check_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unusedPrivateDiagnostic")) {
		if (val.is_bool()) {
			g_config.unused_private_diagnostic = val.b;
			log::debug("[kls] config: unusedPrivateDiagnostic = %s",
				g_config.unused_private_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("redundantExplicitTypeDiagnostic")) {
		if (val.is_bool()) {
			g_config.redundant_explicit_type_diagnostic = val.b;
			log::debug("[kls] config: redundantExplicitTypeDiagnostic = %s",
				g_config.redundant_explicit_type_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unsafeNullableCallDiagnostic")) {
		if (val.is_bool()) {
			g_config.unsafe_nullable_call_diagnostic = val.b;
			log::debug("[kls] config: unsafeNullableCallDiagnostic = %s",
				g_config.unsafe_nullable_call_diagnostic ? "true" : "false");
		}
	}

	if (try val = opts.get("unitTypedDeclDiagnostic")) {
		if (val.is_bool()) {
			g_config.unit_typed_decl_diagnostic = val.b;
			log::debug("[kls] config: unitTypedDeclDiagnostic = %s",
				g_config.unit_typed_decl_diagnostic ? "true" : "false");
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
 * Whether to emit "Condition is always true/false" warnings for
 * `x == null` / `x != null` where the static type of `x` is non-nullable.
 */
fn bool redundant_null_check_diagnostic_enabled() {
	return g_config.redundant_null_check_diagnostic;
}

/**
 * Whether to emit "Catch clause is unreachable" warnings when a later
 * catch clause's exception type is a subtype of an earlier one.
 */
fn bool unreachable_catch_diagnostic_enabled() {
	return g_config.unreachable_catch_diagnostic;
}

/**
 * Whether to emit "Unnecessary safe call on non-null receiver" warnings
 * when `?.` is used on a receiver whose static type is non-nullable.
 */
fn bool unnecessary_safe_call_diagnostic_enabled() {
	return g_config.unnecessary_safe_call_diagnostic;
}

/**
 * Whether to emit "Redundant 'if'" warnings for boolean if-else
 * expressions of the form `if (cond) true else false` (or false/true).
 */
fn bool redundant_if_bool_diagnostic_enabled() {
	return g_config.redundant_if_bool_diagnostic;
}

/**
 * Whether to emit "Elvis operator (?:) on non-null value is redundant"
 * warnings when the LHS of `?:` is statically non-null.
 */
fn bool unnecessary_elvis_diagnostic_enabled() {
	return g_config.unnecessary_elvis_diagnostic;
}

/**
 * Whether to emit "Empty catch block" hints for catch clauses with
 * empty bodies (no statements).
 */
fn bool empty_catch_diagnostic_enabled() {
	return g_config.empty_catch_diagnostic;
}

/**
 * Whether to emit "Override is redundant" warnings for
 * `override fun foo(args) = super.foo(args)` and equivalent block forms.
 */
fn bool redundant_override_diagnostic_enabled() {
	return g_config.redundant_override_diagnostic;
}

fn bool redundant_else_when_diagnostic_enabled() {
	return g_config.redundant_else_when_diagnostic;
}

fn bool catch_swallows_diagnostic_enabled() {
	return g_config.catch_swallows_diagnostic;
}

fn bool redundant_bool_comparison_diagnostic_enabled() {
	return g_config.redundant_bool_comparison_diagnostic;
}

fn bool redundant_type_check_diagnostic_enabled() {
	return g_config.redundant_type_check_diagnostic;
}

fn bool unused_private_diagnostic_enabled() {
	return g_config.unused_private_diagnostic;
}

fn bool redundant_explicit_type_diagnostic_enabled() {
	return g_config.redundant_explicit_type_diagnostic;
}

fn bool unsafe_nullable_call_diagnostic_enabled() {
	return g_config.unsafe_nullable_call_diagnostic;
}

fn bool unit_typed_decl_diagnostic_enabled() {
	return g_config.unit_typed_decl_diagnostic;
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
