module kls::test::rename_test;

import std::collections::object;
import kls::document;
import kls::lsp::rename;

// ── Helper: build params for prepareRename ─────────────────────────

fn Object* make_prepare_params(String uri, int line, int character) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	return params;
}

// ── Helper: build params for rename ────────────────────────────────

fn Object* make_rename_params(String uri, int line, int character, String new_name) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	params.set("newName", new_name);
	return params;
}

// ── Helper: extract edit info from changes ─────────────────────────

fn Object* get_edits_for_uri(Object* workspace_edit, String uri) {
	Object* changes = workspace_edit.get("changes")!!;
	return changes.get(uri) ?? null;
}

fn int get_edit_line(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	Object* range = edit.get("range")!!;
	Object* start = range.get("start")!!;
	return start.get_int("line")!!;
}

fn int get_edit_col(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	Object* range = edit.get("range")!!;
	Object* start = range.get("start")!!;
	return start.get_int("character")!!;
}

fn int get_edit_end_col(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	Object* range = edit.get("range")!!;
	Object* end_pos = range.get("end")!!;
	return end_pos.get_int("character")!!;
}

fn String get_edit_new_text(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	return edit.get_string("newText")!!;
}

// ── prepareRename: identifier returns range + placeholder ──────────

fn void prepare_rename_on_identifier() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		// Cursor on "greet" at line 0, col 4
		Object* params = make_prepare_params("file:///test.kt", 0, 4);
		Object* result = rename::handle_prepare_rename(&store, params);

		assert(result != null, "expected prepare rename result");

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		assert(start.get_int("line")!! == 0, "expected line 0");
		assert(start.get_int("character")!! == 4, "expected start col 4");

		Object* end_pos = range.get("end")!!;
		assert(end_pos.get_int("character")!! == 9, "expected end col 9");

		String placeholder = result.get_string("placeholder")!!;
		assert(placeholder == "greet", "expected placeholder 'greet', got '%s'", placeholder);
	};
}

// ── prepareRename: keyword returns null ─────────────────────────────

fn void prepare_rename_on_keyword() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		// Cursor on "fun" keyword at col 0
		Object* params = make_prepare_params("file:///test.kt", 0, 0);
		Object* result = rename::handle_prepare_rename(&store, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── prepareRename: unknown document returns null ────────────────────

fn void prepare_rename_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_prepare_params("file:///unknown.kt", 0, 0);
		Object* result = rename::handle_prepare_rename(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Rename function: declaration + call site ────────────────────────

fn void rename_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in the call at line 1, col 14
		Object* params = make_rename_params("file:///test.kt", 1, 14, "hello");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

		// First edit: declaration "greet" at line 0, col 4
		assert(get_edit_line(edits, 0) == 0, "expected edit 0 at line 0");
		assert(get_edit_col(edits, 0) == 4, "expected edit 0 at col 4");
		assert(get_edit_end_col(edits, 0) == 9, "expected edit 0 end col 9");
		assert(get_edit_new_text(edits, 0) == "hello", "expected newText 'hello'");

		// Second edit: call "greet" at line 1, col 13
		assert(get_edit_line(edits, 1) == 1, "expected edit 1 at line 1");
		assert(get_edit_col(edits, 1) == 13, "expected edit 1 at col 13");
		assert(get_edit_end_col(edits, 1) == 18, "expected edit 1 end col 18");
		assert(get_edit_new_text(edits, 1) == "hello", "expected newText 'hello'");
	};
}

// ── Rename variable: declaration + usage ────────────────────────────

fn void rename_variable() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 42\nval y = x + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 1, col 8 (usage)
		Object* params = make_rename_params("file:///test.kt", 1, 8, "count");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

		// Declaration at line 0, col 4
		assert(get_edit_line(edits, 0) == 0, "expected edit 0 at line 0");
		assert(get_edit_col(edits, 0) == 4, "expected edit 0 at col 4");
		assert(get_edit_new_text(edits, 0) == "count");

		// Usage at line 1, col 8
		assert(get_edit_line(edits, 1) == 1, "expected edit 1 at line 1");
		assert(get_edit_col(edits, 1) == 8, "expected edit 1 at col 8");
		assert(get_edit_new_text(edits, 1) == "count");
	};
}

