module kls::deps::javadoc;

import std::io;
import std::compression::zip;
import kls::config;
import kls::deps::jar_index;
import kls::deps::source_nav;
import kls::lsp::hover;

// ── Javadoc extraction from source archives ───────────────────────
//
// Extracts Javadoc comments in real time from src.zip (JDK) or
// -sources.jar (Maven dependencies) when hovering on dependency
// symbols.  No pre-indexing — each hover request opens the archive,
// reads one source file, and extracts the doc comment preceding the
// target declaration.

faultdef NO_DOC;

// ── Public API ────────────────────────────────────────────────────

/**
 * Extract the Javadoc/KDoc for a dependency symbol by reading its
 * source file from src.zip or -sources.jar in real time.
 * Returns the cleaned doc text, or a fault if unavailable.
 * All allocations use tmem (caller's temp pool).
 */
fn String? extract_dep_doc(DepSymbol* sym) {
	if (sym == null) return NO_DOC~;
	if (!config::hover_docs_enabled()) return NO_DOC~;

	// 1. Derive the source archive path
	String source_path = source_nav::derive_source_jar_path(sym.jar_path);
	if (source_path.len == 0) {
		source_path = source_nav::derive_jdk_source_path(sym.jar_path);
	}
	if (source_path.len == 0) return NO_DOC~;

	// 2. Find the source entry in the archive
	String entry_name;
	if (try e = source_nav::find_source_entry_in_jar(source_path, sym.package_name, sym.class_name)) {
		entry_name = e;
	} else {
		return NO_DOC~;
	}

	// 3. Read the source file into memory (no disk write)
	ZipArchive archive;
	if (try a = zip::open(tmem, source_path, "r")) {
		archive = a;
	} else {
		return NO_DOC~;
	}
	defer archive.close()!!;

	char[] data;
	if (try d = archive.read_file_all(tmem, entry_name)) {
		data = d;
	} else {
		return NO_DOC~;
	}
	String content = (String)data;
	if (content.len == 0) return NO_DOC~;

	// 4. Find the symbol declaration in the source
	uint sym_line = 0;
	uint sym_col = 0;
	if (!source_nav::find_symbol_position(content, sym.name, sym.kind, &sym_line, &sym_col)) {
		return NO_DOC~;
	}

	// 5. Convert (line, col) to byte offset
	uint offset = line_col_to_offset(content, sym_line, sym_col);
	if (offset == 0 && (sym_line > 0 || sym_col > 0)) return NO_DOC~;

	// 6. Scan backward to find the declaration keyword start
	//    find_symbol_position returns the position of the symbol name,
	//    but extract_doc_comment needs the start of the declaration
	//    (including modifiers). Walk backward to find the line start
	//    to capture annotations and modifiers above.
	uint decl_start = find_declaration_start(content, offset);

	// 7. Extract the doc comment using the existing hover infrastructure
	if (try raw_doc = hover::extract_doc_comment(content, decl_start)) {
		if (raw_doc.len == 0) return NO_DOC~;
		// 8. Clean Javadoc HTML to markdown
		return clean_javadoc(raw_doc);
	}

	return NO_DOC~;
}

// ── Line/col to byte offset ───────────────────────────────────────

/**
 * Convert a 0-based (line, col) position to a byte offset in the
 * source string. Returns 0 if the position is out of bounds.
 */
fn uint line_col_to_offset(String content, uint target_line, uint target_col) {
	uint current_line = 0;
	usz i = 0;

	while (i < content.len && current_line < target_line) {
		if (content[i] == '\n') {
			current_line++;
		}
		i++;
	}

	// Now at the start of target_line, add column offset
	usz result = i + (usz)target_col;
	if (result > content.len) return 0;
	return (uint)result;
}

// ── Find declaration start ────────────────────────────────────────

/**
 * Given the byte offset of a symbol name, walk backward to find the
 * start of the full declaration line (including modifiers like
 * "public static native"). We walk back to the first non-blank
 * character after a newline or the start of the file.
 *
 * This handles Java declarations like:
 *   public static native long nanoTime();
 * where the symbol name is at the end but extract_doc_comment needs
 * to start scanning from before "public".
 */
