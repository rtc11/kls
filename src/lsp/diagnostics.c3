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
import kls::kotlin::types;
import kls::kotlin::symbols;
import kls::workspace;
import kls::deps::jar_index;
import kls::log;

/**
 * Run the lexer on content and return a JSON array of LSP Diagnostic
 * objects for lexer errors.  Parser errors are added from the cached
 * AST when available and the source is lexically clean.
 * Unused imports are tagged with DiagnosticTag.Unnecessary (1).
 * Unused local variables are tagged with DiagnosticTag.Unnecessary (1).
 * References to @Deprecated declarations are tagged with DiagnosticTag.Deprecated (2).
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

	// ── Deprecated usage (DiagnosticTag.Deprecated) ──────────────
	// Flag NAME_EXPR references to @Deprecated declarations.
	if (lexer_error_count == 0 && ast != null) {
		add_deprecated_usage_diagnostics(diagnostics, content, ast, workspace);
	}

	// ── Unused local variables (DiagnosticTag.Unnecessary) ───────
	// Flag val/var inside function bodies that are never read.
	if (lexer_error_count == 0 && ast != null) {
		add_unused_local_diagnostics(diagnostics, content, ast);
	}

	// ── Val reassignment (Error) ─────────────────────────────────
	// Flag assignments to val-declared local variables.
	if (lexer_error_count == 0 && ast != null) {
		add_val_reassignment_diagnostics(diagnostics, content, ast);
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
 * Check if a NAME_EXPR node is a named argument label in a function call.
 * e.g., `type` in `Lib(type = "jar")` -- the AST looks like:
 *   CALL_EXPR -> ASSIGNMENT_EXPR -> NAME_EXPR (the label)
 * These are parameter names, not variable references, so we skip them.
 */
fn bool is_named_argument_label(ParseResult* ast, uint node_idx) {
	AstNode* n = &ast.nodes[node_idx];
	if (n.parent == ast::NO_PARENT) return false;
	AstNode* parent = &ast.nodes[n.parent];
	// Named arg pattern: NAME_EXPR is LHS of ASSIGNMENT_EXPR inside CALL_EXPR
	if (parent.kind != ASSIGNMENT_EXPR) return false;
	// Verify this NAME_EXPR is the left-hand side (first child) of the assignment
	// by checking that the NAME_EXPR starts at the same offset as the assignment
	if (n.start_offset != parent.start_offset) return false;
	// Check grandparent is CALL_EXPR
	if (parent.parent == ast::NO_PARENT) return false;
	AstNode* grandparent = &ast.nodes[parent.parent];
	return grandparent.kind == CALL_EXPR;
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
 * Get the package name declared in the file's AST (from PACKAGE_DECL).
 * Returns "" if no package declaration is found.
 */
fn String get_file_package(ParseResult* ast) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind == PACKAGE_DECL && n.parent == 0) {
			return n.extra_text;
		}
	}
	return "";
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

// ── Receiver lambda member resolution ────────────────────────────
// When a NAME_EXPR is inside a receiver lambda (e.g., Module.() -> Unit),
// the name may refer to a member of the receiver type. We must not flag
// these as unresolved references.

/**
 * Find the nearest LAMBDA_EXPR ancestor of a node.
 * Returns the index of the LAMBDA_EXPR, or ast::NO_PARENT if not inside a lambda.
 */
fn uint find_lambda_ancestor(ParseResult* ast, uint node_idx) {
	uint current = node_idx;
	while (current != ast::NO_PARENT) {
		AstNode* n = &ast.nodes[current];
		if (n.kind == LAMBDA_EXPR && current != node_idx) {
			return current;
		}
		current = n.parent;
	}
	return ast::NO_PARENT;
}

/**
 * Find the CALL_EXPR parent of a LAMBDA_EXPR.
 * Trailing lambdas are direct children of CALL_EXPR.
 * Returns the CALL_EXPR index, or ast::NO_PARENT if not found.
 */
