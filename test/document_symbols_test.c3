module kls::test::document_symbols_test;

import std::collections::object;
import kls::document;
import kls::lsp::document_symbols;

// ── Helper: build params object ────────────────────────────────────

fn Object* make_params(String uri) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	return params;
}

// ── Single function ────────────────────────────────────────────────

fn void symbol_single_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null, "expected an array result");
		assert(result.get_len() == 1, "expected 1 symbol, got %d", (int)result.get_len());

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "greet", "expected 'greet', got '%s'", name);
		assert(kind == 12, "expected Function (12), got %d", kind);
	};
}

// ── Single class ───────────────────────────────────────────────────

fn void symbol_single_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class MyClass {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "MyClass", "expected 'MyClass', got '%s'", name);
		assert(kind == 5, "expected Class (5), got %d", kind);
	};
}

// ── Interface ──────────────────────────────────────────────────────

fn void symbol_interface() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "interface Drawable {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		int kind = sym.get_int("kind")!!;
		assert(kind == 11, "expected Interface (11), got %d", kind);
	};
}

// ── Object maps to Module (2) ──────────────────────────────────────

fn void symbol_object_is_module() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "object Singleton {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "Singleton", "expected 'Singleton', got '%s'", name);
		assert(kind == 2, "expected Module (2), got %d", kind);
	};
}

// ── Property (val) ─────────────────────────────────────────────────

fn void symbol_val_property() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 42");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "x", "expected 'x', got '%s'", name);
		assert(kind == 7, "expected Property (7), got %d", kind);
	};
}

// ── Typealias maps to Class (5) ────────────────────────────────────

fn void symbol_typealias() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "typealias StringList = List<String>");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "StringList", "expected 'StringList', got '%s'", name);
		assert(kind == 5, "expected Class (5) for typealias, got %d", kind);
	};
}

// ── Multiple symbols ───────────────────────────────────────────────

fn void symbol_multiple_declarations() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`class Foo {}
fun bar() {}
val x = 1
interface Baz {}
object Config {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 5, "expected 5 symbols, got %d", (int)result.get_len());

		// Verify order matches source order
		Object* s0 = result.get_at(0);
		Object* s1 = result.get_at(1);
		Object* s2 = result.get_at(2);
		Object* s3 = result.get_at(3);
		Object* s4 = result.get_at(4);
		assert(s0.get_string("name")!! == "Foo");
		assert(s1.get_string("name")!! == "bar");
		assert(s2.get_string("name")!! == "x");
		assert(s3.get_string("name")!! == "Baz");
		assert(s4.get_string("name")!! == "Config");
	};
}

// ── Empty document ─────────────────────────────────────────────────

fn void symbol_empty_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null, "expected empty array, not null");
		assert(result.get_len() == 0, "expected 0 symbols, got %d", (int)result.get_len());
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void symbol_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Position and range correctness ─────────────────────────────────

fn void symbol_range_correctness() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "fun greet() {}" -- "greet" starts at col 4, length 5
		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		Object* range = sym.get("range")!!;
		Object* start = range.get("start")!!;
		Object* end_pos = range.get("end")!!;
		int start_line = start.get_int("line")!!;
		int start_col = start.get_int("character")!!;
		int end_line = end_pos.get_int("line")!!;
		int end_col = end_pos.get_int("character")!!;

		assert(start_line == 0, "expected start line 0, got %d", start_line);
		assert(start_col == 4, "expected start col 4, got %d", start_col);
		assert(end_line == 0, "expected end line 0, got %d", end_line);
		assert(end_col == 9, "expected end col 9, got %d", end_col);
	};
}

// ── Selection range matches range ──────────────────────────────────

fn void symbol_selection_range_matches() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Widget {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		Object* sym = result.get_at(0);

		Object* range = sym.get("range")!!;
		Object* sel_range = sym.get("selectionRange")!!;

		// Both ranges should be identical
		int r_start_col = range.get("start")!!.get_int("character")!!;
		int r_end_col = range.get("end")!!.get_int("character")!!;
		int s_start_col = sel_range.get("start")!!.get_int("character")!!;
		int s_end_col = sel_range.get("end")!!.get_int("character")!!;

		assert(r_start_col == s_start_col, "range and selectionRange start should match");
		assert(r_end_col == s_end_col, "range and selectionRange end should match");
	};
}

// ── Modifier keywords produce correct kind ─────────────────────────

fn void symbol_data_class_kind() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "data class User(val name: String)");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() >= 1);

		// First symbol should be the class
		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "User", "expected 'User', got '%s'", name);
		assert(kind == 5, "expected Class (5), got %d", kind);
	};
}

// ── Extension function name ────────────────────────────────────────

fn void symbol_extension_function_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun String.greet() {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		int kind = sym.get_int("kind")!!;
		assert(name == "greet", "expected 'greet', got '%s'", name);
		assert(kind == 12, "expected Function (12), got %d", kind);
	};
}

// ── Second-line position tracking ──────────────────────────────────

fn void symbol_second_line_position() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 1\nfun bar() {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params);

		assert(result != null);
		assert(result.get_len() == 2);

		// bar is on line 1, col 4
		Object* sym = result.get_at(1);
		assert(sym.get_string("name")!! == "bar");

		Object* range = sym.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 1, "expected line 1, got %d", line);
		assert(col == 4, "expected col 4, got %d", col);
	};
}
