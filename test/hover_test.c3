module kls::test::hover_test;

import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::token;

// ── position_to_offset ─────────────────────────────────────────────

fn void offset_first_char() @test {
	long off = hover::position_to_offset("fun main()", 0, 0);
	assert(off == 0, "expected 0, got %d", (int)off);
}

fn void offset_middle_of_first_line() @test {
	long off = hover::position_to_offset("fun main()", 0, 4);
	assert(off == 4, "expected 4, got %d", (int)off);
}

fn void offset_second_line() @test {
	long off = hover::position_to_offset("abc\ndef", 1, 0);
	assert(off == 4, "expected 4, got %d", (int)off);
}

fn void offset_second_line_col() @test {
	long off = hover::position_to_offset("abc\ndef", 1, 2);
	assert(off == 6, "expected 6, got %d", (int)off);
}

fn void offset_past_end_line() @test {
	// Per LSP spec: line past end clamps to end of content
	long off = hover::position_to_offset("abc", 5, 0);
	assert(off == 3, "expected 3 (clamped), got %d", (int)off);
}

fn void offset_past_end_col() @test {
	// Per LSP spec: char past line length clamps to line length
	long off = hover::position_to_offset("abc", 0, 100);
	assert(off == 3, "expected 3 (clamped), got %d", (int)off);
}

// ── find_token_at_position ─────────────────────────────────────────

fn void find_keyword_token() @test {
	@pool() {
		Token tok = hover::find_token_at_position("fun main()", 0, 0)!!;
		assert(tok.kind == KW_FUN, "expected KW_FUN");
	};
}

fn void find_keyword_middle() @test {
	@pool() {
		// Cursor at col 1 is inside "fun" (cols 0,1,2)
		Token tok = hover::find_token_at_position("fun main()", 0, 1)!!;
		assert(tok.kind == KW_FUN, "expected KW_FUN");
	};
}

fn void find_keyword_last_char() @test {
	@pool() {
		// Cursor at col 2 is the last char of "fun"
		Token tok = hover::find_token_at_position("fun main()", 0, 2)!!;
		assert(tok.kind == KW_FUN, "expected KW_FUN");
	};
}

fn void cursor_on_whitespace_returns_none() @test {
	@pool() {
		// Col 3 is the space between "fun" and "main"
		if (catch hover::find_token_at_position("fun main()", 0, 3)) {
			// Expected: no token on whitespace
			return;
		}
		assert(false, "expected no token on whitespace");
	};
}

fn void find_identifier() @test {
	@pool() {
		// "main" starts at col 4
		Token tok = hover::find_token_at_position("fun main()", 0, 4)!!;
		assert(tok.kind == IDENTIFIER, "expected IDENTIFIER");
		assert(tok.text == "main", "expected 'main', got '%s'", tok.text);
	};
}

fn void find_token_second_line() @test {
	@pool() {
		Token tok = hover::find_token_at_position("val x = 1\nfun y()", 1, 0)!!;
		assert(tok.kind == KW_FUN, "expected KW_FUN on second line");
	};
}

fn void find_operator() @test {
	@pool() {
		// "?:" starts at col 6
		Token tok = hover::find_token_at_position("x = a ?: b", 0, 6)!!;
		assert(tok.kind == ELVIS, "expected ELVIS, got %d", (int)tok.kind);
	};
}

fn void find_integer_literal() @test {
	@pool() {
		Token tok = hover::find_token_at_position("val x = 42", 0, 8)!!;
		assert(tok.kind == INTEGER_LITERAL, "expected INTEGER_LITERAL");
	};
}

fn void find_string_literal() @test {
	@pool() {
		// Cursor inside string content at col 9
		Token tok = hover::find_token_at_position(`val s = "hello"`, 0, 9)!!;
		assert(tok.kind == STRING_CONTENT, "expected STRING_CONTENT");
	};
}

fn void token_at_boundary_exclusive_end() @test {
	@pool() {
		// "fun" occupies cols 0..2. Col 3 is a space, no token.
		if (catch hover::find_token_at_position("fun main()", 0, 3)) {
			// Expected: no token at exclusive end boundary
			return;
		}
		assert(false, "expected no token at exclusive end boundary");
	};
}

// ── describe_token ─────────────────────────────────────────────────

