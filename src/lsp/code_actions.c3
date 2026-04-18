module kls::lsp::code_actions;

import std::collections::object;
import kls::document;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::lsp::hover;
import kls::workspace;

faultdef NO_RECEIVER;

/**
 * Handle textDocument/codeAction request.
 *
 * Examines the diagnostics provided in the request context and returns
 * applicable code actions (quick fixes and source actions).
 *
 * Supported actions:
 *   - "Remove unused import" (quickfix) for each unused import diagnostic
 *   - "Remove all unused imports" (source.organizeImports) computed from full document
 *   - "Replace '&' with '&&'" / "'|' with '||'" (quickfix) for operator errors
 *   - "Insert missing '<delim>'" (quickfix) for Expected ')', '}', '>' errors
 *   - "Import <pkg>.<name>" (quickfix) for unresolved references
 */
fn Object* handle_code_action(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* context = params.get("context")!!;
	Object* client_diagnostics = context.get("diagnostics")!!;

	// Check if the client is filtering by kind
	String[8] only_kinds;
	usz only_count = 0;
	if (try only = context.get("only")) {
		if (only.is_array()) {
			for (sz i = 0; i < only.get_len() && only_count < 8; i++) {
				if (try kind_str = only.get_string_at(i)) {
					only_kinds[only_count] = kind_str;
					only_count++;
				}
			}
		}
	}

	Document* doc = store.get(uri) ?? null;

	Object* actions = object::new_obj(tmem); // JSON array

	ParseResult* ast = store.get_ast(uri) ?? null;

	// ── Process each diagnostic from the client context ──────────
	for (sz i = 0; i < client_diagnostics.get_len(); i++) {
		Object* diag = client_diagnostics.get_at(i);
		String message = diag.get_string("message") ?? "";

		// Quick fix: remove this one unused import
		if (message.starts_with("Unused import:") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_unused_import(uri, doc, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: replace & with && or | with ||
		if (message.starts_with("Unexpected character:") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_fix_operator(uri, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: insert missing delimiter
		if (message.starts_with("Expected '") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_insert_delimiter(uri, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: add missing import for unresolved reference
		if (message.starts_with("Unresolved reference: '") && is_kind_wanted("quickfix", only_kinds[:only_count])) {
			add_import_actions_for_diagnostic(actions, uri, doc, ast, workspace, diag, message);
		}
	}

	// ── Quick fix: import all unresolved references at once ─────
	if (doc != null && workspace != null && ast != null
		&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
		Object* import_all = try_import_all_unresolved(uri, doc, ast, workspace, client_diagnostics);
		if (import_all != null) {
			actions.push(import_all);
		}
	}

	// ── Source action: convert to star import ───────────────────
	if (doc != null && ast != null && is_kind_wanted("source.organizeImports", only_kinds[:only_count])) {
		add_star_import_actions(actions, uri, ast);
	}

	// ── Source action: remove ALL unused imports (computed server-side) ──
	// Don't rely on client-provided diagnostics for this — compute from
	// the full document so it works regardless of cursor position.
	if (doc != null && is_kind_wanted("source.organizeImports", only_kinds[:only_count])) {
		Object* all_diags = diagnostics::build_diagnostics_array(doc.content, ast);

		Object*[128] all_unused;
		usz all_unused_count = 0;
		if (all_diags.is_array()) {
			for (sz j = 0; j < all_diags.get_len() && all_unused_count < 128; j++) {
				Object* d = all_diags.get_at(j);
				String msg = d.get_string("message") ?? "";
				if (msg.starts_with("Unused import:")) {
					all_unused[all_unused_count] = d;
					all_unused_count++;
				}
			}
		}

		if (all_unused_count >= 1) {
			Object* action = build_organize_imports_action(uri, all_unused[:all_unused_count]);
			if (action != null) {
				actions.push(action);
			}
		}
	}

	// ── Refactor: extract variable ──────────────────────────────
	if (doc != null && ast != null && is_kind_wanted("refactor.extract", only_kinds[:only_count])) {
		Object* extract = try_extract_variable(uri, doc, ast, params);
		if (extract != null) {
			actions.push(extract);
		}
		Object* extract_fn = try_extract_function(uri, doc, ast, params);
		if (extract_fn != null) {
			actions.push(extract_fn);
		}
	}

	// ── Source: generate data class methods ──────────────────────
	if (doc != null && ast != null && is_kind_wanted("source.generate", only_kinds[:only_count])) {
		add_data_class_actions(actions, uri, doc, ast, params);
	}

	// ── Refactor: convert to expression form ────────────────────
	if (doc != null && ast != null && is_kind_wanted("refactor.rewrite", only_kinds[:only_count])) {
		Object* expr_body = try_convert_fun_to_expression_body(uri, doc, ast, params);
		if (expr_body != null) {
			actions.push(expr_body);
		}
	}

	// ── Cursor-context: add import for identifier under cursor ───
	// Independent of diagnostics — works even if the client didn't
	// send an "Unresolved reference" diagnostic for this position.
	if (doc != null && workspace != null && ast != null
		&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
		add_import_actions_at_cursor(actions, uri, doc, ast, workspace, params);
	}

	return actions;
}

// ── Quick fix: remove a single unused import ──────────────────────

/**
 * Build a "Remove unused import" code action for a single unused-import
 * diagnostic. Deletes the entire import line (from line start through
 * the next line start, consuming the trailing newline).
 */
fn Object* try_remove_unused_import(String uri, Document* doc, Object* diag) {
	if (doc == null) return null;

	Object* range = diag.get("range")!!;
	int start_line = range.get("start")!!.get_int("line")!!;
	int end_line = range.get("end")!!.get_int("line")!!;

	// Build a range that covers the full line(s) of the import, including newline
	Object* delete_range = build_line_delete_range(start_line, end_line);

	Object* edit = object::new_obj(tmem);
	edit.set("range", delete_range);
	edit.set("newText", "");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	// Build the code action
	Object* action = object::new_obj(tmem);
	action.set("title", "Remove unused import");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	// Link to the diagnostic
	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Source action: remove all unused imports ──────────────────────

/**
 * Build an "Organize imports: remove all unused" action that deletes
 * all unused import lines in one edit operation.
 */
fn Object* build_organize_imports_action(String uri, Object*[] diags) {
	if (diags.len == 0) return null;

	Object* edits = object::new_obj(tmem);

	for (usz i = 0; i < diags.len; i++) {
		Object* range = diags[i].get("range")!!;
		int start_line = range.get("start")!!.get_int("line")!!;
		int end_line = range.get("end")!!.get_int("line")!!;

		Object* delete_range = build_line_delete_range(start_line, end_line);

		Object* edit = object::new_obj(tmem);
		edit.set("range", delete_range);
		edit.set("newText", "");
		edits.push(edit);
	}

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove all unused imports");
	action.set("kind", "source.organizeImports");
	action.set("edit", workspace_edit);

	// Link all diagnostics
	Object* action_diags = object::new_obj(tmem);
	for (usz i = 0; i < diags.len; i++) {
		action_diags.push(diags[i]);
	}
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quick fix: replace & with && or | with || ────────────────────

/**
 * If the diagnostic message indicates a lone '&' or '|', offer to
 * replace it with '&&' or '||' respectively.
 */
fn Object* try_fix_operator(String uri, Object* diag, String message) {
	// Messages look like: "Unexpected character: '&'" or "Unexpected character: '|'"
	String replacement;
	String title;

	if (message.contains("'&'")) {
		replacement = "&&";
		title = "Replace '&' with '&&'";
	} else if (message.contains("'|'")) {
		replacement = "||";
		title = "Replace '|' with '||'";
	} else {
		return null;
	}

	Object* range = diag.get("range")!!;

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", replacement);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", title);
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quick fix: insert missing delimiter ──────────────────────────

/**
 * If the diagnostic message matches "Expected ')', got ..." (or '}', '>'),
 * offer to insert the missing delimiter at the diagnostic position.
 */
fn Object* try_insert_delimiter(String uri, Object* diag, String message) {
	// Parse the expected token from "Expected '<tok>', got '<actual>'"
	String delimiter = extract_expected_token(message);
	if (delimiter.len == 0) return null;

	// Only offer insertion for closing delimiters
	if (delimiter != ")" && delimiter != "}" && delimiter != ">") return null;

	Object* range = diag.get("range")!!;
	Object* start = range.get("start")!!;

	// Build an insert range (zero-width at the start of the diagnostic)
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", start.get_int("line")!!);
	insert_start.set("character", start.get_int("character")!!);

	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", start.get_int("line")!!);
	insert_end.set("character", start.get_int("character")!!);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", delimiter);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	DString title;
	title.tinit();
	title.appendf("Insert missing '%s'", delimiter);

	Object* action = object::new_obj(tmem);
	action.set("title", title.str_view());
	action.set("kind", "quickfix");
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Refactor: extract variable ───────────────────────────────────

/**
 * Build an "Extract variable" code action when the selection exactly
 * matches an expression AST node. Produces two edits:
 *   1. Insert `val extractedVar = <expr>\n<indent>` before the containing statement
 *   2. Replace the expression with `extractedVar`
 *
 * Returns null if the selection doesn't match an extractable expression.
 */
fn Object* try_extract_variable(String uri, Document* doc, ParseResult* ast, Object* params) {
	Object* range = params.get("range") ?? null;
	if (range == null) return null;

	Object* start = range.get("start") ?? null;
	Object* end_pos = range.get("end") ?? null;
	if (start == null || end_pos == null) return null;

	uint start_line = (uint)(start.get_int("line") ?? 0);
	uint start_col = (uint)(start.get_int("character") ?? 0);
	uint end_line = (uint)(end_pos.get_int("line") ?? 0);
	uint end_col = (uint)(end_pos.get_int("character") ?? 0);

	// Empty selection → nothing to extract
	if (start_line == end_line && start_col == end_col) return null;

	long sel_start = document::position_to_byte_offset(doc.content, start_line, start_col);
	long sel_end = document::position_to_byte_offset(doc.content, end_line, end_col);
	if (sel_start < 0 || sel_end < 0 || sel_end <= sel_start) return null;

	// Find innermost expression node with exact match on selection
	uint best_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (!ast::is_expression(n.kind)) continue;
		if (n.start_offset == (uint)sel_start && n.end_offset == (uint)sel_end) {
			best_idx = i; // later = deeper = innermost
		}
	}
	if (best_idx == uint.max) return null;

	AstNode* expr = &ast.nodes[best_idx];

	// Skip NAME_EXPR — already a variable reference, no point extracting
	if (expr.kind == NAME_EXPR) return null;

	// Get expression source text
	String expr_text = doc.content[(usz)expr.start_offset..(usz)expr.end_offset - 1];

	// Find containing statement: walk parent chain until we find a node
	// whose parent is a BLOCK or FILE (that node is the statement level)
	uint stmt_idx = best_idx;
	while (stmt_idx != 0 && ast.nodes[stmt_idx].parent != ast::NO_PARENT) {
		uint parent_idx = ast.nodes[stmt_idx].parent;
		AstNode* parent = &ast.nodes[parent_idx];
		if (parent.kind == BLOCK || parent.kind == FILE) {
			break;
		}
		stmt_idx = parent_idx;
	}

	AstNode* stmt = &ast.nodes[stmt_idx];

	// Get indentation: scan content from line start to stmt start_col
	String indent = "";
	if (stmt.start_col > 0) {
		// Find line start by scanning backward from stmt.start_offset
		usz line_start = (usz)stmt.start_offset;
		while (line_start > 0 && doc.content[line_start - 1] != '\n') {
			line_start--;
		}
		// Extract leading whitespace
		usz ws_end = line_start;
		while (ws_end < doc.content.len && (doc.content[ws_end] == ' ' || doc.content[ws_end] == '\t')) {
			ws_end++;
		}
		if (ws_end > line_start) {
			indent = doc.content[line_start..ws_end - 1];
		}
	}

	// Build insert text: "val extractedVar = <expr>\n<indent>"
	DString insert_text;
	insert_text.tinit();
	insert_text.appendf("val extractedVar = %s\n%s", expr_text, indent);

	// Edit 1: insert before the statement (at statement's start position)
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", (int)stmt.start_line);
	insert_start.set("character", (int)stmt.start_col);

	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", (int)stmt.start_line);
	insert_end.set("character", (int)stmt.start_col);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit1 = object::new_obj(tmem);
	edit1.set("range", insert_range);
	edit1.set("newText", insert_text.str_view());

	// Edit 2: replace expression with "extractedVar"
	Object* replace_start = object::new_obj(tmem);
	replace_start.set("line", (int)expr.start_line);
	replace_start.set("character", (int)expr.start_col);

	Object* replace_end = object::new_obj(tmem);
	replace_end.set("line", (int)expr.end_line);
	replace_end.set("character", (int)expr.end_col);

	Object* replace_range = object::new_obj(tmem);
	replace_range.set("start", replace_start);
	replace_range.set("end", replace_end);

	Object* edit2 = object::new_obj(tmem);
	edit2.set("range", replace_range);
	edit2.set("newText", "extractedVar");

	// Build workspace edit with both edits
	Object* edits = object::new_obj(tmem);
	edits.push(edit1);
	edits.push(edit2);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Extract variable");
	action.set("kind", "refactor.extract.variable");
	action.set("edit", workspace_edit);

	return action;
}

// ── Refactor: extract function ──────────────────────────────────

/**
 * Build an "Extract function" code action when the selection matches
 * an expression node or covers complete statement lines.
 *
 * Mode A (expression): selection exactly matches an expression AST node.
 *   Creates `private fun extracted() = <expr>` after the enclosing function.
 *   Replaces expression with `extracted()`.
 *
 * Mode B (statements): selection covers one or more complete lines inside
 *   a function body. Creates `private fun extracted(<params>) { <lines> }`
 *   after the enclosing function. Replaces selected lines with `extracted(<args>)`.
 *   Parameters are detected by finding identifiers in the selected code that
 *   reference declarations from the enclosing scope (before the selection).
 *
 * Returns null if the selection doesn't match either mode.
 */
fn Object* try_extract_function(String uri, Document* doc, ParseResult* ast, Object* params) {
	Object* range = params.get("range") ?? null;
	if (range == null) return null;

	Object* start = range.get("start") ?? null;
	Object* end_pos = range.get("end") ?? null;
	if (start == null || end_pos == null) return null;

	uint start_line = (uint)(start.get_int("line") ?? 0);
	uint start_col = (uint)(start.get_int("character") ?? 0);
	uint end_line = (uint)(end_pos.get_int("line") ?? 0);
	uint end_col = (uint)(end_pos.get_int("character") ?? 0);

	// Empty selection → nothing to extract
	if (start_line == end_line && start_col == end_col) return null;

	long sel_start = document::position_to_byte_offset(doc.content, start_line, start_col);
	long sel_end = document::position_to_byte_offset(doc.content, end_line, end_col);
	if (sel_start < 0 || sel_end < 0 || sel_end <= sel_start) return null;

	// Try Mode A: exact expression match
	uint expr_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (!ast::is_expression(n.kind)) continue;
		if (n.start_offset == (uint)sel_start && n.end_offset == (uint)sel_end) {
			expr_idx = i;
		}
	}

	// Find enclosing function for placement
	uint enc_fun_idx = find_enclosing_fun(ast, expr_idx != uint.max ? expr_idx : 0, (uint)sel_start);
	if (enc_fun_idx == ast::NO_PARENT) return null;

	AstNode* enc_fun = &ast.nodes[enc_fun_idx];

	// Get enclosing function indentation
	String fun_indent = get_line_indent(doc.content, enc_fun.start_offset);

	if (expr_idx != uint.max) {
		// ── Mode A: expression extraction ──
		AstNode* expr = &ast.nodes[expr_idx];

		// Skip NAME_EXPR — just a variable reference
		if (expr.kind == NAME_EXPR) return null;

		String expr_text = doc.content[(usz)expr.start_offset..(usz)expr.end_offset - 1];

		// Build function: "private fun extracted() = <expr>"
		DString fun_text;
		fun_text.tinit();
		fun_text.appendf("\n\n%sprivate fun extracted() = %s", fun_indent, expr_text);

		// Insert after enclosing function
		Object* insert_start_pos = object::new_obj(tmem);
		insert_start_pos.set("line", (int)enc_fun.end_line);
		insert_start_pos.set("character", (int)enc_fun.end_col);
		Object* insert_end_pos = object::new_obj(tmem);
		insert_end_pos.set("line", (int)enc_fun.end_line);
		insert_end_pos.set("character", (int)enc_fun.end_col);
		Object* insert_range = object::new_obj(tmem);
		insert_range.set("start", insert_start_pos);
		insert_range.set("end", insert_end_pos);

		Object* edit1 = object::new_obj(tmem);
		edit1.set("range", insert_range);
		edit1.set("newText", fun_text.str_view());

		// Replace expression with "extracted()"
		Object* replace_start_pos = object::new_obj(tmem);
		replace_start_pos.set("line", (int)expr.start_line);
		replace_start_pos.set("character", (int)expr.start_col);
		Object* replace_end_pos = object::new_obj(tmem);
		replace_end_pos.set("line", (int)expr.end_line);
		replace_end_pos.set("character", (int)expr.end_col);
		Object* replace_range = object::new_obj(tmem);
		replace_range.set("start", replace_start_pos);
		replace_range.set("end", replace_end_pos);

		Object* edit2 = object::new_obj(tmem);
		edit2.set("range", replace_range);
		edit2.set("newText", "extracted()");

		Object* edits = object::new_obj(tmem);
		edits.push(edit2);  // replace first (earlier in doc)
		edits.push(edit1);  // insert after function (later in doc)

		Object* changes = object::new_obj(tmem);
		changes.set(uri, edits);
		Object* workspace_edit = object::new_obj(tmem);
		workspace_edit.set("changes", changes);

		Object* action = object::new_obj(tmem);
		action.set("title", "Extract function");
		action.set("kind", "refactor.extract.function");
		action.set("edit", workspace_edit);
		return action;
	}

	// ── Mode B: statement block extraction ──
	// Selection must cover complete lines inside a function body
	// Find statement-level nodes that fall within the selection
	uint enc_block_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != BLOCK) continue;
		if (n.parent == enc_fun_idx) {
			enc_block_idx = i;
			break;
		}
	}
	if (enc_block_idx == ast::NO_PARENT || enc_block_idx == uint.max) return null;

	// Collect statement nodes in the block that overlap with selection
	uint[64] sel_stmts;
	usz sel_stmt_count = 0;
	for (uint i = 1; i < ast.node_count && sel_stmt_count < 64; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.parent != enc_block_idx) continue;
		// Statement overlaps selection if it starts before sel_end and ends after sel_start
		if (n.start_offset < (uint)sel_end && n.end_offset > (uint)sel_start) {
			sel_stmts[sel_stmt_count] = i;
			sel_stmt_count++;
		}
	}
	if (sel_stmt_count == 0) return null;

	// Get the range covering all selected statements
	AstNode* first_stmt = &ast.nodes[sel_stmts[0]];
	AstNode* last_stmt = &ast.nodes[sel_stmts[sel_stmt_count - 1]];

	// Get selected code text
	String selected_text = doc.content[(usz)first_stmt.start_offset..(usz)last_stmt.end_offset - 1];

	// Get statement indentation (for the body of the new function)
	String stmt_indent = get_line_indent(doc.content, first_stmt.start_offset);

	// Detect free variables: identifiers in selected code that are declared
	// in the enclosing function before the selection
	String[32] param_names;
	String[32] param_types;
	usz param_count = 0;

	// Collect declarations in enclosing block before selection
	String[64] enclosing_decl_names;
	String[64] enclosing_decl_types;
	usz enclosing_decl_count = 0;

	for (uint i = 1; i < ast.node_count && enclosing_decl_count < 64; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.parent != enc_block_idx && n.parent != enc_fun_idx) continue;
		if (n.kind != PROPERTY_DECL && n.kind != PARAM) continue;
		if (n.name.len == 0) continue;
		// Only declarations before the selection
		if (n.end_offset > (uint)sel_start) {
			// PARAM nodes are always "before" (they're function params)
			if (n.kind != PARAM) continue;
		}
		enclosing_decl_names[enclosing_decl_count] = n.name;
		enclosing_decl_types[enclosing_decl_count] = n.type_text.len > 0 ? n.type_text : "Any";
		enclosing_decl_count++;
	}

	// Scan selected text for identifier tokens that match enclosing decls
	lexer::Lexer lex = lexer::init(selected_text);
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		if (tok.kind != IDENTIFIER) continue;

		// Check if this identifier matches an enclosing declaration
		for (usz d = 0; d < enclosing_decl_count; d++) {
			if (tok.text != enclosing_decl_names[d]) continue;

			// Check if already added
			bool already = false;
			for (usz p = 0; p < param_count; p++) {
				if (param_names[p] == tok.text) {
					already = true;
					break;
				}
			}
			if (!already && param_count < 32) {
				param_names[param_count] = enclosing_decl_names[d];
				param_types[param_count] = enclosing_decl_types[d];
				param_count++;
			}
			break;
		}
	}

	// Build the new function
	DString fun_text;
	fun_text.tinit();
	fun_text.appendf("\n\n%sprivate fun extracted(", fun_indent);
	for (usz p = 0; p < param_count; p++) {
		if (p > 0) fun_text.append(", ");
		fun_text.appendf("%s: %s", param_names[p], param_types[p]);
	}
	fun_text.append(") {\n");
	// Add the selected code, re-indented to function body level
	fun_text.appendf("%s", selected_text);
	if (selected_text.len > 0 && selected_text[selected_text.len - 1] != '\n') {
		fun_text.append("\n");
	}
	fun_text.appendf("%s}", fun_indent);

	// Build the call
	DString call_text;
	call_text.tinit();
	call_text.appendf("%sextracted(", stmt_indent);
	for (usz p = 0; p < param_count; p++) {
		if (p > 0) call_text.append(", ");
		call_text.appendf("%s", param_names[p]);
	}
	call_text.append(")");

	// Edit 1: replace selected statements with call
	Object* replace_start_pos = object::new_obj(tmem);
	replace_start_pos.set("line", (int)first_stmt.start_line);
	replace_start_pos.set("character", 0);
	Object* replace_end_pos = object::new_obj(tmem);
	replace_end_pos.set("line", (int)last_stmt.end_line);
	replace_end_pos.set("character", (int)last_stmt.end_col);
	Object* replace_range = object::new_obj(tmem);
	replace_range.set("start", replace_start_pos);
	replace_range.set("end", replace_end_pos);

	Object* edit1 = object::new_obj(tmem);
	edit1.set("range", replace_range);
	edit1.set("newText", call_text.str_view());

	// Edit 2: insert new function after enclosing function
	Object* insert_start_pos = object::new_obj(tmem);
	insert_start_pos.set("line", (int)enc_fun.end_line);
	insert_start_pos.set("character", (int)enc_fun.end_col);
	Object* insert_end_pos2 = object::new_obj(tmem);
	insert_end_pos2.set("line", (int)enc_fun.end_line);
	insert_end_pos2.set("character", (int)enc_fun.end_col);
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start_pos);
	insert_range.set("end", insert_end_pos2);

	Object* edit2 = object::new_obj(tmem);
	edit2.set("range", insert_range);
	edit2.set("newText", fun_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit1);
	edits.push(edit2);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Extract function");
	action.set("kind", "refactor.extract.function");
	action.set("edit", workspace_edit);
	return action;
}

/**
 * Find the enclosing FUN_DECL for a given node index or byte offset.
 * Returns the node index of the FUN_DECL, or NO_PARENT if not inside one.
 */
fn uint find_enclosing_fun(ParseResult* ast, uint node_idx, uint byte_offset) {
	// If we have a specific node, walk its parent chain
	if (node_idx > 0 && node_idx != uint.max) {
		uint current = node_idx;
		while (current != 0 && ast.nodes[current].parent != ast::NO_PARENT) {
			uint parent_idx = ast.nodes[current].parent;
			if (ast.nodes[parent_idx].kind == FUN_DECL) return parent_idx;
			current = parent_idx;
		}
	}

	// Fallback: find innermost FUN_DECL containing byte_offset
	uint best = ast::NO_PARENT;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if (byte_offset >= n.start_offset && byte_offset < n.end_offset) {
			best = i; // later = deeper = innermost
		}
	}
	return best;
}

