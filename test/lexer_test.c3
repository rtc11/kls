module kls::kotlin::lexer_test;

import kls::kotlin::lexer;
import kls::kotlin::token;

// ── Helper ──────────────────────────────────────────────────────────
// Lex a source string and return the first token.
fn Token first(String src) {
	Lexer lex = lexer::init(src);
	return lex.next();
}

// Collect all non-EOF tokens into a temp-allocated slice.
fn Token[] all_tokens(String src) {
	Lexer lex = lexer::init(src);
	Token[256] buf;
	usz count = 0;
	while (count < 256) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		buf[count] = tok;
		count++;
	}
	Token[] result = mem::talloc_array(Token, count);
	for (usz i = 0; i < count; i++) {
		result[i] = buf[i];
	}
	return result;
}

// ── Empty / EOF ─────────────────────────────────────────────────────

fn void empty_input() @test {
	Token tok = first("");
	assert(tok.kind == EOF, "expected EOF, got %d", (int)tok.kind);
}

fn void whitespace_only() @test {
	Token tok = first("   \t  ");
	assert(tok.kind == EOF, "expected EOF after whitespace");
}

fn void newlines_only() @test {
	Token tok = first("\n\n\n");
	assert(tok.kind == EOF, "expected EOF after newlines");
}

// ── Hard Keywords ───────────────────────────────────────────────────

fn void keyword_fun() @test {
	Token tok = first("fun");
	assert(tok.kind == KW_FUN, "expected KW_FUN");
	assert(tok.text == "fun", "expected text 'fun', got '%s'", tok.text);
}

fn void keyword_class() @test {
	Token tok = first("class");
	assert(tok.kind == KW_CLASS);
	assert(tok.text == "class");
}

fn void keyword_val() @test {
	Token tok = first("val");
	assert(tok.kind == KW_VAL);
}

fn void keyword_var() @test {
	Token tok = first("var");
	assert(tok.kind == KW_VAR);
}

fn void keyword_if() @test {
	Token tok = first("if");
	assert(tok.kind == KW_IF);
}

fn void keyword_else() @test {
	Token tok = first("else");
	assert(tok.kind == KW_ELSE);
}

fn void keyword_when() @test {
	Token tok = first("when");
	assert(tok.kind == KW_WHEN);
}

fn void keyword_return() @test {
	Token tok = first("return");
	assert(tok.kind == KW_RETURN);
}

fn void keyword_interface() @test {
	Token tok = first("interface");
	assert(tok.kind == KW_INTERFACE);
}

fn void keyword_object() @test {
	Token tok = first("object");
	assert(tok.kind == KW_OBJECT);
}

fn void keyword_package() @test {
	Token tok = first("package");
	assert(tok.kind == KW_PACKAGE);
}

fn void keyword_import() @test {
	Token tok = first("import");
	assert(tok.kind == KW_IMPORT);
}

fn void keyword_for() @test {
	Token tok = first("for");
	assert(tok.kind == KW_FOR);
}

fn void keyword_while() @test {
	Token tok = first("while");
	assert(tok.kind == KW_WHILE);
}

fn void keyword_do() @test {
	Token tok = first("do");
	assert(tok.kind == KW_DO);
}

fn void keyword_try() @test {
	Token tok = first("try");
	assert(tok.kind == KW_TRY);
}

fn void keyword_catch() @test {
	Token tok = first("catch");
	assert(tok.kind == KW_CATCH);
}

fn void keyword_throw() @test {
	Token tok = first("throw");
	assert(tok.kind == KW_THROW);
}

fn void keyword_is() @test {
	Token tok = first("is");
	assert(tok.kind == KW_IS);
}

fn void keyword_as() @test {
	Token tok = first("as");
	assert(tok.kind == KW_AS);
}

fn void keyword_in() @test {
	Token tok = first("in");
	assert(tok.kind == KW_IN);
}

fn void keyword_null() @test {
	Token tok = first("null");
	assert(tok.kind == NULL_LITERAL);
}

fn void keyword_true() @test {
	Token tok = first("true");
	assert(tok.kind == BOOLEAN_LITERAL);
	assert(tok.text == "true");
}

fn void keyword_false() @test {
	Token tok = first("false");
	assert(tok.kind == BOOLEAN_LITERAL);
	assert(tok.text == "false");
}

// ── Soft Keywords ───────────────────────────────────────────────────