fn void describe_hard_keyword() @test {
	@pool() {
		Token tok = { .kind = KW_FUN, .text = "fun" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("fun"), "description should mention 'fun'");
		assert(desc.contains("keyword"), "description should mention 'keyword'");
	};
}

fn void describe_soft_keyword() @test {
	@pool() {
		Token tok = { .kind = KW_DATA, .text = "data" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("data"), "description should mention 'data'");
		assert(desc.contains("data class"), "description should mention 'data class'");
	};
}

fn void describe_identifier() @test {
	@pool() {
		Token tok = { .kind = IDENTIFIER, .text = "myVar" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("myVar"), "description should contain identifier name");
	};
}

fn void describe_integer_literal() @test {
	@pool() {
		Token tok = { .kind = INTEGER_LITERAL, .text = "42" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("42"), "description should contain the value");
		assert(desc.contains("Int"), "description should mention type Int");
	};
}

fn void describe_long_literal() @test {
	@pool() {
		Token tok = { .kind = INTEGER_LITERAL, .text = "42L" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("Long"), "description should mention type Long");
	};
}

fn void describe_float_literal() @test {
	@pool() {
		Token tok = { .kind = FLOAT_LITERAL, .text = "3.14" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("Double"), "description should mention type Double");
	};
}

fn void describe_float_f_suffix() @test {
	@pool() {
		Token tok = { .kind = FLOAT_LITERAL, .text = "3.14f" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("Float"), "description should mention type Float");
	};
}

fn void describe_elvis_operator() @test {
	@pool() {
		Token tok = { .kind = ELVIS, .text = "?:" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("elvis"), "description should mention elvis");
	};
}

fn void describe_safe_call() @test {
	@pool() {
		Token tok = { .kind = SAFE_CALL, .text = "?." };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("safe call"), "description should mention safe call");
	};
}

fn void describe_not_null_assertion() @test {
	@pool() {
		Token tok = { .kind = NOT_NULL, .text = "!!" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("not-null"), "description should mention not-null");
	};
}

fn void describe_punctuation_returns_none() @test {
	@pool() {
		Token tok = { .kind = LPAREN, .text = "(" };
		if (catch hover::describe_token(tok)) {
			// Expected: no description for punctuation
			return;
		}
		assert(false, "expected no description for punctuation");
	};
}

fn void describe_comma_returns_none() @test {
	@pool() {
		Token tok = { .kind = COMMA, .text = "," };
		if (catch hover::describe_token(tok)) {
			// Expected: no description for comma
			return;
		}
		assert(false, "expected no description for comma");
	};
}

fn void describe_boolean_literal() @test {
	@pool() {
		Token tok = { .kind = BOOLEAN_LITERAL, .text = "true" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("Boolean"), "description should mention Boolean");
		assert(desc.contains("true"), "description should contain the value");
	};
}

fn void describe_null_literal() @test {
	@pool() {
		Token tok = { .kind = NULL_LITERAL, .text = "null" };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("null"), "description should mention null");
	};
}

fn void describe_string_literal() @test {
	@pool() {
		Token tok = { .kind = STRING_CONTENT, .text = `"hello"` };
		String desc = hover::describe_token(tok)!!;
		assert(desc.contains("String"), "description should mention String");
	};
}

// ── AST-based hover (via handle_hover) ────────────────────────────

fn Object* make_hover_params(String uri, int line, int character) {
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

fn void hover_function_shows_signature() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet(name: String): String {}");
		// Hover over "greet" at col 4
		Object* params = make_hover_params("file:///test.kt", 0, 4);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("fun greet"), "expected 'fun greet' in hover, got: '%s'", value);
		assert(value.contains("name: String"), "expected param 'name: String' in hover");
		assert(value.contains(": String"), "expected return type in hover");
	};
}

fn void hover_class_shows_signature() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "data class User(val name: String)");
		// Hover over "User" at col 11
		Object* params = make_hover_params("file:///test.kt", 0, 11);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("data"), "expected 'data' modifier in hover, got: '%s'", value);
		assert(value.contains("class User"), "expected 'class User' in hover");
	};
}

fn void hover_property_shows_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val count: Int = 0");
		// Hover over "count" at col 4
		Object* params = make_hover_params("file:///test.kt", 0, 4);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("val count"), "expected 'val count' in hover, got: '%s'", value);
		assert(value.contains(": Int"), "expected ': Int' in hover");
	};
}