/**
 * Get the leading whitespace indentation for the line containing the given byte offset.
 */
fn String get_line_indent(String content, uint offset) {
	// Find line start
	usz line_start = (usz)offset;
	while (line_start > 0 && content[line_start - 1] != '\n') {
		line_start--;
	}
	// Extract leading whitespace
	usz ws_end = line_start;
	while (ws_end < content.len && (content[ws_end] == ' ' || content[ws_end] == '\t')) {
		ws_end++;
	}
	if (ws_end > line_start) {
		return content[line_start..ws_end - 1];
	}
	return "";
}

// ── Source: generate data class methods ──────────────────────────

/**
 * Add "Generate toString()", "Generate equals()", "Generate hashCode()"
 * code actions for data classes at the cursor position that are missing
 * these methods.
 */
fn void add_data_class_actions(Object* actions, String uri, Document* doc, ParseResult* ast, Object* params) {
	Object* range = params.get("range") ?? null;
	if (range == null) return;
	Object* start = range.get("start") ?? null;
	if (start == null) return;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return;

	// Find data class containing cursor
	uint class_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != CLASS_DECL) continue;
		if (n.mod_flags & ast::MOD_DATA == 0) continue;
		if ((uint)cursor_offset >= n.start_offset && (uint)cursor_offset < n.end_offset) {
			class_idx = i;
		}
	}
	if (class_idx == uint.max) return;

	AstNode* cls = &ast.nodes[class_idx];
	String class_name = cls.name;
	if (class_name.len == 0) return;

	// Collect primary constructor properties (PARAM children of class)
	String[32] prop_names;
	String[32] prop_types;
	usz prop_count = 0;

	for (uint i = 1; i < ast.node_count && prop_count < 32; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.parent != class_idx) continue;
		if (n.kind != PARAM) continue;
		if (n.name.len == 0) continue;
		prop_names[prop_count] = n.name;
		prop_types[prop_count] = n.type_text.len > 0 ? n.type_text : "Any";
		prop_count++;
	}
	if (prop_count == 0) return;

	// Check which methods already exist
	bool has_to_string = false;
	bool has_equals = false;
	bool has_hash_code = false;

	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if (n.parent != class_idx) continue;
		// Also check if parent is a BLOCK child of the class
		if (n.parent != class_idx) {
			// Check for FUN_DECL inside BLOCK that is child of class
			AstNode* p = &ast.nodes[n.parent];
			if (p.kind != BLOCK || p.parent != class_idx) continue;
		}
		if (n.name == "toString") has_to_string = true;
		if (n.name == "equals") has_equals = true;
		if (n.name == "hashCode") has_hash_code = true;
	}

	// Find insertion point: before closing '}' of class body
	// The class end_offset points past the '}', so end_line/end_col is after '}'
	// Insert at end_line, col 0 — before the closing brace line
	uint insert_line = cls.end_line;
	uint insert_col = 0;

	// Member indentation: class indent + one level
	String class_indent = get_line_indent(doc.content, cls.start_offset);
	DString member_indent;
	member_indent.tinit();
	member_indent.appendf("%s    ", class_indent);
	String mind = member_indent.str_view();

	if (!has_to_string) {
		DString body;
		body.tinit();
		body.appendf("\n%soverride fun toString(): String = \"%s(", mind, class_name);
		for (usz p = 0; p < prop_count; p++) {
			if (p > 0) body.append(", ");
			body.appendf("%s=$%s", prop_names[p], prop_names[p]);
		}
		body.append(")\"\n");

		Object* action = build_insert_action(uri, "Generate toString()",
			"source.generate.toString", (int)insert_line, (int)insert_col, body.str_view());
		actions.push(action);
	}

	if (!has_equals) {
		DString body;
		body.tinit();
		body.appendf("\n%soverride fun equals(other: Any?): Boolean {\n", mind);
		body.appendf("%s    if (this === other) return true\n", mind);
		body.appendf("%s    if (other !is %s) return false\n", mind, class_name);
		if (prop_count == 1) {
			body.appendf("%s    return %s == other.%s\n", mind, prop_names[0], prop_names[0]);
		} else {
			body.appendf("%s    return ", mind);
			for (usz p = 0; p < prop_count; p++) {
				if (p > 0) body.append(" && ");
				body.appendf("%s == other.%s", prop_names[p], prop_names[p]);
			}
			body.append("\n");
		}
		body.appendf("%s}\n", mind);

		Object* action = build_insert_action(uri, "Generate equals()",
			"source.generate.equals", (int)insert_line, (int)insert_col, body.str_view());
		actions.push(action);
	}

	if (!has_hash_code) {
		DString body;
		body.tinit();
		body.appendf("\n%soverride fun hashCode(): Int {\n", mind);
		body.appendf("%s    var result = %s.hashCode()\n", mind, prop_names[0]);
		for (usz p = 1; p < prop_count; p++) {
			body.appendf("%s    result = 31 * result + %s.hashCode()\n", mind, prop_names[p]);
		}
		body.appendf("%s    return result\n", mind);
		body.appendf("%s}\n", mind);

		Object* action = build_insert_action(uri, "Generate hashCode()",
			"source.generate.hashCode", (int)insert_line, (int)insert_col, body.str_view());
		actions.push(action);
	}
}

