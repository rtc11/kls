module kls::kotlin::incremental;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::lexer;
import kls::kotlin::token;
import std::io;

// ── Chunk tracking ─────────────────────────────────────────────────

const usz MAX_CHUNKS = 1024;
const usz MAX_MEMBER_CHUNKS = 256;

/**
 * A chunk represents the byte range and node range of a single top-level
 * declaration or class member. Used to determine what needs re-parsing
 * when an edit occurs.
 */
struct Chunk {
	uint byte_start;      // start byte offset in source
	uint byte_end;        // end byte offset in source (exclusive)
	uint line_start;      // start line (0-based)
	uint line_end;        // end line (0-based)
	uint node_start;      // first node index in ParseResult (the decl node itself)
	uint node_end;        // one past last node index belonging to this chunk

	// Two-level: for class-like declarations, track member chunks
	MemberChunk[MAX_MEMBER_CHUNKS] members;
	usz member_count;
}

/**
 * A member chunk tracks a single member within a class-like declaration.
 */
struct MemberChunk {
	uint byte_start;
	uint byte_end;
	uint line_start;
	uint line_end;
	uint node_start;      // first node index (the member decl node)
	uint node_end;        // one past last node index
}

/**
 * ChunkMap tracks the boundaries of all top-level declarations in a parsed file.
 * Built after each full parse, updated incrementally on edits.
 */
struct ChunkMap {
	Chunk[MAX_CHUNKS] chunks;
	usz chunk_count;

	// Preamble region (package + imports) -- edits here force full re-parse
	uint preamble_end_byte;
	uint preamble_end_line;
	uint preamble_node_end; // one past last preamble node index
}

// ── Build chunk map from a parse result ────────────────────────────

/**
 * Build a ChunkMap by scanning direct children of the FILE node (index 0).
 * Groups preamble (PACKAGE_DECL, IMPORT_DECL) separately from declaration chunks.
 * For class-like declarations, also records member-level chunks.
 */
fn void build_chunk_map(ParseResult* result, ChunkMap* map, String source) {
	map.chunk_count = 0;
	map.preamble_end_byte = 0;
	map.preamble_end_line = 0;
	map.preamble_node_end = 0;

	if (result.node_count == 0) return;

	AstNode* file_node = &result.nodes[0];
	if (file_node.kind != FILE) return;

	uint file_idx = 0;
	bool in_preamble = true;

	// Scan direct children of FILE
	for (uint i = file_node.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent != file_idx) continue;

		AstNode* node = &result.nodes[i];

		// Package and import declarations are preamble
		if (in_preamble && (node.kind == PACKAGE_DECL || node.kind == IMPORT_DECL)) {
			map.preamble_end_byte = node.end_offset;
			map.preamble_end_line = node.end_line;
			map.preamble_node_end = find_subtree_end(result, i);
			continue;
		}
		in_preamble = false;

		if (map.chunk_count >= MAX_CHUNKS) break;

		// Find the range of nodes belonging to this declaration's subtree
		uint subtree_end = find_subtree_end(result, i);

		Chunk* chunk = &map.chunks[map.chunk_count];
		chunk.byte_start = node.start_offset;
		chunk.byte_end = node.end_offset;
		chunk.line_start = node.start_line;
		chunk.line_end = node.end_line;
		chunk.node_start = i;
		chunk.node_end = subtree_end;
		chunk.member_count = 0;

		// Two-level: if class-like, build member chunks
		if (ast::is_class_like(node.kind)) {
			build_member_chunks(result, i, chunk);
		}

		map.chunk_count++;
	}
}

/**
 * Find the index one past the last node in the subtree rooted at `root_idx`.
 * Since children are stored contiguously after their parent in the flat array
 * (due to how adopt_children works), we scan forward finding all nodes whose
 * ancestor chain includes root_idx.
 */
fn uint find_subtree_end(ParseResult* result, uint root_idx) {
	uint end = root_idx + 1;
	for (uint i = root_idx + 1; i < result.node_count; i++) {
		// Walk up the parent chain to check if this node is under root_idx
		uint p = result.nodes[i].parent;
		bool is_descendant = false;
		uint safety = 0;
		while (p != ast::NO_PARENT && safety < 100) {
			if (p == root_idx) {
				is_descendant = true;
				break;
			}
			p = result.nodes[p].parent;
			safety++;
		}
		if (is_descendant) {
			end = i + 1;
		} else {
			// Once we hit a non-descendant, all descendants have been seen
			// (due to contiguous layout)
			break;
		}
	}
	return end;
}

