module kls::test::redund_override_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	return diagnostics::build_diagnostics_array(content, pr);
}

fn bool has_diag_message_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Probe: nullary expression body → warn ──────────────────────

fn void nullary_expr_body_warns() @test {
	@pool() {
		String content =
			`open class A { open fun foo() {} }
class B : A() {
	override fun foo() = super.foo()
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Override is redundant"),
			"expected redundant override hint");
	};
}

// ── Probe: matching positional args → warn ─────────────────────

fn void matching_args_warns() @test {
	@pool() {
		String content =
			`open class A { open fun foo(x: Int, y: Int) {} }
class B : A() {
	override fun foo(x: Int, y: Int) = super.foo(x, y)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Override is redundant"),
			"expected redundant override hint for matching args");
	};
}

// ── Probe: block body single statement → warn ──────────────────

fn void block_body_single_stmt_warns() @test {
	@pool() {
		String content =
			`open class A { open fun foo(x: Int) {} }
class B : A() {
	override fun foo(x: Int) { super.foo(x) }
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Override is redundant"),
			"expected redundant override hint for block body");
	};
}

// ── Probe: return wrapping → warn ──────────────────────────────

fn void return_wrap_warns() @test {
	@pool() {
		String content =
			`open class A { open fun foo(x: Int): Int = x }
class B : A() {
	override fun foo(x: Int): Int { return super.foo(x) }
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Override is redundant"),
			"expected redundant override hint for return wrap");
	};
}

// ── Probe: extra arg modification → no warn ────────────────────

fn void modified_arg_no_warn() @test {
	@pool() {
		String content =
			`open class A { open fun foo(x: Int) {} }
class B : A() {
	override fun foo(x: Int) = super.foo(x + 1)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Override is redundant"),
			"should not warn for modified arg");
	};
}

// ── Probe: extra statement → no warn ───────────────────────────

fn void extra_stmt_no_warn() @test {
	@pool() {
		String content =
			`open class A { open fun foo() {} }
class B : A() {
	override fun foo() {
		super.foo()
		println("extra")
	}
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Override is redundant"),
			"should not warn for extra statement");
	};
}

// ── Probe: no override modifier → no warn ──────────────────────

fn void no_override_no_warn() @test {
	@pool() {
		String content =
			`open class A { open fun foo() {} }
class B : A() {
	fun bar() = super.foo()
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Override is redundant"),
			"should not warn without override modifier");
	};
}

// ── Probe: not super → no warn ─────────────────────────────────

fn void not_super_no_warn() @test {
	@pool() {
		String content =
			`open class A { open fun foo() {} }
class B : A() {
	override fun foo() = bar()
	fun bar() {}
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Override is redundant"),
			"should not warn when callee is not super");
	};
}

// ── Probe: wrong arg name → no warn ────────────────────────────

fn void wrong_arg_name_no_warn() @test {
	@pool() {
		String content =
			`open class A { open fun foo(x: Int) {} }
class B : A() {
	val y: Int = 0
	override fun foo(x: Int) = super.foo(y)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Override is redundant"),
			"should not warn when arg name differs from param");
	};
}