// ── Rename class: declaration + type usage + constructor ────────────

fn void rename_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Foo {}\nfun make(): Foo = Foo()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 0, col 6 (declaration)
		Object* params = make_rename_params("file:///test.kt", 0, 6, "Bar");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "Foo" appears 3 times: class Foo, : Foo, Foo()
		assert(edits.get_len() == 3, "expected 3 edits, got %d", (int)edits.get_len());

		// All edits should have newText "Bar"
		assert(get_edit_new_text(edits, 0) == "Bar");
		assert(get_edit_new_text(edits, 1) == "Bar");
		assert(get_edit_new_text(edits, 2) == "Bar");

		// Declaration at line 0, col 6
		assert(get_edit_line(edits, 0) == 0);
		assert(get_edit_col(edits, 0) == 6);

		// Return type at line 1, col 12
		assert(get_edit_line(edits, 1) == 1);
		assert(get_edit_col(edits, 1) == 12);

		// Constructor call at line 1, col 18
		assert(get_edit_line(edits, 2) == 1);
		assert(get_edit_col(edits, 2) == 18);
	};
}

// ── Rename parameter ────────────────────────────────────────────────

fn void rename_parameter() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun add(a: Int, b: Int): Int = a + b";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "a" at line 0, col 31 (usage in expression)
		Object* params = make_rename_params("file:///test.kt", 0, 31, "first");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "a" appears twice: parameter declaration and usage in body
		assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

		assert(get_edit_new_text(edits, 0) == "first");
		assert(get_edit_new_text(edits, 1) == "first");

		// Parameter at col 8, usage at col 31
		assert(get_edit_col(edits, 0) == 8, "expected param at col 8, got %d", get_edit_col(edits, 0));
		assert(get_edit_col(edits, 1) == 31, "expected usage at col 31, got %d", get_edit_col(edits, 1));
	};
}

// ── Rename on keyword returns null ──────────────────────────────────

fn void rename_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

		// Cursor on "fun" keyword at col 0
		Object* params = make_rename_params("file:///test.kt", 0, 0, "function");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for keyword rename");
	};
}

// ── Rename with same name returns null ──────────────────────────────

fn void rename_same_name_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		// Rename "greet" to "greet" (same name)
		Object* params = make_rename_params("file:///test.kt", 0, 4, "greet");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for same-name rename");
	};
}

// ── Rename unknown document returns null ─────────────────────────────

fn void rename_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_rename_params("file:///unknown.kt", 0, 0, "newName");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Rename with multiple references in same file ────────────────────

fn void rename_multiple_references() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun calc(x: Int): Int {\n    val y = x * 2\n    return x + y\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 0, col 9 (parameter declaration)
		Object* params = make_rename_params("file:///test.kt", 0, 9, "value");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "x" appears 3 times: param decl, usage in y = x * 2, usage in return x + y
		assert(edits.get_len() == 3, "expected 3 edits, got %d", (int)edits.get_len());

		// All edits should have newText "value"
		assert(get_edit_new_text(edits, 0) == "value");
		assert(get_edit_new_text(edits, 1) == "value");
		assert(get_edit_new_text(edits, 2) == "value");
	};
}

// ── Rename only targets matching identifiers ────────────────────────

fn void rename_does_not_affect_other_identifiers() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val foo = 1\nval fooBar = 2\nval result = foo + fooBar";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "foo" at line 0, col 4
		Object* params = make_rename_params("file:///test.kt", 0, 4, "baz");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "foo" exact match: declaration at line 0, usage at line 2 col 13
		// "fooBar" should NOT be affected (different identifier)
		assert(edits.get_len() == 2, "expected 2 edits (not fooBar), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 0);
		assert(get_edit_col(edits, 0) == 4);

		assert(get_edit_line(edits, 1) == 2);
		assert(get_edit_col(edits, 1) == 13, "expected usage at col 13, got %d", get_edit_col(edits, 1));
	};
}

