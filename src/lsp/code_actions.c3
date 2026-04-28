module kls::lsp::code_actions;

import std::collections::object;
import std::collections::list;
import kls::document;
import kls::lsp::diagnostics;
import kls::lsp::inlay_hints;
import kls::kotlin::ast;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::types;
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
 *   - "Replace '|' with '||'" (quickfix) for operator errors
 *   - "Insert missing '<delim>'" (quickfix) for Expected ')', '}', '>' errors
 *   - "Import <pkg>.<name>" (quickfix) for unresolved references
 */
fn Object*? handle_code_action(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* context = params.get("context")!;
	Object* client_diagnostics = context.get("diagnostics")!;

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

		// Quick fix: change `var` to `val` for never-reassigned local
		if (message.starts_with("Variable '") && message.contains("can be 'val'")
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_change_var_to_val(uri, doc, ast, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: remove unnecessary `!!`
		if (message.starts_with("Unnecessary '!!'")
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_not_null_assertion(uri, doc, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: simplify `if (cond) true else false` → `cond`
		if (message.starts_with("Redundant 'if'") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_simplify_redundant_if_bool(uri, doc, ast, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: simplify subject-less `when { cond -> true; else -> false }` → `cond`
		if (message.starts_with("Redundant 'when'") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_simplify_redundant_when_bool(uri, doc, ast, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: remove redundant elvis `?:` on non-null LHS
		if (message.starts_with("Elvis operator (?:) on non-null") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_redundant_elvis(uri, doc, ast, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: remove redundant override
		if (message.starts_with("Override is redundant") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_redundant_override(uri, doc, ast, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: remove redundant else arm in exhaustive when
		if (message.starts_with("'else' is redundant") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_redundant_else_arm(uri, doc, ast, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: simplify `b == true` / `b != false` / etc.
		if (message.starts_with("Redundant comparison to boolean literal") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_simplify_redundant_bool_cmp(uri, doc, ast, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: remove useless cast `x as T`
		if (message.starts_with("Useless cast") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_useless_cast(uri, doc, ast, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: replace redundant `x is T` / `x !is T` with literal
		if (message.starts_with("Type check is always") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_replace_type_check_with_literal(uri, doc, ast, diag, message);
			if (action != null) {
				actions.push(action);
			}
		}

		// Quick fix: remove redundant explicit type on val/var
		if (message.starts_with("Explicitly given type is redundant") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_remove_redundant_explicit_type(uri, doc, ast, diag);
			if (action != null) {
				actions.push(action);
			}
		}

		if (message.starts_with("Only safe (?.) or non-null asserted") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			try_add_unsafe_null_recv_actions(actions, uri, doc, ast, diag);
		}

		if (message.starts_with("Parameter '") && message.contains("is never used")
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* action = try_rename_unused_param_underscore(uri, diag);
			if (action != null) {
				actions.push(action);
			}
			Object* prefix_action = try_prefix_unused_param_underscore(uri, diag);
			if (prefix_action != null) {
				actions.push(prefix_action);
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

		// Quick fix: add missing branches to non-exhaustive sealed when
		if (message.starts_with("'when' on sealed class ") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* sealed_action = try_add_missing_sealed_branches(uri, doc, ast, diag, message);
			if (sealed_action != null) {
				actions.push(sealed_action);
			}
		}

		// Quick fix: add missing branches to non-exhaustive enum when
		if (message.starts_with("'when' on enum class ") && doc != null && ast != null
			&& is_kind_wanted("quickfix", only_kinds[:only_count])) {
			Object* enum_action = try_add_missing_enum_branches(uri, doc, ast, diag, message);
			if (enum_action != null) {
				actions.push(enum_action);
			}
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
		Object* extract_all = try_extract_variable_all_occurrences(uri, doc, ast, params);
		if (extract_all != null) {
			actions.push(extract_all);
		}
		Object* extract_fn = try_extract_function(uri, doc, ast, params);
		if (extract_fn != null) {
			actions.push(extract_fn);
		}
	}

	// ── Refactor: surround with try/catch ───────────────────────
	if (doc != null && ast != null && is_kind_wanted("refactor.rewrite", only_kinds[:only_count])) {
		Object* surround = try_surround_with_try_catch(uri, doc, ast, params);
		if (surround != null) {
			actions.push(surround);
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
		Object* if_to_when = try_convert_if_chain_to_when(uri, doc, ast, params);
		if (if_to_when != null) {
			actions.push(if_to_when);
		}
		Object* cmp_chain = try_simplify_compareto_chain(uri, doc, ast, params);
		if (cmp_chain != null) {
			actions.push(cmp_chain);
		}
		Object* if_bool = try_simplify_if_bool_consts(uri, doc, ast, params);
		if (if_bool != null) {
			actions.push(if_bool);
		}
		Object* let_to_sc = try_collapse_let_to_safe_call(uri, doc, ast, params);
		if (let_to_sc != null) {
			actions.push(let_to_sc);
		}
		Object* lateinit_lazy = try_lateinit_to_lazy(uri, doc, ast, params);
		if (lateinit_lazy != null) {
			actions.push(lateinit_lazy);
		}
		Object* null_pass = try_simplify_null_passthrough(uri, doc, ast, params);
		if (null_pass != null) {
			actions.push(null_pass);
		}
		Object* when_to_if = try_convert_when_to_if_chain(uri, doc, ast, params);
		if (when_to_if != null) {
			actions.push(when_to_if);
		}
		Object* concat_to_tpl = try_convert_concat_to_template(uri, doc, ast, params);
		if (concat_to_tpl != null) {
			actions.push(concat_to_tpl);
		}
		TypeInfo* ti_aet = store.get_types(uri) ?? null;
		Object* add_type = try_add_explicit_type(uri, doc, ast, ti_aet, params);
		if (add_type != null) {
			actions.push(add_type);
		}
		Object* add_ret = try_add_return_type(uri, doc, ast, ti_aet, params);
		if (add_ret != null) {
			actions.push(add_ret);
		}
		Object* expr_to_block = try_convert_expression_body_to_block(uri, doc, ast, ti_aet, params);
		if (expr_to_block != null) {
			actions.push(expr_to_block);
		}
		add_scope_function_actions(actions, uri, doc, ast, params);
		Object* split_decl = try_split_declaration_assignment(uri, doc, ast, params);
		if (split_decl != null) {
			actions.push(split_decl);
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

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	Object* end = range.get("end") ?? null;
	if (start == null || end == null) return null;
	int start_line;
	int end_line;
	if (try sl = start.get_int("line")) { start_line = sl; } else { return null; }
	if (try el = end.get_int("line")) { end_line = el; } else { return null; }

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
		Object* range = diags[i].get("range") ?? null;
		if (range == null) continue;
		Object* start = range.get("start") ?? null;
		Object* end = range.get("end") ?? null;
		if (start == null || end == null) continue;
		int start_line;
		int end_line;
		if (try sl = start.get_int("line")) { start_line = sl; } else { continue; }
		if (try el = end.get_int("line")) { end_line = el; } else { continue; }

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

// ── Quick fix: replace | with || ─────────────────────────────────

/**
 * If the diagnostic message indicates a lone '|', offer to
 * replace it with '||'.
 */
fn Object* try_fix_operator(String uri, Object* diag, String message) {
	// Messages look like: "Unexpected character: '|'"
	String replacement;
	String title;

	if (message.contains("'|'")) {
		replacement = "||";
		title = "Replace '|' with '||'";
	} else {
		return null;
	}

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;

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

// ── Refactor: convert if/else-if chain → when ──────────────────

/**
 * Find the TOP of an if-chain: walk up while parent is IF_EXPR with `cur`
 * sitting in its else-slot (3rd child).
 */
fn uint top_of_if_chain(ParseResult* ast, uint if_idx) {
	uint cur = if_idx;
	while (true) {
		AstNode* n = &ast.nodes[cur];
		uint p = n.parent;
		if (p == 0 || p >= ast.node_count) return cur;
		if (ast.nodes[p].kind != IF_EXPR) return cur;
		uint count = 0;
		uint else_idx = uint.max;
		for (uint i = 1; i < ast.node_count; i++) {
			if (ast.nodes[i].parent != p) continue;
			count++;
			if (count == 3) { else_idx = i; break; }
		}
		if (else_idx != cur) return cur;
		cur = p;
	}
}

/**
 * Build "Convert to when" code action. Cursor must be on or in an IF_EXPR
 * that starts an if/else-if chain (≥ 1 else-if).
 */
/**
 * Extract the condition text from an IF_EXPR by scanning source for `(` after
 * `if` keyword and matching `)`. Returns "" on failure.
 * Sets `cond_end_offset` to the byte offset just after the closing `)`.
 */
fn String extract_if_cond_text(String content, AstNode* if_node, uint* cond_end_offset) {
	uint p = if_node.start_offset;
	// Skip "if" keyword
	while (p < if_node.end_offset && content[p] != '(') p++;
	if (p >= if_node.end_offset || content[p] != '(') return "";
	uint open = p;
	uint depth = 0;
	while (p < if_node.end_offset) {
		char c = content[p];
		if (c == '(') {
			depth++;
		} else if (c == ')') {
			depth--;
			if (depth == 0) {
				*cond_end_offset = p + 1;
				if (open + 1 > p) return "";
				return content[(usz)(open + 1)..(usz)p - 1];
			}
		}
		p++;
	}
	return "";
}

/**
 * Classify a condition AST node into (subject_name, arm_label) for `when (x)` form.
 *  - `x is T` / `x !is T`     → subject=x, label="is T" / "!is T"
 *  - `x == lit` / `x === lit` → subject=x, label=literal/expr text
 *  - `x in r`  / `x !in r`    → subject=x, label="in r" / "!in r"
 *  - else                     → subject="" (unclassifiable)
 *
 * Subject must be a NAME_EXPR. Multi-level (a.b) deliberately rejected.
 */
fn void classify_subject_cond(ParseResult* ast, String content, uint cond_idx, String* subject, String* label) {
	*subject = "";
	*label = "";
	AstNode* n = &ast.nodes[cond_idx];

	// Disjunction `a || b` — recurse on both sides; if same subject, merge
	// labels with ", " (Kotlin when arm comma list).
	if (n.kind == BINARY_EXPR && n.extra_text == "||") {
		uint left_idx = uint.max;
		uint right_idx = uint.max;
		for (uint i = 0; i < ast.node_count; i++) {
			if (ast.nodes[i].parent != cond_idx) continue;
			if (left_idx == uint.max) {
				left_idx = i;
			} else if (right_idx == uint.max) {
				right_idx = i;
			}
		}
		if (left_idx == uint.max || right_idx == uint.max) return;
		String l_subj; String l_label;
		String r_subj; String r_label;
		classify_subject_cond(ast, content, left_idx, &l_subj, &l_label);
		if (l_subj.len == 0) return;
		classify_subject_cond(ast, content, right_idx, &r_subj, &r_label);
		if (r_subj.len == 0 || r_subj != l_subj) return;
		*subject = l_subj;
		*label = string::tformat("%s, %s", l_label, r_label);
		return;
	}

	if (n.kind == TYPE_CHECK_EXPR) {
		uint subj_idx = uint.max;
		for (uint i = 1; i < ast.node_count; i++) {
			if (ast.nodes[i].parent == cond_idx) { subj_idx = i; break; }
		}
		if (subj_idx == uint.max) return;
		AstNode* subj = &ast.nodes[subj_idx];
		if (subj.kind != NAME_EXPR) return;
		*subject = subj.name;
		*label = string::tformat("%s %s", n.extra_text, n.type_text);
		return;
	}

	if (n.kind == BINARY_EXPR) {
		String op = n.extra_text;
		bool is_eq = (op == "==" || op == "===");
		bool is_in = (op == "in" || op == "!in");
		if (!is_eq && !is_in) return;
		uint left_idx = uint.max;
		uint right_idx = uint.max;
		for (uint i = 1; i < ast.node_count; i++) {
			if (ast.nodes[i].parent != cond_idx) continue;
			if (left_idx == uint.max) {
				left_idx = i;
			} else if (right_idx == uint.max) {
				right_idx = i;
			}
		}
		if (left_idx == uint.max || right_idx == uint.max) return;
		AstNode* left = &ast.nodes[left_idx];
		if (left.kind != NAME_EXPR) return;
		*subject = left.name;
		AstNode* right = &ast.nodes[right_idx];
		String right_text = content[(usz)right.start_offset..(usz)right.end_offset - 1];
		if (is_eq) {
			*label = right_text;
		} else {
			*label = string::tformat("%s %s", op, right_text);
		}
		return;
	}
}

fn Object* try_convert_if_chain_to_when(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest IF_EXPR containing cursor
	uint if_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IF_EXPR) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			if_idx = i;
		}
	}
	if (if_idx == uint.max) return null;

	uint top_idx = top_of_if_chain(ast, if_idx);
	AstNode* top = &ast.nodes[top_idx];

	// Walk down chain. For each IF_EXPR:
	//  - cond text via source scan (parser may not adopt cond as child)
	//  - cond AST via direct-child whose start_offset falls inside cond range (may be uint.max)
	//  - then body = first child whose start_offset >= cond_end
	//  - else = next child after then; if IF_EXPR continue, else terminal
	String[16] cond_texts;
	String[16] body_texts;
	uint[16] cond_ast;
	uint[16] body_starts;
	uint[16] body_ends;
	usz arm_count = 0;
	String else_body_text = "";
	bool has_else = false;
	uint else_body_start = 0;
	uint else_body_end = 0;

	uint cur = top_idx;
	while (arm_count < 16) {
		AstNode* cur_n = &ast.nodes[cur];
		uint cond_end = 0;
		String cond_text = extract_if_cond_text(doc.content, cur_n, &cond_end);
		if (cond_text.len == 0) return null;

		// Find cond AST node (direct child of cur with start_offset in cond range)
		uint cond_node = uint.max;
		uint then_idx = uint.max;
		uint else_idx = uint.max;
		for (uint i = 1; i < ast.node_count; i++) {
			if (ast.nodes[i].parent != cur) continue;
			if (ast.nodes[i].start_offset < cond_end) {
				// cond child — pick outermost (smallest start_offset, largest span) if multiple
				if (cond_node == uint.max ||
					ast.nodes[i].end_offset - ast.nodes[i].start_offset >
					ast.nodes[cond_node].end_offset - ast.nodes[cond_node].start_offset) {
					cond_node = i;
				}
				continue;
			}
			if (then_idx == uint.max) {
				then_idx = i;
			} else if (else_idx == uint.max) {
				else_idx = i;
			}
		}
		if (then_idx == uint.max) return null;

		AstNode* then_n = &ast.nodes[then_idx];
		cond_texts[arm_count] = cond_text;
		cond_ast[arm_count] = cond_node;
		body_texts[arm_count] = doc.content[(usz)then_n.start_offset..(usz)then_n.end_offset - 1];
		body_starts[arm_count] = then_n.start_offset;
		body_ends[arm_count] = then_n.end_offset;
		arm_count++;

		if (else_idx == uint.max) break;
		AstNode* else_n = &ast.nodes[else_idx];
		if (else_n.kind == IF_EXPR) {
			cur = else_idx;
			continue;
		}
		else_body_text = doc.content[(usz)else_n.start_offset..(usz)else_n.end_offset - 1];
		else_body_start = else_n.start_offset;
		else_body_end = else_n.end_offset;
		has_else = true;
		break;
	}

	if (arm_count < 2) return null;

	// ── Bail on inter-arm comments ────────────────────────────────
	// Comments between arms (between bodies, around 'else if', after closing braces)
	// would be silently dropped by the rewrite. Refuse the refactor when any such
	// comment exists. Comments inside arm body slices survive because we copy the
	// body source verbatim; only check the bytes NOT covered by any body span.
	{
		usz scan_lo = top.start_offset;
		usz scan_hi = top.end_offset;
		// Build sorted (start, end) span list of body slices to skip.
		uint[17] span_starts;
		uint[17] span_ends;
		usz span_n = 0;
		for (usz i = 0; i < arm_count; i++) {
			span_starts[span_n] = body_starts[i];
			span_ends[span_n] = body_ends[i];
			span_n++;
		}
		if (has_else) {
			span_starts[span_n] = else_body_start;
			span_ends[span_n] = else_body_end;
			span_n++;
		}
		// Sort by start (small N — bubble sort fine).
		for (usz i = 0; i + 1 < span_n; i++) {
			for (usz j = 0; j + 1 < span_n - i; j++) {
				if (span_starts[j] > span_starts[j+1]) {
					uint ts = span_starts[j]; span_starts[j] = span_starts[j+1]; span_starts[j+1] = ts;
					uint te = span_ends[j]; span_ends[j] = span_ends[j+1]; span_ends[j+1] = te;
				}
			}
		}
		usz cursor = scan_lo;
		for (usz i = 0; i < span_n; i++) {
			if (span_starts[i] > cursor) {
				if (range_has_comment(doc.content, cursor, span_starts[i])) return null;
			}
			if (span_ends[i] > cursor) cursor = span_ends[i];
		}
		if (cursor < scan_hi) {
			if (range_has_comment(doc.content, cursor, scan_hi)) return null;
		}
	}

	// Try to detect a common subject across all arms.
	// Each arm classified into (subject_name, arm_label).
	// If all share the same non-empty subject → emit `when (subject) { label -> body; ... }`.
	String[16] arm_subjects;
	String[16] arm_labels;
	String common_subject = "";
	bool subject_form = true;
	for (usz i = 0; i < arm_count; i++) {
		String subj = "";
		String label = "";
		if (cond_ast[i] != uint.max) {
			classify_subject_cond(ast, doc.content, cond_ast[i], &subj, &label);
		}
		arm_subjects[i] = subj;
		arm_labels[i] = label;
		if (subj.len == 0) {
			subject_form = false;
		} else if (i == 0) {
			common_subject = subj;
		} else if (subj != common_subject) {
			subject_form = false;
		}
	}

	String outer_indent = line_leading_indent(doc.content, top.start_line);
	String inner_indent = string::tformat("%s\t", outer_indent);

	DString out;
	out.tinit();
	if (subject_form) {
		out.appendf("when (%s) {\n", common_subject);
	} else {
		out.append("when {\n");
	}
	for (usz i = 0; i < arm_count; i++) {
		out.append(inner_indent);
		if (subject_form) {
			out.append(arm_labels[i]);
		} else {
			out.append(cond_texts[i]);
		}
		out.append(" -> ");
		String reindented = reindent_block(body_texts[i], inner_indent);
		out.append(reindented);
		out.append("\n");
	}
	if (has_else) {
		out.append(inner_indent);
		out.append("else -> ");
		String reindented = reindent_block(else_body_text, inner_indent);
		out.append(reindented);
		out.append("\n");
	}
	out.append(outer_indent);
	out.append("}");

	Object* rs = object::new_obj(tmem);
	rs.set("line", (int)top.start_line);
	rs.set("character", (int)top.start_col);
	Object* re = object::new_obj(tmem);
	re.set("line", (int)top.end_line);
	re.set("character", (int)top.end_col);
	Object* rrange = object::new_obj(tmem);
	rrange.set("start", rs);
	rrange.set("end", re);

	Object* edit = object::new_obj(tmem);
	edit.set("range", rrange);
	edit.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Convert to when");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ── Refactor: convert when → if-chain ────────────────────────────

/**
 * Translate a when-arm condition (verbatim source text from the cond AST node)
 * into an if-chain condition.
 *  - subject empty       → cond_text returned verbatim
 *  - cond is "is T"/"!is T" or "in r"/"!in r" → "subject <op> ..."
 *  - else                → "subject == cond_text"
 */
fn String arm_label_to_if_cond(String subject, String cond_text) {
	if (subject.len == 0) return cond_text;
	String t = cond_text.trim();
	if (t.starts_with("is ") || t.starts_with("!is ")) {
		return string::tformat("%s %s", subject, t);
	}
	if (t.starts_with("in ") || t.starts_with("!in ")) {
		return string::tformat("%s %s", subject, t);
	}
	return string::tformat("%s == %s", subject, t);
}

fn Object* try_convert_when_to_if_chain(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest WHEN_EXPR containing cursor
	uint when_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != WHEN_EXPR) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			when_idx = i;
		}
	}
	if (when_idx == uint.max) return null;

	AstNode* when_n = &ast.nodes[when_idx];

	// Walk direct children: subject (optional, kind != WHEN_ENTRY) then WHEN_ENTRYs.
	String subject = "";
	uint[64] entries;
	usz entry_count = 0;
	for (uint i = 1; i < ast.node_count; i++) {
		if (ast.nodes[i].parent != when_idx) continue;
		AstNode* c = &ast.nodes[i];
		if (c.kind == WHEN_ENTRY) {
			if (entry_count >= 64) return null;
			entries[entry_count++] = i;
			continue;
		}
		// Subject candidate. Bail if it's a property decl (when (val x = ...)).
		if (c.kind == PROPERTY_DECL) return null;
		if (subject.len == 0) {
			subject = doc.content[(usz)c.start_offset..(usz)c.end_offset - 1];
		}
	}
	if (entry_count == 0) return null;

	String outer_indent = line_leading_indent(doc.content, when_n.start_line);
	String inner_indent = string::tformat("%s\t", outer_indent);

	DString out;
	out.tinit();
	bool first_arm = true;
	bool emitted_else = false;

	for (usz e = 0; e < entry_count; e++) {
		uint eidx = entries[e];
		AstNode* en = &ast.nodes[eidx];
		bool is_else = en.extra_text == "else";

		// Children of this WHEN_ENTRY: cond exprs then body. Body = last child.
		uint[16] kids;
		usz kid_count = 0;
		for (uint j = 1; j < ast.node_count; j++) {
			if (ast.nodes[j].parent != eidx) continue;
			if (kid_count >= 16) return null;
			kids[kid_count++] = j;
		}
		if (kid_count == 0) return null;

		uint body_idx = kids[kid_count - 1];
		usz cond_count = is_else ? 0 : kid_count - 1;

		AstNode* body_n = &ast.nodes[body_idx];
		String body_text = doc.content[(usz)body_n.start_offset..(usz)body_n.end_offset - 1];

		// If non-else and cond_count == 0, parser may have failed to adopt
		// cond AST (e.g. angle-bracket ambiguity). Fall back to source text
		// from entry start up to "->".
		String fallback_cond = "";
		if (!is_else && cond_count == 0) {
			uint p = en.start_offset;
			uint limit = body_n.start_offset;
			while (p + 1 < limit) {
				if (doc.content[p] == '-' && doc.content[p + 1] == '>') break;
				p++;
			}
			if (p + 1 >= limit) return null;
			fallback_cond = doc.content[(usz)en.start_offset..(usz)p - 1].trim();
			if (fallback_cond.len == 0) return null;
		}

		// Wrap body in {} if not already a block
		bool body_is_block = body_n.kind == BLOCK;
		String wrapped_body;
		if (body_is_block) {
			wrapped_body = reindent_block(body_text, outer_indent);
		} else {
			DString bb;
			bb.tinit();
			bb.append("{\n");
			bb.append(inner_indent);
			bb.append(body_text.trim());
			bb.append("\n");
			bb.append(outer_indent);
			bb.append("}");
			wrapped_body = bb.str_view();
		}

		if (is_else) {
			out.append(" else ");
			out.append(wrapped_body);
			emitted_else = true;
		} else {
			// Translate cond(s) and join with ||
			DString cond_buf;
			cond_buf.tinit();
			if (cond_count == 0) {
				// Use source-text fallback (single cond)
				String if_cond = arm_label_to_if_cond(subject, fallback_cond);
				cond_buf.append(if_cond);
			} else {
				for (usz c = 0; c < cond_count; c++) {
					AstNode* cn = &ast.nodes[kids[c]];
					String cond_src = doc.content[(usz)cn.start_offset..(usz)cn.end_offset - 1];
					String if_cond = arm_label_to_if_cond(subject, cond_src);
					if (c > 0) cond_buf.append(" || ");
					cond_buf.append(if_cond);
				}
			}
			if (first_arm) {
				out.appendf("if (%s) ", cond_buf.str_view());
				first_arm = false;
			} else {
				out.appendf(" else if (%s) ", cond_buf.str_view());
			}
			out.append(wrapped_body);
		}
	}

	if (first_arm) return null; // only had else?

	Object* rs = object::new_obj(tmem);
	rs.set("line", (int)when_n.start_line);
	rs.set("character", (int)when_n.start_col);
	Object* re = object::new_obj(tmem);
	re.set("line", (int)when_n.end_line);
	re.set("character", (int)when_n.end_col);
	Object* rrange = object::new_obj(tmem);
	rrange.set("start", rs);
	rrange.set("end", re);

	Object* edit = object::new_obj(tmem);
	edit.set("range", rrange);
	edit.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Convert to if-chain");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
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

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int start_line;
	int start_char;
	if (try sl = start.get_int("line")) { start_line = sl; } else { return null; }
	if (try sc = start.get_int("character")) { start_char = sc; } else { return null; }

	// Build an insert range (zero-width at the start of the diagnostic)
	Object* insert_start = object::new_obj(tmem);
	insert_start.set("line", start_line);
	insert_start.set("character", start_char);

	Object* insert_end = object::new_obj(tmem);
	insert_end.set("line", start_line);
	insert_end.set("character", start_char);
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

	// If block contains any comment between '{' and '}' (other than inside the
	// statement itself), refuse — converting would silently drop the comment.
	if (block_contains_comment_outside(doc.content, block, &ast.nodes[single_stmt_idx])) return null;

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

// ── Refactor: add explicit type to val/var ───────────────────────

/**
 * Cursor on `val x = expr` (no type annotation) → offer
 * "Add explicit type" → rewrites to `val x: T = expr`.
 *
 * Skips: properties already typed, destructuring decls, properties
 * whose type can't be inferred or resolves to UNKNOWN/Unit/Nothing.
 *
 * Reuses inlay_hints type inference (TypeInfo cache + heuristics).
 */
fn Object* try_add_explicit_type(String uri, Document* doc, ParseResult* ast,
		TypeInfo* ti, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest PROPERTY_DECL containing cursor
	uint prop_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != PROPERTY_DECL) continue;
		if ((uint)cursor_offset < n.start_offset) continue;
		if ((uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			prop_idx = i;
		}
	}
	if (prop_idx == uint.max) return null;

	AstNode* prop = &ast.nodes[prop_idx];

	// Skip if already typed
	if (prop.type_text.len > 0) return null;

	// Skip destructuring / no-name
	if (prop.name.len == 0 || prop.name == "(destructuring)") return null;

	// Try TypeInfo cache first, then heuristic
	String type_display = "";
	bool found = false;
	if (ti != null && ti.has_type[prop_idx]) {
		TypeRef tr = ti.node_types[prop_idx];
		if (tr.kind != UNKNOWN) {
			if (tr.full_text.len > 0) {
				type_display = tr.full_text;
				found = true;
			} else if (tr.name.len > 0) {
				type_display = tr.name;
				found = true;
			}
		}
	}
	if (!found) {
		if (try inferred = inlay_hints::infer_type_from_initializer(ast, ti, prop_idx, doc.content)) {
			type_display = inferred;
			found = true;
		}
	}
	if (!found) return null;

	// Reject useless types
	if (type_display.len == 0) return null;
	if (type_display == "Unit" || type_display == "Nothing") return null;
	if (type_display.contains("UNKNOWN") || type_display == "?") return null;

	// Insert ": Type" right after the property name
	DString new_text;
	new_text.tinit();
	new_text.appendf(": %s", type_display);

	Object* insert_pos = object::new_obj(tmem);
	insert_pos.set("line", (int)prop.name_line);
	insert_pos.set("character", (int)(prop.name_col + prop.name_len));
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_pos);
	insert_range.set("end", insert_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", new_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Add explicit type");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
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

// ── codeAction/resolve support ──────────────────────────────────
//
// The resolve handler recomputes edits on demand for clients that
// support lazy resolution. Actions are returned with edits eagerly,
// but clients can also send codeAction/resolve to recompute.

/**
 * Handle codeAction/resolve request.
 * Receives an action with "data" field, computes the full "edit", returns completed action.
 * Also handles actions that already have edits (returns as-is).
 */
fn Object*? handle_code_action_resolve(DocumentStore* store, WorkspaceIndex* workspace, Object* action) {
	// If action already has an edit, return as-is
	if (try action.get("edit")) {
		return action;
	}

	Object* data = action.get("data") ?? null;
	if (data == null) return action;

	String action_type = data.get_string("action_type") ?? "";
	String uri = data.get_string("uri") ?? "";
	Object* range = data.get("range") ?? null;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return action;

	ParseResult* ast = store.get_ast(uri) ?? null;
	if (ast == null) return action;

	// Build synthetic params object with range for the builder functions
	Object* params = object::new_obj(tmem);
	if (range != null) {
		params.set("range", range);
	}

	Object* resolved = null;

	if (action_type == "extract_variable") {
		resolved = try_extract_variable(uri, doc, ast, params);
	} else if (action_type == "extract_function") {
		resolved = try_extract_function(uri, doc, ast, params);
	} else if (action_type == "convert_expression_body") {
		resolved = try_convert_fun_to_expression_body(uri, doc, ast, params);
	} else if (action_type == "generate_toString" || action_type == "generate_equals" || action_type == "generate_hashCode") {
		Object* temp_actions = object::new_obj(tmem);
		add_data_class_actions(temp_actions, uri, doc, ast, params);
		String title = action.get_string("title") ?? "";
		for (sz i = 0; i < temp_actions.get_len(); i++) {
			Object* a = temp_actions.get_at(i);
			String t = a.get_string("title") ?? "";
			if (t == title) {
				resolved = a;
				break;
			}
		}
	}

	if (resolved != null) {
		if (try edit = resolved.get("edit")) {
			action.set("edit", edit);
		}
	}

	return action;
}

// ── Quick fix: add missing branches to non-exhaustive sealed when ─

/**
 * Build "Add missing branches" code action for a non-exhaustive sealed
 * `when` diagnostic emitted by add_sealed_exhaustive_diagnostics.
 *
 * Diagnostic message format:
 *   "'when' on sealed class 'X' is non-exhaustive: missing 'A', 'B', ..."
 *
 * Approach: parse missing names from message, find the WHEN_EXPR node
 * whose start position matches the diagnostic range start, infer indent
 * from the first WHEN_ENTRY's start column, insert one `is Name -> TODO()`
 * arm per missing subtype just before the closing `}`.
 */
fn Object* try_add_missing_sealed_branches(String uri, Document* doc, ParseResult* ast,
		Object* diag, String message) {
	if (doc == null || ast == null) return null;

	// Parse range start (line/col) — used to locate the WHEN_EXPR node
	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate WHEN_EXPR with matching start position
	uint when_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != WHEN_EXPR) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			when_idx = i;
			break;
		}
	}
	if (when_idx == (uint)-1) return null;
	AstNode* when_node = &ast.nodes[when_idx];

	// Parse missing names from message after "missing "
	usz missing_pos = 0;
	bool have_missing = false;
	for (usz i = 0; i + 8 <= message.len; i++) {
		if (message[i:8] == "missing ") {
			missing_pos = i + 8;
			have_missing = true;
			break;
		}
	}
	if (!have_missing) return null;

	String[] names = parse_quoted_names(message[missing_pos..]);
	if (names.len == 0) return null;

	// Determine indent from first WHEN_ENTRY child
	uint entry_col = when_node.start_col + 1; // fallback: when_col+1
	for (uint j = when_node.children_start; j < ast.node_count; j++) {
		AstNode* child = &ast.nodes[j];
		if (child.parent != when_idx) continue;
		if (child.kind == WHEN_ENTRY) {
			entry_col = child.start_col;
			break;
		}
	}

	String indent = build_indent_for_column(doc.content, entry_col);

	// Build newText: one `is X -> TODO()\n<indent>` per missing
	DString text;
	text.tinit();
	for (usz i = 0; i < names.len; i++) {
		text.appendf("is %s -> TODO()\n%s", names[i], indent);
	}

	// Insertion point: just before the closing `}` of the when block.
	// when_node.end_line/end_col point past the closing brace.
	// We insert at (end_line, end_col - 1) which is the position of `}`.
	int insert_line = (int)when_node.end_line;
	int insert_col = (int)when_node.end_col - 1;
	if (insert_col < 0) insert_col = 0;

	Object* pos = object::new_obj(tmem);
	pos.set("line", (int128)insert_line);
	pos.set("character", (int128)insert_col);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", pos);
	insert_range.set("end", pos);

	Object* edit_obj = object::new_obj(tmem);
	edit_obj.set("range", insert_range);
	edit_obj.set("newText", text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit_obj);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Add missing branches");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

/**
 * Parse single-quoted names from a comma-separated list.
 * Input: "'A', 'B', 'C'"  Output: ["A", "B", "C"] (tmem-allocated).
 */
fn String[] parse_quoted_names(String s) {
	List{String} names;
	names.tinit();
	usz i = 0;
	while (i < s.len) {
		// Skip to next single quote
		while (i < s.len && s[i] != '\'') i++;
		if (i >= s.len) break;
		i++; // past opening quote
		usz start = i;
		while (i < s.len && s[i] != '\'') i++;
		if (i > start) {
			names.push(s[start:i - start].tcopy());
		}
		if (i < s.len) i++; // past closing quote
	}
	return names.array_view();
}

/**
 * Produce a whitespace string that visually fills `target_col` columns
 * (1-indexed). Tabs are taken as 4 columns. Falls back to plain spaces.
 */
fn String build_indent_for_column(String content, uint target_col) {
	if (target_col <= 1) return "";
	// Use spaces — robust default; tabs are rendered inconsistently by clients
	DString s;
	s.tinit();
	for (uint i = 1; i < target_col; i++) s.append_char(' ');
	return s.str_view();
}

// ── Refactor: surround with try/catch ─────────────────────────────

/**
 * Build a "Surround with try/catch" code action for the given selection.
 *
 * Wraps the selected text in:
 *   try {
 *       <selected text>
 *   } catch (e: Exception) {
 *       TODO("Handle exception")
 *   }
 *
 * Selection rules:
 *   - Empty selection: no action.
 *   - Selection must lie inside a function/lambda body (BLOCK ancestor).
 *   - Indent inferred from the line where selection starts.
 *   - The selected text is re-indented one extra level (4 spaces) inside
 *     the try block.
 */
fn Object* try_surround_with_try_catch(String uri, Document* doc, ParseResult* ast, Object* params) {
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	Object* end_pos = range.get("end") ?? null;
	if (start == null || end_pos == null) return null;

	uint start_line = (uint)(start.get_int("line") ?? 0);
	uint start_col = (uint)(start.get_int("character") ?? 0);
	uint end_line = (uint)(end_pos.get_int("line") ?? 0);
	uint end_col = (uint)(end_pos.get_int("character") ?? 0);

	// Empty selection → nothing to surround
	if (start_line == end_line && start_col == end_col) return null;

	long sel_start = document::position_to_byte_offset(doc.content, start_line, start_col);
	long sel_end = document::position_to_byte_offset(doc.content, end_line, end_col);
	if (sel_start < 0 || sel_end < 0 || sel_end <= sel_start) return null;

	// Require the selection to be inside a BLOCK (function/lambda body),
	// otherwise wrapping with try/catch is meaningless (e.g. at top level).
	bool inside_block = false;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != BLOCK) continue;
		if (n.start_offset <= (uint)sel_start && n.end_offset >= (uint)sel_end) {
			inside_block = true;
			break;
		}
	}
	if (!inside_block) return null;

	// Compute base indent from the start line
	String base_indent = line_leading_indent(doc.content, start_line);

	// Get selected text
	String selected = doc.content[(usz)sel_start..(usz)sel_end - 1];

	// Re-indent selected text: every line gets one extra indent level (4 spaces)
	// The first line keeps no leading indent (we'll insert it inline after `try {\n`).
	String inner_indent = string::tformat("%s    ", base_indent);
	String reindented = reindent_block(selected, inner_indent);

	DString out;
	out.tinit();
	out.appendf("try {\n%s%s\n%s} catch (e: Exception) {\n%s    TODO(\"Handle exception\")\n%s}",
		inner_indent, reindented, base_indent, base_indent, base_indent);

	Object* edit_obj = object::new_obj(tmem);
	edit_obj.set("range", range);
	edit_obj.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit_obj);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Surround with try/catch");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);

	return action;
}

/**
 * Get the leading whitespace of the given 0-indexed line.
 * Returns an empty string for missing lines or lines that start with non-whitespace.
 */
fn String line_leading_indent(String content, uint line) {
	uint cur = 0;
	usz line_start = 0;
	while (line_start < content.len && cur < line) {
		if (content[line_start] == '\n') cur++;
		line_start++;
	}
	if (cur < line) return "";
	usz ws_end = line_start;
	while (ws_end < content.len && (content[ws_end] == ' ' || content[ws_end] == '\t')) {
		ws_end++;
	}
	if (ws_end == line_start) return "";
	return content[line_start..ws_end - 1];
}

/**
 * Re-indent a multi-line block: every line *after* the first gets `prefix`
 * prepended. The first line is left alone (caller positions it).
 */
fn String reindent_block(String text, String prefix) {
	DString out;
	out.tinit();
	usz i = 0;
	bool first_line = true;
	while (i < text.len) {
		if (first_line) {
			while (i < text.len && text[i] != '\n') {
				out.append_char(text[i]);
				i++;
			}
			first_line = false;
		} else {
			out.append(prefix);
			while (i < text.len && text[i] != '\n') {
				out.append_char(text[i]);
				i++;
			}
		}
		if (i < text.len && text[i] == '\n') {
			out.append_char('\n');
			i++;
		}
	}
	return out.str_view();
}

// ── Quick fix: add missing branches to non-exhaustive enum when ───

/**
 * Build "Add missing branches" code action for a non-exhaustive enum
 * `when` diagnostic. Inserts `<EnumName>.<ENTRY> -> TODO()` arms.
 *
 * Diagnostic message format:
 *   "'when' on enum class 'X' is non-exhaustive: missing 'A', 'B', ..."
 */
fn Object* try_add_missing_enum_branches(String uri, Document* doc, ParseResult* ast,
		Object* diag, String message) {
	if (doc == null || ast == null) return null;

	// Parse range start (line/col) — locate WHEN_EXPR
	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate WHEN_EXPR with matching start position
	uint when_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != WHEN_EXPR) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			when_idx = i;
			break;
		}
	}
	if (when_idx == (uint)-1) return null;
	AstNode* when_node = &ast.nodes[when_idx];

	// Extract enum class name from message after "enum class '"
	String enum_name = "";
	String anchor = "enum class '";
	usz a_pos = 0;
	bool found_anchor = false;
	for (usz i = 0; i + anchor.len <= message.len; i++) {
		if (message[i:anchor.len] == anchor) {
			a_pos = i + anchor.len;
			found_anchor = true;
			break;
		}
	}
	if (!found_anchor) return null;
	usz e_end = a_pos;
	while (e_end < message.len && message[e_end] != '\'') e_end++;
	if (e_end == a_pos || e_end >= message.len) return null;
	enum_name = message[a_pos..e_end - 1];

	// Parse missing entry names from message after "missing "
	usz missing_pos = 0;
	bool have_missing = false;
	for (usz i = 0; i + 8 <= message.len; i++) {
		if (message[i:8] == "missing ") {
			missing_pos = i + 8;
			have_missing = true;
			break;
		}
	}
	if (!have_missing) return null;
	String[] names = parse_quoted_names(message[missing_pos..]);
	if (names.len == 0) return null;

	// Indent from first WHEN_ENTRY
	uint entry_col = when_node.start_col + 1;
	for (uint j = when_node.children_start; j < ast.node_count; j++) {
		AstNode* child = &ast.nodes[j];
		if (child.parent != when_idx) continue;
		if (child.kind == WHEN_ENTRY) {
			entry_col = child.start_col;
			break;
		}
	}
	String indent = build_indent_for_column(doc.content, entry_col);

	// Build newText: one `<Enum>.<Entry> -> TODO()\n<indent>` per missing
	DString text;
	text.tinit();
	for (usz i = 0; i < names.len; i++) {
		text.appendf("%s.%s -> TODO()\n%s", enum_name, names[i], indent);
	}

	// Insertion at `(end_line, end_col - 1)` — just before closing `}`
	int insert_line = (int)when_node.end_line;
	int insert_col = (int)when_node.end_col - 1;
	if (insert_col < 0) insert_col = 0;

	Object* pos = object::new_obj(tmem);
	pos.set("line", (int128)insert_line);
	pos.set("character", (int128)insert_col);

	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", pos);
	insert_range.set("end", pos);

	Object* edit_obj = object::new_obj(tmem);
	edit_obj.set("range", insert_range);
	edit_obj.set("newText", text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit_obj);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Add missing branches");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Refactor: add explicit return type to function ───────────────

/**
 * Cursor on `fun foo(...) = expr` or `fun foo(...) { ... }` (no
 * declared return type) → offer "Add return type" → inserts `: T`
 * between `)` and the body. Reuses
 * `inlay_hints::infer_fun_return_type` so the type matches what
 * users already see as a hint.
 *
 * Skips: functions with explicit return type, anonymous funs,
 * Unit/Nothing/UNKNOWN inferred types.
 */
fn Object* try_add_return_type(String uri, Document* doc, ParseResult* ast,
		TypeInfo* ti, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest FUN_DECL containing cursor
	uint fun_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if ((uint)cursor_offset < n.start_offset) continue;
		if ((uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			fun_idx = i;
		}
	}
	if (fun_idx == uint.max) return null;

	AstNode* fun_node = &ast.nodes[fun_idx];

	// Skip if return type already present
	if (fun_node.type_text.len > 0) return null;

	// Skip anonymous funs
	if (fun_node.name.len == 0) return null;

	// Infer return type from body
	String return_type = "";
	if (try rt = inlay_hints::infer_fun_return_type(ast, ti, fun_idx, doc.content)) {
		return_type = rt;
	} else {
		return null;
	}

	// Reject useless types
	if (return_type.len == 0) return null;
	if (return_type == "Unit" || return_type == "Nothing") return null;
	if (return_type.contains("UNKNOWN") || return_type == "?") return null;

	// Find position: just after closing ')' of param list
	uint hint_line;
	uint hint_col;
	if (try pos = inlay_hints::find_fun_paren_close(doc.content, fun_node)) {
		hint_line = pos.line;
		hint_col = pos.col + 1;
	} else {
		return null;
	}

	DString new_text;
	new_text.tinit();
	new_text.appendf(": %s", return_type);

	Object* insert_pos = object::new_obj(tmem);
	insert_pos.set("line", (int)hint_line);
	insert_pos.set("character", (int)hint_col);
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_pos);
	insert_range.set("end", insert_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", new_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Add return type");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ── Refactor: convert expression body to block body ──────────────

/**
 * Cursor on `fun foo(...): T = expr` → offer "Convert to block body"
 * → rewrites to `fun foo(...): T { return expr }`. Inverse of
 * `try_convert_fun_to_expression_body`.
 *
 * If function returns Unit (declared or inferred), omits `return`
 * and uses `{ expr }`.
 *
 * Skips: functions with block body (has BLOCK child), no expression
 * body found, anonymous funs.
 */
fn Object* try_convert_expression_body_to_block(String uri, Document* doc, ParseResult* ast,
		TypeInfo* ti, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest FUN_DECL containing cursor
	uint fun_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if ((uint)cursor_offset < n.start_offset) continue;
		if ((uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			fun_idx = i;
		}
	}
	if (fun_idx == uint.max) return null;

	AstNode* fun_node = &ast.nodes[fun_idx];

	// Skip anonymous funs
	if (fun_node.name.len == 0) return null;

	// Detect: must have an expression child (NOT a BLOCK) representing the body.
	// If a BLOCK child exists, it's already a block body — no action.
	uint expr_idx = uint.max;
	for (uint j = 1; j < ast.node_count; j++) {
		AstNode* child = &ast.nodes[j];
		if (child.parent != fun_idx) continue;
		if (child.kind == BLOCK) return null; // already block body
		if (child.kind == TYPE_REF || child.kind == TYPE_PARAM || child.kind == PARAM) continue;
		if (ast::is_expression(child.kind)) {
			expr_idx = j;
		}
	}
	if (expr_idx == uint.max) return null;

	AstNode* expr_node = &ast.nodes[expr_idx];

	// Determine return type — to decide whether to emit `return`.
	bool returns_unit = false;
	if (fun_node.type_text.len > 0) {
		if (fun_node.type_text == "Unit") returns_unit = true;
	} else {
		// No declared type — infer from expr
		if (try rt = inlay_hints::infer_fun_return_type(ast, ti, fun_idx, doc.content)) {
			if (rt == "Unit") returns_unit = true;
		}
	}

	// Extract expression text
	usz expr_start = (usz)expr_node.start_offset;
	usz expr_end = (usz)expr_node.end_offset;
	if (expr_start >= expr_end || expr_end > doc.content.len) return null;
	String expr_text = doc.content[expr_start..expr_end - 1];
	if (expr_text.len == 0) return null;

	// Find `=` token preceding the expression by scanning backwards
	// from expr_start through doc.content. Skip whitespace.
	if (expr_start == 0) return null;
	usz scan = expr_start;
	while (scan > 0) {
		scan--;
		char c = doc.content[scan];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
		if (c == '=') break;
		return null; // unexpected token before expr
	}
	if (doc.content[scan] != '=') return null;

	// Compute line/col of `=` for replace range start
	uint eq_line;
	uint eq_col;
	{
		uint l = 0;
		uint c = 0;
		for (usz i = 0; i < scan; i++) {
			if (doc.content[i] == '\n') {
				l++;
				c = 0;
			} else {
				c++;
			}
		}
		eq_line = l;
		eq_col = c;
	}

	// Build replacement text
	DString new_text;
	new_text.tinit();
	if (returns_unit) {
		new_text.appendf("{ %s }", expr_text);
	} else {
		new_text.appendf("{ return %s }", expr_text);
	}

	Object* replace_start_pos = object::new_obj(tmem);
	replace_start_pos.set("line", (int)eq_line);
	replace_start_pos.set("character", (int)eq_col);
	Object* replace_end_pos = object::new_obj(tmem);
	replace_end_pos.set("line", (int)expr_node.end_line);
	replace_end_pos.set("character", (int)expr_node.end_col);
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
	action.set("title", "Convert to block body");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ── Quick fix: change `var` to `val` ─────────────────────────────

/**
 * For a "Variable 'x' can be 'val'" diagnostic, build a quick-fix
 * that replaces the `var` keyword in the corresponding PROPERTY_DECL
 * with `val`.
 *
 * Locates the property by line/character of the diagnostic range start
 * (which we set to the property's start position in
 * `add_var_can_be_val_diagnostics`). Scans the property's source slice
 * for the literal `var ` token to locate the keyword precisely
 * (handles property declarations preceded by modifiers/annotations).
 */
fn Object* try_change_var_to_val(String uri, Document* doc, ParseResult* ast, Object* diag) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	int line;
	int col;
	if (try sl = start.get_int("line")) { line = sl; } else { return null; }
	if (try sc = start.get_int("character")) { col = sc; } else { return null; }

	// Find PROPERTY_DECL whose name_line/start matches
	uint prop_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != PROPERTY_DECL) continue;
		if ((int)n.start_line == line && (int)n.start_col == col) {
			prop_idx = i;
			break;
		}
	}
	if (prop_idx == uint.max) return null;

	AstNode* prop = &ast.nodes[prop_idx];

	// Locate the `var` keyword inside the property's source slice.
	usz scan = (usz)prop.start_offset;
	usz end = (usz)prop.end_offset;
	if (end > doc.content.len) end = doc.content.len;

	usz var_off = usz.max;
	while (scan + 3 <= end) {
		// Word-boundary check: prev char is not ident-like and next char is whitespace
		bool prev_ok = (scan == 0)
			|| !is_ident_char(doc.content[scan - 1]);
		bool match = doc.content[scan] == 'v' && doc.content[scan + 1] == 'a'
			&& doc.content[scan + 2] == 'r';
		bool next_ok = (scan + 3 < end)
			&& !is_ident_char(doc.content[scan + 3]);
		if (prev_ok && match && next_ok) {
			var_off = scan;
			break;
		}
		scan++;
	}
	if (var_off == usz.max) return null;

	// Compute line/col of `var`
	uint kw_line = 0;
	uint kw_col = 0;
	for (usz i = 0; i < var_off; i++) {
		if (doc.content[i] == '\n') { kw_line++; kw_col = 0; }
		else { kw_col++; }
	}

	Object* replace_start = object::new_obj(tmem);
	replace_start.set("line", (int)kw_line);
	replace_start.set("character", (int)kw_col);
	Object* replace_end = object::new_obj(tmem);
	replace_end.set("line", (int)kw_line);
	replace_end.set("character", (int)(kw_col + 3));
	Object* replace_range = object::new_obj(tmem);
	replace_range.set("start", replace_start);
	replace_range.set("end", replace_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", replace_range);
	edit.set("newText", "val");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Change 'var' to 'val'");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

fn bool is_ident_char(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		|| (c >= '0' && c <= '9') || c == '_';
}

// ── Quick fix: remove unnecessary `!!` ───────────────────────────

/**
 * For an "Unnecessary '!!'" diagnostic, build a quick-fix that deletes
 * the `!!` operator. The diagnostic range was set to cover exactly the
 * 2-char `!!`, so the fix is a simple range replacement with empty text.
 */
fn Object* try_remove_not_null_assertion(String uri, Document* doc, Object* diag) {
	if (doc == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	Object* end = range.get("end") ?? null;
	if (start == null || end == null) return null;

	// Reuse the diagnostic range as the edit range
	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", "");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove '!!'");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: simplify redundant if-bool ──────────────────────
//
// For `if (cond) true else false` → replace IF_EXPR with cond text.
// For `if (cond) false else true` → replace with `!(cond)` or `!cond`
// (parens added when cond is a compound expression).
fn Object* try_simplify_redundant_if_bool(String uri, Document* doc, ParseResult* ast,
		Object* diag, String message) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate IF_EXPR matching diag start position
	uint if_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IF_EXPR) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			if_idx = i;
			break;
		}
	}
	if (if_idx == (uint)-1) return null;
	AstNode* if_node = &ast.nodes[if_idx];

	// Find cond child: first NON-block child whose kind is an expression.
	// IF_EXPR layout: [cond?, then, else]. Cond may be missing if parser
	// fell back; in that case give up (can't synthesize from source — would
	// need to parse the parenthesized region).
	uint cond_idx = (uint)-1;
	uint child_count = 0;
	for (uint c = if_node.children_start; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != if_idx) continue;
		child_count++;
	}
	if (child_count < 3) return null; // need cond + then + else

	uint first_child = (uint)-1;
	for (uint c = if_node.children_start; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != if_idx) continue;
		first_child = c;
		break;
	}
	if (first_child == (uint)-1) return null;
	cond_idx = first_child;

	AstNode* cond = &ast.nodes[cond_idx];
	String content = doc.content;
	if (cond.start_offset >= content.len || cond.end_offset > content.len) return null;
	if (cond.end_offset <= cond.start_offset) return null;
	String cond_text = content[cond.start_offset:cond.end_offset - cond.start_offset];

	bool negated = message.contains("negated");
	DString new_text;
	new_text.tinit();
	if (negated) {
		// Wrap in parens unless cond is a simple atom
		if (needs_parens_for_negation(cond.kind)) {
			new_text.appendf("!(%s)", cond_text);
		} else {
			new_text.appendf("!%s", cond_text);
		}
	} else {
		new_text.append(cond_text);
	}

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", new_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", negated ? "Replace with negated condition" : "Replace with condition");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

fn bool needs_parens_for_negation(NodeKind k) {
	switch (k) {
		case NAME_EXPR:
		case CALL_EXPR:
		case DOT_EXPR:
		case LITERAL_EXPR:
		case THIS_EXPR:
		case SUPER_EXPR:
		case PAREN_EXPR:
			return false;
		default:
			return true;
	}
}

// ── Refactor: extract variable (replace all occurrences) ──────
//
// Companion to try_extract_variable. When the selected expression has
// 2+ identical occurrences (by exact source text) inside the enclosing
// function/lambda/init scope, offers a separate action that replaces
// ALL of them with the new variable.
//
// Returns null if:
// - Selection doesn't match a single expression node
// - That expression is a NAME_EXPR (already a reference)
// - Only one occurrence exists in the enclosing scope
fn Object* try_extract_variable_all_occurrences(String uri, Document* doc, ParseResult* ast, Object* params) {
	Object* range = params.get("range") ?? null;
	if (range == null) return null;

	Object* start = range.get("start") ?? null;
	Object* end_pos = range.get("end") ?? null;
	if (start == null || end_pos == null) return null;

	uint start_line = (uint)(start.get_int("line") ?? 0);
	uint start_col = (uint)(start.get_int("character") ?? 0);
	uint end_line = (uint)(end_pos.get_int("line") ?? 0);
	uint end_col = (uint)(end_pos.get_int("character") ?? 0);

	if (start_line == end_line && start_col == end_col) return null;

	long sel_start = document::position_to_byte_offset(doc.content, start_line, start_col);
	long sel_end = document::position_to_byte_offset(doc.content, end_line, end_col);
	if (sel_start < 0 || sel_end < 0 || sel_end <= sel_start) return null;

	// Find selected expression
	uint best_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (!ast::is_expression(n.kind)) continue;
		if (n.start_offset == (uint)sel_start && n.end_offset == (uint)sel_end) {
			best_idx = i;
		}
	}
	if (best_idx == uint.max) return null;

	AstNode* expr = &ast.nodes[best_idx];
	if (expr.kind == NAME_EXPR) return null;

	String expr_text = doc.content[(usz)expr.start_offset..(usz)expr.end_offset - 1];

	// Find enclosing scope: walk parents until FUN_DECL / LAMBDA_EXPR /
	// INIT_BLOCK / CONSTRUCTOR_DECL / FILE / ANONYMOUS_FUN_EXPR
	uint scope_idx = best_idx;
	while (scope_idx != 0) {
		AstNode* sn = &ast.nodes[scope_idx];
		if (sn.kind == FUN_DECL || sn.kind == LAMBDA_EXPR || sn.kind == INIT_BLOCK
			|| sn.kind == CONSTRUCTOR_DECL || sn.kind == ANONYMOUS_FUN_EXPR
			|| sn.kind == FILE) {
			break;
		}
		uint p = sn.parent;
		if (p == ast::NO_PARENT) break;
		scope_idx = p;
	}
	AstNode* scope = &ast.nodes[scope_idx];
	uint scope_start = scope.start_offset;
	uint scope_end = scope.end_offset;

	// Collect all expression nodes inside scope whose source text matches
	uint[64] match_indices;
	uint match_count = 0;
	for (uint i = 1; i < ast.node_count && match_count < 64; i++) {
		AstNode* n = &ast.nodes[i];
		if (!ast::is_expression(n.kind)) continue;
		if (n.start_offset < scope_start || n.end_offset > scope_end) continue;
		uint len = n.end_offset - n.start_offset;
		if (len != expr_text.len) continue;
		String node_text = doc.content[(usz)n.start_offset..(usz)n.end_offset - 1];
		if (node_text != expr_text) continue;
		match_indices[match_count++] = i;
	}

	if (match_count < 2) return null;

	// First match (smallest start_offset) — for statement-level insert
	uint first_idx = match_indices[0];
	for (uint k = 1; k < match_count; k++) {
		if (ast.nodes[match_indices[k]].start_offset < ast.nodes[first_idx].start_offset) {
			first_idx = match_indices[k];
		}
	}

	// Walk to containing statement of first occurrence
	uint stmt_idx = first_idx;
	while (stmt_idx != 0 && ast.nodes[stmt_idx].parent != ast::NO_PARENT) {
		uint parent_idx = ast.nodes[stmt_idx].parent;
		AstNode* parent = &ast.nodes[parent_idx];
		if (parent.kind == BLOCK || parent.kind == FILE) break;
		stmt_idx = parent_idx;
	}
	AstNode* stmt = &ast.nodes[stmt_idx];

	// Compute indent
	String indent = "";
	if (stmt.start_col > 0) {
		usz line_start = (usz)stmt.start_offset;
		while (line_start > 0 && doc.content[line_start - 1] != '\n') line_start--;
		usz ws_end = line_start;
		while (ws_end < doc.content.len && (doc.content[ws_end] == ' ' || doc.content[ws_end] == '\t')) ws_end++;
		if (ws_end > line_start) indent = doc.content[line_start..ws_end - 1];
	}

	DString insert_text;
	insert_text.tinit();
	insert_text.appendf("val extractedVar = %s\n%s", expr_text, indent);

	Object* edits = object::new_obj(tmem);

	// Edit 1: insert
	Object* insert_start_pos = object::new_obj(tmem);
	insert_start_pos.set("line", (int)stmt.start_line);
	insert_start_pos.set("character", (int)stmt.start_col);
	Object* insert_end_pos = object::new_obj(tmem);
	insert_end_pos.set("line", (int)stmt.start_line);
	insert_end_pos.set("character", (int)stmt.start_col);
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", insert_start_pos);
	insert_range.set("end", insert_end_pos);
	Object* edit1 = object::new_obj(tmem);
	edit1.set("range", insert_range);
	edit1.set("newText", insert_text.str_view());
	edits.push(edit1);

	// Edits 2..N: replace each occurrence
	for (uint k = 0; k < match_count; k++) {
		AstNode* m = &ast.nodes[match_indices[k]];
		Object* rs = object::new_obj(tmem);
		rs.set("line", (int)m.start_line);
		rs.set("character", (int)m.start_col);
		Object* re = object::new_obj(tmem);
		re.set("line", (int)m.end_line);
		re.set("character", (int)m.end_col);
		Object* rr = object::new_obj(tmem);
		rr.set("start", rs);
		rr.set("end", re);
		Object* e = object::new_obj(tmem);
		e.set("range", rr);
		e.set("newText", "extractedVar");
		edits.push(e);
	}

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	DString title;
	title.tinit();
	title.appendf("Extract variable (replace %d occurrences)", (int)match_count);

	Object* action = object::new_obj(tmem);
	action.set("title", title.str_view());
	action.set("kind", "refactor.extract.variable");
	action.set("edit", workspace_edit);

	return action;
}

// ── Refactor: convert string concatenation to template ────────
//
// `"a" + x + "b"` → `"a${x}b"`
//
// Detection: cursor inside a `+` BINARY_EXPR. Walk up while parent is
// also `+` BINARY_EXPR (find topmost concat chain). Flatten chain into
// operands. Require ≥1 STRING_TEMPLATE_EXPR operand (regular string).
// Skip multi-line strings (different quoting).
fn Object* try_convert_concat_to_template(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cur_line = (uint)(start.get_int("line") ?? 0);
	uint cur_col = (uint)(start.get_int("character") ?? 0);
	long cur_off_l = document::position_to_byte_offset(doc.content, cur_line, cur_col);
	if (cur_off_l < 0) return null;
	uint cur_off = (uint)cur_off_l;

	// Find smallest BINARY_EXPR("+") containing cursor
	uint best_idx = uint.max;
	uint best_size = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != BINARY_EXPR) continue;
		if (n.extra_text != "+") continue;
		if (cur_off < n.start_offset || cur_off > n.end_offset) continue;
		uint size = n.end_offset - n.start_offset;
		if (size < best_size) {
			best_size = size;
			best_idx = i;
		}
	}
	if (best_idx == uint.max) return null;

	// Walk up while parent is also `+` BINARY_EXPR
	uint top_idx = best_idx;
	while (true) {
		uint p = ast.nodes[top_idx].parent;
		if (p == ast::NO_PARENT) break;
		AstNode* parent = &ast.nodes[p];
		if (parent.kind != BINARY_EXPR || parent.extra_text != "+") break;
		top_idx = p;
	}

	// Flatten the concat chain into operands
	uint[32] operands;
	uint op_count = 0;
	flatten_concat(ast, top_idx, operands[..], &op_count);
	if (op_count < 2) return null;

	// Require ≥1 STRING_TEMPLATE_EXPR operand (regular, not multi-line)
	bool has_string = false;
	for (uint k = 0; k < op_count; k++) {
		AstNode* op = &ast.nodes[operands[k]];
		if (op.kind == STRING_TEMPLATE_EXPR) {
			// Skip multi-line strings (start with """)
			if (op.start_offset + 3 <= doc.content.len) {
				String prefix = doc.content[(usz)op.start_offset:3];
				if (prefix == `"""`) return null;
			}
			has_string = true;
		}
	}
	if (!has_string) return null;

	// Build template
	DString out;
	out.tinit();
	out.append_char('"');
	for (uint k = 0; k < op_count; k++) {
		AstNode* op = &ast.nodes[operands[k]];
		if (op.kind == STRING_TEMPLATE_EXPR) {
			// Strip surrounding quotes
			if (op.end_offset <= op.start_offset + 1) continue;
			usz s = (usz)op.start_offset + 1;
			usz e = (usz)op.end_offset - 1;
			if (e > s) out.append(doc.content[s..e - 1]);
		} else if (op.kind == NAME_EXPR) {
			// If the next operand is a STRING_TEMPLATE_EXPR whose first
			// content char is an identifier-continuation char (alnum / _),
			// the bare `$name` form would absorb it. Use `${name}` to be safe.
			bool need_braces = false;
			if (k + 1 < op_count) {
				AstNode* next = &ast.nodes[operands[k + 1]];
				if (next.kind == STRING_TEMPLATE_EXPR && next.end_offset > next.start_offset + 1) {
					usz s = (usz)next.start_offset + 1;
					if (s < doc.content.len) {
						char ch = doc.content[s];
						if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
							|| (ch >= '0' && ch <= '9') || ch == '_') {
							need_braces = true;
						}
					}
				}
			}
			if (need_braces) {
				out.append("${");
				out.append(doc.content[(usz)op.start_offset..(usz)op.end_offset - 1]);
				out.append_char('}');
			} else {
				out.append_char('$');
				out.append(doc.content[(usz)op.start_offset..(usz)op.end_offset - 1]);
			}
		} else {
			out.append("${");
			out.append(doc.content[(usz)op.start_offset..(usz)op.end_offset - 1]);
			out.append_char('}');
		}
	}
	out.append_char('"');

	AstNode* top = &ast.nodes[top_idx];
	Object* edit_range = object::new_obj(tmem);
	Object* es = object::new_obj(tmem);
	es.set("line", (int)top.start_line);
	es.set("character", (int)top.start_col);
	Object* ee = object::new_obj(tmem);
	ee.set("line", (int)top.end_line);
	ee.set("character", (int)top.end_col);
	edit_range.set("start", es);
	edit_range.set("end", ee);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Convert concatenation to template");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);

	return action;
}

// Recursively flatten a `+` chain. If a node is a `+` BINARY_EXPR, descend
// into both children (left then right). Otherwise add as operand.
fn void flatten_concat(ParseResult* ast, uint idx, uint[] out, uint* count) {
	AstNode* n = &ast.nodes[idx];
	if (n.kind == BINARY_EXPR && n.extra_text == "+") {
		// Children in source order
		uint[2] kids;
		uint k = 0;
		for (uint c = n.children_start; c < ast.node_count && k < 2; c++) {
			if (ast.nodes[c].parent != idx) continue;
			kids[k++] = c;
		}
		for (uint i = 0; i < k; i++) {
			flatten_concat(ast, kids[i], out, count);
		}
		return;
	}
	if (*count < out.len) {
		out[*count] = idx;
		(*count)++;
	}
}

// ── Quickfix: remove redundant elvis (?:) ───────────────────────
//
// For `lhs ?: rhs` flagged as redundant, replace the whole BINARY_EXPR
// with the LHS source text.
fn Object* try_remove_redundant_elvis(String uri, Document* doc, ParseResult* ast, Object* diag) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate elvis BINARY_EXPR matching diag start position
	uint elvis_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != BINARY_EXPR) continue;
		if (n.extra_text != "?:") continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			elvis_idx = i;
			break;
		}
	}
	if (elvis_idx == (uint)-1) return null;
	AstNode* elvis = &ast.nodes[elvis_idx];

	// Find LHS (first child)
	uint lhs_idx = (uint)-1;
	for (uint c = elvis.children_start; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != elvis_idx) continue;
		lhs_idx = c;
		break;
	}
	if (lhs_idx == (uint)-1) return null;
	AstNode* lhs = &ast.nodes[lhs_idx];

	if (lhs.start_offset >= lhs.end_offset) return null;
	if (lhs.end_offset > doc.content.len) return null;

	String lhs_text = doc.content[lhs.start_offset:lhs.end_offset - lhs.start_offset];

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", lhs_text);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove redundant '?:'");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: remove redundant override ────────────────────────
//
// For "Override is redundant" diagnostic, replace the entire FUN_DECL
// (plus trailing newline if present) with empty text.
fn Object* try_remove_redundant_override(String uri, Document* doc, ParseResult* ast, Object* diag) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate FUN_DECL matching diag start
	uint fun_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			fun_idx = i;
			break;
		}
	}
	if (fun_idx == (uint)-1) return null;

	AstNode* fun_node = &ast.nodes[fun_idx];

	// Compute removal range: from start_line:start_col through end_line:end_col,
	// extended to consume one trailing newline if next char is \n.
	int end_line = (int)fun_node.end_line;
	int end_col = (int)fun_node.end_col;

	// Try to consume trailing newline
	if (fun_node.end_offset < doc.content.len && doc.content[fun_node.end_offset] == '\n') {
		end_line++;
		end_col = 0;
	}

	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)fun_node.start_line);
	edit_start.set("character", (int)fun_node.start_col);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", end_line);
	edit_end.set("character", end_col);
	Object* edit_range = object::new_obj(tmem);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", "");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove redundant override");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Refactor: convert to scope function (let/run/apply/also) ────
