module kls::test::cfg_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::kotlin::cfg;

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

// Count CFG nodes of a given kind.
fn uint count_kind(Cfg* c, CfgNodeKind k) {
	uint n = 0;
	for (uint i = 0; i < c.node_count; i++) {
		if (c.nodes[i].kind == k) n++;
	}
	return n;
}

// ── Phase A: linear-block CFG construction ─────────────────────────

fn void empty_function_body() @test {
	@pool() {
		String src = "fun f() {}";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		assert(f != ast::NO_PARENT, "expected fun f");

		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(c.node_count == 2, "expected ENTRY+EXIT only, got %d", c.node_count);
		assert(c.nodes[c.entry].kind == ENTRY, "entry kind");
		assert(c.nodes[c.exit].kind == EXIT, "exit kind");
		// ENTRY -> EXIT
		assert(c.nodes[c.entry].succ_count == 1, "entry succ count");
		assert(c.nodes[c.entry].succ[0] == c.exit, "entry -> exit");
	};
}

fn void linear_three_statements() @test {
	@pool() {
		String src = "fun f() { val a = 1; val b = 2; val c = 3 }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		// ENTRY + 3 STATEMENT + EXIT
		assert(count_kind(c, ENTRY) == 1, "entry count");
		assert(count_kind(c, EXIT) == 1, "exit count");
		assert(count_kind(c, STATEMENT) == 3, "statement count = %d", count_kind(c, STATEMENT));

		// Walk linear chain
		uint cur = c.entry;
		uint steps = 0;
		while (cur != c.exit && steps < 10) {
			assert(c.nodes[cur].succ_count == 1, "linear chain: succ_count=1 at %d", cur);
			cur = c.nodes[cur].succ[0];
			steps++;
		}
		assert(cur == c.exit, "chain reaches exit");
		assert(steps == 4, "4 edges (ENTRY->S1->S2->S3->EXIT), got %d", steps);
	};
}

fn void abstract_function_no_body() @test {
	@pool() {
		String src = "abstract class C { abstract fun f() }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		// No body -> ENTRY directly to EXIT
		assert(c.node_count == 2, "abstract fun: just ENTRY+EXIT, got %d", c.node_count);
		assert(c.nodes[c.entry].succ[0] == c.exit, "ENTRY -> EXIT");
	};
}

fn void ast_to_cfg_mapping() @test {
	@pool() {
		String src = "fun f() { val a = 1 }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		// PROPERTY_DECL `a` should map to a STATEMENT CFG node.
		uint a = find_decl(pr, PROPERTY_DECL, "a");
		assert(a != ast::NO_PARENT, "found a decl");
		uint cfg_idx = c.cfg_node_for(a);
		assert(cfg_idx != cfg::NO_CFG, "expected mapping for PROPERTY_DECL a");
		assert(c.nodes[cfg_idx].kind == STATEMENT, "mapped to STATEMENT");
	};
}

fn void predecessors_query() @test {
	@pool() {
		String src = "fun f() { val a = 1; val b = 2 }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		uint[8] buf;
		uint pred_count = c.predecessors(c.exit, &buf);
		assert(pred_count == 1, "exit has 1 predecessor, got %d", pred_count);

		// Entry has no predecessors
		uint entry_pred = c.predecessors(c.entry, &buf);
		assert(entry_pred == 0, "entry has no predecessor, got %d", entry_pred);
	};
}

// ── Phase B: branch / loop / terminator lowering ───────────────────

fn void if_else_creates_cond_and_merge() @test {
	@pool() {
		String src = "fun f(x: Int) { if (x > 0) { val a = 1 } else { val b = 2 } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, COND) == 1, "expected 1 COND, got %d", count_kind(c, COND));
		assert(count_kind(c, MERGE) == 1, "expected 1 MERGE, got %d", count_kind(c, MERGE));

		// COND has 2 successors
		uint cond_idx = 0;
		for (uint i = 0; i < c.node_count; i++) {
			if (c.nodes[i].kind == COND) { cond_idx = i; break; }
		}
		assert(c.nodes[cond_idx].succ_count == 2, "cond has 2 succ, got %d",
			c.nodes[cond_idx].succ_count);
	};
}

fn void if_no_else_falls_through() @test {
	@pool() {
		String src = "fun f(x: Int) { if (x > 0) { val a = 1 } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		// COND has 2 successors: then-branch and direct edge to merge.
		uint cond_idx = 0;
		for (uint i = 0; i < c.node_count; i++) {
			if (c.nodes[i].kind == COND) { cond_idx = i; break; }
		}
		assert(c.nodes[cond_idx].succ_count == 2, "cond has 2 succ");
	};
}