// ── prepareRename on variable in expression ─────────────────────────

fn void prepare_rename_on_variable_in_expression() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val count = 0\nval next = count + 1");

		// Cursor on "count" at line 1, col 11 (usage in expression)
		Object* params = make_prepare_params("file:///test.kt", 1, 11);
		Object* result = rename::handle_prepare_rename(&store, params);

		assert(result != null, "expected prepare rename result");

		String placeholder = result.get_string("placeholder")!!;
		assert(placeholder == "count", "expected placeholder 'count', got '%s'", placeholder);

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		assert(start.get_int("line")!! == 1);
		assert(start.get_int("character")!! == 11);

		Object* end_pos = range.get("end")!!;
		assert(end_pos.get_int("character")!! == 16, "expected end col 16, got %d", end_pos.get_int("character")!!);
	};
}

// ── Rename interface ────────────────────────────────────────────────

fn void rename_interface() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "interface Drawable {\n    fun draw()\n}\nclass Circle : Drawable {\n    override fun draw() {}\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Drawable" at line 0, col 10 (declaration)
		Object* params = make_rename_params("file:///test.kt", 0, 10, "Renderable");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "Drawable" appears twice: interface decl and supertype
		assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

		assert(get_edit_new_text(edits, 0) == "Renderable");
		assert(get_edit_new_text(edits, 1) == "Renderable");

		// Declaration at line 0, col 10
		assert(get_edit_line(edits, 0) == 0);
		assert(get_edit_col(edits, 0) == 10);

		// Supertype at line 3, col 15
		assert(get_edit_line(edits, 1) == 3);
		assert(get_edit_col(edits, 1) == 15);
	};
}

// ── Rename single declaration with no usages ────────────────────────

fn void rename_declaration_only() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun unused() {}");

		// Cursor on "unused" at line 0, col 4
		Object* params = make_rename_params("file:///test.kt", 0, 4, "notUsed");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		assert(edits.get_len() == 1, "expected 1 edit, got %d", (int)edits.get_len());

		assert(get_edit_col(edits, 0) == 4);
		assert(get_edit_new_text(edits, 0) == "notUsed");
	};
}

// ── Rename does not touch package path identifiers ──────────────────

fn void rename_skips_package_path() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "package com.example.model\nval model = 42\nval x = model + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "model" at line 1, col 4 (the variable declaration)
		Object* params = make_rename_params("file:///test.kt", 1, 4, "info");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "model" in package path should be skipped, only val decl + usage
		assert(edits.get_len() == 2, "expected 2 edits (skip package), got %d", (int)edits.get_len());

		// val data at line 1
		assert(get_edit_line(edits, 0) == 1);
		assert(get_edit_col(edits, 0) == 4);
		assert(get_edit_new_text(edits, 0) == "info");

		// usage at line 2
		assert(get_edit_line(edits, 1) == 2);
		assert(get_edit_col(edits, 1) == 8);
		assert(get_edit_new_text(edits, 1) == "info");
	};
}

// ── Rename does not touch import path identifiers ───────────────────

fn void rename_skips_import_path() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "import com.example.Foo\nclass Foo {}\nfun make(): Foo = Foo()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 1, col 6 (class declaration)
		Object* params = make_rename_params("file:///test.kt", 1, 6, "Bar");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "Foo" in import path should be skipped: class Foo, : Foo, Foo()
		assert(edits.get_len() == 3, "expected 3 edits (skip import), got %d", (int)edits.get_len());

		// class Foo at line 1, col 6
		assert(get_edit_line(edits, 0) == 1);
		assert(get_edit_col(edits, 0) == 6);

		// return type Foo at line 2
		assert(get_edit_line(edits, 1) == 2);

		// constructor Foo() at line 2
		assert(get_edit_line(edits, 2) == 2);
	};
}

// ── Rename does not touch wildcard import path ──────────────────────

