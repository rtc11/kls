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
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;
import kls::deps::jar_index;
import kls::deps::member_resolver;

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

// File-local sub-AST helpers (C5d migration). Find direct TYPE_REF children
// of a declaration node so callers can render via `ast::type_ref_name` while
// the legacy `type_text` text path stays as a Wave-D fallback.
fn uint find_type_ref_child(ParseResult* pr, uint decl_idx) {
	if (decl_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* decl = &pr.nodes[decl_idx];
	if (decl.child_count == 0) return ast::NO_PARENT;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != decl_idx) continue;
		if (child.kind == TYPE_REF) return i;
	}
	return ast::NO_PARENT;
}

fn uint find_return_type_ref_child(ParseResult* pr, uint fun_idx) {
	if (fun_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* decl = &pr.nodes[fun_idx];
	if (decl.child_count == 0) return ast::NO_PARENT;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != fun_idx) continue;
		if (child.kind != TYPE_REF) continue;
		if (child.extra_text == "return") return i;
	}
	return ast::NO_PARENT;
}

/**
 * Handle textDocument/completion request.
 * Returns a CompletionList JSON object with keyword, identifier, and
 * workspace completions. Documentation is omitted; use completionItem/resolve.
 */
fn Object*? handle_completion(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return build_empty_completion_list();
	}

	String prefix = get_prefix_at_position(doc.content, line, character);

	// Check if we're in an import path context (after 'import ') — checked first, takes priority over dot
	bool is_import_context = is_import_completion_context(doc.content, line, character);

	// Check if we're in a dot-completion context (after . or ?.)
	bool is_dot_context = !is_import_context && is_dot_completion_context(doc.content, line, character, prefix);

	// Check if we're inside type argument angle brackets: List<|>
	bool is_type_arg_context = !is_dot_context && !is_import_context && is_type_argument_context(doc.content, line, character, prefix);

	// Check if we're in an annotation context (after @)
	bool is_annotation_context = !is_dot_context && !is_import_context && is_annotation_completion_context(doc.content, line, character, prefix);

	// Build completion items
	Object* items = object::new_obj(tmem);

	if (is_dot_context) {
		// Dot-completion: resolve receiver type and offer members
		add_dot_completions(items, store, workspace, uri, doc.content, line, character, prefix);
	}

	if (is_type_arg_context) {
		// Type argument context: offer types, type params, star projection
		add_type_argument_completions(items, store, uri, doc.content, line, character, prefix);
	}

	if (is_annotation_context) {
		// Annotation context: offer annotation types
		add_annotation_completions(items, workspace, prefix);
	}

	if (is_import_context) {
		// Import context: offer package paths and class names
		String import_path = get_import_path_prefix(doc.content, line, character);
		add_import_completions(items, workspace, import_path, prefix);

		// Build CompletionList (skip normal completions in import context)
		Object* result = object::new_obj(tmem);
		result.set("isIncomplete", false);
		result.set("items", items);
		return result;
	}

	// Always add general completions (keywords, identifiers, etc.)
	// In dot context these still help since the member lookup may not cover everything

	// Add keyword completions
	if (!is_dot_context) {
		add_keyword_completions(items, prefix);
	}

	// Add identifier completions from the document
	add_identifier_completions(items, doc.content, prefix);

	// Add workspace completions from other files
	if (workspace != null) {
		ParseResult* pr = store.get_ast(uri) ?? null;
		add_workspace_completions(items, workspace, prefix, uri, pr);

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
 * Handle completionItem/resolve request.
 * Populates the documentation field based on the item's data.
 * Returns the enriched completion item.
 */
fn Object*? handle_completion_resolve(WorkspaceIndex* workspace, Object* item) {
	Object* data = item.get("data") ?? null;
	if (data == null) return item;

	String source = data.get_string("source") ?? "";
	String name = data.get_string("name") ?? "";

	if (source == "stdlib") {
		String pkg = data.get_string("package") ?? "";
		resolve_stdlib_doc(item, name, pkg);
	} else if (source == "jdk") {
		String pkg = data.get_string("package") ?? "";
		resolve_jdk_doc(item, name, pkg);
	} else if (source == "dep") {
		String pkg = data.get_string("package") ?? "";
		resolve_dep_doc(item, workspace, name, pkg);
	} else if (source == "member") {
		String signature = data.get_string("signature") ?? "";
		resolve_member_doc(item, signature);
	}

	return item;
}

fn void resolve_stdlib_doc(Object* item, String name, String pkg) {
	StdlibSymbol*[128] matches;
	usz count = stdlib::lookup_by_prefix(name, &matches);
	for (usz i = 0; i < count; i++) {
		StdlibSymbol* sym = matches[i];
		if (sym.name == name && sym.package_name == pkg) {
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
			return;
		}
	}
	// Also check all symbols by name (for receiver-scoped matches)
	StdlibSymbol*[64] recv_matches;
	usz recv_count = stdlib::lookup_all_by_name(name, &recv_matches);
	for (usz i = 0; i < recv_count; i++) {
		StdlibSymbol* sym = recv_matches[i];
		if (sym.name == name && sym.package_name == pkg) {
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
			return;
		}
	}
}

fn void resolve_jdk_doc(Object* item, String name, String pkg) {
	StdlibSymbol*[128] matches;
	usz count = jdk_symbols::lookup_by_prefix(name, &matches);
	for (usz i = 0; i < count; i++) {
		StdlibSymbol* sym = matches[i];
		if (sym.name == name && sym.package_name == pkg) {
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
			return;
		}
	}
}

fn void resolve_dep_doc(Object* item, WorkspaceIndex* workspace, String name, String pkg) {
	if (workspace == null || !workspace.dep_index.initialized) return;

	DepSymbol*[128] matches;
	usz count = workspace.dep_index.lookup_by_prefix(name, &matches);
	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = matches[i];
		if (sym.name == name && sym.package_name == pkg) {
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
			return;
		}
	}
}

