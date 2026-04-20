module kls::lsp::formatting;

import std::collections::object;
import kls::document;
import kls::kotlin::ast;
import kls::log;

/**
 * Handle textDocument/formatting request.
 *
 * Applies basic whitespace normalization to the entire document:
 *   1. Trailing whitespace removal (spaces/tabs before newlines)
 *   2. Indentation normalization (tabs <-> spaces per client options)
 *   3. Collapse 3+ consecutive blank lines to 2
 *   4. Trim trailing blank lines at end of file (keep at most 1)
 *   5. Ensure final newline
 *
 * Returns a JSON array of TextEdit objects (single whole-document edit),
 * or null if the document is unknown or no changes are needed.
 *
 * Params: {
 *   textDocument: { uri },
 *   options: { tabSize: int, insertSpaces: bool, ... }
 * }
 */
fn Object* handle_formatting(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Parse formatting options
	int tab_size = 4;
	bool insert_spaces = true;
	bool trim_trailing_whitespace = true;
	bool insert_final_newline = true;
	bool trim_final_newlines = true;

	if (try opts = params.get("options")) {
		if (try ts = opts.get_int("tabSize")) {
			tab_size = ts;
		}
		if (try is_obj = opts.get("insertSpaces")) {
			if (is_obj.is_bool()) {
				insert_spaces = is_obj.b;
			}
		}
		if (try ttw = opts.get("trimTrailingWhitespace")) {
			if (ttw.is_bool()) {
				trim_trailing_whitespace = ttw.b;
			}
		}
		if (try ifn = opts.get("insertFinalNewline")) {
			if (ifn.is_bool()) {
				insert_final_newline = ifn.b;
			}
		}
		if (try tfn = opts.get("trimFinalNewlines")) {
			if (tfn.is_bool()) {
				trim_final_newlines = tfn.b;
			}
		}
	}

	String content = doc.content;
	if (content.len == 0) {
		if (insert_final_newline) {
			return build_whole_doc_edit(content, "\n");
		}
		return null;
	}

	// Try AST-aware formatting first (proper indentation)
	ParseResult* pr = store.get_ast(uri) ?? null;
	String formatted;
	if (pr != null && pr.node_count > 0) {
		formatted = format_content_with_ast(content, pr, tab_size, insert_spaces,
			trim_trailing_whitespace, insert_final_newline, trim_final_newlines);
	} else {
		formatted = format_content(content, tab_size, insert_spaces,
			trim_trailing_whitespace, insert_final_newline, trim_final_newlines);
	}

	// If nothing changed, return empty array (no edits)
	if (formatted == content) {
		return null;
	}

	return build_whole_doc_edit(content, formatted);
}

/**
 * Handle textDocument/rangeFormatting request.
 *
 * Applies whitespace normalization only to lines within the given range:
 *   1. Trailing whitespace removal
 *   2. Indentation normalization (tabs <-> spaces per client options)
 *   3. Collapse 3+ consecutive blank lines to 2 (within range)
 *
 * Does NOT apply document-level rules (final newline, trim final newlines).
 *
 * Params: {
 *   textDocument: { uri },
 *   range: { start: { line, character }, end: { line, character } },
 *   options: { tabSize: int, insertSpaces: bool, ... }
 * }
 */