//
// When the cursor is on an expression, offer 4 actions to wrap it
// in a Kotlin scope function. The expression becomes the receiver;
// the body is a placeholder so the user can fill it in.
//
//   let   → expr.let { it }
//   run   → expr.run { this }
//   apply → expr.apply { }
//   also  → expr.also { it }
//
// Skipped when the expression is the receiver of an enclosing DOT_EXPR
// (would break the chain). User can wrap at the DOT_EXPR level instead.

/**
 * Find the smallest "wrappable" expression containing the given byte
 * offset. Returns NO_PARENT if none.
 */
fn uint find_wrappable_expr_at(ParseResult* ast, long offset) {
	uint best_idx = ast::NO_PARENT;
	uint best_size = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		bool eligible = false;
		switch (n.kind) {
			case NAME_EXPR:
			case DOT_EXPR:
			case CALL_EXPR:
			case LITERAL_EXPR:
			case STRING_TEMPLATE_EXPR:
			case PAREN_EXPR:
			case BINARY_EXPR:
			case POSTFIX_EXPR:
			case PREFIX_EXPR:
			case THIS_EXPR:
			case SUPER_EXPR:
				eligible = true;
				break;
			default:
				break;
		}
		if (!eligible) continue;
		if ((long)n.start_offset > offset) continue;
		if ((long)n.end_offset < offset) continue;
		uint size = n.end_offset - n.start_offset;
		if (size < best_size) {
			best_size = size;
			best_idx = i;
		}
	}
	return best_idx;
}