fn uint find_call_parent_of_lambda(ParseResult* ast, uint lambda_idx) {
	AstNode* lambda = &ast.nodes[lambda_idx];
	if (lambda.parent == ast::NO_PARENT) return ast::NO_PARENT;

	AstNode* parent = &ast.nodes[lambda.parent];
	if (parent.kind == CALL_EXPR) {
		return lambda.parent;
	}
	return ast::NO_PARENT;
}

/**
 * Given a CALL_EXPR, find the receiver type name for the trailing lambda parameter.
 * Looks up the called function in the same file's AST, checking each parameter
 * for a function type with a receiver (e.g., Module.() -> Unit).
 *
 * Also handles Kotlin scope functions: apply, run, with, also, let.
 * For these, the receiver type comes from the call's receiver expression
 * or first argument.
 *
 * Returns the receiver type name (e.g., "Module"), or "" if none found.
 */
fn String find_receiver_type_for_call(ParseResult* ast, uint call_idx, WorkspaceIndex* workspace) {
	AstNode* call = &ast.nodes[call_idx];

	// Get the callee name. The parser copies the callee name into CALL_EXPR.name
	// for both simple calls (foo()) and member calls (obj.foo()).
	String callee_name = call.name;

	// Fallback: if CALL_EXPR.name is empty, check for a NAME_EXPR child
	if (callee_name.len == 0) {
		for (uint i = 0; i < ast.node_count; i++) {
			if (ast.nodes[i].parent == call_idx && ast.nodes[i].kind == NAME_EXPR) {
				callee_name = ast.nodes[i].name;
				break;
			}
		}
	}

	if (callee_name.len == 0) return "";

	// ── Handle Kotlin scope functions ─────────────────────────────
	// apply/run: receiver.apply { ... } → receiver type is the "this" type
	// with: with(receiver) { ... } → first arg type is "this" type
	// also/let: don't use receiver lambdas (they use `it`, not `this`)
	if (callee_name == "apply" || callee_name == "run") {
		// For receiver.apply { ... }, find the receiver's type.
		// The CALL_EXPR wraps DOT_EXPR as a child; DOT_EXPR's first child
		// is the receiver expression. We need to find what class that is.
		// Find DOT_EXPR child of CALL_EXPR
		for (uint i = 0; i < ast.node_count; i++) {
			if (ast.nodes[i].parent == call_idx && ast.nodes[i].kind == DOT_EXPR) {
				uint dot_idx = i;
				// Find NAME_EXPR child of DOT_EXPR (the receiver)
				for (uint j = 0; j < ast.node_count; j++) {
					if (ast.nodes[j].parent == dot_idx && ast.nodes[j].kind == NAME_EXPR) {
						String recv_name = ast.nodes[j].name;
						// Look up what type this variable is
						String recv_type = find_variable_type_name(ast, call_idx, recv_name);
						if (recv_type.len > 0) return recv_type;
						// If we can't resolve the variable type, try using the name directly
						// as a class name (e.g., Foo.apply { ... })
						if (is_class_name(ast, recv_name, workspace)) return recv_name;
						break;
					}
				}
				break;
			}
		}
		return "";
	}

	if (callee_name == "with") {
		// with(receiver) { ... } → first arg to with() is the receiver object
		// We'd need to resolve the first argument's type, which is complex.
		// For now, skip -- "with" is less common in DSL patterns.
		return "";
	}

	// ── Look up the function in the same file ─────────────────────
	// Search for FUN_DECL nodes with matching name
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if (n.name != callee_name) continue;

		// Found a matching function. Scan its PARAM children for a function type
		// with a receiver.
		String recv = find_receiver_param_type(ast, i);
		if (recv.len > 0) return recv;
	}

	// ── Look up in workspace index ────────────────────────────────
	if (workspace != null) {
		if (try indices = workspace.lookup_by_name(callee_name)) {
			for (usz j = 0; j < indices.len(); j++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(j));
				if (sym.kind != symbols::SymbolKind.FUNCTION) continue;
				// We need the function's source to examine parameters.
				// For workspace symbols we don't have the parameter types stored.
				// Fall through to check if the name might be a class with an extension function.
			}
		}
	}

	return "";
}

