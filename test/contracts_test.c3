module kls::test::contracts_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::kotlin::cfg;
import kls::kotlin::flow;
import kls::kotlin::types;
import kls::kotlin::contracts;

// ── Helpers (shared with flow_test) ────────────────────────────────

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

// ── Stdlib contract lookup ─────────────────────────────────────────

fn void stdlib_table_has_require_not_null() @test {
	contracts::ContractEffect[4] buf;
	usz n = contracts::collect_stdlib_contracts("requireNotNull", buf[..]);
	assert(n >= 1, "requireNotNull contract present");
	assert(buf[0].kind == contracts::ContractEffectKind.RETURNS_IMPLIES,
		"is RETURNS_IMPLIES");
	assert(buf[0].rv == contracts::ReturnValue.ANY_RETURN, "any-return");
	assert(buf[0].pred == contracts::PredKind.PRED_NOT_NULL, "predicates not-null");
	assert(buf[0].target.kind == contracts::PredTargetKind.TARGET_PARAM,
		"targets a parameter");
	assert(buf[0].target.param_index == 0, "first parameter");
}

fn void stdlib_table_has_is_null_or_empty() @test {
	contracts::ContractEffect[4] buf;
	usz n = contracts::collect_stdlib_contracts("isNullOrEmpty", buf[..]);
	assert(n >= 1, "isNullOrEmpty contract present");
	bool found_receiver_target = false;
	for (usz i = 0; i < n; i++) {
		if (buf[i].target.kind == contracts::PredTargetKind.TARGET_RECEIVER) {
			found_receiver_target = true;
			assert(buf[i].rv == contracts::ReturnValue.RETURN_FALSE,
				"narrows on returns(false)");
		}
	}
	assert(found_receiver_target, "has receiver-targeted contract");
}

// ── Flow integration: stdlib contracts narrow at call sites ────────

fn void require_not_null_call_narrows_param() @test {
	@pool() {
		String src = "fun f(x: String?) { requireNotNull(x); val s = x }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "x", 1); // 2nd `x`
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "x");
		assert(fact != null, "expected fact after requireNotNull(x)");
		assert(fact.not_null, "x is non-null after requireNotNull");
	};
}

fn void check_not_null_call_narrows_param() @test {
	@pool() {
		String src = "fun f(x: String?) { checkNotNull(x); val s = x }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "x", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "x");
		assert(fact != null, "fact after checkNotNull");
		assert(fact.not_null, "non-null");
	};
}

fn void require_with_is_check_narrows() @test {
	@pool() {
		String src = "fun f(a: Any) { require(a is String); val s = a }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "a", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "a");
		assert(fact != null, "fact after require(a is String)");
		assert(fact.narrowed.name == "String", "narrowed to String, got '%s'",
			fact.narrowed.name);
	};
}

// ── User-defined contract extraction ───────────────────────────────

fn void extract_user_contract_returns_implies_param() @test {
	@pool() {
		String src = "fun assertNotNull(x: Any?) { contract { returns() implies (x != null) } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint fdecl = find_decl(pr, FUN_DECL, "assertNotNull");
		assert(fdecl != ast::NO_PARENT, "found fun");

		contracts::ContractEffect[4] buf;
		usz n = contracts::extract_user_contracts(pr, fdecl, buf[..]);
		assert(n == 1, "decoded 1 effect, got %d", n);
		assert(buf[0].kind == contracts::ContractEffectKind.RETURNS_IMPLIES,
			"RETURNS_IMPLIES");
		assert(buf[0].rv == contracts::ReturnValue.ANY_RETURN, "any-return");
		assert(buf[0].pred == contracts::PredKind.PRED_NOT_NULL, "not-null pred");
		assert(buf[0].target.kind == contracts::PredTargetKind.TARGET_PARAM,
			"param target");
		assert(buf[0].target.param_index == 0, "param index 0");
	};
}

fn void extract_user_contract_returns_true_implies_is() @test {
	@pool() {
		String src = "fun isStr(v: Any?): Boolean { contract { returns(true) implies (v is String) } ; return v is String }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint fdecl = find_decl(pr, FUN_DECL, "isStr");
		contracts::ContractEffect[4] buf;
		usz n = contracts::extract_user_contracts(pr, fdecl, buf[..]);
		assert(n == 1, "1 effect");
		assert(buf[0].rv == contracts::ReturnValue.RETURN_TRUE, "returns(true)");
		assert(buf[0].pred == contracts::PredKind.PRED_IS_TYPE, "is-type pred");
		assert(buf[0].type_text == "String", "type is String, got '%s'",
			buf[0].type_text);
	};
}

fn void extract_user_contract_calls_in_place() @test {
	@pool() {
		String src = "fun runOnce(block: () -> Unit) { contract { callsInPlace(block, EXACTLY_ONCE) } ; block() }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint fdecl = find_decl(pr, FUN_DECL, "runOnce");
		contracts::ContractEffect[4] buf;
		usz n = contracts::extract_user_contracts(pr, fdecl, buf[..]);
		assert(n == 1, "1 effect");
		assert(buf[0].kind == contracts::ContractEffectKind.CALLS_IN_PLACE,
			"CALLS_IN_PLACE");
		assert(buf[0].cip_param_index == 0, "first param");
		assert(buf[0].ik == contracts::InvocationKind.EXACTLY_ONCE, "exactly once");
	};
}

fn void extract_user_contract_skips_non_contract_body() @test {
	@pool() {
		String src = "fun plain(x: Int): Int { return x + 1 }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint fdecl = find_decl(pr, FUN_DECL, "plain");
		contracts::ContractEffect[4] buf;
		usz n = contracts::extract_user_contracts(pr, fdecl, buf[..]);
		assert(n == 0, "no contracts on plain body");
	};
}

