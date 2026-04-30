module kls::test::cross_file_contracts_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::kotlin::cfg;
import kls::kotlin::flow;
import kls::kotlin::types;
import kls::kotlin::contracts;
import kls::workspace;

// ── Helpers ────────────────────────────────────────────────────────

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

// ── Cross-file user contract tests ─────────────────────────────────

// `assertNotNull` defined in helpers.kt with `returns() implies (x != null)`,
// called from caller.kt — caller-side `p` should be smart-cast to non-null
// after the call (Kotlin spec §11.3 contract DSL, statement-position).
fn void cross_file_returns_implies_not_null_narrows_caller() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String helpers = "fun assertNotNull(x: Any?) { contract { returns() implies (x != null) } }";
		String caller = "fun f(p: String?) { assertNotNull(p) ; val s = p }";

		ws.index_file("file:///helpers.kt", helpers);
		ws.index_file("file:///caller.kt", caller);

		// Parse caller fresh (workspace-cached AST is fine too, but we need a
		// stable pointer for the CFG/flow scratch).
		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(caller, pr);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 1st `p` use = arg, 2nd = post-call rhs of `val s`.
		uint use_idx = find_nth_name(pr, "p", 1);
		assert(use_idx != ast::NO_PARENT, "found post-call use of p");
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact for p after cross-file assertNotNull(p)");
		assert(fact.not_null, "p should be not-null after cross-file contract call");
	};
}

// `isNotNull` defined in helpers.kt with `returns(true) implies (x != null)`,
// caller uses it in `if (...)` condition — narrow in then-branch only.
fn void cross_file_returns_true_implies_narrows_then_branch() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String helpers = "fun isNotNull(x: Any?): Boolean { contract { returns(true) implies (x != null) } ; return x != null }";
		String caller = "fun f(p: String?) { if (isNotNull(p)) { val s = p } }";

		ws.index_file("file:///helpers.kt", helpers);
		ws.index_file("file:///caller.kt", caller);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(caller, pr);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		// 1st `p` = arg to isNotNull, 2nd `p` = inside then-branch.
		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact in then-branch");
		assert(fact.not_null, "p should be not-null in then-branch of cross-file isNotNull(p)");
	};
}

// `assertString` in helpers.kt with `returns() implies (x is String)` —
// caller-side `p` narrows to String after the call.
fn void cross_file_returns_implies_is_type_narrows_caller() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String helpers = "fun assertString(x: Any) { contract { returns() implies (x is String) } }";
		String caller = "fun f(p: Any) { assertString(p) ; val s = p }";

		ws.index_file("file:///helpers.kt", helpers);
		ws.index_file("file:///caller.kt", caller);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(caller, pr);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact != null, "expected fact after cross-file assertString(p)");
		assert(fact.narrowed.name == "String",
			"expected narrowing to String, got '%s'", fact.narrowed.name);
	};
}

// Cross-file callee with NO contract — must not narrow caller. Guards
// against false positives where the workspace lookup accidentally
// fabricates effects.
fn void cross_file_no_contract_does_not_narrow() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String helpers = "fun touch(x: Any?) { return }";
		String caller = "fun f(p: String?) { touch(p) ; val s = p }";

		ws.index_file("file:///helpers.kt", helpers);
		ws.index_file("file:///caller.kt", caller);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(caller, pr);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		assert(fact == null || !fact.not_null,
			"cross-file callee with no contract must not narrow caller");
	};
}

// Member function (extension or class member) cross-file contracts are
// out of scope — receiver-type disambiguation isn't done here. Verify
// we don't accidentally pick up a member contract by name alone.
fn void cross_file_member_function_contract_ignored() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Extension function on Any? with a contract — we should NOT
		// pick this up for a bare-name call (no receiver match logic).
		String helpers = "fun Any?.assertNotNull() { contract { returns() implies (this@assertNotNull != null) } }";
		String caller = "fun f(p: String?) { assertNotNull(p) ; val s = p }";

		ws.index_file("file:///helpers.kt", helpers);
		ws.index_file("file:///caller.kt", caller);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(caller, pr);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		uint fdecl = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, fdecl);
		defer c.free();
		flow::FlowAnalysis* fa = flow::analyze(pr, c);
		defer fa.free();

		uint use_idx = find_nth_name(pr, "p", 1);
		flow::Fact* fact = fa.fact_at(pr, c, use_idx, "p");
		// Receiver-bound contract not consumed for bare-name caller —
		// p should not be narrowed here.
		assert(fact == null || !fact.not_null,
			"member/extension contracts must not narrow bare-name callers");
	};
}