/**
 * Scan the PARAM children of a FUN_DECL for a function type parameter
 * that has a receiver (e.g., "Module.() -> Unit").
 * Returns the receiver type name, or "" if none found.
 */
fn String find_receiver_param_type(ParseResult* ast, uint fun_idx) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.parent != fun_idx) continue;
		if (n.kind != PARAM) continue;
		if (n.type_text.len == 0) continue;

		// Parse the type text and check for a receiver
		TypeRef tref = types::parse_type_text(n.type_text);
		if (tref.kind == FUNCTION && tref.receiver_type_name.len > 0) {
			return tref.receiver_type_name;
		}
	}
	return "";
}

/**
 * Try to find the type name of a variable by looking at its declaration
 * in the same file. Searches for PROPERTY_DECL or PARAM with matching name
 * that has a type_text.
 */
fn String find_variable_type_name(ParseResult* ast, uint scope_idx, String var_name) {
	// Walk parent scopes from scope_idx up to FILE looking for declarations
	uint current = scope_idx;
	while (current != ast::NO_PARENT) {
		for (uint i = 0; i < ast.node_count; i++) {
			AstNode* n = &ast.nodes[i];
			if (n.parent != current) continue;
			if (n.name != var_name) continue;
			if (n.kind == PROPERTY_DECL || n.kind == PARAM) {
				if (n.type_text.len > 0) {
					return n.type_text;
				}
			}
		}
		AstNode* scope = &ast.nodes[current];
		current = scope.parent;
	}
	return "";
}

/**
 * Check if a name refers to a class/interface/object declaration
 * in the same file or in the workspace.
 */
fn bool is_class_name(ParseResult* ast, String name, WorkspaceIndex* workspace) {
	// Check same-file AST
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.name != name) continue;
		if (n.kind == CLASS_DECL || n.kind == INTERFACE_DECL || n.kind == OBJECT_DECL) {
			return true;
		}
	}

	// Check workspace
	if (workspace != null) {
		if (try indices = workspace.lookup_by_name(name)) {
			for (usz j = 0; j < indices.len(); j++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(j));
				if (sym.kind == symbols::SymbolKind.CLASS ||
					sym.kind == symbols::SymbolKind.INTERFACE ||
					sym.kind == symbols::SymbolKind.OBJECT) {
					return true;
				}
			}
		}
	}

	return false;
}

/**
 * Check if a name is a member of a given class (by class name).
 * Searches the same-file AST for a CLASS_DECL/INTERFACE_DECL/OBJECT_DECL
 * with matching name, then checks its children for the member name.
 *
 * For data classes, constructor parameters with var/val (PARAM with
 * MOD_VAR or MOD_FINAL) are also members.
 */
