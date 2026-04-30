module kls::test::method_call_shadows_stdlib_test;

import kls::lsp::diagnostics;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::kotlin::ast;
import std::collections::object;

fn Object* build_diags(String src) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(src, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(src, pr, null, ti);
}

fn bool has_msg_containing(Object* arr, String needle) {
	for (usz i = 0; i < arr.get_len(); i++) {
		if (arr.get_at(i).get_string("message")!!.contains(needle)) return true;
	}
	return false;
}

// `recv.error(...)` is a method call on `recv`, NOT the stdlib top-level
// `kotlin.error(): Nothing`. Previously the CALL_EXPR resolver short-circuited
// on `name == "error"` via resolve_known_call() and returned Nothing,
// causing every branch of `when { … -> log.error(…) }` to be typed Nothing,
// which made the CFG mark the post-when fall-through as Unreachable.
fn void method_call_named_error_is_not_nothing() @test {
	@pool() {
		Object* d = build_diags(
`class Logger { fun error(s: String) {}; fun warn(s: String) {} }
val log = Logger()
fun handle(code: Int, topic: String): Int {
    when {
        code >= 500 -> log.error("e")
        code >= 400 -> log.warn("w")
    }
    val x = topic.length ?: return 0
    return x
}`);
		assert(!has_msg_containing(d, "Unreachable"),
			"method call `recv.error(...)` must not be typed Nothing");
	};
}

// Same shape for `recv.TODO(...)` — must not pick up stdlib TODO(): Nothing.
fn void method_call_named_TODO_is_not_nothing() @test {
	@pool() {
		Object* d = build_diags(
`class Foo { fun TODO() {} }
fun handle(): Int {
    val f = Foo()
    f.TODO()
    return 1
}`);
		assert(!has_msg_containing(d, "Unreachable"),
			"method call `recv.TODO()` must not be typed Nothing");
	};
}
