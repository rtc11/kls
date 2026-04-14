module kls::lsp::diagnostics;

import std::io;
import std::collections::object;
import kls::json_rpc;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::stdlib;
import kls::kotlin::jdk_symbols;
import kls::workspace;
import kls::deps::jar_index;

/**
 * Run the lexer on content and return a JSON array of LSP Diagnostic
 * objects for lexer errors.  Parser errors are added from the cached
 * AST when available and the source is lexically clean.
 * Unused imports are tagged with DiagnosticTag.Unnecessary (1).
 * Unresolved references that can be resolved via imports are tagged as Hint.
 *
 * `workspace` may be null (e.g. in tests); when null the unresolved-reference
 * pass is skipped.
 */
fn Object* build_diagnostics_array(String content, ParseResult* ast, WorkspaceIndex* workspace = null) {
	Object* diagnostics = object::new_obj(tmem);

	if (content.len == 0) {
		return diagnostics;
	}

	// ── Lexer errors (ERROR tokens) ───────────────────────────────
	usz lexer_error_count = 0;
	Lexer lex = lexer::init(content);
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		if (tok.kind == ERROR) {
			lexer_error_count++;
			Object* diag = object::new_obj(tmem);

			Object* range = object::new_obj(tmem);
			Object* start = object::new_obj(tmem);
			start.set("line", (int)tok.line);
			start.set("character", (int)tok.col);
			Object* end = object::new_obj(tmem);
			end.set("line", (int)tok.line);
			end.set("character", (int)(tok.col + tok.len));
			range.set("start", start);
			range.set("end", end);

			diag.set("range", range);
			diag.set("severity", 1); // DiagnosticSeverity.Error
			diag.set("source", "kls");

			DString message;
			message.tinit();
			if (tok.text.len > 0) {
				message.appendf("Unexpected character: '%s'", tok.text);
			} else {
				message.appendf("Unexpected character");
			}
			diag.set("message", message.str_view());

			diagnostics.push(diag);
		}
	}

	// ── Parser errors (structural) ────────────────────────────────
	// Only include parser errors when the source is lexically clean.
	// If there are lexer errors, the parser will also trip on them,
	// producing redundant or misleading messages.
	if (lexer_error_count == 0 && ast != null) {
		for (usz i = 0; i < ast.error_count; i++) {
			ParseError* pe = &ast.errors[i];
			Object* diag = object::new_obj(tmem);

			Object* range = object::new_obj(tmem);
			Object* start = object::new_obj(tmem);
			start.set("line", (int)pe.line);
			start.set("character", (int)pe.col);
			Object* end = object::new_obj(tmem);
			end.set("line", (int)pe.line);
			// Use at least 1 character width for the diagnostic range
			uint end_col = pe.col + (pe.len > 0 ? pe.len : 1);
			end.set("character", (int)end_col);
			range.set("start", start);
			range.set("end", end);

			diag.set("range", range);
			diag.set("severity", 1); // DiagnosticSeverity.Error
			diag.set("source", "kls");
			diag.set("message", pe.message);

			diagnostics.push(diag);
		}
	}

	// ── Unused imports (DiagnosticTag.Unnecessary) ────────────────
	// Only check when the source is lexically clean and we have an AST.
	if (lexer_error_count == 0 && ast != null) {
		add_unused_import_diagnostics(diagnostics, content, ast);
	}

	// ── Unresolved references (Hint with import suggestion) ───────
	// Only when lexically clean, AST available, and workspace is known.
	if (lexer_error_count == 0 && ast != null && workspace != null) {
		add_unresolved_reference_diagnostics(diagnostics, content, ast, workspace);
	}

	return diagnostics;
}

/**
 * Extract the simple (short) name from an import declaration.
 * For aliased imports (import foo.Bar as Baz), returns the alias ("Baz").
 * For normal imports (import foo.Bar), returns the last segment ("Bar").
 * For wildcard imports (import foo.*), returns "".
 */
