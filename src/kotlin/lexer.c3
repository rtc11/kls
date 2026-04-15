module kls::kotlin::lexer;

import kls::kotlin::token;
import std::io;

const int MAX_STRING_DEPTH = 8;  // max nesting of string templates

struct Lexer {
	String source;
	usz pos;
	uint line;
	uint col;
	// String template state: a stack of contexts for nested strings.
	// in_string[depth-1] == true means we're inside a string literal.
	// brace_depth[depth-1] tracks `{` nesting inside `${ ... }`.
	// is_multiline[depth-1] tracks triple-quoted vs regular string.
	bool[MAX_STRING_DEPTH] in_string;
	int[MAX_STRING_DEPTH] brace_depth;
	bool[MAX_STRING_DEPTH] is_multiline;
	int string_depth;            // current nesting level (0 = not in string)
}

fn Lexer init(String source) {
	return {
		.source = source,
		.pos = 0,
		.line = 0,
		.col = 0,
	};
}

fn Token Lexer.next(Lexer* self) {
	// If we're inside a string template expression (${ ... }),
	// lex normally but track brace nesting.
	if (self.string_depth > 0 && self.brace_depth[self.string_depth - 1] > 0) {
		self.skip_whitespace_and_comments();
		if (self.pos >= self.source.len) {
			return self.make_token(EOF, self.pos, 0);
		}
		char c = self.peek();
		// Track braces inside template expressions
		if (c == '{') {
			self.brace_depth[self.string_depth - 1]++;
			usz start = self.pos;
			uint sl = self.line; uint sc = self.col;
			self.advance();
			return self.make_token_at(LCURL, start, sl, sc);
		}
		if (c == '}') {
			self.brace_depth[self.string_depth - 1]--;
			if (self.brace_depth[self.string_depth - 1] == 0) {
				// Closing the template expression: emit RCURL and resume string
				usz start = self.pos;
				uint sl = self.line; uint sc = self.col;
				self.advance();
				return self.make_token_at(RCURL, start, sl, sc);
			}
			usz start = self.pos;
			uint sl = self.line; uint sc = self.col;
			self.advance();
			return self.make_token_at(RCURL, start, sl, sc);
		}
		// Inside a template expression, lex the next normal token.
		// Strings can be nested inside template expressions.
		return self.lex_normal_token();
	}

	// If we're inside a string literal (not in a template expression),
	// continue lexing string content.
	if (self.string_depth > 0) {
		return self.lex_string_content();
	}

	// Normal lexing
	self.skip_whitespace_and_comments();
	if (self.pos >= self.source.len) {
		return self.make_token(EOF, self.pos, 0);
	}
	return self.lex_normal_token();
}

/**
 * Lex the next normal (non-string-content) token.
 */
fn Token Lexer.lex_normal_token(Lexer* self) {
	if (self.pos >= self.source.len) {
		return self.make_token(EOF, self.pos, 0);
	}

	usz start = self.pos;
	uint start_line = self.line;
	uint start_col = self.col;
	char c = self.peek();

	// Backtick-quoted identifiers: `fun`, `my test`, etc.
	if (c == '`') {
		return self.lex_backtick_identifier(start, start_line, start_col);
	}

	// Identifiers and keywords
	if (is_ident_start(c)) {
		return self.lex_identifier(start, start_line, start_col);
	}

	// Numeric literals
	if (is_digit(c)) {
		return self.lex_number(start, start_line, start_col);
	}

	// String literals
	if (c == '"') {
		return self.lex_string(start, start_line, start_col);
	}

	// Character literals
	if (c == '\'') {
		return self.lex_char(start, start_line, start_col);
	}

	// Operators and punctuation
	return self.lex_operator(start, start_line, start_col);
}

/**
 * Like next(), but emits WHITESPACE, NEWLINE, LINE_COMMENT, and
 * BLOCK_COMMENT tokens instead of skipping them. Useful for semantic
 * tokens where every visible token must be reported.
 */