fn Object* handle_range_formatting(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Parse range
	Object* range_obj = params.get("range")!!;
	Object* start_obj = range_obj.get("start")!!;
	Object* end_obj = range_obj.get("end")!!;
	uint start_line = (uint)start_obj.get_int("line")!!;
	uint end_line = (uint)end_obj.get_int("line")!!;

	// Parse formatting options
	int tab_size = 4;
	bool insert_spaces = true;
	bool trim_trailing_whitespace = true;

	if (try opts = params.get("options")) {
		if (try ts = opts.get_int("tabSize")) {
			tab_size = ts;
		}
		if (try is_obj = opts.get("insertSpaces")) {
			if (is_obj.is_bool()) {
				insert_spaces = is_obj.b;
			}
		}
		if (try ttw = opts.get("trimTrailingWhitespace")) {
			if (ttw.is_bool()) {
				trim_trailing_whitespace = ttw.b;
			}
		}
	}

	String content = doc.content;
	if (content.len == 0) {
		return null;
	}

	// Find byte offsets for the range lines
	// We format full lines: start_line..end_line inclusive
	usz range_start = 0;
	usz range_end = content.len;
	uint current_line = 0;
	usz line_start = 0;

	for (usz i = 0; i <= content.len; i++) {
		if (i == content.len || content[i] == '\n') {
			if (current_line == start_line) {
				range_start = line_start;
			}
			if (current_line == end_line) {
				range_end = i;
				if (i < content.len) range_end++; // include the \n
				break;
			}
			current_line++;
			line_start = i + 1;
		}
	}

	if (range_start >= range_end) return null;

	String range_text = content[range_start..range_end - 1];

	// Get AST for indent-level computation
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Format lines within the range (AST-aware if AST available)
	String formatted;
	if (pr != null) {
		formatted = format_range_with_ast(content, range_start, range_end,
			pr, tab_size, insert_spaces, trim_trailing_whitespace);
	} else {
		formatted = format_range_content(range_text, tab_size, insert_spaces,
			trim_trailing_whitespace);
	}

	if (formatted == range_text) {
		return null;
	}

	// Build edit for just the range
	// Calculate end position
	uint fmt_end_line = end_line;
	uint fmt_end_char = 0;
	// Walk to find the end character of end_line
	usz walk_pos = 0;
	uint walk_line = 0;
	for (usz i = 0; i <= content.len; i++) {
		if (walk_line == end_line) {
			walk_pos = i;
			break;
		}
		if (i < content.len && content[i] == '\n') {
			walk_line++;
		}
	}
	// Find end of end_line
	usz eol = walk_pos;
	while (eol < content.len && content[eol] != '\n') {
		eol++;
	}
	fmt_end_char = (uint)(eol - walk_pos);

	// If range_end includes the \n, the edit goes to start of next line
	bool includes_final_newline = range_end <= content.len && range_end > 0 && content[range_end - 1] == '\n';
	if (includes_final_newline) {
		fmt_end_line = end_line + 1;
		fmt_end_char = 0;
	}

	Object* start_pos = object::new_obj(tmem);
	start_pos.set("line", (int)start_line);
	start_pos.set("character", 0);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)fmt_end_line);
	end_pos.set("character", (int)fmt_end_char);

	Object* range = object::new_obj(tmem);
	range.set("start", start_pos);
	range.set("end", end_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", formatted);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	return edits;
}

/**
 * Format content within a range. Like format_content but:
 * - No final newline enforcement
 * - No trim final newlines
 * - Still collapses 3+ blank lines to 2
 */
fn String format_range_content(String content, int tab_size, bool insert_spaces,
		bool trim_trailing_whitespace) {
	DString out;
	out.tinit();

	usz i = 0;
	int consecutive_blank_lines = 0;

	while (i < content.len) {
		usz line_start = i;
		usz line_end = i;
		while (line_end < content.len && content[line_end] != '\n') {
			line_end++;
		}

		String line_content = content[line_start..line_end - 1];
		bool has_newline = (line_end < content.len);

		String trimmed = line_content;
		if (trim_trailing_whitespace) {
			trimmed = trim_trailing_ws(line_content);
		}

		trimmed = normalize_indent(trimmed, tab_size, insert_spaces);

		bool is_blank = is_blank_line(trimmed);
		if (is_blank) {
			consecutive_blank_lines++;
		} else {
			consecutive_blank_lines = 0;
		}

		if (is_blank && consecutive_blank_lines > 2) {
			i = line_end;
			if (has_newline) i++;
			continue;
		}

		out.append(trimmed);
		if (has_newline) {
			out.append_char('\n');
		}

		i = line_end;
		if (has_newline) i++;
		if (!has_newline) break;
	}

	return out.str_view();
}

