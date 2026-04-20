module kls::test::linked_editing_range_test;

import std::collections::object;
import kls::document;
import kls::lsp::linked_editing_range;

// ── Helper: build params ───────────────────────────────────────────

fn Object* make_params(String uri, int line, int character) {
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

// ── Unknown document returns null ──────────────────────────────────

fn void linked_editing_unknown_doc_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///nonexistent.kt", 0, 0);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;
		assert(result == null, "expected null for unknown document");
	};
}

// ── Keyword returns null ───────────────────────────────────────────

fn void linked_editing_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");
		// Cursor on "fun" at col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;
		assert(result == null, "expected null for keyword");
	};
}

// ── Single identifier occurrence ───────────────────────────────────

fn void linked_editing_single_occurrence() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");
		// Cursor on "greet" at col 4
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;

		assert(result != null, "expected a result");
		Object* ranges = result.get("ranges")!!;
		assert(ranges.get_len() == 1, "expected 1 range, got %d", (int)ranges.get_len());
	};
}

// ── Multiple same-name in same scope ───────────────────────────────

fn void linked_editing_multiple_same_scope() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun test() {\n    val x = 1\n    val y = x + x\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on first "x" at line 1, col 8
		Object* params = make_params("file:///test.kt", 1, 8);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;

		assert(result != null, "expected a result");
		Object* ranges = result.get("ranges")!!;
		// Should find all 3 occurrences of "x" in same scope: decl + 2 uses
		assert(ranges.get_len() == 3, "expected 3 ranges, got %d", (int)ranges.get_len());
	};
}

// ── Different scopes → isolation ───────────────────────────────────

fn void linked_editing_cross_scope_isolation() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() {\n    val x = 1\n}\nfun bar() {\n    val x = 2\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" in foo() at line 1, col 8
		Object* params = make_params("file:///test.kt", 1, 8);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;

		assert(result != null, "expected a result");
		Object* ranges = result.get("ranges")!!;
		// Should only find the x in foo's scope, not bar's
		assert(ranges.get_len() == 1, "expected 1 range (scoped), got %d", (int)ranges.get_len());
	};
}

// ── wordPattern field present ──────────────────────────────────────

fn void linked_editing_has_word_pattern() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 1");
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;

		assert(result != null, "expected a result");
		String pattern = result.get_string("wordPattern")!!;
		assert(pattern == "[a-zA-Z_][a-zA-Z0-9_]*", "expected Kotlin identifier pattern");
	};
}

// ── Top-level identifier matches across file ───────────────────────

fn void linked_editing_top_level() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 1\nval y = x";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 0, col 4
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = linked_editing_range::handle_linked_editing_range(&store, params)!!;

		assert(result != null, "expected a result");
		Object* ranges = result.get("ranges")!!;
		// Both x at top-level = same scope
		assert(ranges.get_len() == 2, "expected 2 ranges at top level, got %d", (int)ranges.get_len());
	};
}