fn Token Lexer.next_all(Lexer* self) {
	// If we're inside a string template expression (${ ... }),
	// lex normally (with whitespace tokens) but track brace nesting.
	if (self.string_depth > 0 && self.brace_depth[self.string_depth - 1] > 0) {
		if (self.pos >= self.source.len) {
			return self.make_token(EOF, self.pos, 0);
		}
		char c = self.peek();
		usz start = self.pos;
		uint start_line = self.line;
		uint start_col = self.col;

		// Whitespace
		if (c == ' ' || c == '\t' || c == '\r') {
			while (self.pos < self.source.len) {
				char ch = self.peek();
				if (ch == ' ' || ch == '\t' || ch == '\r') {
					self.advance();
				} else {
					break;
				}
			}
			return self.make_token_at(WHITESPACE, start, start_line, start_col);
		}

		// Newline
		if (c == '\n') {
			self.advance();
			self.line++;
			self.col = 0;
			return self.make_token_at(NEWLINE, start, start_line, start_col);
		}

		// Line comment
		if (c == '/' && self.peek_at(1) == '/') {
			while (self.pos < self.source.len && self.peek() != '\n') {
				self.advance();
			}
			return self.make_token_at(LINE_COMMENT, start, start_line, start_col);
		}

		// Block comment (nestable)
		if (c == '/' && self.peek_at(1) == '*') {
			self.skip_block_comment();
			return self.make_token_at(BLOCK_COMMENT, start, start_line, start_col);
		}

		// Track braces inside template expressions
		if (c == '{') {
			self.brace_depth[self.string_depth - 1]++;
			self.advance();
			return self.make_token_at(LCURL, start, start_line, start_col);
		}
		if (c == '}') {
			self.brace_depth[self.string_depth - 1]--;
			self.advance();
			return self.make_token_at(RCURL, start, start_line, start_col);
		}

		// Normal token inside template expression
		return self.lex_normal_token();
	}

	// If we're inside a string literal (not in a template expression),
	// continue lexing string content.
	if (self.string_depth > 0) {
		return self.lex_string_content();
	}

	// Normal lexing with all whitespace/comments
	if (self.pos >= self.source.len) {
		return self.make_token(EOF, self.pos, 0);
	}

	usz start = self.pos;
	uint start_line = self.line;
	uint start_col = self.col;
	char c = self.peek();

	// Whitespace (spaces, tabs, carriage returns)
	if (c == ' ' || c == '\t' || c == '\r') {
		while (self.pos < self.source.len) {
			char ch = self.peek();
			if (ch == ' ' || ch == '\t' || ch == '\r') {
				self.advance();
			} else {
				break;
			}
		}
		return self.make_token_at(WHITESPACE, start, start_line, start_col);
	}

	// Newline
	if (c == '\n') {
		self.advance();
		self.line++;
		self.col = 0;
		return self.make_token_at(NEWLINE, start, start_line, start_col);
	}

	// Line comment
	if (c == '/' && self.peek_at(1) == '/') {
		while (self.pos < self.source.len && self.peek() != '\n') {
			self.advance();
		}
		return self.make_token_at(LINE_COMMENT, start, start_line, start_col);
	}

	// Block comment (nestable)
	if (c == '/' && self.peek_at(1) == '*') {
		self.skip_block_comment();
		return self.make_token_at(BLOCK_COMMENT, start, start_line, start_col);
	}

	return self.lex_normal_token();
}

// --- Private helpers ---

fn void Lexer.skip_whitespace_and_comments(Lexer* self) {
	while (self.pos < self.source.len) {
		char c = self.peek();

		if (c == ' ' || c == '\t' || c == '\r') {
			self.advance();
			continue;
		}

		if (c == '\n') {
			self.advance();
			self.line++;
			self.col = 0;
			continue;
		}

		// Line comment
		if (c == '/' && self.peek_at(1) == '/') {
			while (self.pos < self.source.len && self.peek() != '\n') {
				self.advance();
			}
			continue;
		}

		// Block comment (nestable)
		if (c == '/' && self.peek_at(1) == '*') {
			self.skip_block_comment();
			continue;
		}

		break;
	}
}

fn void Lexer.skip_block_comment(Lexer* self) {
	self.advance(); // skip /
	self.advance(); // skip *
	int depth = 1;
	while (self.pos < self.source.len && depth > 0) {
		char c = self.peek();
		if (c == '/' && self.peek_at(1) == '*') {
			self.advance();
			self.advance();
			depth++;
		} else if (c == '*' && self.peek_at(1) == '/') {
			self.advance();
			self.advance();
			depth--;
		} else if (c == '\n') {
			self.advance();
			self.line++;
			self.col = 0;
		} else {
			self.advance();
		}
	}
}