/**
 * Build a single scope-function action.
 */
fn Object* build_scope_function_action(String uri, String expr_text, String fn_name,
		String body_placeholder, AstNode* expr_node) {
	String new_text;
	if (body_placeholder.len == 0) {
		new_text = string::tformat("%s.%s {  }", expr_text, fn_name);
	} else {
		new_text = string::tformat("%s.%s { %s }", expr_text, fn_name, body_placeholder);
	}

	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)expr_node.start_line);
	edit_start.set("character", (int)expr_node.start_col);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", (int)expr_node.end_line);
	edit_end.set("character", (int)expr_node.end_col);
	Object* edit_range = object::new_obj(tmem);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit_obj = object::new_obj(tmem);
	edit_obj.set("range", edit_range);
	edit_obj.set("newText", new_text);

	Object* edits = object::new_obj(tmem);
	edits.push(edit_obj);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);

	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	String title = string::tformat("Wrap in '%s'", fn_name);
	action.set("title", title);
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);

	return action;
}

fn void add_scope_function_actions(Object* actions, String uri, Document* doc,
		ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return;

	Object* range = params.get("range") ?? null;
	if (range == null) return;
	Object* start = range.get("start") ?? null;
	if (start == null) return;
	int cursor_line;
	int cursor_col;
	if (try v = start.get_int("line")) { cursor_line = v; } else { return; }
	if (try v = start.get_int("character")) { cursor_col = v; } else { return; }

	long cursor_offset = document::position_to_byte_offset(doc.content, (uint)cursor_line, (uint)cursor_col);
	if (cursor_offset < 0) return;

	uint expr_idx = find_wrappable_expr_at(ast, cursor_offset);
	if (expr_idx == ast::NO_PARENT) return;

	AstNode* expr = &ast.nodes[expr_idx];

	// Skip if the expression is the receiver of an enclosing DOT_EXPR
	// (would break member access chains). The receiver is the first
	// child of DOT_EXPR by parent link. Detect by walking up.
	if (expr.parent < ast.node_count) {
		AstNode* parent = &ast.nodes[expr.parent];
		if (parent.kind == DOT_EXPR) {
			// Find first child of parent
			for (uint c = 0; c < ast.node_count; c++) {
				if (ast.nodes[c].parent != expr.parent) continue;
				if (c == expr_idx) return; // expr is the receiver — skip
				break;
			}
		}
	}

	if (expr.start_offset >= expr.end_offset) return;
	if (expr.end_offset > doc.content.len) return;

	String expr_text = doc.content[expr.start_offset:expr.end_offset - expr.start_offset];

	actions.push(build_scope_function_action(uri, expr_text, "let", "it", expr));
	actions.push(build_scope_function_action(uri, expr_text, "run", "this", expr));
	actions.push(build_scope_function_action(uri, expr_text, "apply", "", expr));
	actions.push(build_scope_function_action(uri, expr_text, "also", "it", expr));
}