fn bool is_member_of_class(ParseResult* ast, String class_name, String member_name, WorkspaceIndex* workspace) {
	// Search same-file AST
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.name != class_name) continue;
		if (n.kind != CLASS_DECL && n.kind != INTERFACE_DECL && n.kind != OBJECT_DECL) continue;

		// Check direct children for matching member declarations
		for (uint j = 0; j < ast.node_count; j++) {
			AstNode* child = &ast.nodes[j];
			if (child.parent != i) continue;
			if (child.name != member_name) continue;

			// FUN_DECL, PROPERTY_DECL are direct members
			if (child.kind == FUN_DECL || child.kind == PROPERTY_DECL) return true;

			// PARAM with MOD_VAR or MOD_FINAL (data class constructor params)
			if (child.kind == PARAM) {
				if ((child.mod_flags & ast::MOD_VAR) != 0 || (child.mod_flags & ast::MOD_FINAL) != 0) {
					return true;
				}
			}

			// ENUM_ENTRY, nested classes
			if (child.kind == ENUM_ENTRY || child.kind == CLASS_DECL ||
				child.kind == INTERFACE_DECL || child.kind == OBJECT_DECL) {
				return true;
			}
		}

		// Also check COMPANION_OBJECT_DECL children (companion members)
		for (uint j = 0; j < ast.node_count; j++) {
			AstNode* child = &ast.nodes[j];
			if (child.parent != i) continue;
			if (child.kind != COMPANION_OBJECT_DECL) continue;

			// Check children of the companion object
			for (uint k = 0; k < ast.node_count; k++) {
				AstNode* comp_child = &ast.nodes[k];
				if (comp_child.parent != j) continue;
				if (comp_child.name != member_name) continue;
				if (comp_child.kind == FUN_DECL || comp_child.kind == PROPERTY_DECL) return true;
			}
		}
	}

	// Search workspace for the class in other files
	if (workspace != null) {
		if (try indices = workspace.lookup_by_name(member_name)) {
			for (usz j = 0; j < indices.len(); j++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(j));
				// Workspace symbols don't have a class_name field directly,
				// but we could check the file URI and package to match.
				// For now, just check if the name exists in the workspace at all.
				// This is a conservative approach -- we err on the side of not flagging.
			}
		}
	}

	// If the class is not found in the same file, we can't verify members.
	// Be conservative: assume it COULD be a member to avoid false positives.
	// Only return false if we found the class but the member wasn't in it.
	bool class_found_in_ast = false;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.name == class_name &&
			(n.kind == CLASS_DECL || n.kind == INTERFACE_DECL || n.kind == OBJECT_DECL)) {
			class_found_in_ast = true;
			break;
		}
	}

	// Class not in this file -- be conservative, assume member exists
	if (!class_found_in_ast) return true;

	// Class was found but member was not -- it's not a member
	return false;
}

/**
 * Check if a NAME_EXPR is inside an extension function/property body and
 * could refer to an implicit `this` member of the receiver type.
 *
 * Walks the parent chain to find an enclosing FUN_DECL or PROPERTY_DECL
 * with a non-empty extra_text (the receiver type). Then checks if the
 * name is a member of that receiver class via is_member_of_class.
 */
fn bool is_in_extension_function_scope(ParseResult* ast, uint node_idx, String name, WorkspaceIndex* workspace) {
	uint current = ast.nodes[node_idx].parent;
	while (current != ast::NO_PARENT) {
		AstNode* n = &ast.nodes[current];
		if ((n.kind == FUN_DECL || n.kind == PROPERTY_DECL) && n.extra_text.len > 0) {
			String receiver = n.extra_text;
			// Strip nullable suffix for lookup
			if (receiver.len > 0 && receiver[receiver.len - 1] == '?') {
				receiver = receiver[:receiver.len - 1];
			}
			// Strip type parameters (e.g., "List<String>" -> "List")
			for (usz k = 0; k < receiver.len; k++) {
				if (receiver[k] == '<') {
					receiver = receiver[:k];
					break;
				}
			}
			return is_member_of_class(ast, receiver, name, workspace);
		}
		current = n.parent;
	}
	return false;
}

/**
 * Check if a NAME_EXPR is inside a receiver lambda and refers to a member
 * of the receiver type.
 *
 * Walk the parent chain to find a LAMBDA_EXPR, then its CALL_EXPR parent,
 * then resolve the called function's receiver lambda parameter type,
 * then check if the name is a member of that receiver class.
 */
