module kls::test::redundant_null_check_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool has_diag_message_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Probe: non-null val compared to null with `!=` ──────────────

fn void non_null_neq_null_warns_always_true() @test {
	@pool() {
		String content =
			`fun foo() {
	val x: String = "hi"
	if (x != null) println(x)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "always true"),
			"expected 'always true' for non-null != null");
	};
}

// ── Probe: non-null val compared to null with `==` ──────────────

fn void non_null_eq_null_warns_always_false() @test {
	@pool() {
		String content =
			`fun foo() {
	val x: String = "hi"
	if (x == null) println("never")
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "always false"),
			"expected 'always false' for non-null == null");
	};
}

// ── Probe: nullable val → no warning ────────────────────────────

fn void nullable_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	val x: String? = null
	if (x != null) println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "always true"),
			"should not warn for nullable val");
		assert(!has_diag_message_contains(diags, "always false"),
			"should not warn for nullable val");
	};
}

// ── Probe: literal compared to null ─────────────────────────────

fn void literal_neq_null_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	if ("hi" != null) println("ok")
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "always true"),
			"expected 'always true' for \"hi\" != null");
	};
}

// ── Probe: this != null → warn ──────────────────────────────────

fn void this_neq_null_warns() @test {
	@pool() {
		String content =
			`class C {
	fun foo() {
		if (this != null) println("ok")
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "always true"),
			"expected 'always true' for this != null");
	};
}

// ── Probe: nullable param without narrowing → no warning ────────

fn void nullable_param_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: String?) {
	if (x != null) println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "always true"),
			"should not warn for nullable param");
	};
}
