module kls::test::unrelated_equality_test;

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

fn bool has(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		String m = diags.get_at((usz)i).get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Positive ────────────────────────────────────────────────────

fn void int_eq_string() @test {
	@pool() {
		String content =
			`fun foo() {
	val a: Int = 1
	val b: String = "x"
	if (a == b) println("nope")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Comparison of unrelated types 'Int' and 'String'"),
			"Int == String flagged");
	};
}

fn void boolean_neq_int() @test {
	@pool() {
		String content =
			`fun foo() {
	val a: Boolean = true
	val b: Int = 1
	if (a != b) println("nope")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Comparison of unrelated types 'Boolean' and 'Int'"),
			"Boolean != Int flagged");
	};
}

fn void verdict_eq_is_false() @test {
	@pool() {
		String content =
			`fun foo() {
	val a: Int = 1
	val b: String = "x"
	if (a == b) println("nope")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "always yields false"),
			"== verdict is false");
	};
}

fn void verdict_neq_is_true() @test {
	@pool() {
		String content =
			`fun foo() {
	val a: Int = 1
	val b: String = "x"
	if (a != b) println("yep")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "always yields true"),
			"!= verdict is true");
	};
}

// ── Negative ───────────────────────────────────────────────────

fn void numeric_tower_not_flagged() @test {
	@pool() {
		String content =
			`fun foo() {
	val a: Int = 1
	val b: Long = 2L
	if (a == b) println("ok")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Comparison of unrelated types"),
			"Int vs Long not flagged (numeric tower)");
	};
}

fn void any_not_flagged() @test {
	@pool() {
		String content =
			`fun foo(a: Any, b: Int) {
	if (a == b) println("ok")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Comparison of unrelated types"),
			"Any not flagged");
	};
}

fn void nullable_diff_not_flagged() @test {
	@pool() {
		String content =
			`fun foo(a: String?, b: String) {
	if (a == b) println("ok")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Comparison of unrelated types"),
			"String? vs String not flagged");
	};
}

fn void null_compare_not_flagged() @test {
	@pool() {
		String content =
			`fun foo(a: String?) {
	if (a == null) println("ok")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Comparison of unrelated types"),
			"== null not flagged");
	};
}

fn void same_type_not_flagged() @test {
	@pool() {
		String content =
			`fun foo() {
	val a: Int = 1
	val b: Int = 2
	if (a == b) println("ok")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Comparison of unrelated types"),
			"Int == Int not flagged");
	};
}

fn void unknown_type_not_flagged() @test {
	@pool() {
		String content =
			`fun foo(x: Foo, y: Bar) {
	if (x == y) println("ok")
}
`;
		Object* diags = build_diags(content);
		// Foo and Bar are unresolved (UNKNOWN) – be permissive.
		assert(!has(diags, "Comparison of unrelated types"),
			"unresolved types not flagged");
	};
}
