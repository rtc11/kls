module kls::test::unreach_while_true_test;

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

// Probe: break inside loop block followed by stmt → should warn
fn void after_break_in_loop() @test {
	@pool() {
		String content =
			`fun foo() {
	while (true) {
		break
		println("dead")
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after break");
	};
}

// Probe: continue followed by stmt
fn void after_continue_in_loop() @test {
	@pool() {
		String content =
			`fun foo() {
	for (i in 1..10) {
		continue
		println("dead")
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after continue");
	};
}

// Probe: unreachable inside nested block (via CFG)
fn void after_return_in_nested_block() @test {
	@pool() {
		String content =
			`fun foo(): Int {
	if (true) {
		return 1
		println("dead")
	}
	return 2
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after return in nested block");
	};
}

// Probe: throw + unreachable
fn void after_throw_with_message() @test {
	@pool() {
		String content =
			`fun foo() {
	throw RuntimeException("boom")
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after throw");
	};
}

// Probe: while(true) without break → infinite loop, code after is unreachable
fn void after_infinite_while() @test {
	@pool() {
		String content =
			`fun foo() {
	while (true) {
		println("forever")
	}
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after while(true)");
	};
}

// Probe: do { ... } while(false) — body runs once, condition always false
// stmt after is reachable, NO warning
fn void after_do_while_false_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	do {
		println("once")
	} while (false)
	println("after")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable"), "should NOT warn for code after do-while(false)");
	};
}

// Probe: when expression where every branch returns (no else, sealed-style would be exhaustive)
fn void after_when_all_return() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Int {
	when (x) {
		1 -> return 10
		else -> return 20
	}
	println("dead")
	return 0
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after exhaustive when all return");
	};
}

// ── Negative regressions for while(true) detection ─────────────

// while(true) with break in body → post-loop reachable, no warning
fn void no_warn_while_true_with_break() @test {
	@pool() {
		String content =
			`fun foo() {
	while (true) {
		if (Math.random() > 0.5) break
	}
	println("after")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable"), "while(true) with break should not flag post-loop");
	};
}

// while(false) → post-loop reachable, no warning
fn void no_warn_while_false() @test {
	@pool() {
		String content =
			`fun foo() {
	while (false) {
		println("never")
	}
	println("after")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable"), "while(false) should not flag post-loop code");
	};
}

// while with var condition → not literal-true, no warning
fn void no_warn_while_var_cond() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	while (b) {
		println("loop")
	}
	println("after")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable"), "while(var) should not flag post-loop");
	};
}

// while ((true)) → parenthesized literal still detected
fn void after_while_paren_true() @test {
	@pool() {
		String content =
			`fun foo() {
	while ((true)) {
		println("loop")
	}
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "while((true)) should flag post-loop");
	};
}