/**
 * Build a code action that inserts text at a given position.
 */
fn Object* build_insert_action(String uri, String title, String kind, int line, int col, String text) {
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", line);
	insert_start.set("character", col);
	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", line);
	insert_end.set("character", col);
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", text);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", title);
	action.set("kind", kind);
	action.set("edit", workspace_edit);
	return action;
}

// ── Refactor: convert function to expression body ───────────────

/**
 * Offer "Convert to expression body" when cursor is on a FUN_DECL whose body
 * is a BLOCK containing exactly one RETURN_EXPR (or one expression statement).
 *
 * Transforms: `fun foo(): Type { return expr }` → `fun foo(): Type = expr`
 *
 * The replacement covers from the block start `{` to the function end `}`,
 * replacing with `= <expr>`.
 */
fn Object* try_convert_fun_to_expression_body(String uri, Document* doc, ParseResult* ast, Object* params) {
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find FUN_DECL containing cursor
	uint fun_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if ((uint)cursor_offset >= n.start_offset && (uint)cursor_offset < n.end_offset) {
			fun_idx = i;
		}
	}
	if (fun_idx == uint.max) return null;

	AstNode* fun_node = &ast.nodes[fun_idx];

	// Find BLOCK child
	uint block_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		if (ast.nodes[i].parent != fun_idx) continue;
		if (ast.nodes[i].kind == BLOCK) {
			block_idx = i;
			break;
		}
	}
	if (block_idx == uint.max) return null;

	AstNode* block = &ast.nodes[block_idx];

	// Count children of block — need exactly one statement
	uint stmt_count = 0;
	uint single_stmt_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		if (ast.nodes[i].parent != block_idx) continue;
		stmt_count++;
		single_stmt_idx = i;
	}
	if (stmt_count != 1 || single_stmt_idx == uint.max) return null;

	AstNode* stmt = &ast.nodes[single_stmt_idx];

	// Must be a RETURN_EXPR or a simple expression
	String expr_text;
	if (stmt.kind == RETURN_EXPR) {
		// Get the expression after 'return' — it's the source text from
		// after "return " to the end of the RETURN_EXPR node
		// The return keyword is 6 chars, plus space(s)
		usz return_start = (usz)stmt.start_offset;
		usz return_end = (usz)stmt.end_offset;
		// Skip "return" keyword and whitespace
		usz expr_start = return_start + 6; // "return"
		while (expr_start < return_end && (doc.content[expr_start] == ' ' || doc.content[expr_start] == '\t')) {
			expr_start++;
		}
		if (expr_start >= return_end) return null; // empty return
		expr_text = doc.content[expr_start..return_end - 1];
	} else if (ast::is_expression(stmt.kind)) {
		expr_text = doc.content[(usz)stmt.start_offset..(usz)stmt.end_offset - 1];
	} else {
		return null;
	}

	if (expr_text.len == 0) return null;

	// Build replacement: replace from block start to function end with "= expr"
	DString new_text;
	new_text.tinit();
	new_text.appendf("= %s", expr_text);

	// Replace range: from block start to function end
	Object* replace_start_pos = object::new_obj(tmem);
	replace_start_pos.set("line", (int)block.start_line);
	replace_start_pos.set("character", (int)block.start_col);
	Object* replace_end_pos = object::new_obj(tmem);
	replace_end_pos.set("line", (int)fun_node.end_line);
	replace_end_pos.set("character", (int)fun_node.end_col);
	Object* replace_range = object::new_obj(tmem);
	replace_range.set("start", replace_start_pos);
	replace_range.set("end", replace_end_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", replace_range);
	edit.set("newText", new_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Convert to expression body");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ── Quick fix: import all unresolved references ─────────────────

/**
 * When 2+ "Unresolved reference" diagnostics exist, offer a single
 * "Import all" action that resolves all of them at once.
 * Each unresolved name is resolved to its best candidate (first match).
 * Returns null if < 2 unresolved references or no candidates found.
 */
fn Object* try_import_all_unresolved(String uri, Document* doc, ParseResult* ast,
	WorkspaceIndex* workspace, Object* client_diagnostics) {
	if (workspace == null || ast == null) return null;

	// Collect all unresolved names from diagnostics
	String[32] unresolved_names;
	usz unresolved_count = 0;

	for (sz i = 0; i < client_diagnostics.get_len() && unresolved_count < 32; i++) {
		Object* diag = client_diagnostics.get_at(i);
		String message = diag.get_string("message") ?? "";
		if (!message.starts_with("Unresolved reference: '")) continue;

		String name = extract_unresolved_name(message);
		if (name.len == 0) continue;

		// Dedup
		bool dup = false;
		for (usz j = 0; j < unresolved_count; j++) {
			if (unresolved_names[j] == name) { dup = true; break; }
		}
		if (dup) continue;

		unresolved_names[unresolved_count] = name;
		unresolved_count++;
	}

	if (unresolved_count < 2) return null;

	// Resolve each name to its best import candidate
	String[32] import_paths;
	usz import_count = 0;

	bool needs_newline_before = false;
	uint insert_line = find_import_insertion_line(ast, &needs_newline_before);

	for (usz i = 0; i < unresolved_count; i++) {
		String[16] candidates;
		String[16] packages;
		usz cand_count = diagnostics::find_import_candidates(
			unresolved_names[i], workspace, &candidates, &packages);
		if (cand_count == 0) continue;

		// Use first candidate (best match)
		String path = candidates[0];

		// Check not already imported
		if (is_already_imported(ast, path, packages[0])) continue;

		// Dedup against already-collected paths
		bool dup = false;
		for (usz j = 0; j < import_count; j++) {
			if (import_paths[j] == path) { dup = true; break; }
		}
		if (dup) continue;

		import_paths[import_count] = path;
		import_count++;
	}

	if (import_count < 2) return null;

	// Build combined import text
	DString import_text;
	import_text.tinit();
	if (needs_newline_before) {
		import_text.append("\n");
	}
	for (usz i = 0; i < import_count; i++) {
		import_text.appendf("import %s\n", import_paths[i]);
	}

	// Single insert edit
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", (int)insert_line);
	insert_start.set("character", 0);
	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", (int)insert_line);
	insert_end.set("character", 0);
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", import_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	DString title;
	title.tinit();
	title.appendf("Import all (%d imports)", (int)import_count);

	Object* action = object::new_obj(tmem);
	action.set("title", title.str_view());
	action.set("kind", "quickfix");
	action.set("edit", workspace_edit);
	return action;
}

// ── Source: star import suggestion ───────────────────────────────

struct PkgGroup {
	String package_name;
	uint[16] import_indices;
	usz count;
}

/**
 * When 3+ imports exist from the same package, offer to replace them
 * with a single star import `import pkg.*`.
 */
fn void add_star_import_actions(Object* actions, String uri, ParseResult* ast) {
	if (ast == null) return;

	// Collect all IMPORT_DECL nodes and group by package
	PkgGroup[16] groups;
	usz group_count = 0;

	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.extra_text.len == 0) continue; // extra_text = full import path

		// Extract package: everything before the last '.'
		String path = n.extra_text;
		usz last_dot = 0;
		bool found_dot = false;
		for (usz j = path.len; j > 0; j--) {
			if (path[j - 1] == '.') {
				last_dot = j - 1;
				found_dot = true;
				break;
			}
		}
		if (!found_dot) continue;
		// Skip star imports
		if (last_dot + 1 < path.len && path[last_dot + 1] == '*') continue;

		String pkg = path[:last_dot];

		// Find or create group
		bool found_group = false;
		for (usz g = 0; g < group_count; g++) {
			if (groups[g].package_name == pkg) {
				if (groups[g].count < 16) {
					groups[g].import_indices[groups[g].count] = i;
					groups[g].count++;
				}
				found_group = true;
				break;
			}
		}
		if (!found_group && group_count < 16) {
			groups[group_count].package_name = pkg;
			groups[group_count].import_indices[0] = i;
			groups[group_count].count = 1;
			group_count++;
		}
	}

	// Offer star import for groups with 3+ imports
	for (usz g = 0; g < group_count; g++) {
		if (groups[g].count < 3) continue;

		// Build edit: replace all imports in this group with one star import
		// Find the range covering first to last import in the group
		AstNode* first_import = &ast.nodes[groups[g].import_indices[0]];
		AstNode* last_import = &ast.nodes[groups[g].import_indices[groups[g].count - 1]];

		DString star_text;
		star_text.tinit();
		star_text.appendf("import %s.*\n", groups[g].package_name);

		// Replace from first import start to last import end (full lines)
		Object* replace_start = object::new_obj(tmem);
		replace_start.set("line", (int)first_import.start_line);
		replace_start.set("character", 0);
		// End: next line after last import
		Object* replace_end = object::new_obj(tmem);
		replace_end.set("line", (int)last_import.end_line + 1);
		replace_end.set("character", 0);
		Object* replace_range = object::new_obj(tmem);
		replace_range.set("start", replace_start);
		replace_range.set("end", replace_end);

		Object* edit = object::new_obj(tmem);
		edit.set("range", replace_range);
		edit.set("newText", star_text.str_view());

		Object* edits = object::new_obj(tmem);
		edits.push(edit);

		Object* changes = object::new_obj(tmem);
		changes.set(uri, edits);
		Object* workspace_edit = object::new_obj(tmem);
		workspace_edit.set("changes", changes);

		DString title;
		title.tinit();
		title.appendf("Replace with 'import %s.*'", groups[g].package_name);

		Object* action = object::new_obj(tmem);
		action.set("title", title.str_view());
		action.set("kind", "source.organizeImports");
		action.set("edit", workspace_edit);
		actions.push(action);
	}
}

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Build a Range that covers from the start of start_line to the start
 * of (end_line + 1), effectively deleting the entire line(s) including
 * the trailing newline.
 */