fn Token Lexer.lex_identifier(Lexer* self, usz start, uint start_line, uint start_col) {
	while (self.pos < self.source.len && is_ident_part(self.peek())) {
		self.advance();
	}
	String text = self.source[start:self.pos - start];
	TokenKind kind = lookup_keyword(text);

	// Handle compound keyword operators: as? -> AS_SAFE
	if (kind == KW_AS && self.pos < self.source.len && self.peek() == '?') {
		self.advance(); // consume '?'
		return {
			.kind = AS_SAFE,
			.text = self.source[start:self.pos - start],
			.line = start_line,
			.col = start_col,
			.offset = (uint)start,
			.len = (uint)(self.pos - start),
		};
	}

	return {
		.kind = kind,
		.text = text,
		.line = start_line,
		.col = start_col,
		.offset = (uint)start,
		.len = (uint)(self.pos - start),
	};
}

/**
 * Lex a backtick-quoted identifier: `foo`, `fun`, `my test name`.
 * The opening backtick has NOT been consumed yet.
 * Emits IDENTIFIER with text = inner content (no backticks),
 * offset/col = opening backtick, len = full span including backticks.
 */
fn Token Lexer.lex_backtick_identifier(Lexer* self, usz start, uint start_line, uint start_col) {
	self.advance(); // consume opening backtick

	// Consume characters until closing backtick, newline, or EOF
	usz inner_start = self.pos;
	while (self.pos < self.source.len) {
		char ch = self.peek();
		if (ch == '`') {
			break;
		}
		if (ch == '\n') {
			break; // unterminated: newline not allowed in backtick identifiers
		}
		self.advance();
	}

	usz inner_end = self.pos;

	// Check for closing backtick
	if (self.pos < self.source.len && self.peek() == '`') {
		self.advance(); // consume closing backtick
	} else {
		// Unterminated backtick identifier
		return self.make_token_at(ERROR, start, start_line, start_col);
	}

	// Empty backtick identifier `` is an error
	if (inner_end == inner_start) {
		return self.make_token_at(ERROR, start, start_line, start_col);
	}

	return {
		.kind = IDENTIFIER,
		.text = self.source[inner_start:inner_end - inner_start],
		.line = start_line,
		.col = start_col,
		.offset = (uint)start,
		.len = (uint)(self.pos - start),
	};
}

fn Token Lexer.lex_number(Lexer* self, usz start, uint start_line, uint start_col) {
	TokenKind kind = INTEGER_LITERAL;

	// Check for hex (0x) or binary (0b)
	if (self.peek() == '0' && self.pos + 1 < self.source.len) {
		char next = self.source[self.pos + 1];
		if (next == 'x' || next == 'X') {
			self.advance(); // 0
			self.advance(); // x
			while (self.pos < self.source.len && is_hex_digit(self.peek())) {
				self.advance();
			}
			return self.make_token_at(kind, start, start_line, start_col);
		}
		if (next == 'b' || next == 'B') {
			self.advance(); // 0
			self.advance(); // b
			while (self.pos < self.source.len && (self.peek() == '0' || self.peek() == '1' || self.peek() == '_')) {
				self.advance();
			}
			return self.make_token_at(kind, start, start_line, start_col);
		}
	}

	// Decimal digits
	while (self.pos < self.source.len && (is_digit(self.peek()) || self.peek() == '_')) {
		self.advance();
	}

	// Decimal point -> float
	if (self.pos < self.source.len && self.peek() == '.' && self.pos + 1 < self.source.len && is_digit(self.source[self.pos + 1])) {
		kind = FLOAT_LITERAL;
		self.advance(); // .
		while (self.pos < self.source.len && (is_digit(self.peek()) || self.peek() == '_')) {
			self.advance();
		}
	}

	// Exponent
	if (self.pos < self.source.len && (self.peek() == 'e' || self.peek() == 'E')) {
		kind = FLOAT_LITERAL;
		self.advance();
		if (self.pos < self.source.len && (self.peek() == '+' || self.peek() == '-')) {
			self.advance();
		}
		while (self.pos < self.source.len && is_digit(self.peek())) {
			self.advance();
		}
	}

	// Float suffix
	if (self.pos < self.source.len && (self.peek() == 'f' || self.peek() == 'F')) {
		kind = FLOAT_LITERAL;
		self.advance();
	}

	// Long/unsigned suffix
	if (self.pos < self.source.len && (self.peek() == 'L' || self.peek() == 'u' || self.peek() == 'U')) {
		self.advance();
		if (self.pos < self.source.len && self.peek() == 'L') {
			self.advance();
		}
	}

	return self.make_token_at(kind, start, start_line, start_col);
}

