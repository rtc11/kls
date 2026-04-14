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

	// Signature help support
	Object* sig_help_opts = object::new_obj(tmem);
	Object* sig_trigger_chars = object::new_obj(tmem);
	sig_trigger_chars.push(object::new_string("(", tmem));
	sig_trigger_chars.push(object::new_string(",", tmem));
	sig_help_opts.set("triggerCharacters", sig_trigger_chars);
	caps.set("signatureHelpProvider", sig_help_opts);

	// Go to definition support
	caps.set("definitionProvider", true);

	// Find references support
	caps.set("referencesProvider", true);

	// Document highlight support (same-symbol highlighting)
	caps.set("documentHighlightProvider", true);

	// Document symbol support (outline view)
	caps.set("documentSymbolProvider", true);

	// Workspace symbol support (Ctrl+T search)
	caps.set("workspaceSymbolProvider", true);

	// Rename support (with prepare)
	Object* rename_opts = object::new_obj(tmem);
	rename_opts.set("prepareProvider", true);
	caps.set("renameProvider", rename_opts);

	// Semantic tokens support (full document)
	caps.set("semanticTokensProvider", semantic_tokens::build_semantic_tokens_options());

	// Workspace capabilities
	Object* workspace_caps = object::new_obj(tmem);
	Object* file_operations = object::new_obj(tmem);

	// Register interest in .kt file changes and build files
	Object* watchers = object::new_obj(tmem);
	Object* watcher = object::new_obj(tmem);
	watcher.set("globPattern", "**/*.kt");
	watcher.set("kind", 7); // Create=1 | Change=2 | Delete=4 = 7 (all)
	watchers.push(watcher);

	// Watch build.gradle.kts
	Object* gradle_kts_watcher = object::new_obj(tmem);
	gradle_kts_watcher.set("globPattern", "**/build.gradle.kts");
	gradle_kts_watcher.set("kind", 7);
	watchers.push(gradle_kts_watcher);

	// Watch build.gradle
	Object* gradle_watcher = object::new_obj(tmem);
	gradle_watcher.set("globPattern", "**/build.gradle");
	gradle_watcher.set("kind", 7);
	watchers.push(gradle_watcher);

	// Watch pom.xml
	Object* pom_watcher = object::new_obj(tmem);
	pom_watcher.set("globPattern", "**/pom.xml");
	pom_watcher.set("kind", 7);
	watchers.push(pom_watcher);

	Object* change_reg = object::new_obj(tmem);
	change_reg.set("watchers", watchers);
	file_operations.set("didChangeWatchedFiles", change_reg);
	workspace_caps.set("fileOperations", file_operations);
	caps.set("workspace", workspace_caps);

	return caps;
}