// ── Refactor: split declaration and assignment ──────────────────

/**
 * Cursor on `var x: T = expr` (local) → offer
 * "Split declaration and assignment" → rewrites to
 *
 *     var x: T
 *     x = expr
 *
 * Only offered for `var` (since `val x: T` would be uncompilable).
 * Requires explicit type annotation. Skips destructuring,
 * properties with custom accessors, `by` delegation, and non-local
 * properties (top-level / class members).
 */
fn Object* try_split_declaration_assignment(String uri, Document* doc,
		ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;

	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest PROPERTY_DECL containing cursor.
	uint prop_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != PROPERTY_DECL) continue;
		if ((uint)cursor_offset < n.start_offset) continue;
		if ((uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			prop_idx = i;
		}
	}
	if (prop_idx == uint.max) return null;

	AstNode* prop = &ast.nodes[prop_idx];

	// Must be `var` (val x: T would be uncompilable after split).
	if ((prop.mod_flags & ast::MOD_VAR) == 0) return null;

	// Must have explicit type annotation.
	if (prop.type_text.len == 0) return null;

	// Skip destructuring / no-name.
	if (prop.name.len == 0 || prop.name == "(destructuring)") return null;

	// Must be local (parent is BLOCK).
	if (prop.parent >= ast.node_count) return null;
	if (ast.nodes[prop.parent].kind != BLOCK) return null;

	// Walk children (iterate from 0 — initializer expr may have lower
	// index in some shapes, but typically higher; safe either way).
	// Find: the lone non-FUN_DECL non-PARAM child = initializer expr.
	// Reject if any FUN_DECL child (custom accessor) found.
	uint init_idx = uint.max;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != prop_idx) continue;
		NodeKind ck = ast.nodes[c].kind;
		if (ck == FUN_DECL) return null; // custom get/set accessor
		if (ck == PARAM || ck == TYPE_PARAM) continue;
		// First non-decl child is initializer (or `by` delegate root).
		if (init_idx == uint.max) {
			init_idx = c;
		}
	}
	if (init_idx == uint.max) return null; // no initializer

	AstNode* init = &ast.nodes[init_idx];

	// Skip `by` delegation.
	if (init.extra_text == "delegate") return null;

	// Compute indentation of the property's start line.
	String content = doc.content;
	uint line_start = prop.start_offset;
	while (line_start > 0 && content[line_start - 1] != '\n') {
		line_start--;
	}
	uint indent_end = line_start;
	while (indent_end < prop.start_offset
		&& (content[indent_end] == ' ' || content[indent_end] == '\t')) {
		indent_end++;
	}
	String indent = content[line_start:indent_end - line_start];

	// Locate the type annotation end. The PROPERTY_DECL's range covers
	// `var x: T = expr`. We want to replace from end of type to end of
	// initializer with newline + indent + name = expr.
	// Find type_text end: search for type_text starting after `:`.
	// Simpler: find the `=` token between cursor and init.start_offset.
	uint scan = prop.start_offset;
	uint eq_offset = uint.max;
	while (scan < init.start_offset) {
		if (content[scan] == '=' && (scan + 1 >= content.len || content[scan + 1] != '=')) {
			eq_offset = scan;
			break;
		}
		scan++;
	}
	if (eq_offset == uint.max) return null;

	// Trim trailing whitespace from before `=` (so we don't leave
	// `var x: Int ` with trailing space). Find first non-WS char before `=`.
	uint pre_eq_end = eq_offset;
	while (pre_eq_end > prop.start_offset
		&& (content[pre_eq_end - 1] == ' ' || content[pre_eq_end - 1] == '\t')) {
		pre_eq_end--;
	}

	uint init_end = init.end_offset;
	if (init_end > content.len) init_end = (uint)content.len;
	if (pre_eq_end >= init_end) return null;

	String init_text = content[init.start_offset:init_end - init.start_offset];

	// Build replacement: newline + indent + name + " = " + init.
	// Range: from end of trimmed-WS-before-`=` up to end of init.
	DString new_text;
	new_text.tinit();
	new_text.appendf("\n%s%s = %s", indent, prop.name, init_text);

	// Compute line/col for pre_eq_end (same line as `=`, so use `=` line
	// from scan; col = pre_eq_end - line_start_of_eq).
	uint eq_line_start = eq_offset;
	while (eq_line_start > 0 && content[eq_line_start - 1] != '\n') {
		eq_line_start--;
	}
	// Count newlines from 0 to eq_line_start to get line number.
	uint start_line2 = 0;
	for (uint i = 0; i < eq_line_start; i++) {
		if (content[i] == '\n') start_line2++;
	}
	uint start_col2 = pre_eq_end - eq_line_start;

	// init.end_line/end_col already computed by parser.
	uint end_line2 = init.end_line;
	uint end_col2 = init.end_col;

	Object* start_pos = object::new_obj(tmem);
	start_pos.set("line", (int)start_line2);
	start_pos.set("character", (int)start_col2);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)end_line2);
	end_pos.set("character", (int)end_col2);
	Object* edit_range = object::new_obj(tmem);
	edit_range.set("start", start_pos);
	edit_range.set("end", end_pos);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", new_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Split declaration and assignment");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ── Quickfix: remove redundant else arm ──────────────────────────

