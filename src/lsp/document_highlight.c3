module kls::lsp::document_highlight;

import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::references;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

// DocumentHighlightKind (LSP 3.17)
const int TEXT  = 1;
const int READ  = 2;
const int WRITE = 3;

/**
 * Handle textDocument/documentHighlight request.
 * Returns a JSON array of DocumentHighlight objects for all occurrences
 * of the identifier under the cursor, or null if nothing is found.
 *
 * Uses the lexer token stream to find all matching IDENTIFIER tokens,
 * then classifies each as Write (declaration sites) or Read (usage sites)
 * using the AST.
 */
fn Object* handle_document_highlight(DocumentStore* store, Object* params) {
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

	// Only highlight identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Get cached AST for declaration classification
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Collect all IDENTIFIER tokens matching target_name
	Object* highlights = object::new_obj(tmem); // JSON array

	Lexer lex = lexer::init(doc.content);
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		// Classify: declaration names are Write, everything else is Read
		int kind = READ;
		if (pr != null && references::is_declaration_name(pr, t.offset)) {
			kind = WRITE;
		}

		Object* highlight = build_highlight(t, kind);
		highlights.push(highlight);
	}

	// Return null if no highlights found
	if (highlights.get_len() == 0) {
		return null;
	}

	return highlights;
}

/**
 * Build an LSP DocumentHighlight object from a token and highlight kind.
 */
fn Object* build_highlight(Token tok, int kind) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* highlight = object::new_obj(tmem);
	highlight.set("range", range);
	highlight.set("kind", kind);

	return highlight;
}