/**
 * Start lexing a string literal.
 * Emits STRING_OPEN or MULTILINE_STRING_OPEN and pushes string state.
 */
fn Token Lexer.lex_string(Lexer* self, usz start, uint start_line, uint start_col) {
	self.advance(); // opening "

	// Check for triple-quote
	if (self.pos + 1 < self.source.len && self.peek() == '"' && self.source[self.pos + 1] == '"') {
		self.advance(); // second "
		self.advance(); // third "
		self.push_string_state(true);
		return self.make_token_at(MULTILINE_STRING_OPEN, start, start_line, start_col);
	}

	// Regular string: check for empty string ""
	if (self.pos < self.source.len && self.peek() == '"') {
		// Empty string: emit as STRING_OPEN immediately followed by STRING_CLOSE
		// Don't push state; just emit STRING_CONTENT for the whole ""
		self.advance(); // closing "
		return self.make_token_at(STRING_CONTENT, start, start_line, start_col);
	}

	self.push_string_state(false);
	return self.make_token_at(STRING_OPEN, start, start_line, start_col);
}

/**
 * Push a new string context onto the stack.
 */
fn void Lexer.push_string_state(Lexer* self, bool multiline) {
	if (self.string_depth < MAX_STRING_DEPTH) {
		self.in_string[self.string_depth] = true;
		self.brace_depth[self.string_depth] = 0;
		self.is_multiline[self.string_depth] = multiline;
		self.string_depth++;
	}
}

/**
 * Pop the current string context.
 */
fn void Lexer.pop_string_state(Lexer* self) {
	if (self.string_depth > 0) {
		self.string_depth--;
	}
}

/**
 * Continue lexing inside a string literal.
 * Emits STRING_CONTENT, STRING_TEMPLATE_REF, STRING_TEMPLATE_START,
 * STRING_CLOSE, or MULTILINE_STRING_CLOSE.
 */
fn Token Lexer.lex_string_content(Lexer* self) {
	if (self.pos >= self.source.len) {
		// Unterminated string
		self.pop_string_state();
		return self.make_token(EOF, self.pos, 0);
	}

	bool multiline = self.string_depth > 0 && self.is_multiline[self.string_depth - 1];

	// Check for string close
	if (self.peek() == '"') {
		if (multiline) {
			if (self.pos + 2 < self.source.len && self.source[self.pos + 1] == '"' && self.source[self.pos + 2] == '"') {
				usz start = self.pos;
				uint start_line = self.line;
				uint start_col = self.col;
				self.advance(); // "
				self.advance(); // "
				self.advance(); // "
				self.pop_string_state();
				return self.make_token_at(MULTILINE_STRING_CLOSE, start, start_line, start_col);
			}
			// Single/double quote inside triple-quoted string: fall through to content
		} else {
			usz start = self.pos;
			uint start_line = self.line;
			uint start_col = self.col;
			self.advance(); // closing "
			self.pop_string_state();
			return self.make_token_at(STRING_CLOSE, start, start_line, start_col);
		}
	}

	// Check for template reference: $identifier
	if (self.peek() == '$' && self.pos + 1 < self.source.len) {
		char next_ch = self.source[self.pos + 1];
		if (next_ch == '{') {
			// Template expression start: ${
			usz start = self.pos;
			uint start_line = self.line;
			uint start_col = self.col;
			self.advance(); // $
			self.advance(); // {
			// Record brace depth for this string level
			if (self.string_depth > 0) {
				self.brace_depth[self.string_depth - 1] = 1;
			}
			return self.make_token_at(STRING_TEMPLATE_START, start, start_line, start_col);
		}
		if (is_ident_start(next_ch)) {
			// Template reference: $identifier
			usz start = self.pos;
			uint start_line = self.line;
			uint start_col = self.col;
			self.advance(); // $
			while (self.pos < self.source.len && is_ident_part(self.peek())) {
				self.advance();
			}
			return self.make_token_at(STRING_TEMPLATE_REF, start, start_line, start_col);
		}
	}

	// Regular string content: consume until $, closing quote, or end
	usz start = self.pos;
	uint start_line = self.line;
	uint start_col = self.col;

	while (self.pos < self.source.len) {
		char ch = self.peek();

		// Closing quote check
		if (ch == '"') {
			if (multiline) {
				if (self.pos + 2 < self.source.len && self.source[self.pos + 1] == '"' && self.source[self.pos + 2] == '"') {
					break; // let next call handle the close
				}
				// Single/double " in multiline: include as content
				self.advance();
				continue;
			} else {
				break; // let next call handle the close
			}
		}

		// Template marker
		if (ch == '$' && self.pos + 1 < self.source.len) {
			char nc = self.source[self.pos + 1];
			if (nc == '{' || is_ident_start(nc)) {
				break; // let next call handle the template
			}
		}

		// Newline terminates regular strings
		if (!multiline && ch == '\n') {
			break;
		}

		// Escape sequences in regular strings
		if (!multiline && ch == '\\') {
			self.advance(); // backslash
			if (self.pos < self.source.len) {
				if (self.peek() == '\n') {
					self.line++;
					self.col = 0;
				}
				self.advance(); // escaped char
			}
			continue;
		}

		if (ch == '\n') {
			self.advance();
			self.line++;
			self.col = 0;
			continue;
		}

		self.advance();
	}

	// If we consumed nothing (e.g., unterminated), pop and return error
	if (self.pos == start) {
		self.pop_string_state();
		return self.make_token_at(ERROR, start, start_line, start_col);
	}

	return self.make_token_at(STRING_CONTENT, start, start_line, start_col);
}

