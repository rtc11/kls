module kls::test::remove_not_null_quickfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

fn Object* make_diag(int line, int col_start, int col_end, String message) {
	Object* d = object::new_obj(tmem);
	Object* range = object::new_obj(tmem);
	Object* start = object::new_obj(tmem);
	start.set("line", line);
	start.set("character", col_start);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", line);
	end_pos.set("character", col_end);
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

fn String find_action_text(Object* result, String title) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (t == title) {
			Object* edit = action.get("edit") ?? null;
			if (edit == null) return "<no-edit>";
			Object* changes = edit.get("changes") ?? null;
			if (changes == null) return "<no-changes>";
			Object* edits = changes.get("file:///test.kt") ?? null;
			if (edits == null) return "<no-edits>";
			Object* e = edits.get_at(0);
			return e.get_string("newText") ?? "<no-text>";
		}
	}
	return "";
}

fn void remove_not_null_quickfix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun foo() {
	val x: String = "hi"
	println(x!!)
}
`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Diagnostic at the `!!` location: line 2, cols 11..13 (after 'x' inside println)
		Object* diag = make_diag(2, 11, 13, "Unnecessary '!!' on non-null value");
		Object* params = make_params("file:///test.kt", diag);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		String text = find_action_text(result, "Remove '!!'");
		assert(text == "", "expected empty newText replacing '!!', got '%s'", text);
	};
}