/**
 * Build member-level chunks for a class-like declaration.
 * Scans direct children of the class node for declaration kinds.
 */
fn void build_member_chunks(ParseResult* result, uint class_idx, Chunk* chunk) {
	AstNode* class_node = &result.nodes[class_idx];

	for (uint i = class_node.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent != class_idx) continue;

		AstNode* member = &result.nodes[i];
		if (!ast::is_declaration(member.kind) && member.kind != BLOCK) continue;

		if (chunk.member_count >= MAX_MEMBER_CHUNKS) break;

		uint subtree_end = find_subtree_end(result, i);

		MemberChunk* mc = &chunk.members[chunk.member_count];
		mc.byte_start = member.start_offset;
		mc.byte_end = member.end_offset;
		mc.line_start = member.start_line;
		mc.line_end = member.end_line;
		mc.node_start = i;
		mc.node_end = subtree_end;

		chunk.member_count++;
	}
}

// ── Edit analysis ──────────────────────────────────────────────────

/**
 * Result of analyzing which chunks are affected by an edit.
 */
struct EditAnalysis {
	bool needs_full_reparse;  // true if edit is in preamble or spans multiple chunks
	bool found_chunk;         // true if a containing chunk was found
	usz chunk_idx;            // index into ChunkMap.chunks
	bool found_member;        // true if edit is within a single class member
	usz member_idx;           // index into Chunk.members (valid if found_member)
}

/**
 * Analyze an edit to determine which chunk(s) are affected.
 * Returns whether incremental parsing is possible and which chunk to re-parse.
 *
 * edit_start/edit_end are byte offsets in the OLD source.
 */
fn EditAnalysis analyze_edit(ChunkMap* map, uint edit_start, uint edit_end) {
	EditAnalysis result;
	result.needs_full_reparse = false;
	result.found_chunk = false;
	result.found_member = false;

	// Edit in preamble region -> full re-parse
	if (edit_start < map.preamble_end_byte) {
		result.needs_full_reparse = true;
		return result;
	}

	// Find which chunk(s) the edit overlaps
	usz first_chunk = MAX_CHUNKS;
	usz last_chunk = 0;
	usz overlap_count = 0;

	for (usz i = 0; i < map.chunk_count; i++) {
		Chunk* c = &map.chunks[i];
		// Check if edit overlaps this chunk
		if (edit_start < c.byte_end && edit_end > c.byte_start) {
			if (first_chunk == MAX_CHUNKS) first_chunk = i;
			last_chunk = i;
			overlap_count++;
		}
	}

	// Edit between chunks or spanning multiple -> full re-parse
	if (overlap_count == 0 || overlap_count > 1) {
		result.needs_full_reparse = true;
		return result;
	}

	result.found_chunk = true;
	result.chunk_idx = first_chunk;

	// Two-level: check if edit is within a single class member
	Chunk* chunk = &map.chunks[first_chunk];
	if (chunk.member_count > 0) {
		usz first_member = MAX_MEMBER_CHUNKS;
		usz last_member = 0;
		usz member_overlap = 0;

		for (usz j = 0; j < chunk.member_count; j++) {
			MemberChunk* mc = &chunk.members[j];
			if (edit_start < mc.byte_end && edit_end > mc.byte_start) {
				if (first_member == MAX_MEMBER_CHUNKS) first_member = j;
				last_member = j;
				member_overlap++;
			}
		}

		if (member_overlap == 1) {
			result.found_member = true;
			result.member_idx = first_member;
		}
		// member_overlap > 1 or 0: re-parse whole class chunk (still incremental at L1)
	}

	return result;
}

// ── Incremental re-parse ───────────────────────────────────────────

/**
 * Attempt incremental re-parse after an edit. Returns true if successful,
 * false if a full re-parse is needed.
 *
 * Parameters:
 *   result       - the existing ParseResult (modified in place on success)
 *   map          - the existing ChunkMap (updated on success)
 *   old_source   - the source BEFORE the edit
 *   new_source   - the source AFTER the edit
 *   edit_start   - byte offset where edit begins (in old source)
 *   edit_end     - byte offset where edit ends (in old source, exclusive)
 *   new_text_len - length of the replacement text
 */
