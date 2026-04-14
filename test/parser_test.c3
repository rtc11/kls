module kls::test::parser_test;

import kls::kotlin::parser;
import kls::kotlin::ast;

// ── Helper ──────────────────────────────────────────────────────────

// Heap-allocate a ParseResult (too large for stack) and parse into it.
fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	mem::free(r);
}

// Get the FILE node (always index 0)
fn AstNode* file_node(ParseResult* r) {
	return &r.nodes[0];
}

// Get Nth child of a node (uses parent-pointer traversal)
fn AstNode* child(ParseResult* r, AstNode* parent, usz n) {
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
		for (usz i = 0; i < fun.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < outer.child_count; i++) {
			AstNode* ch = ast::get_child(r, outer, i)!!;
			if (ch.kind == CLASS_DECL && ch.name == "Inner") {
				found_inner = true;
				// Inner should have a method
				bool found_method = false;
				for (usz j = 0; j < ch.child_count; j++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
	for (usz i = 0; i < fun_node.child_count; i++) {
		AstNode* ch = ast::get_child(r, fun_node, i)!!;
		if (ch.kind == BLOCK) return ch;
	}
	unreachable("expected BLOCK child in FUN_DECL");
}

// Find the first child of a given kind
fn AstNode* find_kind(ParseResult* r, AstNode* parent, NodeKind kind) {
	for (usz i = 0; i < parent.child_count; i++) {
		AstNode* ch = ast::get_child(r, parent, i)!!;
		if (ch.kind == kind) return ch;
	}
	unreachable("expected child of kind %d", (int)kind);
}

// Count children of a given kind
fn usz count_kind(ParseResult* r, AstNode* parent, NodeKind kind) {
	usz count = 0;
	for (usz i = 0; i < parent.child_count; i++) {
		AstNode* ch = ast::get_child(r, parent, i)!!;
		if (ch.kind == kind) count++;
	}
	return count;
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
	for (usz i = 0; i < block.child_count; i++) {
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
		for (usz i = 0; i < cls.child_count; i++) {
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
		for (usz i = 0; i < iface.child_count; i++) {
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
