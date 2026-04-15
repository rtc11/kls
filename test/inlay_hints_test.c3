module kls::test::inlay_hints_test;

import std::collections::object;
import kls::document;
import kls::lsp::inlay_hints;
import kls::kotlin::ast;
import kls::kotlin::parser;

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Build inlayHint params for a given URI covering lines [start_line, end_line].
 */
fn Object* make_inlay_hint_params(String uri, uint start_line, uint end_line) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* start = object::new_obj(tmem);
	start.set("line", (int)start_line);
	start.set("character", 0);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)end_line);
	end_pos.set("character", 999);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	return params;
}

/**
 * Extract the label string from a hint at a given index.
 */
fn String get_hint_label(Object* hints, usz index) {
	return hints.get_at(index).get_string("label")!!;
}

/**
 * Extract the hint kind from a hint at a given index.
 */
fn int get_hint_kind(Object* hints, usz index) {
	return hints.get_at(index).get_int("kind")!!;
}

/**
 * Extract the line from a hint's position at a given index.
 */
fn int get_hint_line(Object* hints, usz index) {
	Object* pos = hints.get_at(index).get("position")!!;
	return pos.get_int("line")!!;
}

/**
 * Extract the character from a hint's position at a given index.
 */
fn int get_hint_character(Object* hints, usz index) {
	Object* pos = hints.get_at(index).get("position")!!;
	return pos.get_int("character")!!;
}

// ── Null / empty document tests ─────────────────────────────────

fn void null_for_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_inlay_hint_params("file:///unknown.kt", 0, 100);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result == null, "expected null for unknown document");
	};
}

fn void null_for_empty_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		store.open(uri, "kotlin", 1, "");

		Object* params = make_inlay_hint_params(uri, 0, 100);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result == null, "expected null for empty document");
	};
}

// ── Parameter hint tests ────────────────────────────────────────

fn void param_hint_simple_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun greet(name: String, age: Int) {}` "\n"
			`fun main() {` "\n"
			`    greet("Alice", 30)` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		// Should have 2 parameter hints: name: and age:
		usz count = result.get_len();
		assert(count >= 2, "expected at least 2 hints, got %d", (int)count);

		// Find the parameter hints (filter by kind=2)
		bool found_name = false;
		bool found_age = false;
		for (usz i = 0; i < count; i++) {
			int kind = get_hint_kind(result, i);
			if (kind != 2) continue;
			String label = get_hint_label(result, i);
			if (label == "name:") found_name = true;
			if (label == "age:") found_age = true;
		}
		assert(found_name, "expected 'name:' parameter hint");
		assert(found_age, "expected 'age:' parameter hint");
	};
}

fn void param_hint_suppressed_when_name_matches() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun greet(name: String) {}` "\n"
			`fun main() {` "\n"
			`    val name = "Alice"` "\n"
			`    greet(name)` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);

		// The parameter hint should be suppressed because
		// the argument 'name' matches the parameter 'name'
		if (result != null) {
			for (usz i = 0; i < result.get_len(); i++) {
				int kind = get_hint_kind(result, i);
				if (kind != 2) continue;
				String label = get_hint_label(result, i);
				assert(label != "name:", "expected 'name:' hint to be suppressed");
			}
		}
	};
}

fn void param_hint_named_argument_suppressed() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun greet(name: String, age: Int) {}` "\n"
			`fun main() {` "\n"
			`    greet(name = "Alice", 30)` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);

		// 'name' is a named argument -> suppressed
		// 'age' should still get a hint for the second arg (30)
		if (result != null) {
			bool found_name_hint = false;
			for (usz i = 0; i < result.get_len(); i++) {
				int kind = get_hint_kind(result, i);
				if (kind != 2) continue;
				String label = get_hint_label(result, i);
				if (label == "name:") found_name_hint = true;
			}
			assert(!found_name_hint, "expected 'name:' hint to be suppressed for named argument");
		}
	};
}

fn void param_hint_no_declaration() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		// Call to undeclared function -- no hints expected
		String content =
			`fun main() {` "\n"
			`    unknownFunc("hello")` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);

		// Should have no parameter hints (may have type hints or null)
		if (result != null) {
			for (usz i = 0; i < result.get_len(); i++) {
				int kind = get_hint_kind(result, i);
				assert(kind != 2, "should not produce parameter hints for undeclared function");
			}
		}
	};
}

fn void param_hint_multiple_arguments() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun add(a: Int, b: Int, c: Int) {}` "\n"
			`fun main() {` "\n"
			`    add(1, 2, 3)` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		// Collect parameter hints
		int param_hint_count = 0;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) == 2) param_hint_count++;
		}
		assert(param_hint_count == 3, "expected 3 param hints, got %d", param_hint_count);
	};
}

fn void param_hint_constructor_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`class Person(val name: String, val age: Int)` "\n"
			`fun main() {` "\n"
			`    Person("Alice", 30)` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		// Should have parameter hints for the constructor call
		bool found_name = false;
		bool found_age = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 2) continue;
			String label = get_hint_label(result, i);
			if (label == "name:") found_name = true;
			if (label == "age:") found_age = true;
		}
		assert(found_name, "expected 'name:' hint for constructor param");
		assert(found_age, "expected 'age:' hint for constructor param");
	};
}

