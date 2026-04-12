module kls::kotlin::symbols;

import kls::kotlin::lexer;
import kls::kotlin::token;

enum SymbolKind : int {
	FUNCTION,
	CLASS,
	INTERFACE,
	OBJECT,
	PROPERTY,
	TYPEALIAS,
}

struct Symbol {
	SymbolKind kind;
	String name;
	uint line;
	uint col;
	uint offset;
	uint len;
}

/**
 * Scan a Kotlin source string for top-level and nested declarations.
 * Writes discovered symbols into `out_buf` and returns the count.
 *
 * Recognises these declaration patterns:
 *   fun [<T>] [Receiver.] name (...)
 *   class / interface / object / typealias  name
 *   val / var  name
 *   data class / enum class / sealed class / sealed interface
 *   annotation class / value class
 *   companion object [name]
 */
fn usz scan_declarations(String content, Symbol[] out_buf) {
	if (content.len == 0 || out_buf.len == 0) return 0;

	Lexer lex = lexer::init(content);
	usz count = 0;

	while (count < out_buf.len) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		switch (tok.kind) {
			case KW_FUN:
				if (try sym = scan_fun_name(&lex)) {
					out_buf[count] = sym;
					count++;
				}

			case KW_CLASS:
				if (try sym = scan_simple_name(&lex, SymbolKind.CLASS)) {
					out_buf[count] = sym;
					count++;
				}

			case KW_INTERFACE:
				if (try sym = scan_simple_name(&lex, SymbolKind.INTERFACE)) {
					out_buf[count] = sym;
					count++;
				}

			case KW_OBJECT:
				if (try sym = scan_simple_name(&lex, SymbolKind.OBJECT)) {
					out_buf[count] = sym;
					count++;
				}

			case KW_VAL:
				nextcase;
			case KW_VAR:
				if (try sym = scan_property_name(&lex)) {
					out_buf[count] = sym;
					count++;
				}

			case KW_TYPEALIAS:
				if (try sym = scan_simple_name(&lex, SymbolKind.TYPEALIAS)) {
					out_buf[count] = sym;
					count++;
				}

			// Modifier keywords: skip and let next iteration handle
			// the declaration keyword that follows.
			case KW_DATA:
				nextcase;
			case KW_ENUM:
				nextcase;
			case KW_SEALED:
				nextcase;
			case KW_ANNOTATION:
				nextcase;
			case KW_VALUE:
				nextcase;
			case KW_ABSTRACT:
				nextcase;
			case KW_OPEN:
				nextcase;
			case KW_INNER:
				nextcase;
			case KW_PRIVATE:
				nextcase;
			case KW_PROTECTED:
				nextcase;
			case KW_PUBLIC:
				nextcase;
			case KW_INTERNAL:
				nextcase;
			case KW_FINAL:
				nextcase;
			case KW_OVERRIDE:
				nextcase;
			case KW_EXTERNAL:
				nextcase;
			case KW_INLINE:
				nextcase;
			case KW_INFIX:
				nextcase;
			case KW_OPERATOR:
				nextcase;
			case KW_SUSPEND:
				nextcase;
			case KW_TAILREC:
				nextcase;
			case KW_EXPECT:
				nextcase;
			case KW_ACTUAL:
				nextcase;
			case KW_LATEINIT:
				nextcase;
			case KW_CONST:
				break;

			case KW_COMPANION:
				// companion object [Name]
				if (try sym = scan_companion_object(&lex)) {
					out_buf[count] = sym;
					count++;
				}

			default:
				break;
		}
	}

	return count;
}

// ── Private helpers ────────────────────────────────────────────────

faultdef NO_SYMBOL;

/**
 * After seeing `fun`, scan for the function name.
 * Handles: fun name(...)
 *          fun <T> name(...)
 *          fun Receiver.name(...)
 *          fun <T> Receiver.name(...)
 */
fn Symbol? scan_fun_name(Lexer* lex) {
	Token next = lex.next();

	// Skip generics: <...>
	if (next.kind == LANGLE) {
		skip_angle_brackets(lex);
		next = lex.next();
	}

	if (next.kind != IDENTIFIER) return NO_SYMBOL~;

	// Peek ahead: if DOT follows, this is a receiver type
	Token after = lex.next();
	if (after.kind == DOT) {
		// Receiver.name -- get the actual name
		Token name_tok = lex.next();
		if (name_tok.kind == IDENTIFIER) {
			return make_symbol(SymbolKind.FUNCTION, name_tok);
		}
		return NO_SYMBOL~;
	}

	// If LANGLE follows, this could be Receiver<T>.name
	if (after.kind == LANGLE) {
		skip_angle_brackets(lex);
		Token dot = lex.next();
		if (dot.kind == DOT) {
			Token name_tok = lex.next();
			if (name_tok.kind == IDENTIFIER) {
				return make_symbol(SymbolKind.FUNCTION, name_tok);
			}
			return NO_SYMBOL~;
		}
		// Not a receiver -- the identifier before <> was the name
		return make_symbol(SymbolKind.FUNCTION, next);
	}

	// Simple: fun name
	return make_symbol(SymbolKind.FUNCTION, next);
}

/**
 * After seeing `val` or `var`, scan for the property name.
 * Handles: val name
 *          val (destructuring) -- skip
 *          val Receiver.name (extension property)
 */
fn Symbol? scan_property_name(Lexer* lex) {
	Token next = lex.next();

	// Destructuring: val (a, b) = ... -- skip
	if (next.kind == LPAREN) return NO_SYMBOL~;

	if (next.kind != IDENTIFIER) return NO_SYMBOL~;

	// Peek ahead: if DOT follows, this is an extension property
	Token after = lex.next();
	if (after.kind == DOT) {
		Token name_tok = lex.next();
		if (name_tok.kind == IDENTIFIER) {
			return make_symbol(SymbolKind.PROPERTY, name_tok);
		}
		return NO_SYMBOL~;
	}

	// Simple property
	return make_symbol(SymbolKind.PROPERTY, next);
}

/**
 * After seeing `class`, `interface`, `object`, or `typealias`,
 * scan for the identifier name.
 */
fn Symbol? scan_simple_name(Lexer* lex, SymbolKind kind) {
	Token next = lex.next();
	if (next.kind == IDENTIFIER) {
		return make_symbol(kind, next);
	}
	return NO_SYMBOL~;
}

/**
 * After seeing `companion`, check for `object` and optional name.
 */
fn Symbol? scan_companion_object(Lexer* lex) {
	Token next = lex.next();
	if (next.kind != KW_OBJECT) return NO_SYMBOL~;

	Token name_tok = lex.next();
	if (name_tok.kind == IDENTIFIER) {
		return make_symbol(SymbolKind.OBJECT, name_tok);
	}
	// Anonymous companion object -- no symbol to record
	return NO_SYMBOL~;
}

/**
 * Skip over angle-bracket-delimited generic parameters.
 * Assumes the opening `<` has already been consumed.
 * Handles nesting: `<A<B>>`.
 */
fn void skip_angle_brackets(Lexer* lex) {
	int depth = 1;
	while (depth > 0) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		if (tok.kind == LANGLE) depth++;
		if (tok.kind == RANGLE) depth--;
	}
}

fn Symbol make_symbol(SymbolKind kind, Token tok) @inline {
	return {
		.kind = kind,
		.name = tok.text,
		.line = tok.line,
		.col = tok.col,
		.offset = tok.offset,
		.len = tok.len,
	};
}
