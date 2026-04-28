module kls::test::redund_else_quickfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

fn Object* make_diag(int line, int col, String message) {
	Object* d = object::new_obj(tmem);
	Object* range = object::new_obj(tmem);
	Object* start = object::new_obj(tmem);
	start.set("line", line);
	start.set("character", col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", line);
	end_pos.set("character", col + 4);
	range.set("start", start);
	range.set("end", end_pos);
	d.set("range", range);
	d.set("message", message);
	return d;
}

fn Object* make_params(String uri, Object* diag) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* start = object::new_obj(tmem);
	start.set("line", 0);
	start.set("character", 0);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", 0);
	end_pos.set("character", 0);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* diags = object::new_obj(tmem);
	if (diag != null) diags.push(diag);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

fn Object* find_action(Object* result, String title) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (t == title) return action;
	}
	return null;
}

fn String find_action_text(Object* result, String title) {
	Object* a = find_action(result, title);
	if (a == null) return "<NO_ACTION>";
	Object* edit = a.get("edit") ?? null;
	if (edit == null) return "<NO_EDIT>";
	Object* changes = edit.get("changes") ?? null;
	if (changes == null) return "<NO_CHANGES>";
	Object* edits = changes.get("file:///test.kt") ?? null;
	if (edits == null) return "<NO_EDITS>";
	Object* e = edits.get_at(0);
	return e.get_string("newText") ?? "<NO_NEW_TEXT>";
}

fn void quickfix_removes_else_arm() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Layout (0-indexed lines):
		// 0: "fun pick(c: Int): Int {"
		// 1: "    return when (c) {"
		// 2: "        1 -> 1"
		// 3: "        else -> 0"      ← else at col 8
		// 4: "    }"
		// 5: "}"
		String content =
`fun pick(c: Int): Int {
    return when (c) {
        1 -> 1
        else -> 0
    }
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Diagnostic at line 3, col 8 (start of "else")
		Object* diag = make_diag(3, 8,
			"'else' is redundant — 'when' is already exhaustive over 'X'");
		Object* params = make_params("file:///test.kt", diag);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Remove redundant else");
		// Should delete the entire else line (newText empty)
		assert(text == "", "expected empty newText, got '%s'", text);
	};
}

fn void quickfix_only_for_else_redundant_message() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun pick(c: Int): Int {
    return when (c) {
        1 -> 1
        else -> 0
    }
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Diagnostic with unrelated message → no quickfix
		Object* diag = make_diag(3, 8, "Some other diagnostic");
		Object* params = make_params("file:///test.kt", diag);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		Object* a = find_action(result, "Remove redundant else");
		assert(a == null, "should not offer quickfix for unrelated diagnostic");
	};
}

fn String find_edit_range_str(Object* result, String title) {
	Object* a = find_action(result, title);
	if (a == null) return "";
	Object* edit = a.get("edit") ?? null;
	if (edit == null) return "";
	Object* changes = edit.get("changes") ?? null;
	if (changes == null) return "";
	Object* edits = changes.get("file:///test.kt") ?? null;
	if (edits == null) return "";
	Object* e = edits.get_at(0);
	Object* range = e.get("range") ?? null;
	if (range == null) return "";
	Object* s = range.get("start")!!;
	Object* en = range.get("end")!!;
	int sl = (int)(s.get_int("line") ?? -1);
	int sc = (int)(s.get_int("character") ?? -1);
	int el = (int)(en.get_int("line") ?? -1);
	int ec = (int)(en.get_int("character") ?? -1);
	return string::tformat("%d:%d-%d:%d", sl, sc, el, ec);
}

fn void quickfix_edit_range_drops_full_line() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun pick(c: Int): Int {
    return when (c) {
        1 -> 1
        else -> 0
    }
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diag = make_diag(3, 8,
			"'else' is redundant — 'when' is already exhaustive over 'X'");
		Object* params = make_params("file:///test.kt", diag);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Range should span the full else line:
		// from start of line 3 (col 0) to start of line 4 (col 0)
		String r = find_edit_range_str(result, "Remove redundant else");
		assert(r == "3:0-4:0", "expected full-line range '3:0-4:0', got '%s'", r);
	};
}