fn void resolve_member_doc(Object* item, String signature) {
	if (signature.len == 0) return;
	Object* doc_obj = object::new_obj(tmem);
	doc_obj.set("kind", "markdown");
	DString doc_val;
	doc_val.tinit();
	doc_val.appendf("```kotlin\n%s\n```", signature);
	doc_obj.set("value", doc_val.str_view());
	item.set("documentation", doc_obj);
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

	// Collect unique identifiers using a temp HashMap for O(1) dedup.
	// Seed with existing item labels so we don't shadow richer entries
	// (e.g. dot-completion already added 'extra' as a Property).
	HashMap{String, bool} seen;
	seen.tinit();
	for (usz i = 0; i < items.get_len(); i++) {
		Object* item = items.get_at(i);
		if (try label = item.get_string("label")) {
			seen.set(label, true);
		}
	}

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
		if (try existing = seen.get(name)) continue;

		// Track as seen
		seen.set(name, true);

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

// ── Dot-completion ────────────────────────────────────────────────

/**
 * Check if the cursor is in a dot-completion context (right after . or ?.)
 * by looking at what precedes the prefix in the source.
 */
fn bool is_dot_completion_context(String content, uint line, uint character, String prefix) {
	long byte_offset = hover::position_to_offset(content, line, character);
	if (byte_offset <= 0) return false;

	// Move back past the prefix to find what's before it
	usz pos = (usz)byte_offset - prefix.len;
	if (pos == 0) return false;

	// Check for dot or safe-call dot
	if (content[pos - 1] == '.') {
		// Could be plain dot or end of ?. safe-call
		return true;
	}

	return false;
}

/**
 * Detect if the cursor is inside type argument angle brackets: List<|>, Map<String, |>
 * Scans backward from cursor for an unmatched '<'.
 */
fn bool is_type_argument_context(String content, uint line, uint character, String prefix) {
	long byte_offset = hover::position_to_offset(content, line, character);
	if (byte_offset <= 0) return false;

	usz pos = (usz)byte_offset - prefix.len;
	int depth = 0;

	while (pos > 0) {
		pos--;
		char c = content[pos];
		if (c == '>') {
			depth++;
		} else if (c == '<') {
			if (depth == 0) {
				// Found unmatched '<' -- check that it follows an identifier (type name)
				if (pos > 0 && lexer::is_ident_part(content[pos - 1])) {
					return true;
				}
				return false;
			}
			depth--;
		} else if (c == '{' || c == '}' || c == ';' || c == '\n') {
			// Stop at statement/block boundaries
			return false;
		}
	}
	return false;
}

/**
 * Check if cursor is in an annotation context (after @).
 * Detects: @|, @Pre|fix
 */
fn bool is_annotation_completion_context(String content, uint line, uint character, String prefix) {
	long byte_offset = hover::position_to_offset(content, line, character);
	if (byte_offset <= 0) return false;

	usz pos = (usz)byte_offset - prefix.len;
	if (pos == 0) return false;

	// The character before the prefix should be @
	if (content[pos - 1] == '@') return true;

	return false;
}

/**
 * Check if cursor is in an import statement context.
 * Returns true when the current line starts with 'import '.
 */
fn bool is_import_completion_context(String content, uint line, uint character) {
	// Find the line start
	uint current_line = 0;
	usz line_start = 0;
	for (usz i = 0; i < content.len; i++) {
		if (current_line == line) {
			line_start = i;
			break;
		}
		if (content[i] == '\n') current_line++;
	}

	// Extract the line text up to cursor
	usz cursor_pos = line_start + character;
	if (cursor_pos > content.len) cursor_pos = content.len;
	String line_text = content[line_start:cursor_pos - line_start];

	// Skip leading whitespace
	usz idx = 0;
	while (idx < line_text.len && (line_text[idx] == ' ' || line_text[idx] == '\t')) idx++;

	// Check for "import " prefix
	String remaining = line_text[idx..];
	if (remaining.len >= 7 && remaining[:7] == "import ") return true;

	return false;
}

/**
 * Extract the import path prefix typed so far.
 * For "import com.example." returns "com.example."
 * For "import com.example.Fo" returns "com.example."
 * The prefix (last partial segment) is handled by the standard prefix logic.
 */
fn String get_import_path_prefix(String content, uint line, uint character) {
	// Find line start
	uint current_line = 0;
	usz line_start = 0;
	for (usz i = 0; i < content.len; i++) {
		if (current_line == line) {
			line_start = i;
			break;
		}
		if (content[i] == '\n') current_line++;
	}

	usz cursor_pos = line_start + character;
	if (cursor_pos > content.len) cursor_pos = content.len;
	String line_text = content[line_start:cursor_pos - line_start];

	// Find "import " and extract path after it
	usz idx = 0;
	while (idx < line_text.len && (line_text[idx] == ' ' || line_text[idx] == '\t')) idx++;
	if (line_text.len < idx + 7) return "";
	String after_import = line_text[idx + 7..];

	// Find last '.' — everything up to and including it is the path prefix
	bool found_dot = false;
	usz last_dot = 0;
	for (usz i = after_import.len; i > 0; i--) {
		if (after_import[i - 1] == '.') {
			last_dot = i;
			found_dot = true;
			break;
		}
	}

	if (found_dot) {
		return after_import[:last_dot]; // includes trailing dot
	}

	// No dot — return empty (top-level packages)
	return "";
}

/**
 * Add import path completions from workspace symbols and dependencies.
 * `import_path` is the path prefix (e.g., "com.example."), may be empty.
 * `prefix` is the last partial segment being typed (e.g., "Fo").
 */
fn void add_import_completions(Object* items, WorkspaceIndex* workspace, String import_path, String prefix) {
	if (workspace == null) return;

	// Collect unique next segments to offer
	// Use a simple dedup approach: track offered labels
	bool[256] offered;
	for (usz i = 0; i < 256; i++) offered[i] = false;
	usz offered_count = 0;
	String[256] offered_labels;

	// Search workspace symbols
	for (usz i = 0; i < workspace.symbols.len(); i++) {
		WorkspaceSymbol* sym = &workspace.symbols[i];
		if (sym.name.len == 0) continue;

		// Build full qualified name: package.Name
		DString fqn;
		fqn.tinit();
		if (sym.package_name.len > 0) {
			fqn.appendf("%s.%s", sym.package_name, sym.name);
		} else {
			fqn.appendf("%s", sym.name);
		}
		String fqn_str = fqn.str_view();

		// Check if fqn starts with import_path
		if (import_path.len > 0 && !fqn_str.starts_with(import_path)) continue;

		// Get the part after import_path
		String remainder = fqn_str[import_path.len..];
		if (remainder.len == 0) continue;

		// Find next segment (up to next '.')
		String next_segment;
		bool is_package = false;
		usz dot_pos = remainder.len;
		for (usz j = 0; j < remainder.len; j++) {
			if (remainder[j] == '.') {
				dot_pos = j;
				break;
			}
		}
		if (dot_pos < remainder.len) {
			next_segment = remainder[:dot_pos];
			is_package = true;
		} else {
			next_segment = remainder;
			is_package = false;
		}

		if (next_segment.len == 0) continue;
		if (prefix.len > 0 && !next_segment.starts_with(prefix)) continue;
		if (prefix.len > 0 && next_segment == prefix) continue;

		// Dedup
		bool already = false;
		for (usz j = 0; j < offered_count; j++) {
			if (offered_labels[j] == next_segment) {
				already = true;
				break;
			}
		}
		if (already) continue;
		if (offered_count < 256) {
			offered_labels[offered_count] = next_segment;
			offered_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", next_segment);
		if (is_package) {
			item.set("kind", COMPLETION_KIND_MODULE);  // 9 = Module
			item.set("detail", "package");
		} else {
			item.set("kind", sym.lsp_kind);
			if (sym.package_name.len > 0) {
				item.set("detail", sym.package_name);
			}
		}
		items.push(item);
	}

	// Also search dependency index for package completions
	if (workspace.dep_index.initialized) {
		add_dep_import_completions(items, &workspace.dep_index, import_path, prefix,
			offered_labels[..], &offered_count);
	}
}

/**
 * Add import completions from dependency index (JARs).
 */
fn void add_dep_import_completions(Object* items, DependencyIndex* dep_index,
		String import_path, String prefix, String[] offered_labels, usz* offered_count) {
	for (usz i = 0; i < dep_index.symbols.len(); i++) {
		DepSymbol* sym = &dep_index.symbols[i];
		if (sym.name.len == 0) continue;

		// Build FQN
		DString fqn;
		fqn.tinit();
		if (sym.package_name.len > 0) {
			fqn.appendf("%s.%s", sym.package_name, sym.name);
		} else {
			fqn.appendf("%s", sym.name);
		}
		String fqn_str = fqn.str_view();

		if (import_path.len > 0 && !fqn_str.starts_with(import_path)) continue;

		String remainder = fqn_str[import_path.len..];
		if (remainder.len == 0) continue;

		String next_segment;
		bool is_package = false;
		usz dot_pos = remainder.len;
		for (usz j = 0; j < remainder.len; j++) {
			if (remainder[j] == '.') {
				dot_pos = j;
				break;
			}
		}
		if (dot_pos < remainder.len) {
			next_segment = remainder[:dot_pos];
			is_package = true;
		} else {
			next_segment = remainder;
		}

		if (next_segment.len == 0) continue;
		if (prefix.len > 0 && !next_segment.starts_with(prefix)) continue;
		if (prefix.len > 0 && next_segment == prefix) continue;

		// Dedup
		bool already = false;
		for (usz j = 0; j < *offered_count; j++) {
			if (offered_labels[j] == next_segment) {
				already = true;
				break;
			}
		}
		if (already) continue;
		if (*offered_count < 256) {
			offered_labels[*offered_count] = next_segment;
			(*offered_count)++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", next_segment);
		if (is_package) {
			item.set("kind", COMPLETION_KIND_MODULE);
			item.set("detail", "package");
		} else {
			item.set("kind", (int)sym.kind);
			if (sym.package_name.len > 0) {
				item.set("detail", sym.package_name);
			}
		}
		items.push(item);
	}
}

/**
 * Add annotation completion items. Offers well-known Kotlin annotations
 * plus annotation classes from workspace and dependencies.
 */
fn void add_annotation_completions(Object* items, WorkspaceIndex* workspace, String prefix) {
	// Well-known Kotlin annotations
	String[*] kotlin_annotations = {
		"Deprecated", "JvmStatic", "JvmOverloads", "JvmField", "JvmName",
		"Suppress", "OptIn", "RequiresOptIn",
		"Target", "Retention", "Repeatable", "MustBeDocumented",
		"Throws", "Synchronized", "Volatile", "Transient",
		"Strictfp", "JvmRecord", "JvmInline",
	};

	foreach (name : kotlin_annotations) {
		if (prefix.len > 0 && !name.starts_with(prefix)) continue;
		if (prefix.len > 0 && name == prefix) continue;

		Object* item = object::new_obj(tmem);
		item.set("label", name);
		item.set("kind", COMPLETION_KIND_CLASS); // annotations are classes
		item.set("detail", "annotation");
		item.set("sortText", "0"); // prioritize annotations in this context
		items.push(item);
	}

	// Android/JUnit/common framework annotations
	String[*] framework_annotations = {
		"Test", "Before", "After", "BeforeEach", "AfterEach",
		"Override", "FunctionalInterface",
		"Serializable", "Parcelize",
	};

	foreach (name : framework_annotations) {
		if (prefix.len > 0 && !name.starts_with(prefix)) continue;
		if (prefix.len > 0 && name == prefix) continue;

		Object* item = object::new_obj(tmem);
		item.set("label", name);
		item.set("kind", COMPLETION_KIND_CLASS);
		item.set("detail", "annotation");
		item.set("sortText", "1");
		items.push(item);
	}

	// Workspace annotation classes
	if (workspace != null) {
		for (usz i = 0; i < workspace.symbols.len(); i++) {
			WorkspaceSymbol* sym = &workspace.symbols[i];
			if (sym.name.len == 0) continue;
			if (sym.kind != SymbolKind.CLASS) continue;
			// Check if it's an annotation class (has annotation modifier or name convention)
			// We can't easily check mod_flags from WorkspaceSymbol, so include all classes
			// that are capitalized (annotation classes are always PascalCase)
			if (prefix.len > 0 && !sym.name.starts_with(prefix)) continue;
			if (prefix.len > 0 && sym.name == prefix) continue;

			Object* item = object::new_obj(tmem);
			item.set("label", sym.name);
			item.set("kind", COMPLETION_KIND_CLASS);
			item.set("detail", "class");
			item.set("sortText", "2");
			items.push(item);
		}
	}
}

/**
 * Add type completions for inside angle brackets context.
 * Offers: type params in scope, class/interface names, type aliases, star projection.
 */
fn void add_type_argument_completions(Object* items, DocumentStore* store, String uri, String content,
		uint line, uint character, String prefix) {
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Add star projection
	if ("*".starts_with(prefix) || prefix.len == 0) {
		Object* item = object::new_obj(tmem);
		item.set("label", "*");
		item.set("kind", 14); // Keyword
		item.set("detail", "Star projection");
		item.set("sortText", "0000*");
		items.push(item);
	}

	if (pr == null) return;

	long byte_offset = hover::position_to_offset(content, line, character);
	uint cursor_offset = byte_offset > 0 ? (uint)byte_offset : 0;

	// Add type parameters in scope (highest priority)
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != TYPE_PARAM || n.name.len == 0) continue;
		if (n.parent == ast::NO_PARENT) continue;

		// Check if cursor is within the parent scope
		AstNode* owner = &pr.nodes[n.parent];
		if (cursor_offset < owner.start_offset || cursor_offset >= owner.end_offset) continue;

		if (prefix.len == 0 || n.name.starts_with(prefix)) {
			Object* item = object::new_obj(tmem);
			item.set("label", n.name);
			item.set("kind", 25); // TypeParameter
			// gate: presence check on dual-storage text field
			// TODO(wave-D): TYPE_PARAM upper bounds may be intersection (T : A & B);
			// `find_type_ref_child` only yields first TYPE_REF, so source-slice render
			// would drop the `& B` portion. Migrate when intersection rendering supported.
			if (n.type_text.len > 0) {
				DString detail;
				detail.tinit();
				detail.appendf("type parameter : %s", n.type_text);
				item.set("detail", detail.str_view());
			} else {
				item.set("detail", "type parameter");
			}
			item.set("sortText", "0001");
			items.push(item);
		}
	}

	// Add class/interface/typealias declarations (from AST)
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name.len == 0) continue;
		bool is_type = n.kind == CLASS_DECL || n.kind == INTERFACE_DECL ||
		               n.kind == OBJECT_DECL || n.kind == TYPEALIAS_DECL ||
		               n.kind == ENUM_ENTRY;
		if (!is_type) continue;

		if (prefix.len == 0 || n.name.starts_with(prefix)) {
			Object* item = object::new_obj(tmem);
			item.set("label", n.name);
			int kind;
			switch (n.kind) {
				case CLASS_DECL:     kind = 7;  // Class
				case INTERFACE_DECL: kind = 8;  // Interface
				case OBJECT_DECL:    kind = 7;  // Class
				case TYPEALIAS_DECL: kind = 7;  // Class
				case ENUM_ENTRY:     kind = 13; // Enum
				default:             kind = 7;
			}
			item.set("kind", kind);
			item.set("sortText", "0010");
			items.push(item);
		}
	}
}