/**
 * For a "'else' is redundant" diagnostic emitted by
 * add_redundant_else_when_diagnostics, locate the WHEN_ENTRY whose
 * `extra_text == "else"` and start position matches the diagnostic
 * range start, then return a quickfix that deletes the entire arm
 * (including the line it occupies and one trailing newline).
 */
fn Object* try_remove_redundant_else_arm(String uri, Document* doc,
		ParseResult* ast, Object* diag) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate WHEN_ENTRY with extra_text == "else" matching diag start.
	uint else_idx = uint.max;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != WHEN_ENTRY) continue;
		if (n.extra_text != "else") continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			else_idx = i;
			break;
		}
	}
	if (else_idx == uint.max) return null;

	AstNode* else_arm = &ast.nodes[else_idx];
	String content = doc.content;

	// Compute removal range:
	// Start: beginning of the line containing the else arm.
	// End: end of the arm + one trailing newline if present.
	uint del_start = else_arm.start_offset;
	while (del_start > 0 && content[del_start - 1] != '\n') {
		del_start--;
	}
	uint del_end = else_arm.end_offset;
	if (del_end < content.len && content[del_end] == '\n') {
		del_end++;
	}
	if (del_start >= del_end) return null;

	// Convert offsets back to LSP positions.
	uint start_line2 = 0;
	for (uint k = 0; k < del_start; k++) {
		if (content[k] == '\n') start_line2++;
	}
	uint start_col2 = 0;
	uint end_line2 = start_line2;
	uint end_col2 = 0;
	for (uint k = del_start; k < del_end; k++) {
		if (content[k] == '\n') {
			end_line2++;
			end_col2 = 0;
		} else {
			end_col2++;
		}
	}

	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)start_line2);
	edit_start.set("character", (int)start_col2);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", (int)end_line2);
	edit_end.set("character", (int)end_col2);
	Object* edit_range = object::new_obj(tmem);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", "");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove redundant else");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: simplify redundant boolean literal comparison ─────
//
// Pairs with diagnostic `redundant_bool_comparison_diagnostic`.
// Rewrites BINARY_EXPR of form `b == true|false` / `b != true|false`
// (literal on either side) to `b` or `!b`. Negation case wraps the
// expression in `!(...)` when the operand is a complex expression
// (binary op, prefix, etc.) — atoms (NAME_EXPR, CALL_EXPR, DOT_EXPR,
// PAREN_EXPR, THIS_EXPR, SUPER_EXPR, LITERAL_EXPR) get a bare `!`.
fn Object* try_simplify_redundant_bool_cmp(String uri, Document* doc, ParseResult* ast,
		Object* diag, String message) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate BINARY_EXPR matching diag start position
	uint bin_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != BINARY_EXPR) continue;
		if (n.extra_text != "==" && n.extra_text != "!=") continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			bin_idx = i;
			break;
		}
	}
	if (bin_idx == (uint)-1) return null;
	AstNode* bin = &ast.nodes[bin_idx];

	// Collect 2 children (BINARY_EXPR may have lower-indexed left).
	uint[4] children;
	uint child_count = 0;
	for (uint c = 0; c < ast.node_count && child_count < 4; c++) {
		if (ast.nodes[c].parent != bin_idx) continue;
		children[child_count++] = c;
	}
	if (child_count != 2) return null;

	uint lhs = children[0];
	uint rhs = children[1];
	AstNode* l = &ast.nodes[lhs];
	AstNode* r = &ast.nodes[rhs];

	bool l_is_bool_lit = (l.kind == LITERAL_EXPR
		&& (l.extra_text == "true" || l.extra_text == "false"));
	bool r_is_bool_lit = (r.kind == LITERAL_EXPR
		&& (r.extra_text == "true" || r.extra_text == "false"));
	if (l_is_bool_lit == r_is_bool_lit) return null; // need exactly one literal side

	uint expr_idx = l_is_bool_lit ? rhs : lhs;
	String lit = l_is_bool_lit ? l.extra_text : r.extra_text;
	bool is_eq = (bin.extra_text == "==");
	// `b` if (== true) or (!= false); `!b` otherwise.
	bool keep_direct = (is_eq && lit == "true") || (!is_eq && lit == "false");

	AstNode* expr = &ast.nodes[expr_idx];
	String content = doc.content;
	if (expr.start_offset >= content.len || expr.end_offset > content.len) return null;
	if (expr.end_offset <= expr.start_offset) return null;
	String expr_text = content[expr.start_offset:expr.end_offset - expr.start_offset];

	DString new_text;
	new_text.tinit();
	if (keep_direct) {
		new_text.append(expr_text);
	} else {
		if (needs_parens_for_negation(expr.kind)) {
			new_text.appendf("!(%s)", expr_text);
		} else {
			new_text.appendf("!%s", expr_text);
		}
	}

	// Build replacement range spanning full BINARY_EXPR.
	Object* edit_range = object::new_obj(tmem);
	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)bin.start_line);
	edit_start.set("character", (int)bin.start_col);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", (int)bin.end_line);
	edit_end.set("character", (int)bin.end_col);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", new_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Simplify boolean comparison");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: remove useless cast ─────────────────────────────
//
// Pairs with diagnostic `useless_cast_diagnostic`. Replaces the entire
// TYPE_CAST_EXPR span (`x as T`) with the source expression text (`x`).
// No additional parenthesization required because the source expression
// is itself a valid expression at the original cast's grammatical
// position (a TYPE_CAST_EXPR appears wherever a postfix expression is
// allowed, and any expression that fits as the LHS of `as` already
// fits in the same slot without it).
fn Object* try_remove_useless_cast(String uri, Document* doc, ParseResult* ast, Object* diag) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate TYPE_CAST_EXPR matching diag start position
	uint cast_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != TYPE_CAST_EXPR) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			cast_idx = i;
			break;
		}
	}
	if (cast_idx == (uint)-1) return null;
	AstNode* cast = &ast.nodes[cast_idx];

	// Find source expression: first child. TYPE_CAST_EXPR re-parents an
	// already-parsed left expression, so the child may have a lower index.
	uint src_idx = (uint)-1;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != cast_idx) continue;
		src_idx = c;
		break;
	}
	if (src_idx == (uint)-1) return null;
	AstNode* src = &ast.nodes[src_idx];

	String content = doc.content;
	if (src.start_offset >= content.len || src.end_offset > content.len) return null;
	if (src.end_offset <= src.start_offset) return null;
	String src_text = content[src.start_offset:src.end_offset - src.start_offset];

	// Build replacement range spanning full TYPE_CAST_EXPR.
	Object* edit_range = object::new_obj(tmem);
	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)cast.start_line);
	edit_start.set("character", (int)cast.start_col);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", (int)cast.end_line);
	edit_end.set("character", (int)cast.end_col);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", src_text);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove useless cast");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: replace redundant type check with literal ─────────
//
// Pairs with diagnostic from add_redundant_type_check_diagnostics.
// Rewrites TYPE_CHECK_EXPR ('x is T' / 'x !is T') to the constant
// 'true' or 'false' depending on which form the diagnostic message
// reports.
//
// Conservative: only offered when the subject expression has no
// observable side effects (NAME_EXPR, DOT_EXPR, THIS_EXPR, SUPER_EXPR,
// LITERAL_EXPR, PAREN_EXPR). For CALL_EXPR / other complex subjects
// the rewrite would silently discard the call, so skip — user can
// manually decide whether the call is needed for its side effect.
fn Object* try_replace_type_check_with_literal(String uri, Document* doc, ParseResult* ast,
		Object* diag, String message) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	// Locate TYPE_CHECK_EXPR matching diag start position.
	uint tc_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != TYPE_CHECK_EXPR) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			tc_idx = i;
			break;
		}
	}
	if (tc_idx == (uint)-1) return null;
	AstNode* tc = &ast.nodes[tc_idx];

	// Find subject child (TYPE_CHECK_EXPR re-parents left).
	uint subj_idx = (uint)-1;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != tc_idx) continue;
		subj_idx = c;
		break;
	}
	if (subj_idx == (uint)-1) return null;
	AstNode* subj = &ast.nodes[subj_idx];

	// Side-effect gate: only offer rewrite for clearly pure subjects.
	switch (subj.kind) {
		case NAME_EXPR:
		case DOT_EXPR:
		case THIS_EXPR:
		case SUPER_EXPR:
		case LITERAL_EXPR:
		case PAREN_EXPR:
			break;
		default:
			return null;
	}

	bool always_true = message.contains("always true");
	String literal = always_true ? "true" : "false";

	// Build replacement range spanning full TYPE_CHECK_EXPR.
	Object* edit_range = object::new_obj(tmem);
	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)tc.start_line);
	edit_start.set("character", (int)tc.start_col);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", (int)tc.end_line);
	edit_end.set("character", (int)tc.end_col);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", literal);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", always_true ? "Replace with 'true'" : "Replace with 'false'");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: simplify redundant subject-less when ────────────