fn uint find_declaration_start(String content, uint name_offset) {
	if (name_offset == 0) return 0;

	usz pos = (usz)name_offset;

	// Walk backward to the beginning of the line
	while (pos > 0 && content[pos - 1] != '\n') {
		pos--;
	}

	// Now pos is at the start of the line containing the symbol.
	// However, Java declarations can have annotations on previous lines:
	//   @IntrinsicCandidate
	//   public static native long nanoTime();
	//
	// Walk further back over annotation lines and blank lines.
	while (pos > 0) {
		// Find the start of the previous line
		usz prev_end = pos;
		if (prev_end > 0) prev_end--;  // skip the newline char

		// Skip trailing CR
		if (prev_end > 0 && content[prev_end] == '\r') prev_end--;

		usz prev_start = prev_end;
		while (prev_start > 0 && content[prev_start - 1] != '\n') {
			prev_start--;
		}

		// Check if the previous line starts with '@' (annotation) after whitespace
		String prev_line;
		if (prev_end >= prev_start) {
			prev_line = content[prev_start..prev_end];
		} else {
			break;
		}

		// Trim leading whitespace
		usz ws = 0;
		while (ws < prev_line.len && (prev_line[ws] == ' ' || prev_line[ws] == '\t')) {
			ws++;
		}

		if (ws < prev_line.len && prev_line[ws] == '@') {
			// Annotation line — include it in the declaration range
			pos = prev_start;
		} else {
			break;
		}
	}

	return (uint)pos;
}

// ── Javadoc HTML to markdown cleaning ─────────────────────────────

/**
 * Clean a raw Javadoc comment (already stripped of comment delimiters
 * and leading asterisks by extract_doc_comment) into markdown.
 *
 * Handles:
 *   {@code text}         → `text`
 *   {@link Foo#bar}      → Foo.bar
 *   {@link Foo#bar text} → text
 *   {@linkplain Foo text}→ text
 *   {@literal text}      → text
 *   <p> / </p>           → paragraph break
 *   <pre>{@code ...}</pre> → fenced code block
 *   <sup>n</sup>         → ^n
 *   @param name desc     → **name** — desc
 *   @return desc         → **Returns:** desc
 *   @throws E desc       → **Throws** E — desc
 *   @since ...           → (stripped)
 *   @see ...             → (stripped)
 *   Other HTML tags       → stripped
 */
fn String clean_javadoc(String raw) {
	if (raw.len == 0) return "";

	DString ds;
	ds.tinit();

	usz i = 0;
	bool in_pre = false;

	while (i < raw.len) {
		char c = raw[i];

		// Handle inline Javadoc tags: {@code ...}, {@link ...}, etc.
		if (c == '{' && i + 1 < raw.len && raw[i + 1] == '@') {
			i = process_inline_tag(raw, i, &ds, in_pre);
			continue;
		}

		// Handle HTML tags
		if (c == '<') {
			usz tag_end = i + 1;
			while (tag_end < raw.len && raw[tag_end] != '>') {
				tag_end++;
			}
			if (tag_end < raw.len) {
				String tag_content = raw[i + 1..tag_end - 1];
				String tag_lower = tag_to_lower(tag_content);

				if (tag_lower == "p" || tag_lower == "/p" || tag_lower == "p/") {
					// Paragraph break — emit double newline
					if (ds.len() > 0) {
						ds.appendf("\n\n");
					}
				} else if (tag_lower == "pre") {
					in_pre = true;
					ds.appendf("\n```\n");
				} else if (tag_lower == "/pre") {
					in_pre = false;
					ds.appendf("\n```\n");
				} else if (starts_with(tag_lower, "sup")) {
					ds.appendf("^");
				} else if (tag_lower == "/sup") {
					// nothing — the exponent text was already emitted
				} else if (tag_lower == "br" || tag_lower == "br/") {
					ds.appendf("\n");
				} else {
					// Strip unknown HTML tags silently
				}

				i = tag_end + 1;
				continue;
			}
		}

		// Handle block tags at start of line: @param, @return, etc.
		if (c == '@' && is_at_line_start(raw, i)) {
			i = process_block_tag(raw, i, &ds);
			continue;
		}

		// Regular character — emit as-is
		ds.appendf("%c", c);
		i++;
	}

	String result = ds.str_view();

	// Trim trailing whitespace/newlines
	while (result.len > 0 && is_trailing_ws(result[result.len - 1])) {
		result = result[:result.len - 1];
	}
	// Trim leading whitespace/newlines
	while (result.len > 0 && is_trailing_ws(result[0])) {
		result = result[1..];
	}

	// Collapse runs of 3+ newlines into 2
	return collapse_newlines(result);
}