// ── #13: var property shows 'var' not 'val' ────────────────────────

fn void hover_var_property_shows_var() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "var count: Int = 0");
		// Hover over "count" at col 4
		Object* params = make_hover_params("file:///test.kt", 0, 4);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result for var");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("var count"), "expected 'var count' in hover, got: '%s'", value);
		assert(!value.contains("val count"), "should not contain 'val count' for var property, got: '%s'", value);
		assert(value.contains(": Int"), "expected ': Int' in hover");
	};
}

fn void hover_val_property_shows_val() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val name: String = \"hello\"");
		// Hover over "name" at col 4
		Object* params = make_hover_params("file:///test.kt", 0, 4);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result for val");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("val name"), "expected 'val name' in hover, got: '%s'", value);
		assert(!value.contains("var name"), "should not contain 'var name' for val property, got: '%s'", value);
	};
}

// ── KDoc appears in hover for functions ────────────────────────────

fn void hover_shows_kdoc_for_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`/**`
			"\n"
			` * Greets a person by name.`
			"\n"
			` */`
			"\n"
			`fun greet(name: String) {}`
			"\n"
			`fun main() { greet("x") }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Hover over "greet" in the call on line 4
		// Line 4: "fun main() { greet("x") }"
		//          01234567890123456
		Object* params = make_hover_params("file:///test.kt", 4, 15);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("fun greet"), "expected signature in hover, got: '%s'", value);
		assert(value.contains("Greets a person"), "expected KDoc in hover, got: '%s'", value);
	};
}

// ── Line comments appear in hover ──────────────────────────────────

fn void hover_shows_line_comments_for_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`// A simple data container.`
			"\n"
			`class Box(val value: Int)`
			"\n"
			`fun main() { Box(1) }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Hover over "Box" in the call on line 2
		// Line 2: "fun main() { Box(1) }"
		Object* params = make_hover_params("file:///test.kt", 2, 15);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("class Box"), "expected class signature in hover, got: '%s'", value);
		assert(value.contains("simple data container"), "expected line comment in hover, got: '%s'", value);
	};
}

// ── No doc when no comment is present ──────────────────────────────

fn void hover_no_doc_without_comment() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet(name: String) {}\nfun main() { greet(\"\") }");

		Object* params = make_hover_params("file:///test.kt", 1, 15);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("fun greet"), "expected signature, got: '%s'", value);
		// Should not contain any doc text beyond the code block
		// The value should just be the code block
		assert(!value.contains("@param"), "should not have @param without KDoc, got: '%s'", value);
	};
}

// ── Dot-member hover (scope functions) ────────────────────────────

fn void hover_apply_shows_doc() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String source =
			"class Foo\n"
			"fun main() {\n"
			"    val f = Foo().apply { }\n"
			"}";

		store.open("file:///test.kt", "kotlin", 1, source);
		// Hover over "apply" at line 2, col 20
		Object* params = make_hover_params("file:///test.kt", 2, 20);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result for .apply");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("apply"),
			"expected 'apply' in hover, got: '%s'", value);
		assert(value.contains("T.() -> Unit"),
			"expected signature, got: '%s'", value);
		assert(value.contains("Calls block with this value as receiver"),
			"expected doc text, got: '%s'", value);
	};
}

fn void hover_let_shows_doc() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String source =
			"class Bar\n"
			"fun main() {\n"
			"    Bar().let { }\n"
			"}";

		store.open("file:///test.kt", "kotlin", 1, source);
		// Hover over "let" at line 2, col 10
		Object* params = make_hover_params("file:///test.kt", 2, 10);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result for .let");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("let"),
			"expected 'let' in hover, got: '%s'", value);
		assert(value.contains("Calls block with this value as argument"),
			"expected doc text, got: '%s'", value);
	};
}

// ── Hover for generic declarations ─────────────────────────────────

fn void hover_generic_class_shows_type_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Box<T>(val value: T)");
		// Hover over "Box" at col 6
		Object* params = make_hover_params("file:///test.kt", 0, 6);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("class Box<T>"), "expected 'class Box<T>' in hover, got: '%s'", value);
	};
}

fn void hover_generic_fun_shows_type_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun <T> identity(x: T): T = x");
		// Hover over "identity" at col 8
		Object* params = make_hover_params("file:///test.kt", 0, 8);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("<T>"), "expected '<T>' in hover, got: '%s'", value);
		assert(value.contains("fun"), "expected 'fun' in hover");
		assert(value.contains("identity"), "expected 'identity' in hover");
	};
}

fn void hover_generic_class_with_bound_and_variance() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Sorter<out T : Comparable<T>>()");
		// Hover over "Sorter" at col 6
		Object* params = make_hover_params("file:///test.kt", 0, 6);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("out T"), "expected 'out T' in hover, got: '%s'", value);
		assert(value.contains("Comparable<T>"), "expected bound 'Comparable<T>' in hover, got: '%s'", value);
	};
}

fn void hover_fun_with_where_clause() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun <T> sort(list: List<T>) where T : Comparable<T> {}");
		// Hover over "sort" at col 8
		Object* params = make_hover_params("file:///test.kt", 0, 8);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("where"), "expected 'where' clause in hover, got: '%s'", value);
		assert(value.contains("Comparable<T>"), "expected 'Comparable<T>' in where clause, got: '%s'", value);
	};
}

fn void hover_typealias_with_type_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "typealias StringMap<V> = Map<String, V>");
		// Hover over "StringMap" at col 10
		Object* params = make_hover_params("file:///test.kt", 0, 10);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("StringMap<V>"), "expected 'StringMap<V>' in hover, got: '%s'", value);
	};
}

// ── KDoc extraction through annotations ────────────────────────────

fn void hover_kdoc_through_annotation() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src = `/**
 * Builder for engine connectors
 */
