module kls::test::add_return_type_test;

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

// ── Probe: expression body returning Int ────────────────────────

fn void expr_body_int_offers_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() = 42
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on 'foo' (line 0, col 4)
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add return type");
		assert(text.len > 0, "expected 'Add return type' action");
		assert(text.contains("Int"), "expected 'Int' in newText, got '%s'", text);
	};
}

// ── Probe: expression body returning String ─────────────────────

fn void expr_body_string_offers_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun greet() = "hi"
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add return type");
		assert(text.len > 0, "expected action");
		assert(text.contains("String"), "expected 'String', got '%s'", text);
	};
}

// ── Probe: explicit return type already present → no action ─────

fn void already_typed_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(): Int = 42
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add return type");
		assert(text.len == 0, "should not offer when already typed");
	};
}

// ── Probe: Unit-returning function → no action ──────────────────

fn void unit_returning_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	println("hi")
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add return type");
		assert(text.len == 0, "should not offer for Unit-returning fun");
	};
}

// ── Probe: cursor outside any function → no action ──────────────

fn void cursor_outside_fun_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`val top = 1

fun foo() = 42
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on top-level val
		Object* params = make_params("file:///test.kt", 0, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Add return type");
		assert(text.len == 0, "should not offer outside fun");
	};
}
