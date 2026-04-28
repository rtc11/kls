module kls::test::unsafe_null_recv_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

/**
 * Helper: count diagnostics whose message matches the unsafe-nullable-call
 * needle. Returns the count and (via out param) the full message of the first
 * match for asserting on.
 */
fn int count_unsafe_nullable(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	Object* arr = diagnostics::build_diagnostics_array(content, pr, null, ti);
	usz n = arr.get_len();
	int hits = 0;
	for (usz i = 0; i < n; i++) {
		Object* d = arr.get_at(i);
		String msg = d.get_string("message")!!;
		if (msg.contains("Only safe (?.) or non-null asserted")) hits++;
	}
	return hits;
}

fn void warns_on_dot_access_nullable_param() @test {
	String src = "fun test(s: String?) { s.length }";
	assert(count_unsafe_nullable(src) == 1, "expected 1 warning for `s.length` on nullable");
}

fn void warns_on_method_call_nullable_param() @test {
	String src = "fun test(s: String?) { s.toUpperCase() }";
	assert(count_unsafe_nullable(src) == 1, "expected 1 warning for `s.toUpperCase()` on nullable");
}

fn void warns_on_chained_dot_access() @test {
	// First `s.length` warns; second access is on Int (non-null) so OK.
	String src = "fun test(s: String?) { s.length.toString() }";
	assert(count_unsafe_nullable(src) == 1, "expected 1 warning for first nullable receiver");
}

fn void no_warning_on_safe_call() @test {
	String src = "fun test(s: String?) { s?.length }";
	assert(count_unsafe_nullable(src) == 0, "safe call should not warn");
}

fn void no_warning_on_not_null_assert() @test {
	String src = "fun test(s: String?) { s!!.length }";
	assert(count_unsafe_nullable(src) == 0, "!!. should not warn");
}

fn void no_warning_after_null_check_smart_cast() @test {
	String src = "fun test(s: String?) { if (s != null) s.length }";
	assert(count_unsafe_nullable(src) == 0, "smart cast should narrow to non-null");
}

fn void no_warning_on_non_null_param() @test {
	String src = "fun test(s: String) { s.length }";
	assert(count_unsafe_nullable(src) == 0, "non-null receiver is fine");
}

fn void no_warning_on_class_ref() @test {
	// Color is a class-ref (not a value); is_class_ref guard prevents warning.
	String src = "enum class Color { RED, BLUE }\nfun test() { Color.RED }";
	assert(count_unsafe_nullable(src) == 0, "class-ref receiver should not warn");
}

fn void warns_with_correct_severity_error() @test {
	String src = "fun test(s: String?) { s.length }";
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(src, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	Object* arr = diagnostics::build_diagnostics_array(src, pr, null, ti);
	usz n = arr.get_len();
	bool found = false;
	for (usz i = 0; i < n; i++) {
		Object* d = arr.get_at(i);
		String msg = d.get_string("message")!!;
		if (!msg.contains("Only safe (?.) or non-null asserted")) continue;
		int sev = (int)d.get_int("severity")!!;
		assert(sev == 1, "severity should be Error (1), got %d", sev);
		found = true;
	}
	assert(found, "should find at least one diagnostic");
}

fn void warns_on_nullable_local_val() @test {
	String src = "fun test() { val s: String? = null; s.length }";
	assert(count_unsafe_nullable(src) == 1, "nullable local val should warn");
}

fn void no_warning_after_elvis_throw() @test {
	String src = "fun test(s: String?) { val t: String = s ?: return; t.length }";
	assert(count_unsafe_nullable(src) == 0, "elvis-return should narrow t to non-null");
}

fn void no_warning_on_lhs_assignment() @test {
	// Writing to a nullable property via dot is a different concern (and rare);
	// don't flag the LHS itself.
	String src = "class B { var x: Int = 0 }\nfun test(b: B?) { b.x = 5 }";
	// b.x on LHS is the only access; we skip writes. Reading b.x as receiver
	// for the rest of the assignment chain should still be OK.
	int n = count_unsafe_nullable(src);
	assert(n == 0, "LHS write on nullable receiver currently not flagged (skip writes), got %d", n);
}