// ── AST-aware range formatting ───────────────────────────────────

/**
 * Compute the nesting depth of a byte offset in the AST.
 * Counts scope-like nodes (class body, function body, block, etc.)
 * that contain the offset. Returns the depth (0 = top-level).
 */
fn int compute_indent_depth(ParseResult* ast, usz offset) {
	int depth = 0;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		// Count nodes that create indentation scopes.
		// Class-like declarations (CLASS_DECL, INTERFACE_DECL, OBJECT_DECL,
		// COMPANION_OBJECT_DECL) contain members directly without a BLOCK,
		// so we count them. FUN_DECL/FOR_STMT/etc. contain a BLOCK child
		// for their body, so we count BLOCK instead to avoid double-counting.
		switch (n.kind) {
			case CLASS_DECL:
			case INTERFACE_DECL:
			case OBJECT_DECL:
			case COMPANION_OBJECT_DECL:
			case INIT_BLOCK:
			case BLOCK:
			case LAMBDA_EXPR:
			case WHEN_EXPR:
				if (offset >= n.start_offset && offset < n.end_offset) {
					// Only count if offset is past the opening line
					// (we don't indent the line with the opening brace itself)
					if (n.start_line != get_line_at_offset(ast, offset)) {
						depth++;
					}
				}
			default:
				break;
		}
	}
	return depth;
}

/**
 * Get the 0-based line number for a byte offset by checking AST nodes
 * or scanning the content. Uses a simple scan approach.
 */
fn uint get_line_at_offset(ParseResult* ast, usz offset) {
	// Find node closest to offset for its line info
	// Simple: look for any node whose start_offset <= offset and is closest
	uint best_line = 0;
	usz best_dist = offset + 1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.start_offset <= offset) {
			usz dist = offset - n.start_offset;
			if (dist < best_dist) {
				best_dist = dist;
				best_line = n.start_line;
			}
		}
	}
	return best_line;
}

/**
 * Format a range using AST-derived indentation levels.
 * For each line in the range, compute expected indent depth from AST
 * nesting, then re-indent to that depth.
 */
fn String format_range_with_ast(String content, usz range_start, usz range_end,
		ParseResult* ast, int tab_size, bool insert_spaces,
		bool trim_trailing_whitespace) {
	DString out;
	out.tinit();

	usz i = range_start;
	int consecutive_blank_lines = 0;

	while (i < range_end) {
		usz line_start = i;
		usz line_end = i;
		while (line_end < range_end && content[line_end] != '\n') {
			line_end++;
		}

		String line_content = content[line_start..line_end - 1];
		bool has_newline = (line_end < range_end);

		// Trim trailing whitespace
		String trimmed = line_content;
		if (trim_trailing_whitespace) {
			trimmed = trim_trailing_ws(line_content);
		}

		// Get the non-whitespace content
		String stripped = strip_leading_ws(trimmed);

		bool is_blank = stripped.len == 0;
		if (is_blank) {
			consecutive_blank_lines++;
		} else {
			consecutive_blank_lines = 0;
		}

		if (is_blank && consecutive_blank_lines > 2) {
			i = line_end;
			if (has_newline) i++;
			continue;
		}

		if (is_blank) {
			// Blank line: no indent
			out.append("");
		} else {
			// Compute expected indent from AST
			// Use the offset of the first non-ws char on this line
			usz first_nonws_offset = line_start;
			while (first_nonws_offset < line_end &&
				(content[first_nonws_offset] == ' ' || content[first_nonws_offset] == '\t')) {
				first_nonws_offset++;
			}

			int depth = compute_indent_depth(ast, first_nonws_offset);

			// Closing braces/brackets reduce depth by 1
			if (stripped.len > 0 && (stripped[0] == '}' || stripped[0] == ')')) {
				if (depth > 0) depth--;
			}

			// Build indent string
			build_indent(&out, depth, tab_size, insert_spaces);
			out.append(stripped);
		}

		if (has_newline) {
			out.append_char('\n');
		}

		i = line_end;
		if (has_newline) i++;
		if (!has_newline) break;
	}

	return out.str_view();
}

