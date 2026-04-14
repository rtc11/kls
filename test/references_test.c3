module kls::test::references_test;

import std::collections::object;
import kls::document;
import kls::lsp::references;

// ── Helper: build params object ────────────────────────────────────

fn Object* make_params(String uri, int line, int character, bool include_declaration = true) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* ctx = object::new_obj(tmem);
	ctx.set("includeDeclaration", include_declaration);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	params.set("context", ctx);
	return params;
}

// ── Helper: extract line/col from a Location in the array ──────────

fn int get_line(Object* locations, usz index) {
	Object* loc = locations.get_at(index);
	Object* range = loc.get("range")!!;
	Object* start = range.get("start")!!;
	return start.get_int("line")!!;
}

fn int get_col(Object* locations, usz index) {
	Object* loc = locations.get_at(index);
	Object* range = loc.get("range")!!;
	Object* start = range.get("start")!!;
	return start.get_int("character")!!;
}

fn int get_end_col(Object* locations, usz index) {
	Object* loc = locations.get_at(index);
	Object* range = loc.get("range")!!;
	Object* end_pos = range.get("end")!!;
	return end_pos.get_int("character")!!;
}

// ── Function references (declaration + call sites) ─────────────────

fn void references_of_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in the call at line 1, col 13
		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		assert(result.get_len() == 2, "expected 2 references, got %d", (int)result.get_len());

		// First: declaration at line 0, col 4
		assert(get_line(result, 0) == 0, "expected ref 0 at line 0");
		assert(get_col(result, 0) == 4, "expected ref 0 at col 4");

		// Second: call at line 1, col 13
		assert(get_line(result, 1) == 1, "expected ref 1 at line 1");
		assert(get_col(result, 1) == 13, "expected ref 1 at col 13");
	};
}

// ── Variable references (declaration + usage) ──────────────────────

fn void references_of_variable() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 42\nval y = x + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 0, col 4 (the declaration)
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		assert(result.get_len() == 2, "expected 2 references, got %d", (int)result.get_len());

		// Declaration at line 0, col 4
		assert(get_line(result, 0) == 0);
		assert(get_col(result, 0) == 4);

		// Usage at line 1, col 8
		assert(get_line(result, 1) == 1);
		assert(get_col(result, 1) == 8);
	};
}

// ── Class references (declaration + type usage + constructor) ──────

fn void references_of_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Foo {}\nfun make(): Foo = Foo()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 0, col 6 (declaration)
		Object* params = make_params("file:///test.kt", 0, 6);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// "Foo" appears 3 times: class Foo, : Foo, Foo()
		assert(result.get_len() == 3, "expected 3 references, got %d", (int)result.get_len());

		assert(get_line(result, 0) == 0);
		assert(get_col(result, 0) == 6, "expected class decl at col 6");

		assert(get_line(result, 1) == 1);
		assert(get_col(result, 1) == 12, "expected return type at col 12, got %d", get_col(result, 1));

		assert(get_line(result, 2) == 1);
		assert(get_col(result, 2) == 18, "expected constructor call at col 18, got %d", get_col(result, 2));
	};
}

// ── includeDeclaration: false excludes declaration site ─────────────

fn void references_exclude_declaration() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" at line 1, col 13 -- exclude declaration
		Object* params = make_params("file:///test.kt", 1, 13, false);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// Only the call site, not the declaration
		assert(result.get_len() == 1, "expected 1 reference (excl decl), got %d", (int)result.get_len());
		assert(get_line(result, 0) == 1, "expected call at line 1");
		assert(get_col(result, 0) == 13, "expected call at col 13");
	};
}

// ── Keyword at cursor returns null ─────────────────────────────────

fn void references_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

		// Cursor on "fun" keyword at col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = references::handle_references(&store, null, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void references_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = references::handle_references(&store, null, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Cursor on whitespace returns null ──────────────────────────────

fn void references_on_whitespace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun foo() {}");

		// Cursor on space at col 3
		Object* params = make_params("file:///test.kt", 0, 3);
		Object* result = references::handle_references(&store, null, params);

		assert(result == null, "expected null on whitespace");
	};
}

// ── Identifier with no other references returns single location ────

fn void references_single_occurrence() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun uniqueName() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "uniqueName" at col 4
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		assert(result.get_len() == 1, "expected 1 reference, got %d", (int)result.get_len());
		assert(get_col(result, 0) == 4);
	};
}