fn String import_simple_name(AstNode* node) {
	// Aliased import: name field is set to the alias
	if (node.name.len > 0) {
		return node.name;
	}

	String path = node.extra_text;
	if (path.len == 0) return "";

	// Wildcard import: skip
	if (path[path.len - 1] == '*') return "";

	// Find last '.' and return the segment after it
	usz last_dot = path.len;
	for (usz i = path.len; i > 0; i--) {
		if (path[i - 1] == '.') {
			last_dot = i - 1;
			break;
		}
	}

	if (last_dot < path.len) {
		return path[last_dot + 1..];
	}

	// No dot: single-segment import (rare but valid)
	return path;
}

/**
 * Check if a given simple name is used anywhere in the file body
 * (outside of package/import declarations) by lexer-scanning.
 */
fn bool is_import_name_used(String content, String simple_name) {
	Lexer lex = lexer::init(content);
	bool in_package_or_import = false;
	while (true) {
		Token t = lex.next();
		if (t.kind == EOF) break;

		// Enter skip mode for package/import paths
		if (t.kind == KW_PACKAGE || t.kind == KW_IMPORT) {
			in_package_or_import = true;
			continue;
		}

		// Skip identifiers inside package/import paths
		if (in_package_or_import) {
			if (t.kind == IDENTIFIER || t.kind == DOT || t.kind == MULT
				|| t.kind == KW_AS) continue;
			in_package_or_import = false;
		}

		if (t.kind != IDENTIFIER) continue;
		if (t.text == simple_name) return true;
	}
	return false;
}

/**
 * Scan AST for IMPORT_DECL nodes whose imported name is never used
 * in the file body and append Hint-severity diagnostics with
 * DiagnosticTag.Unnecessary (1).
 */
fn void add_unused_import_diagnostics(Object* diagnostics, String content, ParseResult* ast) {
	// The FILE node is always at index 0; iterate its IMPORT_DECL children.
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* node = &ast.nodes[i];
		if (node.kind != IMPORT_DECL) continue;
		// IMPORT_DECL nodes are direct children of FILE (parent == 0)
		if (node.parent != 0) continue;

		String simple_name = import_simple_name(node);
		if (simple_name.len == 0) continue; // wildcard or empty

		if (!is_import_name_used(content, simple_name)) {
			Object* diag = object::new_obj(tmem);

			Object* range = object::new_obj(tmem);
			Object* start = object::new_obj(tmem);
			start.set("line", (int)node.start_line);
			start.set("character", (int)node.start_col);
			Object* end_pos = object::new_obj(tmem);
			end_pos.set("line", (int)node.end_line);
			end_pos.set("character", (int)node.end_col);
			range.set("start", start);
			range.set("end", end_pos);

			diag.set("range", range);
			diag.set("severity", 4); // DiagnosticSeverity.Hint
			diag.set("source", "kls");

			DString message;
			message.tinit();
			message.appendf("Unused import: %s", node.extra_text);
			diag.set("message", message.str_view());

			// DiagnosticTag.Unnecessary = 1
			Object* tags = object::new_obj(tmem);
			tags.push(object::new_int(1, tmem));
			diag.set("tags", tags);

			diagnostics.push(diag);
		}
	}
}

// ── Kotlin auto-imported package prefixes ────────────────────────
// Symbols from these packages are available without an explicit import.
const String[*] KOTLIN_AUTO_IMPORT_PACKAGES = {
	"kotlin",
	"kotlin.annotation",
	"kotlin.collections",
	"kotlin.comparisons",
	"kotlin.io",
	"kotlin.ranges",
	"kotlin.sequences",
	"kotlin.text",
};

/**
 * Check if a name is defined in the scope chain by walking the AST.
 * Collects PROPERTY_DECL, FUN_DECL, CLASS_DECL, INTERFACE_DECL,
 * OBJECT_DECL, PARAM, ENUM_ENTRY, and TYPEALIAS_DECL names from
 * parent scopes up to FILE level. Also includes import simple names
 * at the FILE level.
 */