// ── AST-aware whole-document formatting ──────────────────────────

/**
 * Format entire document content using AST-derived indentation.
 * Combines AST indent computation with whitespace normalization
 * (trailing ws, blank line collapsing, final newline).
 */
fn String format_content_with_ast(String content, ParseResult* ast,
		int tab_size, bool insert_spaces, bool trim_trailing_whitespace,
		bool insert_final_newline, bool trim_final_newlines) {
	DString out;
	out.tinit();

	usz i = 0;
	int consecutive_blank_lines = 0;

	while (i < content.len) {
		usz line_start = i;
		usz line_end = i;
		while (line_end < content.len && content[line_end] != '\n') {
			line_end++;
		}

		String line_content = content[line_start..line_end - 1];
		bool has_newline = (line_end < content.len);

		// Trim trailing whitespace
		String trimmed = line_content;
		if (trim_trailing_whitespace) {
			trimmed = trim_trailing_ws(line_content);
		}

		// Get non-whitespace content
		String stripped = strip_leading_ws(trimmed);

		bool is_blank = stripped.len == 0;
		if (is_blank) {
			consecutive_blank_lines++;
		} else {
			consecutive_blank_lines = 0;
		}

		// Collapse 3+ consecutive blank lines to 2
		if (is_blank && consecutive_blank_lines > 2) {
			i = line_end;
			if (has_newline) i++;
			continue;
		}

		if (is_blank) {
			// Blank line: no indent
		} else {
			// Compute expected indent from AST
			usz first_nonws_offset = line_start;
			while (first_nonws_offset < line_end &&
				(content[first_nonws_offset] == ' ' || content[first_nonws_offset] == '\t')) {
				first_nonws_offset++;
			}

			int depth = compute_indent_depth(ast, first_nonws_offset);

			// Closing braces/brackets reduce depth by 1
			if (stripped.len > 0 && (stripped[0] == '}' || stripped[0] == ')')) {
				if (depth > 0) depth--;
			}

			build_indent(&out, depth, tab_size, insert_spaces);
			out.append(stripped);
		}

		if (has_newline) {
			out.append_char('\n');
		}

		i = line_end;
		if (has_newline) i++;
		if (!has_newline) break;
	}

	String result = out.str_view();

	// Trim trailing blank lines
	if (trim_final_newlines && result.len > 0) {
		usz end = result.len;
		usz last_content = end;
		while (last_content > 0) {
			char c = result[last_content - 1];
			if (c != '\n' && c != ' ' && c != '\t' && c != '\r') {
				break;
			}
			last_content--;
		}
		if (last_content < end) {
			DString trimmed_result;
			trimmed_result.tinit();
			if (last_content > 0) {
				trimmed_result.append(result[:last_content]);
			}
			if (insert_final_newline) {
				trimmed_result.append_char('\n');
			}
			return trimmed_result.str_view();
		}
	}

	// Ensure final newline
	if (insert_final_newline && result.len > 0 && result[result.len - 1] != '\n') {
		DString with_nl;
		with_nl.tinit();
		with_nl.append(result);
		with_nl.append_char('\n');
		return with_nl.str_view();
	}

	return result;
}

/**
 * Append indent characters to a DString.
 */
fn void build_indent(DString* out, int depth, int tab_size, bool insert_spaces) {
	if (insert_spaces) {
		int total = depth * tab_size;
		for (int j = 0; j < total; j++) {
			out.append_char(' ');
		}
	} else {
		for (int j = 0; j < depth; j++) {
			out.append_char('\t');
		}
	}
}

/**
 * Strip leading whitespace from a string.
 */
fn String strip_leading_ws(String s) {
	usz i = 0;
	while (i < s.len && (s[i] == ' ' || s[i] == '\t')) {
		i++;
	}
	if (i >= s.len) return "";
	return s[i..];
}

