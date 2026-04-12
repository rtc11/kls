module kls::test::definition_test;

import std::collections::object;
import kls::document;
import kls::lsp::definition;

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

// ── Go to function definition ──────────────────────────────────────

fn void definition_of_function_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in the call at line 1, col 13
		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");

		String uri = result.get_string("uri")!!;
		assert(uri == "file:///test.kt", "expected same URI");

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Go to variable definition ──────────────────────────────────────

fn void definition_of_variable() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 42\nval y = x + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 1, col 8
		Object* params = make_params("file:///test.kt", 1, 8);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Go to class definition ─────────────────────────────────────────

fn void definition_of_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Foo {}\nfun make(): Foo = Foo()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 1, col 18 (the constructor call)
		Object* params = make_params("file:///test.kt", 1, 18);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 6, "expected col 6, got %d", col);
	};
}

// ── Cursor on keyword returns null ─────────────────────────────────

fn void definition_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

		// Cursor on "fun" keyword at col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = definition::handle_definition(&store, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── Identifier with no declaration returns null ────────────────────

fn void definition_no_declaration_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() { println(unknown) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "unknown" at col 21
		Object* params = make_params("file:///test.kt", 0, 21);
		Object* result = definition::handle_definition(&store, params);

		assert(result == null, "expected null when no declaration found");
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void definition_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = definition::handle_definition(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Definition on the declaration itself ───────────────────────────

fn void definition_on_declaration_itself() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "foo" at col 4 -- the declaration itself
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected Location even on declaration itself");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int col = start.get_int("character")!!;
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Location range includes full name length ───────────────────────

fn void definition_range_covers_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class MyWidget {}\nval w: MyWidget = MyWidget()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "MyWidget" at line 1, col 19
		Object* params = make_params("file:///test.kt", 1, 19);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		Object* end_pos = range.get("end")!!;
		int start_col = start.get_int("character")!!;
		int end_col = end_pos.get_int("character")!!;
		// "MyWidget" is 8 chars, starts at col 6
		assert(start_col == 6, "expected start col 6, got %d", start_col);
		assert(end_col == 14, "expected end col 14, got %d", end_col);
	};
}

// ── Multiple declarations, finds first match ───────────────────────

fn void definition_finds_first_match() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Two functions named "doWork" -- should find the first one
		String content = "fun doWork() {}\nfun doWork(x: Int) {}\nfun main() { doWork() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "doWork" call at line 2
		Object* params = make_params("file:///test.kt", 2, 14);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 0, "expected first declaration at line 0, got %d", line);
	};
}

// ── Cursor on whitespace returns null ──────────────────────────────

fn void definition_on_whitespace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun foo() {}");

		// Cursor on space between "fun" and "foo" (col 3)
		Object* params = make_params("file:///test.kt", 0, 3);
		Object* result = definition::handle_definition(&store, params);

		assert(result == null, "expected null on whitespace");
	};
}

// ── Call context: prefers function over property ───────────────────

fn void definition_prefers_function_in_call_context() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// val module appears before fun module -- but cursor is on a call site
		String content =
			`val module = nob.module {
    name = "nob"
}

fun module(block: Int): Int {
    return block
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "module" in "nob.module {" at line 0, col 18
		Object* params = make_params("file:///test.kt", 0, 18);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should navigate to fun module on line 4, not val module on line 0
		assert(line == 4, "expected function declaration at line 4, got %d", line);
	};
}

fn void definition_prefers_function_with_paren_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val greet = 42\nfun greet(name: String) {}\nfun main() { greet(\"hi\") }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in "greet("hi")" at line 2, col 13
		Object* params = make_params("file:///test.kt", 2, 13);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should navigate to fun greet on line 1, not val greet on line 0
		assert(line == 1, "expected function declaration at line 1, got %d", line);
	};
}

fn void definition_non_call_context_returns_first_match() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "module" used as a value (not called), should get the val
		String content = "val module = 42\nfun module() {}\nfun main() { val x = module }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "module" in "val x = module" at line 2
		// "val x = module }" -- "module" starts at col 21
		Object* params = make_params("file:///test.kt", 2, 21);
		Object* result = definition::handle_definition(&store, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Non-call context: first match is val module on line 0
		assert(line == 0, "expected property declaration at line 0, got %d", line);
	};
}
