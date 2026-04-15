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

	// Check if we're in a dot-completion context (after . or ?.)
	bool is_dot_context = is_dot_completion_context(doc.content, line, character, prefix);

	// Build completion items
	Object* items = object::new_obj(tmem);

	if (is_dot_context) {
		// Dot-completion: resolve receiver type and offer members
		add_dot_completions(items, store, workspace, uri, doc.content, line, character, prefix);
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

	// If we couldn't resolve via AST, try to infer from the name
	// (e.g., receiver is a class name -> offer static members)
	if (receiver_type.kind == UNKNOWN) {
		// Try literal type heuristic based on the receiver text
		receiver_type = guess_receiver_type(content, receiver_name, line, character);
	}

	if (receiver_type.kind == UNKNOWN) return;

	// Look up members for this type from the hardcoded type tables
	MemberInfo[128] members;
	usz member_count = types::lookup_members(&receiver_type, members[..]);

	for (usz i = 0; i < member_count; i++) {
		MemberInfo* m = &members[i];

		// Filter by prefix if one exists
		if (prefix.len > 0 && !m.name.starts_with(prefix)) continue;
		if (prefix.len > 0 && m.name == prefix) continue;

		Object* item = object::new_obj(tmem);
		item.set("label", m.name);
		item.set("kind", m.kind);
		item.set("detail", m.detail);

		// Add documentation with signature
		if (m.signature.len > 0) {
			Object* doc_obj = object::new_obj(tmem);
			doc_obj.set("kind", "markdown");
			DString doc_val;
			doc_val.tinit();
			doc_val.appendf("```kotlin\n%s\n```", m.signature);
			doc_obj.set("value", doc_val.str_view());
			item.set("documentation", doc_obj);
		}

		items.push(item);
	}

	// Look up members from the workspace index for user-defined types
	if (workspace != null) {
		add_workspace_class_members(items, workspace, store, &receiver_type, prefix);
	}

	// Also add receiver-specific stdlib completions
	add_stdlib_receiver_completions(items, &receiver_type, prefix);
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

	// Look up the type name in the workspace index
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

		add_members_from_class_ast(items, pr, type_name, prefix);

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
fn void add_members_from_class_ast(Object* items, ParseResult* pr, String class_name, String prefix) {
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
					detail = child.type_text.len > 0 ? child.type_text : "Unit";
					build_fun_signature(&sig, child, pr, i);
				case PROPERTY_DECL:
					kind = COMPLETION_KIND_PROPERTY;
					detail = child.type_text.len > 0 ? child.type_text : "";
					build_property_signature(&sig, child);
				case CLASS_DECL:
				case INTERFACE_DECL:
				case OBJECT_DECL:
					kind = COMPLETION_KIND_CLASS;
					detail = "nested class";
				case PARAM:
					// Data class constructor params with val/var
					if ((child.mod_flags & ast::MOD_VAR) != 0 || (child.mod_flags & ast::MOD_FINAL) != 0) {
						kind = COMPLETION_KIND_PROPERTY;
						detail = child.type_text.len > 0 ? child.type_text : "";
						build_property_signature(&sig, child);
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
				Object* doc_obj = object::new_obj(tmem);
				doc_obj.set("kind", "markdown");
				DString doc_val;
				doc_val.tinit();
				doc_val.appendf("```kotlin\n%s\n```", sig_str);
				doc_obj.set("value", doc_val.str_view());
				item.set("documentation", doc_obj);
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
fn void build_fun_signature(DString* sig, AstNode* fun_node, ParseResult* pr, uint class_idx) {
	sig.appendf("fun %s(", fun_node.name);

	bool first = true;
	for (uint k = 0; k < pr.node_count; k++) {
		if (pr.nodes[k].parent != ast::node_index(pr, fun_node)) continue;
		if (pr.nodes[k].kind != PARAM) continue;
		if (!first) sig.append(", ");
		first = false;
		if (pr.nodes[k].name.len > 0) {
			sig.appendf("%s", pr.nodes[k].name);
		}
		if (pr.nodes[k].type_text.len > 0) {
			sig.appendf(": %s", pr.nodes[k].type_text);
		}
	}

	sig.append(")");
	if (fun_node.type_text.len > 0) {
		sig.appendf(": %s", fun_node.type_text);
	}
}

/**
 * Build a property signature string for documentation:
 * "val name: Type" or "var name: Type"
 */
fn void build_property_signature(DString* sig, AstNode* prop_node) {
	String keyword = (prop_node.mod_flags & ast::MOD_VAR) != 0 ? "var" : "val";
	sig.appendf("%s %s", keyword, prop_node.name);
	if (prop_node.type_text.len > 0) {
		sig.appendf(": %s", prop_node.type_text);
	}
}

/**
 * Look up a supertype in the workspace and add its members.
 * This enables inherited member completion (one level deep to avoid
 * infinite recursion with cyclic type hierarchies).
 */
fn void add_workspace_supertype_members(Object* items, WorkspaceIndex* workspace, DocumentStore* store,
		String supertype_name, String prefix) {
	if (supertype_name.len == 0) return;

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

		add_members_from_class_ast(items, pr, supertype_name, prefix);
		return; // Only one level of supertypes (avoids infinite recursion)
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