fn void soft_keyword_data() @test {
	Token tok = first("data");
	assert(tok.kind == KW_DATA);
}

fn void soft_keyword_sealed() @test {
	Token tok = first("sealed");
	assert(tok.kind == KW_SEALED);
}

fn void soft_keyword_suspend() @test {
	Token tok = first("suspend");
	assert(tok.kind == KW_SUSPEND);
}

fn void soft_keyword_override() @test {
	Token tok = first("override");
	assert(tok.kind == KW_OVERRIDE);
}

fn void soft_keyword_inline() @test {
	Token tok = first("inline");
	assert(tok.kind == KW_INLINE);
}

fn void soft_keyword_private() @test {
	Token tok = first("private");
	assert(tok.kind == KW_PRIVATE);
}

fn void soft_keyword_public() @test {
	Token tok = first("public");
	assert(tok.kind == KW_PUBLIC);
}

fn void soft_keyword_const() @test {
	Token tok = first("const");
	assert(tok.kind == KW_CONST);
}

// ── Identifiers ─────────────────────────────────────────────────────

fn void simple_identifier() @test {
	Token tok = first("myVar");
	assert(tok.kind == IDENTIFIER, "expected IDENTIFIER, got %d", (int)tok.kind);
	assert(tok.text == "myVar", "expected 'myVar', got '%s'", tok.text);
}

fn void underscore_identifier() @test {
	Token tok = first("_private");
	assert(tok.kind == IDENTIFIER);
	assert(tok.text == "_private");
}

fn void identifier_with_digits() @test {
	Token tok = first("x123");
	assert(tok.kind == IDENTIFIER);
	assert(tok.text == "x123");
}

fn void single_char_identifier() @test {
	Token tok = first("x");
	assert(tok.kind == IDENTIFIER);
	assert(tok.text == "x");
}

fn void identifier_not_keyword_prefix() @test {
	// "funky" is not keyword "fun"
	Token tok = first("funky");
	assert(tok.kind == IDENTIFIER, "expected IDENTIFIER for 'funky', got %d", (int)tok.kind);
	assert(tok.text == "funky");
}

fn void identifier_not_keyword_prefix_val() @test {
	// "value" is soft keyword KW_VALUE
	Token tok = first("values");
	assert(tok.kind == IDENTIFIER, "expected IDENTIFIER for 'values'");
	assert(tok.text == "values");
}

// ── Integer Literals ────────────────────────────────────────────────

fn void decimal_integer() @test {
	Token tok = first("42");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "42");
}

fn void hex_integer() @test {
	Token tok = first("0xFF");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "0xFF");
}

fn void binary_integer() @test {
	Token tok = first("0b1010");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "0b1010");
}

fn void integer_with_underscores() @test {
	Token tok = first("1_000_000");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "1_000_000");
}

fn void long_suffix() @test {
	Token tok = first("42L");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "42L");
}

fn void unsigned_suffix() @test {
	Token tok = first("42u");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "42u");
}

fn void unsigned_long_suffix() @test {
	Token tok = first("42uL");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "42uL");
}

fn void zero() @test {
	Token tok = first("0");
	assert(tok.kind == INTEGER_LITERAL);
	assert(tok.text == "0");
}

// ── Float Literals ──────────────────────────────────────────────────

fn void simple_float() @test {
	Token tok = first("3.14");
	assert(tok.kind == FLOAT_LITERAL, "expected FLOAT_LITERAL, got %d", (int)tok.kind);
	assert(tok.text == "3.14");
}

fn void float_with_f_suffix() @test {
	Token tok = first("3.14f");
	assert(tok.kind == FLOAT_LITERAL);
	assert(tok.text == "3.14f");
}

fn void scientific_notation() @test {
	Token tok = first("1e10");
	assert(tok.kind == FLOAT_LITERAL);
	assert(tok.text == "1e10");
}

fn void scientific_negative_exp() @test {
	Token tok = first("1.5e-3");
	assert(tok.kind == FLOAT_LITERAL);
	assert(tok.text == "1.5e-3");
}

fn void scientific_with_f_suffix() @test {
	Token tok = first("1.5e-3f");
	assert(tok.kind == FLOAT_LITERAL);
	assert(tok.text == "1.5e-3f");
}

// ── String Literals ─────────────────────────────────────────────────