fn bool is_receiver_lambda_member(ParseResult* ast, uint node_idx, String name, WorkspaceIndex* workspace) {
	// Walk up through potentially nested lambdas
	uint current = node_idx;
	while (true) {
		uint lambda_idx = find_lambda_ancestor(ast, current);
		if (lambda_idx == ast::NO_PARENT) return false;

		uint call_idx = find_call_parent_of_lambda(ast, lambda_idx);
		if (call_idx != ast::NO_PARENT) {
			String receiver_type = find_receiver_type_for_call(ast, call_idx, workspace);
			if (receiver_type.len > 0) {
				if (is_member_of_class(ast, receiver_type, name, workspace)) {
					return true;
				}
			}
		}

		// Try the next outer lambda (for nested receiver lambdas)
		current = lambda_idx;
	}
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

		// Skip if this is a named argument label (e.g., `type` in Lib(type = "jar"))
		if (is_named_argument_label(ast, i)) continue;

		// Skip if inside an extension function and the name could be an
		// implicit `this` member of the receiver type
		if (is_in_extension_function_scope(ast, i, name, workspace)) continue;

		// Skip if this name is inside a receiver lambda and refers to a
		// member of the receiver type (e.g., `src` inside Module.() -> Unit)
		// This check is per-occurrence (not cached) because it's position-dependent.
		if (is_receiver_lambda_member(ast, i, name, workspace)) continue;

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

			// 3. Check if there's a wildcard import covering a package that has this symbol,
			//    or if the symbol is in the same package as this file.
			if (!resolved) {
				String[16] import_paths;
				String[16] packages;
				usz candidate_count = find_import_candidates(name, workspace, &import_paths, &packages);
				if (candidate_count > 0) {
					// Get this file's package name
					String file_package = get_file_package(ast);

					for (usz c = 0; c < candidate_count; c++) {
						// Same-package symbols are always in scope
						if (file_package.len > 0 && packages[c] == file_package) {
							resolved = true;
							break;
						}
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
	log::debug("[kls] Published diagnostics for %s", uri);
}

// ── Deprecated usage diagnostics ─────────────────────────────────

/**
 * Collect names of declarations annotated with @Deprecated in the current
 * file's AST.  Stores up to `buf_len` names.
 */
fn usz collect_deprecated_names(ParseResult* ast, String[] buf) {
	usz count = 0;
	for (uint i = 0; i < ast.node_count && count < buf.len; i++) {
		AstNode* n = &ast.nodes[i];
		if (!ast::is_declaration(n.kind) && n.kind != PARAM) continue;
		if (n.name.len == 0) continue;
		if (n.has_annotation("Deprecated")) {
			// Deduplicate
			bool dup = false;
			for (usz j = 0; j < count; j++) {
				if (buf[j] == n.name) { dup = true; break; }
			}
			if (!dup) {
				buf[count] = n.name;
				count++;
			}
		}
	}
	return count;
}

/**
 * Check if a name is in the deprecated names set.
 */
fn bool is_deprecated_name(String name, String[] deprecated_names, usz count) {
	for (usz i = 0; i < count; i++) {
		if (deprecated_names[i] == name) return true;
	}
	return false;
}

/**
 * Scan for NAME_EXPR references to @Deprecated declarations and emit
 * Hint diagnostics with DiagnosticTag.Deprecated (2).
 *
 * Currently checks same-file declarations only.
 */
fn void add_deprecated_usage_diagnostics(Object* diagnostics, String content,
	ParseResult* ast, WorkspaceIndex* workspace) {
	// Collect deprecated declaration names from this file
	String[64] deprecated_names;
	usz dep_count = collect_deprecated_names(ast, &deprecated_names);

	if (dep_count == 0) return;

	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != NAME_EXPR) continue;
		if (n.name.len == 0) continue;

		if (!is_deprecated_name(n.name, deprecated_names[:dep_count], dep_count)) continue;

		Object* diag = object::new_obj(tmem);

		Object* range = object::new_obj(tmem);
		Object* start = object::new_obj(tmem);
		start.set("line", (int)n.name_line);
		start.set("character", (int)n.name_col);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", (int)n.name_line);
		end_pos.set("character", (int)(n.name_col + n.name_len));
		range.set("start", start);
		range.set("end", end_pos);

		diag.set("range", range);
		diag.set("severity", 4); // DiagnosticSeverity.Hint
		diag.set("source", "kls");

		DString message;
		message.tinit();
		message.appendf("'%s' is deprecated", n.name);
		diag.set("message", message.str_view());

		// DiagnosticTag.Deprecated = 2
		Object* tags = object::new_obj(tmem);
		tags.push(object::new_int(2, tmem));
		diag.set("tags", tags);

		diagnostics.push(diag);
	}
}

// ── Unused local variable diagnostics ────────────────────────────

/**
 * Check if a PROPERTY_DECL is a local variable (inside a function body,
 * lambda, or init block -- not a top-level or class member property).
 */
fn bool is_local_property(ParseResult* ast, uint node_idx) {
	AstNode* n = &ast.nodes[node_idx];
	if (n.kind != PROPERTY_DECL) return false;

	// Walk parent chain: must hit a FUN_DECL, LAMBDA_EXPR, or INIT_BLOCK
	// before hitting FILE or a class-like declaration
	uint current = n.parent;
	while (current != ast::NO_PARENT) {
		AstNode* p = &ast.nodes[current];
		switch (p.kind) {
			case FUN_DECL:
			case LAMBDA_EXPR:
			case INIT_BLOCK:
				return true;
			case FILE:
			case CLASS_DECL:
			case INTERFACE_DECL:
			case OBJECT_DECL:
			case COMPANION_OBJECT_DECL:
				return false;
			default:
				break;
		}
		current = p.parent;
	}
	return false;
}

/**
 * Check if a local variable name is used (referenced) anywhere after its
 * declaration within its containing scope. Scans NAME_EXPR nodes.
 */
fn bool is_local_name_used(ParseResult* ast, uint decl_idx) {
	AstNode* decl = &ast.nodes[decl_idx];
	String name = decl.name;
	if (name.len == 0) return true; // unnamed = destructuring, skip

	// Find any NAME_EXPR with this name that is NOT the declaration itself
	for (uint i = 0; i < ast.node_count; i++) {
		if (i == decl_idx) continue;
		AstNode* n = &ast.nodes[i];
		if (n.kind != NAME_EXPR) continue;
		if (n.name != name) continue;

		// Verify this NAME_EXPR is within the same scope as the declaration
		// by checking it shares a common scope ancestor
		// Simple approach: if start_offset > decl end_offset and same-ish scope, it's a use
		// But for correctness, just check that ANY NAME_EXPR with same name exists
		// after the declaration offset
		if (n.start_offset > decl.start_offset) return true;
	}
	return false;
}

/**
 * Scan for local val/var declarations that are never used and emit
 * Hint diagnostics with DiagnosticTag.Unnecessary (1).
 *
 * Skips properties starting with '_' (conventional "intentionally unused").
 */
fn void add_unused_local_diagnostics(Object* diagnostics, String content, ParseResult* ast) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (!is_local_property(ast, i)) continue;
		if (n.name.len == 0) continue;

		// Skip names starting with '_' (intentionally unused convention)
		if (n.name[0] == '_') continue;

		if (!is_local_name_used(ast, i)) {
			Object* diag = object::new_obj(tmem);

			Object* range = object::new_obj(tmem);
			Object* start = object::new_obj(tmem);
			start.set("line", (int)n.start_line);
			start.set("character", (int)n.start_col);
			Object* end_pos = object::new_obj(tmem);
			end_pos.set("line", (int)n.end_line);
			end_pos.set("character", (int)n.end_col);
			range.set("start", start);
			range.set("end", end_pos);

			diag.set("range", range);
			diag.set("severity", 4); // DiagnosticSeverity.Hint
			diag.set("source", "kls");

			DString message;
			message.tinit();
			bool is_var = (n.mod_flags & ast::MOD_VAR) != 0;
			if (is_var) {
				message.appendf("Variable '%s' is never used", n.name);
			} else {
				message.appendf("Value '%s' is never used", n.name);
			}
			diag.set("message", message.str_view());

			// DiagnosticTag.Unnecessary = 1
			Object* tags = object::new_obj(tmem);
			tags.push(object::new_int(1, tmem));
			diag.set("tags", tags);

			diagnostics.push(diag);
		}
	}
}

