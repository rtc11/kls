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

const usz MAX_SUPERTYPES = 8;

struct Symbol {
	SymbolKind kind;
	String name;
	String receiver;       // receiver type text for extension functions/properties
	uint line;
	uint col;
	uint offset;
	uint len;
	bool is_private;       // declared with 'private' modifier
	String[MAX_SUPERTYPES] supertypes;  // supertype names (slices into source)
	usz supertype_count;
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
	int brace_depth = 0;  // track nesting: only top-level fun/val/var are importable
	bool saw_private = false;  // track private modifier for current declaration

	while (count < out_buf.len) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		// Track brace depth for nesting awareness
		if (tok.kind == LCURL) { brace_depth++; saw_private = false; continue; }
		if (tok.kind == RCURL) { if (brace_depth > 0) brace_depth--; saw_private = false; continue; }

		switch (tok.kind) {
			case KW_FUN:
				// Skip nested functions (local funs, class members -- members
				// are found via member_cache from the full parser).
				if (brace_depth > 0) { saw_private = false; break; }
				if (try sym = scan_fun_name(&lex)) {
					sym.is_private = saw_private;
					out_buf[count] = sym;
					count++;
				}
				saw_private = false;

		case KW_CLASS:
			if (try sym = scan_simple_name(&lex, SymbolKind.CLASS)) {
				scan_supertypes(&lex, &sym);
				sym.is_private = saw_private;
				out_buf[count] = sym;
				count++;
			}
			saw_private = false;

		case KW_INTERFACE:
			if (try sym = scan_simple_name(&lex, SymbolKind.INTERFACE)) {
				scan_supertypes(&lex, &sym);
				sym.is_private = saw_private;
				out_buf[count] = sym;
				count++;
			}
			saw_private = false;

		case KW_OBJECT:
			if (try sym = scan_simple_name(&lex, SymbolKind.OBJECT)) {
				scan_supertypes(&lex, &sym);
				sym.is_private = saw_private;
				out_buf[count] = sym;
				count++;
			}
			saw_private = false;

			case KW_VAL:
				nextcase;
			case KW_VAR:
				// Skip nested properties (locals, class members).
				if (brace_depth > 0) { saw_private = false; break; }
				if (try sym = scan_property_name(&lex)) {
					sym.is_private = saw_private;
					out_buf[count] = sym;
					count++;
				}
				saw_private = false;

			case KW_TYPEALIAS:
				if (try sym = scan_simple_name(&lex, SymbolKind.TYPEALIAS)) {
					sym.is_private = saw_private;
					out_buf[count] = sym;
					count++;
				}
				saw_private = false;

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

		case KW_PRIVATE:
			saw_private = true;
			break;

			case KW_COMPANION:
				// companion object [Name]
				if (try sym = scan_companion_object(&lex)) {
					out_buf[count] = sym;
					count++;
				}

			default:
				saw_private = false;
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
			Symbol sym = make_symbol(SymbolKind.FUNCTION, name_tok);
			sym.receiver = next.text;
			return sym;
		}
		return NO_SYMBOL~;
	}

	// If LANGLE follows, this could be Receiver<T>.name
	if (after.kind == LANGLE) {
		String receiver_text = next.text;
		skip_angle_brackets(lex);
		Token dot = lex.next();
		if (dot.kind == DOT) {
			Token name_tok = lex.next();
			if (name_tok.kind == IDENTIFIER) {
				Symbol sym = make_symbol(SymbolKind.FUNCTION, name_tok);
				sym.receiver = receiver_text;
				return sym;
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
			Symbol sym = make_symbol(SymbolKind.PROPERTY, name_tok);
			sym.receiver = next.text;
			return sym;
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
		.supertype_count = 0,
	};
}

/**
 * After scanning a class/interface/object name, use a SEPARATE lexer
 * to look ahead in the source for the supertype list.
 * This avoids advancing the main scanner's lexer position.
 *
 * Scans from the symbol's offset+len forward, looking for ': Type, Type'.
 * Skips type parameters <T> and primary constructor (...).
 */
fn void scan_supertypes(Lexer* main_lex, Symbol* sym) {
	// Create a separate lexer starting right after the symbol name
	// We need to get the source from the main lexer
	String source = main_lex.source;
	usz start_pos = (usz)sym.offset + (usz)sym.len;
	if (start_pos >= source.len) return;

	Lexer lookahead = lexer::init(source[start_pos..]);

	// Limit how far ahead we look (avoid scanning the entire file)
	int budget = 50;

	while (budget > 0) {
		Token tok = lookahead.next();
		budget--;
		if (tok.kind == EOF) return;

		// Skip type parameters
		if (tok.kind == LANGLE) {
			int depth = 1;
			while (depth > 0 && budget > 0) {
				Token inner = lookahead.next();
				budget--;
				if (inner.kind == EOF) return;
				if (inner.kind == LANGLE) depth++;
				if (inner.kind == RANGLE) depth--;
			}
			continue;
		}

		// Skip primary constructor parameters
		if (tok.kind == LPAREN) {
			int depth = 1;
			while (depth > 0 && budget > 0) {
				Token inner = lookahead.next();
				budget--;
				if (inner.kind == EOF) return;
				if (inner.kind == LPAREN) depth++;
				if (inner.kind == RPAREN) depth--;
			}
			continue;
		}

		// Found colon -- scan supertype names
		if (tok.kind == COLON) {
			scan_supertype_list(&lookahead, sym, source, start_pos);
			return;
		}

		// Hit class body or end of declaration -- no supertypes
		if (tok.kind == LCURL || tok.kind == SEMICOLON || tok.kind == KW_WHERE) {
			return;
		}

		// Unexpected token for this context -- stop looking
		if (tok.kind != IDENTIFIER && tok.kind != COMMA && tok.kind != DOT
			&& tok.kind != KW_CONSTRUCTOR && tok.kind != KW_INTERNAL
			&& tok.kind != KW_PUBLIC && tok.kind != KW_PRIVATE
			&& tok.kind != KW_PROTECTED) {
			return;
		}
	}
}

/**
 * After consuming ':', scan the comma-separated supertype names.
 * Records each simple name (ignoring generic args and constructor calls).
 * Uses the original source and offset for correct string slicing.
 */
fn void scan_supertype_list(Lexer* lex, Symbol* sym, String source, usz base_offset) {
	while (sym.supertype_count < MAX_SUPERTYPES) {
		Token tok = lex.next();
		if (tok.kind == EOF) return;

		if (tok.kind == IDENTIFIER) {
			// Compute the actual offset in the original source
			usz real_offset = base_offset + (usz)tok.offset;
			if (real_offset + (usz)tok.len <= source.len) {
				sym.supertypes[sym.supertype_count] = source[real_offset..real_offset + (usz)tok.len - 1];
			} else {
				sym.supertypes[sym.supertype_count] = tok.text;
			}
			sym.supertype_count++;

			// Skip generic arguments: <T, R>
			Token after = lex.next();
			if (after.kind == LANGLE) {
				int depth = 1;
				while (depth > 0) {
					Token inner = lex.next();
					if (inner.kind == EOF) return;
					if (inner.kind == LANGLE) depth++;
					if (inner.kind == RANGLE) depth--;
				}
				after = lex.next();
			}

			// Skip constructor call: ()
			if (after.kind == LPAREN) {
				int depth = 1;
				while (depth > 0) {
					Token inner = lex.next();
					if (inner.kind == EOF) return;
					if (inner.kind == LPAREN) depth++;
					if (inner.kind == RPAREN) depth--;
				}
				after = lex.next();
			}

			// Skip delegation: by expr (consume until comma, {, or where)
			if (after.kind == KW_BY) {
				while (true) {
					Token skip_tok = lex.next();
					if (skip_tok.kind == EOF) return;
					if (skip_tok.kind == COMMA) break;
					if (skip_tok.kind == LCURL || skip_tok.kind == KW_WHERE) return;
				}
				continue; // comma consumed, next supertype
			}

			// Comma means more supertypes
			if (after.kind == COMMA) continue;

			// Anything else means end of supertype list
			return;
		}

		// Non-identifier at start -- end of list
		return;
	}
}