fn bool is_name_in_scope(ParseResult* ast, String name, uint name_offset) {
	// First, find the innermost scope containing name_offset
	uint scope_idx = 0; // FILE node
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (!is_scope_node(n.kind)) continue;
		if (name_offset >= n.start_offset && name_offset < n.end_offset) {
			scope_idx = i;
		}
	}

	// Walk from innermost scope outward to FILE
	uint current = scope_idx;
	while (true) {
		// Search direct children of this scope for matching declarations
		for (uint i = 0; i < ast.node_count; i++) {
			AstNode* n = &ast.nodes[i];
			if (n.parent != current) continue;
			if (n.name != name) continue;
			if (is_definition_target(n.kind)) return true;
		}

		// At FILE level, also check import simple names
		if (current == 0) {
			for (uint i = 0; i < ast.node_count; i++) {
				AstNode* n = &ast.nodes[i];
				if (n.kind != IMPORT_DECL) continue;
				if (n.parent != 0) continue;
				String simple = import_simple_name(n);
				if (simple == name) return true;
				// Check wildcard imports: we can't resolve them, so
				// assume the name could be from a wildcard import
			}
			break;
		}

		// Move to parent scope
		AstNode* scope = &ast.nodes[current];
		if (scope.parent == ast::NO_PARENT) break;
		current = scope.parent;
	}

	return false;
}

/**
 * Check if a node kind represents a scope that can contain declarations.
 */
fn bool is_scope_node(NodeKind kind) {
	switch (kind) {
		case FILE:
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case FUN_DECL:
		case BLOCK:
		case FOR_STMT:
		case CATCH_CLAUSE:
		case LAMBDA_EXPR:
			return true;
		default:
			return false;
	}
}

/**
 * Check if a node kind can be a definition target (declarations + parameters).
 */
fn bool is_definition_target(NodeKind kind) {
	if (ast::is_declaration(kind)) return true;
	return kind == PARAM;
}

/**
 * Check if a NAME_EXPR node is the child (member) part of a DOT_EXPR.
 * Such names require type information to resolve, so we skip them.
 */
fn bool is_dot_member(ParseResult* ast, uint node_idx) {
	AstNode* n = &ast.nodes[node_idx];
	if (n.parent == ast::NO_PARENT) return false;
	AstNode* parent = &ast.nodes[n.parent];
	// If parent is DOT_EXPR, check if this node is NOT the first child.
	// The first child is the receiver, the name field on DOT_EXPR is the member.
	// But actually, NAME_EXPR used as the leftmost identifier in a chain
	// IS the receiver, which we DO want to check. The DOT_EXPR member name
	// is stored in the DOT_EXPR's name field, not as a separate NAME_EXPR child.
	// So NAME_EXPR children of DOT_EXPR are receivers -- we check them.
	//
	// However if the NAME_EXPR is a child of CALL_EXPR whose parent is DOT_EXPR,
	// then the CALL_EXPR's callee is the member name -- skip it.
	if (parent.kind == CALL_EXPR) {
		if (parent.parent != ast::NO_PARENT) {
			AstNode* grandparent = &ast.nodes[parent.parent];
			if (grandparent.kind == DOT_EXPR) {
				// This call expr is a member call (e.g., foo.bar())
				// The NAME_EXPR callee is the member -- skip
				return true;
			}
		}
	}
	return false;
}

/**
 * Check if a name is from Kotlin's auto-imported packages or java.lang.
 * These names are always available without explicit import.
 * On Kotlin/JVM, java.lang.* is also auto-imported.
 */
fn bool is_auto_imported(String name) {
	// Check stdlib: look for the name and see if its package is auto-imported
	StdlibSymbol*[16] matches;
	usz count = stdlib::lookup_all_by_name(name, &matches);
	for (usz i = 0; i < count; i++) {
		for (usz j = 0; j < KOTLIN_AUTO_IMPORT_PACKAGES.len; j++) {
			if (matches[i].package_name == KOTLIN_AUTO_IMPORT_PACKAGES[j]) {
				return true;
			}
		}
	}

	// Check JDK: java.lang.* is auto-imported on Kotlin/JVM
	if (jdk_symbols::is_java_lang_symbol(name)) {
		return true;
	}

	return false;
}

/**
 * Check if any wildcard import in the file covers a given package name.
 * E.g., if the file has `import java.util.*`, then package "java.util" is covered.
 */