/**
 * Find the receiver identifier name before a dot at the given position.
 * Scans backward from the dot to find the identifier text.
 */
fn String find_receiver_name(String content, uint line, uint character, String prefix) {
	long byte_offset = hover::position_to_offset(content, line, character);
	if (byte_offset <= 0) return "";

	// Move back past the prefix and the dot
	usz pos = (usz)byte_offset - prefix.len;
	if (pos == 0) return "";

	// Skip over the dot
	if (pos > 0 && content[pos - 1] == '.') {
		pos--;
		// Also skip ? for safe-call ?.
		if (pos > 0 && content[pos - 1] == '?') {
			pos--;
		}
	} else {
		return "";
	}

	// Now scan backward to find the receiver identifier
	usz end = pos;
	while (pos > 0 && lexer::is_ident_part(content[pos - 1])) {
		pos--;
	}

	if (pos == end) return "";
	if (!lexer::is_ident_start(content[pos])) return "";

	return content[pos:end - pos];
}

/**
 * Add dot-completion items by resolving the receiver type and looking
 * up available members. Falls back to workspace class lookup and
 * stdlib receiver members.
 */
fn void add_dot_completions(Object* items, DocumentStore* store, WorkspaceIndex* workspace,
		String uri, String content, uint line, uint character, String prefix) {
	String receiver_name = find_receiver_name(content, line, character, prefix);
	if (receiver_name.len == 0) return;

	// Try to resolve the receiver type from the AST + TypeInfo
	TypeRef receiver_type = types::TYPE_UNKNOWN;

	ParseResult* pr = store.get_ast(uri) ?? null;
	TypeInfo* ti = store.get_types(uri) ?? null;

	if (pr != null && ti != null) {
		receiver_type = resolve_receiver_type(pr, ti, receiver_name, line, character);
	}

	// Object expression body members (Kotlin spec §11.2.7 + §16.6).
	// Surfaces decls from `val o = object [: Super] { ... }` even when
	// the receiver type is UNKNOWN (pure-anonymous). Body decls win
	// over supertype members so this runs first; later workspace/dep
	// passes dedup against existing labels.
	if (pr != null) {
		add_object_body_completions(items, pr, content, receiver_name, prefix);
	}

	// If we couldn't resolve via AST, try to infer from the name
	// (e.g., receiver is a class name -> offer static members)
	if (receiver_type.kind == UNKNOWN) {
		// Try literal type heuristic based on the receiver text
		receiver_type = guess_receiver_type(content, receiver_name, line, character);
	}

	if (receiver_type.kind == UNKNOWN) return;

	// Look up members for this type from the hardcoded type tables
	// (instance-only — class-ref receivers fall through to dep path).
	MemberInfo[128] members;
	usz member_count = types::lookup_members(&receiver_type, members[..], receiver_type.is_class_ref);

	for (usz i = 0; i < member_count; i++) {
		MemberInfo* m = &members[i];

		// Filter by prefix if one exists
		if (prefix.len > 0 && !m.name.starts_with(prefix)) continue;
		if (prefix.len > 0 && m.name == prefix) continue;

		Object* item = object::new_obj(tmem);
		item.set("label", m.name);
		item.set("kind", m.kind);
		item.set("detail", m.detail);

		// Data for lazy resolve (type member)
		if (m.signature.len > 0) {
			Object* data = object::new_obj(tmem);
			data.set("source", "member");
			data.set("name", m.name);
			data.set("signature", m.signature);
			item.set("data", data);
		}

		items.push(item);
	}

	// Look up members from the workspace index for user-defined types
	if (workspace != null) {
		add_workspace_class_members(items, workspace, store, &receiver_type, prefix);
	}

	// Look up members from dep JARs (Java/Kotlin classes from classpath).
	// Runs after workspace so user-defined types win on dedup.
	if (workspace != null && workspace.dep_index.initialized) {
		add_dep_class_member_completions(items, &workspace.dep_index, &receiver_type, prefix);
	}

	// Also add receiver-specific stdlib completions
	add_stdlib_receiver_completions(items, &receiver_type, prefix);
}

