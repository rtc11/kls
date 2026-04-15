module kls::lsp::selection_range;

import std::collections::object;
import kls::document;
import kls::kotlin::ast;

/**
 * Handle textDocument/selectionRange request.
 *
 * Returns a JSON array of SelectionRange objects, one per input position.
 * Each SelectionRange is a recursive structure:
 *   { range: Range, parent?: SelectionRange }
 * where the innermost range contains the cursor and each parent is
 * a strictly wider range, up to the entire file.
 *
 * The implementation walks the flat AST to find all nodes containing each
 * cursor position, then builds a chain from innermost to outermost via
 * the parent index.
 */
fn Object* handle_selection_range(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;

	Object* positions = params.get("positions")!!;
	Object* result = object::new_obj(tmem); // JSON array

	for (sz i = 0; i < positions.get_len(); i++) {
		Object* pos = positions.get_at(i);
		uint line = (uint)pos.get_int("line")!!;
		uint character = (uint)pos.get_int("character")!!;

		Object* sel = build_selection_range(doc, pr, line, character);
		result.push(sel);
	}

	return result;
}

// ── Core algorithm ──────────────────────────────────────────────────

/**
 * Build a SelectionRange chain for a single cursor position.
 *
 * 1. Find the innermost AST node containing the cursor offset.
 * 2. Walk up the parent chain collecting nodes from inner to outer.
 * 3. Deduplicate nodes with identical ranges.
 * 4. Build the recursive JSON from outermost (no parent) inward.
 */
fn Object* build_selection_range(Document* doc, ParseResult* pr, uint line, uint character) {
	long cursor = document::position_to_byte_offset(doc.content, line, character);

	// If no AST or cursor past end, return a single-level range for the whole file
	if (pr == null || pr.node_count == 0 || cursor < 0) {
		return make_file_fallback(doc.content);
	}

	// ── Step 1: find innermost node containing cursor ───────────
	// In the flat array, deeper nodes appear later, so the last
	// matching node is the innermost.
	uint innermost = 0; // FILE node as default
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.start_offset == n.end_offset) continue; // skip zero-width nodes
		if ((uint)cursor >= n.start_offset && (uint)cursor < n.end_offset) {
			innermost = i;
		}
	}

	// ── Step 2: walk parent chain from innermost to FILE ────────
	// Collect node indices (innermost first)
	const usz MAX_CHAIN = 64;
	uint[MAX_CHAIN] chain;
	usz chain_len = 0;

	uint current = innermost;
	while (chain_len < MAX_CHAIN) {
		chain[chain_len] = current;
		chain_len++;

		if (current == 0) break; // reached FILE node
		uint parent_idx = pr.nodes[current].parent;
		if (parent_idx == ast::NO_PARENT) break;
		current = parent_idx;
	}

	// ── Step 3: build JSON from outermost to innermost ──────────
	// chain[chain_len-1] is outermost (FILE), chain[0] is innermost.
	// Build from the tail forward, linking parents.
	Object* outer = null;

	// Track the previous range to deduplicate identical spans
	uint prev_sl = uint.max;
	uint prev_sc = uint.max;
	uint prev_el = uint.max;
	uint prev_ec = uint.max;

	// Walk from outermost (chain_len-1) to innermost (0)
	for (usz j = chain_len; j > 0; j--) {
		AstNode* n = &pr.nodes[chain[j - 1]];

		uint sl = n.start_line;
		uint sc = n.start_col;
		uint el = n.end_line;
		uint ec = n.end_col;

		// Deduplicate: skip if range is identical to previous level
		if (sl == prev_sl && sc == prev_sc && el == prev_el && ec == prev_ec) {
			continue;
		}
		prev_sl = sl;
		prev_sc = sc;
		prev_el = el;
		prev_ec = ec;

		Object* sel = object::new_obj(tmem);
		sel.set("range", make_range(sl, sc, el, ec));
		if (outer != null) {
			sel.set("parent", outer);
		}
		outer = sel;
	}

	// outer is now the innermost SelectionRange (which links to parents)
	if (outer != null) return outer;

	// Fallback: should not happen, but return file-level range
	return make_file_fallback(doc.content);
}

// ── Helpers ─────────────────────────────────────────────────────────

/**
 * Build a { start: { line, character }, end: { line, character } } object.
 */
fn Object* make_range(uint start_line, uint start_col, uint end_line, uint end_col) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)start_line);
	start.set("character", (int)start_col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)end_line);
	end_pos.set("character", (int)end_col);

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	return range;
}

/**
 * Fallback: single SelectionRange covering the entire document.
 */
fn Object* make_file_fallback(String content) {
	uint end_line = 0;
	uint end_col = 0;
	for (usz i = 0; i < content.len; i++) {
		if (content[i] == '\n') {
			end_line++;
			end_col = 0;
		} else {
			end_col++;
		}
	}

	Object* sel = object::new_obj(tmem);
	sel.set("range", make_range(0, 0, end_line, end_col));
	return sel;
}
