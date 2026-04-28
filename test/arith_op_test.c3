module kls::test::arith_op_test;

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
	defer { types::free_type_info(ti); mem::free(ti); }
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool any_msg_contains(Object* diags, String needle) {
	usz n = diags.get_len();
	for (usz i = 0; i < n; i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

// ── Negative tests (should NOT warn) ───────────────────────────────

fn void no_warn_int_plus_int() @test {
	@pool() {
		Object* diags = build_diags(`fun foo() { val x: Int = 1; val y: Int = 2; val z = x + y }`);
		assert(!any_msg_contains(diags, "is not defined"), "Int + Int must not warn");
	};
}

fn void no_warn_int_plus_long() @test {
	@pool() {
		Object* diags = build_diags(`fun foo() { val x: Int = 1; val y: Long = 2; val z = x + y }`);
		assert(!any_msg_contains(diags, "is not defined"), "numeric tower must not warn");
	};
}

fn void no_warn_string_plus_int() @test {
	@pool() {
		Object* diags = build_diags(`fun foo() { val s: String = "hi"; val n: Int = 1; val z = s + n }`);
		assert(!any_msg_contains(diags, "is not defined"), "String + Int must not warn");
	};
}

fn void no_warn_when_left_unknown() @test {
	@pool() {
		// `q` has no type annotation and no init in scope — UNKNOWN
		Object* diags = build_diags(`fun foo(q: Any) { val n: Int = 1; val z = q + n }`);
		assert(!any_msg_contains(diags, "is not defined"), "Any operand must not warn");
	};
}

fn void no_warn_data_class_with_plus_operator() @test {
	@pool() {
		String content = `data class Vec(val x: Int) {
	operator fun plus(o: Vec): Vec = Vec(x + o.x)
}
fun foo() { val a = Vec(1); val b = Vec(2); val z = a + b }`;
		Object* diags = build_diags(content);
		assert(!any_msg_contains(diags, "is not defined"),
			"user-defined plus operator must suppress warning");
	};
}

// ── Positive tests (should warn) ───────────────────────────────────

fn void warn_class_without_plus_operator() @test {
	@pool() {
		String content = `class Vec(val x: Int)
fun foo() { val a = Vec(1); val b = Vec(2); val z = a + b }`;
		Object* diags = build_diags(content);
		assert(any_msg_contains(diags, "Operator '+' is not defined"),
			"class without plus must warn");
	};
}

fn void warn_minus_on_class_without_operator() @test {
	@pool() {
		String content = `class Vec(val x: Int)
fun foo() { val a = Vec(1); val b = Vec(2); val z = a - b }`;
		Object* diags = build_diags(content);
		assert(any_msg_contains(diags, "Operator '-' is not defined"),
			"class without minus must warn");
	};
}

fn void warn_times_on_class_without_operator() @test {
	@pool() {
		String content = `class Vec
fun foo() { val a = Vec(); val b = Vec(); val z = a * b }`;
		Object* diags = build_diags(content);
		assert(any_msg_contains(diags, "Operator '*' is not defined"),
			"class without times must warn");
	};
}