// ── Inline tag processing ─────────────────────────────────────────

/**
 * Process an inline Javadoc tag starting at position i (the '{').
 * Writes the converted text to ds. Returns the new position past
 * the closing '}'.
 */
fn usz process_inline_tag(String raw, usz start, DString* ds, bool in_pre) {
	// Find the closing '}'
	usz end = start + 2;  // skip '{@'
	int depth = 1;
	while (end < raw.len && depth > 0) {
		if (raw[end] == '{') depth++;
		if (raw[end] == '}') depth--;
		if (depth > 0) end++;
	}
	if (end >= raw.len) {
		// Malformed — just emit the opening chars and move on
		ds.appendf("{@");
		return start + 2;
	}

	// Extract the tag body (between '{@' and '}')
	String body = raw[start + 2..end - 1];

	// Split into tag name and content
	usz space = 0;
	while (space < body.len && body[space] != ' ' && body[space] != '\t' && body[space] != '\n') {
		space++;
	}
	String tag_name = body[:space];
	String tag_body = "";
	if (space < body.len) {
		tag_body = body[space + 1..];
		// Trim leading whitespace
		while (tag_body.len > 0 && (tag_body[0] == ' ' || tag_body[0] == '\t')) {
			tag_body = tag_body[1..];
		}
	}

	if (tag_name == "code") {
		if (in_pre) {
			// Inside <pre>, just emit the code text directly
			ds.appendf("%s", tag_body);
		} else {
			ds.appendf("`%s`", tag_body);
		}
	} else if (tag_name == "link" || tag_name == "linkplain") {
		// {@link Foo#bar} or {@link Foo#bar display text}
		// {@linkplain Foo#bar display text}
		String ref = tag_body;
		String display = "";

		// Check if there's display text (space after the reference)
		usz ref_end = 0;
		while (ref_end < tag_body.len && tag_body[ref_end] != ' ' && tag_body[ref_end] != '\t') {
			ref_end++;
		}
		if (ref_end < tag_body.len) {
			ref = tag_body[:ref_end];
			display = tag_body[ref_end + 1..];
			while (display.len > 0 && (display[0] == ' ' || display[0] == '\t')) {
				display = display[1..];
			}
		}

		if (display.len > 0) {
			ds.appendf("%s", display);
		} else {
			// Convert Foo#bar to Foo.bar, strip leading #
			emit_java_ref(ref, ds);
		}
	} else if (tag_name == "literal") {
		ds.appendf("%s", tag_body);
	} else if (tag_name == "value") {
		ds.appendf("%s", tag_body);
	} else if (tag_name == "inheritDoc") {
		// Can't resolve — just skip
	} else {
		// Unknown inline tag — emit the body
		ds.appendf("%s", tag_body);
	}

	return end + 1;  // skip past '}'
}

/**
 * Convert a Java reference like "Foo#bar" or "#bar" to "Foo.bar" or "bar".
 */
fn void emit_java_ref(String ref, DString* ds) {
	for (usz j = 0; j < ref.len; j++) {
		if (ref[j] == '#') {
			if (j > 0) {
				ds.appendf(".");
			}
			// Skip the '#' itself
		} else if (ref[j] == '(') {
			// Include parens from method refs like "foo(int, int)"
			ds.appendf("%s", ref[j..]);
			return;
		} else {
			ds.appendf("%c", ref[j]);
		}
	}
}

// ── Block tag processing ──────────────────────────────────────────

/**
 * Process a block Javadoc tag (@param, @return, etc.) starting at
 * position i. Writes the formatted text to ds. Returns the new
 * position.
 */