//
// For `when { cond -> true; else -> false }` → replace whole when with cond text.
// For `when { cond -> false; else -> true }` → replace with `!(cond)` or `!cond`.
//
// Note: parser's parse_when_entry_conditions falls back to skip_when_condition
// for many shapes (e.g. binary expressions with `>`), which consumes tokens
// without producing AST nodes. So cond AST may not exist; instead extract cond
// text from source as `[entry.start_offset, body.start_offset - "->".len)`,
// trimmed of whitespace.
fn Object* try_simplify_redundant_when_bool(String uri, Document* doc, ParseResult* ast,
		Object* diag, String message) {
	if (doc == null || ast == null) return null;

	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = v; } else { return null; }
	if (try v = start.get_int("character")) { diag_col = v; } else { return null; }

	uint when_idx = (uint)-1;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != WHEN_EXPR) continue;
		if ((int)n.start_line == diag_line && (int)n.start_col == diag_col) {
			when_idx = i;
			break;
		}
	}
	if (when_idx == (uint)-1) return null;
	AstNode* when_node = &ast.nodes[when_idx];

	String content = doc.content;
	bool negated = message.contains("negated");

	// Detect subject (first non-WHEN_ENTRY child).
	uint subject_idx = (uint)-1;
	for (uint c = when_node.children_start; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != when_idx) continue;
		if (ast.nodes[c].kind == WHEN_ENTRY) break;
		subject_idx = c;
		break;
	}

	uint regular_entry = (uint)-1;
	for (uint c = when_node.children_start; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != when_idx) continue;
		if (ast.nodes[c].kind != WHEN_ENTRY) continue;
		if (ast.nodes[c].extra_text == "else") continue;
		regular_entry = c;
		break;
	}
	if (regular_entry == (uint)-1) return null;

	// ── Subject form: build "subject == cond" / "subject != cond" / "subject is/!is T"
	if (subject_idx != (uint)-1) {
		AstNode* subj = &ast.nodes[subject_idx];
		if (subj.start_offset >= content.len || subj.end_offset > content.len) return null;
		if (subj.end_offset <= subj.start_offset) return null;
		String subj_text = content[subj.start_offset:subj.end_offset - subj.start_offset];

		// Cond = first child of regular entry
		uint cond_idx = (uint)-1;
		for (uint c = ast.nodes[regular_entry].children_start; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != regular_entry) continue;
			cond_idx = c;
			break;
		}
		if (cond_idx == (uint)-1) return null;
		AstNode* cond = &ast.nodes[cond_idx];
		if (cond.start_offset >= content.len || cond.end_offset > content.len) return null;
		if (cond.end_offset <= cond.start_offset) return null;
		String cond_text = content[cond.start_offset:cond.end_offset - cond.start_offset];

		DString out;
		out.tinit();

		if (cond.kind == TYPE_CHECK_EXPR) {
			// cond_text already starts with "is " or "!is "
			String op_text = cond.extra_text == "is" ? "is" : "!is";
			// Skip the leading op + whitespace from cond_text to get the type
			usz op_len = op_text.len;
			usz tstart = op_len;
			while (tstart < cond_text.len && (cond_text[tstart] == ' ' || cond_text[tstart] == '\t')) tstart++;
			String type_text = tstart < cond_text.len ? cond_text[tstart..] : cond_text;
			String emit_op = op_text;
			if (negated) {
				emit_op = (op_text == "is") ? "!is" : "is";
			}
			out.appendf("%s %s %s", subj_text, emit_op, type_text);
		} else {
			// Equality form
			String op = negated ? "!=" : "==";
			out.appendf("%s %s %s", subj_text, op, cond_text);
		}

		return build_when_qfix_action(uri, range, diag, out.str_view(), negated);
	}

	// ── Subject-less form: derive cond text from source range

	// Body = last child (LITERAL_EXPR or BLOCK)
	uint body_idx = (uint)-1;
	for (uint c = ast.nodes[regular_entry].children_start; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != regular_entry) continue;
		body_idx = c;
	}
	if (body_idx == (uint)-1) return null;

	AstNode* entry = &ast.nodes[regular_entry];
	AstNode* body = &ast.nodes[body_idx];
	if (entry.start_offset >= content.len) return null;
	if (body.start_offset > content.len) return null;
	if (body.start_offset <= entry.start_offset) return null;

	// Slice from entry start to body start, then trim trailing whitespace + "->"
	String raw = content[entry.start_offset:body.start_offset - entry.start_offset];
	usz end = raw.len;
	// Trim trailing whitespace
	while (end > 0 && (raw[end - 1] == ' ' || raw[end - 1] == '\t' || raw[end - 1] == '\n' || raw[end - 1] == '\r')) {
		end--;
	}
	// Strip trailing "->"
	if (end >= 2 && raw[end - 2] == '-' && raw[end - 1] == '>') {
		end -= 2;
	}
	// Trim again
	while (end > 0 && (raw[end - 1] == ' ' || raw[end - 1] == '\t' || raw[end - 1] == '\n' || raw[end - 1] == '\r')) {
		end--;
	}
	if (end == 0) return null;
	String cond_text = raw[:end];

	DString new_text;
	new_text.tinit();
	if (negated) {
		// Conservative: parens whenever cond text isn't a "simple atom"
		// (contains space or non-identifier operator chars).
		bool needs_parens = cond_text_needs_parens(cond_text);
		if (needs_parens) {
			new_text.appendf("!(%s)", cond_text);
		} else {
			new_text.appendf("!%s", cond_text);
		}
	} else {
		new_text.append(cond_text);
	}

	return build_when_qfix_action(uri, range, diag, new_text.str_view(), negated);
}

// Build a workspace-edit action for the when quickfix. Shared by subject
// and subject-less code paths.
fn Object* build_when_qfix_action(String uri, Object* range, Object* diag, String new_text, bool negated) {
	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", new_text);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", negated ? "Replace with negated condition" : "Replace with condition");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// True if cond text needs parentheses to safely apply unary `!`.
// Heuristic: any binary operator, space, or `is`/`in`/`as` keyword present.
fn bool cond_text_needs_parens(String s) {
	// Allow simple call expressions: foo(...) without spaces or top-level operators.
	// Allow simple member access: foo.bar
	// Reject anything with binary operators.
	for (usz i = 0; i < s.len; i++) {
		char c = s[i];
		switch (c) {
			case ' ':
			case '\t':
			case '<':
			case '>':
			case '+':
			case '-':
			case '*':
			case '/':
			case '%':
			case '=':
			case '&':
			case '|':
			case '^':
			case '?':
				return true;
			default:
				break;
		}
	}
	return false;
}

// Scan block source bytes for // or /* OUTSIDE the single statement range.
// Returns true if any comment marker found in the block prelude/postlude.
fn bool block_contains_comment_outside(String content, AstNode* block, AstNode* stmt) {
	usz bs = (usz)block.start_offset;
	usz be = (usz)block.end_offset;
	usz ss = (usz)stmt.start_offset;
	usz se = (usz)stmt.end_offset;
	if (bs >= content.len || be > content.len) return false;
	// Check prelude: bs..ss and postlude: se..be
	if (range_has_comment(content, bs, ss)) return true;
	if (range_has_comment(content, se, be)) return true;
	return false;
}

fn bool range_has_comment(String content, usz lo, usz hi) {
	if (hi > content.len) hi = content.len;
	usz i = lo;
	while (i + 1 < hi) {
		char c0 = content[i];
		char c1 = content[i+1];
		if (c0 == '/' && (c1 == '/' || c1 == '*')) return true;
		i++;
	}
	return false;
}

// ── Quick fix: remove redundant explicit type on val/var ────────

fn Object* try_remove_redundant_explicit_type(String uri, Document* doc, ParseResult* ast, Object* diag) {
	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	uint diag_line = (uint)(start.get_int("line") ?? 0);
	uint diag_col = (uint)(start.get_int("character") ?? 0);
	long diag_off = document::position_to_byte_offset(doc.content, diag_line, diag_col);
	if (diag_off < 0) return null;

	// Find PROPERTY_DECL whose name range includes the diag offset.
	uint prop_idx = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != PROPERTY_DECL) continue;
		if (n.name_line != diag_line) continue;
		if (n.name_col != diag_col) continue;
		prop_idx = i;
		break;
	}
	if (prop_idx == uint.max) return null;

	AstNode* prop = &ast.nodes[prop_idx];
	if (prop.type_text.len == 0) return null;

	// Locate the colon after the name. Name end offset = name_col bytes after
	// the line start. Use source scan: from name's start_offset + name_len,
	// skip whitespace, expect ':'.
	usz name_end = (usz)prop.start_offset;
	// PROPERTY_DECL.start_offset begins at modifiers/keyword. Use name_len
	// + name_col against the line — easier: find the byte offset of the name
	// then scan forward.
	long name_off = document::position_to_byte_offset(doc.content, prop.name_line, prop.name_col);
	if (name_off < 0) return null;
	usz scan = (usz)name_off + (usz)prop.name_len;

	// Skip whitespace before ':'
	while (scan < doc.content.len && (doc.content[scan] == ' ' || doc.content[scan] == '\t')) {
		scan++;
	}
	if (scan >= doc.content.len || doc.content[scan] != ':') return null;
	usz colon_off = scan;
	scan++; // past ':'

	// Find end of type annotation. The next significant token is either '='
	// (initializer), 'by' (delegate — but we skip those in the diag), or
	// newline / EOF (no initializer — skipped too). Conservatively: scan to
	// the next '=' or newline, whichever comes first.
	usz type_end = scan;
	while (type_end < doc.content.len) {
		char c = doc.content[type_end];
		if (c == '=' || c == '\n' || c == '\r') break;
		type_end++;
	}

	// type_end points at '=' or newline. Trim trailing whitespace from the
	// region we'll delete so the spacing around '=' looks right after edit.
	while (type_end > scan && (doc.content[type_end - 1] == ' ' || doc.content[type_end - 1] == '\t')) {
		type_end--;
	}

	// Backtrack name_end-1 to swallow the single space between name and ':'
	// so we don't leave a trailing space. But if there's no preceding space
	// (e.g. `val x:Int`), don't underflow.
	usz delete_start = (usz)name_off + (usz)prop.name_len;
	usz delete_end = type_end;
	if (delete_end <= delete_start) return null;

	// Convert offsets to LSP positions for the edit range.
	uint dl_line, dl_col;
	if (!offset_to_line_col(doc.content, delete_start, &dl_line, &dl_col)) return null;
	uint de_line, de_col;
	if (!offset_to_line_col(doc.content, delete_end, &de_line, &de_col)) return null;

	Object* edit_start = object::new_obj(tmem);
	edit_start.set("line", (int)dl_line);
	edit_start.set("character", (int)dl_col);
	Object* edit_end = object::new_obj(tmem);
	edit_end.set("line", (int)de_line);
	edit_end.set("character", (int)de_col);
	Object* edit_range = object::new_obj(tmem);
	edit_range.set("start", edit_start);
	edit_range.set("end", edit_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", "");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Remove explicit type specification");
	action.set("kind", "quickfix");
	Object* diags_arr = object::new_obj(tmem);
	diags_arr.push(diag);
	action.set("diagnostics", diags_arr);
	action.set("edit", workspace_edit);
	return action;
}

fn bool offset_to_line_col(String content, usz offset, uint* line, uint* col) {
	if (offset > content.len) return false;
	uint l = 0;
	uint c = 0;
	for (usz i = 0; i < offset; i++) {
		if (content[i] == '\n') { l++; c = 0; }
		else { c++; }
	}
	*line = l;
	*col = c;
	return true;
}

// ── Quickfix: insert ?. or !! for nullable receiver ──────────
//
// Pair quickfixes for the unsafe-nullable-receiver diagnostic. Locates the
// DOT_EXPR whose receiver lives at the diagnostic's start position, then
// emits two actions:
//   - Replace `.` with `?.` (safe call)
//   - Add `!!` after the receiver (non-null assertion)
fn void try_add_unsafe_null_recv_actions(Object* actions, String uri, Document* doc, ParseResult* ast, Object* diag) {
	if (doc == null || ast == null) return;

	Object* range = diag.get("range") ?? null;
	if (range == null) return;
	Object* start = range.get("start") ?? null;
	if (start == null) return;
	int diag_line;
	int diag_col;
	if (try v = start.get_int("line")) { diag_line = (int)v; }
	else { return; }
	if (try v = start.get_int("character")) { diag_col = (int)v; }
	else { return; }

	long diag_offset = document::position_to_byte_offset(doc.content, diag_line, diag_col);
	if (diag_offset < 0) return;

	// Find the DOT_EXPR whose start_offset matches the diag_offset.
	uint dot_idx = ast::NO_PARENT;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != DOT_EXPR) continue;
		if (n.extra_text == "?.") continue;
		if ((long)n.start_offset != diag_offset) continue;
		dot_idx = i;
		break;
	}
	if (dot_idx == ast::NO_PARENT) return;

	// Receiver is the lower-indexed first child.
	uint recv_idx = ast::NO_PARENT;
	for (uint j = 0; j < ast.node_count; j++) {
		if (ast.nodes[j].parent == dot_idx) { recv_idx = j; break; }
	}
	if (recv_idx == ast::NO_PARENT) return;

	AstNode* recv = &ast.nodes[recv_idx];
	usz recv_end = recv.end_offset;
	if (recv_end >= doc.content.len) return;

	// Find the dot character starting from recv_end (skip whitespace).
	usz dot_off = recv_end;
	while (dot_off < doc.content.len && doc.content[dot_off] != '.') dot_off++;
	if (dot_off >= doc.content.len) return;

	// Convert recv_end and dot_off back to line/col.
	uint recv_line; uint recv_col;
	if (!offset_to_line_col(doc.content, recv_end, &recv_line, &recv_col)) return;
	uint dot_line; uint dot_col;
	if (!offset_to_line_col(doc.content, dot_off, &dot_line, &dot_col)) return;

	// Action 1: replace `.` with `?.` (insert `?` before the dot).
	{
		Object* edit_range = object::new_obj(tmem);
		Object* es = object::new_obj(tmem);
		es.set("line", (int)dot_line);
		es.set("character", (int)dot_col);
		Object* ee = object::new_obj(tmem);
		ee.set("line", (int)dot_line);
		ee.set("character", (int)dot_col);
		edit_range.set("start", es);
		edit_range.set("end", ee);

		Object* edit = object::new_obj(tmem);
		edit.set("range", edit_range);
		edit.set("newText", "?");

		Object* edits = object::new_obj(tmem);
		edits.push(edit);
		Object* changes = object::new_obj(tmem);
		changes.set(uri, edits);
		Object* workspace_edit = object::new_obj(tmem);
		workspace_edit.set("changes", changes);

		Object* action = object::new_obj(tmem);
		action.set("title", "Replace '.' with safe call '?.'");
		action.set("kind", "quickfix");
		action.set("isPreferred", true);
		action.set("edit", workspace_edit);

		Object* action_diags = object::new_obj(tmem);
		action_diags.push(diag);
		action.set("diagnostics", action_diags);

		actions.push(action);
	}

	// Action 2: insert `!!` after receiver.
	{
		Object* edit_range = object::new_obj(tmem);
		Object* es = object::new_obj(tmem);
		es.set("line", (int)recv_line);
		es.set("character", (int)recv_col);
		Object* ee = object::new_obj(tmem);
		ee.set("line", (int)recv_line);
		ee.set("character", (int)recv_col);
		edit_range.set("start", es);
		edit_range.set("end", ee);

		Object* edit = object::new_obj(tmem);
		edit.set("range", edit_range);
		edit.set("newText", "!!");

		Object* edits = object::new_obj(tmem);
		edits.push(edit);
		Object* changes = object::new_obj(tmem);
		changes.set(uri, edits);
		Object* workspace_edit = object::new_obj(tmem);
		workspace_edit.set("changes", changes);

		Object* action = object::new_obj(tmem);
		action.set("title", "Assert non-null with '!!'");
		action.set("kind", "quickfix");
		action.set("edit", workspace_edit);

		Object* action_diags = object::new_obj(tmem);
		action_diags.push(diag);
		action.set("diagnostics", action_diags);

		actions.push(action);
	}
}

