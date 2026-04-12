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