/**
 * Format the content string, returning a new temp-allocated string.
 * Processes line-by-line for straightforward whitespace normalization.
 */
fn String format_content(String content, int tab_size, bool insert_spaces,
		bool trim_trailing_whitespace, bool insert_final_newline,
		bool trim_final_newlines) {
	DString out;
	out.tinit();

	// Process line by line
	usz i = 0;
	int consecutive_blank_lines = 0;

	while (i < content.len) {
		// Find end of current line
		usz line_start = i;
		usz line_end = i;
		while (line_end < content.len && content[line_end] != '\n') {
			line_end++;
		}

		// line_end now points to '\n' or end of content
		String line_content = content[line_start..line_end - 1]; // excluding \n
		bool has_newline = (line_end < content.len);

		// Trim trailing whitespace from the line
		String trimmed = line_content;
		if (trim_trailing_whitespace) {
			trimmed = trim_trailing_ws(line_content);
		}

		// Normalize indentation
		trimmed = normalize_indent(trimmed, tab_size, insert_spaces);

		// Track blank lines
		bool is_blank = is_blank_line(trimmed);
		if (is_blank) {
			consecutive_blank_lines++;
		} else {
			consecutive_blank_lines = 0;
		}

		// Collapse 3+ consecutive blank lines to 2
		if (is_blank && consecutive_blank_lines > 2) {
			// Skip this blank line entirely
			i = line_end;
			if (has_newline) i++;
			continue;
		}

		out.append(trimmed);
		if (has_newline) {
			out.append_char('\n');
		}

		i = line_end;
		if (has_newline) i++;
		if (!has_newline) break;
	}

	String result = out.str_view();

	// Trim trailing blank lines (keep at most 1 newline at end)
	if (trim_final_newlines && result.len > 0) {
		usz end = result.len;
		// Walk backwards past blank lines, keeping content
		// Find the last non-whitespace character
		usz last_content = end;
		while (last_content > 0) {
			char c = result[last_content - 1];
			if (c != '\n' && c != ' ' && c != '\t' && c != '\r') {
				break;
			}
			last_content--;
		}
		// Keep up to last_content, then add exactly one newline
		if (last_content < end) {
			DString trimmed;
			trimmed.tinit();
			if (last_content > 0) {
				trimmed.append(result[:last_content]);
			}
			if (insert_final_newline) {
				trimmed.append_char('\n');
			}
			return trimmed.str_view();
		}
	}

	// Ensure final newline
	if (insert_final_newline && result.len > 0 && result[result.len - 1] != '\n') {
		DString with_nl;
		with_nl.tinit();
		with_nl.append(result);
		with_nl.append_char('\n');
		return with_nl.str_view();
	}

	return result;
}

// ── Line helpers ─────────────────────────────────────────────────

/**
 * Trim trailing spaces and tabs from a line (not including newline).
 */
fn String trim_trailing_ws(String line) {
	usz end = line.len;
	while (end > 0) {
		char c = line[end - 1];
		if (c != ' ' && c != '\t' && c != '\r') break;
		end--;
	}
	if (end == line.len) return line;
	if (end == 0) return "";
	return line[:end];
}

/**
 * Check if a line is blank (only whitespace).
 */
fn bool is_blank_line(String line) {
	for (usz i = 0; i < line.len; i++) {
		char c = line[i];
		if (c != ' ' && c != '\t' && c != '\r') return false;
	}
	return true;
}

/**
 * Normalize leading indentation of a line.
 * If insertSpaces is true: convert leading tabs to spaces (tab_size each).
 * If insertSpaces is false: convert leading space groups to tabs.
 * Mixed indent (tabs then spaces, or vice versa) is normalized.
 */
