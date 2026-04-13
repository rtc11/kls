module kls::lsp::references;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

/**
 * Handle textDocument/references request.
 * Returns a JSON array of Location objects for all occurrences of the
 * identifier under the cursor, or null if nothing is found.
 *
 * Scans the lexer token stream for all IDENTIFIER tokens matching the
 * target name. When context.includeDeclaration is false, filters out
 * locations that correspond to AST declaration name positions.
 * Only resolves references within the same document (no cross-file).
 */
fn Object* handle_references(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	// Check context.includeDeclaration (default true per LSP spec)
	bool include_declaration = true;
	if (try ctx = params.get("context")) {
		if (try incl = ctx.get_bool("includeDeclaration")) {
			include_declaration = incl;
		}
	}

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

	// Only find references for identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Get cached AST for declaration filtering
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Collect all IDENTIFIER tokens matching target_name
	Object* locations = object::new_obj(tmem);  // JSON array

	Lexer lex = lexer::init(doc.content);
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		if (t.kind != IDENTIFIER) continue;
		if (t.text != target_name) continue;

		// If not including declarations, check if this token is a declaration name
		if (!include_declaration && pr != null) {
			if (is_declaration_name(pr, t.offset)) {
				continue;
			}
		}

		// Build Location for this occurrence
		Object* location = build_location(uri, t);
		locations.push(location);
	}

	// Return null if no references found
	if (locations.get_len() == 0) {
		return null;
	}

	return locations;
}

/**
 * Check if a given byte offset corresponds to a declaration's name position
 * in the AST. Used to filter out declaration sites when includeDeclaration
 * is false.
 */
fn bool is_declaration_name(ParseResult* pr, uint offset) {
	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name_offset == offset && n.name_len > 0) {
			return true;
		}
	}
	return false;
}

/**
 * Build an LSP Location object from a token's position.
 */
fn Object* build_location(String uri, Token tok) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", uri);
	location.set("range", range);

	return location;
}
