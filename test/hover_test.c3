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
	long off = hover::position_to_offset("abc", 5, 0);
	assert(off == -1, "expected -1 for line past end");
}

fn void offset_past_end_col() @test {
	long off = hover::position_to_offset("abc", 0, 100);
	assert(off == -1, "expected -1 for col past end");
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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

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
		Object* result = hover::handle_hover(&store, null, params);

		assert(result != null, "expected hover result");
		Object* contents = result.get("contents")!!;
		String value = contents.get_string("value")!!;
		assert(value.contains("fun greet"), "expected signature, got: '%s'", value);
		// Should not contain any doc text beyond the code block
		// The value should just be the code block
		assert(!value.contains("@param"), "should not have @param without KDoc, got: '%s'", value);
	};
}
