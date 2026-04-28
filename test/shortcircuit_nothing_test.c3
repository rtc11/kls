module kls::test::shortcircuit_nothing_test;

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

fn void and_with_error_rhs() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	val r = b && error("nope")
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Right-hand side of '&&' has type Nothing"),
			"&& Nothing rhs");
	};
}

fn void or_with_error_rhs() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	val r = b || error("nope")
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Right-hand side of '||' has type Nothing"),
			"|| Nothing rhs");
	};
}

fn void and_with_todo_rhs() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	val r = b && TODO("not yet")
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "has type Nothing"), "TODO rhs");
	};
}

fn void hint_severity() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	val r = b && error("x")
	println(r)
}
`;
		Object* diags = build_diags(content);
		bool found = false;
		for (sz i = 0; i < diags.get_len(); i++) {
			Object* d = diags.get_at((usz)i);
			String m = d.get_string("message") ?? "";
			if (!m.contains("has type Nothing")) continue;
			int sev = d.get_int("severity") ?? 0;
			assert(sev == 4, "Hint severity");
			found = true;
		}
		assert(found, "diag found");
	};
}

// ── Negative: must NOT trigger ──────────────────────────────────

fn void and_with_bool_rhs_no_hint() @test {
	@pool() {
		String content =
			`fun foo(a: Boolean, b: Boolean) {
	val r = a && b
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "has type Nothing"), "ordinary && no hint");
	};
}

fn void plus_with_nothing_rhs_not_flagged() @test {
	@pool() {
		// `+` is not short-circuit — both sides always eval; this case is
		// already caught by the unreachable-code pass at the statement
		// level (val init diverges), not here.
		String content =
			`fun foo() {
	val r = 1 + error("x")
	println(r)
}
`;
		Object* diags = build_diags(content);
		// No "Right-hand side of '&&'" message — different op.
		assert(!has(diags, "Right-hand side of"),
			"non-short-circuit op not flagged here");
	};
}

fn void elvis_rhs_not_flagged_by_this_pass() @test {
	@pool() {
		// `?:` rhs Nothing is the canonical guard pattern — never flag.
		String content =
			`fun foo(x: Int?) {
	val y = x ?: error("null")
	println(y)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Right-hand side of '?:' has type Nothing"),
			"elvis Nothing rhs not flagged");
	};
}

fn void multiple_short_circuits_each_flagged() @test {
	@pool() {
		String content =
			`fun foo(a: Boolean, b: Boolean) {
	val r1 = a && error("x")
	val r2 = b || error("y")
	println(r1)
	println(r2)
}
`;
		Object* diags = build_diags(content);
		assert(count(diags, "has type Nothing") == 2, "two hints");
	};
}