fn Object* build_line_delete_range(int start_line, int end_line) {
	Object* start = object::new_obj(tmem);
	start.set("line", start_line);
	start.set("character", 0);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", end_line + 1);
	end_pos.set("character", 0);

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	return range;
}

/**
 * Extract the expected token from a parser error message.
 * Messages have the form: "Expected '<tok>', got '<actual>'"
 * Returns the token string (e.g., ")", "}", ">") or "" if not found.
 */
fn String extract_expected_token(String message) {
	// Find "Expected '" and extract up to the next "'"
	String prefix = "Expected '";
	if (!message.starts_with(prefix)) return "";

	String rest = message[prefix.len..];
	// Find the closing single quote
	for (usz i = 0; i < rest.len; i++) {
		if (rest[i] == '\'') {
			return rest[:i];
		}
	}
	return "";
}

/**
 * Check if a given code action kind is wanted based on the client's
 * "only" filter. If no filter is set (empty slice), all kinds are wanted.
 * Uses prefix matching per LSP spec (e.g., "source" matches
 * "source.organizeImports").
 */
fn bool is_kind_wanted(String kind, String[] only_kinds) {
	if (only_kinds.len == 0) return true; // no filter = all wanted

	for (usz i = 0; i < only_kinds.len; i++) {
		String filter = only_kinds[i];
		// Exact match
		if (kind == filter) return true;
		// Filter is a prefix of kind: "source" matches "source.organizeImports"
		if (kind.len > filter.len && kind.starts_with(filter) && kind[filter.len] == '.') return true;
		// Kind is a prefix of filter: kind "quickfix" matches filter "quickfix.import"
		if (filter.len > kind.len && filter.starts_with(kind) && filter[kind.len] == '.') return true;
	}
	return false;
}