/**
 * Surface dep-class members (Java/Kotlin from JARs) as completions for
 * `receiver.` expressions. Uses the class_index for O(class members)
 * lookup, walks one level of supertypes for inherited members, applies
 * static-vs-instance filter via TypeRef.is_class_ref.
 *
 * Dedup against existing items by label (workspace + stdlib already added).
 */
fn void add_dep_class_member_completions(Object* items, DependencyIndex* dep_index,
		TypeRef* receiver_type, String prefix) {
	String type_name = receiver_type.name;
	if (type_name.len == 0) return;

	DepSymbol*[256] members;
	usz count = member_resolver::find_dep_class_all_members(
		dep_index, type_name, receiver_type.is_class_ref, &members);
	if (count == 0) return;

	// Collect existing labels for dedup
	String[256] seen_buf;
	usz seen_count = 0;
	for (usz i = 0; i < items.get_len() && seen_count < 256; i++) {
		Object* item = items.get_at(i);
		if (try label = item.get_string("label")) {
			seen_buf[seen_count] = label;
			seen_count++;
		}
	}

	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = members[i];

		// Filter by prefix
		if (prefix.len > 0 && !sym.name.starts_with(prefix)) continue;
		if (prefix.len > 0 && sym.name == prefix) continue;

		// Dedup against existing items + within this batch
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
		// Detail: signature if available, else "package.Class"
		if (sym.signature.len > 0) {
			item.set("detail", sym.signature);
		} else if (sym.class_name.len > 0 && sym.package_name.len > 0) {
			DString detail;
			detail.tinit();
			detail.appendf("%s.%s", sym.package_name, sym.class_name);
			item.set("detail", detail.str_view());
		} else if (sym.package_name.len > 0) {
			item.set("detail", sym.package_name);
		}

		// Data for lazy resolve via existing dep doc path
		Object* data = object::new_obj(tmem);
		data.set("source", "dep");
		data.set("name", sym.name);
		data.set("package", sym.package_name);
		item.set("data", data);

		items.push(item);
	}
}

