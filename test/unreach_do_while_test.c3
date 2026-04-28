module kls::test::unreach_do_while_test;

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

// Probe: gap — do { ... } while (true) post-loop should be unreachable
fn void after_do_while_true() @test {
	@pool() {
		String content =
			`fun foo() {
	do {
		println("loop")
	} while (true)
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "expected unreachable after do-while(true)");
	};
}

// Regression: do-while(true) with break → no warning
fn void no_warn_do_while_true_with_break() @test {
	@pool() {
		String content =
			`fun foo() {
	do {
		if (Math.random() > 0.5) break
	} while (true)
	println("after")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable"), "do-while(true) with break should not flag post-loop");
	};
}

// Regression: do-while(false) → body runs once, post-loop reachable
fn void no_warn_do_while_false() @test {
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
		assert(!has(diags, "Unreachable"), "do-while(false) should not flag post-loop");
	};
}

// Regression: do-while(var) → not literal-true, no warning
fn void no_warn_do_while_var_cond() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	do {
		println("loop")
	} while (b)
	println("after")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable"), "do-while(var) should not flag post-loop");
	};
}

// do { ... } while ((true)) → parenthesized literal still detected
fn void after_do_while_paren_true() @test {
	@pool() {
		String content =
			`fun foo() {
	do {
		println("loop")
	} while ((true))
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable"), "do-while((true)) should flag post-loop");
	};
}