fn void return_diverges_remaining_unreachable() @test {
	@pool() {
		String src = "fun f(x: Int): Int { if (x > 0) return 1; return 2 }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		// Two RETURN nodes both edge to EXIT
		assert(count_kind(c, RETURN) == 2, "2 returns, got %d", count_kind(c, RETURN));
		uint[8] buf;
		uint exit_preds = c.predecessors(c.exit, &buf);
		// EXIT predecessors: both RETURNs (and possibly merge fall-through).
		assert(exit_preds >= 2, "EXIT has >=2 preds, got %d", exit_preds);
	};
}

fn void while_loop_has_back_edge() @test {
	@pool() {
		String src = "fun f(x: Int) { while (x != 0) { val a = 1 } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, LOOP_HEAD) == 1, "1 loop head");
		// LOOP_HEAD has at least 2 predecessors (entry + back-edge)
		uint head_idx = 0;
		for (uint i = 0; i < c.node_count; i++) {
			if (c.nodes[i].kind == LOOP_HEAD) { head_idx = i; break; }
		}
		uint[16] buf;
		uint preds = c.predecessors(head_idx, &buf);
		assert(preds == 2, "LOOP_HEAD has 2 preds (entry + back-edge), got %d", preds);
	};
}

fn void do_while_loop_body_executes_first() @test {
	@pool() {
		String src = "fun f(x: Int) { do { val a = 1 } while (x != 0) }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, LOOP_HEAD) == 1, "1 loop head");
		assert(count_kind(c, COND) == 1, "1 cond");
	};
}

fn void break_jumps_to_loop_exit() @test {
	@pool() {
		String src = "fun f(x: Int) { while (x != 0) { if (x == 1) break } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, BREAK) == 1, "1 break");
		// BREAK's successor must be a MERGE (loop exit), not the head
		uint break_idx = 0;
		for (uint i = 0; i < c.node_count; i++) {
			if (c.nodes[i].kind == BREAK) { break_idx = i; break; }
		}
		uint succ = c.nodes[break_idx].succ[0];
		assert(c.nodes[succ].kind == MERGE, "break -> MERGE (loop exit)");
	};
}

fn void continue_jumps_to_loop_head() @test {
	@pool() {
		String src = "fun f(x: Int) { while (x != 0) { if (x == 1) continue } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, CONTINUE) == 1, "1 continue");
		uint co_idx = 0;
		for (uint i = 0; i < c.node_count; i++) {
			if (c.nodes[i].kind == CONTINUE) { co_idx = i; break; }
		}
		uint succ = c.nodes[co_idx].succ[0];
		assert(c.nodes[succ].kind == LOOP_HEAD, "continue -> LOOP_HEAD");
	};
}

fn void when_with_two_entries_and_else() @test {
	@pool() {
		String src = "fun f(x: Int) { when (x) { 1 -> { val a = 1 } 2 -> { val b = 2 } else -> { val c = 3 } } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		// Each WHEN_ENTRY becomes a COND
		assert(count_kind(c, COND) == 3, "3 conds for 3 when entries, got %d",
			count_kind(c, COND));
		assert(count_kind(c, MERGE) == 1, "1 merge");
	};
}

fn void try_catch_creates_merge() @test {
	@pool() {
		String src = "fun f() { try { val a = 1 } catch (e: Exception) { val b = 2 } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, MERGE) >= 1, "try/catch merge");
	};
}

fn void for_loop_lowers_to_loop_head() @test {
	@pool() {
		String src = "fun f(xs: List<Int>) { for (x in xs) { val a = x } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, LOOP_HEAD) == 1, "1 for loop head");
		// LOOP_HEAD has 2 preds: iterable-statement + back-edge
		uint head_idx = 0;
		for (uint i = 0; i < c.node_count; i++) {
			if (c.nodes[i].kind == LOOP_HEAD) { head_idx = i; break; }
		}
		uint[16] buf;
		uint preds = c.predecessors(head_idx, &buf);
		assert(preds == 2, "for LOOP_HEAD has 2 preds, got %d", preds);
	};
}

fn void throw_terminates_path() @test {
	@pool() {
		String src = "fun f(x: Int): Int { if (x == 0) throw Exception(); return x }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, THROW) == 1, "1 throw");
		assert(count_kind(c, RETURN) == 1, "1 return");
	};
}

fn void nested_if_inside_loop() @test {
	@pool() {
		String src = "fun f(x: Int) { while (x != 0) { if (x == 1) { val a = 1 } else { val b = 2 } } }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);

		uint f = find_decl(pr, FUN_DECL, "f");
		Cfg* c = cfg::build_cfg(pr, f);
		defer c.free();

		assert(count_kind(c, LOOP_HEAD) == 1, "outer while");
		assert(count_kind(c, COND) == 2, "while cond + if cond, got %d", count_kind(c, COND));
	};
}