// ── Import action helpers ────────────────────────────────────────

/**
 * Find the line where a new import should be inserted.
 * Returns the line number where the import text should be placed.
 * If there are existing imports, inserts after the last import line.
 * If no imports exist but there's a package declaration, inserts after
 * the package line + 1 blank line.
 * Otherwise inserts at line 0.
 *
 * `needs_newline_before` is set to true when a blank line should be
 * inserted before the import (e.g. after a package declaration with
 * no existing imports).
 */
fn uint find_import_insertion_line(ParseResult* ast, bool* needs_newline_before) {
	*needs_newline_before = false;

	// Find the last IMPORT_DECL's end_line at FILE level
	bool found_import = false;
	uint last_import_end_line = 0;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.parent != 0) continue;
		found_import = true;
		if (n.end_line >= last_import_end_line) {
			last_import_end_line = n.end_line;
		}
	}

	if (found_import) {
		return last_import_end_line + 1; // line after last import
	}

	// No imports -- look for PACKAGE_DECL
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind == PACKAGE_DECL && n.parent == 0) {
			*needs_newline_before = true;
			return n.end_line + 1; // line after package declaration
		}
	}

	// No package, no imports: insert at line 0
	return 0;
}

/**
 * Check if an import for the given path already exists in the AST.
 * Returns true if there's an IMPORT_DECL with the exact path, or a
 * wildcard import covering the package.
 */
