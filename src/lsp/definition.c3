module kls::lsp::definition;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::symbols;

const usz MAX_SYMBOLS = 512;

/**
 * Handle textDocument/definition request.
 * Returns a Location JSON object pointing to the declaration of the
 * identifier under the cursor, or null if no definition is found.
 *
 * Only resolves definitions within the same document (no cross-file).
 */
fn Object* handle_definition(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	// Only navigate to definitions of identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Detect call context: if the next token after the cursor token
	// is ( or { (trailing lambda), the identifier is being invoked
	// and we should prefer FUNCTION declarations over PROPERTY.
	bool is_call = is_call_context(doc.content, tok);

	// Scan declarations in the document
	Symbol[MAX_SYMBOLS] sym_buf;
	usz sym_count = symbols::scan_declarations(doc.content, &sym_buf);

	// Find matching declaration.
	// In call context, prefer FUNCTION; fall back to first match.
	// Otherwise, return the first match by source order.
	usz first_match = sym_count; // sentinel: no match
	usz func_match = sym_count;  // sentinel: no function match

	for (usz i = 0; i < sym_count; i++) {
		if (sym_buf[i].name == target_name) {
			if (first_match == sym_count) {
				first_match = i;
			}
			if (func_match == sym_count && sym_buf[i].kind == SymbolKind.FUNCTION) {
				func_match = i;
			}
		}
	}

	if (is_call && func_match < sym_count) {
		return build_location(uri, sym_buf[func_match]);
	}
	if (first_match < sym_count) {
		return build_location(uri, sym_buf[first_match]);
	}

	return null;
}

/**
 * Build an LSP Location object from a Symbol.
 */
fn Object* build_location(String uri, Symbol sym) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)sym.line);
	start.set("character", (int)sym.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)sym.line);
	end_pos.set("character", (int)(sym.col + sym.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", uri);
	location.set("range", range);

	return location;
}

/**
 * Determine if an identifier token is in a call context by checking
 * the next non-whitespace token after it. Returns true if the next
 * token is `(`, `{` (trailing lambda), or `<` (generic invocation).
 */
fn bool is_call_context(String content, Token tok) {
	usz after_pos = (usz)tok.offset + (usz)tok.len;
	if (after_pos >= content.len) return false;

	// Lex from just after the cursor token to find the next token
	Lexer lex = lexer::init(content[after_pos..]);
	Token next = lex.next();

	return next.kind == LPAREN || next.kind == LCURL || next.kind == LANGLE;
}
