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

	return diagnostics;
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
