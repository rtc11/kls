module kls::test::smart_cast_diagnostic_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::config;

/**
 * Build diagnostics for the given source. Same shape as the helper in
 * diagnostics_test.c3 but local so the two files don't collide.
 */
fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); }
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool any_message_contains(Object* diags, String needle) {
	usz n = diags.get_len();
	for (usz i = 0; i < n; i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

fn void smart_cast_impossible_emitted_for_captured_local_var() @test {
	@pool() {
		// Local var captured by a nested lambda after a null guard:
		// stability gate fails => warning surfaces.
		String src =
			`fun test(s: String?) {
				var hashKey: String? = s
				if (hashKey == null) { return }
				run {
					val y = hashKey
				}
			}`;
		Object* diags = build_diags(src);
		assert(any_message_contains(diags, "Smart cast"),
			"expected smart-cast-impossible warning for captured local var");
	};
}

fn void smart_cast_impossible_not_emitted_for_local_val() @test {
	@pool() {
		// Local val is stable, even when captured by a lambda: no warning.
		String src =
			`fun test(s: String?) {
				val hashKey: String? = s
				if (hashKey == null) { return }
				run {
					val y = hashKey
				}
			}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Smart cast"),
			"expected NO smart-cast-impossible warning for stable local val");
	};
}

fn void smart_cast_impossible_not_emitted_when_disabled() @test {
	@pool() {
		// Toggle the config flag off: no warning even when the binding is
		// unstable. Restore the default afterwards so other tests keep
		// the expected behaviour.
		bool saved = config::g_config.smart_cast_diagnostic;
		config::g_config.smart_cast_diagnostic = false;
		defer config::g_config.smart_cast_diagnostic = saved;

		String src =
			`fun test(s: String?) {
				var hashKey: String? = s
				if (hashKey == null) { return }
				run {
					val y = hashKey
				}
			}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Smart cast"),
			"expected NO warning when smart_cast_diagnostic is disabled");
	};
}

fn void smart_cast_impossible_not_emitted_for_param() @test {
	@pool() {
		// Function parameters are stable (effective val): no warning.
		String src =
			`fun test(x: String?) {
				if (x == null) { return }
				run {
					val y = x
				}
			}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Smart cast"),
			"expected NO smart-cast-impossible warning for parameter");
	};
}
