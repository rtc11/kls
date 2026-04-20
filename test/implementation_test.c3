module kls::test::implementation_test;

import std::collections::object;
import std::collections::list;
import kls::document;
import kls::lsp::implementation;
import kls::workspace;
import kls::kotlin::ast;
import kls::kotlin::parser;

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

// ── Parser: TYPE_REF nodes are created for supertypes ──────────────

fn void parser_creates_type_ref_for_supertype() @test {
	@pool() {
		ParseResult* r = mem::new(ParseResult);
		defer { r.free_errors(); mem::free(r); }
		parser::parse("class Foo : Bar {}", r);

		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Find the CLASS_DECL node
		AstNode* cls = null;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CLASS_DECL) {
				cls = &r.nodes[i];
				break;
			}
		}
		assert(cls != null, "expected CLASS_DECL node");
		assert(cls.name == "Foo");

		// Find TYPE_REF child
		uint cls_idx = ast::node_index(r, cls);
		bool found_type_ref = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].parent == cls_idx && r.nodes[i].kind == TYPE_REF) {
				assert(r.nodes[i].name == "Bar", "expected TYPE_REF name 'Bar', got '%s'", r.nodes[i].name);
				found_type_ref = true;
			}
		}
		assert(found_type_ref, "expected TYPE_REF child for supertype 'Bar'");
	};
}

fn void parser_creates_multiple_type_refs() @test {
	@pool() {
		ParseResult* r = mem::new(ParseResult);
		defer { r.free_errors(); mem::free(r); }
		parser::parse("class Foo : Base(), Serializable, Comparable<Foo> {}", r);

		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		uint cls_idx = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CLASS_DECL) {
				cls_idx = i;
				break;
			}
		}

		// Count TYPE_REF children
		usz type_ref_count = 0;
		String[3] names;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].parent == cls_idx && r.nodes[i].kind == TYPE_REF) {
				if (type_ref_count < 3) {
					names[type_ref_count] = r.nodes[i].name;
				}
				type_ref_count++;
			}
		}
		assert(type_ref_count == 3, "expected 3 TYPE_REF children, got %d", (int)type_ref_count);
		assert(names[0] == "Base", "expected 'Base', got '%s'", names[0]);
		assert(names[1] == "Serializable", "expected 'Serializable', got '%s'", names[1]);
		assert(names[2] == "Comparable", "expected 'Comparable', got '%s'", names[2]);
	};
}

fn void parser_interface_supertypes() @test {
	@pool() {
		ParseResult* r = mem::new(ParseResult);
		defer { r.free_errors(); mem::free(r); }
		parser::parse("interface Foo : Bar, Baz {}", r);

		assert(r.error_count == 0, "expected no errors");

		uint iface_idx = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == INTERFACE_DECL) {
				iface_idx = i;
				break;
			}
		}

		usz type_ref_count = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].parent == iface_idx && r.nodes[i].kind == TYPE_REF) {
				type_ref_count++;
			}
		}
		assert(type_ref_count == 2, "expected 2 TYPE_REF children, got %d", (int)type_ref_count);
	};
}

// ── Same-file: class implementing interface ────────────────────────

fn void implementation_class_implements_interface() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`interface Drawable {
    fun draw()
}
class Circle : Drawable {
    fun draw() {}
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Drawable" (the interface name) at line 0, col 10
		Object* params = make_params("file:///test.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result != null, "expected implementation results");
		usz len = result.get_len();
		assert(len == 1, "expected 1 implementation, got %d", (int)len);

		// Verify the location points to Circle
		Object* loc = result.get_at(0);
		Object* range = loc.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 3, "expected Circle at line 3, got %d", line);
	};
}

// ── Same-file: class extending abstract class ──────────────────────

fn void implementation_class_extends_abstract() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`abstract class Shape {
    abstract fun area(): Double
}
class Rectangle : Shape() {
    fun area(): Double = 0.0
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Shape" at line 0, col 16
		Object* params = make_params("file:///test.kt", 0, 16);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result != null, "expected implementation results");
		usz len = result.get_len();
		assert(len == 1, "expected 1 implementation, got %d", (int)len);

		Object* loc = result.get_at(0);;
		Object* range = loc.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 3, "expected Rectangle at line 3, got %d", line);
	};
}

// ── Same-file: multiple implementations ────────────────────────────

fn void implementation_multiple_implementors() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`interface Animal {
    fun speak(): String
}
class Dog : Animal {
    fun speak(): String = "Woof"
}
class Cat : Animal {
    fun speak(): String = "Meow"
}
class Bird : Animal {
    fun speak(): String = "Tweet"
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Animal" at line 0, col 10
		Object* params = make_params("file:///test.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result != null, "expected implementation results");
		usz len = result.get_len();
		assert(len == 3, "expected 3 implementations, got %d", (int)len);
	};
}

// ── Same-file: object implementing interface ───────────────────────

fn void implementation_object_implements_interface() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`interface Logger {
    fun log(msg: String)
}
object ConsoleLogger : Logger {
    fun log(msg: String) {}
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Logger" at line 0, col 10
		Object* params = make_params("file:///test.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result != null, "expected implementation results");
		usz len = result.get_len();
		assert(len == 1, "expected 1 implementation, got %d", (int)len);

		Object* loc = result.get_at(0);
		Object* range = loc.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 3, "expected ConsoleLogger at line 3, got %d", line);
	};
}

// ── No implementations returns null ────────────────────────────────

fn void implementation_no_implementations() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "interface Foo {}\nclass Bar {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 0, col 10
		Object* params = make_params("file:///test.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result == null, "expected null when no implementations exist");
	};
}

