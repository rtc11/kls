module kls::test::add_explicit_type_test;

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

// ── Probe: val with int literal offers action ───────────────────

fn void val_int_literal_offers_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	val x = 42
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor inside `val x = 42` (line 1, col 5 -- on 'x')
		Object* params = make_params("file:///test.kt", 1, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add explicit type");
		assert(text.len > 0, "expected 'Add explicit type' action");
		assert(text.contains("Int"), "expected 'Int' in newText, got '%s'", text);
	};
}

// ── Probe: val with string literal ──────────────────────────────

fn void val_string_literal_offers_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	val s = "hi"
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add explicit type");
		assert(text.len > 0, "expected action");
		assert(text.contains("String"), "expected 'String' in newText, got '%s'", text);
	};
}

// ── Probe: explicit type already present → no action ────────────

fn void val_already_typed_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	val x: Int = 42
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add explicit type");
		assert(text.len == 0, "should not offer action when type is explicit");
	};
}

// ── Probe: destructuring → no action ────────────────────────────

fn void destructuring_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	val (a, b) = Pair(1, 2)
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add explicit type");
		assert(text.len == 0, "should not offer action for destructuring");
	};
}

// ── Probe: cursor outside any property → no action ──────────────

fn void cursor_outside_property_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	val x = 42
	println(x)
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on println line
		Object* params = make_params("file:///test.kt", 2, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add explicit type");
		assert(text.len == 0, "should not offer action outside property");
	};
}
