module kls::lsp::completion;

import std::io;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;

// LSP CompletionItemKind constants
const int COMPLETION_KIND_VARIABLE = 6;
const int COMPLETION_KIND_KEYWORD = 14;

// All Kotlin keywords for completion (hard + soft + property/accessor)
const String[] KOTLIN_KEYWORDS = {
	// Hard keywords
	"package", "import", "class", "interface", "fun", "object",
	"val", "var", "typealias", "constructor", "by", "companion",
	"init", "this", "super", "typeof", "where",
	"if", "else", "when", "try", "catch", "finally",
	"for", "do", "while", "throw", "return", "continue", "break",
	"as", "is", "in", "out", "dynamic",
	// Soft keywords (modifiers)
	"abstract", "annotation", "data", "enum", "external", "final",
	"infix", "inline", "inner", "internal", "lateinit", "noinline",
	"open", "operator", "override", "private", "protected", "public",
	"reified", "sealed", "suspend", "tailrec", "vararg", "crossinline",
	"const", "expect", "actual", "value",
	// Soft keywords (property/accessor)
	"get", "set", "field", "property", "receiver", "param",
	"setparam", "delegate", "file",
	// Literals that are keywords
	"true", "false", "null",
};

/**
 * Handle textDocument/completion request.
 * Returns a CompletionList JSON object with keyword and identifier completions.
 */
fn Object* handle_completion(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return build_empty_completion_list();
	}

	String prefix = get_prefix_at_position(doc.content, line, character);

	// Build completion items
	Object* items = object::new_obj(tmem);

	// Add keyword completions
	add_keyword_completions(items, prefix);

	// Add identifier completions from the document
	add_identifier_completions(items, doc.content, prefix);

	// Build CompletionList
	Object* result = object::new_obj(tmem);
	result.set("isIncomplete", false);
	result.set("items", items);

	return result;
}

/**
 * Extract the identifier prefix at the given cursor position.
 * Scans backwards from the cursor to find the start of the current
 * identifier being typed. Returns an empty string if the cursor is
 * not at/after an identifier character.
 */
fn String get_prefix_at_position(String content, uint line, uint character) {
	long byte_offset = hover::position_to_offset(content, line, character);
	if (byte_offset <= 0) {
		return "";
	}
	usz cursor = (usz)byte_offset;

	// Scan backwards to find the start of the identifier
	usz start = cursor;
	while (start > 0) {
		char c = content[start - 1];
		if (lexer::is_ident_part(c)) {
			start--;
		} else {
			break;
		}
	}

	// Verify the first character is a valid identifier start
	if (start < cursor && !lexer::is_ident_start(content[start])) {
		return "";
	}

	if (start == cursor) {
		return "";
	}

	return content[start:cursor - start];
}

/**
 * Add matching keyword completions to the items array.
 */
fn void add_keyword_completions(Object* items, String prefix) {
	foreach (kw : KOTLIN_KEYWORDS) {
		if (prefix.len == 0 || kw.starts_with(prefix)) {
			// Skip exact matches (already fully typed)
			if (prefix.len > 0 && kw == prefix) continue;

			Object* item = object::new_obj(tmem);
			item.set("label", kw);
			item.set("kind", COMPLETION_KIND_KEYWORD);
			item.set("detail", "Keyword");
			items.push(item);
		}
	}
}

/**
 * Add matching identifier completions from the document to the items array.
 * Scans all tokens, collects unique identifiers, and filters by prefix.
 * Skips identifiers that match a keyword (already covered by keyword completions).
 */
fn void add_identifier_completions(Object* items, String content, String prefix) {
	if (content.len == 0) return;

	// Collect unique identifiers using a simple array + linear scan for dedup.
	// For typical file sizes this is fast enough.
	String[256] seen_buf;
	usz seen_count = 0;

	Lexer lex = lexer::init(content);
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		if (tok.kind != IDENTIFIER) continue;

		String name = tok.text;

		// Filter by prefix
		if (prefix.len > 0 && !name.starts_with(prefix)) continue;

		// Skip exact matches (the word currently being typed)
		if (prefix.len > 0 && name == prefix) continue;

		// Skip if already seen (dedup)
		bool already_seen = false;
		for (usz i = 0; i < seen_count; i++) {
			if (seen_buf[i] == name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		// Track as seen
		if (seen_count < 256) {
			seen_buf[seen_count] = name;
			seen_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", name);
		item.set("kind", COMPLETION_KIND_VARIABLE);
		item.set("detail", "Identifier");
		items.push(item);
	}
}

/**
 * Build an empty CompletionList response.
 */
fn Object* build_empty_completion_list() {
	Object* items = object::new_obj(tmem);
	Object* result = object::new_obj(tmem);
	result.set("isIncomplete", false);
	result.set("items", items);
	return result;
}
