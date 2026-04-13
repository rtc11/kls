module kls::test::semantic_tokens_test;

import std::collections::object;
import kls::document;
import kls::lsp::semantic_tokens;

// ── Helpers ────────────────────────────────────────────────────────

fn Object* make_params(String uri) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	return params;
}

/**
 * Extract the data array from a SemanticTokens result and return
 * it as an int slice for easier assertion. Each token is 5 ints.
 */
fn int[] get_data(Object* result) {
	Object* data = result.get("data")!!;
	usz len = data.get_len();
	int[] arr = mem::talloc_array(int, len);
	for (usz i = 0; i < len; i++) {
		arr[i] = data.get_int_at((sz)i)!!;
	}
	return arr;
}

// ── Empty document ─────────────────────────────────────────────────

fn void empty_document_returns_empty_data() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null, "expected result, not null");
		int[] data = get_data(result);
		assert(data.len == 0, "expected empty data, got %d ints", (int)data.len);
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void unknown_document_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Single keyword ─────────────────────────────────────────────────

fn void single_keyword_encoding() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// 1 token * 5 ints = 5
		assert(data.len == 5, "expected 5 ints, got %d", (int)data.len);
		// deltaLine=0, deltaStart=0, length=3, tokenType=0(keyword), tokenModifiers=0
		assert(data[0] == 0, "deltaLine should be 0, got %d", data[0]);
		assert(data[1] == 0, "deltaStart should be 0, got %d", data[1]);
		assert(data[2] == 3, "length should be 3, got %d", data[2]);
		assert(data[3] == semantic_tokens::TT_KEYWORD, "tokenType should be keyword(%d), got %d", semantic_tokens::TT_KEYWORD, data[3]);
		assert(data[4] == 0, "tokenModifiers should be 0, got %d", data[4]);
	};
}

// ── Two tokens same line (relative deltaStart) ────────────────────

fn void two_tokens_same_line() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "val x" -> KW_VAL at col 0, IDENTIFIER at col 4
		store.open("file:///test.kt", "kotlin", 1, "val x");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// 2 tokens * 5 = 10 ints
		assert(data.len == 10, "expected 10 ints, got %d", (int)data.len);

		// Token 1: val (keyword) at line 0, col 0
		assert(data[0] == 0, "t1 deltaLine");
		assert(data[1] == 0, "t1 deltaStart");
		assert(data[2] == 3, "t1 length");
		assert(data[3] == semantic_tokens::TT_KEYWORD, "t1 type");

		// Token 2: x (property declaration name) at line 0, col 4
		// deltaLine=0, deltaStart=4-0=4 (relative to previous token start col 0)
		assert(data[5] == 0, "t2 deltaLine, got %d", data[5]);
		assert(data[6] == 4, "t2 deltaStart, got %d", data[6]);
		assert(data[7] == 1, "t2 length");
		assert(data[8] == semantic_tokens::TT_PROPERTY, "t2 type, got %d", data[8]);
	};
}

// ── Tokens on different lines ──────────────────────────────────────

fn void tokens_different_lines() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "val\nfun" -> KW_VAL at (0,0), KW_FUN at (1,0)
		store.open("file:///test.kt", "kotlin", 1, "val\nfun");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 10, "expected 10 ints, got %d", (int)data.len);

		// Token 1: val at (0,0)
		assert(data[0] == 0);
		assert(data[1] == 0);

		// Token 2: fun at (1,0)
		// deltaLine=1, deltaStart=0 (absolute col since different line)
		assert(data[5] == 1, "t2 deltaLine, got %d", data[5]);
		assert(data[6] == 0, "t2 deltaStart, got %d", data[6]);
	};
}

// ── Modifier token type ────────────────────────────────────────────

fn void modifier_keyword_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "abstract");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5);
		assert(data[3] == semantic_tokens::TT_MODIFIER, "expected modifier type, got %d", data[3]);
	};
}

// ── String token type ──────────────────────────────────────────────

fn void string_token_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, `"hello"`);

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5, "expected 5 ints, got %d", (int)data.len);
		assert(data[3] == semantic_tokens::TT_STRING, "expected string type, got %d", data[3]);
	};
}

// ── Number token type ──────────────────────────────────────────────

fn void number_token_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "42");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5);
		assert(data[3] == semantic_tokens::TT_NUMBER, "expected number type, got %d", data[3]);
	};
}

// ── Operator token type ────────────────────────────────────────────

fn void operator_token_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "+" is an operator
		store.open("file:///test.kt", "kotlin", 1, "+");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5);
		assert(data[3] == semantic_tokens::TT_OPERATOR, "expected operator type, got %d", data[3]);
	};
}

// ── Property keyword type ──────────────────────────────────────────

fn void property_keyword_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "get");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5);
		assert(data[3] == semantic_tokens::TT_PROPERTY, "expected property type, got %d", data[3]);
	};
}

