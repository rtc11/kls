module kls::lsp::completion;

import std::io;
import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::symbols;
import kls::kotlin::stdlib;
import kls::kotlin::jdk_symbols;
import kls::workspace;
import kls::deps::jar_index;

// LSP CompletionItemKind constants
const int COMPLETION_KIND_METHOD = 2;
const int COMPLETION_KIND_FUNCTION = 3;
const int COMPLETION_KIND_FIELD = 5;
const int COMPLETION_KIND_VARIABLE = 6;
const int COMPLETION_KIND_CLASS = 7;
const int COMPLETION_KIND_INTERFACE = 8;
const int COMPLETION_KIND_MODULE = 9;
const int COMPLETION_KIND_PROPERTY = 10;
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
 * Returns a CompletionList JSON object with keyword, identifier, and
 * workspace completions.
 */
fn Object* handle_completion(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
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

	// Add workspace completions from other files
	if (workspace != null) {
		add_workspace_completions(items, workspace, prefix, uri);

		// Add dependency completions from indexed JARs
		if (workspace.dep_index.initialized) {
			add_dependency_completions(items, &workspace.dep_index, prefix);
		}
	}

	// Add stdlib completions (bundled kotlin-stdlib symbols)
	add_stdlib_completions(items, prefix);

	// Add JDK completions (bundled Java platform class symbols)
	add_jdk_completions(items, prefix);

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

// ── Workspace completions ─────────────────────────────────────────

/**
 * Add completion items from the workspace index for symbols matching
 * the given prefix. Skips symbols from the current document (already
 * covered by identifier completions) and deduplicates by name.
 */
fn void add_workspace_completions(Object* items, WorkspaceIndex* workspace, String prefix, String current_uri) {
	// Track seen names to avoid duplicates (also dedup against local items)
	String[256] seen_buf;
	usz seen_count = 0;

	// Collect names already in items to avoid workspace dupes
	for (usz i = 0; i < items.get_len() && seen_count < 256; i++) {
		Object* item = items.get_at(i);
		if (try label = item.get_string("label")) {
			seen_buf[seen_count] = label;
			seen_count++;
		}
	}

	for (usz i = 0; i < workspace.symbols.len(); i++) {
		WorkspaceSymbol* sym = &workspace.symbols[i];
		if (sym.name.len == 0) continue;

		// Skip symbols from current document
		if (sym.uri == current_uri) continue;

		// Filter by prefix
		if (prefix.len > 0 && !sym.name.starts_with(prefix)) continue;

		// Skip exact matches
		if (prefix.len > 0 && sym.name == prefix) continue;

		// Dedup check
		bool already_seen = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen_buf[j] == sym.name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		if (seen_count < 256) {
			seen_buf[seen_count] = sym.name;
			seen_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", sym.name);
		item.set("kind", symbol_kind_to_completion_kind(sym.kind));
		// Detail shows file origin
		item.set("detail", sym.uri);
		items.push(item);
	}
}

/**
 * Map a workspace SymbolKind to an LSP CompletionItemKind.
 */
fn int symbol_kind_to_completion_kind(SymbolKind kind) {
	switch (kind) {
		case FUNCTION:  return COMPLETION_KIND_FUNCTION;
		case CLASS:     return COMPLETION_KIND_CLASS;
		case INTERFACE: return COMPLETION_KIND_INTERFACE;
		case OBJECT:    return COMPLETION_KIND_MODULE;
		case PROPERTY:  return COMPLETION_KIND_PROPERTY;
		case TYPEALIAS: return COMPLETION_KIND_CLASS;
	}
}

// ── Stdlib completions ────────────────────────────────────────────

/**
 * Add completion items from the bundled kotlin-stdlib index.
 * Filters by prefix and deduplicates against items already present.
 */
fn void add_stdlib_completions(Object* items, String prefix) {
	if (prefix.len == 0) return;

	// Collect names already in items to avoid duplicates
	String[256] seen_buf;
	usz seen_count = 0;
	for (usz i = 0; i < items.get_len() && seen_count < 256; i++) {
		Object* item = items.get_at(i);
		if (try label = item.get_string("label")) {
			seen_buf[seen_count] = label;
			seen_count++;
		}
	}

	StdlibSymbol*[128] matches;
	usz match_count = stdlib::lookup_by_prefix(prefix, &matches);

	for (usz i = 0; i < match_count; i++) {
		StdlibSymbol* sym = matches[i];

		// Skip exact matches
		if (sym.name == prefix) continue;

		// Dedup check
		bool already_seen = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen_buf[j] == sym.name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		if (seen_count < 256) {
			seen_buf[seen_count] = sym.name;
			seen_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", sym.name);
		item.set("kind", stdlib_kind_to_completion_kind(sym.kind));
		item.set("detail", sym.package_name);

		// Add documentation with signature
		Object* doc_obj = object::new_obj(tmem);
		doc_obj.set("kind", "markdown");
		DString doc_val;
		doc_val.tinit();
		doc_val.appendf("```kotlin\n%s\n```", sym.signature);
		if (sym.doc.len > 0) {
			doc_val.appendf("\n\n%s", sym.doc);
		}
		doc_obj.set("value", doc_val.str_view());
		item.set("documentation", doc_obj);

		items.push(item);
	}
}

/**
 * Add completion items from the bundled JDK symbols table.
 * These cover commonly used Java platform classes (java.util.UUID,
 * java.io.File, java.time.LocalDate, etc.) that are available on
 * Kotlin/JVM without declaring an explicit dependency.
 */
fn void add_jdk_completions(Object* items, String prefix) {
	if (prefix.len == 0) return;

	// Collect names already in items to avoid duplicates
	String[256] seen_buf;
	usz seen_count = 0;
	for (usz i = 0; i < items.get_len() && seen_count < 256; i++) {
		Object* item = items.get_at(i);
		if (try label = item.get_string("label")) {
			seen_buf[seen_count] = label;
			seen_count++;
		}
	}

	StdlibSymbol*[128] matches;
	usz match_count = jdk_symbols::lookup_by_prefix(prefix, &matches);

	for (usz i = 0; i < match_count; i++) {
		StdlibSymbol* sym = matches[i];

		// Skip exact matches
		if (sym.name == prefix) continue;

		// Dedup check
		bool already_seen = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen_buf[j] == sym.name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		if (seen_count < 256) {
			seen_buf[seen_count] = sym.name;
			seen_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", sym.name);
		item.set("kind", stdlib_kind_to_completion_kind(sym.kind));
		item.set("detail", sym.package_name);

		// Add documentation with signature
		Object* doc_obj = object::new_obj(tmem);
		doc_obj.set("kind", "markdown");
		DString doc_val;
		doc_val.tinit();
		doc_val.appendf("```kotlin\n%s\n```", sym.signature);
		if (sym.doc.len > 0) {
			doc_val.appendf("\n\n%s", sym.doc);
		}
		doc_obj.set("value", doc_val.str_view());
		item.set("documentation", doc_obj);

		items.push(item);
	}
}

/**
 * Map a StdlibKind to an LSP CompletionItemKind.
 */
fn int stdlib_kind_to_completion_kind(StdlibKind kind) {
	switch (kind) {
		case FUNCTION:  return COMPLETION_KIND_FUNCTION;
		case CLASS:     return COMPLETION_KIND_CLASS;
		case INTERFACE: return COMPLETION_KIND_INTERFACE;
		case PROPERTY:  return COMPLETION_KIND_PROPERTY;
		case METHOD:    return COMPLETION_KIND_METHOD;
		case OBJECT:    return COMPLETION_KIND_MODULE;
		case TYPEALIAS: return COMPLETION_KIND_CLASS;
	}
}

// ── Dependency completions ────────────────────────────────────────

/**
 * Add completion items from the dependency index (JARs on the classpath).
 * Filters by prefix and deduplicates against items already present.
 */
fn void add_dependency_completions(Object* items, DependencyIndex* dep_index, String prefix) {
	if (prefix.len == 0) return;

	// Collect names already in items to avoid duplicates
	String[256] seen_buf;
	usz seen_count = 0;
	for (usz i = 0; i < items.get_len() && seen_count < 256; i++) {
		Object* item = items.get_at(i);
		if (try label = item.get_string("label")) {
			seen_buf[seen_count] = label;
			seen_count++;
		}
	}

	DepSymbol*[128] matches;
	usz match_count = dep_index.lookup_by_prefix(prefix, &matches);

	for (usz i = 0; i < match_count; i++) {
		DepSymbol* sym = matches[i];

		// Skip exact matches
		if (sym.name == prefix) continue;

		// Dedup check
		bool already_seen = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen_buf[j] == sym.name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		if (seen_count < 256) {
			seen_buf[seen_count] = sym.name;
			seen_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", sym.name);
		item.set("kind", jar_index::dep_kind_to_completion_kind(sym.kind));
		item.set("detail", sym.package_name);

		// Add documentation with signature
		Object* doc_obj = object::new_obj(tmem);
		doc_obj.set("kind", "markdown");
		DString doc_val;
		doc_val.tinit();
		doc_val.appendf("```kotlin\n%s\n```", sym.signature);
		if (sym.class_name.len > 0) {
			doc_val.appendf("\n\n*%s* (%s)", sym.package_name, sym.class_name);
		}
		doc_obj.set("value", doc_val.str_view());
		item.set("documentation", doc_obj);

		items.push(item);
	}
}