fn void param_hint_no_params_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun noop() {}` "\n"
			`fun main() {` "\n"
			`    noop()` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);

		// No parameter hints for zero-param call
		if (result != null) {
			for (usz i = 0; i < result.get_len(); i++) {
				int kind = get_hint_kind(result, i);
				assert(kind != 2, "should not produce parameter hints for zero-param call");
			}
		}
	};
}

// ── Type hint tests ─────────────────────────────────────────────

fn void type_hint_integer_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x = 42`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result for type hint");

		// Should have a type hint ": Int"
		bool found_int = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Int") found_int = true;
		}
		assert(found_int, "expected ': Int' type hint");
	};
}

fn void type_hint_string_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val s = "hello"`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_string = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": String") found_string = true;
		}
		assert(found_string, "expected ': String' type hint");
	};
}

fn void type_hint_boolean_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val b = true`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_bool = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Boolean") found_bool = true;
		}
		assert(found_bool, "expected ': Boolean' type hint");
	};
}

fn void type_hint_suppressed_with_explicit_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x: Int = 42`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);

		// Should have NO type hints since the type is explicit
		if (result != null) {
			for (usz i = 0; i < result.get_len(); i++) {
				int kind = get_hint_kind(result, i);
				assert(kind != 1, "should not produce type hint when type is explicit");
			}
		}
	};
}

fn void type_hint_constructor_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`class Foo` "\n"
			`val x = Foo()`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_foo = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Foo") found_foo = true;
		}
		assert(found_foo, "expected ': Foo' type hint for constructor call");
	};
}

fn void type_hint_long_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x = 42L`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_long = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Long") found_long = true;
		}
		assert(found_long, "expected ': Long' type hint");
	};
}

fn void type_hint_float_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x = 3.14f`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_float = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Float") found_float = true;
		}
		assert(found_float, "expected ': Float' type hint");
	};
}

fn void type_hint_double_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x = 3.14`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_double = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Double") found_double = true;
		}
		assert(found_double, "expected ': Double' type hint");
	};
}

fn void type_hint_char_literal() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val c = 'A'`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_char = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Char") found_char = true;
		}
		assert(found_char, "expected ': Char' type hint");
	};
}

fn void type_hint_var_property() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `var count = 0`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		bool found_int = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": Int") found_int = true;
		}
		assert(found_int, "expected ': Int' type hint for var");
	};
}

fn void type_hint_function_return_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun getName(): String { return "Alice" }` "\n"
			`val n = getName()`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		// The val n should get a ": String" hint from the function return type
		bool found_string = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			String label = get_hint_label(result, i);
			if (label == ": String") found_string = true;
		}
		assert(found_string, "expected ': String' type hint from function return type");
	};
}

// ── Range filtering tests ───────────────────────────────────────

fn void range_filter_excludes_out_of_range() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`val a = 1` "\n"
			`val b = 2` "\n"
			`val c = 3`;
		store.open(uri, "kotlin", 1, content);

		// Only request hints for line 1 (val b = 2)
		Object* params = make_inlay_hint_params(uri, 1, 1);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);

		if (result != null) {
			for (usz i = 0; i < result.get_len(); i++) {
				int line = get_hint_line(result, i);
				assert(line == 1, "expected hints only on line 1, got line %d", line);
			}
		}
	};
}

// ── Position accuracy tests ─────────────────────────────────────

fn void type_hint_position_after_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x = 42`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		// The type hint should be positioned after 'x' (col 4, len 1 -> col 5)
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			int character = get_hint_character(result, i);
			assert(character == 5, "expected type hint at character 5, got %d", character);
		}
	};
}

fn void param_hint_position_at_argument() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun greet(name: String) {}` "\n"
			`fun main() {` "\n"
			`    greet("Alice")` "\n"
			`}`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		// The parameter hint should be on line 2 where "Alice" starts
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 2) continue;
			int line = get_hint_line(result, i);
			assert(line == 2, "expected param hint on line 2, got %d", line);
			found = true;
		}
		assert(found, "expected a parameter hint");
	};
}

// ── Mixed hints test ────────────────────────────────────────────

fn void mixed_param_and_type_hints() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun add(a: Int, b: Int): Int { return a + b }` "\n"
			`val result = add(1, 2)`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		int type_count = 0;
		int param_count = 0;
		for (usz i = 0; i < result.get_len(); i++) {
			int kind = get_hint_kind(result, i);
			if (kind == 1) type_count++;
			if (kind == 2) param_count++;
		}

		// Should have parameter hints (a:, b:) and a type hint (: Int) for result
		assert(param_count >= 2, "expected at least 2 param hints, got %d", param_count);
		assert(type_count >= 1, "expected at least 1 type hint, got %d", type_count);
	};
}

// ── Padding tests ───────────────────────────────────────────────

fn void param_hint_has_padding_right() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content =
			`fun greet(name: String) {}` "\n"
			`fun main() { greet("Alice") }`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 2) continue;
			Object* hint = result.get_at(i);
			bool pr_val = hint.get_bool("paddingRight")!!;
			assert(pr_val, "expected paddingRight=true for param hint");
		}
	};
}

fn void type_hint_has_padding_left() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String uri = "file:///test.kt";
		String content = `val x = 42`;
		store.open(uri, "kotlin", 1, content);

		Object* params = make_inlay_hint_params(uri, 0, 10);
		Object* result = inlay_hints::handle_inlay_hints(&store, null, params);
		assert(result != null, "expected non-null result");

		for (usz i = 0; i < result.get_len(); i++) {
			if (get_hint_kind(result, i) != 1) continue;
			Object* hint = result.get_at(i);
			bool pl_val = hint.get_bool("paddingLeft")!!;
			assert(pl_val, "expected paddingLeft=true for type hint");
		}
	};
}
