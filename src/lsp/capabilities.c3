module kls::lsp::capabilities;

import std::collections::object;
import kls::lsp::semantic_tokens;
import kls::lsp::execute_command;

/**
 * Build the server capabilities object for the initialize response.
 * Start minimal and add capabilities as features are implemented.
 */
fn Object* build_capabilities(bool client_supports_utf8) {
	Object* caps = object::new_obj(tmem);

	// Text document sync: full sync mode
	Object* text_doc_sync = object::new_obj(tmem);
	text_doc_sync.set("openClose", true);
	text_doc_sync.set("change", 2); // TextDocumentSyncKind.Incremental
	text_doc_sync.set("save", true);
	caps.set("textDocumentSync", text_doc_sync);

	// #6: Only claim UTF-8 position encoding if client supports it
	if (client_supports_utf8) {
		caps.set("positionEncoding", "utf-8");
	}

	// Hover support
	caps.set("hoverProvider", true);

	// Completion support
	Object* completion_opts = object::new_obj(tmem);
	Object* trigger_chars = object::new_obj(tmem);
	trigger_chars.push(object::new_string(".", tmem));
	trigger_chars.push(object::new_string("@", tmem));
	completion_opts.set("triggerCharacters", trigger_chars);
	completion_opts.set("resolveProvider", true);
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

	// Go to declaration support (interface/abstract method declarations)
	caps.set("declarationProvider", true);

	// Go to type definition support
	caps.set("typeDefinitionProvider", true);

	// Go to implementation support
	caps.set("implementationProvider", true);

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

	// Semantic tokens support (full with delta + range)
	caps.set("semanticTokensProvider", semantic_tokens::build_semantic_tokens_options());

	// Folding range support
	caps.set("foldingRangeProvider", true);

	// Selection range support (smart selection expand/shrink)
	caps.set("selectionRangeProvider", true);

	// Document formatting support (full + range + on-type)
	caps.set("documentFormattingProvider", true);
	caps.set("documentRangeFormattingProvider", true);

	Object* on_type_opts = object::new_obj(tmem);
	on_type_opts.set("firstTriggerCharacter", "\n");
	Object* more_triggers = object::new_obj(tmem);
	more_triggers.push(object::new_string("}", tmem));
	on_type_opts.set("moreTriggerCharacter", more_triggers);
	caps.set("documentOnTypeFormattingProvider", on_type_opts);

	// Code action support (quick fixes + organize imports)
	Object* code_action_opts = object::new_obj(tmem);
	Object* code_action_kinds = object::new_obj(tmem);
	code_action_kinds.push(object::new_string("quickfix", tmem));
	code_action_kinds.push(object::new_string("source.organizeImports", tmem));
	code_action_kinds.push(object::new_string("refactor.extract", tmem));
	code_action_kinds.push(object::new_string("refactor.rewrite", tmem));
	code_action_kinds.push(object::new_string("source.generate", tmem));
	code_action_opts.set("codeActionKinds", code_action_kinds);
	code_action_opts.set("resolveProvider", true);
	caps.set("codeActionProvider", code_action_opts);

	// CodeLens support (run/test lenses)
	Object* code_lens_opts = object::new_obj(tmem);
	code_lens_opts.set("resolveProvider", true);
	caps.set("codeLensProvider", code_lens_opts);

	// Inlay hint support (with resolve)
	Object* inlay_hint_opts = object::new_obj(tmem);
	inlay_hint_opts.set("resolveProvider", true);
	caps.set("inlayHintProvider", inlay_hint_opts);

	// Document link support (URLs + import paths)
	caps.set("documentLinkProvider", true);

	// Linked editing range support (rename-as-you-type for identifiers)
	caps.set("linkedEditingRangeProvider", true);

	// Call hierarchy support (prepare + incoming/outgoing)
	caps.set("callHierarchyProvider", true);

	// Type hierarchy support (prepare + supertypes/subtypes)
	caps.set("typeHierarchyProvider", true);

	// Execute command support (run main, run test)
	caps.set("executeCommandProvider", execute_command::build_execute_command_options());

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

	// Watch settings.gradle.kts (multi-module Gradle projects)
	Object* settings_kts_watcher = object::new_obj(tmem);
	settings_kts_watcher.set("globPattern", "**/settings.gradle.kts");
	settings_kts_watcher.set("kind", 7);
	watchers.push(settings_kts_watcher);

	// Watch settings.gradle
	Object* settings_watcher = object::new_obj(tmem);
	settings_watcher.set("globPattern", "**/settings.gradle");
	settings_watcher.set("kind", 7);
	watchers.push(settings_watcher);

	// Watch pom.xml
	Object* pom_watcher = object::new_obj(tmem);
	pom_watcher.set("globPattern", "**/pom.xml");
	pom_watcher.set("kind", 7);
	watchers.push(pom_watcher);

	// Watch gradle.properties
	Object* gradle_props_watcher = object::new_obj(tmem);
	gradle_props_watcher.set("globPattern", "**/gradle.properties");
	gradle_props_watcher.set("kind", 7);
	watchers.push(gradle_props_watcher);

	// Watch Gradle version catalog (libs.versions.toml)
	Object* version_catalog_watcher = object::new_obj(tmem);
	version_catalog_watcher.set("globPattern", "**/gradle/libs.versions.toml");
	version_catalog_watcher.set("kind", 7);
	watchers.push(version_catalog_watcher);

	// Watch gradle-wrapper.properties (Gradle version changes)
	Object* wrapper_watcher = object::new_obj(tmem);
	wrapper_watcher.set("globPattern", "**/gradle/wrapper/gradle-wrapper.properties");
	wrapper_watcher.set("kind", 7);
	watchers.push(wrapper_watcher);

	Object* change_reg = object::new_obj(tmem);
	change_reg.set("watchers", watchers);
	file_operations.set("didChangeWatchedFiles", change_reg);
	workspace_caps.set("fileOperations", file_operations);
	caps.set("workspace", workspace_caps);

	return caps;
}
