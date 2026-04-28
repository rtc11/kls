module kls::test::unnecessary_safe_call_test;

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

// ── Probe: declared non-null → warn ────────────────────────────

fn void declared_non_null_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	val s: String = "hi"
	println(s?.length)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary safe call"),
			"expected unnecessary safe call diagnostic for declared non-null");
	};
}

// ── Probe: smart-cast non-null → warn ──────────────────────────

fn void smart_cast_non_null_warns() @test {
	@pool() {
		String content =
			`fun foo(s: String?) {
	if (s != null) {
		println(s?.length)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary safe call"),
			"expected unnecessary safe call after smart cast");
	};
}

// ── Probe: nullable type → no warn ─────────────────────────────

fn void nullable_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	val s: String? = null
	println(s?.length)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Unnecessary safe call"),
			"should not warn for nullable receiver");
	};
}

// ── Probe: nullable param → no warn ────────────────────────────

fn void nullable_param_no_warn() @test {
	@pool() {
		String content =
			`fun foo(s: String?) {
	println(s?.length)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Unnecessary safe call"),
			"should not warn for nullable param");
	};
}

// ── Probe: regular dot → no warn ───────────────────────────────

fn void regular_dot_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	val s: String = "hi"
	println(s.length)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Unnecessary safe call"),
			"should not warn for regular dot");
	};
}

// ── Probe: this on non-null context → warn ─────────────────────

fn void this_in_non_null_context_warns() @test {
	@pool() {
		String content =
			`class Foo {
	fun bar() {
		println(this?.hashCode())
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary safe call"),
			"expected unnecessary safe call for this");
	};
}
