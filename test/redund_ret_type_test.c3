module kls::test::redund_ret_type_test;

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

fn bool any_msg_contains(Object* diags, String needle) {
	usz n = diags.get_len();
	for (usz i = 0; i < n; i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

fn void hint_when_int_return_matches_int_literal() @test {
	@pool() {
		Object* diags = build_diags(`fun foo(): Int = 42`);
		assert(any_msg_contains(diags, "return type is redundant"),
			"expected redundant-return-type hint");
	};
}

fn void hint_when_string_return_matches_string_literal() @test {
	@pool() {
		Object* diags = build_diags(`fun foo(): String = "hello"`);
		assert(any_msg_contains(diags, "return type is redundant"),
			"expected redundant-return-type hint for String");
	};
}

fn void no_hint_when_no_explicit_type() @test {
	@pool() {
		Object* diags = build_diags(`fun foo() = 42`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"no explicit type — no hint expected");
	};
}

fn void no_hint_for_block_body() @test {
	@pool() {
		Object* diags = build_diags(`fun foo(): Int { return 42 }`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"block body — defer (multi-return analysis)");
	};
}

fn void no_hint_for_override() @test {
	@pool() {
		Object* diags = build_diags(
`open class Base { open fun foo(): Int = 0 }
class Sub : Base() { override fun foo(): Int = 42 }`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"override — explicit type may be required for ABI clarity");
	};
}

fn void no_hint_for_open_fun() @test {
	@pool() {
		Object* diags = build_diags(`open class Foo { open fun bar(): Int = 1 }`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"open fun — explicit type clarifies ABI for subclasses");
	};
}

fn void no_hint_for_abstract() @test {
	@pool() {
		Object* diags = build_diags(`abstract class Foo { abstract fun bar(): Int }`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"abstract has no body");
	};
}

fn void no_hint_when_types_differ() @test {
	@pool() {
		Object* diags = build_diags(`fun foo(): Long = 42`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"declared Long, body Int — types differ, hint should not fire");
	};
}

fn void no_hint_for_unit_return() @test {
	@pool() {
		Object* diags = build_diags(`fun foo(): Unit = println("x")`);
		assert(!any_msg_contains(diags, "return type is redundant"),
			"Unit covered by separate diag");
	};
}
