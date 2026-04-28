module kls::test::if_to_when_more_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

fn Object* make_params(String uri, int line, int col) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* start = object::new_obj(tmem);
	start.set("line", line);
	start.set("character", col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", line);
	end_pos.set("character", col);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);
	Object* diags = object::new_obj(tmem);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

fn String find_action_text(Object* result, String title) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (t == title) {
			Object* edit = action.get("edit") ?? null;
			if (edit == null) return "";
			Object* changes = edit.get("changes") ?? null;
			if (changes == null) return "";
			Object* edits = changes.get("file:///test.kt") ?? null;
			if (edits == null) return "";
			Object* e = edits.get_at(0);
			return e.get_string("newText") ?? "";
		}
	}
	return "";
}

fn String run_at(String content, int line, int col) {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, content);
	Object* params = make_params("file:///test.kt", line, col);
	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	return find_action_text(result, "Convert to when");
}

// ── Coverage extension: braceless single-line chain ────────────

fn void braceless_inline_chain_offers_action() @test {
	@pool() {
		String c = "fun f(x: Int): Int = if (x < 0) -1 else if (x == 0) 0 else 1";
		String text = run_at(c, 0, 22);
		assert(text.len > 0, "expected action for braceless chain");
		assert(text.contains("when {"), "expected subject-less when (mixed bodies), got '%s'", text);
		assert(text.contains("x < 0 -> -1"), "expected 'x < 0 -> -1' arm, got '%s'", text);
		assert(text.contains("else -> 1"), "expected 'else -> 1' arm, got '%s'", text);
	};
}

// ── Coverage extension: x in range produces subject form ───────

fn void in_range_produces_subject_form() @test {
	@pool() {
		String c = `fun f(x: Int): String {
	if (x in 1..5) {
		return "low"
	} else if (x in 6..10) {
		return "mid"
	} else {
		return "?"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0);
		assert(text.contains("when (x)"), "expected subject form, got '%s'", text);
		assert(text.contains("in 1..5 ->"), "expected 'in 1..5 ->' arm, got '%s'", text);
		assert(text.contains("in 6..10 ->"), "expected 'in 6..10 ->' arm, got '%s'", text);
	};
}

// ── Coverage extension: !is type check produces subject form ───

fn void not_is_check_produces_subject_form() @test {
	@pool() {
		String c = `fun f(x: Any): String {
	if (x !is String) {
		return "ns"
	} else if (x !is Int) {
		return "ni"
	} else {
		return "?"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0);
		assert(text.contains("when (x)"), "expected subject form, got '%s'", text);
		assert(text.contains("!is String ->"), "expected '!is String ->' arm, got '%s'", text);
		assert(text.contains("!is Int ->"), "expected '!is Int ->' arm, got '%s'", text);
	};
}

// ── Coverage extension: != null on different vars stays subject-less ──

fn void neq_null_different_vars_subject_less() @test {
	@pool() {
		String c = `fun f(x: String?, y: String?): String {
	if (x != null) {
		return "x"
	} else if (y != null) {
		return "y"
	} else {
		return "neither"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0);
		assert(text.contains("when {"), "different vars → subject-less, got '%s'", text);
		assert(text.contains("x != null ->"), "expected 'x != null ->', got '%s'", text);
		assert(text.contains("y != null ->"), "expected 'y != null ->', got '%s'", text);
	};
}

// ── Coverage extension: deep chain (5 arms) ────────────────────

fn void deep_chain_five_arms() @test {
	@pool() {
		String c = `fun f(x: Int): String {
	if (x == 1) {
		return "a"
	} else if (x == 2) {
		return "b"
	} else if (x == 3) {
		return "c"
	} else if (x == 4) {
		return "d"
	} else {
		return "e"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0);
		assert(text.contains("when (x)"));
		assert(text.contains("1 ->"));
		assert(text.contains("2 ->"));
		assert(text.contains("3 ->"));
		assert(text.contains("4 ->"));
		assert(text.contains("else ->"));
	};
}

// ── Coverage extension: cursor on else-if branch promotes to top ──

fn void cursor_on_else_if_promotes_to_top() @test {
	@pool() {
		String c = `fun f(x: Int): String {
	if (x < 0) {
		return "neg"
	} else if (x == 0) {
		return "zero"
	} else {
		return "pos"
	}
}`;
		String text = run_at(c, 3, 4);
		assert(text.len > 0, "cursor on else-if should still trigger via top_of_if_chain");
		assert(text.contains("x < 0 ->"), "expected outer arm in output, got '%s'", text);
	};
}

// ── Coverage extension: nested if in body kept verbatim ────────

fn void nested_if_in_body_preserved() @test {
	@pool() {
		String c = `fun f(x: Int, y: Int): String {
	if (x < 0) {
		if (y < 0) return "nn"
		return "n"
	} else if (x == 0) {
		return "z"
	} else {
		return "p"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0);
		assert(text.contains("if (y < 0)"), "nested if should be preserved in body, got '%s'", text);
	};
}

// ── New feature: disjunction collapses to comma-list under same subject ──

fn void disjunction_same_subject_collapses() @test {
	@pool() {
		String c = `fun f(x: Int): String {
	if (x == 1 || x == 2) {
		return "low"
	} else if (x == 3) {
		return "mid"
	} else {
		return "?"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0);
		assert(text.contains("when (x)"), "shared subject expected, got '%s'", text);
		assert(text.contains("1, 2 ->"), "disjunction should collapse to '1, 2 ->', got '%s'", text);
	};
}

// ── Bug fix: refuse refactor when comment lives between arms ───

fn void refuses_when_comment_between_arms() @test {
	@pool() {
		String c = `fun f(x: Int): String {
	if (x < 0) {
		return "neg"
	}
	// classify zero
	else if (x == 0) {
		return "zero"
	} else {
		return "pos"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len == 0, "refactor should refuse to avoid dropping inter-arm comment, got '%s'", text);
	};
}

// ── Bug fix: still refactors when comment is INSIDE a body ─────

fn void refactors_when_comment_inside_body() @test {
	@pool() {
		String c = `fun f(x: Int): String {
	if (x < 0) {
		// negative case
		return "neg"
	} else if (x == 0) {
		return "zero"
	} else {
		return "pos"
	}
}`;
		String text = run_at(c, 1, 2);
		assert(text.len > 0, "comment inside body span should not block refactor");
		assert(text.contains("// negative case"), "comment in body should be preserved, got '%s'", text);
	};
}

// ── Top-level chain (val initializer) ──────────────────────────

fn void top_level_val_chain() @test {
	@pool() {
		String c = `val x = 5
val y = if (x == 1) "a" else if (x == 2) "b" else "c"`;
		String text = run_at(c, 1, 8);
		assert(text.len > 0, "top-level chain should be supported");
		assert(text.contains("when (x)"));
		assert(text.contains("1 -> \"a\""));
	};
}
