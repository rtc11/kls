module kls::lsp::formatting;

import std::collections::object;
import kls::document;

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

	// Format the content
	String formatted = format_content(content, tab_size, insert_spaces,
		trim_trailing_whitespace, insert_final_newline, trim_final_newlines);

	// If nothing changed, return empty array (no edits)
	if (formatted == content) {
		return null;
	}

	return build_whole_doc_edit(content, formatted);
}

// ── Core formatting logic ────────────────────────────────────────

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

	while (i <= content.len) {
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