fn void simple_string() @test {
	Token[] toks = all_tokens(`"hello"`);
	assert(toks.len == 3, "expected 3 tokens (open, content, close), got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[1].text == "hello");
	assert(toks[2].kind == STRING_CLOSE);
}

fn void empty_string() @test {
	Token tok = first(`""`);
	assert(tok.kind == STRING_CONTENT);
	assert(tok.text == `""`);
}

fn void string_with_escape() @test {
	Token[] toks = all_tokens(`"hello\nworld"`);
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[2].kind == STRING_CLOSE);
}

fn void triple_quoted_string() @test {
	Token[] toks = all_tokens(`"""hello"""`);
	assert(toks.len == 3, "expected 3 tokens (open, content, close), got %d", (int)toks.len);
	assert(toks[0].kind == MULTILINE_STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[1].text == "hello");
	assert(toks[2].kind == MULTILINE_STRING_CLOSE);
}

fn void triple_quoted_multiline() @test {
	String src = `"""line1
line2
line3"""`;
	Token[] toks = all_tokens(src);
	assert(toks.len >= 2, "expected at least 2 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == MULTILINE_STRING_OPEN);
}

// ── Character Literals ──────────────────────────────────────────────

fn void simple_char() @test {
	Token tok = first("'a'");
	assert(tok.kind == CHARACTER_LITERAL);
	assert(tok.text == "'a'");
}

fn void escaped_char() @test {
	Token tok = first(`'\n'`);
	assert(tok.kind == CHARACTER_LITERAL);
	assert(tok.text == `'\n'`);
}

// ── Operators ───────────────────────────────────────────────────────

fn void dot() @test {
	Token tok = first(".");
	assert(tok.kind == DOT, "expected DOT, got %d", (int)tok.kind);
}

fn void comma() @test {
	Token tok = first(",");
	assert(tok.kind == COMMA);
}

fn void lparen() @test {
	Token tok = first("(");
	assert(tok.kind == LPAREN);
}

fn void rparen() @test {
	Token tok = first(")");
	assert(tok.kind == RPAREN);
}

fn void lsquare() @test {
	Token tok = first("[");
	assert(tok.kind == LSQUARE);
}

fn void rsquare() @test {
	Token tok = first("]");
	assert(tok.kind == RSQUARE);
}

fn void lcurl() @test {
	Token tok = first("{");
	assert(tok.kind == LCURL);
}

fn void rcurl() @test {
	Token tok = first("}");
	assert(tok.kind == RCURL);
}

fn void colon() @test {
	Token tok = first(":");
	assert(tok.kind == COLON);
}

fn void semicolon() @test {
	Token tok = first(";");
	assert(tok.kind == SEMICOLON);
}

fn void assignment() @test {
	Token tok = first("=");
	assert(tok.kind == ASSIGNMENT);
}

fn void arrow() @test {
	Token tok = first("->");
	assert(tok.kind == ARROW);
}

fn void double_arrow() @test {
	Token tok = first("=>");
	assert(tok.kind == DOUBLE_ARROW);
}

fn void range_op() @test {
	Token tok = first("..");
	assert(tok.kind == RANGE);
}

fn void coloncolon() @test {
	Token tok = first("::");
	assert(tok.kind == COLONCOLON);
}

fn void at() @test {
	Token tok = first("@");
	assert(tok.kind == AT);
}

fn void quest() @test {
	Token tok = first("?");
	assert(tok.kind == QUEST);
}

fn void safe_call() @test {
	Token tok = first("?.");
	assert(tok.kind == SAFE_CALL);
}

fn void elvis() @test {
	Token tok = first("?:");
	assert(tok.kind == ELVIS);
}

fn void not_null() @test {
	Token tok = first("!!");
	assert(tok.kind == NOT_NULL);
}

fn void excl() @test {
	Token tok = first("! ");
	assert(tok.kind == EXCL);
}

fn void add() @test {
	Token tok = first("+ ");
	assert(tok.kind == ADD);
}

fn void sub() @test {
	Token tok = first("- ");
	assert(tok.kind == SUB);
}

fn void mult() @test {
	Token tok = first("* ");
	assert(tok.kind == MULT);
}

fn void div() @test {
	Token tok = first("% ");
	assert(tok.kind == MOD);
}

fn void incr() @test {
	Token tok = first("++");
	assert(tok.kind == INCR);
}

fn void decr() @test {
	Token tok = first("--");
	assert(tok.kind == DECR);
}

fn void add_assign() @test {
	Token tok = first("+=");
	assert(tok.kind == ADD_ASSIGN);
}

fn void sub_assign() @test {
	Token tok = first("-=");
	assert(tok.kind == SUB_ASSIGN);
}

fn void mult_assign() @test {
	Token tok = first("*=");
	assert(tok.kind == MULT_ASSIGN);
}

fn void div_assign() @test {
	Token tok = first("/=");
	assert(tok.kind == DIV_ASSIGN);
}

fn void mod_assign() @test {
	Token tok = first("%=");
	assert(tok.kind == MOD_ASSIGN);
}

fn void conj() @test {
	Token tok = first("&&");
	assert(tok.kind == CONJ);
}

fn void disj() @test {
	Token tok = first("||");
	assert(tok.kind == DISJ);
}

fn void eqeq() @test {
	Token tok = first("==");
	assert(tok.kind == EQEQ);
}

fn void eqeqeq() @test {
	Token tok = first("===");
	assert(tok.kind == EQEQEQ);
}

fn void excl_eq() @test {
	Token tok = first("!=");
	assert(tok.kind == EXCL_EQ);
}

fn void excl_eqeq() @test {
	Token tok = first("!==");
	assert(tok.kind == EXCL_EQEQ);
}

fn void langle() @test {
	Token tok = first("<");
	assert(tok.kind == LANGLE);
}

fn void rangle() @test {
	Token tok = first(">");
	assert(tok.kind == RANGLE);
}

fn void le() @test {
	Token tok = first("<=");
	assert(tok.kind == LE);
}

fn void ge() @test {
	Token tok = first(">=");
	assert(tok.kind == GE);
}

// ── Comments ────────────────────────────────────────────────────────

fn void line_comment_skipped() @test {
	Token tok = first("// this is a comment\nfun");
	assert(tok.kind == KW_FUN, "expected KW_FUN after line comment, got %d", (int)tok.kind);
}

fn void block_comment_skipped() @test {
	Token tok = first("/* comment */ fun");
	assert(tok.kind == KW_FUN, "expected KW_FUN after block comment");
}

fn void nested_block_comment_skipped() @test {
	Token tok = first("/* outer /* inner */ still outer */ fun");
	assert(tok.kind == KW_FUN, "expected KW_FUN after nested block comment");
}

fn void comment_only() @test {
	Token tok = first("// nothing else");
	assert(tok.kind == EOF);
}

// ── Position Tracking ───────────────────────────────────────────────

fn void first_token_position() @test {
	Token tok = first("fun");
	assert(tok.line == 0, "expected line 0, got %d", tok.line);
	assert(tok.col == 0, "expected col 0, got %d", tok.col);
	assert(tok.offset == 0);
}

fn void token_after_space() @test {
	Token tok = first("   fun");
	assert(tok.col == 3, "expected col 3, got %d", tok.col);
}

fn void token_on_second_line() @test {
	Token tok = first("\nfun");
	assert(tok.line == 1, "expected line 1, got %d", tok.line);
	assert(tok.col == 0, "expected col 0 on second line, got %d", tok.col);
}

fn void token_on_third_line() @test {
	Token tok = first("\n\nfun");
	assert(tok.line == 2, "expected line 2, got %d", tok.line);
}

fn void second_token_position() @test {
	Token[] toks = all_tokens("fun main");
	assert(toks.len == 2, "expected 2 tokens, got %d", (int)toks.len);
	assert(toks[1].col == 4, "expected col 4 for 'main', got %d", toks[1].col);
}

// ── Token Sequences ─────────────────────────────────────────────────

fn void fun_declaration() @test {
	Token[] toks = all_tokens("fun main()");
	assert(toks.len == 4, "expected 4 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == KW_FUN);
	assert(toks[1].kind == IDENTIFIER);
	assert(toks[1].text == "main");
	assert(toks[2].kind == LPAREN);
	assert(toks[3].kind == RPAREN);
}

fn void val_declaration() @test {
	Token[] toks = all_tokens("val x = 42");
	assert(toks.len == 4, "expected 4 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == KW_VAL);
	assert(toks[1].kind == IDENTIFIER);
	assert(toks[1].text == "x");
	assert(toks[2].kind == ASSIGNMENT);
	assert(toks[3].kind == INTEGER_LITERAL);
	assert(toks[3].text == "42");
}

fn void class_declaration() @test {
	Token[] toks = all_tokens("data class Point(val x: Int, val y: Int)");
	assert(toks.len >= 12, "expected >= 12 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == KW_DATA);
	assert(toks[1].kind == KW_CLASS);
	assert(toks[2].kind == IDENTIFIER);
	assert(toks[2].text == "Point");
	assert(toks[3].kind == LPAREN);
}

fn void nullable_safe_call_chain() @test {
	Token[] toks = all_tokens("x?.y?.z");
	assert(toks.len == 5, "expected 5 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == IDENTIFIER);
	assert(toks[0].text == "x");
	assert(toks[1].kind == SAFE_CALL);
	assert(toks[2].kind == IDENTIFIER);
	assert(toks[2].text == "y");
	assert(toks[3].kind == SAFE_CALL);
	assert(toks[4].kind == IDENTIFIER);
	assert(toks[4].text == "z");
}

fn void elvis_expression() @test {
	Token[] toks = all_tokens("x ?: 0");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == IDENTIFIER);
	assert(toks[1].kind == ELVIS);
	assert(toks[2].kind == INTEGER_LITERAL);
}

fn void not_null_assertion() @test {
	Token[] toks = all_tokens("x!!");
	assert(toks.len == 2, "expected 2 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == IDENTIFIER);
	assert(toks[1].kind == NOT_NULL);
}

fn void when_expression() @test {
	Token[] toks = all_tokens("when (x) { 1 -> true }");
	assert(toks.len >= 8, "expected >= 8 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == KW_WHEN);
	assert(toks[1].kind == LPAREN);
}

fn void package_and_import() @test {
	Token[] toks = all_tokens("package com.example\nimport kotlin.io");
	assert(toks.len >= 6, "expected >= 6 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == KW_PACKAGE);
	assert(toks[1].kind == IDENTIFIER);
	assert(toks[1].text == "com");
	assert(toks[2].kind == DOT);
}

fn void lambda_syntax() @test {
	Token[] toks = all_tokens("{ x -> x + 1 }");
	assert(toks.len == 7, "expected 7 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == LCURL);
	assert(toks[1].kind == IDENTIFIER);
	assert(toks[2].kind == ARROW);
	assert(toks[3].kind == IDENTIFIER);
	assert(toks[4].kind == ADD);
	assert(toks[5].kind == INTEGER_LITERAL);
	assert(toks[6].kind == RCURL);
}

fn void range_expression() @test {
	Token[] toks = all_tokens("1..10");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == INTEGER_LITERAL);
	assert(toks[1].kind == RANGE);
	assert(toks[2].kind == INTEGER_LITERAL);
}

// ── String Template Lexing ──────────────────────────────────────────

fn void string_template_simple_ref() @test {
	// "hello $name"
	Token[] toks = all_tokens(`"hello $name"`);
	assert(toks.len == 4, "expected 4 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[1].text == "hello ");
	assert(toks[2].kind == STRING_TEMPLATE_REF);
	assert(toks[2].text == "$name");
	assert(toks[3].kind == STRING_CLOSE);
}

fn void string_template_expr() @test {
	// "result: ${x + 1}"
	Token[] toks = all_tokens(`"result: ${x + 1}"`);
	assert(toks.len >= 7, "expected >= 7 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[1].text == "result: ");
	assert(toks[2].kind == STRING_TEMPLATE_START);
	assert(toks[2].text == "${");
	// tokens 3..N-3 are the expression: x, +, 1
	// Last two: RCURL, STRING_CLOSE
	usz last = toks.len - 1;
	assert(toks[last].kind == STRING_CLOSE);
	assert(toks[last - 1].kind == RCURL);
}

fn void string_template_nested_string() @test {
	// "hello ${foo("bar")}" -- nested string inside template expression
	Token[] toks = all_tokens(`"hello ${foo("bar")}"`);
	// STRING_OPEN, STRING_CONTENT("hello "), STRING_TEMPLATE_START("${"),
	// IDENTIFIER(foo), LPAREN, STRING_CONTENT("bar" - empty string), RPAREN,
	// RCURL, STRING_CLOSE
	assert(toks.len >= 7, "expected >= 7 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[2].kind == STRING_TEMPLATE_START);
	// Find the closing tokens
	usz last = toks.len - 1;
	assert(toks[last].kind == STRING_CLOSE, "expected STRING_CLOSE at end, got %d", (int)toks[last].kind);
}

fn void string_template_function_call() @test {
	// "value: ${colorize("text", Color.yellow)}"
	Token[] toks = all_tokens(`"value: ${colorize("text", Color.yellow)}"`);
	assert(toks.len >= 8, "expected >= 8 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[1].text == "value: ");
	assert(toks[2].kind == STRING_TEMPLATE_START);
	// Last tokens: RCURL, STRING_CLOSE
	usz last = toks.len - 1;
	assert(toks[last].kind == STRING_CLOSE, "expected STRING_CLOSE at end, got %d", (int)toks[last].kind);
	assert(toks[last - 1].kind == RCURL, "expected RCURL before close, got %d", (int)toks[last - 1].kind);
}

fn void string_template_ref_at_start() @test {
	// "$x is great"
	Token[] toks = all_tokens(`"$x is great"`);
	assert(toks.len >= 3, "expected >= 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_TEMPLATE_REF);
	assert(toks[1].text == "$x");
	assert(toks[2].kind == STRING_CONTENT);
	usz last = toks.len - 1;
	assert(toks[last].kind == STRING_CLOSE);
}

fn void string_template_ref_at_end() @test {
	// "value: $x"
	Token[] toks = all_tokens(`"value: $x"`);
	assert(toks.len == 4, "expected 4 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[2].kind == STRING_TEMPLATE_REF);
	assert(toks[3].kind == STRING_CLOSE);
}

fn void string_only_template_ref() @test {
	// "$x"
	Token[] toks = all_tokens(`"$x"`);
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_TEMPLATE_REF);
	assert(toks[2].kind == STRING_CLOSE);
}

fn void multiline_string_template() @test {
	// """hello $name"""
	String src = `"""hello $name"""`;
	Token[] toks = all_tokens(src);
	assert(toks.len >= 3, "expected >= 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == MULTILINE_STRING_OPEN);
	// Find template ref
	bool found_ref = false;
	for (usz i = 0; i < toks.len; i++) {
		if (toks[i].kind == STRING_TEMPLATE_REF) found_ref = true;
	}
	assert(found_ref, "expected STRING_TEMPLATE_REF in multiline string");
	assert(toks[toks.len - 1].kind == MULTILINE_STRING_CLOSE);
}

fn void as_safe_token() @test {
	Token[] toks = all_tokens("x as? String");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == IDENTIFIER);
	assert(toks[1].kind == AS_SAFE);
	assert(toks[1].text == "as?");
	assert(toks[2].kind == IDENTIFIER);
}

fn void as_not_safe_without_question() @test {
	Token[] toks = all_tokens("x as String");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[1].kind == KW_AS);
	assert(toks[1].text == "as");
}

// ── #5: !is and !in compound tokens ───────────────────────────────

fn void not_is_token() @test {
	Token[] toks = all_tokens("x !is String");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == IDENTIFIER);
	assert(toks[1].kind == NOT_IS, "expected NOT_IS, got %d", (int)toks[1].kind);
	assert(toks[1].text == "!is");
	assert(toks[2].kind == IDENTIFIER);
}

fn void not_in_token() @test {
	Token[] toks = all_tokens("x !in list");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == IDENTIFIER);
	assert(toks[1].kind == NOT_IN, "expected NOT_IN, got %d", (int)toks[1].kind);
	assert(toks[1].text == "!in");
	assert(toks[2].kind == IDENTIFIER);
}

fn void not_is_not_prefix_of_identifier() @test {
	// "!island" should NOT be tokenized as NOT_IS + "land"
	Token[] toks = all_tokens("!island");
	assert(toks.len == 2, "expected 2 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == EXCL, "expected EXCL, got %d", (int)toks[0].kind);
	assert(toks[1].kind == IDENTIFIER);
	assert(toks[1].text == "island");
}

fn void not_in_not_prefix_of_identifier() @test {
	// "!index" should NOT be tokenized as NOT_IN + "dex"
	Token[] toks = all_tokens("!index");
	assert(toks.len == 2, "expected 2 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == EXCL, "expected EXCL, got %d", (int)toks[0].kind);
	assert(toks[1].kind == IDENTIFIER);
	assert(toks[1].text == "index");
}