// ── Quickfix: rename unused parameter to '_' ────────────────────
//
// Pairs with diagnostic "Parameter 'x' is never used" (Hint, severity 4).
// Kotlin convention: prefixing or replacing an unused param name with '_'
// signals intent. The diagnostic range already points at the param name
// identifier — replacing that range with "_" is a safe text edit.
fn Object* try_rename_unused_param_underscore(String uri, Object* diag) {
	Object* range = diag.get("range") ?? null;
	if (range == null) return null;

	Object* edit = object::new_obj(tmem);
	edit.set("range", range);
	edit.set("newText", "_");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Rename to '_'");
	action.set("kind", "quickfix");
	action.set("isPreferred", true);
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Quickfix: prefix unused parameter with '_' ──────────────────
//
// Companion to try_rename_unused_param_underscore. Some users prefer to
// keep the name readable (e.g. `_event` instead of `_`) for documentation
// while still silencing the diagnostic — Kotlin's unused-name rule keys
// on the leading underscore.
fn Object* try_prefix_unused_param_underscore(String uri, Object* diag) {
	Object* range = diag.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;

	// Insert '_' at the start of the name range — zero-width edit.
	Object* zero_end = object::new_obj(tmem);
	int sl = start.get_int("line") ?? 0;
	int sc = start.get_int("character") ?? 0;
	zero_end.set("line", sl);
	zero_end.set("character", sc);
	Object* zero_start = object::new_obj(tmem);
	zero_start.set("line", sl);
	zero_start.set("character", sc);
	Object* insert_range = object::new_obj(tmem);
	insert_range.set("start", zero_start);
	insert_range.set("end", zero_end);

	Object* edit = object::new_obj(tmem);
	edit.set("range", insert_range);
	edit.set("newText", "_");

	Object* edits = object::new_obj(tmem);
	edits.push(edit);

	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Prefix with '_'");
	action.set("kind", "quickfix");
	action.set("edit", workspace_edit);

	Object* action_diags = object::new_obj(tmem);
	action_diags.push(diag);
	action.set("diagnostics", action_diags);

	return action;
}

// ── Refactor: simplify Comparable's compareTo chain ─────────────
//
// Detects the manual idiom:
//
//   override fun compareTo(other: T): Int {
//       val cmp1 = a.compareTo(other.a)
//       if (cmp1 != 0) return cmp1
//       val cmp2 = b.compareTo(other.b)
//       if (cmp2 != 0) return cmp2
//       return c.compareTo(other.c)
//   }
//
// and rewrites it to:
//
//   override fun compareTo(other: T): Int =
//       compareValuesBy(this, other, { it.a }, { it.b }, { it.c })
//
// Tight scope:
//   - exactly one BLOCK with N>=2 stmts (can be 1 chain step + return)
//   - all 'cmp' bindings: PROPERTY_DECL + IF_EXPR pair
//   - each 'a.compareTo(other.a)' uses NAME_EXPR receiver matching
//     'this' and arg 'other.<same name>' (using fn's param name as
//     'other')
//   - last stmt is RETURN_EXPR returning either the trailing cmp name
//     or a final field.compareTo(other.field) call
//
// Bails on anything funky: type args, custom getters, qualified
// receivers, named-arg syntax, not-equals zero variants other than
// '!= 0', etc.

fn String extract_field_from_compare_call(ParseResult* ast, uint call_idx, String other_name) {
	if (call_idx >= ast.node_count) return "";
	AstNode* call = &ast.nodes[call_idx];
	if (call.kind != CALL_EXPR) return "";
	// callee should be DOT_EXPR named "compareTo" with NAME_EXPR receiver
	uint callee = ast::NO_PARENT;
	uint arg = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != call_idx) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind == DOT_EXPR && callee == ast::NO_PARENT) {
			callee = c;
		} else if (ch.kind == VALUE_ARGUMENT && arg == ast::NO_PARENT) {
			arg = c;
		}
	}
	if (callee == ast::NO_PARENT || arg == ast::NO_PARENT) return "";
	AstNode* cn = &ast.nodes[callee];
	if (cn.name != "compareTo") return "";
	// Receiver of callee = NAME_EXPR (the 'a' field). Get its name.
	String recv_name = "";
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != callee) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind != NAME_EXPR) return "";
		recv_name = ch.name;
		break;
	}
	if (recv_name.len == 0) return "";
	if (ast.nodes[arg].name.len > 0) return ""; // named arg => bail
	// VALUE_ARGUMENT child = DOT_EXPR named recv_name with receiver NAME_EXPR(other_name)
	uint arg_expr = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != arg) continue;
		arg_expr = c; break;
	}
	if (arg_expr == ast::NO_PARENT) return "";
	AstNode* ae = &ast.nodes[arg_expr];
	if (ae.kind != DOT_EXPR) return "";
	if (ae.name != recv_name) return "";
	uint ae_recv = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != arg_expr) continue;
		ae_recv = c; break;
	}
	if (ae_recv == ast::NO_PARENT) return "";
	if (ast.nodes[ae_recv].kind != NAME_EXPR) return "";
	if (ast.nodes[ae_recv].name != other_name) return "";
	return recv_name;
}

fn Object* try_simplify_compareto_chain(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest FUN_DECL containing cursor
	uint fun_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			fun_idx = i;
		}
	}
	if (fun_idx == uint.max) return null;

	AstNode* fun_node = &ast.nodes[fun_idx];
	if (fun_node.name != "compareTo") return null;

	// Locate exactly one PARAM (besides ANNOTATION_ENTRY/TYPE_PARAM) and
	// one BLOCK child.
	uint param_idx = uint.max;
	uint block_idx = uint.max;
	uint param_count = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != fun_idx) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind == PARAM) {
			param_count++;
			param_idx = c;
		} else if (ch.kind == BLOCK) {
			block_idx = c;
		}
	}
	if (param_count != 1) return null;
	if (block_idx == uint.max) return null;
	String other_name = ast.nodes[param_idx].name;
	if (other_name.len == 0) return null;

	// Collect block statements in order.
	uint[64] stmts;
	uint stmt_count = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != block_idx) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind == ANNOTATION_ENTRY) continue;
		if (stmt_count >= 64) return null;
		stmts[stmt_count++] = c;
	}
	if (stmt_count < 2) return null;

	// Walk pairs: (PROPERTY_DECL cmpN := field.compareTo(other.field), IF_EXPR)
	// Final stmt must be a RETURN_EXPR.
	String[32] fields;
	uint field_count = 0;
	uint i = 0;
	while (i + 2 <= stmt_count - 1) {
		uint pd_idx = stmts[i];
		uint if_idx = stmts[i + 1];
		AstNode* pd = &ast.nodes[pd_idx];
		AstNode* iff = &ast.nodes[if_idx];
		if (pd.kind != PROPERTY_DECL) return null;
		if (iff.kind != IF_EXPR) return null;
		String cmp_name = pd.name;
		if (cmp_name.len == 0) return null;
		// PROPERTY_DECL must have one CALL_EXPR initializer.
		uint init_call = ast::NO_PARENT;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != pd_idx) continue;
			AstNode* ch = &ast.nodes[c];
			if (ch.kind == ANNOTATION_ENTRY) continue;
			if (ch.kind == TYPE_REF) continue;
			if (ch.kind == FUN_DECL) return null; // custom accessor
			if (init_call == ast::NO_PARENT) {
				init_call = c;
			} else {
				return null;
			}
		}
		if (init_call == ast::NO_PARENT) return null;
		String fld = extract_field_from_compare_call(ast, init_call, other_name);
		if (fld.len == 0) return null;
		// IF_EXPR: cond = BINARY_EXPR(NAME_EXPR(cmp_name) "!=" LITERAL_EXPR("0"))
		// then = RETURN_EXPR(NAME_EXPR(cmp_name)), no else
		uint cond_idx = ast::NO_PARENT;
		uint then_idx = ast::NO_PARENT;
		uint else_idx = ast::NO_PARENT;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != if_idx) continue;
			if (cond_idx == ast::NO_PARENT) { cond_idx = c; }
			else if (then_idx == ast::NO_PARENT) { then_idx = c; }
			else if (else_idx == ast::NO_PARENT) { else_idx = c; }
		}
		if (else_idx != ast::NO_PARENT) return null;
		if (cond_idx == ast::NO_PARENT || then_idx == ast::NO_PARENT) return null;
		AstNode* cond = &ast.nodes[cond_idx];
		if (cond.kind != BINARY_EXPR || cond.extra_text != "!=") return null;
		// Cond children: NAME_EXPR cmp_name, LITERAL_EXPR "0"
		uint cond_lhs = ast::NO_PARENT;
		uint cond_rhs = ast::NO_PARENT;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != cond_idx) continue;
			if (cond_lhs == ast::NO_PARENT) { cond_lhs = c; }
			else if (cond_rhs == ast::NO_PARENT) { cond_rhs = c; }
		}
		if (cond_lhs == ast::NO_PARENT || cond_rhs == ast::NO_PARENT) return null;
		if (ast.nodes[cond_lhs].kind != NAME_EXPR || ast.nodes[cond_lhs].name != cmp_name) return null;
		if (ast.nodes[cond_rhs].kind != LITERAL_EXPR || ast.nodes[cond_rhs].extra_text != "0") return null;
		// then = RETURN_EXPR returning NAME_EXPR(cmp_name)
		AstNode* then_n = &ast.nodes[then_idx];
		uint return_node = then_idx;
		if (then_n.kind == BLOCK) {
			uint inner = ast::NO_PARENT;
			uint inner_count = 0;
			for (uint c = 0; c < ast.node_count; c++) {
				if (ast.nodes[c].parent != then_idx) continue;
				inner = c;
				inner_count++;
			}
			if (inner_count != 1) return null;
			return_node = inner;
		}
		if (ast.nodes[return_node].kind != RETURN_EXPR) return null;
		uint ret_val = ast::NO_PARENT;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != return_node) continue;
			ret_val = c; break;
		}
		if (ret_val == ast::NO_PARENT) return null;
		if (ast.nodes[ret_val].kind != NAME_EXPR || ast.nodes[ret_val].name != cmp_name) return null;

		if (field_count >= 32) return null;
		fields[field_count++] = fld;
		i += 2;
	}

	// Final stmt: RETURN_EXPR returning either NAME_EXPR(last cmp) or a
	// raw field.compareTo(other.field) call.
	if (i != stmt_count - 1) return null;
	uint last_stmt = stmts[stmt_count - 1];
	if (ast.nodes[last_stmt].kind != RETURN_EXPR) return null;
	uint ret_expr = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != last_stmt) continue;
		ret_expr = c; break;
	}
	if (ret_expr == ast::NO_PARENT) return null;
	AstNode* re = &ast.nodes[ret_expr];
	if (re.kind == CALL_EXPR) {
		String fld = extract_field_from_compare_call(ast, ret_expr, other_name);
		if (fld.len == 0) return null;
		if (field_count >= 32) return null;
		fields[field_count++] = fld;
	} else {
		// Bail: must be a CALL_EXPR for the trailing comparison.
		return null;
	}

	if (field_count < 2) return null;

	// Build the replacement source text and edit range covering the
	// BLOCK (we replace ' { ... }' with ' = compareValuesBy(...)').
	AstNode* block = &ast.nodes[block_idx];
	// Find the '{' offset = block.start_offset (first char of body in
	// most parser shapes).
	DString out;
	out.tinit();
	out.append("= compareValuesBy(this, ");
	out.append(other_name);
	for (uint k = 0; k < field_count; k++) {
		out.append(", { it.");
		out.append(fields[k]);
		out.append(" }");
	}
	out.append(")");

	// Replacement spans from one char before '{' (to swap the brace for '=')
	// through the closing '}'. Walk content backwards from block.start_offset
	// to find any whitespace just before the brace.
	uint replace_start = block.start_offset;
	while (replace_start > 0) {
		char ch = doc.content[replace_start - 1];
		if (ch == ' ' || ch == '\t') {
			replace_start--;
		} else {
			break;
		}
	}
	uint replace_end = block.end_offset;

	uint start_line; uint start_col;
	uint end_line; uint end_col;
	offset_to_line_col(doc.content, replace_start, &start_line, &start_col);
	offset_to_line_col(doc.content, replace_end, &end_line, &end_col);

	Object* edit_range = object::new_obj(tmem);
	Object* es = object::new_obj(tmem);
	es.set("line", (int)start_line);
	es.set("character", (int)start_col);
	Object* ee = object::new_obj(tmem);
	ee.set("line", (int)end_line);
	ee.set("character", (int)end_col);
	edit_range.set("start", es);
	edit_range.set("end", ee);

	DString final_text;
	final_text.tinit();
	final_text.append(" ");
	final_text.append(out.str_view());

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", final_text.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Replace with 'compareValuesBy'");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ─── Refactor: simplify `if (cond) true else false` (or boolean inverse) ───
//
// Cursor-based refactor.rewrite. Triggers when the cursor sits inside an
// IF_EXPR whose then and else branches each unwrap to a single boolean
// literal (`true` / `false`). Two forms supported:
//   expression form   if (c) true else false        →  c
//                     if (c) false else true        →  !c
//   return form       if (c) return true else return false   → return c
//                     if (c) return false else return true   → return !c
// Both literal-position and BLOCK-wrapped variants are accepted (e.g.
// `if (c) { true } else { false }`). Mixed forms (one branch literal, the
// other return) are skipped — the rewrite would change control flow.
//
// Comments anywhere inside the if-expr span suppress the action.
fn uint if_bool_unwrap_branch(ParseResult* ast, uint branch_idx, bool* is_return_out) {
	if (branch_idx >= ast.node_count) return ast::NO_PARENT;
	AstNode* n = &ast.nodes[branch_idx];
	// Unwrap BLOCK { single statement }
	if (n.kind == BLOCK) {
		uint inner = ast::NO_PARENT;
		uint count = 0;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != branch_idx) continue;
			if (ast.nodes[c].kind == ANNOTATION_ENTRY) continue;
			count++;
			inner = c;
		}
		if (count != 1) return ast::NO_PARENT;
		return if_bool_unwrap_branch(ast, inner, is_return_out);
	}
	// RETURN_EXPR with single literal child
	if (n.kind == RETURN_EXPR) {
		uint inner = ast::NO_PARENT;
		uint count = 0;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != branch_idx) continue;
			if (ast.nodes[c].kind == ANNOTATION_ENTRY) continue;
			count++;
			inner = c;
		}
		if (count != 1) return ast::NO_PARENT;
		AstNode* lit = &ast.nodes[inner];
		if (lit.kind != LITERAL_EXPR) return ast::NO_PARENT;
		if (lit.extra_text != "true" && lit.extra_text != "false") return ast::NO_PARENT;
		*is_return_out = true;
		return inner;
	}
	if (n.kind == LITERAL_EXPR) {
		if (n.extra_text != "true" && n.extra_text != "false") return ast::NO_PARENT;
		*is_return_out = false;
		return branch_idx;
	}
	return ast::NO_PARENT;
}

fn Object* try_simplify_if_bool_consts(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find the smallest IF_EXPR containing the cursor.
	uint if_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IF_EXPR) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			if_idx = i;
		}
	}
	if (if_idx == uint.max) return null;

	AstNode* iff = &ast.nodes[if_idx];

	// Collect children: cond, then, else.
	uint cond_idx = ast::NO_PARENT;
	uint then_idx = ast::NO_PARENT;
	uint else_idx = ast::NO_PARENT;
	uint child_seen = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != if_idx) continue;
		if (ast.nodes[c].kind == ANNOTATION_ENTRY) continue;
		if (child_seen == 0) {
			cond_idx = c;
		} else if (child_seen == 1) {
			then_idx = c;
		} else if (child_seen == 2) {
			else_idx = c;
		} else {
			return null; // more than 3 children – unexpected
		}
		child_seen++;
	}
	if (cond_idx == ast::NO_PARENT) return null;
	if (then_idx == ast::NO_PARENT) return null;
	if (else_idx == ast::NO_PARENT) return null;

	bool then_is_return = false;
	bool else_is_return = false;
	uint then_lit = if_bool_unwrap_branch(ast, then_idx, &then_is_return);
	uint else_lit = if_bool_unwrap_branch(ast, else_idx, &else_is_return);
	if (then_lit == ast::NO_PARENT) return null;
	if (else_lit == ast::NO_PARENT) return null;
	// Mixed forms (literal vs return) would change control flow – skip.
	if (then_is_return != else_is_return) return null;

	String then_val = ast.nodes[then_lit].extra_text;
	String else_val = ast.nodes[else_lit].extra_text;
	bool negate;
	if (then_val == "true" && else_val == "false") {
		negate = false;
	} else if (then_val == "false" && else_val == "true") {
		negate = true;
	} else {
		return null;
	}

	// Refuse if any comment lives inside the if-expr span – preserve intent.
	if (range_has_comment(doc.content, iff.start_offset, iff.end_offset)) return null;

	// Extract the original cond source slice.
	AstNode* cond = &ast.nodes[cond_idx];
	if (cond.start_offset >= cond.end_offset) return null;
	if (cond.end_offset > doc.content.len) return null;
	String cond_src = doc.content[cond.start_offset:cond.end_offset - cond.start_offset];

	DString out;
	out.tinit();
	if (then_is_return) {
		out.append("return ");
	}
	if (negate) {
		out.append("!");
		if (cond_text_needs_parens(cond_src)) {
			out.append("(");
			out.append(cond_src);
			out.append(")");
		} else {
			out.append(cond_src);
		}
	} else {
		out.append(cond_src);
	}

	uint start_line; uint start_col;
	uint end_line; uint end_col;
	offset_to_line_col(doc.content, iff.start_offset, &start_line, &start_col);
	offset_to_line_col(doc.content, iff.end_offset, &end_line, &end_col);

	Object* edit_range = object::new_obj(tmem);
	Object* es = object::new_obj(tmem);
	es.set("line", (int)start_line);
	es.set("character", (int)start_col);
	Object* ee = object::new_obj(tmem);
	ee.set("line", (int)end_line);
	ee.set("character", (int)end_col);
	edit_range.set("start", es);
	edit_range.set("end", ee);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Simplify boolean expression");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ─── Refactor: `recv?.let { it.foo(args) }` → `recv?.foo(args)` ──────
//
// Cursor-based refactor.rewrite. Triggers when the cursor sits inside a
// CALL_EXPR whose callee is `recv.let` / `recv?.let` and whose single
// argument is a trailing lambda containing exactly one statement of the
// form `it.member` or `it.member(args)`.
//
// Cases handled:
//   recv.let { it.foo() }      →  recv.foo()
//   recv?.let { it.foo() }     →  recv?.foo()
//   recv.let { it.field }      →  recv.field
//   recv?.let { it.field }     →  recv?.field
//
// Skipped when the inner access is itself `?.` (would chain safe-calls
// around an already-narrowed `it` which is illegal), when the lambda has
// any explicit parameters (renaming `it` defeats the rewrite), when the
// args reference `it` (would lose the local binding), or when comments
// live inside the CALL_EXPR span.
fn bool name_expr_is_it(ParseResult* ast, uint idx) {
	if (idx >= ast.node_count) return false;
	AstNode* n = &ast.nodes[idx];
	return n.kind == NAME_EXPR && n.name == "it";
}

fn bool subtree_uses_name(ParseResult* ast, uint root, String name) {
	if (root >= ast.node_count) return false;
	uint root_lo = ast.nodes[root].start_offset;
	uint root_hi = ast.nodes[root].end_offset;
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != NAME_EXPR) continue;
		if (n.name != name) continue;
		if (n.start_offset < root_lo) continue;
		if (n.end_offset > root_hi) continue;
		return true;
	}
	return false;
}

