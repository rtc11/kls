module kls::lsp::capabilities;

import std::collections::object;

/**
 * Build the server capabilities object for the initialize response.
 * Start minimal and add capabilities as features are implemented.
 */
fn Object* build_capabilities() {
	Object* caps = object::new_obj(tmem);

	// Text document sync: full sync mode
	Object* text_doc_sync = object::new_obj(tmem);
	text_doc_sync.set("openClose", true);
	text_doc_sync.set("change", 1); // TextDocumentSyncKind.Full
	caps.set("textDocumentSync", text_doc_sync);

	// Position encoding
	caps.set("positionEncoding", "utf-8");

	// TODO: Add more capabilities as features are implemented:
	// caps.set("hoverProvider", true);
	// caps.set("completionProvider", build_completion_options());
	// caps.set("definitionProvider", true);
	// caps.set("documentSymbolProvider", true);
	// caps.set("semanticTokensProvider", build_semantic_tokens_options());

	return caps;
}