// ── Comment token type ─────────────────────────────────────────────

fn void line_comment_token_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "// hello");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5, "expected 5 ints, got %d", (int)data.len);
		assert(data[3] == semantic_tokens::TT_COMMENT, "expected comment type, got %d", data[3]);
		assert(data[2] == 8, "expected length 8 for '// hello', got %d", data[2]);
	};
}

fn void block_comment_token_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "/* block */");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 5, "expected 5 ints, got %d", (int)data.len);
		assert(data[3] == semantic_tokens::TT_COMMENT, "expected comment type, got %d", data[3]);
	};
}

// ── Multi-line mixed content ───────────────────────────────────────

fn void multiline_mixed() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Line 0: "// comment"     -> 1 token: comment at (0,0) len=10
		// Line 1: "val x = 42"     -> 4 tokens: val(1,0), x(1,4), =(1,6), 42(1,8)
		store.open("file:///test.kt", "kotlin", 1, "// comment\nval x = 42");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// 5 tokens * 5 ints = 25
		assert(data.len == 25, "expected 25 ints, got %d", (int)data.len);

		// Token 0: comment at (0,0)
		assert(data[0] == 0, "t0 deltaLine");
		assert(data[1] == 0, "t0 deltaStart");
		assert(data[2] == 10, "t0 length: '// comment' = 10, got %d", data[2]);
		assert(data[3] == semantic_tokens::TT_COMMENT, "t0 type");

		// Token 1: val at (1,0) -> deltaLine=1, deltaStart=0 (abs col)
		assert(data[5] == 1, "t1 deltaLine, got %d", data[5]);
		assert(data[6] == 0, "t1 deltaStart, got %d", data[6]);
		assert(data[7] == 3, "t1 length");
		assert(data[8] == semantic_tokens::TT_KEYWORD, "t1 type");

		// Token 2: x (property declaration name) at (1,4) -> deltaLine=0, deltaStart=4-0=4 (relative)
		assert(data[10] == 0, "t2 deltaLine");
		assert(data[11] == 4, "t2 deltaStart, got %d", data[11]);
		assert(data[12] == 1, "t2 length");
		assert(data[13] == semantic_tokens::TT_PROPERTY, "t2 type, got %d", data[13]);

		// Token 3: = at (1,6) -> deltaLine=0, deltaStart=6-4=2
		assert(data[15] == 0, "t3 deltaLine");
		assert(data[16] == 2, "t3 deltaStart, got %d", data[16]);
		assert(data[17] == 1, "t3 length");
		assert(data[18] == semantic_tokens::TT_OPERATOR, "t3 type");

		// Token 4: 42 at (1,8) -> deltaLine=0, deltaStart=8-6=2
		assert(data[20] == 0, "t4 deltaLine");
		assert(data[21] == 2, "t4 deltaStart, got %d", data[21]);
		assert(data[22] == 2, "t4 length");
		assert(data[23] == semantic_tokens::TT_NUMBER, "t4 type");
	};
}

// ── Whitespace-only document ───────────────────────────────────────

fn void whitespace_only_empty_data() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "   \n\t\n  ");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		assert(data.len == 0, "expected empty data for whitespace-only, got %d", (int)data.len);
	};
}

// ── Capability options structure ───────────────────────────────────

fn void capability_options_has_legend() @test {
	@pool() {
		Object* opts = semantic_tokens::build_semantic_tokens_options();

		assert(opts != null);

		// Check legend exists
		Object* legend = opts.get("legend")!!;
		Object* types = legend.get("tokenTypes")!!;
		Object* modifiers = legend.get("tokenModifiers")!!;

		// Should have TOKEN_TYPE_COUNT types
		assert(types.get_len() == semantic_tokens::TOKEN_TYPE_COUNT,
			"expected %d token types, got %d",
			(int)semantic_tokens::TOKEN_TYPE_COUNT, (int)types.get_len());

		// First type should be "keyword"
		String first_type = types.get_string_at(0)!!;
		assert(first_type == "keyword", "expected 'keyword', got '%s'", first_type);

		// Modifiers should be empty
		assert(modifiers.get_len() == 0, "expected 0 modifiers, got %d", (int)modifiers.get_len());

		// full should be true
		bool full = opts.get_bool("full")!!;
		assert(full, "expected full=true");
	};
}

// ── Real Kotlin snippet ────────────────────────────────────────────