fn Object* try_collapse_let_to_safe_call(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Smallest CALL_EXPR containing the cursor.
	uint call_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != CALL_EXPR) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			call_idx = i;
		}
	}
	if (call_idx == uint.max) return null;

	AstNode* call = &ast.nodes[call_idx];

	// Children: callee + value-arguments.
	uint callee_idx = ast::NO_PARENT;
	uint trailing_va_idx = ast::NO_PARENT;
	uint other_arg_count = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != call_idx) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind == ANNOTATION_ENTRY) continue;
		if (ch.kind == VALUE_ARGUMENT) {
			if (ch.extra_text == "trailing") {
				if (trailing_va_idx != ast::NO_PARENT) return null;
				trailing_va_idx = c;
			} else {
				other_arg_count++;
			}
		} else {
			if (callee_idx != ast::NO_PARENT) return null;
			callee_idx = c;
		}
	}
	if (callee_idx == ast::NO_PARENT) return null;
	if (trailing_va_idx == ast::NO_PARENT) return null;
	if (other_arg_count != 0) return null;

	// Callee must be DOT_EXPR named "let".
	AstNode* callee = &ast.nodes[callee_idx];
	if (callee.kind != DOT_EXPR) return null;
	if (callee.name != "let") return null;
	// Outer dot: "" (plain ".") or "?." for safe call.
	String outer_dot = callee.extra_text == "?." ? "?." : ".";

	// Receiver of `recv.let` / `recv?.let`.
	uint outer_recv_idx = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != callee_idx) continue;
		if (ast.nodes[c].kind == ANNOTATION_ENTRY) continue;
		if (ast.nodes[c].kind == TYPE_ARG) continue;
		if (outer_recv_idx == ast::NO_PARENT) {
			outer_recv_idx = c;
		} else {
			return null;
		}
	}
	if (outer_recv_idx == ast::NO_PARENT) return null;
	AstNode* outer_recv = &ast.nodes[outer_recv_idx];

	// Trailing arg must wrap a single LAMBDA_EXPR.
	uint lambda_idx = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != trailing_va_idx) continue;
		if (lambda_idx != ast::NO_PARENT) return null;
		lambda_idx = c;
	}
	if (lambda_idx == ast::NO_PARENT) return null;
	AstNode* lambda = &ast.nodes[lambda_idx];
	if (lambda.kind != LAMBDA_EXPR) return null;

	// Lambda must have no explicit PARAMs (implicit `it` only) and a single
	// statement body.
	uint body_stmt = ast::NO_PARENT;
	uint body_count = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != lambda_idx) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind == ANNOTATION_ENTRY) continue;
		if (ch.kind == PARAM) return null; // explicit params – skip
		body_count++;
		body_stmt = c;
	}
	if (body_count != 1) return null;
	if (body_stmt == ast::NO_PARENT) return null;

	// Body statement: `it.member` (DOT_EXPR) or `it.member(args)` (CALL_EXPR).
	AstNode* stmt = &ast.nodes[body_stmt];
	uint inner_dot_idx = ast::NO_PARENT;
	uint inner_args_lo = 0;
	uint inner_args_hi = 0;
	bool is_call_form = false;
	if (stmt.kind == DOT_EXPR) {
		inner_dot_idx = body_stmt;
	} else if (stmt.kind == CALL_EXPR) {
		is_call_form = true;
		// Find inner callee + check args don't reference `it`.
		uint inner_callee = ast::NO_PARENT;
		for (uint c = 0; c < ast.node_count; c++) {
			if (ast.nodes[c].parent != body_stmt) continue;
			AstNode* ch = &ast.nodes[c];
			if (ch.kind == ANNOTATION_ENTRY) continue;
			if (ch.kind == VALUE_ARGUMENT) {
				if (subtree_uses_name(ast, c, "it")) return null;
			} else if (ch.kind != TYPE_ARG) {
				if (inner_callee != ast::NO_PARENT) return null;
				inner_callee = c;
			}
		}
		if (inner_callee == ast::NO_PARENT) return null;
		if (ast.nodes[inner_callee].kind != DOT_EXPR) return null;
		inner_dot_idx = inner_callee;
		// Args span: from end of inner callee dot to end of body stmt
		// (covers `(args)` including parens).
		inner_args_lo = ast.nodes[inner_callee].end_offset;
		inner_args_hi = stmt.end_offset;
		if (inner_args_hi < inner_args_lo) return null;
	} else {
		return null;
	}

	AstNode* inner_dot = &ast.nodes[inner_dot_idx];
	// Plain dot has empty extra_text; safe-call has "?.". Skip the latter
	// because chaining safe calls around an already-narrowed `it` is illegal.
	if (inner_dot.extra_text == "?.") return null;
	if (inner_dot.name.len == 0) return null;
	String member = inner_dot.name;

	// Inner dot's receiver must be the bare `it` NAME_EXPR.
	uint it_idx = ast::NO_PARENT;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != inner_dot_idx) continue;
		AstNode* ch = &ast.nodes[c];
		if (ch.kind == ANNOTATION_ENTRY) continue;
		if (ch.kind == TYPE_ARG) continue;
		if (it_idx == ast::NO_PARENT) {
			it_idx = c;
		} else {
			return null;
		}
	}
	if (it_idx == ast::NO_PARENT) return null;
	if (!name_expr_is_it(ast, it_idx)) return null;

	// Comments inside the CALL_EXPR span suppress the rewrite.
	if (range_has_comment(doc.content, call.start_offset, call.end_offset)) return null;

	// Outer receiver source slice.
	if (outer_recv.start_offset >= outer_recv.end_offset) return null;
	if (outer_recv.end_offset > doc.content.len) return null;
	String recv_src = doc.content[outer_recv.start_offset:outer_recv.end_offset - outer_recv.start_offset];

	String args_src = "";
	if (is_call_form) {
		if (inner_args_hi > doc.content.len) return null;
		args_src = doc.content[inner_args_lo:inner_args_hi - inner_args_lo];
		// Strip leading whitespace from args – the original source had a
		// space before the lambda, but we want a tight call.
	}

	DString out;
	out.tinit();
	out.append(recv_src);
	out.append(outer_dot);
	out.append(member);
	if (is_call_form) {
		// Trim leading whitespace from args_src.
		uint k = 0;
		while (k < args_src.len) {
			char ch = args_src[k];
			if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
				k++;
			} else {
				break;
			}
		}
		out.append(args_src[k..]);
	}

	uint start_line; uint start_col;
	uint end_line; uint end_col;
	offset_to_line_col(doc.content, call.start_offset, &start_line, &start_col);
	offset_to_line_col(doc.content, call.end_offset, &end_line, &end_col);

	Object* edit_range = object::new_obj(tmem);
	Object* es = object::new_obj(tmem);
	es.set("line", (int)start_line);
	es.set("character", (int)start_col);
	Object* ee = object::new_obj(tmem);
	ee.set("line", (int)end_line);
	ee.set("character", (int)end_col);
	edit_range.set("start", es);
	edit_range.set("end", ee);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Replace 'let' with safe call");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ─── Refactor: `lateinit var foo: T` → `val foo: T by lazy { TODO(...) }` ─
//
// Cursor-based refactor.rewrite. Replaces the entire PROPERTY_DECL span
// with a `val ... by lazy { TODO(...) }` template. The rewrite is
// intentionally a STARTING POINT — the author must fill in the TODO
// with the real initialization expression, since semantics differ:
//
//   lateinit var: caller assigns at some later point; reads before
//                  assignment throw UninitializedPropertyAccessException.
//   val by lazy:   first read evaluates the lambda; subsequent reads
//                  return the cached value.
//
// We surface this as a refactor (not an automatic quickfix) so the
// author confirms the timing change is intentional. The TODO is
// preserved verbatim with the property name as the message.
//
// Constraints:
//   - PROPERTY_DECL has both MOD_LATEINIT and MOD_VAR set.
//   - Has an explicit type (no `lateinit var foo` without `: T` – which
//     is also rejected by the Kotlin compiler, so this is just defence).
//   - Lives inside a class/interface/object/companion body (not local).
//     Local properties cannot be `lateinit` per spec.
//
// Comments inside the PROPERTY_DECL span suppress the action to avoid
// silently dropping author intent.
fn bool decl_is_class_member(ParseResult* ast, uint idx) {
	uint cur = ast.nodes[idx].parent;
	while (cur != ast::NO_PARENT) {
		NodeKind k = ast.nodes[cur].kind;
		if (k == CLASS_DECL || k == INTERFACE_DECL || k == OBJECT_DECL || k == COMPANION_OBJECT_DECL) return true;
		if (k == FUN_DECL || k == LAMBDA_EXPR || k == ANONYMOUS_FUN_EXPR) return false;
		if (k == FILE) return false;
		cur = ast.nodes[cur].parent;
	}
	return false;
}

fn Object* try_lateinit_to_lazy(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Smallest PROPERTY_DECL containing the cursor.
	uint pd_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != PROPERTY_DECL) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			pd_idx = i;
		}
	}
	if (pd_idx == uint.max) return null;

	AstNode* pd = &ast.nodes[pd_idx];
	if ((pd.mod_flags & ast::MOD_LATEINIT) == 0) return null;
	if ((pd.mod_flags & ast::MOD_VAR) == 0) return null;
	if (pd.name.len == 0) return null;
	if (pd.type_text.len == 0) return null;
	if (!decl_is_class_member(ast, pd_idx)) return null;

	// Comment guard.
	if (range_has_comment(doc.content, pd.start_offset, pd.end_offset)) return null;

	// Build replacement: `val NAME: TYPE by lazy { TODO("Initialize NAME") }`.
	DString out;
	out.tinit();
	out.append("val ");
	out.append(pd.name);
	out.append(": ");
	out.append(pd.type_text);
	out.append(" by lazy { TODO(\"Initialize ");
	out.append(pd.name);
	out.append("\") }");

	uint start_line; uint start_col;
	uint end_line; uint end_col;
	offset_to_line_col(doc.content, pd.start_offset, &start_line, &start_col);
	offset_to_line_col(doc.content, pd.end_offset, &end_line, &end_col);

	Object* edit_range = object::new_obj(tmem);
	Object* es = object::new_obj(tmem);
	es.set("line", (int)start_line);
	es.set("character", (int)start_col);
	Object* ee = object::new_obj(tmem);
	ee.set("line", (int)end_line);
	ee.set("character", (int)end_col);
	edit_range.set("start", es);
	edit_range.set("end", ee);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", out.str_view());

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Convert 'lateinit var' to 'val by lazy { TODO }'");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}

// ─── Refactor: `if (x != null) x else null` / `if (x == null) null else x` → `x` ─
//
// Cursor-based refactor.rewrite. The two if-branches are exactly `x` and
// `null`, gated by a `x != null` (or `x == null`) check. The whole thing
// is just `x` — the type system already gives the same result.
//
// Skips:
//   - condition is not a binary `==`/`!=` between a name and `null`
//   - branches are not exactly the same name and a null literal
//   - any comment in the if-expr span (preserve author intent)
//   - if-expr without an else branch
fn uint null_passthrough_unwrap(ParseResult* ast, uint branch_idx) {
	// Strip BLOCK wrapping a single statement.
	if (branch_idx >= ast.node_count) return ast::NO_PARENT;
	AstNode* n = &ast.nodes[branch_idx];
	if (n.kind != BLOCK) return branch_idx;
	uint inner = ast::NO_PARENT;
	uint count = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != branch_idx) continue;
		inner = c;
		count++;
		if (count > 1) return ast::NO_PARENT;
	}
	if (count != 1) return ast::NO_PARENT;
	return inner;
}

fn Object* try_simplify_null_passthrough(String uri, Document* doc, ParseResult* ast, Object* params) {
	if (doc == null || ast == null) return null;
	Object* range = params.get("range") ?? null;
	if (range == null) return null;
	Object* start = range.get("start") ?? null;
	if (start == null) return null;
	uint cursor_line = (uint)(start.get_int("line") ?? 0);
	uint cursor_col = (uint)(start.get_int("character") ?? 0);
	long cursor_offset = document::position_to_byte_offset(doc.content, cursor_line, cursor_col);
	if (cursor_offset < 0) return null;

	// Find smallest IF_EXPR containing cursor.
	uint if_idx = uint.max;
	uint best_span = uint.max;
	for (uint i = 1; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IF_EXPR) continue;
		if ((uint)cursor_offset < n.start_offset || (uint)cursor_offset >= n.end_offset) continue;
		uint span = n.end_offset - n.start_offset;
		if (span < best_span) {
			best_span = span;
			if_idx = i;
		}
	}
	if (if_idx == uint.max) return null;

	AstNode* iff = &ast.nodes[if_idx];

	// Collect children: cond, then, else.
	uint cond_idx = ast::NO_PARENT;
	uint then_idx = ast::NO_PARENT;
	uint else_idx = ast::NO_PARENT;
	uint child_seen = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != if_idx) continue;
		if (ast.nodes[c].kind == ANNOTATION_ENTRY) continue;
		if (child_seen == 0) {
			cond_idx = c;
		} else if (child_seen == 1) {
			then_idx = c;
		} else if (child_seen == 2) {
			else_idx = c;
		} else {
			return null;
		}
		child_seen++;
	}
	if (cond_idx == ast::NO_PARENT) return null;
	if (then_idx == ast::NO_PARENT) return null;
	if (else_idx == ast::NO_PARENT) return null;

	// Cond must be BINARY_EXPR with op `==` or `!=`.
	AstNode* cond = &ast.nodes[cond_idx];
	if (cond.kind != BINARY_EXPR) return null;
	bool is_ne;
	if (cond.extra_text == "!=") {
		is_ne = true;
	} else if (cond.extra_text == "==") {
		is_ne = false;
	} else {
		return null;
	}

	// Cond children: lhs, rhs.
	uint cond_lhs = ast::NO_PARENT;
	uint cond_rhs = ast::NO_PARENT;
	uint cseen = 0;
	for (uint c = 0; c < ast.node_count; c++) {
		if (ast.nodes[c].parent != cond_idx) continue;
		if (cseen == 0) {
			cond_lhs = c;
		} else if (cseen == 1) {
			cond_rhs = c;
		} else {
			return null;
		}
		cseen++;
	}
	if (cond_lhs == ast::NO_PARENT) return null;
	if (cond_rhs == ast::NO_PARENT) return null;

	// One side must be NAME_EXPR, the other LITERAL_EXPR `null`.
	String name_text = "";
	if (ast.nodes[cond_lhs].kind == NAME_EXPR
		&& ast.nodes[cond_rhs].kind == LITERAL_EXPR
		&& ast.nodes[cond_rhs].extra_text == "null") {
		name_text = ast.nodes[cond_lhs].name;
	} else if (ast.nodes[cond_rhs].kind == NAME_EXPR
		&& ast.nodes[cond_lhs].kind == LITERAL_EXPR
		&& ast.nodes[cond_lhs].extra_text == "null") {
		name_text = ast.nodes[cond_rhs].name;
	} else {
		return null;
	}
	if (name_text.len == 0) return null;

	// Unwrap branches (strip BLOCK if single-stmt).
	uint then_inner = null_passthrough_unwrap(ast, then_idx);
	uint else_inner = null_passthrough_unwrap(ast, else_idx);
	if (then_inner == ast::NO_PARENT) return null;
	if (else_inner == ast::NO_PARENT) return null;

	// Determine which branch is name and which is null based on op.
	// `x != null` → then=x, else=null. `x == null` → then=null, else=x.
	uint name_branch = is_ne ? then_inner : else_inner;
	uint null_branch = is_ne ? else_inner : then_inner;

	if (ast.nodes[name_branch].kind != NAME_EXPR) return null;
	if (ast.nodes[name_branch].name != name_text) return null;
	if (ast.nodes[null_branch].kind != LITERAL_EXPR) return null;
	if (ast.nodes[null_branch].extra_text != "null") return null;

	// Comment guard.
	if (range_has_comment(doc.content, iff.start_offset, iff.end_offset)) return null;

	uint start_line; uint start_col;
	uint end_line; uint end_col;
	offset_to_line_col(doc.content, iff.start_offset, &start_line, &start_col);
	offset_to_line_col(doc.content, iff.end_offset, &end_line, &end_col);

	Object* edit_range = object::new_obj(tmem);
	Object* es = object::new_obj(tmem);
	es.set("line", (int)start_line);
	es.set("character", (int)start_col);
	Object* ee = object::new_obj(tmem);
	ee.set("line", (int)end_line);
	ee.set("character", (int)end_col);
	edit_range.set("start", es);
	edit_range.set("end", ee);

	Object* edit = object::new_obj(tmem);
	edit.set("range", edit_range);
	edit.set("newText", name_text);

	Object* edits = object::new_obj(tmem);
	edits.push(edit);
	Object* changes = object::new_obj(tmem);
	changes.set(uri, edits);
	Object* workspace_edit = object::new_obj(tmem);
	workspace_edit.set("changes", changes);

	Object* action = object::new_obj(tmem);
	action.set("title", "Simplify null pass-through to expression");
	action.set("kind", "refactor.rewrite");
	action.set("edit", workspace_edit);
	return action;
}