fn usz process_block_tag(String raw, usz start, DString* ds) {
	// Extract the tag line(s) — a block tag runs until the next block
	// tag or end of text.
	usz end = start + 1;

	// Read the tag name
	while (end < raw.len && raw[end] != ' ' && raw[end] != '\t' && raw[end] != '\n') {
		end++;
	}
	String tag_name = raw[start + 1..end - 1];  // skip '@'

	// Skip whitespace after tag name
	while (end < raw.len && (raw[end] == ' ' || raw[end] == '\t')) {
		end++;
	}

	// Read the rest of the tag content until next @-tag at line start or end
	usz content_start = end;
	while (end < raw.len) {
		if (raw[end] == '@' && is_at_line_start(raw, end)) {
			break;
		}
		end++;
	}

	String tag_body = "";
	if (end > content_start) {
		tag_body = raw[content_start..end - 1];
		// Trim trailing whitespace
		while (tag_body.len > 0 && is_trailing_ws(tag_body[tag_body.len - 1])) {
			tag_body = tag_body[:tag_body.len - 1];
		}
	}

	if (tag_name == "param") {
		// @param name description
		usz name_end = 0;
		while (name_end < tag_body.len && tag_body[name_end] != ' ' && tag_body[name_end] != '\t') {
			name_end++;
		}
		String param_name = tag_body[:name_end];
		String param_desc = "";
		if (name_end < tag_body.len) {
			param_desc = tag_body[name_end + 1..];
			while (param_desc.len > 0 && (param_desc[0] == ' ' || param_desc[0] == '\t')) {
				param_desc = param_desc[1..];
			}
		}
		ds.appendf("\n\n**%s** \u2014 %s", param_name, param_desc);
	} else if (tag_name == "return") {
		ds.appendf("\n\n**Returns:** %s", tag_body);
	} else if (tag_name == "throws" || tag_name == "exception") {
		// @throws ExceptionType description
		usz name_end = 0;
		while (name_end < tag_body.len && tag_body[name_end] != ' ' && tag_body[name_end] != '\t') {
			name_end++;
		}
		String exc_name = tag_body[:name_end];
		String exc_desc = "";
		if (name_end < tag_body.len) {
			exc_desc = tag_body[name_end + 1..];
			while (exc_desc.len > 0 && (exc_desc[0] == ' ' || exc_desc[0] == '\t')) {
				exc_desc = exc_desc[1..];
			}
		}
		ds.appendf("\n\n**Throws** %s \u2014 %s", exc_name, exc_desc);
	} else if (tag_name == "since" || tag_name == "see" || tag_name == "author"
			|| tag_name == "version" || tag_name == "deprecated"
			|| tag_name == "serial" || tag_name == "serialField"
			|| tag_name == "serialData" || tag_name == "hidden") {
		// Strip these tags silently
	} else {
		// Unknown block tag — skip
	}

	return end;
}

// ── Helper functions ──────────────────────────────────────────────

/**
 * Check if position i is at the start of a line (i.e., preceded only
 * by whitespace since the last newline or start of string).
 */
fn bool is_at_line_start(String s, usz i) {
	if (i == 0) return true;
	usz j = i - 1;
	while (j > 0 && (s[j] == ' ' || s[j] == '\t')) {
		j--;
	}
	if (j == 0 && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n')) return true;
	return s[j] == '\n';
}

fn bool is_trailing_ws(char c) {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/**
 * Convert an HTML tag name to lowercase for comparison.
 * Only handles the first word of the tag (before attributes).
 * Uses temp allocator.
 */
fn String tag_to_lower(String tag) {
	if (tag.len == 0) return "";

	// Handle closing tags: strip leading '/'
	usz start = 0;
	bool is_close = false;
	if (tag[0] == '/') {
		start = 1;
		is_close = true;
	}

	// Find end of tag name (before attributes or '/')
	usz end = start;
	while (end < tag.len && tag[end] != ' ' && tag[end] != '\t' && tag[end] != '/') {
		end++;
	}
	// Check if self-closing (e.g., "br/")
	bool self_close = (end < tag.len && tag[end] == '/');

	DString ds;
	ds.tinit();
	if (is_close) ds.appendf("/");

	for (usz j = start; j < end; j++) {
		char c = tag[j];
		if (c >= 'A' && c <= 'Z') {
			ds.appendf("%c", c + 32);
		} else {
			ds.appendf("%c", c);
		}
	}

	if (self_close) ds.appendf("/");
	return ds.str_view();
}

/**
 * Check if a string starts with a given prefix.
 */
fn bool starts_with(String s, String prefix) {
	if (prefix.len > s.len) return false;
	return s[:prefix.len] == prefix;
}

/**
 * Collapse runs of 3+ consecutive newlines into 2.
 * Uses temp allocator.
 */
fn String collapse_newlines(String s) {
	if (s.len == 0) return "";

	DString ds;
	ds.tinit();

	usz newline_count = 0;
	for (usz i = 0; i < s.len; i++) {
		if (s[i] == '\n') {
			newline_count++;
			if (newline_count <= 2) {
				ds.appendf("\n");
			}
		} else {
			newline_count = 0;
			ds.appendf("%c", s[i]);
		}
	}

	return ds.str_view();
}