fn bool is_covered_by_wildcard_import(ParseResult* ast, String package_name) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL || n.parent != 0) continue;
		String path = n.extra_text;
		if (path.len == 0) continue;
		// Wildcard: path ends with ".*"
		if (path.len >= 2 && path[path.len - 1] == '*' && path[path.len - 2] == '.') {
			// Package prefix is everything before ".*"
			String pkg_prefix = path[:path.len - 2];
			if (pkg_prefix == package_name) return true;
		}
	}
	return false;
}

/**
 * Try to find an importable symbol matching `name` in stdlib, deps, or workspace.
 * Returns true if at least one candidate exists, and fills `import_path_buf`
 * with up to `buf_len` distinct import paths (e.g., "java.util.UUID").
 * Returns the number of candidates written.
 */
fn usz find_import_candidates(String name, WorkspaceIndex* workspace,
	String[] import_path_buf, String[] package_buf) {
	usz count = 0;

	// Track seen import paths to deduplicate
	String[32] seen;
	usz seen_count = 0;

	// 1. Check stdlib
	StdlibSymbol*[16] std_matches;
	usz std_count = stdlib::lookup_all_by_name(name, &std_matches);
	for (usz i = 0; i < std_count && count < import_path_buf.len; i++) {
		DString path;
		path.tinit();
		path.appendf("%s.%s", std_matches[i].package_name, name);
		String path_str = path.str_view();

		// Dedup
		bool dup = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen[j] == path_str) { dup = true; break; }
		}
		if (dup) continue;

		import_path_buf[count] = path_str;
		package_buf[count] = std_matches[i].package_name;
		if (seen_count < 32) { seen[seen_count] = path_str; seen_count++; }
		count++;
	}

	// 2. Check JDK symbols (curated table of common Java platform classes)
	StdlibSymbol*[16] jdk_matches;
	usz jdk_count = jdk_symbols::lookup_all_by_name(name, &jdk_matches);
	for (usz i = 0; i < jdk_count && count < import_path_buf.len; i++) {
		DString path;
		path.tinit();
		path.appendf("%s.%s", jdk_matches[i].package_name, name);
		String path_str = path.str_view();

		// Dedup
		bool dup = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen[j] == path_str) { dup = true; break; }
		}
		if (dup) continue;

		import_path_buf[count] = path_str;
		package_buf[count] = jdk_matches[i].package_name;
		if (seen_count < 32) { seen[seen_count] = path_str; seen_count++; }
		count++;
	}

	// 3. Check dependency index
	DepSymbol*[16] dep_matches;
	usz dep_count = workspace.dep_index.lookup_by_name(name, &dep_matches);
	for (usz i = 0; i < dep_count && count < import_path_buf.len; i++) {
		// Only suggest class-level symbols (not methods/fields)
		if (dep_matches[i].kind == DEP_METHOD || dep_matches[i].kind == DEP_FIELD) continue;

		DString path;
		path.tinit();
		path.appendf("%s.%s", dep_matches[i].package_name, name);
		String path_str = path.str_view();

		bool dup = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen[j] == path_str) { dup = true; break; }
		}
		if (dup) continue;

		import_path_buf[count] = path_str;
		package_buf[count] = dep_matches[i].package_name;
		if (seen_count < 32) { seen[seen_count] = path_str; seen_count++; }
		count++;
	}

	// 4. Check workspace index
	if (try indices = workspace.lookup_by_name(name)) {
		for (usz i = 0; i < indices.len() && count < import_path_buf.len; i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.package_name.len == 0) continue;

			DString path;
			path.tinit();
			path.appendf("%s.%s", sym.package_name, name);
			String path_str = path.str_view();

			bool dup = false;
			for (usz j = 0; j < seen_count; j++) {
				if (seen[j] == path_str) { dup = true; break; }
			}
			if (dup) continue;

			import_path_buf[count] = path_str;
			package_buf[count] = sym.package_name;
			if (seen_count < 32) { seen[seen_count] = path_str; seen_count++; }
			count++;
		}
	}

	return count;
}

/**
 * Scan AST for NAME_EXPR nodes whose identifiers are not resolvable in
 * the current scope or via imports, but ARE found in stdlib/deps/workspace.
 * Emits Hint-severity diagnostics for each unresolved reference.
 */
