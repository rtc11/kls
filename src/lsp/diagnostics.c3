module kls::lsp::diagnostics;

import std::io;
import std::collections::object;
import kls::json_rpc;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

/**
 * Run the lexer on content and return a JSON array of LSP Diagnostic
 * objects for lexer errors.  Parser errors are added from the cached
 * AST when available and the source is lexically clean.
 * Unused imports are tagged with DiagnosticTag.Unnecessary (1).
 */
fn Object* build_diagnostics_array(String content, ParseResult* ast) {
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
	for (usz i = 0; i < ast.node_count; i++) {
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

/**
 * Publish diagnostics for a document to the client.
 * Uses the cached AST from the DocumentStore for parser errors.
 * Sends a textDocument/publishDiagnostics notification.
 */
fn void publish_diagnostics(DocumentStore* store, String uri) {
	Document* doc = store.get(uri) ?? null;
	String content;
	if (doc != null) {
		content = doc.content;
	} else {
		content = "";
	}

	// Get cached AST (parses lazily if needed); null if doc not found
	ParseResult* ast = store.get_ast(uri) ?? null;

	Object* diagnostics = build_diagnostics_array(content, ast);

	Object* params = object::new_obj(tmem);
	params.set("uri", uri);
	params.set("diagnostics", diagnostics);

	json_rpc::send_notification("textDocument/publishDiagnostics", params);
	io::eprintfn("[kls] Published diagnostics for %s", uri);
}