/**
 * Resolve the type of a receiver identifier by searching the AST
 * for declarations and expression nodes with that name.
 */
fn TypeRef resolve_receiver_type(ParseResult* pr, TypeInfo* ti, String name, uint line, uint character) {
	// First, search for a declaration with this name (scope-aware: innermost first)
	// Simplified: just find any declaration with this name and return its type
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name != name) continue;

		if (ast::is_declaration(n.kind)) {
			if (ti.has_type[i]) {
				return ti.node_types[i];
			}
			// Fall back to type_text
			// TODO(wave-D): `parse_type_text` is a string-parsing consumer (text-consumer).
			// Migrating requires a TypeRef builder over sub-AST that doesn't exist yet.
			if (n.type_text.len > 0) {
				return types::parse_type_text(n.type_text);
			}
		}

		// Also check NAME_EXPR nodes
		if (n.kind == NAME_EXPR && ti.has_type[i]) {
			return ti.node_types[i];
		}
	}

	return types::TYPE_UNKNOWN;
}

/**
 * Try to guess the receiver type by looking at a string literal or other
 * contextual clues near the cursor.
 */
fn TypeRef guess_receiver_type(String content, String receiver_name, uint line, uint character) {
	// For now, just try well-known receiver names
	if (receiver_name == "this") {
		// Can't resolve 'this' without class context
		return types::TYPE_UNKNOWN;
	}

	return types::TYPE_UNKNOWN;
}

// ── Workspace class member completion ─────────────────────────────

/**
 * Surface body decls (PROPERTY_DECL / FUN_DECL) of an object expression
 * backing the receiver (Kotlin spec §11.2.7 + §16.6). Handles both
 * supertype-anchored objects (`object : Greeter { ... }`) and pure-
 * anonymous objects (`object { ... }`) regardless of receiver_type.
 *
 * Walks `pr` looking for a PROPERTY_DECL named `receiver_name` whose
 * initializer is an OBJECT_EXPR, then emits each direct body decl as
 * a Property/Method completion item with proper kind + detail.
 */
fn void add_object_body_completions(Object* items, ParseResult* pr, String content, String receiver_name, String prefix) {
	if (pr == null || receiver_name.len == 0) return;

	// Find the PROPERTY_DECL bound to receiver_name
	uint obj_idx = ast::NO_PARENT;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* d = &pr.nodes[i];
		if (d.kind != PROPERTY_DECL) continue;
		if (d.name != receiver_name) continue;
		// First non-TYPE_REF child = initializer
		for (uint k = d.children_start; k < pr.node_count; k++) {
			if (pr.nodes[k].parent != i) continue;
			NodeKind kk = pr.nodes[k].kind;
			if (kk == TYPE_REF) continue;
			if (kk == OBJECT_EXPR) obj_idx = k;
			break;
		}
		if (obj_idx != ast::NO_PARENT) break;
	}
	if (obj_idx == ast::NO_PARENT) return;

	// Dedup against any existing items (rare; safety)
	String[256] seen_buf;
	usz seen_count = 0;
	for (usz i = 0; i < items.get_len() && seen_count < 256; i++) {
		Object* it = items.get_at(i);
		if (try label = it.get_string("label")) seen_buf[seen_count++] = label;
	}

	for (uint k = pr.nodes[obj_idx].children_start; k < pr.node_count; k++) {
		if (pr.nodes[k].parent != obj_idx) continue;
		AstNode* m = &pr.nodes[k];
		if (m.name.len == 0) continue;

		int kind;
		String detail;
		switch (m.kind) {
			case PROPERTY_DECL:
				kind = COMPLETION_KIND_PROPERTY;
				{
					uint ref_idx = find_type_ref_child(pr, k);
					String t = (ref_idx != ast::NO_PARENT && content.len > 0)
						? ast::type_ref_name(pr, ref_idx, content, tmem)
						: "";
					detail = t.len > 0 ? t : (m.type_text.len > 0 ? m.type_text : "Any");
				}
				break;
			case FUN_DECL:
				kind = COMPLETION_KIND_METHOD;
				{
					uint ref_idx = find_return_type_ref_child(pr, k);
					String t = (ref_idx != ast::NO_PARENT && content.len > 0)
						? ast::type_ref_name(pr, ref_idx, content, tmem)
						: "";
					detail = t.len > 0 ? t : (m.type_text.len > 0 ? m.type_text : "Unit");
				}
				break;
			default:
				continue;
		}

		if (prefix.len > 0 && !m.name.starts_with(prefix)) continue;
		if (prefix.len > 0 && m.name == prefix) continue;

		bool already = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen_buf[j] == m.name) { already = true; break; }
		}
		if (already) continue;
		if (seen_count < 256) seen_buf[seen_count++] = m.name;

		Object* item = object::new_obj(tmem);
		item.set("label", m.name);
		item.set("kind", kind);
		item.set("detail", detail);
		items.push(item);
	}
}