fn bool is_already_imported(ParseResult* ast, String import_path, String package_name) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.parent != 0) continue;

		String path = n.extra_text;
		// Exact match
		if (path == import_path) return true;

		// Wildcard match: import foo.bar.* covers foo.bar.Baz
		if (path.len >= 2 && path[path.len - 1] == '*' && path[path.len - 2] == '.') {
			String pkg_prefix = path[:path.len - 2];
			if (pkg_prefix == package_name) return true;
		}
	}
	return false;
}

/**
 * Build a code action that inserts `import <import_path>` at the
 * appropriate position in the file.
 */
fn Object* build_import_action(String uri, ParseResult* ast, String import_path, Object* diag) {
	bool needs_newline_before = false;
	uint insert_line = find_import_insertion_line(ast, &needs_newline_before);

	// Build the import text to insert
	DString import_text;
	import_text.tinit();
	if (needs_newline_before) {
		import_text.append("\n");
	}
	import_text.appendf("import %s\n", import_path);

	// Build zero-width insert range at the start of the insertion line
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", (int)insert_line);
	insert_start.set("character", 0);

	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", (int)insert_line);
	insert_end.set("character", 0);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start);
	insert_range.set("end", insert_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", import_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	DString title;
	title.tinit();
	title.appendf("Import '%s'", import_path);

	Object* action = object::new_obj(tmem);
	action.set("title", title.str_view());
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	// Link to the diagnostic if provided
	if (diag != null) {
		Object* action_diags = object::new_obj(tmem);
		action_diags.push(diag);
		action.set("diagnostics", action_diags);
	}

	return action;
}