fn void add_unresolved_reference_diagnostics(Object* diagnostics, String content,
	ParseResult* ast, WorkspaceIndex* workspace) {
	// Track names we've already checked to avoid re-scanning
	String[256] checked_names;
	bool[256] checked_results; // true = resolved, false = unresolved (but importable)
	usz checked_count = 0;

	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* node = &ast.nodes[i];
		if (node.kind != NAME_EXPR) continue;
		if (node.name.len == 0) continue;

		String name = node.name;

		// Skip the implicit lambda parameter `it`
		if (name == "it") continue;

		// Skip if this is a member access (part of a dot chain)
		if (is_dot_member(ast, i)) continue;

		// Check the dedup cache
		bool already_checked = false;
		bool cached_resolved = false;
		for (usz j = 0; j < checked_count; j++) {
			if (checked_names[j] == name) {
				already_checked = true;
				cached_resolved = checked_results[j];
				break;
			}
		}

		if (already_checked) {
			if (cached_resolved) continue; // known to be resolved
			// known unresolved -- emit diagnostic (fall through)
		} else {
			// ── Check if the name is resolvable ─────────────────────
			bool resolved = false;

			// 1. Check if it's declared in scope (local vars, params, class members, etc.)
			if (is_name_in_scope(ast, name, node.name_offset)) {
				resolved = true;
			}

			// 2. Check if it's a Kotlin auto-imported name
			if (!resolved && is_auto_imported(name)) {
				resolved = true;
			}

			// 3. Check if there's a wildcard import covering a package that has this symbol
			if (!resolved) {
				String[16] import_paths;
				String[16] packages;
				usz candidate_count = find_import_candidates(name, workspace, &import_paths, &packages);
				if (candidate_count > 0) {
					// Check if any candidate's package is covered by a wildcard import
					for (usz c = 0; c < candidate_count; c++) {
						if (is_covered_by_wildcard_import(ast, packages[c])) {
							resolved = true;
							break;
						}
					}
					// If not resolved by wildcard, it IS unresolved but importable
				} else {
					// Not found in any index -- don't flag it, could be from
					// implicit scope (receiver members, inherited names, etc.)
					resolved = true;
				}
			}

			// Cache the result
			if (checked_count < 256) {
				checked_names[checked_count] = name;
				checked_results[checked_count] = resolved;
				checked_count++;
			}

			if (resolved) continue;
		}

		// ── Emit Hint diagnostic ────────────────────────────────────
		Object* diag = object::new_obj(tmem);

		Object* range = object::new_obj(tmem);
		Object* start = object::new_obj(tmem);
		start.set("line", (int)node.name_line);
		start.set("character", (int)node.name_col);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", (int)node.name_line);
		end_pos.set("character", (int)(node.name_col + node.name_len));
		range.set("start", start);
		range.set("end", end_pos);

		diag.set("range", range);
		diag.set("severity", 4); // DiagnosticSeverity.Hint
		diag.set("source", "kls");

		DString message;
		message.tinit();
		message.appendf("Unresolved reference: '%s'", name);
		diag.set("message", message.str_view());

		diagnostics.push(diag);
	}
}

/**
 * Publish diagnostics for a document to the client.
 * Uses the cached AST from the DocumentStore for parser errors.
 * Sends a textDocument/publishDiagnostics notification.
 *
 * `workspace` may be null; when non-null, unresolved-reference diagnostics
 * are included (suggesting possible imports).
 */
fn void publish_diagnostics(DocumentStore* store, String uri, WorkspaceIndex* workspace = null) {
	Document* doc = store.get(uri) ?? null;
	String content;
	if (doc != null) {
		content = doc.content;
	} else {
		content = "";
	}

	// Get cached AST (parses lazily if needed); null if doc not found
	ParseResult* ast = store.get_ast(uri) ?? null;

	Object* diagnostics = build_diagnostics_array(content, ast, workspace);

	Object* params = object::new_obj(tmem);
	params.set("uri", uri);
	params.set("diagnostics", diagnostics);

	json_rpc::send_notification("textDocument/publishDiagnostics", params);
	io::eprintfn("[kls] Published diagnostics for %s", uri);
}
