module kls::lsp::capabilities;

import std::collections::object;
import kls::lsp::semantic_tokens;

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

	// Hover support
	caps.set("hoverProvider", true);

	// Completion support
	Object* completion_opts = object::new_obj(tmem);
	Object* trigger_chars = object::new_obj(tmem);
	trigger_chars.push(object::new_string(".", tmem));
	completion_opts.set("triggerCharacters", trigger_chars);
	caps.set("completionProvider", completion_opts);

	// Go to definition support
	caps.set("definitionProvider", true);

	// Find references support
	caps.set("referencesProvider", true);

	// Document symbol support (outline view)
	caps.set("documentSymbolProvider", true);

	// Semantic tokens support (full document)
	caps.set("semanticTokensProvider", semantic_tokens::build_semantic_tokens_options());

	return caps;
}
