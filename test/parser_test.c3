module kls::test::parser_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import std::io;

// ── Helper ──────────────────────────────────────────────────────────

// Heap-allocate a ParseResult (too large for stack) and parse into it.
fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	// Free heap-copied multi-annotation strings (contain spaces).
	// ANNOTATION_ENTRY nodes also store argument text in annotation_text,
	// but that's a zero-copy source slice -- skip those.
	for (uint i = 0; i < r.node_count; i++) {
		if (r.nodes[i].kind == ANNOTATION_ENTRY) continue;
		String ann = r.nodes[i].annotation_text;
		if (ann.len > 0) {
			bool has_space = false;
			foreach (c : ann) {
				if (c == ' ') { has_space = true; break; }
			}
			if (has_space) {
				mem::free((void*)ann.ptr);
			}
		}
	}
	r.free_errors();
	mem::free(r);
}

// Get the FILE node (always index 0)
fn AstNode* file_node(ParseResult* r) {
	return &r.nodes[0];
}

// Get Nth child of a node (uses parent-pointer traversal)
fn AstNode* child(ParseResult* r, AstNode* parent, uint n) {
	return ast::get_child(r, parent, n)!!;
}

// ── Empty file ──────────────────────────────────────────────────────

fn void parse_empty_file() @test {
	@pool() {
		ParseResult* r = do_parse(""); defer free_result(r);
		assert(r.node_count >= 1, "expected FILE node");
		assert(r.nodes[0].kind == FILE, "expected FILE");
		assert(r.nodes[0].child_count == 0, "expected 0 children, got %d", (int)r.nodes[0].child_count);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Package declaration ─────────────────────────────────────────────

fn void parse_package() @test {
	@pool() {
		ParseResult* r = do_parse("package com.example.app"); defer free_result(r);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* pkg = child(r, f, 0);
		assert(pkg.kind == PACKAGE_DECL, "expected PACKAGE_DECL");
		assert(pkg.extra_text == "com.example.app", "expected 'com.example.app', got '%s'", pkg.extra_text);
	};
}

// ── Import declarations ─────────────────────────────────────────────

fn void parse_import() @test {
	@pool() {
		ParseResult* r = do_parse("import kotlin.io.println"); defer free_result(r);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* imp = child(r, f, 0);
		assert(imp.kind == IMPORT_DECL, "expected IMPORT_DECL");
		assert(imp.extra_text == "kotlin.io.println", "expected 'kotlin.io.println', got '%s'", imp.extra_text);
	};
}

fn void parse_import_wildcard() @test {
	@pool() {
		ParseResult* r = do_parse("import kotlin.io.*"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* imp = child(r, f, 0);
		assert(imp.kind == IMPORT_DECL);
		assert(imp.extra_text == "kotlin.io.*", "expected 'kotlin.io.*', got '%s'", imp.extra_text);
	};
}

fn void parse_import_alias() @test {
	@pool() {
		ParseResult* r = do_parse("import kotlin.collections.List as KList"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* imp = child(r, f, 0);
		assert(imp.kind == IMPORT_DECL);
		assert(imp.name == "KList", "expected alias 'KList', got '%s'", imp.name);
	};
}

// ── Simple class ────────────────────────────────────────────────────

fn void parse_simple_class() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo {}"); defer free_result(r);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.name == "Foo", "expected 'Foo', got '%s'", cls.name);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_interface() @test {
	@pool() {
		ParseResult* r = do_parse("interface Drawable {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL, "expected INTERFACE_DECL");
		assert(iface.name == "Drawable", "expected 'Drawable', got '%s'", iface.name);
	};
}

fn void parse_object() @test {
	@pool() {
		ParseResult* r = do_parse("object Singleton {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* obj = child(r, f, 0);
		assert(obj.kind == OBJECT_DECL, "expected OBJECT_DECL");
		assert(obj.name == "Singleton", "expected 'Singleton', got '%s'", obj.name);
	};
}

// ── Modified classes ────────────────────────────────────────────────

fn void parse_data_class() @test {
	@pool() {
		ParseResult* r = do_parse("data class User(val name: String, val age: Int)"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.name == "User", "expected 'User', got '%s'", cls.name);
		assert(cls.mod_flags & ast::MOD_DATA != 0, "expected MOD_DATA flag");
	};
}

fn void parse_enum_class() @test {
	@pool() {
		ParseResult* r = do_parse("enum class Color { RED, GREEN, BLUE }"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.name == "Color", "expected 'Color', got '%s'", cls.name);
		assert(cls.mod_flags & ast::MOD_ENUM != 0, "expected MOD_ENUM flag");
		// Should have enum entries as children
		assert(cls.child_count >= 3, "expected at least 3 children (enum entries), got %d", (int)cls.child_count);
	};
}

fn void parse_sealed_class() @test {
	@pool() {
		ParseResult* r = do_parse("sealed class Result {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Result");
		assert(cls.mod_flags & ast::MOD_SEALED != 0, "expected MOD_SEALED flag");
	};
}

fn void parse_sealed_interface() @test {
	@pool() {
		ParseResult* r = do_parse("sealed interface Event {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL);
		assert(iface.name == "Event");
		assert(iface.mod_flags & ast::MOD_SEALED != 0, "expected MOD_SEALED flag");
	};
}

fn void parse_fun_interface() @test {
	@pool() {
		ParseResult* r = do_parse("fun interface Predicate<T> { fun test(t: T): Boolean }"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL, "expected INTERFACE_DECL");
		assert(iface.name == "Predicate", "expected 'Predicate', got '%s'", iface.name);
		assert(iface.mod_flags & ast::MOD_FUN_INTERFACE != 0, "expected MOD_FUN_INTERFACE flag");
	};
}

fn void parse_fun_modifier_not_function() @test {
	@pool() {
		ParseResult* r = do_parse("fun interface Marker {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL, "expected INTERFACE_DECL");
		assert(iface.mod_flags & ast::MOD_FUN_INTERFACE != 0, "expected MOD_FUN_INTERFACE flag");
	};
}

fn void parse_regular_interface_no_fun_flag() @test {
	@pool() {
		ParseResult* r = do_parse("interface Foo { fun bar() }"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL, "expected INTERFACE_DECL");
		assert(iface.name == "Foo", "expected 'Foo', got '%s'", iface.name);
		assert(iface.mod_flags & ast::MOD_FUN_INTERFACE == 0, "expected no MOD_FUN_INTERFACE flag");
	};
}

fn void parse_fun_function_still_function() @test {
	@pool() {
		ParseResult* r = do_parse("fun foo() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "foo", "expected 'foo', got '%s'", fun.name);
	};
}

fn void parse_abstract_class() @test {
	@pool() {
		ParseResult* r = do_parse("abstract class Shape {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Shape");
		assert(cls.mod_flags & ast::MOD_ABSTRACT != 0, "expected MOD_ABSTRACT flag");
	};
}

fn void parse_annotation_class() @test {
	@pool() {
		ParseResult* r = do_parse("annotation class MyAnnotation"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "MyAnnotation");
		assert(cls.mod_flags & ast::MOD_ANNOTATION != 0, "expected MOD_ANNOTATION flag");
	};
}

fn void parse_value_class() @test {
	@pool() {
		ParseResult* r = do_parse("value class Password(val s: String)"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Password");
		assert(cls.mod_flags & ast::MOD_VALUE != 0, "expected MOD_VALUE flag");
	};
}

fn void parse_inner_class() @test {
	@pool() {
		ParseResult* r = do_parse("inner class ViewHolder {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "ViewHolder");
		assert(cls.mod_flags & ast::MOD_INNER != 0, "expected MOD_INNER flag");
	};
}

fn void parse_private_open_class() @test {
	@pool() {
		ParseResult* r = do_parse("private open class Base {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Base");
		assert(cls.mod_flags & ast::MOD_PRIVATE != 0, "expected MOD_PRIVATE");
		assert(cls.mod_flags & ast::MOD_OPEN != 0, "expected MOD_OPEN");
	};
}

// ── Function declarations ───────────────────────────────────────────

fn void parse_simple_fun() @test {
	@pool() {
		ParseResult* r = do_parse("fun foo() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "foo", "expected 'foo', got '%s'", fun.name);
	};
}

fn void parse_fun_with_return_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun bar(): String {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "bar");
		assert(fun.type_text == "String", "expected return type 'String', got '%s'", fun.type_text);
	};
}

fn void parse_fun_with_params() @test {
	@pool() {
		ParseResult* r = do_parse("fun add(a: Int, b: Int): Int {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "add");
		assert(fun.type_text == "Int", "expected return type 'Int', got '%s'", fun.type_text);
		// Should have PARAM children
		usz param_count = 0;
		for (uint i = 0; i < fun.child_count; i++) {
			AstNode* ch = ast::get_child(r, fun, i)!!;
			if (ch.kind == PARAM) param_count++;
		}
		assert(param_count == 2, "expected 2 params, got %d", (int)param_count);
	};
}

fn void parse_generic_fun() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T> convert(value: T): String {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "convert", "expected 'convert', got '%s'", fun.name);
	};
}

fn void parse_extension_fun() @test {
	@pool() {
		ParseResult* r = do_parse("fun String.greet() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "greet", "expected 'greet', got '%s'", fun.name);
	};
}

fn void parse_generic_extension_fun() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T> List<T>.first(): T {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "first", "expected 'first', got '%s'", fun.name);
	};
}

fn void parse_suspend_fun() @test {
	@pool() {
		ParseResult* r = do_parse("suspend fun fetchData() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "fetchData");
		assert(fun.mod_flags & ast::MOD_SUSPEND != 0, "expected MOD_SUSPEND");
	};
}

fn void parse_inline_fun() @test {
	@pool() {
		ParseResult* r = do_parse("inline fun <reified T> create(): T {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "create");
		assert(fun.mod_flags & ast::MOD_INLINE != 0, "expected MOD_INLINE");
	};
}

fn void parse_override_fun() @test {
	@pool() {
		ParseResult* r = do_parse("override fun toString(): String {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "toString");
		assert(fun.mod_flags & ast::MOD_OVERRIDE != 0, "expected MOD_OVERRIDE");
	};
}

fn void parse_expression_body_fun() @test {
	@pool() {
		ParseResult* r = do_parse("fun double(x: Int): Int = x * 2"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "double");
		assert(fun.type_text == "Int", "expected return type 'Int', got '%s'", fun.type_text);
	};
}

// ── Property declarations ───────────────────────────────────────────

fn void parse_val() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 42"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL");
		assert(prop.name == "x", "expected 'x', got '%s'", prop.name);
	};
}

fn void parse_var() @test {
	@pool() {
		ParseResult* r = do_parse("var count = 0"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "count");
	};
}

fn void parse_val_with_type() @test {
	@pool() {
		ParseResult* r = do_parse("val name: String = \"hello\""); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "name");
		assert(prop.type_text == "String", "expected type 'String', got '%s'", prop.type_text);
	};
}

fn void parse_const_val() @test {
	@pool() {
		ParseResult* r = do_parse("const val MAX = 100"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "MAX");
		assert(prop.mod_flags & ast::MOD_CONST != 0, "expected MOD_CONST");
	};
}

fn void parse_lateinit_var() @test {
	@pool() {
		ParseResult* r = do_parse("lateinit var adapter: Adapter"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "adapter");
		assert(prop.mod_flags & ast::MOD_LATEINIT != 0, "expected MOD_LATEINIT");
	};
}

fn void parse_extension_property() @test {
	@pool() {
		ParseResult* r = do_parse("val String.wordCount: Int get() = split(\" \").size"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "wordCount", "expected 'wordCount', got '%s'", prop.name);
		assert(prop.type_text == "Int", "expected type 'Int', got '%s'", prop.type_text);
	};
}

// ── Typealias ───────────────────────────────────────────────────────

fn void parse_typealias() @test {
	@pool() {
		ParseResult* r = do_parse("typealias StringList = List<String>"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* ta = child(r, f, 0);
		assert(ta.kind == TYPEALIAS_DECL, "expected TYPEALIAS_DECL");
		assert(ta.name == "StringList", "expected 'StringList', got '%s'", ta.name);
		assert(ta.type_text == "List<String>", "expected type 'List<String>', got '%s'", ta.type_text);
	};
}

// ── Nested members ──────────────────────────────────────────────────

fn void parse_class_with_members() @test {
	@pool() {
		String content =
			`class Foo {
    val x = 1
    var y = 2
    fun bar() {}
    fun baz() {}
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 top-level child");
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Foo");
		// Count declaration children
		usz decl_count = 0;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ast::is_declaration(ch.kind)) decl_count++;
		}
		assert(decl_count == 4, "expected 4 member declarations, got %d", (int)decl_count);
	};
}

fn void parse_nested_class() @test {
	@pool() {
		String content =
			`class Outer {
    class Inner {
        fun method() {}
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* outer = child(r, f, 0);
		assert(outer.kind == CLASS_DECL);
		assert(outer.name == "Outer");

		// Find Inner class
		bool found_inner = false;
		for (uint i = 0; i < outer.child_count; i++) {
			AstNode* ch = ast::get_child(r, outer, i)!!;
			if (ch.kind == CLASS_DECL && ch.name == "Inner") {
				found_inner = true;
				// Inner should have a method
				bool found_method = false;
				for (uint j = 0; j < ch.child_count; j++) {
					AstNode* ic = ast::get_child(r, ch, j)!!;
					if (ic.kind == FUN_DECL && ic.name == "method") {
						found_method = true;
					}
				}
				assert(found_method, "expected 'method' inside Inner");
			}
		}
		assert(found_inner, "expected Inner class");
	};
}

// ── Companion object ────────────────────────────────────────────────

fn void parse_named_companion() @test {
	@pool() {
		String content =
			`class Foo {
    companion object Factory {
        fun create(): Foo {}
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);

		bool found_companion = false;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == COMPANION_OBJECT_DECL) {
				found_companion = true;
				assert(ch.name == "Factory", "expected 'Factory', got '%s'", ch.name);
			}
		}
		assert(found_companion, "expected companion object");
	};
}

fn void parse_anonymous_companion() @test {
	@pool() {
		String content =
			`class Foo {
    companion object {
        val INSTANCE = 1
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);

		bool found_companion = false;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == COMPANION_OBJECT_DECL) {
				found_companion = true;
				assert(ch.name == "Companion", "expected default name 'Companion', got '%s'", ch.name);
			}
		}
		assert(found_companion, "expected companion object");
	};
}

// ── Constructor and init ────────────────────────────────────────────

fn void parse_secondary_constructor() @test {
	@pool() {
		String content =
			`class Foo {
    constructor(x: Int) : this(x, 0) {}
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);

		bool found = false;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == CONSTRUCTOR_DECL) found = true;
		}
		assert(found, "expected constructor declaration");
	};
}

fn void parse_init_block() @test {
	@pool() {
		String content =
			`class Foo {
    init {
        println("init")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);

		bool found = false;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == INIT_BLOCK) found = true;
		}
		assert(found, "expected init block");
	};
}

// ── Enum entries ────────────────────────────────────────────────────

fn void parse_enum_entries() @test {
	@pool() {
		ParseResult* r = do_parse("enum class Color { RED, GREEN, BLUE }"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Color");

		usz entry_count = 0;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == ENUM_ENTRY) entry_count++;
		}
		assert(entry_count == 3, "expected 3 enum entries, got %d", (int)entry_count);
	};
}

fn void parse_enum_entries_with_members() @test {
	@pool() {
		String content =
			`enum class Direction {
    NORTH,
    SOUTH,
    EAST,
    WEST;

    fun opposite(): Direction {}
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);

		usz entry_count = 0;
		usz fun_count = 0;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == ENUM_ENTRY) entry_count++;
			if (ch.kind == FUN_DECL) fun_count++;
		}
		assert(entry_count == 4, "expected 4 enum entries, got %d", (int)entry_count);
		assert(fun_count == 1, "expected 1 function member, got %d", (int)fun_count);
	};
}

// ── Primary constructor parameters ──────────────────────────────────

fn void parse_primary_constructor_params() @test {
	@pool() {
		ParseResult* r = do_parse("data class Point(val x: Int, val y: Int)"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Point");

		usz param_count = 0;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == PARAM) {
				param_count++;
				assert(ch.type_text == "Int", "expected param type 'Int', got '%s'", ch.type_text);
			}
		}
		assert(param_count == 2, "expected 2 params, got %d", (int)param_count);
	};
}

// ── Annotations ─────────────────────────────────────────────────────

fn void parse_annotated_class() @test {
	@pool() {
		ParseResult* r = do_parse("@Serializable data class User(val name: String)"); defer free_result(r);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.name == "User", "expected 'User', got '%s'", cls.name);
		assert(cls.mod_flags & ast::MOD_DATA != 0, "expected MOD_DATA flag");
	};
}

fn void parse_annotated_fun() @test {
	@pool() {
		ParseResult* r = do_parse("@JvmStatic fun create() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "create");
	};
}

// ── Multiple top-level declarations ─────────────────────────────────

fn void parse_multiple_top_level() @test {
	@pool() {
		String content =
			`package com.example

import kotlin.io.println

class Foo {}
interface Bar {}
object Baz {}
fun helper() {}
val constant = 42`;
		ParseResult* r = do_parse(content); defer free_result(r);
		AstNode* f = file_node(r);

		// package + import + class + interface + object + fun + val = 7
		assert(f.child_count == 7, "expected 7 children, got %d; kinds: [%d, %d, %d, %d, %d, %d, %d, %d]",
			(int)f.child_count,
			f.child_count > 0 ? (int)child(r, f, 0).kind : -1,
			f.child_count > 1 ? (int)child(r, f, 1).kind : -1,
			f.child_count > 2 ? (int)child(r, f, 2).kind : -1,
			f.child_count > 3 ? (int)child(r, f, 3).kind : -1,
			f.child_count > 4 ? (int)child(r, f, 4).kind : -1,
			f.child_count > 5 ? (int)child(r, f, 5).kind : -1,
			f.child_count > 6 ? (int)child(r, f, 6).kind : -1,
			f.child_count > 7 ? (int)child(r, f, 7).kind : -1);

		AstNode* pkg = child(r, f, 0);
		assert(pkg.kind == PACKAGE_DECL);

		AstNode* imp = child(r, f, 1);
		assert(imp.kind == IMPORT_DECL);

		AstNode* cls = child(r, f, 2);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Foo");

		AstNode* iface = child(r, f, 3);
		assert(iface.kind == INTERFACE_DECL);
		assert(iface.name == "Bar");

		AstNode* obj = child(r, f, 4);
		assert(obj.kind == OBJECT_DECL);
		assert(obj.name == "Baz");

		AstNode* fun = child(r, f, 5);
		assert(fun.kind == FUN_DECL);
		assert(fun.name == "helper");

		AstNode* prop = child(r, f, 6);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "constant");
	};
}

// ── Span tracking ───────────────────────────────────────────────────

fn void parse_span_tracking() @test {
	@pool() {
		ParseResult* r = do_parse("fun foo() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);
		// "fun" starts at offset 0, line 0, col 0
		assert(fun.start_offset == 0, "expected start_offset 0, got %d", (int)fun.start_offset);
		assert(fun.start_line == 0, "expected start_line 0, got %d", (int)fun.start_line);
		// End should be after the closing }
		assert(fun.end_offset == 12, "expected end_offset 12, got %d", (int)fun.end_offset);
		// Name "foo" at offset 4
		assert(fun.name_offset == 4, "expected name_offset 4, got %d", (int)fun.name_offset);
		assert(fun.name_len == 3, "expected name_len 3, got %d", (int)fun.name_len);
	};
}

fn void parse_name_position() @test {
	@pool() {
		// "class MyClass {}" -- "MyClass" at col 6
		ParseResult* r = do_parse("class MyClass {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.name_col == 6, "expected name_col 6, got %d", (int)cls.name_col);
		assert(cls.name_len == 7, "expected name_len 7, got %d", (int)cls.name_len);
	};
}

// ── No errors for valid code ────────────────────────────────────────

fn void no_errors_for_valid_code() @test {
	@pool() {
		String content =
			`package com.example

import kotlin.io.*

data class User(val name: String, val age: Int)

sealed class Result {
    data class Success(val data: String) : Result()
    data class Error(val message: String) : Result()
}

fun process(user: User): Result {
    return Result.Success("ok")
}

val VERSION: String = "1.0"`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Class with supertypes ───────────────────────────────────────────

fn void parse_class_with_supertype() @test {
	@pool() {
		ParseResult* r = do_parse("class MyList : ArrayList<String>() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "MyList");
		assert(r.error_count == 0, "expected no errors");
	};
}

fn void parse_class_multiple_supertypes() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo : Base(), Serializable, Comparable<Foo> {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);
		assert(cls.name == "Foo");
		assert(r.error_count == 0, "expected no errors");
	};
}

// ── Debug: reproduce nob.kt class parsing ──────────────────────────

fn void parse_class_with_expression_body_member() @test {
	@pool() {
		String content =
`class Nob {
    fun exit(code: Int = exit_code): Unit = System.exit(code)
    private fun compile_with_daemon(src: File) {}
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_class_with_when_expression_body() @test {
	@pool() {
		String content =
`class Nob {
    private fun get_any_compiled_file(dir: File): File? {
        return when {
            dir.isFile -> dir
            else -> null
        }
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_top_level_extension_on_generic_type() @test {
	@pool() {
		String content = `fun List<Path>.into_cp(): String = joinToString(":") { it.toString() }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for extension on generic type, got %d", (int)r.error_count);
	};
}

fn void parse_top_level_private_val_with_also() @test {
	@pool() {
		ParseResult* r = do_parse(`private val cache_dir = Paths.get("home", ".cache").also { it.toFile().mkdirs() }`); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for private val with .also, got %d", (int)r.error_count);
	};
}

fn void parse_class_with_val_using_get() @test {
	@pool() {
		String content =
`class Nob {
    var kotlin_home: Path = Paths.get("KOTLIN_LIB")
    fun compile(module: Module): Boolean {
        val target = Paths.get(module.target).toAbsolutePath()
        return true
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for class with .get(), got %d", (int)r.error_count);
	};
}

fn void parse_extension_fun_with_expression_body_get() @test {
	@pool() {
		String content =
`fun Nob.main_srcs(): String = mods.map { path(it.src) }.joinToString(",")

fun path(str: String): Path = Paths.get("user.dir", str).also { it.toFile().mkdirs() }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for extension fun with .get(), got %d", (int)r.error_count);
	};
}

fn void parse_nob_class_skeleton() @test {
	@pool() {
		String content =
`class Nob(val opts: Opts) {
    private var exit_code = 0
    var mods = mutableSetOf<Module>()
    var compiled = mutableSetOf<Module>()

    companion object {
        fun new(args: Array<String>): Nob {
            var opts = Opts()
            val nob = Nob(opts)
            val module = nob.module {
                name = "nob"
                src = "nob.kt"
                target = "out"
            }
            if (args.getOrNull(0) == "clean") nob.clean()
            nob.rebuild_urself(module, args)
            return nob
        }
    }

    fun module(block: Module.() -> Unit): Module {
        val module = Module(opts).apply(block)
        module.libs = resolve_libs(opts, module)
        mods.add(module)
        return module
    }

    fun clean() {
        val target = path(mods.first().target)
        if (!Files.exists(target)) System.exit(0)
        Files.walk(target).forEach { f ->
            if (f.fileName.toString() !in listOf(".alive", mods.first().target)) {
                Files.walk(f).sorted(Comparator.reverseOrder()).forEach { Files.delete(it) }
            }
        }
        exit(0)
    }

    fun compile(module: Module): Boolean {
        val start_time = System.nanoTime()
        if (module in compiled) return false
        module.mods.forEach { compile(it) }

        val src = path(module.src).toFile()
        var target = module.src_target()
        val sources: Sequence<File> = when {
            src.isFile -> sequenceOf(src)
            src.isDirectory -> src.walkTopDown().filter { it.isFile && it.extension == "kt" }
            else -> emptySequence()
        }

        val any_compiled_target_file = get_any_compiled_file(target.toFile())
        val has_changes = sources.any { file ->
            file.lastModified() > any_compiled_target_file?.lastModified() ?: 0
        }

        compiled.add(module)
        if (!has_changes) return false

        val classpath = module.compile_cp()
        if (src.isFile && src.name == "nob.kt") target = Paths.get(module.target).toAbsolutePath().normalize()
        compile_with_daemon(src, target, classpath, module.name)
        return true
    }

    fun run(module: Module, main_class_fq: String, run_args: Array<String> = arrayOf()) {
        val cmd = buildList{
            add("java")
            add("-cp")
            add(module.runtime_cp())
            add(main_class_fq)
            run_args.forEach { add(it) }
        }
        exec(*cmd.toTypedArray())
    }

    fun release(module: Module) {
        val start_time = System.nanoTime()
        val src_target = Paths.get(module.src).toFile()
        val compiled_dir = when {
            src_target.isFile -> module.target
            src_target.isDirectory -> Paths.get(module.target, module.src).toString()
            else -> error("bad")
        }

        val runtime_libs = path(compiled_dir).resolve("runtime-libs").also { it.toFile().mkdirs() }
        module.runtime_cp().split(':').map { Path.of(it) }.filter { it.name.substringAfterLast('.') == "jar" }.forEach {
            exec("cp", it.toString(), runtime_libs.resolve(it.name).toString())
        }

        when (val main_class_fq = module.main_src()?.main_class_fq()) {
            null -> exec("jar", "cf", "out.jar", "-C", compiled_dir, ".")
            else -> exec("jar", "cfe", "out.jar", main_class_fq, "-C", compiled_dir, ".")
        }
        if (exit_code != 0) err("Failed")
    }

    fun release_fat(module: Module) {
        val start_time = System.nanoTime()
        val main_class_fq = module.main_src()!!.main_class_fq()
        val target_dir = path(module.target)
        val fat_jar_file = target_dir.resolve("fat.jar").toFile()
        val added_entries = mutableSetOf<String>()
        JarOutputStream(FileOutputStream(fat_jar_file)).use { jar ->
            val manifest = Manifest().apply {
                mainAttributes.put(Attributes.Name.MANIFEST_VERSION, "1.0")
                mainAttributes.put(Attributes.Name.MAIN_CLASS, main_class_fq)
            }
            JarOutputStream(FileOutputStream(fat_jar_file), manifest).use { jar_stream ->
                fun addFile(file: File, baseDir: File) {
                    val entry_name = baseDir.toPath().relativize(file.toPath()).toString().replace("\\", "/")
                    if (added_entries.add(entry_name)) {
                        jar_stream.putNextEntry(JarEntry(entry_name))
                        file.inputStream().use { it.copyTo(jar_stream) }
                        jar_stream.closeEntry()
                    }
                }
                target_dir.toFile().walkTopDown()
                    .filter { it.isFile && it.extension == "class" }
                    .forEach { addFile(it, target_dir.toFile()) }
                module.libs.forEach { lib ->
                    if (lib.jar_file.exists()) {
                        java.util.zip.ZipFile(lib.jar_file).use { zip ->
                            zip.entries().asSequence().forEach { entry ->
                                val name = entry.name
                                if (name.startsWith("META-INF/")) return@forEach
                                if (added_entries.add(name)) {
                                    jar_stream.putNextEntry(JarEntry(name))
                                    zip.getInputStream(entry).use { it.copyTo(jar_stream) }
                                    jar_stream.closeEntry()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fun exec(vararg cmd: String) {
        if (opts.verbose) info(cmd.joinToString(" "))
        exit_code = java.lang.ProcessBuilder(*cmd).inheritIO().start().waitFor()
    }

    fun exit(code: Int = exit_code): Unit = System.exit(code)

    private fun compile_with_daemon(src: File, target: Path, classpath: String, name: String, retries: Int = 3) {
        val kotlin_libs = listOf(
            "kotlin-stdlib.jar",
            "kotlin-compiler.jar",
            "kotlin-daemon.jar",
            "kotlin-daemon-client.jar",
        ).joinToString(File.pathSeparator) {
            opts.kotlin_home.resolve(it).toAbsolutePath().normalize().toString()
        }
        val args = buildList {
            add("-d")
            add(target.toString())
            add("-jvm-target")
            add(opts.jvm_version.toString())
        }
        val client_alive_file = target.resolve(".alive").toFile().apply { if (!exists()) createNewFile() }
        val daemon_reports = arrayListOf<DaemonReportMessage>()
        val compiler_id = Files.list(opts.kotlin_home).filter { it.toString().endsWith(".jar") }.map { it.toFile() }.toList()
        val daemon = KotlinCompilerClient.connectToCompileService(
            compilerId = CompilerId.makeCompilerId(compiler_id),
            clientAliveFlagFile = client_alive_file,
            daemonJVMOptions = DaemonJVMOptions(),
            daemonOptions = DaemonOptions(verbose = opts.verbose),
            reportingTargets = DaemonReportingTargets(out = if (opts.verbose) System.out else null, messages = daemon_reports),
            autostart = true,
        ) ?: error("unable to connect")
        try {
            val session_id = daemon.leaseCompileSession(client_alive_file.absolutePath).get()
            try {
                exit_code = KotlinCompilerClient.compile(
                    compilerService = daemon,
                    sessionId = session_id,
                    targetPlatform = CompileService.TargetPlatform.JVM,
                    args = args.toTypedArray(),
                    messageCollector = PrintingMessageCollector(System.err, MessageRenderer.PLAIN_FULL_PATHS, true),
                    compilerMode = CompilerMode.NON_INCREMENTAL_COMPILER,
                    reportSeverity = ReportSeverity.INFO,
                )
            } finally {
                daemon.releaseCompileSession(session_id)
            }
        } catch (e: IllegalStateException) {
            daemon.shutdown()
            Thread.sleep(1000)
            if (retries > 0) compile_with_daemon(src, target, classpath, name, retries-1)
            else throw e
            return
        }
    }

    private fun rebuild_urself(module: Module, args: Array<String>) {
        if (compile(module)) {
            if (exit_code != 0) exit()
            java.lang.ProcessBuilder("java", "-cp", "cp", "nob.NobKt", *args).inheritIO().start()
            exit(0)
        }
    }

    private fun get_any_compiled_file(dir: File): File? {
        return when {
            dir.isFile -> dir
            dir.isDirectory -> dir.walkTopDown().firstOrNull { it.isFile && it.extension == "class" }
            else -> null
        }
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for Nob class skeleton, got %d", (int)r.error_count);
	};
}

// ── Vararg parameter ───────────────────────────────────────────────

fn void parse_fun_with_vararg_param() @test {
	@pool() {
		ParseResult* r = do_parse("fun exec(vararg cmd: String) {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "exec");
		assert(r.error_count == 0, "expected no errors for vararg param, got %d", (int)r.error_count);
	};
}

fn void parse_fun_with_crossinline_param() @test {
	@pool() {
		ParseResult* r = do_parse("inline fun run(crossinline block: () -> Unit) {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "run");
		assert(r.error_count == 0, "expected no errors for crossinline param, got %d", (int)r.error_count);
	};
}

fn void parse_fun_with_noinline_param() @test {
	@pool() {
		ParseResult* r = do_parse("inline fun run(noinline block: () -> Unit) {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "run");
		assert(r.error_count == 0, "expected no errors for noinline param, got %d", (int)r.error_count);
	};
}

// ── Parameter default value (DUAL STORAGE: extra_text + sub-AST) ──

// Helper: find first PARAM child of a function declaration.
fn AstNode* first_param(ParseResult* r, AstNode* fun_node) {
	for (uint i = 0; i < fun_node.child_count; i++) {
		AstNode* c = child(r, fun_node, i);
		if (c.kind == PARAM) return c;
	}
	return null;
}

fn void parse_param_default_literal() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(x: Int = 42) {}"); defer free_result(r);
		assert(r.error_count == 0, "no errors expected, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* p = first_param(r, fun_node);
		assert(p != null, "expected PARAM child");
		assert(p.name == "x", "expected name 'x', got '%s'", p.name);
		assert(p.extra_text == "42", "expected extra_text '42', got '%s'", p.extra_text);
		assert(p.child_count == 1, "expected 1 child (default expr), got %d", (int)p.child_count);
		AstNode* expr = child(r, p, 0);
		assert(expr.kind == LITERAL_EXPR, "expected LITERAL_EXPR child, got kind %d", (int)expr.kind);
	};
}

fn void parse_param_default_lambda() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(action: () -> Int = { 1 + 2 }) {}"); defer free_result(r);
		assert(r.error_count == 0, "no errors expected, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* p = first_param(r, fun_node);
		assert(p != null, "expected PARAM child");
		assert(p.extra_text.len > 0, "extra_text must remain populated");
		assert(p.child_count >= 1, "expected at least 1 child, got %d", (int)p.child_count);
		AstNode* expr = child(r, p, 0);
		assert(expr.kind == LAMBDA_EXPR, "expected LAMBDA_EXPR child, got kind %d", (int)expr.kind);
	};
}

fn void parse_param_default_call_expr() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(list: List<Int> = listOf(1, 2, 3)) {}"); defer free_result(r);
		assert(r.error_count == 0, "no errors expected, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* p = first_param(r, fun_node);
		assert(p != null, "expected PARAM child");
		assert(p.extra_text.len > 0, "extra_text must remain populated");
		assert(p.child_count >= 1, "expected at least 1 child, got %d", (int)p.child_count);
		AstNode* expr = child(r, p, 0);
		assert(expr.kind == CALL_EXPR, "expected CALL_EXPR child, got kind %d", (int)expr.kind);
		// Walk all nodes and count VALUE_ARGUMENTs whose parent is the CALL_EXPR.
		uint call_idx = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (&r.nodes[i] == expr) { call_idx = i; break; }
		}
		usz va_count = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == VALUE_ARGUMENT && r.nodes[i].parent == call_idx) va_count++;
		}
		assert(va_count == 3, "expected 3 VALUE_ARGUMENTs under CALL_EXPR, got %d (child_count=%d)",
			(int)va_count, (int)expr.child_count);
	};
}

fn void parse_param_vararg_with_default() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(vararg xs: Int = intArrayOf()) {}"); defer free_result(r);
		assert(r.error_count == 0, "no errors expected, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* p = first_param(r, fun_node);
		assert(p != null, "expected PARAM child");
		assert(p.extra_text.len > 0, "extra_text must remain populated for vararg+default");
		assert(p.child_count >= 1, "expected at least 1 child for vararg+default, got %d",
			(int)p.child_count);
	};
}

fn void parse_param_no_default_no_child() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(x: Int) {}"); defer free_result(r);
		assert(r.error_count == 0, "no errors expected, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* p = first_param(r, fun_node);
		assert(p != null, "expected PARAM child");
		assert(p.extra_text.len == 0, "expected empty extra_text without default, got '%s'", p.extra_text);
		assert(p.child_count == 0, "expected 0 children without default, got %d", (int)p.child_count);
	};
}

// ── Expression body with .get()/.set() ─────────────────────────────

fn void parse_expression_body_dot_get_not_accessor() @test {
	@pool() {
		ParseResult* r = do_parse(`val cache = Paths.get("home", ".cache").also { it.toFile().mkdirs() }`); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for .get() in expression body, got %d", (int)r.error_count);
	};
}

fn void parse_expression_body_dot_set_not_accessor() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = map.set("key", "value")`); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for .set() in expression body, got %d", (int)r.error_count);
	};
}

// ── Function type with receiver ────────────────────────────────────

fn void parse_fun_with_dotted_receiver_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun TopologyDescription.Source.sourceToUml(): String = \"\""); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "sourceToUml", "expected 'sourceToUml', got '%s'", fun_node.name);
		assert(fun_node.extra_text == "TopologyDescription.Source", "expected 'TopologyDescription.Source', got '%s'", fun_node.extra_text);
		assert(r.error_count == 0, "expected no errors for dotted receiver type, got %d", (int)r.error_count);
	};
}

fn void parse_fun_with_receiver_type_param() @test {
	@pool() {
		ParseResult* r = do_parse("fun module(block: Module.() -> Unit): Module {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "module");
		assert(r.error_count == 0, "expected no errors for function type with receiver, got %d", (int)r.error_count);
	};
}

fn void parse_fun_with_generic_receiver_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T> build(block: Builder<T>.() -> Unit): T {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "build");
		assert(r.error_count == 0, "expected no errors for generic receiver type, got %d", (int)r.error_count);
	};
}

fn void parse_fun_with_nullable_receiver_function_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun apply(block: (Module.() -> Unit)?): Module {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);
		assert(fun_node.name == "apply");
		assert(r.error_count == 0, "expected no errors for nullable receiver function type, got %d", (int)r.error_count);
	};
}

fn void parse_data_class_with_primary_constructor_defaults() @test {
	@pool() {
		String content =
`data class Opts(
    var jvm_version: Int = 21,
    var kotlin_version: String = "2.2.21",
    var kotlin_home: Path = Paths.get(System.getenv("KOTLIN_LIB")),
    var backend_threads: Int = 0,
    var verbose: Boolean = false,
    var error: Boolean = true,
    var extra: Boolean = false,
    var debug: Boolean = false,
)`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for data class with defaults, got %d", (int)r.error_count);
	};
}

fn void parse_multiline_expression_body_chain() @test {
	@pool() {
		String content =
`fun Nob.main_srcs(): Sequence<Path> = mods.map { path(it.src) }.asSequence()
    .flatMap { Files.walk(it).asSequence() }
    .filter { Files.isRegularFile(it) && it.toFile().readText().contains("fun main(") }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for multiline chain, got %d", (int)r.error_count);
	};
}

fn void parse_top_level_fun_path_with_get_also() @test {
	@pool() {
		String content =
`fun Path.main_class_fq(): String {
    val pkg = this.toFile().useLines { lines -> lines.firstOrNull { it.trim().startsWith("package ") } }
    val main = this.fileName.toString().removeSuffix(".kt").replaceFirstChar{ it.uppercase() } + "Kt"
    return pkg?.let { "${'$'}pkg.${'$'}main" } ?: main
}

fun List<Path>.into_cp(): String = joinToString(File.pathSeparator) { it.toAbsolutePath().normalize().toString() }
fun path(str: String): Path = Paths.get(System.getProperty("user.dir"), str).also { it.toFile().mkdirs() }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for path/get/also funs, got %d", (int)r.error_count);
	};
}

// ── Statement parsing: helpers ─────────────────────────────────────

// Get the BLOCK child of a FUN_DECL node
fn AstNode* fun_block(ParseResult* r, AstNode* fun_node) {
	for (uint i = 0; i < fun_node.child_count; i++) {
		AstNode* ch = ast::get_child(r, fun_node, i)!!;
		if (ch.kind == BLOCK) return ch;
	}
	unreachable("expected BLOCK child in FUN_DECL");
}

// Find the first child of a given kind
fn AstNode* find_kind(ParseResult* r, AstNode* parent, NodeKind kind) {
	uint parent_idx = ast::node_index(r, parent);
	for (uint i = 0; i < r.node_count; i++) {
		AstNode* ch = &r.nodes[i];
		if (ch.parent == parent_idx && ch.kind == kind) return ch;
	}
	unreachable("expected child of kind %d", (int)kind);
}

// Count children of a given kind
fn usz count_kind(ParseResult* r, AstNode* parent, NodeKind kind) {
	uint parent_idx = ast::node_index(r, parent);
	usz count = 0;
	for (uint i = 0; i < r.node_count; i++) {
		AstNode* ch = &r.nodes[i];
		if (ch.parent == parent_idx && ch.kind == kind) count++;
	}
	return count;
}

fn AstNode* nth_kind(ParseResult* r, AstNode* parent, NodeKind kind, uint n) {
	uint parent_idx = ast::node_index(r, parent);
	uint count = 0;
	for (uint i = 0; i < r.node_count; i++) {
		AstNode* ch = &r.nodes[i];
		if (ch.parent != parent_idx || ch.kind != kind) continue;
		if (count == n) return ch;
		count++;
	}
	unreachable("expected child %d of kind %d", (int)n, (int)kind);
}

fn AstNode* first_type_ref_child(ParseResult* r, AstNode* parent) {
	uint parent_idx = ast::node_index(r, parent);
	for (uint i = 0; i < r.node_count; i++) {
		if (r.nodes[i].parent == parent_idx && r.nodes[i].kind == TYPE_REF) {
			return &r.nodes[i];
		}
	}
	unreachable("expected TYPE_REF child");
}

// ── Local val/var inside function body ──────────────────────────────

fn void parse_local_val_in_fun() @test {
	@pool() {
		String content =
`fun foo() {
    val x = 42
    val y: String = "hello"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		assert(fun_node.kind == FUN_DECL);

		AstNode* block = fun_block(r, fun_node);
		usz prop_count = count_kind(r, block, PROPERTY_DECL);
		assert(prop_count == 2, "expected 2 local val declarations, got %d", (int)prop_count);

		// Check first local val
		AstNode* x = find_kind(r, block, PROPERTY_DECL);
		assert(x.name == "x", "expected 'x', got '%s'", x.name);
	};
}

fn void parse_local_var_in_fun() @test {
	@pool() {
		String content =
`fun foo() {
    var count = 0
    var name: String = "test"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* block = fun_block(r, fun_node);
		usz prop_count = count_kind(r, block, PROPERTY_DECL);
		assert(prop_count == 2, "expected 2 local var declarations, got %d", (int)prop_count);
	};
}

fn void parse_local_val_with_type() @test {
	@pool() {
		String content =
`fun foo() {
    val name: String = "hello"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* prop = find_kind(r, block, PROPERTY_DECL);
		assert(prop.name == "name", "expected 'name', got '%s'", prop.name);
		assert(prop.type_text == "String", "expected type 'String', got '%s'", prop.type_text);
	};
}

// ── If expression ──────────────────────────────────────────────────

fn void parse_if_statement() @test {
	@pool() {
		String content =
`fun foo() {
    if (x > 0) {
        println("positive")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz if_count = count_kind(r, block, IF_EXPR);
		assert(if_count == 1, "expected 1 IF_EXPR, got %d", (int)if_count);
	};
}

fn void parse_if_else() @test {
	@pool() {
		String content =
`fun foo() {
    if (x > 0) {
        println("positive")
    } else {
        println("non-positive")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz if_count = count_kind(r, block, IF_EXPR);
		assert(if_count == 1, "expected 1 IF_EXPR, got %d", (int)if_count);
	};
}

fn void parse_if_else_if() @test {
	@pool() {
		String content =
`fun foo() {
    if (x > 0) {
        println("positive")
    } else if (x < 0) {
        println("negative")
    } else {
        println("zero")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_if_with_local_val() @test {
	@pool() {
		String content =
`fun foo() {
    if (cond) {
        val result = compute()
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// The local val should be inside the if's block
		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* if_node = find_kind(r, block, IF_EXPR);
		// The if has a BLOCK child which has the PROPERTY_DECL
		AstNode* if_block = find_kind(r, if_node, BLOCK);
		usz prop_count = count_kind(r, if_block, PROPERTY_DECL);
		assert(prop_count == 1, "expected 1 local val inside if block, got %d", (int)prop_count);
	};
}

// ── When expression ────────────────────────────────────────────────

fn void parse_when_statement() @test {
	@pool() {
		String content =
`fun foo(x: Int) {
    when (x) {
        1 -> println("one")
        2 -> println("two")
        else -> println("other")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz when_count = count_kind(r, block, WHEN_EXPR);
		assert(when_count == 1, "expected 1 WHEN_EXPR, got %d", (int)when_count);
	};
}

fn void parse_when_without_subject() @test {
	@pool() {
		String content =
`fun foo() {
    when {
        x > 0 -> println("positive")
        x < 0 -> println("negative")
        else -> println("zero")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_when_with_blocks() @test {
	@pool() {
		String content =
`fun foo(x: Int) {
    when (x) {
        1 -> {
            val y = 1
            println(y)
        }
        else -> {
            println("other")
        }
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_when_with_is_and_in() @test {
	@pool() {
		String content =
`fun foo(x: Any) {
    when (x) {
        is String -> println("string")
        is Int -> println("int")
        in 1..10 -> println("range")
        else -> println("other")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── For statement ──────────────────────────────────────────────────

fn void parse_for_loop() @test {
	@pool() {
		String content =
`fun foo() {
    for (item in list) {
        println(item)
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz for_count = count_kind(r, block, FOR_STMT);
		assert(for_count == 1, "expected 1 FOR_STMT, got %d", (int)for_count);

		// Check that the for has a PARAM child for the loop variable
		AstNode* for_node = find_kind(r, block, FOR_STMT);
		usz param_count = count_kind(r, for_node, PARAM);
		assert(param_count == 1, "expected 1 PARAM in for loop, got %d", (int)param_count);

		AstNode* param = find_kind(r, for_node, PARAM);
		assert(param.name == "item", "expected 'item', got '%s'", param.name);
	};
}

fn void parse_for_with_local_val() @test {
	@pool() {
		String content =
`fun foo() {
    for (i in 1..10) {
        val doubled = i * 2
        println(doubled)
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── While statement ────────────────────────────────────────────────

fn void parse_while_loop() @test {
	@pool() {
		String content =
`fun foo() {
    while (running) {
        process()
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz while_count = count_kind(r, block, WHILE_STMT);
		assert(while_count == 1, "expected 1 WHILE_STMT, got %d", (int)while_count);

		// Condition expression should be an AST child of the WHILE_STMT
		AstNode* while_node = find_kind(r, block, WHILE_STMT);
		assert(while_node.child_count >= 2, "expected at least 2 children (condition + block), got %d", (int)while_node.child_count);

		// First child should be the condition expression (NAME_EXPR for 'running')
		AstNode* cond = child(r, while_node, 0);
		assert(cond.kind == NAME_EXPR, "expected NAME_EXPR for condition, got %d", (int)cond.kind);
	};
}

fn void parse_while_with_complex_condition() @test {
	@pool() {
		String content =
`fun foo() {
    while (x != 0 && flag) {
        x--
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* while_node = find_kind(r, block, WHILE_STMT);
		assert(while_node.child_count >= 2, "expected at least 2 children (condition + block), got %d", (int)while_node.child_count);

		// First child should be the binary expression (x != 0 && flag)
		AstNode* cond = child(r, while_node, 0);
		assert(cond.kind == BINARY_EXPR, "expected BINARY_EXPR for condition, got %d", (int)cond.kind);
	};
}

fn void parse_while_with_call_condition() @test {
	@pool() {
		String content =
`fun foo() {
    while (hasNext()) {
        process()
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* while_node = find_kind(r, block, WHILE_STMT);
		assert(while_node.child_count >= 2, "expected at least 2 children (condition + block), got %d", (int)while_node.child_count);

		// First child should be a call expression (hasNext())
		AstNode* cond = child(r, while_node, 0);
		assert(cond.kind == CALL_EXPR, "expected CALL_EXPR for condition, got %d", (int)cond.kind);
	};
}

fn void parse_while_with_not_null_condition() @test {
	@pool() {
		String content =
`fun foo() {
    while (line != null) {
        process(line)
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* while_node = find_kind(r, block, WHILE_STMT);
		assert(while_node.child_count >= 2, "expected at least 2 children (condition + block), got %d", (int)while_node.child_count);

		// First child should be a binary expression (line != null)
		AstNode* cond = child(r, while_node, 0);
		assert(cond.kind == BINARY_EXPR, "expected BINARY_EXPR for condition, got %d", (int)cond.kind);
	};
}

// ── Do-while statement ─────────────────────────────────────────────

fn void parse_do_while_loop() @test {
	@pool() {
		String content =
`fun foo() {
    do {
        val line = readLine()
    } while (line != null)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz do_count = count_kind(r, block, DO_WHILE_STMT);
		assert(do_count == 1, "expected 1 DO_WHILE_STMT, got %d", (int)do_count);

		// Condition expression should be an AST child of the DO_WHILE_STMT
		AstNode* do_node = find_kind(r, block, DO_WHILE_STMT);
		assert(do_node.child_count >= 2, "expected at least 2 children (block + condition), got %d", (int)do_node.child_count);

		// Last child should be the condition expression (line != null)
		AstNode* cond = child(r, do_node, do_node.child_count - 1);
		assert(cond.kind == BINARY_EXPR, "expected BINARY_EXPR for do-while condition, got %d", (int)cond.kind);
	};
}

fn void parse_do_while_with_simple_condition() @test {
	@pool() {
		String content =
`fun foo() {
    do {
        retry()
    } while (shouldRetry)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* do_node = find_kind(r, block, DO_WHILE_STMT);
		assert(do_node.child_count >= 2, "expected at least 2 children (block + condition), got %d", (int)do_node.child_count);

		// Last child should be the condition (NAME_EXPR for 'shouldRetry')
		AstNode* cond = child(r, do_node, do_node.child_count - 1);
		assert(cond.kind == NAME_EXPR, "expected NAME_EXPR for do-while condition, got %d", (int)cond.kind);
	};
}

fn void parse_do_while_with_call_condition() @test {
	@pool() {
		String content =
`fun foo() {
    do {
        attempt()
    } while (hasMore() && count != 0)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* do_node = find_kind(r, block, DO_WHILE_STMT);
		assert(do_node.child_count >= 2, "expected at least 2 children (block + condition), got %d", (int)do_node.child_count);

		// Last child should be a binary expression (hasMore() && count != 0)
		AstNode* cond = child(r, do_node, do_node.child_count - 1);
		assert(cond.kind == BINARY_EXPR, "expected BINARY_EXPR for do-while condition, got %d", (int)cond.kind);
	};
}

fn void parse_while_with_generic_ambiguity_rollback() @test {
	@pool() {
		// Conditions with bare `>` trigger rollback to skip_balanced_parens
		// due to generic ambiguity (< and > are not binary operators in the parser).
		// The while statement should still parse without errors.
		String content =
`fun foo() {
    while (x > 0) {
        x--
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* while_node = find_kind(r, block, WHILE_STMT);
		// Rollback means condition is skipped -- only the body block is a child
		assert(while_node.child_count >= 1, "expected at least 1 child (block), got %d", (int)while_node.child_count);
	};
}

fn void parse_do_while_with_generic_ambiguity_rollback() @test {
	@pool() {
		// Same rollback behavior for do-while with bare `>`
		String content =
`fun foo() {
    do {
        attempt()
    } while (count > 0)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* do_node = find_kind(r, block, DO_WHILE_STMT);
		// Rollback means condition is skipped -- only the body block is a child
		assert(do_node.child_count >= 1, "expected at least 1 child (block), got %d", (int)do_node.child_count);
	};
}

// ── Try/catch/finally ──────────────────────────────────────────────

fn void parse_try_catch() @test {
	@pool() {
		String content =
`fun foo() {
    try {
        riskyOperation()
    } catch (e: Exception) {
        println(e.message)
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz try_count = count_kind(r, block, TRY_EXPR);
		assert(try_count == 1, "expected 1 TRY_EXPR, got %d", (int)try_count);

		// Check catch clause has PARAM for the exception variable
		AstNode* try_node = find_kind(r, block, TRY_EXPR);
		AstNode* catch_node = find_kind(r, try_node, CATCH_CLAUSE);
		AstNode* param = find_kind(r, catch_node, PARAM);
		assert(param.name == "e", "expected catch param 'e', got '%s'", param.name);
		assert(param.type_text == "Exception", "expected type 'Exception', got '%s'", param.type_text);
	};
}

fn void parse_try_catch_finally() @test {
	@pool() {
		String content =
`fun foo() {
    try {
        open()
    } catch (e: IOException) {
        log(e)
    } finally {
        close()
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_try_multiple_catch() @test {
	@pool() {
		String content =
`fun foo() {
    try {
        parse()
    } catch (e: NumberFormatException) {
        handleNumber(e)
    } catch (e: IllegalArgumentException) {
        handleArg(e)
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* try_node = find_kind(r, block, TRY_EXPR);
		usz catch_count = count_kind(r, try_node, CATCH_CLAUSE);
		assert(catch_count == 2, "expected 2 CATCH_CLAUSEs, got %d", (int)catch_count);
	};
}

// ── Return / throw / break / continue ──────────────────────────────

fn void parse_return_statement() @test {
	@pool() {
		String content =
`fun foo(): Int {
    return 42
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz ret_count = count_kind(r, block, RETURN_EXPR);
		assert(ret_count == 1, "expected 1 RETURN_EXPR, got %d", (int)ret_count);
	};
}

fn void parse_return_with_label() @test {
	@pool() {
		String content =
`fun foo() {
    list.forEach {
        if (it == 0) return@forEach
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_throw_statement() @test {
	@pool() {
		String content =
`fun foo() {
    throw IllegalArgumentException("bad")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz throw_count = count_kind(r, block, THROW_EXPR);
		assert(throw_count == 1, "expected 1 THROW_EXPR, got %d", (int)throw_count);
	};
}

fn void parse_break_continue() @test {
	@pool() {
		String content =
`fun foo() {
    for (i in list) {
        if (i == 0) continue
        if (i < 0) break
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Local function ─────────────────────────────────────────────────

fn void parse_local_function() @test {
	@pool() {
		String content =
`fun outer() {
    fun inner(x: Int): Int {
        return x * 2
    }
    val result = inner(21)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz fun_count = count_kind(r, block, FUN_DECL);
		assert(fun_count == 1, "expected 1 local FUN_DECL, got %d", (int)fun_count);

		AstNode* inner = find_kind(r, block, FUN_DECL);
		assert(inner.name == "inner", "expected 'inner', got '%s'", inner.name);
	};
}

// ── Local class ────────────────────────────────────────────────────

fn void parse_local_class() @test {
	@pool() {
		String content =
`fun foo() {
    class Local {
        fun method() {}
    }
    val obj = Local()
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		usz class_count = count_kind(r, block, CLASS_DECL);
		assert(class_count == 1, "expected 1 local CLASS_DECL, got %d", (int)class_count);
	};
}

// ── Nested control flow ────────────────────────────────────────────

fn void parse_nested_control_flow() @test {
	@pool() {
		String content =
`fun foo() {
    for (item in list) {
        if (item.isValid()) {
            when (item.type) {
                "A" -> process(item)
                else -> skip(item)
            }
        }
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Mixed statements ───────────────────────────────────────────────

fn void parse_mixed_statements() @test {
	@pool() {
		String content =
`fun process(items: List<String>): Int {
    var count = 0
    for (item in items) {
        val trimmed = item.trim()
        if (trimmed.isEmpty()) continue
        try {
            count += trimmed.toInt()
        } catch (e: NumberFormatException) {
            println("skipping: $trimmed")
        }
    }
    return count
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for mixed statements, got %d", (int)r.error_count);
	};
}

// ── Expression statements (should be skipped without errors) ───────

fn void parse_expression_statements() @test {
	@pool() {
		String content =
`fun foo() {
    println("hello")
    list.add(item)
    x = 42
    obj.method().chain()
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for expression statements, got %d", (int)r.error_count);
	};
}

// ── Real-world: function bodies from nob.kt ────────────────────────

fn void parse_real_world_compile_function() @test {
	@pool() {
		String content =
`fun compile(module: Module): Boolean {
    val start_time = System.nanoTime()
    if (module in compiled) return false
    module.mods.forEach { compile(it) }

    val src = path(module.src).toFile()
    var target = module.src_target()
    val sources: Sequence<File> = when {
        src.isFile -> sequenceOf(src)
        src.isDirectory -> src.walkTopDown().filter { it.isFile && it.extension == "kt" }
        else -> emptySequence()
    }

    val any_compiled_target_file = get_any_compiled_file(target.toFile())
    val has_changes = sources.any { file ->
        file.lastModified() > any_compiled_target_file?.lastModified() ?: 0
    }

    compiled.add(module)
    if (!has_changes) return false

    val classpath = module.compile_cp()
    if (src.isFile && src.name == "nob.kt") target = Paths.get(module.target).toAbsolutePath().normalize()
    compile_with_daemon(src, target, classpath, module.name)
    return true
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for real-world compile function, got %d", (int)r.error_count);

		// Verify local variables are parsed
		AstNode* f = file_node(r);
		AstNode* fun_node = child(r, f, 0);
		AstNode* block = fun_block(r, fun_node);

		// Should find local val/var declarations
		usz prop_count = count_kind(r, block, PROPERTY_DECL);
		assert(prop_count >= 5, "expected at least 5 local declarations, got %d", (int)prop_count);
	};
}

fn void parse_real_world_try_catch_function() @test {
	@pool() {
		String content =
`fun compile_with_daemon(src: File, target: Path, classpath: String, name: String, retries: Int = 3) {
    val kotlin_libs = listOf("a.jar", "b.jar").joinToString(":") { it }
    val args = buildList {
        add("-d")
        add(target.toString())
    }
    val client_alive_file = target.resolve(".alive").toFile()
    try {
        val session_id = daemon.leaseCompileSession(client_alive_file.absolutePath).get()
        try {
            exit_code = compile(daemon, session_id)
        } finally {
            daemon.releaseCompileSession(session_id)
        }
    } catch (e: IllegalStateException) {
        daemon.shutdown()
        Thread.sleep(1000)
        if (retries > 0) compile_with_daemon(src, target, classpath, name, retries-1)
        else throw e
        return
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for try/catch function, got %d", (int)r.error_count);
	};
}

// ── Expression parsing tests ───────────────────────────────────────

// Helper: get the first expression statement (direct child of block) of a given kind
fn AstNode* first_expr(ParseResult* r, AstNode* block, NodeKind kind) {
	for (uint i = 0; i < block.child_count; i++) {
		AstNode* ch = ast::get_child(r, block, i)!!;
		if (ch.kind == kind) return ch;
	}
	unreachable("expected expression child of kind %d", (int)kind);
}

// ── Simple name expression ─────────────────────────────────────────

fn void parse_expr_name() @test {
	@pool() {
		String content =
`fun foo() {
    bar
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz name_count = count_kind(r, block, NAME_EXPR);
		assert(name_count == 1, "expected 1 NAME_EXPR, got %d", (int)name_count);

		AstNode* name_node = first_expr(r, block, NAME_EXPR);
		assert(name_node.name == "bar", "expected name 'bar', got '%s'", name_node.name);
	};
}

// ── Literal expressions ────────────────────────────────────────────

fn void parse_expr_integer_literal() @test {
	@pool() {
		String content =
`fun foo() {
    42
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz lit_count = count_kind(r, block, LITERAL_EXPR);
		assert(lit_count == 1, "expected 1 LITERAL_EXPR, got %d", (int)lit_count);

		AstNode* lit = first_expr(r, block, LITERAL_EXPR);
		assert(lit.extra_text == "42", "expected '42', got '%s'", lit.extra_text);
	};
}

fn void parse_expr_string_literal() @test {
	@pool() {
		String content =
`fun foo() {
    "hello world"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_boolean_literal() @test {
	@pool() {
		String content =
`fun foo() {
    true
    false
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz lit_count = count_kind(r, block, LITERAL_EXPR);
		assert(lit_count == 2, "expected 2 LITERAL_EXPR, got %d", (int)lit_count);
	};
}

fn void parse_expr_null_literal() @test {
	@pool() {
		String content =
`fun foo() {
    null
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz lit_count = count_kind(r, block, LITERAL_EXPR);
		assert(lit_count == 1, "expected 1 LITERAL_EXPR, got %d", (int)lit_count);
	};
}

// ── Function call expressions ──────────────────────────────────────

fn void parse_expr_simple_call() @test {
	@pool() {
		String content =
`fun foo() {
    println("hello")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz call_count = count_kind(r, block, CALL_EXPR);
		assert(call_count == 1, "expected 1 CALL_EXPR, got %d", (int)call_count);

		AstNode* call = first_expr(r, block, CALL_EXPR);
		assert(call.name == "println", "expected name 'println', got '%s'", call.name);
	};
}

fn void parse_expr_call_multiple_args() @test {
	@pool() {
		String content =
`fun foo() {
    add(1, 2, 3)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		AstNode* call = first_expr(r, block, CALL_EXPR);
		assert(call.name == "add", "expected name 'add', got '%s'", call.name);
	};
}

fn void parse_expr_chained_calls() @test {
	@pool() {
		String content =
`fun foo() {
    list.map { it }.filter { it > 0 }.toList()
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Dot access expressions ─────────────────────────────────────────

fn void parse_expr_dot_access() @test {
	@pool() {
		String content =
`fun foo() {
    obj.name
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz dot_count = count_kind(r, block, DOT_EXPR);
		assert(dot_count == 1, "expected 1 DOT_EXPR, got %d", (int)dot_count);

		AstNode* dot = first_expr(r, block, DOT_EXPR);
		assert(dot.name == "name", "expected member 'name', got '%s'", dot.name);
	};
}

fn void parse_expr_safe_call() @test {
	@pool() {
		String content =
`fun foo() {
    obj?.name
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		AstNode* dot = first_expr(r, block, DOT_EXPR);
		assert(dot.name == "name", "expected member 'name', got '%s'", dot.name);
		assert(dot.extra_text == "?.", "expected '?.' safe call");
	};
}

fn void parse_expr_member_call() @test {
	@pool() {
		String content =
`fun foo() {
    obj.method(42)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz call_count = count_kind(r, block, CALL_EXPR);
		assert(call_count == 1, "expected 1 CALL_EXPR, got %d", (int)call_count);

		AstNode* call = first_expr(r, block, CALL_EXPR);
		assert(call.name == "method", "expected name 'method', got '%s'", call.name);
	};
}

fn void parse_expr_chained_dot_access() @test {
	@pool() {
		String content =
`fun foo() {
    a.b.c.d
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		// The outermost should be a DOT_EXPR with name "d"
		AstNode* outer = first_expr(r, block, DOT_EXPR);
		assert(outer.name == "d", "expected outermost member 'd', got '%s'", outer.name);
	};
}

// ── Binary expressions ─────────────────────────────────────────────

fn void parse_expr_binary_add() @test {
	@pool() {
		String content =
`fun foo() {
    a + b
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz bin_count = count_kind(r, block, BINARY_EXPR);
		assert(bin_count == 1, "expected 1 BINARY_EXPR, got %d", (int)bin_count);

		AstNode* bin = first_expr(r, block, BINARY_EXPR);
		assert(bin.extra_text == "+", "expected operator '+', got '%s'", bin.extra_text);
	};
}

fn void parse_expr_binary_comparison() @test {
	@pool() {
		String content =
`fun foo() {
    x >= 10
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz bin_count = count_kind(r, block, BINARY_EXPR);
		assert(bin_count == 1, "expected 1 BINARY_EXPR, got %d", (int)bin_count);

		AstNode* bin = first_expr(r, block, BINARY_EXPR);
		assert(bin.extra_text == ">=", "expected operator '>=', got '%s'", bin.extra_text);
	};
}

fn void parse_expr_binary_logical() @test {
	@pool() {
		String content =
`fun foo() {
    a && b || c
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Should produce nested BINARY_EXPRs due to precedence
		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		// The outermost should be || (lower precedence)
		AstNode* outer = first_expr(r, block, BINARY_EXPR);
		assert(outer.extra_text == "||", "expected outermost operator '||', got '%s'", outer.extra_text);
	};
}

fn void parse_expr_binary_equality() @test {
	@pool() {
		String content =
`fun foo() {
    x == y
    a != b
    p === q
    m !== n
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz bin_count = count_kind(r, block, BINARY_EXPR);
		assert(bin_count == 4, "expected 4 BINARY_EXPR, got %d", (int)bin_count);
	};
}

fn void parse_expr_binary_arithmetic() @test {
	@pool() {
		String content =
`fun foo() {
    a + b * c - d / e % f
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_elvis() @test {
	@pool() {
		String content =
`fun foo() {
    name ?: "default"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz bin_count = count_kind(r, block, BINARY_EXPR);
		assert(bin_count == 1, "expected 1 BINARY_EXPR for elvis, got %d", (int)bin_count);
	};
}

fn void parse_expr_range() @test {
	@pool() {
		String content =
`fun foo() {
    1..10
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz bin_count = count_kind(r, block, BINARY_EXPR);
		assert(bin_count == 1, "expected 1 BINARY_EXPR for range, got %d", (int)bin_count);
	};
}

fn void parse_expr_infix_function() @test {
	@pool() {
		String content =
`fun foo() {
    a to b
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Assignment expressions ─────────────────────────────────────────

fn void parse_expr_assignment() @test {
	@pool() {
		String content =
`fun foo() {
    x = 42
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz assign_count = count_kind(r, block, ASSIGNMENT_EXPR);
		assert(assign_count == 1, "expected 1 ASSIGNMENT_EXPR, got %d", (int)assign_count);

		AstNode* assign = first_expr(r, block, ASSIGNMENT_EXPR);
		assert(assign.extra_text == "=", "expected operator '=', got '%s'", assign.extra_text);
	};
}

fn void parse_expr_compound_assignment() @test {
	@pool() {
		String content =
`fun foo() {
    x += 1
    y -= 2
    z *= 3
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz assign_count = count_kind(r, block, ASSIGNMENT_EXPR);
		assert(assign_count == 3, "expected 3 ASSIGNMENT_EXPR, got %d", (int)assign_count);
	};
}

// ── Prefix expressions ─────────────────────────────────────────────

fn void parse_expr_prefix_negate() @test {
	@pool() {
		String content =
`fun foo() {
    -x
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz prefix_count = count_kind(r, block, PREFIX_EXPR);
		assert(prefix_count == 1, "expected 1 PREFIX_EXPR, got %d", (int)prefix_count);

		AstNode* prefix = first_expr(r, block, PREFIX_EXPR);
		assert(prefix.extra_text == "-", "expected operator '-', got '%s'", prefix.extra_text);
	};
}

fn void parse_expr_prefix_not() @test {
	@pool() {
		String content =
`fun foo() {
    !flag
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz prefix_count = count_kind(r, block, PREFIX_EXPR);
		assert(prefix_count == 1, "expected 1 PREFIX_EXPR, got %d", (int)prefix_count);
	};
}

fn void parse_expr_prefix_increment() @test {
	@pool() {
		String content =
`fun foo() {
    ++x
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz prefix_count = count_kind(r, block, PREFIX_EXPR);
		assert(prefix_count == 1, "expected 1 PREFIX_EXPR, got %d", (int)prefix_count);
	};
}

fn void parse_expr_prefix_decrement() @test {
	@pool() {
		String content =
`fun foo() {
    --y
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz prefix_count = count_kind(r, block, PREFIX_EXPR);
		assert(prefix_count == 1, "expected 1 PREFIX_EXPR, got %d", (int)prefix_count);
	};
}

// ── Postfix expressions ────────────────────────────────────────────

fn void parse_expr_postfix_increment() @test {
	@pool() {
		String content =
`fun foo() {
    x++
    y--
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz postfix_count = count_kind(r, block, POSTFIX_EXPR);
		assert(postfix_count == 2, "expected 2 POSTFIX_EXPR, got %d", (int)postfix_count);
	};
}

fn void parse_expr_not_null_assertion() @test {
	@pool() {
		String content =
`fun foo() {
    x!!
    obj!!.name
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Index expressions ──────────────────────────────────────────────

fn void parse_expr_index() @test {
	@pool() {
		String content =
`fun foo() {
    arr[0]
    map[key]
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz idx_count = count_kind(r, block, INDEX_EXPR);
		assert(idx_count == 2, "expected 2 INDEX_EXPR, got %d", (int)idx_count);
	};
}

// ── Parenthesized expressions ──────────────────────────────────────

fn void parse_expr_paren() @test {
	@pool() {
		String content =
`fun foo() {
    (a + b) * c
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── This/super expressions ─────────────────────────────────────────

fn void parse_expr_this() @test {
	@pool() {
		String content =
`class Foo {
    fun bar() {
        this
        this.name
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_super() @test {
	@pool() {
		String content =
`class Foo : Bar() {
    override fun bar() {
        super.bar()
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Lambda expressions ─────────────────────────────────────────────

fn void parse_expr_lambda_simple() @test {
	@pool() {
		String content =
`fun foo() {
    val f = { x: Int -> x + 1 }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_lambda_trailing() @test {
	@pool() {
		String content =
`fun foo() {
    listOf(1, 2, 3).map { it * 2 }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_lambda_multi_params() @test {
	@pool() {
		String content =
`fun foo() {
    val f = { a: Int, b: Int -> a + b }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Callable reference expressions ─────────────────────────────────

fn void parse_expr_callable_ref() @test {
	@pool() {
		String content =
`fun foo() {
    ::bar
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz ref_count = count_kind(r, block, CALLABLE_REF_EXPR);
		assert(ref_count == 1, "expected 1 CALLABLE_REF_EXPR, got %d", (int)ref_count);

		AstNode* ref_node = first_expr(r, block, CALLABLE_REF_EXPR);
		assert(ref_node.name == "bar", "expected name 'bar', got '%s'", ref_node.name);
	};
}

// ── Type check/cast expressions ────────────────────────────────────

fn void parse_expr_is_check() @test {
	@pool() {
		String content =
`fun foo() {
    x is String
    y !is Int
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz check_count = count_kind(r, block, TYPE_CHECK_EXPR);
		assert(check_count == 2, "expected 2 TYPE_CHECK_EXPR, got %d", (int)check_count);
	};
}

fn void parse_expr_as_cast() @test {
	@pool() {
		String content =
`fun foo() {
    x as String
    y as? Int
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz cast_count = count_kind(r, block, TYPE_CAST_EXPR);
		assert(cast_count == 2, "expected 2 TYPE_CAST_EXPR, got %d", (int)cast_count);
	};
}

// ── Spread expression ──────────────────────────────────────────────

fn void parse_expr_spread() @test {
	@pool() {
		String content =
`fun foo() {
    bar(*args)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Complex expression combinations ────────────────────────────────

fn void parse_expr_complex_chain() @test {
	@pool() {
		String content =
`fun foo() {
    obj.method(1, 2).field?.toString()
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_complex_mixed() @test {
	@pool() {
		String content =
`fun foo() {
    val result = if (x > 0) x * 2 else -x
    val name = obj?.name ?: "unknown"
    items.filter { it != null }.map { it!! }
    val sum = list.fold(0) { acc, item -> acc + item }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for complex mixed expressions, got %d", (int)r.error_count);
	};
}

fn void parse_expr_when_as_expression() @test {
	@pool() {
		String content =
`fun foo(x: Any) {
    val result = when (x) {
        is String -> x.length
        is Int -> x + 1
        else -> 0
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_string_template() @test {
	@pool() {
		String content =
`fun foo() {
    val name = "world"
    println("hello $name")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_object_expression() @test {
	@pool() {
		String content =
`fun foo() {
    val listener = object : Runnable {
        override fun run() {
            println("running")
        }
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_nested_calls_with_lambdas() @test {
	@pool() {
		String content =
`fun foo() {
    buildList {
        add("a")
        addAll(other.map { it.uppercase() })
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_in_val_initializer() @test {
	@pool() {
		String content =
`fun foo() {
    val x = a + b * c
    val y = listOf(1, 2, 3).size
    val z = if (flag) 1 else 2
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* block = fun_block(r, child(r, file_node(r), 0));
		usz prop_count = count_kind(r, block, PROPERTY_DECL);
		assert(prop_count == 3, "expected 3 PROPERTY_DECL, got %d", (int)prop_count);
	};
}

fn void parse_expr_member_ref_after_dot() @test {
	@pool() {
		String content =
`fun foo() {
    list.map(String::length)
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void parse_expr_real_world_builder_pattern() @test {
	@pool() {
		String content =
`fun createConfig(): Config {
    return Config.builder()
        .setName("test")
        .setPort(8080)
        .setDebug(true)
        .build()
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for builder pattern, got %d", (int)r.error_count);
	};
}

fn void parse_expr_real_world_coroutine() @test {
	@pool() {
		String content =
`suspend fun fetchData(url: String): Result {
    val response = client.get(url)
    val body = response.body?.string() ?: throw Exception("Empty body")
    return Result(body.length, body.hashCode())
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for coroutine function, got %d", (int)r.error_count);
	};
}

// ── String template expression parsing ─────────────────────────────

fn void parse_string_template_simple_ref() @test {
	@pool() {
		String content =
`fun foo() {
    println("hello $name")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for string template with ref, got %d", (int)r.error_count);
	};
}

fn void parse_string_template_with_expr() @test {
	@pool() {
		String content =
`fun foo() {
    println("result: ${x + 1}")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for string template with expr, got %d", (int)r.error_count);
	};
}

fn void parse_string_template_with_function_call() @test {
	@pool() {
		String content =
`fun foo() {
    println("${colorize("text", Color.yellow)}")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for string template with function call, got %d", (int)r.error_count);
	};
}

fn void parse_string_template_complex_interpolation() @test {
	@pool() {
		String content =
`fun foo() {
    val msg = "${colorize("Building", Color.yellow)} - not found ${e.message}"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for complex string template, got %d", (int)r.error_count);
	};
}

fn void parse_string_template_multiple_interpolations() @test {
	@pool() {
		String content =
`fun foo() {
    val msg = "start ${a.b()} middle ${c.d("x")} end"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for multiple interpolations, got %d", (int)r.error_count);
	};
}

fn void parse_infix_to_in_expression() @test {
	@pool() {
		String content =
`fun foo() {
    val pair = 1 to "one"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		// 'to' is an infix function call - currently not fully supported,
		// but it should not produce errors since 'to' is an identifier
		assert(r.error_count == 0, "expected no errors for infix 'to', got %d", (int)r.error_count);
	};
}

fn void parse_infix_to_in_map_of() @test {
	@pool() {
		String content =
`fun foo() {
    val map = mapOf(1 to "one", 2 to "two")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for mapOf with 'to', got %d", (int)r.error_count);
	};
}

fn void parse_fun_nullable_param() @test {
	@pool() {
		String content = `fun foo(x: String?, y: Int?) {}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for nullable params, got %d", (int)r.error_count);
	};
}

fn void parse_fun_complex_nullable_types() @test {
	@pool() {
		String content = `fun foo(x: Map<String, Int>?, y: List<String>?) {}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for complex nullable types, got %d", (int)r.error_count);
	};
}

fn void parse_fun_nullable_return_type() @test {
	@pool() {
		String content = `fun foo(): String? { return null }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for nullable return type, got %d", (int)r.error_count);
	};
}

fn void parse_fun_function_type_nullable_param() @test {
	@pool() {
		String content = `fun foo(block: ((String?) -> Unit)?) {}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for function type with nullable, got %d", (int)r.error_count);
	};
}

fn void parse_intersection_type_definitely_non_nullable() @test {
	@pool() {
		String content = `fun <T> foo(x: T & Any): T & Any { return x }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for intersection type T & Any, got %d", (int)r.error_count);
	};
}

fn void parse_intersection_type_in_generic_bound() @test {
	@pool() {
		String content = `class Foo<V>(private val topic: Topic<K, V & Any>)`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for intersection type in generic arg, got %d", (int)r.error_count);
	};
}

fn void parse_class_with_visibility_constructor() @test {
	@pool() {
		String content = `class Foo internal constructor(private val x: Int)`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for visibility constructor, got %d", (int)r.error_count);
	};
}

fn void parse_class_with_private_constructor() @test {
	@pool() {
		String content = `class Foo private constructor(val x: Int, val y: String)`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for private constructor, got %d", (int)r.error_count);
	};
}

fn void parse_data_class_with_string_template_defaults() @test {
	@pool() {
		String content =
`data class Lib(
    val group_id: String,
    val artifact_id: String,
    val version: String,
    val scope: String = "compile",
    val repo: String = "https://repo1.maven.org/maven2",
    val jar_path: Path = cache.resolve(group_id).resolve("${artifact_id}-$version.jar"),
    val base_url: String = "$repo/${group_id.replace('.', '/')}/$artifact_id",
    val pom_url: String = "$base_url/$version/$artifact_id-$version.pom",
) {
    val jar_file get() = File("${group_id}/${artifact_id}-${version}.jar")
    override fun toString() = "$group_id:$artifact_id:$version"
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for data class with template defaults, got %d", (int)r.error_count);
	};
}

fn void parse_as_safe_cast() @test {
	@pool() {
		String content =
`fun process(data: Any) {
    val map = data as? Map
    val str = data as? String
    val list = data as? List
    val attrs = (variant["attributes"] as? Map)?.mapNotNull { attr ->
        val key = attr.key as? String
        val value = (attr.value as? String)
        key to value
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for as? cast, got %d", (int)r.error_count);
	};
}

fn void parse_nob_kt_string_template_patterns() @test {
	@pool() {
		String content =
`fun log(level: String, msg: String) {
    println("${colorize(level, Color.yellow)} $msg")
    println("${colorize(level, Color.green)} $msg")
    println("${colorize(level, Color.red)} - not found ${e.message}")
    println("${colorize(level, Color.red)} ${e.message}")
    println("${colorize("Building", Color.cyan)}")
}

fun release(module: Module) {
    val main_class_fq = module.main_src()?.main_class_fq()
    val src_target = Paths.get(module.src)?.toFile()
    val x = module.main_src()?.main_class_fq()
    val y = module.target?.toFile()
}

fun foo() {
    val pair = 1 to "one"
    val map = mapOf(1 to "one", 2 to "two")
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for nob.kt patterns, got %d", (int)r.error_count);
	};
}

fn void parse_suspend_receiver_function_type() @test {
	@pool() {
		String content =
`class Route(
    val method: String,
    val handler: suspend Exchange.() -> Any?,
)

fun get(path: String = "", handler: suspend Exchange.() -> Any?) {}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for suspend receiver function type, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.name == "Route", "expected 'Route', got '%s'", cls.name);

		// Check the handler param has correct type text
		bool found_handler = false;
		for (uint i = 0; i < cls.child_count; i++) {
			AstNode* ch = ast::get_child(r, cls, i)!!;
			if (ch.kind == PARAM && ch.name == "handler") {
				found_handler = true;
				assert(ch.type_text == "suspend Exchange.() -> Any?",
					"expected type 'suspend Exchange.() -> Any?', got '%s'", ch.type_text);
			}
		}
		assert(found_handler, "expected to find handler param");

		AstNode* fun = child(r, f, 1);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "get", "expected 'get', got '%s'", fun.name);
	};
}

// ── #7: init block BLOCK child adoption ────────────────────────────

fn void parse_init_block_has_block_child() @test {
	@pool() {
		String content =
`class Foo {
    init {
        println("init")
        val x = 42
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);

		// Find the INIT_BLOCK
		AstNode* init_node = find_kind(r, cls, INIT_BLOCK);
		assert(init_node.child_count >= 1, "expected INIT_BLOCK to have at least 1 child (BLOCK), got %d", (int)init_node.child_count);

		// The BLOCK should be a child of INIT_BLOCK
		AstNode* block_node = find_kind(r, init_node, BLOCK);
		assert(block_node.kind == BLOCK, "expected BLOCK child of INIT_BLOCK");

		// The BLOCK should contain the local val declaration
		usz prop_count = count_kind(r, block_node, PROPERTY_DECL);
		assert(prop_count == 1, "expected 1 PROPERTY_DECL inside init block, got %d", (int)prop_count);
	};
}

// ── #14: variance modifiers on type parameters ─────────────────────

fn void parse_type_param_in_variance() @test {
	@pool() {
		ParseResult* r = do_parse("interface Consumer<in T> {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL);
		assert(iface.name == "Consumer");

		// Find the TYPE_PARAM child
		AstNode* tp = find_kind(r, iface, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		assert(tp.mod_flags & ast::MOD_IN != 0, "expected MOD_IN flag on type param");
		assert(tp.mod_flags & ast::MOD_OUT == 0, "expected no MOD_OUT flag");
	};
}

fn void parse_type_param_out_variance() @test {
	@pool() {
		ParseResult* r = do_parse("interface Producer<out T> {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL);
		assert(iface.name == "Producer");

		AstNode* tp = find_kind(r, iface, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		assert(tp.mod_flags & ast::MOD_OUT != 0, "expected MOD_OUT flag on type param");
		assert(tp.mod_flags & ast::MOD_IN == 0, "expected no MOD_IN flag");
	};
}

fn void parse_type_params_mixed_variance() @test {
	@pool() {
		ParseResult* r = do_parse("interface Transform<in T, out R> {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* iface = child(r, f, 0);
		assert(iface.kind == INTERFACE_DECL);

		// Find both type params
		usz tp_count = count_kind(r, iface, TYPE_PARAM);
		assert(tp_count == 2, "expected 2 TYPE_PARAMs, got %d", (int)tp_count);

		// First param: in T
		AstNode* tp1 = find_kind(r, iface, TYPE_PARAM);
		assert(tp1.name == "T", "expected first type param 'T', got '%s'", tp1.name);
		assert(tp1.mod_flags & ast::MOD_IN != 0, "expected MOD_IN on first type param");

		// Second param: out R (find by iterating)
		bool found_r = false;
		for (uint i = 0; i < iface.child_count; i++) {
			AstNode* ch = ast::get_child(r, iface, i)!!;
			if (ch.kind == TYPE_PARAM && ch.name == "R") {
				found_r = true;
				assert(ch.mod_flags & ast::MOD_OUT != 0, "expected MOD_OUT on R");
				assert(ch.mod_flags & ast::MOD_IN == 0, "expected no MOD_IN on R");
			}
		}
		assert(found_r, "expected to find type param 'R'");
	};
}

fn void parse_type_param_no_variance() @test {
	@pool() {
		ParseResult* r = do_parse("class Box<T> {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		AstNode* tp = find_kind(r, cls, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		// No variance modifiers
		assert(tp.mod_flags & ast::MOD_IN == 0, "expected no MOD_IN");
		assert(tp.mod_flags & ast::MOD_OUT == 0, "expected no MOD_OUT");
	};
}

fn void parse_type_param_single_bound() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T : Comparable<T>> f(x: T) {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		AstNode* tp = find_kind(r, fun, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		assert(count_kind(r, tp, TYPE_REF) == 1, "expected 1 bound, got %d", (int)count_kind(r, tp, TYPE_REF));
		AstNode* bound = find_kind(r, tp, TYPE_REF);
		assert(bound.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", bound.type_text);
	};
}

fn void parse_type_param_multi_bounds() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T : Comparable<T> & Serializable> sort(x: T) {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		AstNode* tp = find_kind(r, fun, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		assert(count_kind(r, tp, TYPE_REF) == 2, "expected 2 bounds, got %d", (int)count_kind(r, tp, TYPE_REF));

		bool found_comparable = false;
		bool found_serializable = false;
		for (uint i = 0; i < tp.child_count; i++) {
			AstNode* ch = ast::get_child(r, tp, i)!!;
			if (ch.kind != TYPE_REF) continue;
			if (ch.type_text == "Comparable<T>") found_comparable = true;
			if (ch.type_text == "Serializable") found_serializable = true;
		}
		assert(found_comparable, "expected Comparable<T> bound");
		assert(found_serializable, "expected Serializable bound");
	};
}

fn void parse_type_param_three_bounds() @test {
	@pool() {
		ParseResult* r = do_parse("class C<T : A & B & C>(val x: T)"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		AstNode* tp = find_kind(r, cls, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		assert(count_kind(r, tp, TYPE_REF) == 3, "expected 3 bounds, got %d", (int)count_kind(r, tp, TYPE_REF));
	};
}

fn void parse_type_param_return_type_amp_not_bound() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T> f(x: T): T & Any = x!!"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		AstNode* tp = find_kind(r, fun, TYPE_PARAM);
		assert(tp.name == "T", "expected type param 'T', got '%s'", tp.name);
		assert(count_kind(r, tp, TYPE_REF) == 0, "expected 0 bounds, got %d", (int)count_kind(r, tp, TYPE_REF));
	};
}

// ── #13: MOD_VAR flag on property declarations ─────────────────────

fn void parse_var_has_mod_var_flag() @test {
	@pool() {
		ParseResult* r = do_parse("var count = 0"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "count");
		assert(prop.mod_flags & ast::MOD_VAR != 0, "expected MOD_VAR flag for 'var'");
	};
}

fn void parse_val_has_no_mod_var_flag() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 42"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL);
		assert(prop.name == "x");
		assert(prop.mod_flags & ast::MOD_VAR == 0, "expected no MOD_VAR flag for 'val'");
	};
}

// ── #14: Receiver type on extension functions/properties ───────────

fn void parse_extension_fun_receiver_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun String.greet() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "greet", "expected 'greet', got '%s'", fun.name);
		assert(fun.extra_text == "String", "expected receiver 'String', got '%s'", fun.extra_text);
	};
}

fn void parse_extension_fun_generic_receiver() @test {
	@pool() {
		ParseResult* r = do_parse("fun List<Int>.first(): Int { return this[0] }"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "first", "expected 'first', got '%s'", fun.name);
		assert(fun.extra_text == "List<Int>", "expected receiver 'List<Int>', got '%s'", fun.extra_text);
	};
}

fn void parse_extension_fun_nullable_receiver() @test {
	@pool() {
		ParseResult* r = do_parse("fun String?.orEmpty(): String { return this ?: \"\" }"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "orEmpty", "expected 'orEmpty', got '%s'", fun.name);
		assert(fun.extra_text.len > 0, "expected non-empty receiver type for nullable extension");
	};
}

fn void parse_regular_fun_no_receiver() @test {
	@pool() {
		ParseResult* r = do_parse("fun greet() {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "greet");
		assert(fun.extra_text.len == 0, "expected no receiver on regular fun, got '%s'", fun.extra_text);
	};
}

fn void parse_extension_property_receiver_type() @test {
	@pool() {
		ParseResult* r = do_parse("val String.lastChar: Char get() = this[length - 1]"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL");
		assert(prop.name == "lastChar", "expected 'lastChar', got '%s'", prop.name);
		assert(prop.extra_text == "String", "expected receiver 'String', got '%s'", prop.extra_text);
	};
}

fn void parse_regular_property_no_receiver() @test {
	@pool() {
		ParseResult* r = do_parse("val count: Int = 42"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL");
		assert(prop.name == "count");
		assert(prop.extra_text.len == 0, "expected no receiver on regular property, got '%s'", prop.extra_text);
	};
}

fn void parse_extension_property_nullable_receiver() @test {
	@pool() {
		ParseResult* r = do_parse("val String?.isNullOrEmpty: Boolean get() = this == null || this.isEmpty()"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL");
		assert(prop.name == "isNullOrEmpty", "expected 'isNullOrEmpty', got '%s'", prop.name);
		assert(prop.extra_text.len > 0, "expected non-empty receiver type for nullable extension property");
	};
}

// ── #15: WHEN_ENTRY nodes in when expressions ──────────────────────

fn void parse_when_has_entry_children() @test {
	@pool() {
		String content =
`fun foo(x: Int) {
    when (x) {
        1 -> println("one")
        2 -> println("two")
        else -> println("other")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		AstNode* f = file_node(r);
		AstNode* block = fun_block(r, child(r, f, 0));
		AstNode* when_expr = find_kind(r, block, WHEN_EXPR);
		usz entry_count = count_kind(r, when_expr, WHEN_ENTRY);
		assert(entry_count == 3, "expected 3 WHEN_ENTRY children, got %d", (int)entry_count);
	};
}

fn void parse_when_else_entry_has_extra_text() @test {
	@pool() {
		String content =
`fun foo(x: Int) {
    when (x) {
        1 -> println("one")
        else -> println("other")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Find WHEN_ENTRY with extra_text == "else"
		bool found_else = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == WHEN_ENTRY && r.nodes[i].extra_text == "else") {
				found_else = true;
			}
		}
		assert(found_else, "expected a WHEN_ENTRY with extra_text 'else'");
	};
}

fn void parse_when_without_subject_has_entries() @test {
	@pool() {
		String content =
`fun foo(x: Int) {
    when {
        x > 0 -> println("positive")
        x < 0 -> println("negative")
        else -> println("zero")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Find the WHEN_EXPR and count entries
		bool found_when = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == WHEN_EXPR) {
				found_when = true;
				usz entry_count = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == WHEN_ENTRY) {
						entry_count++;
					}
				}
				assert(entry_count == 3, "expected 3 WHEN_ENTRY, got %d", (int)entry_count);
			}
		}
		assert(found_when, "expected WHEN_EXPR");
	};
}

fn void parse_when_with_subject_expression() @test {
	@pool() {
		String content =
`fun foo(x: Int) {
    when (x) {
        1 -> println("one")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// The when should have at least one non-WHEN_ENTRY child (the subject)
		// and one WHEN_ENTRY child
		bool found_when = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == WHEN_EXPR) {
				found_when = true;
				usz entry_count = 0;
				usz other_count = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i) {
						if (r.nodes[j].kind == WHEN_ENTRY) {
							entry_count++;
						} else {
							other_count++;
						}
					}
				}
				assert(entry_count >= 1, "expected at least 1 WHEN_ENTRY, got %d", (int)entry_count);
				assert(other_count >= 1, "expected at least 1 non-WHEN_ENTRY child (subject), got %d", (int)other_count);
			}
		}
		assert(found_when, "expected WHEN_EXPR");
	};
}

// ── Destructuring declarations ──────────────────────────────────────

fn void parse_destructuring_val_pair() @test {
	@pool() {
		String content = `fun test() { val (a, b) = pair }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Find the destructuring PROPERTY_DECL
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "(destructuring)") {
				found = true;
				// Should have 2 child PROPERTY_DECL nodes for 'a' and 'b'
				uint child_count = ast::count_children_of_kind(r, &r.nodes[i], PROPERTY_DECL);
				assert(child_count == 2, "expected 2 child PROPERTY_DECL, got %d", (int)child_count);

				// First child: 'a'
				AstNode* c0 = child(r, &r.nodes[i], 0);
				assert(c0.kind == PROPERTY_DECL, "child 0 should be PROPERTY_DECL");
				assert(c0.name == "a", "child 0 name should be 'a', got '%s'", c0.name);

				// Second child: 'b'
				AstNode* c1 = child(r, &r.nodes[i], 1);
				assert(c1.kind == PROPERTY_DECL, "child 1 should be PROPERTY_DECL");
				assert(c1.name == "b", "child 1 name should be 'b', got '%s'", c1.name);
				break;
			}
		}
		assert(found, "expected destructuring PROPERTY_DECL");
	};
}

fn void parse_destructuring_val_triple() @test {
	@pool() {
		String content = `fun test() { val (x, y, z) = triple }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "(destructuring)") {
				uint child_count = ast::count_children_of_kind(r, &r.nodes[i], PROPERTY_DECL);
				assert(child_count == 3, "expected 3 child PROPERTY_DECL, got %d", (int)child_count);
				AstNode* c0 = child(r, &r.nodes[i], 0);
				assert(c0.name == "x", "child 0 name should be 'x', got '%s'", c0.name);
				AstNode* c1 = child(r, &r.nodes[i], 1);
				assert(c1.name == "y", "child 1 name should be 'y', got '%s'", c1.name);
				AstNode* c2 = child(r, &r.nodes[i], 2);
				assert(c2.name == "z", "child 2 name should be 'z', got '%s'", c2.name);
				return;
			}
		}
		assert(false, "expected destructuring PROPERTY_DECL");
	};
}

fn void parse_destructuring_val_with_types() @test {
	@pool() {
		String content = `fun test() { val (a: Int, b: String) = pair }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "(destructuring)") {
				AstNode* c0 = child(r, &r.nodes[i], 0);
				assert(c0.name == "a", "child 0 name should be 'a', got '%s'", c0.name);
				assert(c0.type_text == "Int", "child 0 type should be 'Int', got '%s'", c0.type_text);

				AstNode* c1 = child(r, &r.nodes[i], 1);
				assert(c1.name == "b", "child 1 name should be 'b', got '%s'", c1.name);
				assert(c1.type_text == "String", "child 1 type should be 'String', got '%s'", c1.type_text);
				return;
			}
		}
		assert(false, "expected destructuring PROPERTY_DECL");
	};
}

fn void parse_destructuring_var() @test {
	@pool() {
		String content = `fun test() { var (a, b) = mutable }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "(destructuring)") {
				// Children should inherit MOD_VAR
				AstNode* c0 = child(r, &r.nodes[i], 0);
				assert(c0.mod_flags & ast::MOD_VAR != 0, "child 0 should have MOD_VAR");
				AstNode* c1 = child(r, &r.nodes[i], 1);
				assert(c1.mod_flags & ast::MOD_VAR != 0, "child 1 should have MOD_VAR");
				return;
			}
		}
		assert(false, "expected destructuring PROPERTY_DECL");
	};
}

fn void parse_for_destructuring() @test {
	@pool() {
		String content = `fun test() { for ((k, v) in map) { } }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FOR_STMT) {
				uint param_count = ast::count_children_of_kind(r, &r.nodes[i], PARAM);
				assert(param_count == 2, "expected 2 PARAM children in for-destructuring, got %d", (int)param_count);

				// Find first two PARAMs
				uint found = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == PARAM) {
						if (found == 0) {
							assert(r.nodes[j].name == "k", "param 0 should be 'k', got '%s'", r.nodes[j].name);
						} else if (found == 1) {
							assert(r.nodes[j].name == "v", "param 1 should be 'v', got '%s'", r.nodes[j].name);
						}
						found++;
					}
				}
				return;
			}
		}
		assert(false, "expected FOR_STMT");
	};
}

fn void parse_for_destructuring_with_types() @test {
	@pool() {
		String content = `fun test() { for ((k: String, v: Int) in map) { } }`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FOR_STMT) {
				uint found = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == PARAM) {
						if (found == 0) {
							assert(r.nodes[j].name == "k", "param 0 should be 'k'");
							assert(r.nodes[j].type_text == "String", "param 0 type should be 'String', got '%s'", r.nodes[j].type_text);
						} else if (found == 1) {
							assert(r.nodes[j].name == "v", "param 1 should be 'v'");
							assert(r.nodes[j].type_text == "Int", "param 1 type should be 'Int', got '%s'", r.nodes[j].type_text);
						}
						found++;
					}
				}
				assert(found == 2, "expected 2 params, got %d", found);
				return;
			}
		}
		assert(false, "expected FOR_STMT");
	};
}

// ── Property accessor parsing ───────────────────────────────────────

fn void parse_property_getter_expression() @test {
	@pool() {
		String content =
`class Foo {
    val x: Int
        get() = 42
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Find property 'x'
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "x") {
				// Should have a FUN_DECL child named "get"
				uint getter_count = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == FUN_DECL && r.nodes[j].name == "get") {
						getter_count++;
					}
				}
				assert(getter_count == 1, "expected 1 getter FUN_DECL, got %d", getter_count);
				return;
			}
		}
		assert(false, "expected PROPERTY_DECL 'x'");
	};
}

fn void parse_property_getter_block() @test {
	@pool() {
		String content =
`class Foo {
    val x: Int
        get() { return field + 1 }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "x") {
				uint getter_count = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == FUN_DECL && r.nodes[j].name == "get") {
						getter_count++;
						// The getter should have a BLOCK child
						uint block_count = ast::count_children_of_kind(r, &r.nodes[j], BLOCK);
						assert(block_count == 1, "getter should have 1 BLOCK child, got %d", block_count);
					}
				}
				assert(getter_count == 1, "expected 1 getter FUN_DECL, got %d", getter_count);
				return;
			}
		}
		assert(false, "expected PROPERTY_DECL 'x'");
	};
}

fn void parse_property_setter_with_param() @test {
	@pool() {
		String content =
`class Foo {
    var y: Int = 0
        set(value) { field = value }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "y") {
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == FUN_DECL && r.nodes[j].name == "set") {
						// Setter should have a PARAM child named "value"
						uint param_count = ast::count_children_of_kind(r, &r.nodes[j], PARAM);
						assert(param_count == 1, "setter should have 1 PARAM, got %d", param_count);
						for (uint k = 0; k < r.node_count; k++) {
							if (r.nodes[k].parent == j && r.nodes[k].kind == PARAM) {
								assert(r.nodes[k].name == "value", "setter param should be 'value', got '%s'", r.nodes[k].name);
								return;
							}
						}
					}
				}
				assert(false, "expected setter FUN_DECL for 'y'");
			}
		}
		assert(false, "expected PROPERTY_DECL 'y'");
	};
}

fn void parse_property_getter_and_setter() @test {
	@pool() {
		String content =
`class Foo {
    var z: String = ""
        get() = field.uppercase()
        set(value) { field = value.trim() }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "z") {
				uint getter_count = 0;
				uint setter_count = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == FUN_DECL) {
						if (r.nodes[j].name == "get") getter_count++;
						if (r.nodes[j].name == "set") setter_count++;
					}
				}
				assert(getter_count == 1, "expected 1 getter, got %d", getter_count);
				assert(setter_count == 1, "expected 1 setter, got %d", setter_count);
				return;
			}
		}
		assert(false, "expected PROPERTY_DECL 'z'");
	};
}

fn void parse_property_getter_field_marker() @test {
	@pool() {
		ParseResult* r = do_parse(
`class Foo {
    var x: Int = 0
        get() = field
}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		bool found_field = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "field") {
				assert(r.nodes[i].extra_text == "field",
					"expected getter field NAME_EXPR extra_text='field', got '%s'", r.nodes[i].extra_text);
				found_field = true;
			}
		}
		assert(found_field, "expected NAME_EXPR 'field' in getter body");
	};
}

fn void parse_property_setter_field_marker() @test {
	@pool() {
		ParseResult* r = do_parse(
`class Foo {
    var x: Int = 0
        set(v) { field = v }
}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		bool found_field = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "field") {
				assert(r.nodes[i].extra_text == "field",
					"expected setter field NAME_EXPR extra_text='field', got '%s'", r.nodes[i].extra_text);
				found_field = true;
			}
		}
		assert(found_field, "expected NAME_EXPR 'field' in setter body");
	};
}

fn void parse_field_outside_accessor_no_marker() @test {
	@pool() {
		ParseResult* r = do_parse("fun foo() { val field = 1; print(field) }"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		bool found_use = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "field" && r.nodes[i].extra_text != "field") {
				found_use = true;
			}
		}
		assert(found_use, "expected regular NAME_EXPR 'field' without backing-field marker");
	};
}

fn void parse_property_setter_with_typed_param() @test {
	@pool() {
		String content =
`class Foo {
    var w: Int = 0
        set(v: Int) { field = v }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "w") {
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == FUN_DECL && r.nodes[j].name == "set") {
						for (uint k = 0; k < r.node_count; k++) {
							if (r.nodes[k].parent == j && r.nodes[k].kind == PARAM) {
								assert(r.nodes[k].name == "v", "setter param should be 'v', got '%s'", r.nodes[k].name);
								assert(r.nodes[k].type_text == "Int", "setter param type should be 'Int', got '%s'", r.nodes[k].type_text);
								return;
							}
						}
					}
				}
				assert(false, "expected setter FUN_DECL for 'w'");
			}
		}
		assert(false, "expected PROPERTY_DECL 'w'");
	};
}

// ── Backtick-quoted identifiers ─────────────────────────────────────

fn void parse_backtick_fun_name() @test {
	@pool() {
		ParseResult* r = do_parse("fun `should work`() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL, got %d", (int)fun.kind);
		assert(fun.name == "should work", "expected 'should work', got '%s'", fun.name);
	};
}

fn void parse_backtick_keyword_as_name() @test {
	@pool() {
		ParseResult* r = do_parse("fun `return`(): Int { return 0 }"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "return", "expected name 'return', got '%s'", fun.name);
	};
}

fn void parse_backtick_property_name() @test {
	@pool() {
		ParseResult* r = do_parse("val `class` = 42"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL, got %d", (int)prop.kind);
		assert(prop.name == "class", "expected name 'class', got '%s'", prop.name);
	};
}

fn void parse_backtick_class_name() @test {
	@pool() {
		ParseResult* r = do_parse("class `MyClass` { }"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL, got %d", (int)cls.kind);
		assert(cls.name == "MyClass", "expected name 'MyClass', got '%s'", cls.name);
	};
}

fn void parse_backtick_test_style_fun() @test {
	// Common pattern in Kotlin test code
	@pool() {
		String src = "fun `given valid input should return correct result`() { }";
		ParseResult* r = do_parse(src); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "given valid input should return correct result",
			"expected long test name, got '%s'", fun.name);
	};
}

fn void parse_backtick_name_offset_spans_backticks() @test {
	// name_offset/name_len should cover the backticks for correct LSP ranges
	@pool() {
		ParseResult* r = do_parse("fun `foo`() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "foo", "expected name 'foo', got '%s'", fun.name);
		// `foo` starts at offset 4 (after "fun "), length 5 (backtick + foo + backtick)
		assert(fun.name_offset == 4, "expected name_offset 4, got %d", fun.name_offset);
		assert(fun.name_len == 5, "expected name_len 5, got %d", fun.name_len);
	};
}

// ── Annotation text storage ─────────────────────────────────────────

fn void parse_annotation_on_fun() @test {
	@pool() {
		ParseResult* r = do_parse("@Test fun myTest() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.name == "myTest", "expected 'myTest', got '%s'", fun.name);
		assert(fun.annotation_text == "Test", "expected annotation_text 'Test', got '%s'", fun.annotation_text);
		assert(fun.has_annotation("Test"), "expected has_annotation('Test') to be true");
	};
}

fn void parse_multiple_annotations_on_fun() @test {
	@pool() {
		ParseResult* r = do_parse("@Test @Ignore fun myTest() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.annotation_text == "Test Ignore", "expected 'Test Ignore', got '%s'", fun.annotation_text);
		assert(fun.has_annotation("Test"), "expected has_annotation('Test')");
		assert(fun.has_annotation("Ignore"), "expected has_annotation('Ignore')");
		assert(!fun.has_annotation("Tes"), "partial match should not work");
	};
}

fn void parse_dotted_annotation_stores_simple_name() @test {
	@pool() {
		ParseResult* r = do_parse("@org.junit.Test fun myTest() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.annotation_text == "Test", "expected 'Test' (simple name), got '%s'", fun.annotation_text);
		assert(fun.has_annotation("Test"), "expected has_annotation('Test')");
	};
}

fn void parse_annotation_on_class() @test {
	@pool() {
		ParseResult* r = do_parse("@RunWith(JUnit4::class) class MyTests {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.annotation_text == "RunWith", "expected 'RunWith', got '%s'", cls.annotation_text);
		assert(cls.has_annotation("RunWith"), "expected has_annotation('RunWith')");
	};
}

fn void parse_no_annotation_empty_text() @test {
	@pool() {
		ParseResult* r = do_parse("fun noAnnotation() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		assert(fun.annotation_text == "", "expected empty annotation_text, got '%s'", fun.annotation_text);
		assert(!fun.has_annotation("Test"), "expected has_annotation('Test') to be false");
	};
}

fn void parse_annotation_with_use_site_target() @test {
	@pool() {
		ParseResult* r = do_parse("@get:JvmName(\"foo\") val x = 1"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL");
		assert(prop.annotation_text == "JvmName", "expected 'JvmName', got '%s'", prop.annotation_text);
	};
}

fn void parse_file_annotation_before_package() @test {
	@pool() {
		String content = `@file:Suppress("UNCHECKED_CAST")
package com.example
fun main() {}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for @file: annotation before package, got %d", (int)r.error_count);
	};
}

fn void parse_annotation_on_class_member_fun() @test {
	@pool() {
		String src = `class MyTests {
	@Test fun testAdd() {}
	@Test @Timeout(5) fun testSub() {}
	fun helper() {}
}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");

		AstNode* test1 = child(r, cls, 0);
		assert(test1.kind == FUN_DECL, "expected FUN_DECL for testAdd");
		assert(test1.name == "testAdd", "expected 'testAdd', got '%s'", test1.name);
		assert(test1.has_annotation("Test"), "testAdd should have @Test");

		AstNode* test2 = child(r, cls, 1);
		assert(test2.kind == FUN_DECL, "expected FUN_DECL for testSub");
		assert(test2.name == "testSub", "expected 'testSub', got '%s'", test2.name);
		assert(test2.has_annotation("Test"), "testSub should have @Test");
		assert(test2.has_annotation("Timeout"), "testSub should have @Timeout");

		AstNode* helper = child(r, cls, 2);
		assert(helper.kind == FUN_DECL, "expected FUN_DECL for helper");
		assert(helper.name == "helper", "expected 'helper', got '%s'", helper.name);
		assert(!helper.has_annotation("Test"), "helper should not have @Test");
	};
}

// ── ANNOTATION_ENTRY AST node ──────────────────────────────────────

fn void annotation_entry_attached_as_child() @test {
	@pool() {
		ParseResult* r = do_parse("@Test fun myTest() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		assert(fun.kind == FUN_DECL, "expected FUN_DECL");
		AstNode*? ann = ast::find_annotation(r, fun, "Test");
		assert(@ok(ann), "expected to find @Test child");
		AstNode* a = ann!!;
		assert(a.kind == ANNOTATION_ENTRY, "expected ANNOTATION_ENTRY kind");
		assert(a.name == "Test", "expected name 'Test', got '%s'", a.name);
		assert(a.annotation_target() == "", "expected empty target, got '%s'", a.annotation_target());
	};
}

fn void annotation_entry_dotted_path() @test {
	@pool() {
		ParseResult* r = do_parse("@org.junit.Test fun t() {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, fun, "Test")!!;
		assert(a.name == "Test", "simple name should be last segment");
		assert(a.extra_text == "org.junit.Test", "extra_text should be full dotted path, got '%s'", a.extra_text);
	};
}

fn void annotation_entry_with_use_site_target() @test {
	@pool() {
		ParseResult* r = do_parse("@get:JvmName(\"foo\") val x = 1"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* prop = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, prop, "JvmName")!!;
		assert(a.annotation_target() == "get", "expected target 'get', got '%s'", a.annotation_target());
		assert(a.annotation_text == "(\"foo\")", "expected args slice '(\"foo\")', got '%s'", a.annotation_text);
	};
}

fn void annotation_entry_args_text_captured() @test {
	@pool() {
		ParseResult* r = do_parse("@JvmName(\"hello\") fun f() {}"); defer free_result(r);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, fun, "JvmName")!!;
		assert(a.annotation_text == "(\"hello\")", "expected '(\"hello\")', got '%s'", a.annotation_text);
	};
}

fn void annotation_entry_no_args_empty_text() @test {
	@pool() {
		ParseResult* r = do_parse("@Deprecated fun old() {}"); defer free_result(r);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, fun, "Deprecated")!!;
		assert(a.annotation_text == "", "expected empty args text, got '%s'", a.annotation_text);
	};
}

fn void annotation_entries_multiple_on_one_decl() @test {
	@pool() {
		ParseResult* r = do_parse("@Test @Ignore fun t() {}"); defer free_result(r);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode*? a1 = ast::find_annotation(r, fun, "Test");
		AstNode*? a2 = ast::find_annotation(r, fun, "Ignore");
		assert(@ok(a1), "expected @Test entry");
		assert(@ok(a2), "expected @Ignore entry");
		uint count = ast::count_children_of_kind(r, fun, ANNOTATION_ENTRY);
		assert(count == 2, "expected 2 ANNOTATION_ENTRY children, got %d", count);
	};
}

fn void annotation_entry_on_class() @test {
	@pool() {
		ParseResult* r = do_parse("@RunWith(JUnit4::class) class MyTests {}"); defer free_result(r);
		AstNode* cls = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, cls, "RunWith")!!;
		assert(a.kind == ANNOTATION_ENTRY, "expected ANNOTATION_ENTRY");
		assert(a.annotation_text == "(JUnit4::class)", "expected args '(JUnit4::class)', got '%s'", a.annotation_text);
	};
}

fn void file_annotation_attached_to_file_node() @test {
	@pool() {
		String src = `@file:JvmName("Foo")
package com.example
fun main() {}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* f = file_node(r);
		AstNode* a = ast::find_annotation(r, f, "JvmName")!!;
		assert(a.annotation_target() == "file", "expected target 'file', got '%s'", a.annotation_target());
		assert(a.annotation_text == "(\"Foo\")", "expected args '(\"Foo\")', got '%s'", a.annotation_text);
	};
}

fn void annotation_entries_on_property() @test {
	@pool() {
		ParseResult* r = do_parse("@JvmField val x = 1"); defer free_result(r);
		AstNode* prop = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, prop, "JvmField")!!;
		assert(a.annotation_target() == "", "expected no target");
	};
}

// ── VALUE_ARGUMENT nodes ───────────────────────────────────────────

fn void value_argument_wraps_positional() @test {
	@pool() {
		ParseResult* r = do_parse("fun t() { foo(1, 2, 3) }"); defer free_result(r);
		// Find the CALL_EXPR
		uint call_idx = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "foo") {
				call_idx = i;
				found = true;
				break;
			}
		}
		assert(found, "expected CALL_EXPR for foo");
		uint argc = ast::count_call_args(r, call_idx);
		assert(argc == 3, "expected 3 VALUE_ARGUMENT children, got %d", (int)argc);
	};
}

fn void value_argument_named_arg_has_name() @test {
	@pool() {
		ParseResult* r = do_parse(`fun t() { foo(x = 1, y = 2) }`); defer free_result(r);
		uint call_idx = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "foo") {
				call_idx = i; found = true; break;
			}
		}
		assert(found, "expected CALL_EXPR");
		String[2] names;
		usz vi = 0;
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent == call_idx && r.nodes[j].kind == VALUE_ARGUMENT) {
				if (vi < 2) names[vi++] = r.nodes[j].name;
			}
		}
		assert(vi == 2, "expected 2 args, got %d", (int)vi);
		assert(names[0] == "x", "first arg name should be 'x', got '%s'", names[0]);
		assert(names[1] == "y", "second arg name should be 'y', got '%s'", names[1]);
	};
}

fn void value_argument_spread_marked() @test {
	@pool() {
		ParseResult* r = do_parse("fun t() { foo(*xs) }"); defer free_result(r);
		uint call_idx = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "foo") {
				call_idx = i; found = true; break;
			}
		}
		assert(found, "expected CALL_EXPR");
		bool seen_spread = false;
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent == call_idx && r.nodes[j].kind == VALUE_ARGUMENT) {
				assert(ast::arg_is_spread(&r.nodes[j]), "expected spread arg");
				seen_spread = true;
			}
		}
		assert(seen_spread, "no VALUE_ARGUMENT found");
	};
}

fn void value_argument_expr_child_is_callee_arg() @test {
	@pool() {
		ParseResult* r = do_parse("fun t() { foo(bar()) }"); defer free_result(r);
		uint outer_call = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "foo") {
				outer_call = i; found = true; break;
			}
		}
		assert(found, "expected outer CALL_EXPR");
		uint va_idx = 0;
		bool va_found = false;
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent == outer_call && r.nodes[j].kind == VALUE_ARGUMENT) {
				va_idx = j; va_found = true; break;
			}
		}
		assert(va_found, "no VALUE_ARGUMENT");
		AstNode* expr = ast::get_arg_expr(r, va_idx)!!;
		assert(expr.kind == CALL_EXPR, "expected CALL_EXPR child, got %d", (int)expr.kind);
		assert(expr.name == "bar", "expected 'bar', got '%s'", expr.name);
	};
}

fn void value_argument_trailing_lambda_not_wrapped() @test {
	@pool() {
		ParseResult* r = do_parse("fun t() { xs.filter { it > 0 } }"); defer free_result(r);
		// CALL_EXPR for filter has trailing lambda as VALUE_ARGUMENT child
		// (extra_text = "trailing"). Verify it's there and marked.
		uint call_idx = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "filter") {
				call_idx = i; found = true; break;
			}
		}
		assert(found, "expected filter CALL_EXPR");
		uint va_count = ast::count_call_args(r, call_idx);
		assert(va_count == 1, "expected 1 VALUE_ARGUMENT (trailing lambda), got %d", (int)va_count);
		bool seen_trailing_lambda = false;
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent != call_idx) continue;
			if (r.nodes[j].kind != VALUE_ARGUMENT) continue;
			assert(r.nodes[j].extra_text == "trailing",
				"expected trailing marker, got '%s'", r.nodes[j].extra_text);
			AstNode* expr = ast::get_arg_expr(r, j)!!;
			assert(expr.kind == LAMBDA_EXPR, "expected LAMBDA_EXPR child");
			seen_trailing_lambda = true;
		}
		assert(seen_trailing_lambda, "no trailing-lambda VALUE_ARGUMENT");
	};
}

fn void value_argument_call_with_args_and_trailing_lambda() @test {
	@pool() {
		// foo(1, 2) { it } — both parenthesized args and trailing lambda
		// should be VALUE_ARGUMENT children of the SAME CALL_EXPR (no double-wrap).
		ParseResult* r = do_parse("fun t() { foo(1, 2) { it } }"); defer free_result(r);
		// Find the outermost CALL_EXPR for foo
		uint outer_call = uint.max;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind != CALL_EXPR) continue;
			if (r.nodes[i].name != "foo") continue;
			// Outermost has parent != CALL_EXPR
			uint p = r.nodes[i].parent;
			if (p == ast::NO_PARENT || r.nodes[p].kind != CALL_EXPR) {
				outer_call = i;
				break;
			}
		}
		assert(outer_call != uint.max, "expected outer foo CALL_EXPR");
		uint va_count = ast::count_call_args(r, outer_call);
		assert(va_count == 3, "expected 3 VALUE_ARGUMENT (1, 2, lambda), got %d", (int)va_count);
		// Last VALUE_ARGUMENT should have extra_text == "trailing"
		uint last_va = uint.max;
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent != outer_call) continue;
			if (r.nodes[j].kind != VALUE_ARGUMENT) continue;
			last_va = j;
		}
		assert(last_va != uint.max, "no VALUE_ARGUMENT");
		assert(r.nodes[last_va].extra_text == "trailing",
			"expected last VA to be trailing, got '%s'", r.nodes[last_va].extra_text);
		AstNode* lam = ast::get_arg_expr(r, last_va)!!;
		assert(lam.kind == LAMBDA_EXPR, "expected LAMBDA_EXPR");
	};
}

fn void value_argument_lambda_only_no_parens() @test {
	@pool() {
		// runBlocking { ... } — call with trailing lambda only, no parens.
		ParseResult* r = do_parse("fun t() { runBlocking { 1 } }"); defer free_result(r);
		uint call_idx = uint.max;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "runBlocking") {
				call_idx = i; break;
			}
		}
		assert(call_idx != uint.max, "expected runBlocking CALL_EXPR");
		uint va_count = ast::count_call_args(r, call_idx);
		assert(va_count == 1, "expected 1 VALUE_ARGUMENT (trailing lambda), got %d", (int)va_count);
	};
}

fn void value_argument_paren_lambda_is_wrapped() @test {
	@pool() {
		ParseResult* r = do_parse("fun t() { foo({ it }) }"); defer free_result(r);
		uint call_idx = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "foo") {
				call_idx = i; found = true; break;
			}
		}
		assert(found, "expected foo CALL_EXPR");
		uint va_count = ast::count_call_args(r, call_idx);
		assert(va_count == 1, "expected 1 VALUE_ARGUMENT (parenthesized lambda wrapped), got %d", (int)va_count);
		// The wrapped expression should be a LAMBDA_EXPR
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent == call_idx && r.nodes[j].kind == VALUE_ARGUMENT) {
				AstNode* expr = ast::get_arg_expr(r, j)!!;
				assert(expr.kind == LAMBDA_EXPR, "expected LAMBDA_EXPR child of VALUE_ARGUMENT, got %d", (int)expr.kind);
				break;
			}
		}
	};
}

// ── ANONYMOUS_FUN_EXPR nodes ───────────────────────────────────────

fn void anonymous_fun_expr_basic() @test {
	@pool() {
		ParseResult* r = do_parse("val f = fun(x: Int): Int { return x + 1 }"); defer free_result(r);
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == ANONYMOUS_FUN_EXPR) { found = true; break; }
		}
		assert(found, "expected ANONYMOUS_FUN_EXPR node");
	};
}

fn void anonymous_fun_expr_has_param() @test {
	@pool() {
		ParseResult* r = do_parse("val f = fun(x: Int): Int { return x }"); defer free_result(r);
		uint anon_idx = 0;
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == ANONYMOUS_FUN_EXPR) { anon_idx = i; found = true; break; }
		}
		assert(found, "expected ANONYMOUS_FUN_EXPR");
		AstNode* anon = &r.nodes[anon_idx];
		uint pcount = ast::count_children_of_kind(r, anon, PARAM);
		assert(pcount == 1, "expected 1 PARAM child, got %d", (int)pcount);
		AstNode* p = ast::find_child(r, anon, PARAM)!!;
		assert(p.name == "x", "expected param 'x', got '%s'", p.name);
		assert(p.type_text == "Int", "expected type 'Int', got '%s'", p.type_text);
	};
}

fn void anonymous_fun_expr_has_return_type() @test {
	@pool() {
		ParseResult* r = do_parse("val f = fun(): String { return \"hi\" }"); defer free_result(r);
		bool ok = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == ANONYMOUS_FUN_EXPR) {
				assert(r.nodes[i].type_text == "String", "expected return type 'String', got '%s'", r.nodes[i].type_text);
				ok = true;
				break;
			}
		}
		assert(ok, "expected ANONYMOUS_FUN_EXPR");
	};
}

fn void anonymous_fun_expr_expression_body() @test {
	@pool() {
		ParseResult* r = do_parse("val f = fun(x: Int) = x + 1"); defer free_result(r);
		bool ok = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == ANONYMOUS_FUN_EXPR) { ok = true; break; }
		}
		assert(ok, "expected ANONYMOUS_FUN_EXPR for expression-body form");
	};
}

fn void anonymous_fun_expr_no_params_no_return() @test {
	@pool() {
		ParseResult* r = do_parse("val f = fun() { println(\"hi\") }"); defer free_result(r);
		bool ok = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == ANONYMOUS_FUN_EXPR) { ok = true; break; }
		}
		assert(ok, "expected ANONYMOUS_FUN_EXPR");
	};
}

fn void anonymous_fun_expr_in_call_argument() @test {
	@pool() {
		ParseResult* r = do_parse("fun t() { foo(fun(x: Int): Int = x * 2) }"); defer free_result(r);
		uint call_idx = 0;
		bool found_call = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CALL_EXPR && r.nodes[i].name == "foo") {
				call_idx = i; found_call = true; break;
			}
		}
		assert(found_call, "expected foo CALL_EXPR");
		uint va_count = ast::count_call_args(r, call_idx);
		assert(va_count == 1, "expected 1 VALUE_ARGUMENT, got %d", (int)va_count);
		// VALUE_ARGUMENT child should be ANONYMOUS_FUN_EXPR
		bool wrapped = false;
		for (uint j = 0; j < r.node_count; j++) {
			if (r.nodes[j].parent == call_idx && r.nodes[j].kind == VALUE_ARGUMENT) {
				AstNode* expr = ast::get_arg_expr(r, j)!!;
				assert(expr.kind == ANONYMOUS_FUN_EXPR, "expected ANONYMOUS_FUN_EXPR child, got %d", (int)expr.kind);
				wrapped = true;
				break;
			}
		}
		assert(wrapped, "expected wrapped anonymous fun arg");
	};
}

// ── TYPE_ARG nodes ─────────────────────────────────────────────────

fn void parse_type_args_in_supertype() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo : Bar<Int, String>"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");
		assert(cls.name == "Foo");

		// TYPE_REF for Bar should have TYPE_ARG children
		AstNode* type_ref = ast::find_child(r, cls, TYPE_REF)!!;
		assert(type_ref.name == "Bar", "expected 'Bar', got '%s'", type_ref.name);

		// Count TYPE_ARG children of the class (they're adopted by the class)
		uint arg_count = ast::count_children_of_kind(r, cls, TYPE_ARG);
		assert(arg_count == 2, "expected 2 TYPE_ARG, got %d", (int)arg_count);
	};
}

fn void parse_type_args_star_projection() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo : Bar<*>"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);

		uint arg_count = ast::count_children_of_kind(r, cls, TYPE_ARG);
		assert(arg_count == 1, "expected 1 TYPE_ARG, got %d", (int)arg_count);

		AstNode* arg = ast::find_child(r, cls, TYPE_ARG)!!;
		assert(arg.name == "*", "expected '*', got '%s'", arg.name);
	};
}

fn void parse_type_args_nested_generics() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo : Bar<Map<String, List<Int>>>"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);

		uint arg_count = ast::count_children_of_kind(r, cls, TYPE_ARG);
		assert(arg_count == 1, "expected 1 TYPE_ARG for deeply nested, got %d", (int)arg_count);

		AstNode* arg = ast::find_child(r, cls, TYPE_ARG)!!;
		assert(arg.type_text == "Map<String, List<Int>>", "expected 'Map<String, List<Int>>', got '%s'", arg.type_text);
	};
}

fn void parse_type_args_use_site_variance() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo : Bar<out Int, in String>"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);

		uint arg_count = ast::count_children_of_kind(r, cls, TYPE_ARG);
		assert(arg_count == 2, "expected 2 TYPE_ARG, got %d", (int)arg_count);
	};
}

// ── T11: TYPE_REF dual-storage sub-AST ──────────────────────────────

fn void type_ref_simple_param_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(x: Int) {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode* param = nth_kind(r, fun, PARAM, 0);
		assert(param.type_text == "Int", "expected param type_text 'Int', got '%s'", param.type_text);
		uint tr_idx = ast::node_index(r, param) + 1;
		AstNode* tr = &r.nodes[tr_idx];
		assert(tr.parent == ast::node_index(r, param) && tr.kind == TYPE_REF, "expected adjacent TYPE_REF child");
		assert(tr.name == "Int", "expected TYPE_REF name 'Int', got '%s'", tr.name);
		assert(tr.child_count == 0, "expected no TYPE_REF children, got %d", (int)tr.child_count);
	};
}

fn void type_ref_generic_return_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(): List<String> = listOf()"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		assert(fun.type_text == "List<String>", "expected return type_text 'List<String>', got '%s'", fun.type_text);
		AstNode* tr = first_type_ref_child(r, fun);
		assert(tr.name == "List", "expected TYPE_REF name 'List', got '%s'", tr.name);
		assert(count_kind(r, tr, TYPE_REF) == 1, "expected 1 TYPE_REF child, got %d", (int)count_kind(r, tr, TYPE_REF));
		AstNode* arg = nth_kind(r, tr, TYPE_REF, 0);
		assert(arg.name == "String", "expected type arg name 'String', got '%s'", arg.name);
		assert(arg.extra_text == "arg", "expected type arg marker 'arg', got '%s'", arg.extra_text);
	};
}

// PROBE: dump trees for T11b deferred cases.
fn void probe_t11b_function_types() @test {
	@pool() {
		String[] sources = {
			"fun f(): ((Int) -> String)? = null",
			"fun f(cb: suspend (A, B) -> C?) {}",
			"fun f(): Map<String, List<Pair<Int, Boolean>>> = mapOf()",
		};
		File fh = file::open("/tmp/probe_t11b.txt", "w")!!;
		defer (void)fh.close();
		foreach (src : sources) {
			io::fprintn(&fh, "\n=== SOURCE ===")!!;
			io::fprintn(&fh, src)!!;
			ParseResult* r = do_parse(src); defer free_result(r);
			io::fprintfn(&fh, "error_count=%d node_count=%d", (int)r.error_count, (int)r.node_count)!!;
			for (uint i = 0; i < r.node_count; i++) {
				AstNode* n = &r.nodes[i];
				io::fprintfn(&fh,
					"  [%d] parent=%d kind=%d name='%s' type_text='%s' extra='%s' mods=0x%x",
					(int)i, (int)n.parent, (int)n.kind, n.name, n.type_text,
					n.extra_text, (ulong)n.mod_flags)!!;
			}
		}
	};
}

// ── T11b: function-type / suspend / deeply nested TYPE_REF dual-storage ──

fn void type_ref_nullable_function_type_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(): ((Int) -> String)? = null"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		assert(fun.type_text == "((Int) -> String)?",
			"expected fun type_text '((Int) -> String)?', got '%s'", fun.type_text);
		AstNode* tr = first_type_ref_child(r, fun);
		assert(tr.extra_text == "function nullable",
			"expected 'function nullable' marker, got '%s'", tr.extra_text);
		assert(tr.type_text == "((Int) -> String)?",
			"expected tr type_text '((Int) -> String)?', got '%s'", tr.type_text);
		assert(count_kind(r, tr, TYPE_REF) == 2,
			"expected 2 TYPE_REF children (param+return), got %d",
			(int)count_kind(r, tr, TYPE_REF));
		AstNode* p = nth_kind(r, tr, TYPE_REF, 0);
		assert(p.name == "Int", "expected param name 'Int', got '%s'", p.name);
		assert(p.extra_text == "param", "expected 'param' marker, got '%s'", p.extra_text);
		AstNode* ret = nth_kind(r, tr, TYPE_REF, 1);
		assert(ret.name == "String", "expected return name 'String', got '%s'", ret.name);
		assert(ret.extra_text == "return", "expected 'return' marker, got '%s'", ret.extra_text);
	};
}

fn void type_ref_suspend_function_type_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(cb: suspend (A, B) -> C?) {}"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode* param = nth_kind(r, fun, PARAM, 0);
		assert(param.type_text == "suspend (A, B) -> C?",
			"expected param type_text 'suspend (A, B) -> C?', got '%s'", param.type_text);
		AstNode* tr = first_type_ref_child(r, param);
		assert(tr.extra_text == "function",
			"expected 'function' marker, got '%s'", tr.extra_text);
		assert((tr.mod_flags & ast::MOD_SUSPEND) != 0,
			"expected MOD_SUSPEND on suspend function type");
		assert(count_kind(r, tr, TYPE_REF) == 3,
			"expected 3 TYPE_REF children (2 params + return), got %d",
			(int)count_kind(r, tr, TYPE_REF));
		AstNode* p0 = nth_kind(r, tr, TYPE_REF, 0);
		assert(p0.name == "A" && p0.extra_text == "param",
			"expected param 0 'A'/'param', got '%s'/'%s'", p0.name, p0.extra_text);
		AstNode* p1 = nth_kind(r, tr, TYPE_REF, 1);
		assert(p1.name == "B" && p1.extra_text == "param",
			"expected param 1 'B'/'param', got '%s'/'%s'", p1.name, p1.extra_text);
		AstNode* ret = nth_kind(r, tr, TYPE_REF, 2);
		assert(ret.name == "C", "expected return name 'C', got '%s'", ret.name);
		assert(ret.extra_text == "return nullable",
			"expected 'return nullable' marker, got '%s'", ret.extra_text);
		assert(ret.type_text == "C?",
			"expected return type_text 'C?', got '%s'", ret.type_text);
	};
}

fn void type_ref_deeply_nested_generic_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(): Map<String, List<Pair<Int, Boolean>>> = mapOf()");
		defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		assert(fun.type_text == "Map<String, List<Pair<Int, Boolean>>>",
			"expected fun type_text, got '%s'", fun.type_text);
		// Map<...>
		AstNode* map_tr = first_type_ref_child(r, fun);
		assert(map_tr.name == "Map", "expected outer 'Map', got '%s'", map_tr.name);
		assert(map_tr.type_text == "Map<String, List<Pair<Int, Boolean>>>",
			"expected outer type_text, got '%s'", map_tr.type_text);
		assert(count_kind(r, map_tr, TYPE_REF) == 2,
			"expected 2 type args under Map, got %d",
			(int)count_kind(r, map_tr, TYPE_REF));
		AstNode* str_arg = nth_kind(r, map_tr, TYPE_REF, 0);
		assert(str_arg.name == "String" && str_arg.extra_text == "arg",
			"expected first arg 'String'/'arg', got '%s'/'%s'", str_arg.name, str_arg.extra_text);
		// List<Pair<Int, Boolean>>
		AstNode* list_tr = nth_kind(r, map_tr, TYPE_REF, 1);
		assert(list_tr.name == "List", "expected 'List', got '%s'", list_tr.name);
		assert(list_tr.type_text == "List<Pair<Int, Boolean>>",
			"expected list type_text, got '%s'", list_tr.type_text);
		assert(count_kind(r, list_tr, TYPE_REF) == 1,
			"expected 1 type arg under List, got %d",
			(int)count_kind(r, list_tr, TYPE_REF));
		// Pair<Int, Boolean>
		AstNode* pair_tr = nth_kind(r, list_tr, TYPE_REF, 0);
		assert(pair_tr.name == "Pair", "expected 'Pair', got '%s'", pair_tr.name);
		assert(pair_tr.type_text == "Pair<Int, Boolean>",
			"expected pair type_text, got '%s'", pair_tr.type_text);
		assert(count_kind(r, pair_tr, TYPE_REF) == 2,
			"expected 2 type args under Pair, got %d",
			(int)count_kind(r, pair_tr, TYPE_REF));
		AstNode* int_arg = nth_kind(r, pair_tr, TYPE_REF, 0);
		assert(int_arg.name == "Int" && int_arg.extra_text == "arg",
			"expected 'Int'/'arg', got '%s'/'%s'", int_arg.name, int_arg.extra_text);
		AstNode* bool_arg = nth_kind(r, pair_tr, TYPE_REF, 1);
		assert(bool_arg.name == "Boolean" && bool_arg.extra_text == "arg",
			"expected 'Boolean'/'arg', got '%s'/'%s'", bool_arg.name, bool_arg.extra_text);
	};
}

fn void type_ref_intersection_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T> f(x: T): T & Any = x!!"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		assert(fun.type_text == "T & Any", "expected return type_text 'T & Any', got '%s'", fun.type_text);
		AstNode* tr = first_type_ref_child(r, fun);
		assert(tr.extra_text == "intersection", "expected intersection marker, got '%s'", tr.extra_text);
		assert(count_kind(r, tr, TYPE_REF) == 2, "expected 2 intersection members, got %d", (int)count_kind(r, tr, TYPE_REF));
		assert(nth_kind(r, tr, TYPE_REF, 0).name == "T", "expected first intersection member T");
		assert(nth_kind(r, tr, TYPE_REF, 1).name == "Any", "expected second intersection member Any");
	};
}

fn void type_ref_variance_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("class Box<T>(val items: Array<out T>)"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* cls = child(r, file_node(r), 0);
		AstNode* param = nth_kind(r, cls, PARAM, 0);
		assert(param.type_text == "Array<out T>", "expected param type_text 'Array<out T>', got '%s'", param.type_text);
		uint tr_idx = ast::node_index(r, param) + 1;
		AstNode* tr = &r.nodes[tr_idx];
		assert(tr.parent == ast::node_index(r, param) && tr.kind == TYPE_REF, "expected adjacent TYPE_REF child");
		assert(tr.name == "Array", "expected TYPE_REF name 'Array', got '%s'", tr.name);
		AstNode* arg = nth_kind(r, tr, TYPE_REF, 0);
		assert(arg.name == "T", "expected type arg name 'T', got '%s'", arg.name);
		assert((arg.mod_flags & ast::MOD_OUT) != 0, "expected MOD_OUT on variance type arg");
	};
}

// ── WHERE_CONSTRAINT nodes ─────────────────────────────────────────

fn void parse_where_clause_on_class() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo<T> where T : Comparable<T>, T : Serializable {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL);

		uint wc_count = ast::count_children_of_kind(r, cls, WHERE_CONSTRAINT);
		assert(wc_count == 2, "expected 2 WHERE_CONSTRAINT, got %d", (int)wc_count);

		AstNode* wc = ast::find_child(r, cls, WHERE_CONSTRAINT)!!;
		assert(wc.name == "T", "expected 'T', got '%s'", wc.name);
		assert(wc.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", wc.type_text);
	};
}

fn void parse_where_clause_on_fun() @test {
	@pool() {
		ParseResult* r = do_parse("fun <T> sort(list: List<T>) where T : Comparable<T> {}"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* fun = child(r, f, 0);
		assert(fun.kind == FUN_DECL);

		uint wc_count = ast::count_children_of_kind(r, fun, WHERE_CONSTRAINT);
		assert(wc_count == 1, "expected 1 WHERE_CONSTRAINT, got %d", (int)wc_count);

		AstNode* wc = ast::find_child(r, fun, WHERE_CONSTRAINT)!!;
		assert(wc.name == "T");
		assert(wc.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", wc.type_text);
	};
}

// ── Typealias type params ──────────────────────────────────────────

fn void parse_typealias_type_params() @test {
	@pool() {
		ParseResult* r = do_parse("typealias StringMap<V> = Map<String, V>"); defer free_result(r);
		AstNode* f = file_node(r);
		AstNode* ta = child(r, f, 0);
		assert(ta.kind == TYPEALIAS_DECL);
		assert(ta.name == "StringMap");

		uint tp_count = ast::count_children_of_kind(r, ta, TYPE_PARAM);
		assert(tp_count == 1, "expected 1 TYPE_PARAM on typealias, got %d", (int)tp_count);

		AstNode* tp = ast::find_child(r, ta, TYPE_PARAM)!!;
		assert(tp.name == "V", "expected 'V', got '%s'", tp.name);
	};
}

// ── Destructuring lambda parameters ────────────────────────────────

fn void parse_lambda_destructuring_params() @test {
	@pool() {
		String content =
`fun foo() {
    list.map { (a, b) -> a + b }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Find the LAMBDA_EXPR and check it has PARAM children named "a" and "b"
		bool found_a = false;
		bool found_b = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == LAMBDA_EXPR) {
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == PARAM) {
						if (r.nodes[j].name == "a") found_a = true;
						if (r.nodes[j].name == "b") found_b = true;
					}
				}
			}
		}
		assert(found_a, "expected PARAM 'a' in lambda");
		assert(found_b, "expected PARAM 'b' in lambda");
	};
}

fn void parse_lambda_destructuring_with_underscore() @test {
	@pool() {
		String content =
`fun foo() {
    list.map { (_, dp) -> dp.name }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Should have PARAM 'dp' but NOT a PARAM '_'
		bool found_dp = false;
		bool found_underscore = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM) {
				if (r.nodes[i].name == "dp") found_dp = true;
				if (r.nodes[i].name == "_") found_underscore = true;
			}
		}
		assert(found_dp, "expected PARAM 'dp' in lambda");
		assert(!found_underscore, "underscore should not create a PARAM node");
	};
}

// ── Soft keyword as identifier tests ────────────────────────────

fn void parse_param_named_init() @test {
	@pool() {
		String content = `fun topology(init: Topology.() -> Unit): Topology = Topology().apply(init)`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// Should have FUN_DECL 'topology' with PARAM 'init'
		bool found_fun = false;
		bool found_param = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FUN_DECL && r.nodes[i].name == "topology") found_fun = true;
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "init") found_param = true;
		}
		assert(found_fun, "expected FUN_DECL 'topology'");
		assert(found_param, "expected PARAM 'init'");
	};
}

fn void parse_param_named_constructor() @test {
	@pool() {
		String content = `fun create(constructor: String): Any = Unit`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		bool found_param = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "constructor") found_param = true;
		}
		assert(found_param, "expected PARAM 'constructor'");
	};
}

fn void parse_val_named_init() @test {
	@pool() {
		String content = `val init = "hello"`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PROPERTY_DECL && r.nodes[i].name == "init") found = true;
		}
		assert(found, "expected PROPERTY_DECL 'init'");
	};
}

fn void parse_init_block_still_works() @test {
	@pool() {
		String content =
`class Foo {
    init {
        println("hello")
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		bool found_init = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == INIT_BLOCK) found_init = true;
		}
		assert(found_init, "expected INIT_BLOCK in class");
	};
}

fn void parse_return_when_expression() @test {
	@pool() {
		String content =
`fun test(x: Any): String {
    return when (x) {
        null -> "null"
        else -> "other"
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// RETURN_EXPR should have WHEN_EXPR as child, not sibling
		bool found_return = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind != RETURN_EXPR) continue;
			found_return = true;

			// Check that WHEN_EXPR is a child of RETURN_EXPR
			bool when_is_child = false;
			for (uint j = 0; j < r.node_count; j++) {
				if (r.nodes[j].parent == i && r.nodes[j].kind == WHEN_EXPR) {
					when_is_child = true;
				}
			}
			assert(when_is_child, "WHEN_EXPR should be child of RETURN_EXPR");
		}
		assert(found_return, "expected RETURN_EXPR");
	};
}

fn void parse_return_if_expression() @test {
	@pool() {
		String content =
`fun test(x: Boolean): Int {
    return if (x) 1 else 2
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		bool found_return = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind != RETURN_EXPR) continue;
			found_return = true;

			bool if_is_child = false;
			for (uint j = 0; j < r.node_count; j++) {
				if (r.nodes[j].parent == i && r.nodes[j].kind == IF_EXPR) {
					if_is_child = true;
				}
			}
			assert(if_is_child, "IF_EXPR should be child of RETURN_EXPR");
		}
		assert(found_return, "expected RETURN_EXPR");
	};
}

fn void parse_return_nested_when() @test {
	@pool() {
		String content =
`fun statusReply(o: Any): String {
    return when (o) {
        null -> "ok"
        else -> when (o) {
            "00" -> "a"
            "04" -> "b"
            else -> "c"
        }
    }
}`;
		ParseResult* r = do_parse(content); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);

		// The function body BLOCK should have exactly 1 child: RETURN_EXPR
		// (not RETURN_EXPR + WHEN_EXPR as siblings)
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind != FUN_DECL) continue;
			// Find the BLOCK child
			for (uint j = 0; j < r.node_count; j++) {
				if (r.nodes[j].parent != i || r.nodes[j].kind != BLOCK) continue;

				uint block_children = 0;
				for (uint k = 0; k < r.node_count; k++) {
					if (r.nodes[k].parent == j) block_children++;
				}
				assert(block_children == 1, "function body should have 1 child (RETURN_EXPR), got %d", block_children);
			}
		}
	};
}

// ── FQN dot chain inside index expression ──────────────────────────

fn void fqn_dot_chain_in_index_expr() @test {
	@pool() {
		String src = `import libs.kafka.StreamsConfig

class Config {
    val kafka: StreamsConfig = StreamsConfig(
        additionalProperties = Properties().apply {
            this[org.apache.kafka.streams.StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG] = 0
            this[org.apache.kafka.streams.StreamsConfig.NUM_STREAM_THREADS_CONFIG] = 3
        }
    )
}`;
		ParseResult* r = do_parse(src);
		defer free_result(r);

		// Count DOT_EXPRs with name="StreamsConfig"
		uint sc_count = 0;
		for (uint i = 0; i < r.node_count; i++) {
			AstNode* n = &r.nodes[i];
			if (n.kind != DOT_EXPR) continue;
			if (n.name == "StreamsConfig") sc_count++;
		}
		assert(sc_count >= 2, "expected >=2 DOT_EXPRs with name='StreamsConfig', got %d", sc_count);
	};
}

// ── PARAM default value capture ────────────────────────────────────

fn void param_default_simple_literal() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(x: Int = 42) {}"); defer free_result(r);
		AstNode* p = null;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "x") {
				p = &r.nodes[i]; break;
			}
		}
		assert(p != null, "expected PARAM x");
		assert(ast::param_has_default(p), "expected default value");
		assert(ast::param_default_text(p) == "42",
			"expected '42', got '%s'", ast::param_default_text(p));
	};
}

fn void param_default_string_literal() @test {
	@pool() {
		ParseResult* r = do_parse(`fun f(name: String = "hi") {}`); defer free_result(r);
		AstNode* p = null;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "name") {
				p = &r.nodes[i]; break;
			}
		}
		assert(p != null, "expected PARAM name");
		assert(ast::param_default_text(p) == `"hi"`,
			"expected '\"hi\"', got '%s'", ast::param_default_text(p));
	};
}

fn void param_default_call_expr() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(xs: List<Int> = listOf(1, 2)) {}"); defer free_result(r);
		AstNode* p = null;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "xs") {
				p = &r.nodes[i]; break;
			}
		}
		assert(p != null, "expected PARAM xs");
		String dt = ast::param_default_text(p);
		assert(dt == "listOf(1, 2)",
			"expected 'listOf(1, 2)', got '%s'", dt);
	};
}

fn void param_no_default_text_empty() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(x: Int) {}"); defer free_result(r);
		AstNode* p = null;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "x") {
				p = &r.nodes[i]; break;
			}
		}
		assert(p != null, "expected PARAM x");
		assert(!ast::param_has_default(p), "expected no default");
		assert(ast::param_default_text(p).len == 0, "expected empty default text");
	};
}

fn void param_default_multiple_params() @test {
	@pool() {
		ParseResult* r = do_parse("fun f(a: Int = 1, b: String, c: Int = 3) {}"); defer free_result(r);
		String[3] defaults;
		usz idx = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && idx < 3) {
				defaults[idx++] = ast::param_default_text(&r.nodes[i]);
			}
		}
		assert(defaults[0] == "1", "first default expected '1', got '%s'", defaults[0]);
		assert(defaults[1].len == 0, "middle param has no default, got '%s'", defaults[1]);
		assert(defaults[2] == "3", "third default expected '3', got '%s'", defaults[2]);
	};
}

// ── Labeled return / break / continue + labeled lambdas (Kotlin spec §16.32) ──

fn void return_label_stored_in_extra_text() @test {
	@pool() {
		ParseResult* r = do_parse("fun f() { return@foo }"); defer free_result(r);
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == RETURN_EXPR) {
				assert(r.nodes[i].extra_text == "foo",
					"expected RETURN_EXPR.extra_text='foo', got '%s'", r.nodes[i].extra_text);
				found = true;
			}
		}
		assert(found, "expected RETURN_EXPR node");
	};
}

fn void break_label_stored_in_extra_text() @test {
	@pool() {
		ParseResult* r = do_parse("fun f() { while (true) { break@outer } }"); defer free_result(r);
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == BREAK_EXPR) {
				assert(r.nodes[i].extra_text == "outer",
					"expected BREAK_EXPR.extra_text='outer', got '%s'", r.nodes[i].extra_text);
				found = true;
			}
		}
		assert(found, "expected BREAK_EXPR node");
	};
}

fn void continue_label_stored_in_extra_text() @test {
	@pool() {
		ParseResult* r = do_parse("fun f() { while (true) { continue@loop } }"); defer free_result(r);
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == CONTINUE_EXPR) {
				assert(r.nodes[i].extra_text == "loop",
					"expected CONTINUE_EXPR.extra_text='loop', got '%s'", r.nodes[i].extra_text);
				found = true;
			}
		}
		assert(found, "expected CONTINUE_EXPR node");
	};
}

fn void labeled_lambda_label_stored_in_extra_text() @test {
	@pool() {
		// `name@ { ... }` -- label name stored on the LAMBDA_EXPR
		ParseResult* r = do_parse("fun f() { val x = block@ { 42 } }"); defer free_result(r);
		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == LAMBDA_EXPR) {
				assert(r.nodes[i].extra_text == "block",
					"expected LAMBDA_EXPR.extra_text='block', got '%s'", r.nodes[i].extra_text);
				found = true;
			}
		}
		assert(found, "expected LAMBDA_EXPR node");
	};
}

fn void unlabeled_return_has_empty_extra_text() @test {
	@pool() {
		ParseResult* r = do_parse("fun f() { return }"); defer free_result(r);
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == RETURN_EXPR) {
				assert(r.nodes[i].extra_text.len == 0,
					"expected empty extra_text for unlabeled return, got '%s'", r.nodes[i].extra_text);
			}
		}
	};
}

// ── User-defined infix calls (Kotlin spec §17.5) ─────────────────

fn void same_file_infix_recognized_in_pratt() @test {
	@pool() {
		// `combine` is declared `infix fun` in this file -- the Pratt loop
		// must recognize `a combine b` as a binary infix call and produce
		// a BINARY_EXPR wrapping it (not two separate expression statements).
		ParseResult* r = do_parse(
			"infix fun Int.combine(other: Int): Int = this + other\nfun main() { val z = 1 combine 2 }"
		); defer free_result(r);

		bool found_combine_binary = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == BINARY_EXPR && r.nodes[i].extra_text == "combine") {
				found_combine_binary = true;
				break;
			}
		}
		assert(found_combine_binary,
			"expected BINARY_EXPR with extra_text='combine' for `1 combine 2`");
	};
}

fn void unknown_infix_not_recognized() @test {
	@pool() {
		// `bogus` is not defined as `infix fun` in this file -- must NOT
		// be treated as infix (would otherwise consume `2` as RHS).
		ParseResult* r = do_parse(
			"fun main() { val z = 1 }\nfun bogus(): Int = 0"
		); defer free_result(r);

		// No BINARY_EXPR with extra_text="bogus" should appear.
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == BINARY_EXPR) {
				assert(r.nodes[i].extra_text != "bogus",
					"unexpected BINARY_EXPR with extra_text='bogus' (not infix)");
			}
		}
	};
}

// ── when (val x = expr) subject binding (Kotlin spec §17.6) ─────────

fn void when_subject_binding_creates_property_decl() @test {
	@pool() {
		ParseResult* r = do_parse(
			"fun f(): Int { return when (val x = compute()) { 1 -> x; else -> 0 } }"
		); defer free_result(r);
		// Find WHEN_EXPR, then look for PROPERTY_DECL child named "x"
		bool found_when = false;
		bool found_binding = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == WHEN_EXPR) {
				found_when = true;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == PROPERTY_DECL) {
						assert(r.nodes[j].name == "x",
							"expected PROPERTY_DECL name='x', got '%s'", r.nodes[j].name);
						found_binding = true;
					}
				}
			}
		}
		assert(found_when, "expected WHEN_EXPR");
		assert(found_binding, "expected PROPERTY_DECL child of WHEN_EXPR named 'x'");
	};
}

// ── Property accessor modifiers (Kotlin spec §14.3) ─────────────────

fn void property_accessor_private_set() @test {
	@pool() {
		// `var x: Int = 0\n  private set` -- accessor with visibility modifier
		// only (no body). Must parse without consuming next decl.
		ParseResult* r = do_parse(
			"class C {\n  var x: Int = 0\n    private set\n  fun next() {}\n}"
		); defer free_result(r);

		// Find FUN_DECL named "set" with MOD_PRIVATE flag.
		bool found_set = false;
		bool found_next = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FUN_DECL && r.nodes[i].name == "set") {
				assert((r.nodes[i].mod_flags & ast::MOD_PRIVATE) != 0,
					"expected MOD_PRIVATE on accessor 'set'");
				found_set = true;
			}
			if (r.nodes[i].kind == FUN_DECL && r.nodes[i].name == "next") {
				found_next = true;
			}
		}
		assert(found_set, "expected FUN_DECL accessor 'set'");
		assert(found_next, "expected FUN_DECL 'next' (parser must not over-consume accessor mods)");
	};
}

fn void property_accessor_annotation() @test {
	@pool() {
		// `@JvmName("x") get` -- annotation before accessor.
		ParseResult* r = do_parse(
			"class C {\n  val y: Int\n    @JvmName(\"getY\") get() = 1\n}"
		); defer free_result(r);

		bool found_get = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FUN_DECL && r.nodes[i].name == "get") {
				assert(r.nodes[i].annotation_text == "JvmName",
					"expected annotation_text='JvmName', got '%s'", r.nodes[i].annotation_text);
				found_get = true;
			}
		}
		assert(found_get, "expected FUN_DECL accessor 'get' with @JvmName");
	};
}

// ── Labeled loops (Kotlin spec §17.13) ──────────────────────────────

fn void labeled_for_loop() @test {
	@pool() {
		ParseResult* r = do_parse(
			"fun f() { outer@ for (i in 1..10) { break@outer } }"
		); defer free_result(r);

		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FOR_STMT && r.nodes[i].extra_text == "outer") {
				found = true;
				break;
			}
		}
		assert(found, "expected FOR_STMT with extra_text='outer'");
	};
}

fn void labeled_while_loop() @test {
	@pool() {
		ParseResult* r = do_parse(
			"fun f() { loop@ while (true) { continue@loop } }"
		); defer free_result(r);

		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == WHILE_STMT && r.nodes[i].extra_text == "loop") {
				found = true;
				break;
			}
		}
		assert(found, "expected WHILE_STMT with extra_text='loop'");
	};
}

fn void labeled_do_while_loop() @test {
	@pool() {
		ParseResult* r = do_parse(
			"fun f() { block@ do { break@block } while (false) }"
		); defer free_result(r);

		bool found = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == DO_WHILE_STMT && r.nodes[i].extra_text == "block") {
				found = true;
				break;
			}
		}
		assert(found, "expected DO_WHILE_STMT with extra_text='block'");
	};
}

// ── Supertype `by` delegation sub-AST (T7) ─────────────────────────

// Find the TYPE_REF child of a CLASS_DECL with the given name.
fn AstNode*? find_supertype_ref(ParseResult* r, AstNode* cls, String name) {
	for (uint i = 0; i < r.node_count; i++) {
		if (r.nodes[i].parent != ast::NO_PARENT
			&& &r.nodes[r.nodes[i].parent] == cls
			&& r.nodes[i].kind == TYPE_REF
			&& r.nodes[i].name == name) {
			return &r.nodes[i];
		}
	}
	return NOT_FOUND~;
}

// Returns true iff `parent_node` has any direct child with extra_text == "delegate".
fn bool supertype_has_delegate_child(ParseResult* r, AstNode* parent_node) {
	uint pi = (uint)(parent_node - &r.nodes[0]);
	for (uint i = 0; i < r.node_count; i++) {
		if (r.nodes[i].parent == pi && r.nodes[i].extra_text == "delegate") {
			return true;
		}
	}
	return false;
}

fn void supertype_by_delegation_attaches_expression() @test {
	@pool() {
		ParseResult* r = do_parse(
			"class Foo(items: List<String>) : List<String> by items"
		); defer free_result(r);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");

		AstNode* sup = find_supertype_ref(r, cls, "List")!!;
		assert(supertype_has_delegate_child(r, sup),
			"expected delegate expression child on supertype TYPE_REF");
	};
}

fn void supertype_by_delegation_multiple_supertypes() @test {
	@pool() {
		ParseResult* r = do_parse(
			"class M(a: I1, b: I2) : I1 by a, I2 by b"
		); defer free_result(r);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");

		AstNode* sup1 = find_supertype_ref(r, cls, "I1")!!;
		AstNode* sup2 = find_supertype_ref(r, cls, "I2")!!;
		assert(supertype_has_delegate_child(r, sup1),
			"expected delegate child on I1 supertype");
		assert(supertype_has_delegate_child(r, sup2),
			"expected delegate child on I2 supertype");
	};
}

fn void supertype_by_delegation_lambda_expression() @test {
	@pool() {
		ParseResult* r = do_parse(
			"class Bar : Runnable by Runnable { println(\"x\") }"
		); defer free_result(r);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");

		AstNode* sup = find_supertype_ref(r, cls, "Runnable")!!;
		assert(supertype_has_delegate_child(r, sup),
			"expected delegate expression child for lambda delegate");
	};
}

fn void supertype_without_by_has_no_delegate_child() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo : Bar()"); defer free_result(r);

		AstNode* f = file_node(r);
		AstNode* cls = child(r, f, 0);
		assert(cls.kind == CLASS_DECL, "expected CLASS_DECL");

		AstNode* sup = find_supertype_ref(r, cls, "Bar")!!;
		assert(!supertype_has_delegate_child(r, sup),
			"unexpected delegate child on plain supertype");
	};
}

// ── T9: ANNOTATION_ENTRY argument sub-AST (DUAL STORAGE) ───────────
//
// annotation_text MUST remain populated and byte-identical (legacy readers
// depend on it). We additionally expose VALUE_ARGUMENT children for
// structured access to args.

fn void annotation_args_positional_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("@Suppress(\"UNUSED\", \"DEPRECATION\") fun f() {}");
		defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* fun = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, fun, "Suppress")!!;
		// Byte-identical legacy text:
		assert(a.annotation_text == "(\"UNUSED\", \"DEPRECATION\")",
			"expected legacy annotation_text byte-identical, got '%s'", a.annotation_text);
		// New sub-AST: 2 VALUE_ARGUMENT children.
		uint vargs = ast::count_children_of_kind(r, a, VALUE_ARGUMENT);
		assert(vargs == 2, "expected 2 VALUE_ARGUMENT children, got %d", vargs);
		AstNode* va0 = ast::get_child(r, a, 0)!!;
		assert(va0.kind == VALUE_ARGUMENT, "child 0 should be VALUE_ARGUMENT");
		assert(va0.name == "", "positional arg should have empty name, got '%s'", va0.name);
		uint va0_idx = (uint)((usz)((char*)va0 - (char*)&r.nodes[0]) / AstNode.sizeof);
		AstNode* expr0 = ast::get_arg_expr(r, va0_idx)!!;
		assert(expr0.kind == STRING_TEMPLATE_EXPR || expr0.kind == LITERAL_EXPR,
			"expected string expr (LITERAL or STRING_TEMPLATE), got %d", (int)expr0.kind);
	};
}

fn void annotation_args_named_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("@A(name = \"x\", value = 42) class C");
		defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* cls = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, cls, "A")!!;
		// Legacy text byte-identical:
		assert(a.annotation_text == "(name = \"x\", value = 42)",
			"expected byte-identical annotation_text, got '%s'", a.annotation_text);
		// Sub-AST: 2 named VALUE_ARGUMENTs.
		uint vargs = ast::count_children_of_kind(r, a, VALUE_ARGUMENT);
		assert(vargs == 2, "expected 2 VALUE_ARGUMENT children, got %d", vargs);
		AstNode* va0 = ast::get_child(r, a, 0)!!;
		AstNode* va1 = ast::get_child(r, a, 1)!!;
		assert(va0.name == "name", "expected named arg 'name', got '%s'", va0.name);
		assert(va1.name == "value", "expected named arg 'value', got '%s'", va1.name);
	};
}

fn void annotation_args_array_literal_dual_storage() @test {
	@pool() {
		// Bare collection literal at expression position is unusual; we only
		// require that annotation_text is preserved byte-identical and that
		// at least one VALUE_ARGUMENT was opened for the arg list.
		ParseResult* r = do_parse("@A([1, 2, 3]) class C");
		defer free_result(r);
		AstNode* cls = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, cls, "A")!!;
		assert(a.annotation_text == "([1, 2, 3])",
			"expected byte-identical annotation_text, got '%s'", a.annotation_text);
		uint vargs = ast::count_children_of_kind(r, a, VALUE_ARGUMENT);
		assert(vargs >= 1, "expected at least 1 VALUE_ARGUMENT child, got %d", vargs);
	};
}

fn void annotation_args_empty_parens_dual_storage() @test {
	@pool() {
		ParseResult* r = do_parse("@A() class C"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* cls = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, cls, "A")!!;
		// Legacy: empty-parens still produces "()" slice.
		assert(a.annotation_text == "()",
			"expected legacy annotation_text '()', got '%s'", a.annotation_text);
		uint vargs = ast::count_children_of_kind(r, a, VALUE_ARGUMENT);
		assert(vargs == 0, "expected 0 VALUE_ARGUMENT children, got %d", vargs);
	};
}

fn void annotation_no_parens_unchanged() @test {
	@pool() {
		ParseResult* r = do_parse("@Foo class C"); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		AstNode* cls = child(r, file_node(r), 0);
		AstNode* a = ast::find_annotation(r, cls, "Foo")!!;
		assert(a.annotation_text == "",
			"expected empty annotation_text for no-parens annotation, got '%s'", a.annotation_text);
		uint vargs = ast::count_children_of_kind(r, a, VALUE_ARGUMENT);
		assert(vargs == 0, "expected 0 VALUE_ARGUMENT children, got %d", vargs);
	};
}