// ── Conditional-position narrowing (Phase 2 deferred item) ─────────

fn void cond_narrow_negated_is_null_or_empty() @test {
	@pool() {
		// `if (!s.isNullOrEmpty()) s.length` — s should be non-null in then-branch.
		String src = "fun f(s: String?) { if (!s.isNullOrEmpty()) { val len = s } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 1st `s` = receiver of isNullOrEmpty; 2nd `s` = use in `val len = s`.
		uint use_idx = find_nth_name(pr, "s", 1);
		assert(use_idx != ast::NO_PARENT, "found use of s in then-branch");
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "s");
		assert(fact != null, "expected smart cast fact for s");
		assert(fact.not_null, "s should be not-null in then-branch of !isNullOrEmpty");
	};
}

fn void cond_narrow_else_branch_of_is_null_or_empty() @test {
	@pool() {
		// `if (s.isNullOrEmpty()) {} else { s.length }` — s non-null in else.
		String src = "fun f(s: String?) { if (s.isNullOrEmpty()) {} else { val len = s } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "s", 1);
		assert(use_idx != ast::NO_PARENT, "found use of s in else-branch");
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "s");
		assert(fact != null, "expected smart cast fact for s in else-branch");
		assert(fact.not_null, "s should be not-null in else-branch of isNullOrEmpty");
	};
}

fn void cond_narrow_negated_is_null_or_blank() @test {
	@pool() {
		String src = "fun f(s: String?) { if (!s.isNullOrBlank()) { val len = s } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "s", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "s");
		assert(fact != null, "expected fact");
		assert(fact.not_null, "s should be not-null after !isNullOrBlank()");
	};
}

fn void cond_no_narrow_in_wrong_branch_isNullOrEmpty() @test {
	@pool() {
		// then-branch of `if (s.isNullOrEmpty()) { ... }` learns NOTHING about s
		// (s could be null or empty).
		String src = "fun f(s: String?) { if (s.isNullOrEmpty()) { val x = s } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "s", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "s");
		// Either no fact or not_null=false — both acceptable.
		assert(fact == null || !fact.not_null,
			"s must NOT be smart-cast to non-null in then-branch of isNullOrEmpty");
	};
}

// ── User-defined contract consumption (in-file) ────────────────────

fn void user_contract_stmt_position_narrows_caller() @test {
	@pool() {
		// User defines a non-null assertion helper. Caller-side use of x
		// after the call should be smart-cast to non-null.
		String src = "fun assertNotNull(x: Any?) { contract { returns() implies (x != null) } ; if (x == null) throw RuntimeException() }\n"
			"fun f(p: String?) { assertNotNull(p) ; val s = p }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 1st `p` use = the call argument; 2nd `p` use = the post-call use.
		uint use_idx = find_nth_name(pr, "p", 1);
		assert(use_idx != ast::NO_PARENT, "found post-call use of p");
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected smart cast fact for p");
		assert(fact.not_null, "p should be not-null after assertNotNull(p)");
	};
}

fn void user_contract_cond_position_narrows_then_branch() @test {
	@pool() {
		// User defines isNotNull: returns(true) implies (x != null).
		// Caller-side `if (isNotNull(p)) p.length` narrows p to non-null.
		String src = "fun isNotNull(x: Any?): Boolean { contract { returns(true) implies (x != null) } ; return x != null }\n"
			"fun f(p: String?) { if (isNotNull(p)) { val s = p } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 1st `p` use = arg to isNotNull; 2nd `p` use = inside then-branch.
		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact in then-branch");
		assert(fact.not_null, "p should be not-null in then-branch of isNotNull(p)");
	};
}

fn void user_contract_cond_position_narrows_else_branch_for_returns_false() @test {
	@pool() {
		// returns(false) implies (x != null) — narrow in ELSE branch.
		String src = "fun isMissing(x: Any?): Boolean { contract { returns(false) implies (x != null) } ; return x == null }\n"
			"fun f(p: String?) { if (isMissing(p)) {} else { val s = p } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact in else-branch");
		assert(fact.not_null, "p should be not-null in else-branch of isMissing(p)");
	};
}

fn void user_contract_negated_cond_flips_branch() @test {
	@pool() {
		// `if (!isNotNull(p))` — narrow now in ELSE, not THEN.
		String src = "fun isNotNull(x: Any?): Boolean { contract { returns(true) implies (x != null) } ; return x != null }\n"
			"fun f(p: String?) { if (!isNotNull(p)) {} else { val s = p } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact in else-branch (negated cond)");
		assert(fact.not_null, "p should be not-null in else-branch of !isNotNull(p)");
	};
}

fn void user_contract_is_type_narrows_caller() @test {
	@pool() {
		// returns() implies (x is String) — narrow x to String after call.
		String src = "fun assertString(x: Any) { contract { returns() implies (x is String) } ; if (x !is String) throw RuntimeException() }\n"
			"fun f(p: Any) { assertString(p) ; val s = p }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact after assertString(p)");
		assert(fact.narrowed.name == "String",
			"expected narrowing to String, got '%s'", fact.narrowed.name);
	};
}

fn void user_contract_no_match_does_nothing() @test {
	@pool() {
		// Call to undefined fn — no contract, no narrow.
		String src = "fun f(p: String?) { someUndefinedFn(p) ; val s = p }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		// No fact OR not_null=false — both fine.
		assert(fact == null || !fact.not_null,
			"unknown callee must not narrow caller");
	};
}
