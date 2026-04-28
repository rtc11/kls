module kls::test::unreach_subexpr_test;

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

// ── Positive cases: divergent sub-expr makes next stmt unreachable. ──

fn void val_init_diverges() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = TODO("nope")
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable code"), "val init diverges");
	};
}

fn void assign_rhs_diverges() @test {
	@pool() {
		String content =
			`fun foo() {
	var x = 1
	x = error("nope")
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable code"), "assign rhs diverges");
	};
}

fn void call_arg_diverges() @test {
	@pool() {
		String content =
			`fun foo() {
	println(error("nope"))
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable code"), "call arg diverges");
	};
}

fn void dot_receiver_diverges() @test {
	@pool() {
		String content =
			`fun foo() {
	error("x").toString()
	println("dead")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable code"), "dot receiver diverges");
	};
}

fn void binary_lhs_diverges() @test {
	@pool() {
		String content =
			`fun foo() {
	val a = error("x") + 1
	println(a)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Unreachable code"), "binary lhs (inside val init) diverges");
	};
}

// ── Negative cases: conditional-eval boundaries must NOT trigger. ──

fn void lambda_body_does_not_diverge() @test {
	@pool() {
		String content =
			`fun foo() {
	val f = { error("only when called") }
	println(f)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"),
			"lambda body Nothing does not make next stmt unreachable");
	};
}

fn void if_branch_does_not_diverge() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	val x = if (b) 1 else error("nope")
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"),
			"only one if-branch is Nothing — stmt does not diverge");
	};
}

fn void elvis_rhs_does_not_diverge() @test {
	@pool() {
		String content =
			`fun foo(x: Int?) {
	val y = x ?: error("null")
	println(y)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"),
			"elvis rhs is conditional — stmt does not always diverge");
	};
}

fn void or_rhs_does_not_diverge() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean) {
	val r = b || error("nope")
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"),
			"|| rhs is conditional");
	};
}

fn void when_branch_does_not_diverge() @test {
	@pool() {
		String content =
			`fun foo(s: String) {
	val r = when (s) {
		"a" -> 1
		else -> error("bad")
	}
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"),
			"when branch Nothing — stmt does not always diverge");
	};
}

fn void try_catch_does_not_diverge() @test {
	@pool() {
		String content =
			`fun foo() {
	val r = try { 1 } catch (e: Exception) { error("caught") }
	println(r)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"),
			"catch body Nothing — stmt does not always diverge");
	};
}

// ── Sanity: existing patterns still work. ──

fn void ordinary_call_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	println("a")
	println("b")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Unreachable code"), "ordinary calls reachable");
	};
}
