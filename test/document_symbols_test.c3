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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result == null, "expected null for unknown document");
	};
}

// ── Position and range correctness ─────────────────────────────────

fn void symbol_range_correctness() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "fun greet() {}" -- full decl starts at col 0, ends at col 14
		// "greet" is at col 4, length 5
		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		assert(result.get_len() == 1);

		Object* sym = result.get_at(0);

		// range covers the full declaration
		Object* range = sym.get("range")!!;
		Object* r_start = range.get("start")!!;
		Object* r_end = range.get("end")!!;
		int r_start_line = r_start.get_int("line")!!;
		int r_start_col = r_start.get_int("character")!!;
		int r_end_line = r_end.get_int("line")!!;
		int r_end_col = r_end.get_int("character")!!;
		assert(r_start_line == 0, "expected range start line 0, got %d", r_start_line);
		assert(r_start_col == 0, "expected range start col 0, got %d", r_start_col);
		assert(r_end_line == 0, "expected range end line 0, got %d", r_end_line);
		assert(r_end_col == 14, "expected range end col 14, got %d", r_end_col);

		// selectionRange covers just the name "greet"
		Object* sel_range = sym.get("selectionRange")!!;
		Object* s_start = sel_range.get("start")!!;
		Object* s_end = sel_range.get("end")!!;
		int s_start_col = s_start.get_int("character")!!;
		int s_end_col = s_end.get_int("character")!!;
		assert(s_start_col == 4, "expected selectionRange start col 4, got %d", s_start_col);
		assert(s_end_col == 9, "expected selectionRange end col 9, got %d", s_end_col);
	};
}

// ── Selection range covers the name, range covers declaration ──────

fn void symbol_selection_range_matches() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "class Widget {}" -- full decl: col 0..15, name "Widget" at col 6..12
		store.open("file:///test.kt", "kotlin", 1, "class Widget {}");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		Object* sym = result.get_at(0);

		Object* range = sym.get("range")!!;
		Object* sel_range = sym.get("selectionRange")!!;

		// range covers full declaration
		int r_start_col = range.get("start")!!.get_int("character")!!;
		int r_end_col = range.get("end")!!.get_int("character")!!;
		assert(r_start_col == 0, "expected range start col 0, got %d", r_start_col);
		assert(r_end_col == 15, "expected range end col 15, got %d", r_end_col);

		// selectionRange covers just the name "Widget"
		int s_start_col = sel_range.get("start")!!.get_int("character")!!;
		int s_end_col = sel_range.get("end")!!.get_int("character")!!;
		assert(s_start_col == 6, "expected selectionRange start col 6, got %d", s_start_col);
		assert(s_end_col == 12, "expected selectionRange end col 12, got %d", s_end_col);
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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

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
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		assert(result.get_len() == 2);

		// bar is on line 1
		Object* sym = result.get_at(1);
		assert(sym.get_string("name")!! == "bar");

		// range covers the full declaration starting at col 0
		Object* range = sym.get("range")!!;
		Object* r_start = range.get("start")!!;
		int r_line = r_start.get_int("line")!!;
		int r_col = r_start.get_int("character")!!;
		assert(r_line == 1, "expected range line 1, got %d", r_line);
		assert(r_col == 0, "expected range col 0, got %d", r_col);

		// selectionRange covers just "bar" at col 4
		Object* sel_range = sym.get("selectionRange")!!;
		Object* s_start = sel_range.get("start")!!;
		int s_line = s_start.get_int("line")!!;
		int s_col = s_start.get_int("character")!!;
		assert(s_line == 1, "expected selectionRange line 1, got %d", s_line);
		assert(s_col == 4, "expected selectionRange col 4, got %d", s_col);
	};
}

// ── Hierarchical: class with members ───────────────────────────────

fn void symbol_class_with_members() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`class Foo {
    val x = 1
    fun bar() {}
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		// Top level: 1 class
		assert(result.get_len() == 1, "expected 1 top-level symbol, got %d", (int)result.get_len());

		Object* cls = result.get_at(0);
		assert(cls.get_string("name")!! == "Foo");
		assert(cls.get_int("kind")!! == 5); // Class

		// Children: val x, fun bar
		Object* children = cls.get("children")!!;
		assert(children.get_len() == 2, "expected 2 children, got %d", (int)children.get_len());

		Object* prop = children.get_at(0);
		assert(prop.get_string("name")!! == "x");
		assert(prop.get_int("kind")!! == 7); // Property

		Object* fun = children.get_at(1);
		assert(fun.get_string("name")!! == "bar");
		assert(fun.get_int("kind")!! == 12); // Function
	};
}

// ── Hierarchical: nested classes ───────────────────────────────────

fn void symbol_nested_classes() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`class Outer {
    class Inner {
        fun method() {}
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		assert(result.get_len() == 1);

		Object* outer = result.get_at(0);
		assert(outer.get_string("name")!! == "Outer");

		Object* children = outer.get("children")!!;
		assert(children.get_len() == 1, "expected 1 child (Inner), got %d", (int)children.get_len());

		Object* inner = children.get_at(0);
		assert(inner.get_string("name")!! == "Inner");
		assert(inner.get_int("kind")!! == 5); // Class

		// Inner has a method
		Object* inner_children = inner.get("children")!!;
		assert(inner_children.get_len() == 1, "expected 1 inner child, got %d", (int)inner_children.get_len());
		assert(inner_children.get_at(0).get_string("name")!! == "method");
	};
}

// ── Hierarchical: companion object members ─────────────────────────

fn void symbol_companion_with_members() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`class Foo {
    companion object Factory {
        fun create(): Foo {}
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		assert(result.get_len() == 1);

		Object* cls = result.get_at(0);
		Object* children = cls.get("children")!!;
		assert(children.get_len() == 1, "expected 1 child (companion), got %d", (int)children.get_len());

		Object* companion = children.get_at(0);
		assert(companion.get_string("name")!! == "Factory");
		assert(companion.get_int("kind")!! == 2); // Module

		Object* comp_children = companion.get("children")!!;
		assert(comp_children.get_len() == 1);
		assert(comp_children.get_at(0).get_string("name")!! == "create");
	};
}

// ── Hierarchical: enum with entries ────────────────────────────────

fn void symbol_enum_entries() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "enum class Color { RED, GREEN, BLUE }");

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		assert(result.get_len() == 1);

		Object* cls = result.get_at(0);
		assert(cls.get_string("name")!! == "Color");

		// Enum entries are children
		Object* children = cls.get("children")!!;
		assert(children.get_len() == 3, "expected 3 enum entries, got %d", (int)children.get_len());
		assert(children.get_at(0).get_string("name")!! == "RED");
		assert(children.get_at(1).get_string("name")!! == "GREEN");
		assert(children.get_at(2).get_string("name")!! == "BLUE");

		// Each entry should be EnumMember kind (22)
		assert(children.get_at(0).get_int("kind")!! == 22);
	};
}

// ── Hierarchical: interface with members ───────────────────────────

fn void symbol_interface_with_members() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`interface Drawable {
    fun draw()
    val color: String
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt");
		Object* result = document_symbols::handle_document_symbol(&store, params)!!;

		assert(result != null);
		assert(result.get_len() == 1);

		Object* iface = result.get_at(0);
		assert(iface.get_string("name")!! == "Drawable");
		assert(iface.get_int("kind")!! == 11); // Interface

		Object* children = iface.get("children")!!;
		assert(children.get_len() == 2, "expected 2 children, got %d", (int)children.get_len());
		assert(children.get_at(0).get_string("name")!! == "draw");
		assert(children.get_at(1).get_string("name")!! == "color");
	};
}
