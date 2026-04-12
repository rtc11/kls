module kls::lsp::diagnostics;

import std::io;
import std::collections::object;
import kls::json_rpc;
import kls::kotlin::lexer;
import kls::kotlin::token;

/**
 * Run the lexer on content and return a JSON array of LSP Diagnostic objects
 * for any ERROR tokens found. Uses temp allocation.
 */
fn Object* build_diagnostics_array(String content) {
	Object* diagnostics = object::new_obj(tmem);

	if (content.len == 0) {
		return diagnostics;
	}

	Lexer lex = lexer::init(content);
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		if (tok.kind == ERROR) {
			Object* diag = object::new_obj(tmem);

			// Build range
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

			// Build message with offending character(s)
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

	return diagnostics;
}

/**
 * Publish diagnostics for a document to the client.
 * Runs the lexer on content, collects ERROR tokens as diagnostics,
 * and sends a textDocument/publishDiagnostics notification.
 */
fn void publish_diagnostics(String uri, String content) {
	Object* diagnostics = build_diagnostics_array(content);

	Object* params = object::new_obj(tmem);
	params.set("uri", uri);
	params.set("diagnostics", diagnostics);

	json_rpc::send_notification("textDocument/publishDiagnostics", params);
	io::eprintfn("[kls] Published diagnostics for %s", uri);
}