/**
 * Extract the identifier name from an "Unresolved reference: '<name>'" message.
 */
fn String extract_unresolved_name(String message) {
	String prefix = "Unresolved reference: '";
	if (!message.starts_with(prefix)) return "";
	String rest = message[prefix.len..];
	for (usz i = 0; i < rest.len; i++) {
		if (rest[i] == '\'') {
			return rest[:i];
		}
	}
	return "";
}

/**
 * Add "Import '<pkg>.<name>'" code actions for an unresolved reference diagnostic.
 */
fn void add_import_actions_for_diagnostic(Object* actions, String uri, Document* doc,
	ParseResult* ast, WorkspaceIndex* workspace, Object* diag, String message) {
	if (workspace == null || ast == null) return;

	String name = extract_unresolved_name(message);
	if (name.len == 0) return;

	String[16] import_paths;
	String[16] packages;
	usz count = diagnostics::find_import_candidates(name, workspace, &import_paths, &packages);

	for (usz i = 0; i < count; i++) {
		if (is_already_imported(ast, import_paths[i], packages[i])) continue;
		Object* action = build_import_action(uri, ast, import_paths[i], diag);
		if (action != null) {
			actions.push(action);
		}
	}
}

/**
 * When the cursor is on a dot member (e.g. `randomUUID` in `UUID.randomUUID()`),
 * walk backward in the source to find the receiver identifier before the `.` or `?.`.
 * Returns the receiver name, or a fault if the token is not a dot member.
 */