fn Token Lexer.lex_char(Lexer* self, usz start, uint start_line, uint start_col) {
	self.advance(); // opening '
	if (self.pos < self.source.len && self.peek() == '\\') {
		self.advance(); // backslash
		if (self.pos < self.source.len) {
			if (self.peek() == 'u') {
				self.advance(); // 'u'
				// Consume up to 4 hex digits for \uXXXX
				for (int i = 0; i < 4 && self.pos < self.source.len; i++) {
					char hc = self.peek();
					if (is_hex_digit(hc) && hc != '_') {
						self.advance();
					} else {
						break;
					}
				}
			} else {
				self.advance(); // single escaped char (\n, \t, \\, etc.)
			}
		}
	} else if (self.pos < self.source.len) {
		self.advance(); // regular char
	}
	if (self.pos < self.source.len && self.peek() == '\'') {
		self.advance(); // closing '
	}
	return self.make_token_at(CHARACTER_LITERAL, start, start_line, start_col);
}

fn Token Lexer.lex_operator(Lexer* self, usz start, uint start_line, uint start_col) {
	char c = self.peek();
	self.advance();

	switch (c) {
		case '.':
			if (self.peek() == '.') { self.advance(); return self.make_token_at(RANGE, start, start_line, start_col); }
			return self.make_token_at(DOT, start, start_line, start_col);
		case ',': return self.make_token_at(COMMA, start, start_line, start_col);
		case '(': return self.make_token_at(LPAREN, start, start_line, start_col);
		case ')': return self.make_token_at(RPAREN, start, start_line, start_col);
		case '[': return self.make_token_at(LSQUARE, start, start_line, start_col);
		case ']': return self.make_token_at(RSQUARE, start, start_line, start_col);
		case '{': return self.make_token_at(LCURL, start, start_line, start_col);
		case '}': return self.make_token_at(RCURL, start, start_line, start_col);
		case '*':
			if (self.peek() == '=') { self.advance(); return self.make_token_at(MULT_ASSIGN, start, start_line, start_col); }
			return self.make_token_at(MULT, start, start_line, start_col);
		case '%':
			if (self.peek() == '=') { self.advance(); return self.make_token_at(MOD_ASSIGN, start, start_line, start_col); }
			return self.make_token_at(MOD, start, start_line, start_col);
		case '/':
			if (self.peek() == '=') { self.advance(); return self.make_token_at(DIV_ASSIGN, start, start_line, start_col); }
			return self.make_token_at(DIV, start, start_line, start_col);
		case '+':
			if (self.peek() == '+') { self.advance(); return self.make_token_at(INCR, start, start_line, start_col); }
			if (self.peek() == '=') { self.advance(); return self.make_token_at(ADD_ASSIGN, start, start_line, start_col); }
			return self.make_token_at(ADD, start, start_line, start_col);
		case '-':
			if (self.peek() == '-') { self.advance(); return self.make_token_at(DECR, start, start_line, start_col); }
			if (self.peek() == '=') { self.advance(); return self.make_token_at(SUB_ASSIGN, start, start_line, start_col); }
			if (self.peek() == '>') { self.advance(); return self.make_token_at(ARROW, start, start_line, start_col); }
			return self.make_token_at(SUB, start, start_line, start_col);
		case '&':
			if (self.peek() == '&') { self.advance(); return self.make_token_at(CONJ, start, start_line, start_col); }
			return self.make_token_at(ERROR, start, start_line, start_col);
		case '|':
			if (self.peek() == '|') { self.advance(); return self.make_token_at(DISJ, start, start_line, start_col); }
			return self.make_token_at(ERROR, start, start_line, start_col);
		case '!':
			if (self.peek() == '=') {
				self.advance();
				if (self.peek() == '=') { self.advance(); return self.make_token_at(EXCL_EQEQ, start, start_line, start_col); }
				return self.make_token_at(EXCL_EQ, start, start_line, start_col);
			}
			if (self.peek() == '!') { self.advance(); return self.make_token_at(NOT_NULL, start, start_line, start_col); }
			// #5: Handle !is and !in as compound tokens
			if (self.peek() == 'i') {
				if (self.peek_at(1) == 's' && !is_ident_part(self.peek_at(2))) {
					self.advance(); // consume 'i'
					self.advance(); // consume 's'
					return self.make_token_at(NOT_IS, start, start_line, start_col);
				}
				if (self.peek_at(1) == 'n' && !is_ident_part(self.peek_at(2))) {
					self.advance(); // consume 'i'
					self.advance(); // consume 'n'
					return self.make_token_at(NOT_IN, start, start_line, start_col);
				}
			}
			return self.make_token_at(EXCL, start, start_line, start_col);
		case ':':
			if (self.peek() == ':') { self.advance(); return self.make_token_at(COLONCOLON, start, start_line, start_col); }
			return self.make_token_at(COLON, start, start_line, start_col);
		case ';': return self.make_token_at(SEMICOLON, start, start_line, start_col);
		case '=':
			if (self.peek() == '=') {
				self.advance();
				if (self.peek() == '=') { self.advance(); return self.make_token_at(EQEQEQ, start, start_line, start_col); }
				return self.make_token_at(EQEQ, start, start_line, start_col);
			}
			if (self.peek() == '>') { self.advance(); return self.make_token_at(DOUBLE_ARROW, start, start_line, start_col); }
			return self.make_token_at(ASSIGNMENT, start, start_line, start_col);
		case '<':
			if (self.peek() == '=') { self.advance(); return self.make_token_at(LE, start, start_line, start_col); }
			return self.make_token_at(LANGLE, start, start_line, start_col);
		case '>':
			if (self.peek() == '=') { self.advance(); return self.make_token_at(GE, start, start_line, start_col); }
			return self.make_token_at(RANGLE, start, start_line, start_col);
		case '?':
			if (self.peek() == '.') { self.advance(); return self.make_token_at(SAFE_CALL, start, start_line, start_col); }
			if (self.peek() == ':') { self.advance(); return self.make_token_at(ELVIS, start, start_line, start_col); }
			return self.make_token_at(QUEST, start, start_line, start_col);
		case '@': return self.make_token_at(AT, start, start_line, start_col);
		case '#': return self.make_token_at(HASH, start, start_line, start_col);
		default:
			return self.make_token_at(ERROR, start, start_line, start_col);
	}
}