fn bool try_incremental_reparse(ParseResult* result, ChunkMap* map,
		String old_source, String new_source,
		uint edit_start, uint edit_end, usz new_text_len) {
	int byte_delta = (int)new_text_len - (int)(edit_end - edit_start);

	EditAnalysis analysis = analyze_edit(map, edit_start, edit_end);

	if (analysis.needs_full_reparse || !analysis.found_chunk) {
		return false;
	}

	// Determine the reparse region
	uint reparse_byte_start;
	uint reparse_byte_end_old;  // in old source
	uint reparse_node_start;
	uint reparse_node_end;
	uint reparse_line_start;
	uint reparse_line_end_old;

	if (analysis.found_member) {
		// Two-level: re-parse just the affected member
		Chunk* chunk = &map.chunks[analysis.chunk_idx];
		MemberChunk* mc = &chunk.members[analysis.member_idx];
		reparse_byte_start = mc.byte_start;
		reparse_byte_end_old = mc.byte_end;
		reparse_node_start = mc.node_start;
		reparse_node_end = mc.node_end;
		reparse_line_start = mc.line_start;
		reparse_line_end_old = mc.line_end;
	} else {
		// Level 1: re-parse the whole top-level declaration
		Chunk* chunk = &map.chunks[analysis.chunk_idx];
		reparse_byte_start = chunk.byte_start;
		reparse_byte_end_old = chunk.byte_end;
		reparse_node_start = chunk.node_start;
		reparse_node_end = chunk.node_end;
		reparse_line_start = chunk.line_start;
		reparse_line_end_old = chunk.line_end;
	}

	// Compute the new byte end in the new source
	uint reparse_byte_end_new = (uint)((int)reparse_byte_end_old + byte_delta);

	// Safety: if the reparsed region extends beyond source, bail
	if (reparse_byte_end_new > (uint)new_source.len) {
		return false;
	}

	// Count lines in old edit region to compute line delta
	int old_newlines = count_newlines(old_source, edit_start, edit_end);
	int new_newlines = count_newlines(new_source, edit_start, edit_start + (uint)new_text_len);
	int line_delta = new_newlines - old_newlines;

	// Compute column delta (only relevant when line_delta == 0)
	int col_delta = byte_delta; // simplified: same as byte delta on same line
	uint edit_end_line = reparse_line_end_old; // line where edit ends in old source

	// ── Re-parse the affected region ───────────────────────────────

	// Use a temporary ParseResult on the heap for the re-parsed chunk
	ParseResult* temp = mem::new(ParseResult);
	defer mem::free(temp);
	temp.node_count = 0;
	temp.error_count = 0;

	// Determine the parent node for the re-parsed declaration(s)
	uint parent_idx;
	if (analysis.found_member) {
		// Parent is the class node
		parent_idx = map.chunks[analysis.chunk_idx].node_start;
	} else {
		// Parent is the FILE node (index 0)
		parent_idx = 0;
	}

	// Parse the chunk region from the new source
	bool parse_ok = reparse_region(new_source, temp,
		reparse_byte_start, reparse_byte_end_new,
		reparse_line_start, analysis.found_member);

	if (!parse_ok) {
		temp.free_errors();
		return false;
	}

	// ── Splice the new nodes into the existing result ──────────────

	uint old_chunk_node_count = reparse_node_end - reparse_node_start;
	uint new_chunk_node_count = temp.node_count;
	int node_delta = (int)new_chunk_node_count - (int)old_chunk_node_count;

	// Check we won't exceed max nodes
	int new_total = (int)result.node_count + node_delta;
	if (new_total < 0 || new_total >= (int)ast::OVERFLOW_NODE) {
		temp.free_errors();
		return false;
	}

	// Free old error messages from the main result that came from the old chunk
	// (We can't easily attribute errors to chunks, so we clear all and re-add)
	result.free_errors();

	// Step 1: Move nodes after the old chunk to make room (or close gap)
	uint after_start = reparse_node_end;
	uint after_count = result.node_count - reparse_node_end;
	uint new_after_start = (uint)((int)reparse_node_start + (int)new_chunk_node_count);

	if (after_count > 0 && node_delta != 0) {
		result.move_nodes(new_after_start, after_start, after_count);
	}

	// Step 2: Copy re-parsed nodes into the gap
	for (uint i = 0; i < new_chunk_node_count; i++) {
		result.nodes[reparse_node_start + i] = temp.nodes[i];
	}

	// Step 3: Update node_count
	result.node_count = (uint)new_total;

	// Step 4: Fix parent indices in the newly inserted nodes
	// The temp result has parent indices relative to temp (0-based).
	// We need to offset them by reparse_node_start and reconnect to the
	// parent in the main tree.
	for (uint i = reparse_node_start; i < reparse_node_start + new_chunk_node_count; i++) {
		AstNode* n = &result.nodes[i];
		if (n.parent == ast::NO_PARENT) {
			// Top-level node of this chunk -> connect to parent (FILE or class)
			n.parent = parent_idx;
		} else {
			// Internal node -> offset parent index
			n.parent = n.parent + reparse_node_start;
		}
		// Offset children_start too
		if (n.child_count > 0) {
			n.children_start = n.children_start + reparse_node_start;
		}
	}

	// Step 5: Fix parent indices and children_start in nodes AFTER the splice
	if (node_delta != 0 && after_count > 0) {
		// Nodes that were moved need their own parent/children_start adjusted
		// if they pointed within or after the old chunk region
		for (uint i = new_after_start; i < result.node_count; i++) {
			AstNode* n = &result.nodes[i];
			if (n.parent != ast::NO_PARENT) {
				if (n.parent >= reparse_node_end) {
					// Parent was after the old chunk -> shift by node_delta
					n.parent = (uint)((int)n.parent + node_delta);
				}
				// Parents pointing INTO the old chunk are now invalid.
				// But they should only point to the class/file node which
				// is before the chunk, so this shouldn't happen.
			}
			if (n.child_count > 0 && n.children_start >= reparse_node_end) {
				n.children_start = (uint)((int)n.children_start + node_delta);
			}
		}

		// Also fix references from nodes BEFORE the chunk that point after it
		for (uint i = 0; i < reparse_node_start; i++) {
			AstNode* n = &result.nodes[i];
			if (n.child_count > 0 && n.children_start >= reparse_node_end) {
				n.children_start = (uint)((int)n.children_start + node_delta);
			}
		}
	}

	// Step 6: Update the parent node's child_count
	// Recount direct children of the parent
	if (parent_idx < result.node_count) {
		uint child_count = 0;
		uint first_child = result.node_count; // sentinel
		for (uint i = 0; i < result.node_count; i++) {
			if (i == parent_idx) continue;
			if (result.nodes[i].parent == parent_idx) {
				child_count++;
				if (i < first_child) first_child = i;
			}
		}
		result.nodes[parent_idx].child_count = child_count;
		if (child_count > 0) {
			result.nodes[parent_idx].children_start = first_child;
		}
	}

	// Step 7: Shift byte/line/col offsets for nodes AFTER the re-parsed region
	if (byte_delta != 0 || line_delta != 0) {
		result.shift_offsets(new_after_start, result.node_count,
			byte_delta, line_delta, col_delta, edit_end_line);
	}

	// Step 8: Copy errors from temp to result
	for (usz i = 0; i < temp.error_count && result.error_count < ast::MAX_ERRORS; i++) {
		result.errors[result.error_count] = temp.errors[i];
		// The error message was heap-copied by the parser, so ownership transfers
		result.error_count++;
	}

	// Step 9: Re-run a quick error pass on the rest of the file to recollect
	// errors from unchanged regions. We skip this for now -- errors from
	// unchanged regions were cleared. The diagnostics module will re-run
	// the lexer anyway, and parser errors will come from the next full
	// diagnostics pass. For now, the incremental result has errors only
	// from the re-parsed chunk.

	// Step 10: Update the chunk map
	update_chunk_map_after_edit(result, map, new_source, analysis,
		byte_delta, line_delta, node_delta,
		reparse_node_start, new_chunk_node_count);

	return true;
}