@Suppress("unused")
class EngineConnectorBuilder {}`;
		store.open("file:///test.kt", "kotlin", 1, src);
		Object* params = make_hover_params("file:///test.kt", 4, 6);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("class EngineConnectorBuilder"), "expected class signature, got: '%s'", value);
		assert(value.contains("Builder for engine connectors"), "expected KDoc through annotation, got: '%s'", value);
	};
}

fn void hover_kdoc_through_modifiers_and_annotation() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// KDoc → annotation → modifier → class declaration
		String src_lines = "/**\n * Mutable implementation\n */\n@KtorDsl\npublic class EngineConnectorBuilder {}";
		store.open("file:///test.kt", "kotlin", 1, src_lines);
		// line 4: "public class EngineConnectorBuilder {}", col 13 = 'E'
		Object* params = make_hover_params("file:///test.kt", 4, 13);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("EngineConnectorBuilder"), "expected class name, got: '%s'", value);
		assert(value.contains("Mutable implementation"), "expected KDoc through annotation+modifier, got: '%s'", value);
	};
}

// ── Stdlib hover (println, listOf, etc.) ──────────────────────────

fn void hover_println_shows_stdlib_signature() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, `fun main() { println("hi") }`);
		// "println" at col 13 in "fun main() { println("hi") }"
		Object* params = make_hover_params("file:///test.kt", 0, 13);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("fun println"), "expected 'fun println' signature, got: '%s'", value);
		assert(value.contains("kotlin.io"), "expected 'kotlin.io' package, got: '%s'", value);
		assert(!value.contains("Identifier:"), "should not fall back to 'Identifier:', got: '%s'", value);
	};
}

fn void hover_listof_shows_stdlib_signature() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() { val x = listOf(1, 2) }");
		// "listOf" at col 21
		Object* params = make_hover_params("file:///test.kt", 0, 21);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("listOf"), "expected 'listOf' in signature, got: '%s'", value);
		assert(!value.contains("Identifier:"), "should not fall back to 'Identifier:', got: '%s'", value);
	};
}

fn void hover_local_shadows_stdlib() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Local fun println shadows stdlib — should show local signature
		store.open("file:///test.kt", "kotlin", 1, "fun println(x: Int): Boolean {}");
		// "println" at col 4
		Object* params = make_hover_params("file:///test.kt", 0, 4);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("Boolean"), "expected local return type 'Boolean', got: '%s'", value);
		assert(!value.contains("kotlin.io"), "should not show stdlib package for shadowed name, got: '%s'", value);
	};
}

fn void hover_dot_member_skips_top_level_stdlib() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// `foo.println` — member access, NOT top-level stdlib println.
		// Should not surface kotlin.io.println as the hover answer.
		store.open("file:///test.kt", "kotlin", 1, "fun main() { val foo = 1; foo.println }");
		// "println" at col 30 in "fun main() { val foo = 1; foo.println }"
		Object* params = make_hover_params("file:///test.kt", 0, 30);
		// Result may be a fault, null, or non-null but must NOT show top-level stdlib println
		if (try r = hover::handle_hover(&store, null, params)) {
			if (r != null) {
				Object* contents = r.get("contents")!!;
				String value = contents.get_string("value")!!;
				assert(!value.contains("kotlin.io"), "should not show top-level stdlib for dot member, got: '%s'", value);
			}
		}
	};
}

// ── @JvmStatic / Java-interop annotation display ───────────────────

fn void hover_jvmstatic_annotation_displayed() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src = `class Foo {
    companion object {
        @JvmStatic
        fun bar(): Int = 42
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, src);
		// Line 3: "        fun bar(): Int = 42", col 12 = 'b' of bar
		Object* params = make_hover_params("file:///test.kt", 3, 12);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("@JvmStatic"),
			"expected '@JvmStatic' in hover signature, got: '%s'", value);
		assert(value.contains("fun bar"),
			"expected 'fun bar' in hover signature, got: '%s'", value);
	};
}