fn void real_kotlin_snippet() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`fun main() {
    println("Hello")
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// Should have multiple tokens and data length is a multiple of 5
		assert(data.len > 0, "expected non-empty data");
		assert(data.len % 5 == 0, "data length should be multiple of 5, got %d", (int)data.len);

		// First token: "fun" keyword at (0,0)
		assert(data[0] == 0, "first deltaLine");
		assert(data[1] == 0, "first deltaStart");
		assert(data[2] == 3, "first length (fun)");
		assert(data[3] == semantic_tokens::TT_KEYWORD, "first type");
	};
}

// ── AST-based identifier classification ────────────────────────────

fn void function_name_classified() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// Tokens: fun(kw), greet(fn), (, ), {, }
		// Find the token for "greet" (second token, index 5..9)
		assert(data.len >= 10, "expected at least 2 tokens");
		assert(data[7] == 5, "greet length, got %d", data[7]); // "greet" = 5 chars
		assert(data[8] == semantic_tokens::TT_FUNCTION, "greet should be TT_FUNCTION, got %d", data[8]);
	};
}

fn void class_name_classified() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "class Foo {}");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// Tokens: class(kw), Foo(cls), {, }
		assert(data.len >= 10, "expected at least 2 tokens");
		assert(data[7] == 3, "Foo length, got %d", data[7]); // "Foo" = 3 chars
		assert(data[8] == semantic_tokens::TT_CLASS, "Foo should be TT_CLASS, got %d", data[8]);
	};
}

fn void enum_entry_classified() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "enum class Color { RED }");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// Find RED token: it should be TT_ENUM_MEMBER
		// Tokens: enum(mod), class(kw), Color(cls), {, RED(enum_member), }
		// RED is token 4 (0-indexed), at position data[20..24]
		assert(data.len >= 25, "expected at least 5 tokens, got len=%d", (int)data.len);
		assert(data[22] == 3, "RED length, got %d", data[22]); // "RED" = 3 chars
		assert(data[23] == semantic_tokens::TT_ENUM_MEMBER, "RED should be TT_ENUM_MEMBER, got %d", data[23]);
	};
}

fn void parameter_classified() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun add(a: Int) {}");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);

		assert(result != null);
		int[] data = get_data(result);
		// Tokens: fun(kw), add(fn), (, a(param), :, Int(var), ), {, }
		// 'a' is token 3 (0-indexed), at data[15..19]
		assert(data.len >= 20, "expected at least 4 tokens, got len=%d", (int)data.len);
		assert(data[17] == 1, "a length, got %d", data[17]); // "a" = 1 char
		assert(data[18] == semantic_tokens::TT_PARAMETER, "a should be TT_PARAMETER, got %d", data[18]);
	};
}

// ── Expression-level identifier classification ─────────────────────

fn void call_expr_classified_as_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "println" in the body is a CALL_EXPR and should be classified as TT_FUNCTION
		store.open("file:///test.kt", "kotlin", 1, "fun main() {\n    println(42)\n}");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);
		assert(result != null);
		int[] data = get_data(result);

		// Find "println" token: should be TT_FUNCTION (not TT_VARIABLE)
		// Tokens on line 1: println, (, 42, )
		// We need to find the token with length=7 on line 1
		bool found = false;
		for (usz i = 0; i + 4 < data.len; i += 5) {
			if (data[i + 2] == 7) { // length == 7 ("println")
				assert(data[i + 3] == semantic_tokens::TT_FUNCTION,
					"println should be TT_FUNCTION, got %d", data[i + 3]);
				found = true;
				break;
			}
		}
		assert(found, "expected to find 'println' token");
	};
}

fn void member_access_classified_as_property() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "length" in "name.length" should be classified as TT_PROPERTY
		store.open("file:///test.kt", "kotlin", 1, "fun foo() {\n    name.length\n}");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);
		assert(result != null);
		int[] data = get_data(result);

		// Find "length" token: should be TT_PROPERTY (length=6)
		bool found = false;
		for (usz i = 0; i + 4 < data.len; i += 5) {
			if (data[i + 2] == 6) { // length == 6 ("length")
				assert(data[i + 3] == semantic_tokens::TT_PROPERTY,
					"'length' should be TT_PROPERTY, got %d", data[i + 3]);
				found = true;
				break;
			}
		}
		assert(found, "expected to find 'length' token");
	};
}

fn void member_call_classified_as_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "toString" in "x.toString()" should be TT_FUNCTION (it's a CALL_EXPR)
		store.open("file:///test.kt", "kotlin", 1, "fun foo() {\n    x.toString()\n}");

		Object* params = make_params("file:///test.kt");
		Object* result = semantic_tokens::handle_semantic_tokens_full(&store, params);
		assert(result != null);
		int[] data = get_data(result);

		// Find "toString" token: length=8, should be TT_FUNCTION
		bool found = false;
		for (usz i = 0; i + 4 < data.len; i += 5) {
			if (data[i + 2] == 8) { // length == 8 ("toString")
				assert(data[i + 3] == semantic_tokens::TT_FUNCTION,
					"'toString' should be TT_FUNCTION, got %d", data[i + 3]);
				found = true;
				break;
			}
		}
		assert(found, "expected to find 'toString' token");
	};
}
