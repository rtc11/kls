module kls::test::surround_try_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

// ── Helpers ──────────────────────────────────────────────────────

fn Object* make_selection_params(String uri, int start_line, int start_col, int end_line, int end_col) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* start = object::new_obj(tmem);
	start.set("line", start_line);
	start.set("character", start_col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", end_line);
	end_pos.set("character", end_col);
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

fn Object* find_action_titled(Object* actions, String title) {
	usz n = actions.get_len();
	for (usz i = 0; i < n; i++) {
		Object* a = actions.get_at(i);
		String t = a.get_string("title") ?? "";
		if (t == title) return a;
	}
	return null;
}

// ── Tests ────────────────────────────────────────────────────────

fn void surround_single_statement_emits_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Line 0: fun foo() {
		// Line 1:     val x = doStuff()
		// Line 2: }
		String src =
`fun foo() {
    val x = doStuff()
}`;
		String uri = "file:///t.kt";
		store.open(uri, "kotlin", 1, src);

		// Select the entire `val x = doStuff()` text on line 1
		Object* params = make_selection_params(uri, 1, 4, 1, 21);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_titled(result, "Surround with try/catch");
		assert(action != null, "expected 'Surround with try/catch' action");

		String kind = action.get_string("kind")!!;
		assert(kind == "refactor.rewrite", "expected kind refactor.rewrite");

		Object* edit = action.get("edit")!!;
		Object* edits = edit.get("changes")!!.get(uri)!!;
		assert(edits.get_len() == 1, "expected one edit");

		String new_text = edits.get_at(0).get_string("newText")!!;
		assert(new_text.contains("try {"), "must contain try {");
		assert(new_text.contains("catch (e: Exception)"), "must contain catch clause");
		assert(new_text.contains("val x = doStuff()"), "must preserve selected statement");
		assert(new_text.contains("TODO"), "must contain TODO placeholder");
	};
}

fn void surround_empty_selection_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src =
`fun foo() {
    val x = doStuff()
}`;
		String uri = "file:///t.kt";
		store.open(uri, "kotlin", 1, src);

		// Empty selection (cursor only)
		Object* params = make_selection_params(uri, 1, 4, 1, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_titled(result, "Surround with try/catch");
		assert(action == null, "must not offer surround for empty selection");
	};
}

fn void surround_outside_block_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Top-level val (not in a block) — shouldn't be wrappable
		String src =
`val topLevel = 42
fun foo() {}`;
		String uri = "file:///t.kt";
		store.open(uri, "kotlin", 1, src);

		// Select "topLevel" on line 0
		Object* params = make_selection_params(uri, 0, 4, 0, 12);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_titled(result, "Surround with try/catch");
		assert(action == null, "must not offer surround at top level");
	};
}

fn void surround_multiline_selection_indents_inner() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src =
`fun foo() {
    val a = 1
    val b = 2
}`;
		String uri = "file:///t.kt";
		store.open(uri, "kotlin", 1, src);

		// Select both val lines (line 1 col 4 .. line 2 col 13)
		Object* params = make_selection_params(uri, 1, 4, 2, 13);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_titled(result, "Surround with try/catch");
		assert(action != null, "expected action for multiline selection");

		String new_text = action.get("edit")!!.get("changes")!!.get(uri)!!
			.get_at(0).get_string("newText")!!;
		// Both statements survive
		assert(new_text.contains("val a = 1"), "preserves first stmt");
		assert(new_text.contains("val b = 2"), "preserves second stmt");
		// Inner indent: base 4 + extra 4 = 8 spaces before val a
		assert(new_text.contains("        val a = 1"), "indents inner first line to 8 spaces");
		assert(new_text.contains("        val b = 2"), "indents inner second line to 8 spaces");
	};
}