// ── Non-identifier returns null ────────────────────────────────────

fn void implementation_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "interface Foo {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "interface" keyword at line 0, col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result == null, "expected null for keyword");
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void implementation_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///nonexistent.kt", 0, 0);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result == null, "expected null for unknown document");
	};
}

// ── Cross-file implementation ──────────────────────────────────────

fn void implementation_cross_file() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines an interface
		String file_a = "interface Repository {}";
		store.open("file:///a.kt", "kotlin", 1, file_a);

		// File B implements the interface (in workspace, not open)
		String file_b = "class UserRepository : Repository {}";
		ws.index_file("file:///b.kt", file_b);

		// Cursor on "Repository" at line 0, col 10 in file A
		Object* params = make_params("file:///a.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, &ws, params) ?? null;

		assert(result != null, "expected cross-file implementation result");
		usz len = result.get_len();
		assert(len == 1, "expected 1 cross-file implementation, got %d", (int)len);

		Object* loc = result.get_at(0);
		String uri = loc.get_string("uri")!!;
		assert(uri == "file:///b.kt", "expected URI 'file:///b.kt', got '%s'", uri);
	};
}

// ── Cross-file: multiple implementations in different files ────────

fn void implementation_cross_file_multiple() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Interface defined in open file
		String iface = "interface Service {}";
		store.open("file:///service.kt", "kotlin", 1, iface);

		// Multiple implementations in workspace
		ws.index_file("file:///impl1.kt", "class ServiceImpl1 : Service {}");
		ws.index_file("file:///impl2.kt", "class ServiceImpl2 : Service {}");
		ws.index_file("file:///impl3.kt", "object ServiceSingleton : Service {}");

		// Cursor on "Service" at line 0, col 10
		Object* params = make_params("file:///service.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, &ws, params) ?? null;

		assert(result != null, "expected cross-file implementations");
		usz len = result.get_len();
		assert(len == 3, "expected 3 cross-file implementations, got %d", (int)len);
	};
}

// ── Class with generic supertype ───────────────────────────────────

fn void implementation_generic_supertype() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`interface Comparable<T> {
    fun compareTo(other: T): Int
}
class MyInt : Comparable<MyInt> {
    fun compareTo(other: MyInt): Int = 0
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Comparable" at line 0, col 10
		Object* params = make_params("file:///test.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result != null, "expected implementation for generic interface");
		usz len = result.get_len();
		assert(len == 1, "expected 1 implementation, got %d", (int)len);
	};
}

// ── Class with primary constructor and supertype ───────────────────

fn void implementation_class_with_constructor_supertype() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`abstract class Base(val id: Int)
class Derived(id: Int) : Base(id) {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Base" at line 0, col 16
		Object* params = make_params("file:///test.kt", 0, 16);
		Object* result = implementation::handle_implementation(&store, null, params) ?? null;

		assert(result != null, "expected implementation result");
		usz len = result.get_len();
		assert(len == 1, "expected 1 implementation, got %d", (int)len);

		Object* loc = result.get_at(0);
		Object* range = loc.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 1, "expected Derived at line 1, got %d", line);
	};
}

// ── Same-file + cross-file combined ────────────────────────────────

fn void implementation_mixed_same_and_cross_file() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Interface + one impl in same file
		String content =
`interface Validator {}
class EmailValidator : Validator {}`;
		store.open("file:///main.kt", "kotlin", 1, content);

		// Another impl in workspace
		ws.index_file("file:///other.kt", "class PhoneValidator : Validator {}");

		// Cursor on "Validator" at line 0, col 10
		Object* params = make_params("file:///main.kt", 0, 10);
		Object* result = implementation::handle_implementation(&store, &ws, params) ?? null;

		assert(result != null, "expected implementation results");
		usz len = result.get_len();
		assert(len == 2, "expected 2 implementations (1 same-file + 1 cross-file), got %d", (int)len);
	};
}

// ── Symbol scanner: supertypes are captured ────────────────────────

fn void symbol_scanner_captures_supertypes() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///test.kt", "class Foo : Bar, Baz {}");

		// Verify super_index has entries for Bar and Baz
		if (try indices = ws.lookup_by_supertype("Bar")) {
			assert(indices.len() >= 1, "expected at least 1 implementor of Bar");
			WorkspaceSymbol* sym = ws.get_symbol(indices.get(0));
			assert(sym.name == "Foo", "expected implementor 'Foo', got '%s'", sym.name);
		} else {
			assert(false, "expected to find 'Bar' in super_index");
		}

		if (try indices = ws.lookup_by_supertype("Baz")) {
			assert(indices.len() >= 1, "expected at least 1 implementor of Baz");
		} else {
			assert(false, "expected to find 'Baz' in super_index");
		}
	};
}

fn void symbol_scanner_supertypes_with_generics() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///test.kt", "class MyList : ArrayList<String>(), Serializable {}");

		if (try indices = ws.lookup_by_supertype("ArrayList")) {
			assert(indices.len() >= 1, "expected at least 1 implementor of ArrayList");
		} else {
			assert(false, "expected to find 'ArrayList' in super_index");
		}

		if (try indices = ws.lookup_by_supertype("Serializable")) {
			assert(indices.len() >= 1, "expected at least 1 implementor of Serializable");
		} else {
			assert(false, "expected to find 'Serializable' in super_index");
		}
	};
}

fn void symbol_scanner_no_supertypes() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///test.kt", "class Standalone {}");

		// Should not have any entries in super_index for this class
		List{usz}* indices = ws.lookup_by_supertype("Standalone") ?? null;
		assert(indices == null, "expected no super_index entries for Standalone");
	};
}
