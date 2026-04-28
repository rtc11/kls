module kls::test::if_to_when_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

// Local helper -- mirrors make_extract_params in code_actions_test.c3
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

// ── Probe: chain with else-if + else offers Convert to when ─────

fn void if_chain_offers_convert_to_when() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun classify(x: Int): String {
	if (x < 0) {
		return "neg"
	} else if (x == 0) {
		return "zero"
	} else {
		return "pos"
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "if (x < 0)" line (line 1, col 2 -- inside the 'if' keyword)
		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to when");
		assert(text.len > 0, "expected 'Convert to when' action");
		assert(text.contains("when {"), "expected 'when {' in newText, got '%s'", text);
		assert(text.contains("else ->"), "expected 'else ->' arm, got '%s'", text);
		assert(text.contains("x < 0 ->"), "expected 'x < 0 ->' arm, got '%s'", text);
		assert(text.contains("x == 0 ->"), "expected 'x == 0 ->' arm, got '%s'", text);
	};
}

// ── Probe: chain without else still offers (≥ 2 conditions) ─────

fn void if_chain_no_else_offers_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(x: Int) {
	if (x < 0) {
		println("neg")
	} else if (x == 0) {
		println("zero")
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to when");
		assert(text.len > 0, "expected action even without terminal else");
		assert(!text.contains("else ->"), "should not have 'else ->' arm when no terminal else, got '%s'", text);
	};
}

// ── Probe: simple if (no else-if) → no action ───────────────────

fn void simple_if_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(x: Int) {
	if (x > 0) {
		println("pos")
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to when");
		assert(text.len == 0, "should not offer convert for simple if");
	};
}

// ── Probe: subject form for `x is A` chain ──────────────────────

fn void if_chain_is_check_subject_form() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun describe(x: Any): String {
	if (x is String) {
		return "str"
	} else if (x is Int) {
		return "int"
	} else {
		return "?"
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to when");
		assert(text.len > 0, "expected action");
		assert(text.contains("when (x)"), "expected subject form 'when (x)', got '%s'", text);
		assert(text.contains("is String ->"), "expected 'is String ->' arm, got '%s'", text);
		assert(text.contains("is Int ->"), "expected 'is Int ->' arm, got '%s'", text);
		assert(text.contains("else ->"), "expected 'else ->' arm, got '%s'", text);
	};
}

// ── Probe: subject form for `x == lit` chain ────────────────────

fn void if_chain_eq_literal_subject_form() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun pick(x: Int): String {
	if (x == 1) {
		return "one"
	} else if (x == 2) {
		return "two"
	} else {
		return "other"
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to when");
		assert(text.len > 0, "expected action");
		assert(text.contains("when (x)"), "expected subject form 'when (x)', got '%s'", text);
		assert(text.contains("1 ->"), "expected '1 ->' arm, got '%s'", text);
		assert(text.contains("2 ->"), "expected '2 ->' arm, got '%s'", text);
	};
}

// ── Probe: mixed subjects → falls back to subject-less form ─────

fn void if_chain_mixed_subjects_fallback() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(x: Any, y: Any) {
	if (x is String) {
		println("xs")
	} else if (y is Int) {
		println("yi")
	} else {
		println("?")
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to when");
		assert(text.len > 0, "expected action");
		// Should be subject-less since subjects differ
		assert(!text.contains("when (x)"), "expected NO subject (mixed), got '%s'", text);
		assert(!text.contains("when (y)"), "expected NO subject (mixed), got '%s'", text);
		assert(text.contains("when {"), "expected subject-less 'when {', got '%s'", text);
	};
}
