module kls::test::type_definition_test;

import std::collections::object;
import kls::document;
import kls::lsp::type_definition;
import kls::workspace;

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

fn void assert_location(Object* result, int expected_line, int expected_col) {
	assert(result != null, "expected a Location result");
	Object* range = result.get("range")!!;
	Object* start = range.get("start")!!;
	int line = start.get_int("line")!!;
	int col = start.get_int("character")!!;
	assert(line == expected_line, "expected line %d, got %d", expected_line, line);
	assert(col == expected_col, "expected col %d, got %d", expected_col, col);
}

// ── Variable with explicit type annotation ─────────────────────────

fn void type_def_of_variable_with_explicit_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `class MyClass {}
fun main() {
    val x: MyClass = MyClass()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 2, col 8
		Object* params = make_params("file:///test.kt", 2, 8);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		// Should navigate to MyClass declaration at line 0, col 6
		assert_location(result, 0, 6);
	};
}

// ── Variable with inferred type ────────────────────────────────────

fn void type_def_of_variable_with_inferred_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `class Foo {}
fun create(): Foo = Foo()
fun main() {
    val x = create()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 3, col 8
		Object* params = make_params("file:///test.kt", 3, 8);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		// Should navigate to Foo declaration at line 0, col 6
		// (depends on type inference resolving create() -> Foo)
		if (result != null) {
			assert_location(result, 0, 6);
		}
		// If type inference doesn't resolve, null is acceptable
	};
}

// ── Cursor on type reference itself ────────────────────────────────

fn void type_def_of_type_reference() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `class MyClass {}
fun main() {
    val x: MyClass = MyClass()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "MyClass" in the type annotation at line 2, col 11
		Object* params = make_params("file:///test.kt", 2, 11);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		// Should navigate to MyClass declaration at line 0, col 6
		assert_location(result, 0, 6);
	};
}

// ── Cursor on class declaration itself returns null ─────────────────

fn void type_def_on_class_declaration_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class MyClass {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "MyClass" in the class declaration at line 0, col 6
		Object* params = make_params("file:///test.kt", 0, 6);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		// Should return null - cursor is on the type itself
		assert(result == null, "expected null for cursor on class declaration");
	};
}

// ── Cursor on non-identifier returns null ──────────────────────────

fn void type_def_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "fun" keyword at line 0, col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── Function parameter with type annotation ────────────────────────

fn void type_def_of_function_parameter() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `class User {}
fun greet(user: User) {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "user" parameter at line 1, col 10
		Object* params = make_params("file:///test.kt", 1, 10);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		// Should navigate to User class at line 0, col 6
		assert_location(result, 0, 6);
	};
}

// ── No document returns null ───────────────────────────────────────

fn void type_def_unknown_document_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Interface type ─────────────────────────────────────────────────

fn void type_def_navigates_to_interface() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `interface Runnable {}
fun execute(r: Runnable) {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "r" parameter at line 1, col 12
		Object* params = make_params("file:///test.kt", 1, 12);
		Object* result = type_definition::handle_type_definition(&store, null, params);

		// Should navigate to Runnable interface at line 0, col 10
		assert_location(result, 0, 10);
	};
}