// ── Re-parse a region of source ────────────────────────────────────

/**
 * Parse a single region of source into a temporary ParseResult.
 * The region is [byte_start..byte_end) in the source string.
 *
 * If is_member is true, parses as a class member (single declaration).
 * If is_member is false, parses as a top-level declaration.
 *
 * Returns true on success.
 */
fn bool reparse_region(String source, ParseResult* temp,
		uint byte_start, uint byte_end,
		uint line_start, bool is_member) {
	if (byte_start >= byte_end || byte_end > (uint)source.len) {
		return false;
	}

	// Use the chunk-level parser entry points
	parser::parse_chunk(source, temp, byte_start, byte_end, line_start);
	return true;
}

// ── Chunk map update ───────────────────────────────────────────────

fn void update_chunk_map_after_edit(ParseResult* result, ChunkMap* map, String new_source,
		EditAnalysis analysis, int byte_delta, int line_delta, int node_delta,
		uint new_node_start, uint new_node_count) {
	// Update the affected chunk's boundaries
	if (analysis.found_chunk && analysis.chunk_idx < map.chunk_count) {
		Chunk* chunk = &map.chunks[analysis.chunk_idx];

		if (analysis.found_member) {
			// Update the member chunk
			MemberChunk* mc = &chunk.members[analysis.member_idx];
			mc.byte_end = (uint)((int)mc.byte_end + byte_delta);
			mc.line_end = (uint)((int)mc.line_end + line_delta);
			mc.node_start = new_node_start;
			mc.node_end = new_node_start + new_node_count;

			// Shift subsequent member chunks
			for (usz j = analysis.member_idx + 1; j < chunk.member_count; j++) {
				MemberChunk* m = &chunk.members[j];
				m.byte_start = (uint)((int)m.byte_start + byte_delta);
				m.byte_end = (uint)((int)m.byte_end + byte_delta);
				m.line_start = (uint)((int)m.line_start + line_delta);
				m.line_end = (uint)((int)m.line_end + line_delta);
				m.node_start = (uint)((int)m.node_start + node_delta);
				m.node_end = (uint)((int)m.node_end + node_delta);
			}

			// Update parent chunk end
			chunk.byte_end = (uint)((int)chunk.byte_end + byte_delta);
			chunk.line_end = (uint)((int)chunk.line_end + line_delta);
			chunk.node_end = (uint)((int)chunk.node_end + node_delta);
		} else {
			// Rebuild chunk from the re-parsed nodes
			if (new_node_count > 0) {
				AstNode* first = &result.nodes[new_node_start];
				AstNode* last = &result.nodes[new_node_start + new_node_count - 1];
				chunk.byte_start = first.start_offset;
				chunk.byte_end = last.end_offset;
				chunk.line_start = first.start_line;
				chunk.line_end = last.end_line;
			}
			chunk.node_start = new_node_start;
			chunk.node_end = new_node_start + new_node_count;

			// Rebuild member chunks if class-like
			chunk.member_count = 0;
			if (new_node_count > 0 && ast::is_class_like(result.nodes[new_node_start].kind)) {
				build_member_chunks(result, new_node_start, chunk);
			}
		}

		// Shift subsequent top-level chunks
		for (usz i = analysis.chunk_idx + 1; i < map.chunk_count; i++) {
			Chunk* c = &map.chunks[i];
			c.byte_start = (uint)((int)c.byte_start + byte_delta);
			c.byte_end = (uint)((int)c.byte_end + byte_delta);
			c.line_start = (uint)((int)c.line_start + line_delta);
			c.line_end = (uint)((int)c.line_end + line_delta);
			c.node_start = (uint)((int)c.node_start + node_delta);
			c.node_end = (uint)((int)c.node_end + node_delta);

			// Also shift member chunks within
			for (usz j = 0; j < c.member_count; j++) {
				MemberChunk* m = &c.members[j];
				m.byte_start = (uint)((int)m.byte_start + byte_delta);
				m.byte_end = (uint)((int)m.byte_end + byte_delta);
				m.line_start = (uint)((int)m.line_start + line_delta);
				m.line_end = (uint)((int)m.line_end + line_delta);
				m.node_start = (uint)((int)m.node_start + node_delta);
				m.node_end = (uint)((int)m.node_end + node_delta);
			}
		}
	}
}

// ── Utilities ──────────────────────────────────────────────────────

/**
 * Count newline characters in source[start..end).
 */
fn int count_newlines(String source, uint start, uint end) {
	int count = 0;
	uint e = end > (uint)source.len ? (uint)source.len : end;
	for (uint i = start; i < e; i++) {
		if (source[i] == '\n') count++;
	}
	return count;
}
