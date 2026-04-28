module kls::test::flow_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::kotlin::cfg;
import kls::kotlin::flow;
import kls::kotlin::types;

// ── Helpers ────────────────────────────────────────────────────────

fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	r.free_errors();
	mem::free(r);
}

fn uint find_decl(ParseResult* pr, NodeKind kind, String name) {
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].kind == kind && pr.nodes[i].name == name) return i;
	}
	return ast::NO_PARENT;
}

// Find the Nth NAME_EXPR with the given name (0-indexed).
fn uint find_nth_name(ParseResult* pr, String name, uint n) {
	uint found = 0;
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].kind == NAME_EXPR && pr.nodes[i].name == name) {
			if (found == n) return i;
			found++;
		}
	}
	return ast::NO_PARENT;
}

// Find a CALL_EXPR by callee name.
fn uint find_call(ParseResult* pr, String name) {
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].kind == CALL_EXPR && pr.nodes[i].name == name) return i;
	}
	return ast::NO_PARENT;
}

fn flow::Fact* run_and_lookup(String src, String var_name, uint name_occurrence) {
	ParseResult* pr = do_parse(src);
	uint f = find_decl(pr, FUN_DECL, "f");
	Cfg* c = cfg::build_cfg(pr, f);
	flow::FlowAnalysis* fa = flow::analyze(pr, c);
	uint use_idx = find_nth_name(pr, var_name, name_occurrence);
	flow::Fact* fact = fa.fact_at(pr, c, use_idx, var_name);
	// Intentionally leak: tests are short-lived.
	return fact;
}

// ── Phase C: transfer functions ────────────────────────────────────

fn void if_is_check_narrows_in_then_branch() @test {
	@pool() {
		String src = "fun f(a: Any) { if (a is String) { val len = a } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// The 2nd `a` reference (inside the then-branch).
		uint use_idx = find_nth_name(pr, "a", 1);
		assert(use_idx != ast::NO_PARENT, "found 2nd a");
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected smart cast fact for a");
		assert(fact.narrowed.name == "String", "narrowed to String, got '%s'", fact.narrowed.name);
	};
}

fn void if_not_null_narrows_in_then_branch() @test {
	@pool() {
		String src = "fun f(a: String?) { if (a != null) { val s = a } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected fact");
		assert(fact.not_null, "expected not_null=true");
	};
}

fn void if_eq_null_narrows_in_else_branch() @test {
	@pool() {
		String src = "fun f(a: String?) { if (a == null) { val n = 1 } else { val s = a } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 2nd `a` is in else-branch; first `a` is the condition LHS.
		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected fact in else");
		assert(fact.not_null, "expected not_null in else");
	};
}

fn void bang_bang_asserts_non_null() @test {
	@pool() {
		String src = "fun f(a: String?) { a!!; val s = a }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// The 2nd `a` is the use after `a!!`.
		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected fact after !!");
		assert(fact.not_null, "expected not_null after !!");
	};
}

fn void elvis_return_asserts_non_null() @test {
	@pool() {
		String src = "fun f(a: String?): Int { a ?: return 0; return a.length }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// Find the `a` in `a.length` — the last `a` reference.
		uint last_a = ast::NO_PARENT;
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].kind == NAME_EXPR && pr.nodes[i].name == "a") last_a = i;
		}
		flow::Fact* fact = fa.fact_at(pr, c, last_a, "a");
		assert(fact != null, "expected fact after elvis-return");
		assert(fact.not_null, "expected not_null after elvis-return");
	};
}

fn void require_not_null_asserts_non_null() @test {
	@pool() {
		String src = "fun f(a: String?) { requireNotNull(a); val s = a }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected fact after requireNotNull");
		assert(fact.not_null, "expected not_null");
	};
}

fn void check_not_null_asserts_non_null() @test {
	@pool() {
		String src = "fun f(a: String?) { checkNotNull(a); val s = a }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected fact after checkNotNull");
		assert(fact.not_null, "expected not_null");
	};
}

fn void require_with_not_null_compare_asserts_non_null() @test {
	@pool() {
		String src = "fun f(a: String?) { require(a != null); val s = a }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 2nd `a` reference (after require)
		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "expected fact after require(a != null)");
		assert(fact.not_null, "expected not_null");
	};
}

fn void assignment_kills_facts() @test {
	@pool() {
		String src = "fun f(a: String?) { if (a != null) { a = null; val s = a } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// After `a = null`, the next `a` (3rd occurrence: cond, lhs, rhs use)
		// should NOT have a not_null fact.
		uint use_idx = ast::NO_PARENT;
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].kind == NAME_EXPR && pr.nodes[i].name == "a") {
				use_idx = i; // last one
			}
		}
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact == null || !fact.not_null,
			"expected no smart cast fact after assignment");
	};
}

fn void if_no_smart_cast_outside_branch() @test {
	@pool() {
		String src = "fun f(a: String?) { if (a != null) { val n = 1 }; val s = a }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// The `a` after the if (in `val s = a`).
		uint last_a = ast::NO_PARENT;
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].kind == NAME_EXPR && pr.nodes[i].name == "a") last_a = i;
		}
		flow::Fact* fact = fa.fact_at(pr, c, last_a, "a");
		// After the if (no else), facts from then-branch are intersected
		// with the empty else-branch state -> should NOT have not_null.
		assert(fact == null || !fact.not_null, "expected no fact after if-without-else");
	};
}

fn void early_return_null_guard() @test {
	@pool() {
		String src = "fun f(a: String?): Int { if (a == null) return 0; return a.length }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// The `a` in `a.length` (last `a`).
		uint last_a = ast::NO_PARENT;
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].kind == NAME_EXPR && pr.nodes[i].name == "a") last_a = i;
		}
		flow::Fact* fact = fa.fact_at(pr, c, last_a, "a");
		assert(fact != null, "expected fact after early-return guard");
		assert(fact.not_null, "expected not_null after early-return guard");
	};
}
