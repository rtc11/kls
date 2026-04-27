module kls::test::useless_cast_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::config;

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

// ── Useless: x: Int → x as Int ───────────────────────────────

fn void useless_cast_same_type_emitted() @test {
	@pool() {
		String src =
			`fun foo() {
				val x: Int = 1
				val y = x as Int
			}`;
		Object* diags = build_diags(src);
		assert(any_message_contains(diags, "Useless cast"),
			"expected useless cast warning for `x as Int` where x: Int");
	};
}

// ── Not useless: nullable → non-null cast performs check ─────

fn void useless_cast_nullable_to_nonnull_not_emitted() @test {
	@pool() {
		String src =
			`fun foo() {
				val x: Int? = 1
				val y = x as Int
			}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Useless cast"),
			"should NOT warn — Int? as Int performs a runtime null check");
	};
}

// ── Not useless: safe cast (`as?`) always returns nullable ───

fn void useless_safe_cast_not_emitted() @test {
	@pool() {
		String src =
			`fun foo() {
				val x: Int = 1
				val y = x as? Int
			}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Useless cast"),
			"should NOT warn for safe cast (as?)");
	};
}

// ── Disabled via config ──────────────────────────────────────

fn void useless_cast_not_emitted_when_disabled() @test {
	@pool() {
		bool saved = config::g_config.useless_cast_diagnostic;
		config::g_config.useless_cast_diagnostic = false;
		defer config::g_config.useless_cast_diagnostic = saved;

		String src =
			`fun foo() {
				val x: Int = 1
				val y = x as Int
			}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Useless cast"),
			"expected NO warning when useless_cast_diagnostic is disabled");
	};
}
