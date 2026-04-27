module kls::test::when_to_if_test;

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

// ── Probe: subject-less when → if-chain ────────────────────────

fn void subjectless_when_to_if() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(x: Int) {
	when {
		x < 0 -> println("neg")
		x == 0 -> println("zero")
		else -> println("pos")
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to if-chain");
		assert(text.len > 0, "expected 'Convert to if-chain' action");
		assert(text.contains("if (x < 0)"), "expected 'if (x < 0)', got '%s'", text);
		assert(text.contains("else if (x == 0)"), "expected 'else if (x == 0)', got '%s'", text);
		assert(text.contains("else {"), "expected terminal 'else {', got '%s'", text);
	};
}

// ── Probe: subject form `is T` → `x is T` ──────────────────────

fn void subject_when_is_to_if() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun describe(x: Any): String {
	when (x) {
		is String -> return "str"
		is Int -> return "int"
		else -> return "?"
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to if-chain");
		assert(text.len > 0, "expected action");
		assert(text.contains("if (x is String)"), "expected 'if (x is String)', got '%s'", text);
		assert(text.contains("else if (x is Int)"), "expected 'else if (x is Int)', got '%s'", text);
		assert(text.contains("else {"), "expected terminal else, got '%s'", text);
	};
}

// ── Probe: subject form literal → `x == lit` ───────────────────

fn void subject_when_lit_to_if() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun pick(x: Int): String {
	when (x) {
		1 -> return "one"
		2 -> return "two"
		else -> return "other"
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to if-chain");
		assert(text.len > 0, "expected action");
		assert(text.contains("if (x == 1)"), "expected 'if (x == 1)', got '%s'", text);
		assert(text.contains("else if (x == 2)"), "expected 'else if (x == 2)', got '%s'", text);
	};
}

// ── Probe: `when (val x = ...)` binding → no action ────────────

fn void when_val_binding_no_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo(): Int {
	when (val r = compute()) {
		1 -> return 10
		else -> return 20
	}
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 2);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Convert to if-chain");
		assert(text.len == 0, "should not offer for when-binding form, got '%s'", text);
	};
}