fn void hover_no_annotation_no_jvmstatic_marker() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src = "class Foo {\n    fun bar(): Int = 42\n}";
		store.open("file:///test.kt", "kotlin", 1, src);
		// Line 1: "    fun bar(): Int = 42", col 8 = 'b'
		Object* params = make_hover_params("file:///test.kt", 1, 8);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(!value.contains("@JvmStatic"),
			"unannotated function should not show @JvmStatic, got: '%s'", value);
	};
}

fn void hover_jvmoverloads_annotation_displayed() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src = `class Foo {
    @JvmOverloads
    fun greet(name: String = "world"): String = "hi $name"
}`;
		store.open("file:///test.kt", "kotlin", 1, src);
		// Line 2: "    fun greet(name: String...", col 8 = 'g'
		Object* params = make_hover_params("file:///test.kt", 2, 8);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("@JvmOverloads"),
			"expected '@JvmOverloads' in hover signature, got: '%s'", value);
	};
}

// ── Operator-token hover (Phase 7 of operator-call ticket) ────────────

fn void hover_binary_plus_shows_operator_signature() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Vec(val x: Int) {\n    operator fun plus(other: Vec): Vec = Vec(x + other.x)\n}\nfun f() {\n    val a = Vec(1); val b = Vec(2); val c = a + b\n}";
		store.open("file:///op.kt", "kotlin", 1, content);

		// Cursor on `+` on line 4, col 46
		Object* params = make_hover_params("file:///op.kt", 4, 46);
		Object* result = hover::handle_hover(&store, null, params)!!;
		assert(result != null, "expected hover result for +");

		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("plus"), "expected 'plus' in hover, got: '%s'", value);
	};
}

fn void hover_index_bracket_shows_get_signature() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Box {\n    operator fun get(i: Int): Int = i\n}\nfun f() {\n    val b = Box(); val v = b[0]\n}";
		store.open("file:///idx.kt", "kotlin", 1, content);

		// `[` on line 4, col 28
		Object* params = make_hover_params("file:///idx.kt", 4, 28);
		Object* result = hover::handle_hover(&store, null, params)!!;
		assert(result != null, "expected hover result for [");

		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("get"), "expected 'get' in hover, got: '%s'", value);
	};
}

// Regression: overload arity helper used by hover to filter dep-method overloads.
fn void signature_param_count_zero_args() @test {
	assert(hover::signature_param_count("public static Response resume()") == 0,
		"empty parens => 0 params");
}

fn void signature_param_count_one_arg() @test {
	assert(hover::signature_param_count("public static Response resume(List<Record> records)") == 1,
		"one arg with generics => 1 param");
}

fn void signature_param_count_multi_arg_with_generics() @test {
	assert(hover::signature_param_count("public void put(Map<String, Integer> m, int n)") == 2,
		"two args with nested generics => 2 params");
}

fn void signature_param_count_no_parens() @test {
	assert(hover::signature_param_count("val foo: Int") == -1,
		"no parens => -1");
}