/**
 * Look up a user-defined class/interface/object in the workspace index
 * and add its member declarations as completion items.
 *
 * This handles the case where `receiver.` is typed and the receiver's
 * type resolves to a class defined in the project (not in the hardcoded
 * type tables or stdlib).
 */
fn void add_workspace_class_members(Object* items, WorkspaceIndex* workspace, DocumentStore* store,
		TypeRef* receiver_type, String prefix) {
	String type_name = receiver_type.name;
	if (type_name.len == 0) return;

	// Try the member cache first (fast path — no re-parsing)
	if (try members = workspace.lookup_members(type_name)) {
		add_members_from_cache(items, members, prefix);

		// Walk supertypes to include inherited members
		List{usz}* indices = workspace.lookup_by_name(type_name) ?? null;
		if (indices != null) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
				if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
					sym.kind != SymbolKind.OBJECT) continue;
				for (usz s = 0; s < sym.supertype_count; s++) {
					add_workspace_supertype_members(items, workspace, store, sym.supertypes[s], prefix);
				}
				return;
			}
		}
		return;
	}

	// Fall back to parsing (cache miss — file not yet indexed)
	List{usz}* indices = workspace.lookup_by_name(type_name) ?? null;
	if (indices == null) return;

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));

		// Only look at class-like declarations
		if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
			sym.kind != SymbolKind.OBJECT) continue;

		// Get the file content (prefer open document, fall back to disk)
		String content;
		char[] disk_data;

		if (try doc = store.get(sym.uri)) {
			content = doc.content;
		} else {
			String file_path = workspace::uri_to_path(sym.uri);
			if (try d = std::io::file::load(tmem, file_path)) {
				disk_data = d;
				content = (String)disk_data;
			} else {
				continue;
			}
		}

		// Parse the file and extract class members
		ParseResult* pr = mem::new(ParseResult);
		defer mem::free(pr);
		parser::parse(content, pr);

		add_members_from_class_ast(items, pr, content, type_name, prefix);

		// Walk supertypes to include inherited members
		for (usz s = 0; s < sym.supertype_count; s++) {
			add_workspace_supertype_members(items, workspace, store, sym.supertypes[s], prefix);
		}

		return; // Found the class, done
	}
}

/**
 * Extract member declarations from a class AST and add them as
 * completion items. Handles functions, properties, nested classes,
 * and data class constructor params with val/var.
 */
fn void add_members_from_class_ast(Object* items, ParseResult* pr, String content, String class_name, String prefix) {
	// Find the class declaration
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if ((n.kind != CLASS_DECL && n.kind != INTERFACE_DECL && n.kind != OBJECT_DECL) ||
			n.name != class_name) continue;

		// Iterate direct children for member declarations
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.name.len == 0) continue;

			// Filter by prefix
			if (prefix.len > 0 && !child.name.starts_with(prefix)) continue;
			if (prefix.len > 0 && child.name == prefix) continue;

			// Check for duplicate labels already in items
			bool already_present = false;
			for (usz k = 0; k < items.get_len(); k++) {
				Object* existing = items.get_at(k);
				if (try label = existing.get_string("label")) {
					if (label == child.name) {
						already_present = true;
						break;
					}
				}
			}
			if (already_present) continue;

			int kind = 0;
			String detail = "";
			DString sig;
			sig.tinit();

			switch (child.kind) {
				case FUN_DECL:
					kind = COMPLETION_KIND_METHOD;
					{
						uint ref_idx = find_return_type_ref_child(pr, j);
						String t = (ref_idx != ast::NO_PARENT && content.len > 0)
							? ast::type_ref_name(pr, ref_idx, content, tmem)
							: "";
						detail = t.len > 0 ? t : (child.type_text.len > 0 ? child.type_text : "Unit");
					}
					build_fun_signature(&sig, child, pr, content, i);
				case PROPERTY_DECL:
					kind = COMPLETION_KIND_PROPERTY;
					{
						uint ref_idx = find_type_ref_child(pr, j);
						String t = (ref_idx != ast::NO_PARENT && content.len > 0)
							? ast::type_ref_name(pr, ref_idx, content, tmem)
							: "";
						detail = t.len > 0 ? t : (child.type_text.len > 0 ? child.type_text : "");
					}
					build_property_signature(&sig, child, pr, content);
				case CLASS_DECL:
				case INTERFACE_DECL:
				case OBJECT_DECL:
					kind = COMPLETION_KIND_CLASS;
					detail = "nested class";
				case PARAM:
					// Data class constructor params with val/var
					if ((child.mod_flags & ast::MOD_VAR) != 0 || (child.mod_flags & ast::MOD_FINAL) != 0) {
						kind = COMPLETION_KIND_PROPERTY;
						{
							uint ref_idx = find_type_ref_child(pr, j);
							String t = (ref_idx != ast::NO_PARENT && content.len > 0)
								? ast::type_ref_name(pr, ref_idx, content, tmem)
								: "";
							detail = t.len > 0 ? t : (child.type_text.len > 0 ? child.type_text : "");
						}
						build_property_signature(&sig, child, pr, content);
					} else {
						continue; // regular param, not a member
					}
				default:
					continue;
			}

			Object* item = object::new_obj(tmem);
			item.set("label", child.name);
			item.set("kind", kind);
			item.set("detail", detail);

			String sig_str = sig.str_view();
			if (sig_str.len > 0) {
				Object* data = object::new_obj(tmem);
				data.set("source", "member");
				data.set("name", child.name);
				data.set("signature", sig_str);
				item.set("data", data);
			}

			items.push(item);
		}

		return; // Found the class, done
	}
}