fn String normalize_indent(String line, int tab_size, bool insert_spaces) {
	if (line.len == 0) return line;

	// Measure the leading indentation width in columns
	usz indent_end = 0;
	int indent_width = 0;
	while (indent_end < line.len) {
		char c = line[indent_end];
		if (c == ' ') {
			indent_width++;
			indent_end++;
		} else if (c == '\t') {
			// Tab advances to next tab stop
			indent_width = indent_width + tab_size - (indent_width % tab_size);
			indent_end++;
		} else {
			break;
		}
	}

	// No indentation -- nothing to normalize
	if (indent_end == 0) return line;

	String rest = line[indent_end..];

	// Build the normalized indentation
	DString result;
	result.tinit();

	if (insert_spaces) {
		// All spaces
		for (int j = 0; j < indent_width; j++) {
			result.append_char(' ');
		}
	} else {
		// Convert to tabs + remaining spaces
		int tabs = indent_width / tab_size;
		int spaces = indent_width % tab_size;
		for (int j = 0; j < tabs; j++) {
			result.append_char('\t');
		}
		for (int j = 0; j < spaces; j++) {
			result.append_char(' ');
		}
	}
	result.append(rest);
	return result.str_view();
}

// ── TextEdit builder ─────────────────────────────────────────────

/**
 * Build a TextEdit array containing a single edit that replaces
 * the entire document content.
 */
fn Object* build_whole_doc_edit(String old_content, String new_content) {
	// Count lines in old content to get end position
	uint end_line = 0;
	uint end_char = 0;
	for (usz i = 0; i < old_content.len; i++) {
		if (old_content[i] == '\n') {
			end_line++;
			end_char = 0;
		} else {
			end_char++;
		}
	}

	// Build the range covering the entire document
	Object* start_pos = object::new_obj(tmem);
	start_pos.set("line", 0);
	start_pos.set("character", 0);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)end_line);
	end_pos.set("character", (int)end_char);

	Object* range = object::new_obj(tmem);
	range.set("start", start_pos);
	range.set("end", end_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", new_content);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	return edits;
}

// ── On-type formatting ───────────────────────────────────────────

/**
 * Handle textDocument/onTypeFormatting request.
 *
 * Trigger characters:
 *   '\n' — auto-indent new line (match prev indent, +1 after '{')
 *   '}'  — deindent closing brace to match opening level
 *
 * Params: {
 *   textDocument: { uri },
 *   position: { line, character },
 *   ch: string,
 *   options: { tabSize: int, insertSpaces: bool }
 * }
 */
fn Object* handle_on_type_formatting(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	String ch = params.get_string("ch") ?? "";
	if (ch.len == 0) return null;

	int tab_size = 4;
	bool insert_spaces = true;
	if (try opts = params.get("options")) {
		if (try ts = opts.get_int("tabSize")) tab_size = ts;
		if (try is_obj = opts.get("insertSpaces")) {
			if (is_obj.is_bool()) insert_spaces = is_obj.b;
		}
	}

	String content = doc.content;

	if (ch == "\n") {
		return on_type_newline(content, line, character, tab_size, insert_spaces);
	} else if (ch == "}") {
		return on_type_close_brace(content, line, character, tab_size, insert_spaces);
	}

	return null;
}

/**
 * After Enter, set indentation of new line.
 * If previous line ends with '{', add one indent level.
 */
fn Object* on_type_newline(String content, uint line, uint character,
		int tab_size, bool insert_spaces) {
	if (line == 0) return null;

	String prev_line = get_line(content, line - 1);
	String prev_trimmed = trim_trailing_ws(prev_line);

	int prev_indent = measure_indent_width(prev_line, tab_size);
	int target_indent = prev_indent;
	if (prev_trimmed.len > 0 && prev_trimmed[prev_trimmed.len - 1] == '{') {
		target_indent += tab_size;
	}

	String current_line = get_line(content, line);
	int current_indent = measure_indent_width(current_line, tab_size);

	if (current_indent == target_indent) return null;

	DString indent;
	indent.tinit();
	build_indent_string(&indent, target_indent, tab_size, insert_spaces);

	usz ws_end = 0;
	while (ws_end < current_line.len) {
		char c = current_line[ws_end];
		if (c != ' ' && c != '\t') break;
		ws_end++;
	}

	return build_line_indent_edit(line, ws_end, indent.str_view());
}

