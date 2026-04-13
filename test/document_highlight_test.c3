module kls::test::document_highlight_test;

import std::collections::object;
import kls::document;
import kls::lsp::document_highlight;

// ── Helper: build params object ────────────────────────────────────

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

// ── Helpers: extract fields from a DocumentHighlight in the array ──

fn int get_line(Object* highlights, usz index) {
	Object* h = highlights.get_at(index);
	Object* range = h.get("range")!!;
	Object* start = range.get("start")!!;
	return start.get_int("line")!!;
}

fn int get_col(Object* highlights, usz index) {
	Object* h = highlights.get_at(index);
	Object* range = h.get("range")!!;
	Object* start = range.get("start")!!;
	return start.get_int("character")!!;
}

fn int get_end_col(Object* highlights, usz index) {
	Object* h = highlights.get_at(index);
	Object* range = h.get("range")!!;
	Object* end_pos = range.get("end")!!;
	return end_pos.get_int("character")!!;
}

fn int get_kind(Object* highlights, usz index) {
	Object* h = highlights.get_at(index);
	return h.get_int("kind")!!;
}

// ── Function highlights (declaration + call sites) ─────────────────

fn void highlight_function_occurrences() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in the call at line 1, col 13
		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		assert(result.get_len() == 2, "expected 2 highlights, got %d", (int)result.get_len());

		// First: declaration at line 0, col 4
		assert(get_line(result, 0) == 0, "expected highlight 0 at line 0");
		assert(get_col(result, 0) == 4, "expected highlight 0 at col 4");

		// Second: call at line 1, col 13
		assert(get_line(result, 1) == 1, "expected highlight 1 at line 1");
		assert(get_col(result, 1) == 13, "expected highlight 1 at col 13");
	};
}

// ── Declaration classified as Write ────────────────────────────────

fn void highlight_declaration_is_write() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		assert(result.get_len() == 2, "expected 2 highlights");

		// Declaration should be Write (kind=3)
		assert(get_kind(result, 0) == 3, "expected declaration to be Write(3), got %d", get_kind(result, 0));
	};
}

// ── Usage classified as Read ───────────────────────────────────────

fn void highlight_usage_is_read() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		assert(result.get_len() == 2, "expected 2 highlights");

		// Usage (call site) should be Read (kind=2)
		assert(get_kind(result, 1) == 2, "expected usage to be Read(2), got %d", get_kind(result, 1));
	};
}

// ── Variable highlights with Write/Read classification ─────────────

fn void highlight_variable_declaration_and_usage() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 42\nval y = x + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 0, col 4 (declaration)
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		assert(result.get_len() == 2, "expected 2 highlights, got %d", (int)result.get_len());

		// Declaration at line 0 should be Write
		assert(get_kind(result, 0) == 3, "expected declaration to be Write(3)");
		assert(get_line(result, 0) == 0);
		assert(get_col(result, 0) == 4);

		// Usage at line 1 should be Read
		assert(get_kind(result, 1) == 2, "expected usage to be Read(2)");
		assert(get_line(result, 1) == 1);
		assert(get_col(result, 1) == 8);
	};
}

// ── Keyword at cursor returns null ─────────────────────────────────

fn void highlight_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

		// Cursor on "fun" keyword at col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── Whitespace at cursor returns null ──────────────────────────────

fn void highlight_whitespace_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun foo() {}");

		// Cursor on space at col 3
		Object* params = make_params("file:///test.kt", 0, 3);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result == null, "expected null on whitespace");
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void highlight_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Single occurrence returns single highlight ─────────────────────

fn void highlight_single_occurrence() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun uniqueName() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "uniqueName" at col 4
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		assert(result.get_len() == 1, "expected 1 highlight, got %d", (int)result.get_len());
		assert(get_kind(result, 0) == 3, "expected single declaration to be Write(3)");
	};
}

// ── Range covers full identifier length ────────────────────────────

fn void highlight_range_covers_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class MyWidget {}\nval w: MyWidget = MyWidget()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "MyWidget" at line 0, col 6
		Object* params = make_params("file:///test.kt", 0, 6);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		// All highlights should have end_col = start_col + 8 ("MyWidget" length)
		for (usz i = 0; i < result.get_len(); i++) {
			int start_col = get_col(result, i);
			int end_col = get_end_col(result, i);
			assert(end_col - start_col == 8,
				"expected name length 8, got %d at highlight %d", end_col - start_col, (int)i);
		}
	};
}

// ── Multiple highlights across multiple lines ──────────────────────

fn void highlight_multiple_lines() @test {
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

		// Cursor on "doWork" at line 0, col 4
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		// 1 declaration + 3 calls = 4
		assert(result.get_len() == 4, "expected 4 highlights, got %d", (int)result.get_len());

		assert(get_line(result, 0) == 0, "expected decl at line 0");
		assert(get_line(result, 1) == 2, "expected call 1 at line 2");
		assert(get_line(result, 2) == 3, "expected call 2 at line 3");
		assert(get_line(result, 3) == 4, "expected call 3 at line 4");

		// Declaration is Write, calls are Read
		assert(get_kind(result, 0) == 3, "expected decl to be Write(3)");
		assert(get_kind(result, 1) == 2, "expected call 1 to be Read(2)");
		assert(get_kind(result, 2) == 2, "expected call 2 to be Read(2)");
		assert(get_kind(result, 3) == 2, "expected call 3 to be Read(2)");
	};
}

// ── Class member highlights ────────────────────────────────────────

fn void highlight_class_member() @test {
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
		Object* result = document_highlight::handle_document_highlight(&store, params);

		assert(result != null, "expected highlights array");
		// "bar" appears: declaration (line 1), call in baz (line 2), call in main (line 6)
		assert(result.get_len() == 3, "expected 3 highlights, got %d", (int)result.get_len());

		// Declaration is Write
		assert(get_kind(result, 0) == 3, "expected decl to be Write(3)");
		// Usages are Read
		assert(get_kind(result, 1) == 2, "expected usage 1 to be Read(2)");
		assert(get_kind(result, 2) == 2, "expected usage 2 to be Read(2)");
	};
}