/**
 * Build a function signature string for documentation:
 * "fun name(param: Type, ...): ReturnType"
 */
fn void build_fun_signature(DString* sig, AstNode* fun_node, ParseResult* pr, String content, uint class_idx) {
	sig.appendf("fun %s(", fun_node.name);

	uint fun_idx = ast::node_index(pr, fun_node);
	bool first = true;
	for (uint k = 0; k < pr.node_count; k++) {
		if (pr.nodes[k].parent != fun_idx) continue;
		if (pr.nodes[k].kind != PARAM) continue;
		if (!first) sig.append(", ");
		first = false;
		if (pr.nodes[k].name.len > 0) {
			sig.appendf("%s", pr.nodes[k].name);
		}
		uint ref_idx = find_type_ref_child(pr, k);
		String t = (ref_idx != ast::NO_PARENT && content.len > 0)
			? ast::type_ref_name(pr, ref_idx, content, tmem)
			: "";
		String pt = t.len > 0 ? t : pr.nodes[k].type_text;
		if (pt.len > 0) {
			sig.appendf(": %s", pt);
		}
	}

	sig.append(")");
	uint ret_idx = find_return_type_ref_child(pr, fun_idx);
	String rt = (ret_idx != ast::NO_PARENT && content.len > 0)
		? ast::type_ref_name(pr, ret_idx, content, tmem)
		: "";
	String rendered = rt.len > 0 ? rt : fun_node.type_text;
	if (rendered.len > 0) {
		sig.appendf(": %s", rendered);
	}
}

/**
 * Build a property signature string for documentation:
 * "val name: Type" or "var name: Type"
 */
fn void build_property_signature(DString* sig, AstNode* prop_node, ParseResult* pr, String content) {
	String keyword = (prop_node.mod_flags & ast::MOD_VAR) != 0 ? "var" : "val";
	sig.appendf("%s %s", keyword, prop_node.name);
	uint prop_idx = ast::node_index(pr, prop_node);
	uint ref_idx = find_type_ref_child(pr, prop_idx);
	String t = (ref_idx != ast::NO_PARENT && content.len > 0)
		? ast::type_ref_name(pr, ref_idx, content, tmem)
		: "";
	String rendered = t.len > 0 ? t : prop_node.type_text;
	if (rendered.len > 0) {
		sig.appendf(": %s", rendered);
	}
}

/**
 * Add completion items from cached MemberDecl entries.
 * This is the fast-path equivalent of add_members_from_class_ast,
 * operating on the pre-computed member cache instead of re-parsing.
 */
fn void add_members_from_cache(Object* items, List{MemberDecl}* members, String prefix) {
	// TODO(wave-D): MemberDecl.type_text is workspace-cache state with no AST link.
	// Migration requires either threading (pr, content) into the workspace cache
	// build path or storing a sub-AST handle on MemberDecl. Out of scope for C5d
	// (would touch src/workspace.c3). Legacy text path retained.
	for (usz i = 0; i < members.len(); i++) {
		MemberDecl* m = &(*members)[i];
		if (m.name.len == 0) continue;

		// Filter by prefix
		if (prefix.len > 0 && !m.name.starts_with(prefix)) continue;
		if (prefix.len > 0 && m.name == prefix) continue;

		// Check for duplicate labels already in items
		bool already_present = false;
		for (usz k = 0; k < items.get_len(); k++) {
			Object* existing = items.get_at(k);
			if (try label = existing.get_string("label")) {
				if (label == m.name) {
					already_present = true;
					break;
				}
			}
		}
		if (already_present) continue;

		int kind = 0;
		String detail = "";
		DString sig;
		sig.tinit();

		switch (m.node_kind) {
			case FUN_DECL:
				kind = COMPLETION_KIND_METHOD;
				detail = m.type_text.len > 0 ? m.type_text : "Unit";
				build_fun_signature_from_cache(&sig, m);
			case PROPERTY_DECL:
				kind = COMPLETION_KIND_PROPERTY;
				detail = m.type_text.len > 0 ? m.type_text : "";
				build_property_signature_from_cache(&sig, m);
			case CLASS_DECL:
			case INTERFACE_DECL:
			case OBJECT_DECL:
				kind = COMPLETION_KIND_CLASS;
				detail = "nested class";
			case PARAM:
				// Data class constructor params with val/var
				if ((m.mod_flags & ast::MOD_VAR) != 0 || (m.mod_flags & ast::MOD_FINAL) != 0) {
					kind = COMPLETION_KIND_PROPERTY;
					detail = m.type_text.len > 0 ? m.type_text : "";
					build_property_signature_from_cache(&sig, m);
				} else {
					continue;
				}
			default:
				continue;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", m.name);
		item.set("kind", kind);
		item.set("detail", detail);

		String sig_str = sig.str_view();
		if (sig_str.len > 0) {
			Object* data = object::new_obj(tmem);
			data.set("source", "member");
			data.set("name", m.name);
			data.set("signature", sig_str);
			item.set("data", data);
		}

		items.push(item);
	}
}

/**
 * Build a function signature from a cached MemberDecl.
 */
fn void build_fun_signature_from_cache(DString* sig, MemberDecl* m) {
	// TODO(wave-D): see add_members_from_cache — MemberDecl text fields lack AST link.
	sig.appendf("fun %s(", m.name);

	for (usz i = 0; i < m.param_count; i++) {
		if (i > 0) sig.append(", ");
		if (m.param_names[i].len > 0) {
			sig.appendf("%s", m.param_names[i]);
		}
		if (m.param_types[i].len > 0) {
			sig.appendf(": %s", m.param_types[i]);
		}
	}

	sig.append(")");
	if (m.type_text.len > 0) {
		sig.appendf(": %s", m.type_text);
	}
}

/**
 * Build a property signature from a cached MemberDecl.
 */
fn void build_property_signature_from_cache(DString* sig, MemberDecl* m) {
	// TODO(wave-D): see add_members_from_cache — MemberDecl text fields lack AST link.
	String keyword = (m.mod_flags & ast::MOD_VAR) != 0 ? "var" : "val";
	sig.appendf("%s %s", keyword, m.name);
	if (m.type_text.len > 0) {
		sig.appendf(": %s", m.type_text);
	}
}

/**
 * Look up a supertype in the workspace and add its members.
 * This enables inherited member completion (one level deep to avoid
 * infinite recursion with cyclic type hierarchies).
 */
fn void add_workspace_supertype_members(Object* items, WorkspaceIndex* workspace, DocumentStore* store,
		String supertype_name, String prefix) {
	add_workspace_supertype_members_depth(items, workspace, store, supertype_name, prefix, 0);
}

const int MAX_SUPERTYPE_DEPTH = 5;

fn void add_workspace_supertype_members_depth(Object* items, WorkspaceIndex* workspace, DocumentStore* store,
		String supertype_name, String prefix, int depth) {
	if (supertype_name.len == 0 || depth > MAX_SUPERTYPE_DEPTH) return;

	// Try the member cache first (fast path)
	if (try members = workspace.lookup_members(supertype_name)) {
		add_members_from_cache(items, members, prefix);

		// Continue walking supertypes
		List{usz}* indices = workspace.lookup_by_name(supertype_name) ?? null;
		if (indices != null) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
				if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
					sym.kind != SymbolKind.OBJECT) continue;
				for (usz s = 0; s < sym.supertype_count; s++) {
					add_workspace_supertype_members_depth(items, workspace, store, sym.supertypes[s], prefix, depth + 1);
				}
				return;
			}
		}
		return;
	}

	// Fall back to parsing (cache miss)
	List{usz}* indices = workspace.lookup_by_name(supertype_name) ?? null;
	if (indices == null) return;

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));

		if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
			sym.kind != SymbolKind.OBJECT) continue;

		String content;
		char[] disk_data;

		if (try doc = store.get(sym.uri)) {
			content = doc.content;
		} else {
			String file_path = workspace::uri_to_path(sym.uri);
			if (try d = std::io::file::load(tmem, file_path)) {
				disk_data = d;
				content = (String)disk_data;
			} else {
				continue;
			}
		}

		ParseResult* pr = mem::new(ParseResult);
		defer mem::free(pr);
		parser::parse(content, pr);

		add_members_from_class_ast(items, pr, content, supertype_name, prefix);

		// Continue walking supertypes
		for (usz s = 0; s < sym.supertype_count; s++) {
			add_workspace_supertype_members_depth(items, workspace, store, sym.supertypes[s], prefix, depth + 1);
		}
		return;
	}
}

