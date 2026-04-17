module kls::test::type_hierarchy_test;

import std::collections::object;
import kls::document;
import kls::lsp::type_hierarchy;
import kls::workspace;
import kls::kotlin::ast;

// ── Helpers ──────────────────────────────────────────────────────

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

fn Object* make_hierarchy_item(String name, String uri) {
	Object* item = object::new_obj(tmem);
	item.set("name", name);
	item.set("uri", uri);
	return item;
}

fn Object* make_supertypes_params(String name, String uri) {
	Object* params = object::new_obj(tmem);
	params.set("item", make_hierarchy_item(name, uri));
	return params;
}

fn Object* make_subtypes_params(String name, String uri) {
	return make_supertypes_params(name, uri);
}

// ── Prepare: unknown document ────────────────────────────────────

fn void prepare_unknown_document_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = type_hierarchy::handle_prepare(&store, null, params);
		assert(result == null, "expected null for unknown document");
	};
}

// ── Prepare: cursor on class name ────────────────────────────────

fn void prepare_on_class_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Foo {}");
		Object* params = make_params("file:///test.kt", 0, 6);
		Object* result = type_hierarchy::handle_prepare(&store, null, params);

		assert(result != null, "expected result for class name");
		assert(result.get_len() == 1, "expected 1 item");

		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "Foo", "expected 'Foo', got '%s'", name);

		int kind = item.get_int("kind")!!;
		assert(kind == 5, "expected Class kind 5, got %d", kind);
	};
}

// ── Prepare: cursor on interface name ────────────────────────────

fn void prepare_on_interface_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "interface Drawable {}");
		Object* params = make_params("file:///test.kt", 0, 10);
		Object* result = type_hierarchy::handle_prepare(&store, null, params);

		assert(result != null, "expected result for interface name");
		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "Drawable", "expected 'Drawable', got '%s'", name);

		int kind = item.get_int("kind")!!;
		assert(kind == 11, "expected Interface kind 11, got %d", kind);
	};
}

// ── Prepare: cursor on keyword returns null ──────────────────────

fn void prepare_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Foo {}");
		Object* params = make_params("file:///test.kt", 0, 0);  // on "class" keyword
		Object* result = type_hierarchy::handle_prepare(&store, null, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── Prepare: cursor on non-type returns null ─────────────────────

fn void prepare_on_function_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");
		Object* params = make_params("file:///test.kt", 0, 4);  // on "main"
		Object* result = type_hierarchy::handle_prepare(&store, null, params);

		assert(result == null, "expected null for function name");
	};
}

// ── Prepare: has correct range and selectionRange ────────────────

fn void prepare_has_ranges() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Foo : Bar {}");
		Object* params = make_params("file:///test.kt", 0, 6);
		Object* result = type_hierarchy::handle_prepare(&store, null, params);

		assert(result != null, "expected result");
		Object* item = result.get_at(0);

		// selectionRange should cover "Foo"
		Object* sel = item.get("selectionRange")!!;
		Object* sel_start = sel.get("start")!!;
		int sel_start_char = sel_start.get_int("character")!!;
		Object* sel_end = sel.get("end")!!;
		int sel_end_char = sel_end.get_int("character")!!;
		assert(sel_start_char == 6, "expected selectionRange start char 6, got %d", sel_start_char);
		assert(sel_end_char == 9, "expected selectionRange end char 9, got %d", sel_end_char);
	};
}

// ── Supertypes: class extending another ──────────────────────────

fn void supertypes_of_derived_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`abstract class Base {}
class Derived : Base() {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_supertypes_params("Derived", "file:///test.kt");
		Object* result = type_hierarchy::handle_supertypes(&store, null, params);

		assert(result != null, "expected supertypes");
		assert(result.get_len() == 1, "expected 1 supertype, got %d", (int)result.get_len());

		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "Base", "expected 'Base', got '%s'", name);
	};
}

// ── Supertypes: class implementing multiple ──────────────────────

fn void supertypes_multiple_interfaces() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`interface Foo {}
interface Bar {}
class Baz : Foo, Bar {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_supertypes_params("Baz", "file:///test.kt");
		Object* result = type_hierarchy::handle_supertypes(&store, null, params);

		assert(result != null, "expected supertypes");
		assert(result.get_len() == 2, "expected 2 supertypes, got %d", (int)result.get_len());
	};
}

// ── Supertypes: no supertypes ────────────────────────────────────

fn void supertypes_no_supertypes() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Standalone {}");

		Object* params = make_supertypes_params("Standalone", "file:///test.kt");
		Object* result = type_hierarchy::handle_supertypes(&store, null, params);

		assert(result == null, "expected null for class with no supertypes");
	};
}

// ── Subtypes: find implementors ──────────────────────────────────

fn void subtypes_finds_implementors() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`interface Animal {}
class Dog : Animal {}
class Cat : Animal {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_subtypes_params("Animal", "file:///test.kt");
		Object* result = type_hierarchy::handle_subtypes(&store, null, params);

		assert(result != null, "expected subtypes");
		assert(result.get_len() == 2, "expected 2 subtypes, got %d", (int)result.get_len());
	};
}

// ── Subtypes: no subtypes ────────────────────────────────────────

fn void subtypes_none() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Leaf {}");

		Object* params = make_subtypes_params("Leaf", "file:///test.kt");
		Object* result = type_hierarchy::handle_subtypes(&store, null, params);

		assert(result == null, "expected null for class with no subtypes");
	};
}

// ── Subtypes: cross-file via workspace index ─────────────────────

fn void subtypes_cross_file() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		store.open("file:///base.kt", "kotlin", 1, "interface Repository {}");
		ws.index_file("file:///impl.kt", "class UserRepo : Repository {}");

		Object* params = make_subtypes_params("Repository", "file:///base.kt");
		Object* result = type_hierarchy::handle_subtypes(&store, &ws, params);

		assert(result != null, "expected cross-file subtypes");
		assert(result.get_len() == 1, "expected 1 cross-file subtype, got %d", (int)result.get_len());

		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "UserRepo", "expected 'UserRepo', got '%s'", name);
	};
}

// ── Supertypes: cross-file via workspace index ───────────────────

fn void supertypes_cross_file() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Base interface not open, but indexed
		ws.index_file("file:///base.kt", "interface Repository {}");
		// Derived class is open
		store.open("file:///impl.kt", "kotlin", 1, "class UserRepo : Repository {}");

		Object* params = make_supertypes_params("UserRepo", "file:///impl.kt");
		Object* result = type_hierarchy::handle_supertypes(&store, &ws, params);

		assert(result != null, "expected supertypes via cross-file");
		assert(result.get_len() == 1, "expected 1 supertype, got %d", (int)result.get_len());

		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "Repository", "expected 'Repository', got '%s'", name);
	};
}

// ── Prepare: object declaration ──────────────────────────────────

fn void prepare_on_object_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "object Singleton {}");
		Object* params = make_params("file:///test.kt", 0, 7);
		Object* result = type_hierarchy::handle_prepare(&store, null, params);

		assert(result != null, "expected result for object name");
		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "Singleton", "expected 'Singleton', got '%s'", name);
	};
}
