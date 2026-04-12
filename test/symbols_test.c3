module kls::test::symbols_test;

import kls::kotlin::symbols;

// ── Simple declarations ────────────────────────────────────────────

fn void scan_simple_function() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("fun foo() {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "foo", "expected 'foo', got '%s'", buf[0].name);
	};
}

fn void scan_simple_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("class MyClass {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "MyClass", "expected 'MyClass', got '%s'", buf[0].name);
	};
}

fn void scan_simple_interface() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("interface Drawable {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.INTERFACE, "expected INTERFACE");
		assert(buf[0].name == "Drawable", "expected 'Drawable', got '%s'", buf[0].name);
	};
}

fn void scan_simple_object() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("object Singleton {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.OBJECT, "expected OBJECT");
		assert(buf[0].name == "Singleton", "expected 'Singleton', got '%s'", buf[0].name);
	};
}

fn void scan_val_property() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("val x = 42", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.PROPERTY, "expected PROPERTY");
		assert(buf[0].name == "x", "expected 'x', got '%s'", buf[0].name);
	};
}

fn void scan_var_property() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("var count = 0", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.PROPERTY, "expected PROPERTY");
		assert(buf[0].name == "count", "expected 'count', got '%s'", buf[0].name);
	};
}

fn void scan_typealias() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("typealias StringList = List<String>", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.TYPEALIAS, "expected TYPEALIAS");
		assert(buf[0].name == "StringList", "expected 'StringList', got '%s'", buf[0].name);
	};
}

// ── Modifier keywords before declarations ──────────────────────────

fn void scan_data_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("data class User(val name: String)", &buf);
		// data class produces CLASS "User" + PROPERTY "name"
		assert(count >= 1, "expected at least 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "User", "expected 'User', got '%s'", buf[0].name);
	};
}

fn void scan_enum_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("enum class Color { RED, GREEN, BLUE }", &buf);
		assert(count >= 1, "expected at least 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "Color", "expected 'Color', got '%s'", buf[0].name);
	};
}

fn void scan_sealed_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("sealed class Result {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "Result", "expected 'Result', got '%s'", buf[0].name);
	};
}

fn void scan_sealed_interface() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("sealed interface Event {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.INTERFACE, "expected INTERFACE");
		assert(buf[0].name == "Event", "expected 'Event', got '%s'", buf[0].name);
	};
}

fn void scan_annotation_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("annotation class MyAnnotation", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "MyAnnotation", "expected 'MyAnnotation', got '%s'", buf[0].name);
	};
}

fn void scan_private_fun() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("private fun helper() {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "helper", "expected 'helper', got '%s'", buf[0].name);
	};
}

fn void scan_open_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("open class Base {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "Base", "expected 'Base', got '%s'", buf[0].name);
	};
}

fn void scan_abstract_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("abstract class Shape {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "Shape", "expected 'Shape', got '%s'", buf[0].name);
	};
}

fn void scan_suspend_fun() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("suspend fun fetchData() {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "fetchData", "expected 'fetchData', got '%s'", buf[0].name);
	};
}

fn void scan_inline_fun() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("inline fun <reified T> create(): T {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "create", "expected 'create', got '%s'", buf[0].name);
	};
}

fn void scan_const_val() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("const val MAX = 100", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.PROPERTY, "expected PROPERTY");
		assert(buf[0].name == "MAX", "expected 'MAX', got '%s'", buf[0].name);
	};
}

fn void scan_lateinit_var() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("lateinit var adapter: Adapter", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.PROPERTY, "expected PROPERTY");
		assert(buf[0].name == "adapter", "expected 'adapter', got '%s'", buf[0].name);
	};
}

// ── Extension functions/properties ─────────────────────────────────

fn void scan_extension_function() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("fun String.greet() {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "greet", "expected 'greet', got '%s'", buf[0].name);
	};
}

fn void scan_extension_property() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("val String.wordCount: Int get() = split(\" \").size", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.PROPERTY, "expected PROPERTY");
		assert(buf[0].name == "wordCount", "expected 'wordCount', got '%s'", buf[0].name);
	};
}

// ── Generic functions ──────────────────────────────────────────────

fn void scan_generic_function() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("fun <T> convert(value: T): String {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "convert", "expected 'convert', got '%s'", buf[0].name);
	};
}

fn void scan_generic_extension_function() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("fun <T> List<T>.first(): T {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "first", "expected 'first', got '%s'", buf[0].name);
	};
}

// ── Companion object ───────────────────────────────────────────────

fn void scan_named_companion_object() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("companion object Factory {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.OBJECT, "expected OBJECT");
		assert(buf[0].name == "Factory", "expected 'Factory', got '%s'", buf[0].name);
	};
}

fn void scan_anonymous_companion_object() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("companion object {}", &buf);
		// Anonymous companion object produces no symbol
		assert(count == 0, "expected 0 symbols for anonymous companion object, got %d", (int)count);
	};
}