/**
 * Add stdlib extension function completions that are available on
 * the given receiver type.
 */
fn void add_stdlib_receiver_completions(Object* items, TypeRef* receiver_type, String prefix) {
	if (receiver_type.kind == UNKNOWN) return;

	String type_name = receiver_type.name;
	if (type_name.len == 0) return;

	// Look up stdlib symbols with matching receiver
	StdlibSymbol*[64] matches;
	usz count = stdlib::lookup_by_receiver(type_name, &matches);

	for (usz i = 0; i < count; i++) {
		StdlibSymbol* sym = matches[i];

		if (prefix.len > 0 && !sym.name.starts_with(prefix)) continue;
		if (prefix.len > 0 && sym.name == prefix) continue;

		// Check for duplicates with already-added items
		bool already_present = false;
		for (usz j = 0; j < items.get_len(); j++) {
			Object* existing = items.get_at(j);
			if (try label = existing.get_string("label")) {
				if (label == sym.name) {
					already_present = true;
					break;
				}
			}
		}
		if (already_present) continue;

		Object* item = object::new_obj(tmem);
		item.set("label", sym.name);
		item.set("kind", stdlib_kind_to_completion_kind(sym.kind));
		item.set("detail", sym.package_name);

		// Data for lazy resolve
		Object* data = object::new_obj(tmem);
		data.set("source", "stdlib");
		data.set("name", sym.name);
		data.set("package", sym.package_name);
		item.set("data", data);

		items.push(item);
	}
}

// ── Workspace completions ─────────────────────────────────────────

/**
 * Add completion items from the workspace index for symbols matching
 * the given prefix. Skips symbols from the current document (already
 * covered by identifier completions) and deduplicates by name.
 * Uses import map to prioritize imported symbols.
 */
fn void add_workspace_completions(Object* items, WorkspaceIndex* workspace, String prefix, String current_uri, ParseResult* pr) {
	// Build import map for import-aware filtering
	ImportMap imports;
	if (pr != null) {
		imports = workspace::build_import_map(pr);
	} else {
		imports = (ImportMap) {};
	}

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

		// Skip symbols not reachable via module dependency graph
		if (!workspace.is_module_visible(sym.uri, current_uri)) continue;

		// Check import visibility
		String visible_name = workspace::is_symbol_visible(sym, &imports, sym.name);
		bool is_imported = visible_name.len > 0;

		// Use visible name (alias) for display if available, otherwise real name
		String display_name = is_imported ? visible_name : sym.name;

		// Filter by prefix (using display name for alias matching)
		if (prefix.len > 0 && !display_name.starts_with(prefix)) continue;

		// Skip exact matches
		if (prefix.len > 0 && display_name == prefix) continue;

		// Dedup check
		bool already_seen = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen_buf[j] == display_name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		if (seen_count < 256) {
			seen_buf[seen_count] = display_name;
			seen_count++;
		}

		Object* item = object::new_obj(tmem);
		item.set("label", display_name);
		item.set("kind", symbol_kind_to_completion_kind(sym.kind));
		// Detail shows file origin
		item.set("detail", sym.uri);
		// Imported symbols sort before non-imported ones
		if (is_imported) {
			item.set("sortText", display_name);
		} else {
			DString sort_text;
			sort_text.tinit();
			sort_text.appendf("~%s", display_name); // '~' sorts after letters
			item.set("sortText", sort_text.str_view());
		}
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

		// Data for lazy resolve
		Object* data = object::new_obj(tmem);
		data.set("source", "stdlib");
		data.set("name", sym.name);
		data.set("package", sym.package_name);
		item.set("data", data);

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

		// Data for lazy resolve
		Object* data = object::new_obj(tmem);
		data.set("source", "jdk");
		data.set("name", sym.name);
		data.set("package", sym.package_name);
		item.set("data", data);

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

		// Data for lazy resolve
		Object* data = object::new_obj(tmem);
		data.set("source", "dep");
		data.set("name", sym.name);
		data.set("package", sym.package_name);
		item.set("data", data);

		items.push(item);
	}
}