fn void rename_skips_wildcard_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "import com.example.*\nval example = 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "example" at line 1, col 4
		Object* params = make_rename_params("file:///test.kt", 1, 4, "sample");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// "example" in import path should be skipped
		assert(edits.get_len() == 1, "expected 1 edit (skip import), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 1);
		assert(get_edit_col(edits, 0) == 4);
	};
}

// ═══════════════════════════════════════════════════════════════════
// Scope-aware rename tests
// ═══════════════════════════════════════════════════════════════════

// ── Same variable name in different functions: only rename one ──────

fn void rename_scoped_to_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() {\n    val x = 1\n    println(x)\n}\nfun bar() {\n    val x = 2\n    println(x)\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 1, col 8 (val x in foo)
		Object* params = make_rename_params("file:///test.kt", 1, 8, "value");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Only "x" inside foo() should be renamed (declaration + usage),
		// not the "x" inside bar()
		assert(edits.get_len() == 2, "expected 2 edits (foo only), got %d", (int)edits.get_len());

		// val x at line 1
		assert(get_edit_line(edits, 0) == 1, "expected edit 0 at line 1, got %d", get_edit_line(edits, 0));
		assert(get_edit_col(edits, 0) == 8);
		assert(get_edit_new_text(edits, 0) == "value");

		// println(x) at line 2
		assert(get_edit_line(edits, 1) == 2, "expected edit 1 at line 2, got %d", get_edit_line(edits, 1));
		assert(get_edit_new_text(edits, 1) == "value");
	};
}

// ── Rename from usage site resolves to correct function scope ───────

fn void rename_from_usage_scoped() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() {\n    val x = 1\n    println(x)\n}\nfun bar() {\n    val x = 2\n    println(x)\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 6, col 12 (usage in bar's println)
		Object* params = make_rename_params("file:///test.kt", 6, 12, "num");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Only "x" inside bar() should be renamed
		assert(edits.get_len() == 2, "expected 2 edits (bar only), got %d", (int)edits.get_len());

		// val x at line 5
		assert(get_edit_line(edits, 0) == 5, "expected edit 0 at line 5, got %d", get_edit_line(edits, 0));
		// println(x) at line 6
		assert(get_edit_line(edits, 1) == 6, "expected edit 1 at line 6, got %d", get_edit_line(edits, 1));
	};
}

// ── Shadowing: inner scope variable doesn't affect outer ────────────

fn void rename_with_shadowing() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun test() {\n    val x = 1\n    if (true) {\n        val x = 2\n        println(x)\n    }\n    println(x)\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 1, col 8 (outer val x = 1)
		Object* params = make_rename_params("file:///test.kt", 1, 8, "outer");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Only the outer "x": declaration at line 1 + usage at line 6 (after the if block)
		// The inner "x" at lines 3 and 4 should NOT be touched
		assert(edits.get_len() == 2, "expected 2 edits (outer only), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 1, "expected outer decl at line 1, got %d", get_edit_line(edits, 0));
		assert(get_edit_line(edits, 1) == 6, "expected outer usage at line 6, got %d", get_edit_line(edits, 1));
	};
}

// ── Shadowing: rename inner variable doesn't affect outer ───────────

fn void rename_inner_shadowed_variable() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun test() {\n    val x = 1\n    if (true) {\n        val x = 2\n        println(x)\n    }\n    println(x)\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 3, col 12 (inner val x = 2)
		Object* params = make_rename_params("file:///test.kt", 3, 12, "inner");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Only the inner "x": declaration at line 3 + usage at line 4
		assert(edits.get_len() == 2, "expected 2 edits (inner only), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 3, "expected inner decl at line 3, got %d", get_edit_line(edits, 0));
		assert(get_edit_line(edits, 1) == 4, "expected inner usage at line 4, got %d", get_edit_line(edits, 1));
	};
}

// ── Top-level function renamed across all call sites ────────────────

fn void rename_top_level_function_all_sites() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun a() { greet() }\nfun b() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" at line 0, col 4 (declaration)
		Object* params = make_rename_params("file:///test.kt", 0, 4, "hello");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Top-level function: declaration + 2 call sites = 3 edits
		assert(edits.get_len() == 3, "expected 3 edits (all sites), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 0, "expected decl at line 0");
		assert(get_edit_line(edits, 1) == 1, "expected call in a() at line 1");
		assert(get_edit_line(edits, 2) == 2, "expected call in b() at line 2");
	};
}