// --- Utility functions ---

fn char Lexer.peek(Lexer* self) @inline {
	if (self.pos >= self.source.len) return 0;
	return self.source[self.pos];
}

fn char Lexer.peek_at(Lexer* self, usz offset) @inline {
	usz idx = self.pos + offset;
	if (idx >= self.source.len) return 0;
	return self.source[idx];
}

fn void Lexer.advance(Lexer* self) @inline {
	if (self.pos < self.source.len) {
		self.pos++;
		self.col++;
	}
}

fn Token Lexer.make_token(Lexer* self, TokenKind kind, usz start, uint len) @inline {
	return {
		.kind = kind,
		.text = len > 0 ? self.source[start:len] : "",
		.line = self.line,
		.col = self.col,
		.offset = (uint)start,
		.len = len,
	};
}

fn Token Lexer.make_token_at(Lexer* self, TokenKind kind, usz start, uint start_line, uint start_col) @inline {
	return {
		.kind = kind,
		.text = self.source[start:self.pos - start],
		.line = start_line,
		.col = start_col,
		.offset = (uint)start,
		.len = (uint)(self.pos - start),
	};
}

fn bool is_ident_start(char c) @inline {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

fn bool is_ident_part(char c) @inline {
	return is_ident_start(c) || is_digit(c);
}

fn bool is_digit(char c) @inline {
	return c >= '0' && c <= '9';
}

fn bool is_hex_digit(char c) @inline {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '_';
}

// --- Keyword lookup ---

fn TokenKind lookup_keyword(String text) {
	switch (text) {
		// Hard keywords
		case "package": return KW_PACKAGE;
		case "import": return KW_IMPORT;
		case "class": return KW_CLASS;
		case "interface": return KW_INTERFACE;
		case "fun": return KW_FUN;
		case "object": return KW_OBJECT;
		case "val": return KW_VAL;
		case "var": return KW_VAR;
		case "typealias": return KW_TYPEALIAS;
		case "constructor": return KW_CONSTRUCTOR;
		case "by": return KW_BY;
		case "companion": return KW_COMPANION;
		case "init": return KW_INIT;
		case "this": return KW_THIS;
		case "super": return KW_SUPER;
		case "typeof": return KW_TYPEOF;
		case "where": return KW_WHERE;
		case "if": return KW_IF;
		case "else": return KW_ELSE;
		case "when": return KW_WHEN;
		case "try": return KW_TRY;
		case "catch": return KW_CATCH;
		case "finally": return KW_FINALLY;
		case "for": return KW_FOR;
		case "do": return KW_DO;
		case "while": return KW_WHILE;
		case "throw": return KW_THROW;
		case "return": return KW_RETURN;
		case "continue": return KW_CONTINUE;
		case "break": return KW_BREAK;
		case "as": return KW_AS;
		case "is": return KW_IS;
		case "in": return KW_IN;
		case "out": return KW_OUT;
		case "dynamic": return KW_DYNAMIC;
		case "true": return BOOLEAN_LITERAL;
		case "false": return BOOLEAN_LITERAL;
		case "null": return NULL_LITERAL;

		// Soft keywords (returned as identifiers in most contexts,
		// but we tag them for highlighting / context-sensitive parsing)
		case "abstract": return KW_ABSTRACT;
		case "annotation": return KW_ANNOTATION;
		case "data": return KW_DATA;
		case "enum": return KW_ENUM;
		case "external": return KW_EXTERNAL;
		case "final": return KW_FINAL;
		case "infix": return KW_INFIX;
		case "inline": return KW_INLINE;
		case "inner": return KW_INNER;
		case "internal": return KW_INTERNAL;
		case "lateinit": return KW_LATEINIT;
		case "noinline": return KW_NOINLINE;
		case "open": return KW_OPEN;
		case "operator": return KW_OPERATOR;
		case "override": return KW_OVERRIDE;
		case "private": return KW_PRIVATE;
		case "protected": return KW_PROTECTED;
		case "public": return KW_PUBLIC;
		case "reified": return KW_REIFIED;
		case "sealed": return KW_SEALED;
		case "suspend": return KW_SUSPEND;
		case "tailrec": return KW_TAILREC;
		case "vararg": return KW_VARARG;
		case "crossinline": return KW_CROSSINLINE;
		case "const": return KW_CONST;
		case "expect": return KW_EXPECT;
		case "actual": return KW_ACTUAL;
		case "value": return KW_VALUE;
		case "get": return KW_GET;
		case "set": return KW_SET;
		case "field": return KW_FIELD;
		case "property": return KW_PROPERTY;
		case "receiver": return KW_RECEIVER;
		case "param": return KW_PARAM;
		case "setparam": return KW_SETPARAM;
		case "delegate": return KW_DELEGATE;
		case "file": return KW_FILE;

		default: return IDENTIFIER;
	}
}