// ── Val reassignment diagnostics ──────────────────────────────────

/**
 * Detect assignments to val-declared local variables (which are immutable).
 * Scans for ASSIGNMENT_EXPR nodes whose LHS NAME_EXPR matches a val in scope.
 * Emits Error severity diagnostic: "Val cannot be reassigned".
 */
fn void add_val_reassignment_diagnostics(Object* diagnostics, String content, ParseResult* ast) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != ASSIGNMENT_EXPR) continue;

		// Find LHS: first child should be a NAME_EXPR
		String assigned_name = "";
		uint lhs_idx = 0;
		for (uint j = 0; j < ast.node_count; j++) {
			if (ast.nodes[j].parent == i) {
				if (ast.nodes[j].kind == NAME_EXPR && ast.nodes[j].name.len > 0) {
					assigned_name = ast.nodes[j].name;
					lhs_idx = j;
				}
				break; // first child only
			}
		}
		if (assigned_name.len == 0) continue;

		// Search upward from the assignment for a val PROPERTY_DECL with matching name
		if (find_val_in_scope(ast, i, assigned_name)) {
			AstNode* lhs = &ast.nodes[lhs_idx];
			Object* diag = object::new_obj(tmem);

			Object* range = object::new_obj(tmem);
			Object* start = object::new_obj(tmem);
			start.set("line", (int)lhs.start_line);
			start.set("character", (int)lhs.start_col);
			Object* end_pos = object::new_obj(tmem);
			end_pos.set("line", (int)lhs.end_line);
			end_pos.set("character", (int)lhs.end_col);
			range.set("start", start);
			range.set("end", end_pos);

			diag.set("range", range);
			diag.set("severity", 1); // DiagnosticSeverity.Error
			diag.set("source", "kls");
			diag.set("message", "Val cannot be reassigned");

			diagnostics.push(diag);
		}
	}
}

