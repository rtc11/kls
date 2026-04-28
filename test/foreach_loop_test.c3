module kls::test::foreach_loop_test;

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

fn int count(Object* diags, String needle) {
	int n = 0;
	for (sz i = 0; i < diags.get_len(); i++) {
		String m = diags.get_at((usz)i).get_string("message") ?? "";
		if (m.contains(needle)) n++;
	}
	return n;
}

// ── Positive ────────────────────────────────────────────────────

fn void simple_foreach_with_println() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>) {
	xs.forEach { println(it) }
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "'forEach' can be replaced with a 'for' loop"),
			"forEach hint emitted");
	};
}

fn void foreach_with_explicit_param() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>) {
	xs.forEach { x -> println(x) }
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "'forEach' can be replaced with a 'for' loop"),
			"explicit-param forEach hint");
	};
}

fn void safe_call_foreach() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>?) {
	xs?.forEach { println(it) }
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "'forEach' can be replaced with a 'for' loop"),
			"safe-call forEach hint");
	};
}

// ── Suppression ────────────────────────────────────────────────

fn void suppressed_when_lambda_returns() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>): Int {
	xs.forEach { if (it < 0) return it }
	return 0
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'forEach' can be replaced with a 'for' loop"),
			"non-local return suppresses hint");
	};
}

fn void suppressed_when_lambda_continues() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>) {
	xs.forEach { if (it < 0) continue@forEach; println(it) }
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'forEach' can be replaced with a 'for' loop"),
			"continue suppresses hint");
	};
}

fn void suppressed_when_lambda_breaks() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>) {
	xs.forEach { if (it < 0) break@forEach; println(it) }
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'forEach' can be replaced with a 'for' loop"),
			"break suppresses hint");
	};
}

fn void only_one_diag_per_call() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>) {
	xs.forEach { println(it); println(it + 1) }
}
`;
		Object* diags = build_diags(content);
		assert(count(diags, "'forEach' can be replaced") == 1,
			"exactly one hint per call");
	};
}

// Ensure non-forEach calls are unaffected.
fn void unrelated_call_no_hint() @test {
	@pool() {
		String content =
			`fun foo(xs: List<Int>) {
	xs.map { it + 1 }
	xs.filter { it > 0 }
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'forEach' can be replaced for 'for' loop"),
			"map/filter not flagged");
	};
}