fn String? find_dot_receiver(String content, Token tok) {
	if (tok.offset == 0) return NO_RECEIVER~;
	usz pos = (usz)tok.offset;

	// Walk backward over whitespace before the current token
	while (pos > 0 && (content[pos - 1] == ' ' || content[pos - 1] == '\t'
			|| content[pos - 1] == '\n' || content[pos - 1] == '\r')) {
		pos--;
	}

	// Check for '.' or '?.' (safe call)
	if (pos == 0) return NO_RECEIVER~;
	if (content[pos - 1] == '.') {
		pos--;
		// Check for '?.' (safe call) — skip the '?' too
		if (pos > 0 && content[pos - 1] == '?') {
			pos--;
		}
	} else {
		return NO_RECEIVER~;
	}

	// Walk backward over whitespace before the dot
	while (pos > 0 && (content[pos - 1] == ' ' || content[pos - 1] == '\t'
			|| content[pos - 1] == '\n' || content[pos - 1] == '\r')) {
		pos--;
	}

	// The receiver should end here — find the start of the identifier
	if (pos == 0) return NO_RECEIVER~;
	usz end = pos;

	// Walk backward over identifier chars ([a-zA-Z0-9_])
	while (pos > 0) {
		char c = content[pos - 1];
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
				|| (c >= '0' && c <= '9') || c == '_') {
			pos--;
		} else {
			break;
		}
	}

	if (pos == end) return NO_RECEIVER~;  // no identifier chars found

	// Verify the first char is not a digit (valid identifier start)
	char first = content[pos];
	if (first >= '0' && first <= '9') return NO_RECEIVER~;

	return content[pos..end - 1];
}

/**
 * Offer import actions for a given identifier name. Shared logic between
 * the direct-token path and the dot-receiver fallback path.
 */
fn void offer_import_actions(Object* actions, String uri, ParseResult* ast,
	WorkspaceIndex* workspace, String name, uint offset) {
	// Skip if already imported or locally declared
	if (diagnostics::is_name_in_scope(ast, name, offset)) return;
	if (diagnostics::is_auto_imported(name)) return;

	// Look up candidates
	String[16] import_paths;
	String[16] packages;
	usz count = diagnostics::find_import_candidates(name, workspace, &import_paths, &packages);

	for (usz i = 0; i < count; i++) {
		if (is_already_imported(ast, import_paths[i], packages[i])) continue;

		// Check we haven't already added an action for this import path
		// (from the diagnostic-driven path)
		bool already_offered = false;
		for (sz j = 0; j < actions.get_len(); j++) {
			String title = actions.get_at(j).get_string("title") ?? "";
			DString expected_title;
			expected_title.tinit();
			expected_title.appendf("Import '%s'", import_paths[i]);
			if (title == expected_title.str_view()) {
				already_offered = true;
				break;
			}
		}
		if (already_offered) continue;

		Object* action = build_import_action(uri, ast, import_paths[i], null);
		if (action != null) {
			actions.push(action);
		}
	}
}

/**
 * Add "Import '<pkg>.<name>'" code actions based on the cursor position,
 * independent of diagnostics. Inspects the token at the cursor and offers
 * import suggestions if it's an unresolved identifier.
 *
 * When the cursor is on a dot member (e.g. `randomUUID` in `UUID.randomUUID()`),
 * walks back to the receiver (`UUID`) and offers its import instead.
 */
fn void add_import_actions_at_cursor(Object* actions, String uri, Document* doc,
	ParseResult* ast, WorkspaceIndex* workspace, Object* params) {
	// Get cursor position from the request range
	Object* range = params.get("range") ?? null;
	if (range == null) return;
	Object* start = range.get("start") ?? null;
	if (start == null) return;
	uint line = (uint)(start.get_int("line") ?? 0);
	uint character = (uint)(start.get_int("character") ?? 0);

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return;
	}

	if (tok.kind != IDENTIFIER) return;

	String name = tok.text;
	uint offset = tok.offset;

	// Track how many actions existed before we start
	sz count_before = actions.get_len();

	// Try direct token first
	offer_import_actions(actions, uri, ast, workspace, name, offset);

	// If no import actions were added and the token is a dot member, try the receiver
	if (actions.get_len() == count_before) {
		if (try receiver = find_dot_receiver(doc.content, tok)) {
			offer_import_actions(actions, uri, ast, workspace, receiver, offset);
		}
	}
}