/**
 * Check if an assignment target name matches a val (non-var) PROPERTY_DECL
 * in the enclosing scope. Returns true if reassignment is illegal.
 */
fn bool find_val_in_scope(ParseResult* ast, uint assignment_idx, String name) {
	uint scope_idx = ast::NO_PARENT;
	uint current = assignment_idx;
	while (current != ast::NO_PARENT) {
		AstNode* p = &ast.nodes[current];
		if (p.kind == FUN_DECL || p.kind == LAMBDA_EXPR || p.kind == INIT_BLOCK ||
		    p.kind == FILE || p.kind == CLASS_DECL || p.kind == INTERFACE_DECL ||
		    p.kind == OBJECT_DECL) {
			scope_idx = current;
			break;
		}
		current = p.parent;
	}
	if (scope_idx == ast::NO_PARENT) return false;

	for (uint j = 0; j < ast.node_count; j++) {
		AstNode* candidate = &ast.nodes[j];
		if (candidate.kind != PROPERTY_DECL) continue;
		if (candidate.name != name) continue;
		if ((candidate.mod_flags & ast::MOD_VAR) != 0) continue;
		if (j >= assignment_idx) continue;

		uint cand_scope = candidate.parent;
		while (cand_scope != ast::NO_PARENT) {
			if (cand_scope == scope_idx) return true;
			AstNode* cs = &ast.nodes[cand_scope];
			if (cs.kind == FUN_DECL || cs.kind == LAMBDA_EXPR || cs.kind == FILE ||
			    cs.kind == CLASS_DECL || cs.kind == INTERFACE_DECL ||
			    cs.kind == OBJECT_DECL || cs.kind == INIT_BLOCK) {
				break;
			}
			cand_scope = cs.parent;
		}
	}

	return false;
}
