module kls::test::expr_to_block_test;

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

// ── Probe: declared non-Unit return type → uses `return` ────────

fn void typed_int_uses_return() @test {
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

		String text = find_action_text(result, "Convert to block body");
		assert(text.len > 0, "expected action");
		assert(text.contains("{"), "expected '{' in newText, got '%s'", text);
		assert(text.contains("return 42"), "expected 'return 42', got '%s'", text);
		assert(text.contains("}"), "expected '}' in newText, got '%s'", text);
	};
}

// ── Probe: no declared type, inferred non-Unit → uses `return` ──

fn void inferred_int_uses_return() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() = 42
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to block body");
		assert(text.len > 0, "expected action");
		assert(text.contains("return 42"), "expected 'return 42', got '%s'", text);
	};
}

// ── Probe: Unit-returning expression body → no `return` ─────────

fn void unit_no_return() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() = println("x")
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to block body");
		assert(text.len > 0, "expected action");
		assert(!text.contains("return"), "should not contain 'return' for Unit body, got '%s'", text);
		assert(text.contains("println"), "expected 'println' preserved, got '%s'", text);
	};
}

// ── Probe: already block body → no action ───────────────────────

fn void already_block_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(): Int {
	return 42
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to block body");
		assert(text.len == 0, "should not offer when already block");
	};
}

// ── Probe: cursor outside fun → no action ───────────────────────

fn void cursor_outside_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`val top = 1

fun foo(): Int = 42
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to block body");
		assert(text.len == 0, "should not offer outside fun");
	};
}