// ── Location ranges include full name length ───────────────────────

fn void references_range_covers_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class MyWidget {}\nval w: MyWidget = MyWidget()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "MyWidget" at line 0, col 6
		Object* params = make_params("file:///test.kt", 0, 6);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// All locations should have end_col = start_col + 8 ("MyWidget" length)
		for (usz i = 0; i < result.get_len(); i++) {
			int start_col = get_col(result, i);
			int end_col = get_end_col(result, i);
			assert(end_col - start_col == 8,
				"expected name length 8, got %d at ref %d", end_col - start_col, (int)i);
		}
	};
}

// ── Multiple references across multiple lines ──────────────────────

fn void references_multiple_lines() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun doWork() {}
fun main() {
    doWork()
    doWork()
    doWork()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "doWork" at line 0, col 4 (declaration)
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// 1 declaration + 3 calls = 4
		assert(result.get_len() == 4, "expected 4 references, got %d", (int)result.get_len());

		assert(get_line(result, 0) == 0, "expected decl at line 0");
		assert(get_line(result, 1) == 2, "expected call 1 at line 2");
		assert(get_line(result, 2) == 3, "expected call 2 at line 3");
		assert(get_line(result, 3) == 4, "expected call 3 at line 4");
	};
}

// ── URI is preserved in each Location ──────────────────────────────

fn void references_preserve_uri() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 42\nval y = x";
		store.open("file:///my/file.kt", "kotlin", 1, content);

		Object* params = make_params("file:///my/file.kt", 0, 4);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		for (usz i = 0; i < result.get_len(); i++) {
			Object* loc = result.get_at(i);
			String uri = loc.get_string("uri")!!;
			assert(uri == "file:///my/file.kt", "expected correct URI in ref %d", (int)i);
		}
	};
}

// ── Member references inside a class ───────────────────────────────

fn void references_class_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`class Foo {
    fun bar() {}
    fun baz() { bar() }
}
fun main() {
    val f = Foo()
    f.bar()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "bar" at line 1, col 8 (declaration)
		Object* params = make_params("file:///test.kt", 1, 8);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// "bar" appears: declaration (line 1), call in baz (line 2), call in main (line 6)
		assert(result.get_len() == 3, "expected 3 references, got %d", (int)result.get_len());
	};
}

// ── exclude declaration for variable ───────────────────────────────

fn void references_exclude_variable_declaration() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val counter = 0\nval next = counter + 1\nval prev = counter - 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "counter" at line 1, col 11 -- exclude declaration
		Object* params = make_params("file:///test.kt", 1, 11, false);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// 2 usages only, excluding the declaration
		assert(result.get_len() == 2, "expected 2 references (excl decl), got %d", (int)result.get_len());
		assert(get_line(result, 0) == 1, "expected usage at line 1");
		assert(get_line(result, 1) == 2, "expected usage at line 2");
	};
}

// ── References skip package path identifiers ──────────────────────

fn void references_skip_package_path() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "package com.example.model\nval model = 42\nval x = model + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "model" at line 1, col 4 (the variable)
		Object* params = make_params("file:///test.kt", 1, 4);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// "model" in package path should be skipped, only val decl + usage
		assert(result.get_len() == 2, "expected 2 references (skip package), got %d", (int)result.get_len());

		assert(get_line(result, 0) == 1);
		assert(get_col(result, 0) == 4);

		assert(get_line(result, 1) == 2);
		assert(get_col(result, 1) == 8);
	};
}

// ── References skip import path identifiers ───────────────────────

fn void references_skip_import_path() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "import com.example.Foo\nclass Foo {}\nfun make(): Foo = Foo()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 1, col 6 (class declaration)
		Object* params = make_params("file:///test.kt", 1, 6);
		Object* result = references::handle_references(&store, null, params);

		assert(result != null, "expected references array");
		// "Foo" in import path should be skipped: class Foo, : Foo, Foo()
		assert(result.get_len() == 3, "expected 3 references (skip import), got %d", (int)result.get_len());

		assert(get_line(result, 0) == 1);
		assert(get_col(result, 0) == 6);

		assert(get_line(result, 1) == 2);
		assert(get_line(result, 2) == 2);
	};
}