/**
 * After '}', deindent to match opening '{' indent level.
 * Only acts if '}' is the first non-whitespace on the line.
 */
fn Object* on_type_close_brace(String content, uint line, uint character,
		int tab_size, bool insert_spaces) {
	String current_line = get_line(content, line);

	// Only act if '}' is first non-ws char
	usz first_nonws = 0;
	while (first_nonws < current_line.len) {
		char c = current_line[first_nonws];
		if (c != ' ' && c != '\t') break;
		first_nonws++;
	}
	if (first_nonws >= current_line.len || current_line[first_nonws] != '}') return null;

	if (line == 0) return null;

	// Find matching '{' by scanning backwards
	int brace_depth = 1;
	int match_line = -1;

	for (int scan = (int)line - 1; scan >= 0; scan--) {
		String scan_line = get_line(content, (uint)scan);
		for (usz i = scan_line.len; i > 0; i--) {
			char c = scan_line[i - 1];
			if (c == '}') brace_depth++;
			if (c == '{') {
				brace_depth--;
				if (brace_depth == 0) {
					match_line = scan;
					break;
				}
			}
		}
		if (match_line >= 0) break;
	}

	if (match_line < 0) return null;

	String match_content = get_line(content, (uint)match_line);
	int target_indent = measure_indent_width(match_content, tab_size);
	int current_indent = measure_indent_width(current_line, tab_size);

	if (current_indent == target_indent) return null;

	DString indent;
	indent.tinit();
	build_indent_string(&indent, target_indent, tab_size, insert_spaces);

	usz ws_end = 0;
	while (ws_end < current_line.len) {
		char c = current_line[ws_end];
		if (c != ' ' && c != '\t') break;
		ws_end++;
	}

	return build_line_indent_edit(line, ws_end, indent.str_view());
}

/**
 * Build a TextEdit array replacing leading whitespace on a line.
 */
fn Object* build_line_indent_edit(uint line, usz ws_end, String new_indent) {
	Object* start_pos = object::new_obj(tmem);
	start_pos.set("line", (int)line);
	start_pos.set("character", 0);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)line);
	end_pos.set("character", (int)ws_end);

	Object* range = object::new_obj(tmem);
	range.set("start", start_pos);
	range.set("end", end_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", new_indent);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	return edits;
}

// ── On-type helpers ──────────────────────────────────────────────

/**
 * Get content of a specific line (0-based), without trailing newline.
 */
fn String get_line(String content, uint target_line) {
	uint current = 0;
	usz start = 0;

	for (usz i = 0; i <= content.len; i++) {
		if (i == content.len || content[i] == '\n') {
			if (current == target_line) {
				if (i > start) {
					return content[start..i - 1];
				}
				return "";
			}
			current++;
			start = i + 1;
		}
	}
	return "";
}

/**
 * Measure indentation width (in columns) of a line.
 */
fn int measure_indent_width(String line, int tab_size) {
	int width = 0;
	for (usz i = 0; i < line.len; i++) {
		char c = line[i];
		if (c == ' ') {
			width++;
		} else if (c == '\t') {
			width = width + tab_size - (width % tab_size);
		} else {
			break;
		}
	}
	return width;
}

/**
 * Build an indentation string of given width.
 */
fn void build_indent_string(DString* out, int width, int tab_size, bool insert_spaces) {
	if (insert_spaces) {
		for (int i = 0; i < width; i++) {
			out.append_char(' ');
		}
	} else {
		int tabs = width / tab_size;
		int spaces = width % tab_size;
		for (int i = 0; i < tabs; i++) {
			out.append_char('\t');
		}
		for (int i = 0; i < spaces; i++) {
			out.append_char(' ');
		}
	}
}
