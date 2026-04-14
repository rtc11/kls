module kls::test::formatting_test;

import std::collections::object;
import kls::document;
import kls::lsp::formatting;

// ── Helpers ──────────────────────────────────────────────────────

fn Object* make_params(String uri, int tab_size, bool insert_spaces) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* opts = object::new_obj(tmem);
	opts.set("tabSize", tab_size);
	opts.set("insertSpaces", insert_spaces);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("options", opts);
	return params;
}

fn Object* make_params_defaults(String uri) {
	return make_params(uri, 4, true);
}

/**
 * Extract the newText from the first TextEdit in the result array.
 * Returns empty string if result is null or empty.
 */
fn String get_new_text(Object* result) {
	if (result == null) return "";
	if (result.get_len() == 0) return "";
	Object* edit = result.get_at(0);
	return edit.get_string("newText")!!;
}

// ── Unknown document ─────────────────────────────────────────────

fn void unknown_document_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params_defaults("file:///unknown.kt");
		Object* result = formatting::handle_formatting(&store, params);
		assert(result == null, "expected null for unknown document");
	};
}

// ── No changes needed ────────────────────────────────────────────

fn void already_formatted_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}\n");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);
		assert(result == null, "expected null when no changes needed");
	};
}

// ── Final newline ────────────────────────────────────────────────

fn void adds_final_newline() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {}\n",
			"expected final newline, got '%s'", new_text);
	};
}

fn void empty_file_gets_newline() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits for empty file");
		String new_text = get_new_text(result);
		assert(new_text == "\n", "expected single newline, got '%s'", new_text);
	};
}

// ── Trailing whitespace ──────────────────────────────────────────

fn void removes_trailing_spaces() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 1   \nval y = 2\t\n");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "val x = 1\nval y = 2\n",
			"expected trailing whitespace removed, got '%s'", new_text);
	};
}

fn void blank_line_trailing_spaces() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {\n    \n}\n");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {\n\n}\n",
			"expected blank line cleaned, got '%s'", new_text);
	};
}

// ── Indentation normalization ────────────────────────────────────

fn void tabs_to_spaces() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {\n\tval x = 1\n}\n");
		Object* params = make_params("file:///test.kt", 4, true); // insertSpaces=true
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {\n    val x = 1\n}\n",
			"expected tab converted to 4 spaces, got '%s'", new_text);
	};
}

fn void spaces_to_tabs() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {\n    val x = 1\n}\n");
		Object* params = make_params("file:///test.kt", 4, false); // insertSpaces=false
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {\n\tval x = 1\n}\n",
			"expected 4 spaces converted to tab, got '%s'", new_text);
	};
}

fn void tab_size_2() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {\n\tval x = 1\n}\n");
		Object* params = make_params("file:///test.kt", 2, true); // tabSize=2
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {\n  val x = 1\n}\n",
			"expected tab converted to 2 spaces, got '%s'", new_text);
	};
}

fn void mixed_indent_normalized() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Tab + 2 spaces = 6 columns with tabSize=4, normalized to 6 spaces
		store.open("file:///test.kt", "kotlin", 1, "fun main() {\n\t  val x = 1\n}\n");
		Object* params = make_params("file:///test.kt", 4, true);
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {\n      val x = 1\n}\n",
			"expected mixed indent normalized to 6 spaces, got '%s'", new_text);
	};
}

// ── Blank line collapsing ────────────────────────────────────────

fn void collapses_excessive_blank_lines() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			"fun foo() {}\n\n\n\n\nfun bar() {}\n");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun foo() {}\n\n\nfun bar() {}\n",
			"expected 3+ blank lines collapsed to 2, got '%s'", new_text);
	};
}

fn void two_blank_lines_preserved() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			"fun foo() {}\n\n\nfun bar() {}\n");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		// 2 blank lines = exactly 2 consecutive empty lines, should be preserved
		assert(result == null, "expected no changes for 2 blank lines");
	};
}

// ── Trailing blank lines ─────────────────────────────────────────

fn void trims_trailing_blank_lines() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			"fun main() {}\n\n\n\n");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "fun main() {}\n",
			"expected trailing blank lines trimmed, got '%s'", new_text);
	};
}

// ── TextEdit range ───────────────────────────────────────────────

fn void edit_covers_whole_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 1   ");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		assert(result.get_len() == 1, "expected 1 edit, got %d", (int)result.get_len());

		Object* edit = result.get_at(0);
		Object* range = edit.get("range")!!;
		Object* start = range.get("start")!!;
		Object* end = range.get("end")!!;

		int start_line = start.get_int("line")!!;
		int start_char = start.get_int("character")!!;
		assert(start_line == 0 && start_char == 0,
			"expected start 0:0, got %d:%d", start_line, start_char);

		int end_line = end.get_int("line")!!;
		int end_char = end.get_int("character")!!;
		assert(end_line == 0 && end_char == 12,
			"expected end 0:12, got %d:%d", end_line, end_char);
	};
}

fn void multiline_edit_range() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "line1\nline2\nline3  ");
		Object* params = make_params_defaults("file:///test.kt");
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");

		Object* edit = result.get_at(0);
		Object* range = edit.get("range")!!;
		Object* end = range.get("end")!!;
		int end_line = end.get_int("line")!!;
		int end_char = end.get_int("character")!!;
		assert(end_line == 2, "expected end line 2, got %d", end_line);
		assert(end_char == 7, "expected end char 7, got %d", end_char);
	};
}

// ── Combined formatting ──────────────────────────────────────────

fn void combined_formatting() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Multiple issues: trailing ws, tab indent, missing final newline, excess blank lines
		store.open("file:///test.kt", "kotlin", 1,
			"package com.example  \n\nimport foo.Bar\n\n\n\n\nfun main() {\n\tprintln(\"hello\")   \n}");
		Object* params = make_params("file:///test.kt", 4, true);
		Object* result = formatting::handle_formatting(&store, params);

		assert(result != null, "expected edits");
		String new_text = get_new_text(result);
		assert(new_text == "package com.example\n\nimport foo.Bar\n\n\nfun main() {\n    println(\"hello\")\n}\n",
			"combined formatting failed, got '%s'", new_text);
	};
}
