module kls::kotlin::lexer_next_all_test;

import kls::kotlin::lexer;
import kls::kotlin::token;

// ── Helper ──────────────────────────────────────────────────────────
// Lex using next_all and return the first token.
fn Token first_all(String src) {
	Lexer lex = lexer::init(src);
	return lex.next_all();
}

// Collect all non-EOF tokens using next_all into a temp-allocated slice.
fn Token[] all_tokens(String src) {
	Lexer lex = lexer::init(src);
	Token[256] buf;
	usz count = 0;
	while (count < 256) {
		Token tok = lex.next_all();
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

// ── Whitespace tokens ──────────────────────────────────────────────

fn void whitespace_emitted() @test {
	Token tok = first_all("  fun");
	assert(tok.kind == WHITESPACE, "expected WHITESPACE, got %d", (int)tok.kind);
	assert(tok.len == 2, "expected len 2, got %d", tok.len);
}

fn void tab_whitespace() @test {
	Token tok = first_all("\tfun");
	assert(tok.kind == WHITESPACE, "expected WHITESPACE for tab, got %d", (int)tok.kind);
	assert(tok.len == 1);
}

fn void mixed_whitespace() @test {
	Token tok = first_all(" \t fun");
	assert(tok.kind == WHITESPACE);
	assert(tok.len == 3, "expected len 3, got %d", tok.len);
}

// ── Newline tokens ─────────────────────────────────────────────────

fn void newline_emitted() @test {
	Token tok = first_all("\nfun");
	assert(tok.kind == NEWLINE, "expected NEWLINE, got %d", (int)tok.kind);
	assert(tok.len == 1);
	assert(tok.line == 0, "expected line 0, got %d", tok.line);
	assert(tok.col == 0);
}

fn void newline_then_keyword() @test {
	Token[] toks = all_tokens("\nfun");
	assert(toks.len == 2, "expected 2 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == NEWLINE);
	assert(toks[1].kind == KW_FUN);
	assert(toks[1].line == 1, "expected fun on line 1, got %d", toks[1].line);
	assert(toks[1].col == 0);
}

// ── Line comment tokens ────────────────────────────────────────────

fn void line_comment_emitted() @test {
	Token tok = first_all("// hello");
	assert(tok.kind == LINE_COMMENT, "expected LINE_COMMENT, got %d", (int)tok.kind);
	assert(tok.text == "// hello", "expected '// hello', got '%s'", tok.text);
}

fn void line_comment_then_newline_then_keyword() @test {
	Token[] toks = all_tokens("// comment\nfun");
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == LINE_COMMENT);
	assert(toks[0].text == "// comment");
	assert(toks[1].kind == NEWLINE);
	assert(toks[2].kind == KW_FUN);
	assert(toks[2].line == 1);
}

fn void line_comment_position() @test {
	Token[] toks = all_tokens("val x // comment");
	// val, ws, x, ws, // comment
	assert(toks.len == 5, "expected 5 tokens, got %d", (int)toks.len);
	assert(toks[4].kind == LINE_COMMENT);
	assert(toks[4].col == 6, "expected col 6, got %d", toks[4].col);
}

// ── Block comment tokens ───────────────────────────────────────────

fn void block_comment_emitted() @test {
	Token tok = first_all("/* comment */");
	assert(tok.kind == BLOCK_COMMENT, "expected BLOCK_COMMENT, got %d", (int)tok.kind);
	assert(tok.text == "/* comment */");
}

fn void block_comment_then_keyword() @test {
	Token[] toks = all_tokens("/* x */ fun");
	// block_comment, ws, fun
	assert(toks.len == 3, "expected 3 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == BLOCK_COMMENT);
	assert(toks[1].kind == WHITESPACE);
	assert(toks[2].kind == KW_FUN);
}

fn void nested_block_comment_emitted() @test {
	Token tok = first_all("/* outer /* inner */ end */");
	assert(tok.kind == BLOCK_COMMENT, "expected BLOCK_COMMENT for nested, got %d", (int)tok.kind);
	assert(tok.text == "/* outer /* inner */ end */");
}

fn void multiline_block_comment() @test {
	String src = "/* line1\nline2 */";
	Token tok = first_all(src);
	assert(tok.kind == BLOCK_COMMENT);
	assert(tok.text == src);
}

// ── Normal tokens still work ───────────────────────────────────────

fn void keyword_still_works() @test {
	Token tok = first_all("fun");
	assert(tok.kind == KW_FUN, "expected KW_FUN, got %d", (int)tok.kind);
}

fn void identifier_still_works() @test {
	Token tok = first_all("myVar");
	assert(tok.kind == IDENTIFIER);
	assert(tok.text == "myVar");
}

fn void integer_still_works() @test {
	Token tok = first_all("42");
	assert(tok.kind == INTEGER_LITERAL);
}

fn void string_still_works() @test {
	Token[] toks = all_tokens(`"hello"`);
	assert(toks.len == 3, "expected 3 tokens (open, content, close), got %d", (int)toks.len);
	assert(toks[0].kind == STRING_OPEN);
	assert(toks[1].kind == STRING_CONTENT);
	assert(toks[1].text == "hello");
	assert(toks[2].kind == STRING_CLOSE);
}

fn void operator_still_works() @test {
	Token tok = first_all("+");
	assert(tok.kind == ADD);
}

fn void empty_input_eof() @test {
	Token tok = first_all("");
	assert(tok.kind == EOF);
}

// ── Full sequence with all token types ─────────────────────────────

fn void full_sequence() @test {
	// "// hi\nval x = 42"
	Token[] toks = all_tokens("// hi\nval x = 42");
	// Expected: LINE_COMMENT("// hi"), NEWLINE, KW_VAL, WS, IDENTIFIER(x), WS, ASSIGNMENT, WS, INTEGER_LITERAL(42)
	assert(toks.len == 9, "expected 9 tokens, got %d", (int)toks.len);
	assert(toks[0].kind == LINE_COMMENT);
	assert(toks[1].kind == NEWLINE);
	assert(toks[2].kind == KW_VAL);
	assert(toks[3].kind == WHITESPACE);
	assert(toks[4].kind == IDENTIFIER);
	assert(toks[4].text == "x");
	assert(toks[5].kind == WHITESPACE);
	assert(toks[6].kind == ASSIGNMENT);
	assert(toks[7].kind == WHITESPACE);
	assert(toks[8].kind == INTEGER_LITERAL);
	assert(toks[8].text == "42");
}
