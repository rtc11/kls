module kls::lsp::folding_range;

import std::collections::object;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

/**
 * Handle textDocument/foldingRange request.
 * Returns a JSON array of FoldingRange objects built from:
 *   1. AST nodes that span multiple lines (classes, functions, blocks, etc.)
 *   2. Consecutive import declarations (folded as a region)
 *   3. Multi-line comments (block comments, KDoc)
 *
 * Returns null if the document is unknown.
 *
 * FoldingRange {
 *   startLine:      uint,
 *   startCharacter?: uint,
 *   endLine:        uint,
 *   endCharacter?:  uint,
 *   kind?:          "comment" | "imports" | "region"
 * }
 */
fn Object* handle_folding_range(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;

	Object* result = object::new_obj(tmem); // JSON array

	// ── 1. AST-based folding ranges ──────────────────────────────
	if (pr != null) {
		add_ast_folding_ranges(result, pr);
		add_import_folding_range(result, pr);
	}

	// ── 2. Comment folding ranges (from lexer) ───────────────────
	add_comment_folding_ranges(result, doc.content);

	return result;
}

// ── AST folding ranges ───────────────────────────────────────────

/**
 * Walk all AST nodes and emit a FoldingRange for each node
 * that spans more than one line.
 */
fn void add_ast_folding_ranges(Object* result, ParseResult* pr) {
	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (!is_foldable_node(node.kind)) continue;

		// Only fold if the node spans multiple lines
		if (node.end_line <= node.start_line) continue;

		Object* range = make_folding_range(
			node.start_line, node.start_col,
			node.end_line, node.end_col,
			""
		);
		result.push(range);
	}
}

/**
 * Check if a node kind should produce a folding range.
 */
fn bool is_foldable_node(NodeKind kind) {
	switch (kind) {
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case FUN_DECL:
		case CONSTRUCTOR_DECL:
		case INIT_BLOCK:
		case ENUM_ENTRY:
		case PROPERTY_DECL:
		case IF_EXPR:
		case WHEN_EXPR:
		case FOR_STMT:
		case WHILE_STMT:
		case DO_WHILE_STMT:
		case TRY_EXPR:
		case CATCH_CLAUSE:
		case LAMBDA_EXPR:
		case OBJECT_EXPR:
			return true;

		default:
			return false;
	}
}

// ── Import folding range ─────────────────────────────────────────

/**
 * If there are 2+ consecutive IMPORT_DECL nodes, emit a single
 * folding range covering the entire import block with kind "imports".
 */
fn void add_import_folding_range(Object* result, ParseResult* pr) {
	uint first_line = uint.max;
	uint first_col = 0;
	uint last_line = 0;
	uint last_col = 0;
	usz import_count = 0;

	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.kind != IMPORT_DECL) continue;
		if (node.parent != 0) continue; // only file-level imports

		import_count++;
		if (node.start_line < first_line) {
			first_line = node.start_line;
			first_col = node.start_col;
		}
		if (node.end_line > last_line) {
			last_line = node.end_line;
			last_col = node.end_col;
		}
	}

	// Only fold if imports span multiple lines (i.e., 2+ import statements)
	if (import_count >= 2 && last_line > first_line) {
		Object* range = make_folding_range(
			first_line, first_col,
			last_line, last_col,
			"imports"
		);
		result.push(range);
	}
}

// ── Comment folding ranges ───────────────────────────────────────

/**
 * Scan for multi-line block comments using the lexer's next_all()
 * mode and emit folding ranges with kind "comment".
 */
fn void add_comment_folding_ranges(Object* result, String content) {
	if (content.len == 0) return;

	Lexer lex = lexer::init(content);
	while (true) {
		Token tok = lex.next_all();
		if (tok.kind == EOF) break;

		if (tok.kind != BLOCK_COMMENT) continue;

		// Only fold multi-line comments
		uint end_line = tok.line;
		uint end_col = tok.col + tok.len;

		// Calculate end position by scanning the token text
		// (block comments can span multiple lines)
		end_line = tok.line;
		end_col = tok.col;
		for (usz j = 0; j < tok.text.len; j++) {
			if (tok.text[j] == '\n') {
				end_line++;
				end_col = 0;
			} else {
				end_col++;
			}
		}

		if (end_line > tok.line) {
			Object* range = make_folding_range(
				tok.line, tok.col,
				end_line, end_col,
				"comment"
			);
			result.push(range);
		}
	}
}

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Build a FoldingRange JSON object.
 * kind should be "comment", "imports", "region", or "" (omitted).
 */
fn Object* make_folding_range(uint start_line, uint start_character,
	uint end_line, uint end_character, String kind) {
	Object* range = object::new_obj(tmem);
	range.set("startLine", (int)start_line);
	range.set("startCharacter", (int)start_character);
	range.set("endLine", (int)end_line);
	range.set("endCharacter", (int)end_character);
	if (kind.len > 0) {
		range.set("kind", kind);
	}
	return range;
}