// ── Parameter rename scoped to its function ─────────────────────────

fn void rename_parameter_scoped() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun add(n: Int) = n + 1\nfun sub(n: Int) = n - 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "n" at line 0, col 8 (param in add)
		Object* params = make_rename_params("file:///test.kt", 0, 8, "value");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Only "n" in add() should be renamed (param decl + usage in expression)
		// "n" in sub() should NOT be touched
		assert(edits.get_len() == 2, "expected 2 edits (add only), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 0, "expected param at line 0");
		assert(get_edit_line(edits, 1) == 0, "expected usage at line 0");
		assert(get_edit_col(edits, 0) == 8, "expected param at col 8");
		assert(get_edit_col(edits, 1) == 18, "expected usage at col 18, got %d", get_edit_col(edits, 1));
	};
}

// ── Top-level val renamed in all functions that use it ───────────────

fn void rename_top_level_val_across_functions() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val limit = 100\nfun check(n: Int) = n < limit\nfun show() = println(limit)";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "limit" at line 0, col 4 (declaration)
		Object* params = make_rename_params("file:///test.kt", 0, 4, "max");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected workspace edit");

		Object* edits = get_edits_for_uri(result, "file:///test.kt");
		assert(edits != null, "expected edits for test.kt");
		// Top-level val: declaration + 2 usages in different functions = 3 edits
		assert(edits.get_len() == 3, "expected 3 edits (all sites), got %d", (int)edits.get_len());

		assert(get_edit_line(edits, 0) == 0, "expected decl at line 0");
		assert(get_edit_line(edits, 1) == 1, "expected usage in check() at line 1");
		assert(get_edit_line(edits, 2) == 2, "expected usage in show() at line 2");
	};
}

// ── prepareRename rejects identifier in package path ────────────────

fn void prepare_rename_rejects_package_path() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "package com.example.app\nval app = 1");

		// Cursor on "app" at line 0, col 20 (inside package path)
		Object* params = make_prepare_params("file:///test.kt", 0, 20);
		Object* result = rename::handle_prepare_rename(&store, params);

		assert(result == null, "expected null for identifier in package path");
	};
}

// ── prepareRename rejects identifier in import path ─────────────────

fn void prepare_rename_rejects_import_path() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "import com.example.Foo\nval x = 1");

		// Cursor on "Foo" at line 0, col 19 (inside import path)
		Object* params = make_prepare_params("file:///test.kt", 0, 19);
		Object* result = rename::handle_prepare_rename(&store, params);

		assert(result == null, "expected null for identifier in import path");
	};
}

// ── #17: Rename rejects invalid new names ───────────────────────────

fn void rename_rejects_empty_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_rename_params("file:///test.kt", 0, 4, "");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for empty new name");
	};
}

fn void rename_rejects_name_starting_with_digit() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_rename_params("file:///test.kt", 0, 4, "123abc");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for name starting with digit");
	};
}

fn void rename_rejects_hard_keyword() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_rename_params("file:///test.kt", 0, 4, "class");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for hard keyword 'class'");
	};
}

fn void rename_rejects_name_with_special_chars() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_rename_params("file:///test.kt", 0, 4, "foo-bar");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result == null, "expected null for name with special chars");
	};
}

fn void rename_accepts_soft_keyword() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		// Soft keywords like "data" are valid identifiers
		Object* params = make_rename_params("file:///test.kt", 0, 4, "data");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected rename to succeed with soft keyword 'data'");
	};
}

fn void rename_accepts_valid_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_rename_params("file:///test.kt", 0, 4, "hello_world");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected rename to succeed with valid name");
	};
}

fn void rename_accepts_underscore_start() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_rename_params("file:///test.kt", 0, 4, "_private");
		Object* result = rename::handle_rename(&store, null, params);

		assert(result != null, "expected rename to succeed with underscore-prefixed name");
	};
}