// ── Multiple declarations ──────────────────────────────────────────

fn void scan_multiple_declarations() @test {
	@pool() {
		String content =
			`class Foo {
    val x = 1
    var y = 2
    fun bar() {}
    fun baz() {}
}

interface Quux {}
object Singleton {}`;
		Symbol[16] buf;
		usz count = symbols::scan_declarations(content, &buf);
		// Foo, x, y, bar, baz, Quux, Singleton = 7
		assert(count == 7, "expected 7 symbols, got %d", (int)count);

		assert(buf[0].name == "Foo", "expected 'Foo', got '%s'", buf[0].name);
		assert(buf[0].kind == SymbolKind.CLASS);
		assert(buf[1].name == "x", "expected 'x', got '%s'", buf[1].name);
		assert(buf[1].kind == SymbolKind.PROPERTY);
		assert(buf[2].name == "y", "expected 'y', got '%s'", buf[2].name);
		assert(buf[2].kind == SymbolKind.PROPERTY);
		assert(buf[3].name == "bar", "expected 'bar', got '%s'", buf[3].name);
		assert(buf[3].kind == SymbolKind.FUNCTION);
		assert(buf[4].name == "baz", "expected 'baz', got '%s'", buf[4].name);
		assert(buf[4].kind == SymbolKind.FUNCTION);
		assert(buf[5].name == "Quux", "expected 'Quux', got '%s'", buf[5].name);
		assert(buf[5].kind == SymbolKind.INTERFACE);
		assert(buf[6].name == "Singleton", "expected 'Singleton', got '%s'", buf[6].name);
		assert(buf[6].kind == SymbolKind.OBJECT);
	};
}

// ── Position tracking ──────────────────────────────────────────────

fn void scan_position_tracking() @test {
	@pool() {
		// "fun foo()" -- "foo" starts at col 4, line 0
		Symbol[16] buf;
		usz count = symbols::scan_declarations("fun foo()", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].line == 0, "expected line 0, got %d", (int)buf[0].line);
		assert(buf[0].col == 4, "expected col 4, got %d", (int)buf[0].col);
		assert(buf[0].len == 3, "expected len 3, got %d", (int)buf[0].len);
	};
}

fn void scan_position_second_line() @test {
	@pool() {
		// Line 0: "val x = 1\n", Line 1: "fun bar()"
		// "bar" is at line 1, col 4
		Symbol[16] buf;
		usz count = symbols::scan_declarations("val x = 1\nfun bar()", &buf);
		assert(count == 2, "expected 2 symbols, got %d", (int)count);
		assert(buf[1].name == "bar");
		assert(buf[1].line == 1, "expected line 1, got %d", (int)buf[1].line);
		assert(buf[1].col == 4, "expected col 4, got %d", (int)buf[1].col);
	};
}

// ── Edge cases ─────────────────────────────────────────────────────

fn void scan_empty_content() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("", &buf);
		assert(count == 0, "expected 0 symbols for empty content, got %d", (int)count);
	};
}

fn void scan_no_declarations() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("1 + 2 * 3", &buf);
		assert(count == 0, "expected 0 symbols, got %d", (int)count);
	};
}

fn void scan_buffer_limit() @test {
	@pool() {
		// Buffer can only hold 2, but there are 3 declarations
		Symbol[2] buf;
		usz count = symbols::scan_declarations("val a = 1\nval b = 2\nval c = 3", &buf);
		assert(count == 2, "expected 2 symbols (buffer limit), got %d", (int)count);
		assert(buf[0].name == "a");
		assert(buf[1].name == "b");
	};
}

fn void scan_destructuring_skipped() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("val (a, b) = pair", &buf);
		// Destructuring is skipped
		assert(count == 0, "expected 0 symbols for destructuring, got %d", (int)count);
	};
}

fn void scan_multiple_modifiers() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("public open class Widget {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "Widget", "expected 'Widget', got '%s'", buf[0].name);
	};
}

fn void scan_override_fun() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("override fun toString(): String {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.FUNCTION, "expected FUNCTION");
		assert(buf[0].name == "toString", "expected 'toString', got '%s'", buf[0].name);
	};
}

fn void scan_inner_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("inner class ViewHolder {}", &buf);
		assert(count == 1, "expected 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "ViewHolder", "expected 'ViewHolder', got '%s'", buf[0].name);
	};
}

fn void scan_value_class() @test {
	@pool() {
		Symbol[16] buf;
		usz count = symbols::scan_declarations("value class Password(val s: String)", &buf);
		assert(count >= 1, "expected at least 1 symbol, got %d", (int)count);
		assert(buf[0].kind == SymbolKind.CLASS, "expected CLASS");
		assert(buf[0].name == "Password", "expected 'Password', got '%s'", buf[0].name);
	};
}
