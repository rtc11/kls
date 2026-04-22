module kls::test::code_actions_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::workspace;

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Build diagnostics for the given content (lex + parse + unused imports).
 */
fn Object* build_test_diagnostics(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	return diagnostics::build_diagnostics_array(content, pr);
}

/**
 * Build codeAction params with diagnostics for the given content.
 * Computes diagnostics via the diagnostics module, then builds a
 * codeAction request covering the full document.
 */
fn Object* make_code_action_params(String uri, Object* diags) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	// Full-document range (large enough to cover any file)
	Object* start = object::new_obj(tmem);
	start.set("line", 0);
	start.set("character", 0);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", 999);
	end_pos.set("character", 0);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

/**
 * Build codeAction params with an "only" filter for code action kinds.
 */
fn Object* make_filtered_params(String uri, Object* diags, String[] only_kinds) {
	Object* params = make_code_action_params(uri, diags);
	Object* context = params.get("context")!!;

	Object* only = object::new_obj(tmem);
	for (usz i = 0; i < only_kinds.len; i++) {
		only.push(object::new_string(only_kinds[i], tmem));
	}
	context.set("only", only);
	return params;
}

/**
 * Build codeAction params with source.organizeImports filter (no diagnostics needed).
 */
fn Object* make_code_action_params_source(String uri) {
	Object* diags = object::new_obj(tmem); // empty array
	String[1] only = { "source.organizeImports" };
	return make_filtered_params(uri, diags, only[:1]); 
}

fn String get_action_title(Object* actions, usz index) {
	return actions.get_at(index).get_string("title")!!;
}

fn String get_action_kind(Object* actions, usz index) {
	return actions.get_at(index).get_string("kind")!!;
}

fn Object* get_action_edit(Object* actions, usz index) {
	return actions.get_at(index).get("edit")!!;
}

fn Object* get_edits_for_uri(Object* workspace_edit, String uri) {
	Object* changes = workspace_edit.get("changes")!!;
	return changes.get(uri) ?? null;
}

fn int get_edit_start_line(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	return edit.get("range")!!.get("start")!!.get_int("line")!!;
}

fn int get_edit_start_col(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	return edit.get("range")!!.get("start")!!.get_int("character")!!;
}

fn int get_edit_end_line(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	return edit.get("range")!!.get("end")!!.get_int("line")!!;
}

fn int get_edit_end_col(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	return edit.get("range")!!.get("end")!!.get_int("character")!!;
}

fn String get_edit_new_text(Object* edits, usz index) {
	Object* edit = edits.get_at(index);
	return edit.get_string("newText")!!;
}

/**
 * Build codeAction params with a specific selection range (for extract variable tests).
 */
fn Object* make_extract_params(String uri, int start_line, int start_col, int end_line, int end_col) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* start = object::new_obj(tmem);
	start.set("line", start_line);
	start.set("character", start_col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", end_line);
	end_pos.set("character", end_col);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* diags = object::new_obj(tmem);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

// ── Test: empty diagnostics ─────────────────────────────────────

fn void empty_diagnostics_returns_no_actions() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

		Object* diags = object::new_obj(tmem);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.is_indexable());
		assert(result.get_len() == 0, "expected 0 actions, got %d", (int)result.get_len());
	};
}

// ── Test: valid code produces no actions ─────────────────────────

fn void valid_code_no_actions() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() { val _x = 42 }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		// Cursor-style empty selection (no extract refactor offered)
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* range = params.get("range")!!;
		Object* end_pos = range.get("end")!!;
		end_pos.set("line", 0);
		end_pos.set("character", 0);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.is_indexable());
		assert(result.get_len() == 0, "expected 0 actions for valid code, got %d", (int)result.get_len());
	};
}

// ── Test: unused import quickfix ─────────────────────────────────

fn void unused_import_returns_remove_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		assert(diags.get_len() == 1, "expected 1 diagnostic, got %d", (int)diags.get_len());

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.is_indexable());
		// 1 quickfix + 1 organize imports (server-side)
		assert(result.get_len() == 2, "expected 2 actions, got %d", (int)result.get_len());

		String title = get_action_title(result, 0);
		assert(title == "Remove unused import", "expected 'Remove unused import', got '%s'", title);

		String kind = get_action_kind(result, 0);
		assert(kind == "quickfix", "expected 'quickfix', got '%s'", kind);
	};
}

// ── Test: unused import edit deletes the line ────────────────────

fn void unused_import_edit_deletes_full_line() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.get_len() >= 1);

		Object* workspace_edit = get_action_edit(result, 0);
		Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
		assert(edits != null, "expected edits for file:///test.kt");
		assert(edits.get_len() == 1, "expected 1 edit, got %d", (int)edits.get_len());

		// Should delete from line 0, col 0 to line 1, col 0 (entire first line)
		assert(get_edit_start_line(edits, 0) == 0, "expected start line 0");
		assert(get_edit_start_col(edits, 0) == 0, "expected start col 0");
		assert(get_edit_end_line(edits, 0) == 1, "expected end line 1");
		assert(get_edit_end_col(edits, 0) == 0, "expected end col 0");
		assert(get_edit_new_text(edits, 0) == "", "expected empty newText");
	};
}

// ── Test: unused import is preferred ─────────────────────────────

fn void unused_import_action_is_preferred() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.get_len() >= 1);

		Object* action = result.get_at(0);
		bool preferred = action.get_bool("isPreferred") ?? false;
		assert(preferred, "expected isPreferred to be true");
	};
}

// ── Test: two unused imports also returns organize-imports ────────

fn void two_unused_imports_returns_organize_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
import com.example.Bar
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		assert(diags.get_len() == 2, "expected 2 diagnostics, got %d", (int)diags.get_len());

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.is_indexable());
		// 2 individual "Remove unused import" + 1 "Remove all unused imports"
		assert(result.get_len() == 3, "expected 3 actions, got %d", (int)result.get_len());

		// First two should be quickfixes
		assert(get_action_kind(result, 0) == "quickfix");
		assert(get_action_kind(result, 1) == "quickfix");

		// Third should be organize imports
		String title = get_action_title(result, 2);
		assert(title == "Remove all unused imports", "expected 'Remove all unused imports', got '%s'", title);
		assert(get_action_kind(result, 2) == "source.organizeImports");

		// The organize action should have 2 edits (one per import line)
		Object* workspace_edit = get_action_edit(result, 2);
		Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
		assert(edits != null);
		assert(edits.get_len() == 2, "expected 2 edits in organize action, got %d", (int)edits.get_len());
	};
}

// ── Test: single unused import ALSO gets organize action ─────────

fn void single_unused_import_also_has_organize_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// 1 quickfix + 1 organize imports (computed server-side)
		assert(result.get_len() == 2, "expected 2 actions, got %d", (int)result.get_len());
		assert(get_action_kind(result, 0) == "quickfix");
		assert(get_action_kind(result, 1) == "source.organizeImports");
	};
}

// ── Test: organize imports works with empty client diagnostics ───

fn void organize_imports_works_without_cursor_on_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
import com.example.Bar
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Client sends NO diagnostics (cursor is on line 2, not on imports)
		Object* empty_diags = object::new_obj(tmem);
		Object* params = make_code_action_params("file:///test.kt", empty_diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Should still get the organize imports action (computed server-side)
		assert(result.is_array());
		assert(result.get_len() == 1, "expected 1 organize action, got %d", (int)result.get_len());
		assert(get_action_kind(result, 0) == "source.organizeImports");
		assert(get_action_title(result, 0) == "Remove all unused imports");

		// Verify the edit removes both import lines
		Object* workspace_edit = get_action_edit(result, 0);
		Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
		assert(edits != null);
		assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());
	};
}

// ── Test: & is valid (intersection type operator), no fix offered ──

fn void replace_ampersand_with_double_ampersand() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = true & false";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		// '&' is now a valid token (intersection type operator), no diagnostic expected
		bool found_ampersand = false;
		for (sz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			if (msg.contains("'&'")) found_ampersand = true;
		}
		assert(!found_ampersand, "& should not produce a diagnostic");
	};
}

// ── Test: replace | with || ──────────────────────────────────────

fn void replace_pipe_with_double_pipe() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = true | false";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		bool found_pipe = false;
		for (sz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			if (msg.contains("'|'")) found_pipe = true;
		}
		assert(found_pipe, "expected diagnostic for '|'");

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found_fix = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Replace '|' with '||'") {
				found_fix = true;

				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				assert(edits.get_len() == 1);
				assert(get_edit_new_text(edits, 0) == "||", "expected '||'");
				break;
			}
		}
		assert(found_fix, "expected 'Replace | with ||' action");
	};
}

// ── Test: insert missing close paren ─────────────────────────────

fn void insert_missing_close_paren() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo(x: Int {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		// Find a diagnostic with "Expected ')'"
		bool found_paren_diag = false;
		for (sz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			if (msg.starts_with("Expected ')'")) found_paren_diag = true;
		}
		assert(found_paren_diag, "expected parser diagnostic for missing ')'");

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found_fix = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Insert missing ')'") {
				found_fix = true;
				String kind = get_action_kind(result, (usz)i);
				assert(kind == "quickfix");

				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				assert(edits.get_len() == 1);
				assert(get_edit_new_text(edits, 0) == ")");
				// Insert range should be zero-width
				assert(get_edit_start_line(edits, 0) == get_edit_end_line(edits, 0));
				assert(get_edit_start_col(edits, 0) == get_edit_end_col(edits, 0));
				break;
			}
		}
		assert(found_fix, "expected 'Insert missing )' action");
	};
}

// ── Test: insert missing close brace ─────────────────────────────

fn void insert_missing_close_brace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Foo {";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		bool found_brace_diag = false;
		for (sz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			if (msg.starts_with("Expected '}'")) found_brace_diag = true;
		}
		assert(found_brace_diag, "expected parser diagnostic for missing '}'");

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found_fix = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Insert missing '}'") {
				found_fix = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				assert(get_edit_new_text(edits, 0) == "}");
				break;
			}
		}
		assert(found_fix, "expected 'Insert missing }' action");
	};
}

// ── Test: no action for non-delimiter expected token ─────────────

fn void no_action_for_expected_identifier() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Construct a diagnostic manually for "Expected identifier"
		String content = "fun main() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Build a fake diagnostic with "Expected identifier, got ..."
		Object* diag = object::new_obj(tmem);
		Object* range = object::new_obj(tmem);
		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 0);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 1);
		range.set("start", start);
		range.set("end", end_pos);
		diag.set("range", range);
		diag.set("severity", 1);
		diag.set("source", "kls");
		diag.set("message", "Expected identifier, got '{'");

		Object* diags = object::new_obj(tmem);
		diags.push(diag);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// "Expected identifier" should NOT trigger any code action
		// (because "identifier" is not a closing delimiter)
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.starts_with("Insert missing"),
				"should not offer insert for non-delimiter, got '%s'", title);
		}
	};
}

// ── Test: only filter - quickfix ─────────────────────────────────

fn void only_filter_quickfix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
import com.example.Bar
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		assert(diags.get_len() == 2, "expected 2 diagnostics");

		String[1] only = { "quickfix" };
		Object* params = make_filtered_params("file:///test.kt", diags, only[0..0]);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Should only return quickfix actions, not organize imports
		for (sz i = 0; i < result.get_len(); i++) {
			String kind = get_action_kind(result, (usz)i);
			assert(kind == "quickfix", "expected only quickfix kind, got '%s'", kind);
		}
	};
}

// ── Test: only filter - source ───────────────────────────────────

fn void only_filter_source_organize_imports() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
import com.example.Bar
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);

		String[1] only = { "source.organizeImports" };
		Object* params = make_filtered_params("file:///test.kt", diags, only[0..0]);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Should only return source.organizeImports actions, not individual quickfixes
		assert(result.get_len() == 1, "expected 1 organize action, got %d", (int)result.get_len());
		assert(get_action_kind(result, 0) == "source.organizeImports");
	};
}

// ── Test: action links back to diagnostics ───────────────────────

fn void action_links_to_diagnostics() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		assert(result.get_len() >= 1);

		Object* action = result.get_at(0);
		Object* action_diags = action.get("diagnostics") ?? null;
		assert(action_diags != null, "expected diagnostics array in action");
		assert(action_diags.is_array());
		assert(action_diags.get_len() == 1, "expected 1 linked diagnostic");
	};
}

// ── Test: unrecognized character gets no fix ─────────────────────

fn void unrecognized_character_no_fix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Build a fake diagnostic for an unrecognized char like '~'
		String content = "val x = ~1";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diag = object::new_obj(tmem);
		Object* range = object::new_obj(tmem);
		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 8);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 9);
		range.set("start", start);
		range.set("end", end_pos);
		diag.set("range", range);
		diag.set("severity", 1);
		diag.set("source", "kls");
		diag.set("message", "Unexpected character: '~'");

		Object* diags = object::new_obj(tmem);
		diags.push(diag);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Should not offer any fix for '~' (not & or |)
		// Result should have 0 actions
		assert(result != null);
		if (result.is_array()) {
			for (sz i = 0; i < result.get_len(); i++) {
				String title = get_action_title(result, (usz)i);
				assert(!title.contains("Replace"), "should not offer replacement for '~', got '%s'", title);
			}
		}
	};
}

// ── Test: only filter with "source" parent matches organizeImports ─

fn void only_filter_source_parent_matches_organize() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `import com.example.Foo
import com.example.Bar
fun main() { val _x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);

		// Filter with just "source" should also match "source.organizeImports"
		String[1] only = { "source" };
		Object* params = make_filtered_params("file:///test.kt", diags, only[0..0]);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Should return the organize imports action
		assert(result.get_len() == 1, "expected 1 action with 'source' filter, got %d", (int)result.get_len());
		assert(get_action_kind(result, 0) == "source.organizeImports");
	};
}

// ── Test: operator fix isPreferred ───────────────────────────────

fn void operator_fix_is_preferred() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = true & false";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = build_test_diagnostics(content);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title.contains("Replace")) {
				Object* action = result.get_at(i);
				bool preferred = action.get_bool("isPreferred") ?? false;
				assert(preferred, "operator fix should be isPreferred");
				break;
			}
		}
	};
}

// ── Test: import action for unresolved reference (diagnostic-driven) ──

fn void unresolved_reference_offers_import_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// KClass is from kotlin.reflect (not auto-imported)
		String content = `fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Build diagnostics with workspace so we get "Unresolved reference: 'KClass'"
		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		// Find the unresolved reference diagnostic
		bool found_diag = false;
		for (usz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			if (msg == "Unresolved reference: 'KClass'") {
				found_diag = true;
				break;
			}
		}
		assert(found_diag, "expected 'Unresolved reference: KClass' diagnostic");

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should have at least one "Import 'kotlin.reflect.KClass'" action
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				found_import = true;
				String kind = get_action_kind(result, (usz)i);
				assert(kind == "quickfix", "expected quickfix kind, got '%s'", kind);

				// Verify the edit inserts "import kotlin.reflect.KClass\n"
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null, "expected edits for file");
				assert(edits.get_len() == 1);
				String new_text = get_edit_new_text(edits, 0);
				assert(new_text.contains("import kotlin.reflect.KClass"),
					"expected import text, got '%s'", new_text);
				break;
			}
		}
		assert(found_import, "expected 'Import kotlin.reflect.KClass' action");
	};
}

// ── Test: no import action when already imported ─────────────────

fn void already_imported_no_import_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// KClass is already imported -- no import action should be offered
		String content = `import kotlin.reflect.KClass
fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = object::new_obj(tmem); // empty diagnostics
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.contains("Import 'kotlin.reflect.KClass'"),
				"should not offer import when already imported, got '%s'", title);
		}
	};
}

// ── Test: import insertion after existing imports ─────────────────

fn void import_inserted_after_last_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String content = `import kotlin.io.println
fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				// Should insert at line 1 (after the existing import on line 0)
				assert(get_edit_start_line(edits, 0) == 1,
					"expected insert at line 1, got %d", get_edit_start_line(edits, 0));
				break;
			}
		}
	};
}

// ── Test: import insertion after package (no existing imports) ────

fn void import_inserted_after_package_when_no_imports() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String content = `package com.example
fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				// Should insert at line 1 (after package on line 0)
				assert(get_edit_start_line(edits, 0) == 1,
					"expected insert at line 1 after package, got %d", get_edit_start_line(edits, 0));
				// The text should include a leading newline (blank line after package)
				String new_text = get_edit_new_text(edits, 0);
				assert(new_text.starts_with("\n"),
					"expected leading newline after package declaration");
				break;
			}
		}
	};
}

// ── Test: cursor-context import (no diagnostic needed) ───────────

fn void cursor_context_import_without_diagnostic() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String content = `fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// No diagnostics from the client -- but cursor is on KClass (col 21)
		Object* empty_diags = object::new_obj(tmem);

		// Build params with cursor position on "KClass"
		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21); // cursor on 'K' of KClass
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 21);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should offer import action even without diagnostics
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				found_import = true;
				break;
			}
		}
		assert(found_import, "expected import action from cursor context");
	};
}

// ── Test: auto-imported name gets no import action ───────────────

fn void auto_imported_name_no_import_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// "println" is auto-imported -- no import action should be offered
		String content = `fun main() { println("hello") }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 14); // cursor on 'p' of println
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 14);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.contains("Import"),
				"should not offer import for auto-imported name, got '%s'", title);
		}
	};
}

// ── Test: import action links to diagnostic ──────────────────────

fn void import_action_links_to_diagnostic() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String content = `fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				Object* action = result.get_at(i);
				Object* action_diags = action.get("diagnostics") ?? null;
				assert(action_diags != null, "expected diagnostics array in import action");
				assert(action_diags.is_array());
				assert(action_diags.get_len() == 1, "expected 1 linked diagnostic");
				break;
			}
		}
	};
}

// ── Test: wildcard import prevents import action ─────────────────

fn void wildcard_import_prevents_import_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// Wildcard import covers kotlin.reflect -- no import action needed
		String content = `import kotlin.reflect.*
fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* diags = object::new_obj(tmem);
		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.contains("Import 'kotlin.reflect.KClass'"),
				"should not offer import when wildcard import covers the package");
		}
	};
}

// ── Test: cursor on dot member walks back to receiver and offers import ──

fn void cursor_on_dot_member_offers_receiver_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		//                    0         1         2         3
		//                    0123456789012345678901234567890123456789
		String content = `fun main() { val c = KClass.foo() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// No diagnostics from the client -- cursor is on "foo" (col 28)
		Object* empty_diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 28); // cursor on 'f' of foo
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 28);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should offer import for KClass (the receiver) even though cursor is on foo
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				found_import = true;
				break;
			}
		}
		assert(found_import, "expected import action for receiver KClass when cursor is on dot member");
	};
}

// ── Test: cursor on receiver still works (not broken by dot-receiver logic) ──

fn void cursor_on_receiver_still_offers_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		//                    0         1         2
		//                    0123456789012345678901234567
		String content = `fun main() { val c = KClass.foo() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "KClass" (col 21)
		Object* empty_diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21); // cursor on 'K' of KClass
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 21);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should offer import for KClass directly
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				found_import = true;
				break;
			}
		}
		assert(found_import, "expected import action for KClass when cursor is on receiver");
	};
}

// ── Test: cursor on dot member with safe call (?.) walks back to receiver ──

fn void cursor_on_safe_call_member_offers_receiver_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		//                    0         1         2         3
		//                    0123456789012345678901234567890123456789
		String content = `fun main() { val c = KClass?.foo() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "foo" (col 29, after "KClass?.")
		Object* empty_diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 29); // cursor on 'f' of foo
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 29);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should offer import for KClass (the receiver before ?.)
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'kotlin.reflect.KClass'") {
				found_import = true;
				break;
			}
		}
		assert(found_import, "expected import action for receiver KClass when cursor is on safe-call member");
	};
}

// ── Test: dot member of locally declared name does NOT offer import ──

fn void cursor_on_dot_member_of_local_no_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// "myVar" is declared locally, so its import should not be offered
		String content = `fun main() { val myVar = 1; myVar.foo() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "foo" (col 34)
		Object* empty_diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 34); // cursor on 'f' of foo
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 34);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should NOT offer any import — receiver myVar is in scope
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.starts_with("Import '"),
				"should not offer import when receiver is locally declared");
		}
	};
}

// ── Test: JDK class UUID gets unresolved diagnostic and import action ──

fn void jdk_uuid_gets_import_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// UUID is from java.util (not auto-imported, requires explicit import)
		String content = `fun main() { val id = UUID.randomUUID() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Build diagnostics with workspace so we get "Unresolved reference: 'UUID'"
		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		// Find the unresolved reference diagnostic
		bool found_diag = false;
		for (usz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			if (msg == "Unresolved reference: 'UUID'") {
				found_diag = true;
				break;
			}
		}
		assert(found_diag, "expected 'Unresolved reference: UUID' diagnostic");

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should have "Import 'java.util.UUID'" action
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'java.util.UUID'") {
				found_import = true;
				String kind = get_action_kind(result, (usz)i);
				assert(kind == "quickfix", "expected quickfix kind");

				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null, "expected edits for file");
				assert(edits.get_len() == 1);
				String new_text = get_edit_new_text(edits, 0);
				assert(new_text.contains("import java.util.UUID"),
					"expected import text, got '%s'", new_text);
				break;
			}
		}
		assert(found_import, "expected 'Import java.util.UUID' action");
	};
}

// ── Test: JDK class File gets import action via cursor context ──

fn void jdk_file_cursor_context_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String content = `fun main() { val f = File("/tmp") }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// No diagnostics from client -- cursor on File (col 21)
		Object* empty_diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21); // cursor on 'F' of File
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 21);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should offer import action for java.io.File
		bool found_import = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Import 'java.io.File'") {
				found_import = true;
				break;
			}
		}
		assert(found_import, "expected import action for java.io.File from cursor context");
	};
}

// ── Test: java.lang.Thread is auto-imported -- no import action ──

fn void jdk_java_lang_no_import_action() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// Thread is from java.lang (auto-imported) -- no import should be offered
		String content = `fun main() { val t = Thread.currentThread() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// No diagnostics from client -- cursor on Thread (col 21)
		Object* empty_diags = object::new_obj(tmem);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21); // cursor on 'T' of Thread
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 21);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", empty_diags);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		// Should NOT offer any import for Thread (it's from java.lang, auto-imported)
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.contains("java.lang.Thread"),
				"should not offer import for java.lang.Thread (auto-imported), got '%s'", title);
		}
	};
}

// ── Test: extract variable from binary expression ────────────────

fn void extract_variable_from_binary_expr() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		//                    0         1         2
		//                    0123456789012345678901234567
		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select "1 + 2" (col 21 to col 26)
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 26);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract variable") {
				found = true;
				String kind = get_action_kind(result, (usz)i);
				assert(kind == "refactor.extract.variable", "expected refactor.extract.variable, got '%s'", kind);

				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

				// Edit 1: insert "val extractedVar = 1 + 2\n" before statement
				String insert_text = get_edit_new_text(edits, 0);
				assert(insert_text.contains("val extractedVar = 1 + 2"),
					"expected insert text, got '%s'", insert_text);

				// Edit 2: replace expression with "extractedVar"
				String replace_text = get_edit_new_text(edits, 1);
				assert(replace_text == "extractedVar",
					"expected 'extractedVar', got '%s'", replace_text);
				break;
			}
		}
		assert(found, "expected 'Extract variable' action");
	};
}

// ── Test: extract variable from call expression ─────────────────

fn void extract_variable_from_call_expr() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		//                    0         1         2         3
		//                    0123456789012345678901234567890123456
		String content = `fun main() { println(foo()) }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select "foo()" (col 21 to col 26)
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 26);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract variable") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				String insert_text = get_edit_new_text(edits, 0);
				assert(insert_text.contains("val extractedVar = foo()"),
					"expected insert text with foo(), got '%s'", insert_text);
				break;
			}
		}
		assert(found, "expected 'Extract variable' action for call expression");
	};
}

// ── Test: no extract variable for single name ───────────────────

fn void no_extract_variable_for_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = y }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select "y" (col 21 to col 22)
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 22);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract variable",
				"should not offer extract for single name reference");
		}
	};
}

// ── Test: no extract variable for empty selection ───────────────

fn void no_extract_variable_for_empty_selection() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Empty selection (same start and end)
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 21);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract variable",
				"should not offer extract for empty selection");
		}
	};
}

// ── Test: no extract variable for partial selection ─────────────

fn void no_extract_variable_for_partial_selection() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select "1 +" (col 21 to col 24) — doesn't match any expression node
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 24);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract variable",
				"should not offer extract for partial selection");
		}
	};
}

// ── Test: extract variable preserves indentation ────────────────

fn void extract_variable_preserves_indentation() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() {\n    val x = 1 + 2\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "    val x = 1 + 2"
		//          0         1
		//          0123456789012345678
		// "1 + 2" starts at col 12, ends at col 17 (exclusive)
		Object* params = make_extract_params("file:///test.kt", 1, 12, 1, 17);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract variable") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				String insert_text = get_edit_new_text(edits, 0);
				// Should have "val extractedVar = 1 + 2\n    " (preserving 4-space indent)
				assert(insert_text.contains("val extractedVar = 1 + 2\n    "),
					"expected preserved indentation, got '%s'", insert_text);
				break;
			}
		}
		assert(found, "expected 'Extract variable' action with preserved indent");
	};
}

// ── Test: extract variable only filter ──────────────────────────

fn void extract_variable_only_filter() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Build params with only "refactor" filter
		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 26);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* diags = object::new_obj(tmem);

		Object* only = object::new_obj(tmem);
		only.push(object::new_string("refactor", tmem));

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", diags);
		context.set("only", only);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		// Should include extract variable (refactor.extract.variable matches "refactor")
		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract variable") {
				found = true;
				break;
			}
		}
		assert(found, "expected extract variable with 'refactor' only filter");
	};
}

// ── Test: extract variable filtered out by quickfix only ────────

fn void extract_variable_filtered_out_by_quickfix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 26);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* diags = object::new_obj(tmem);

		Object* only = object::new_obj(tmem);
		only.push(object::new_string("quickfix", tmem));

		Object* context = object::new_obj(tmem);
		context.set("diagnostics", diags);
		context.set("only", only);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract variable",
				"extract variable should be filtered out by 'quickfix' only filter");
		}
	};
}

// ── Test: extract function from expression ──────────────────────

fn void extract_function_from_expression() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		//                    0         1         2
		//                    0123456789012345678901234567
		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select "1 + 2" (col 21 to col 26)
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 26);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract function") {
				found = true;
				String kind = get_action_kind(result, (usz)i);
				assert(kind == "refactor.extract.function", "expected refactor.extract.function, got '%s'", kind);

				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

				// Edit 1: replace expression with "extracted()"
				String replace_text = get_edit_new_text(edits, 0);
				assert(replace_text == "extracted()",
					"expected 'extracted()', got '%s'", replace_text);

				// Edit 2: insert function definition
				String insert_text = get_edit_new_text(edits, 1);
				assert(insert_text.contains("private fun extracted() = 1 + 2"),
					"expected function definition, got '%s'", insert_text);
				break;
			}
		}
		assert(found, "expected 'Extract function' action");
	};
}

// ── Test: extract function from statement block ─────────────────

fn void extract_function_from_statements() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() {\n    val y = 10\n    println(y)\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select lines 1-2 covering both statements
		// Line 1: "    val y = 10"  (14 chars)
		// Line 2: "    println(y)"  (14 chars)
		Object* params = make_extract_params("file:///test.kt", 1, 0, 2, 14);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract function") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);

				// Should have 2 edits: replace + insert
				assert(edits.get_len() == 2, "expected 2 edits, got %d", (int)edits.get_len());

				// The inserted function should contain "private fun extracted"
				String insert_text = get_edit_new_text(edits, 1);
				assert(insert_text.contains("private fun extracted"),
					"expected function definition, got '%s'", insert_text);
				break;
			}
		}
		assert(found, "expected 'Extract function' action for statements");
	};
}

// ── Test: extract function with parameters ──────────────────────

fn void extract_function_with_parameters() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun calc(x: Int) {\n    val result = x + 1\n    println(result)\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select line 1: "    val result = x + 1" — uses parameter 'x' from enclosing fun
		// Line 1: "    val result = x + 1"
		//          0         1         2
		//          0123456789012345678901
		Object* params = make_extract_params("file:///test.kt", 1, 0, 1, 22);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Extract function") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");

				// The inserted function should have 'x' as parameter
				String insert_text = get_edit_new_text(edits, 1);
				assert(insert_text.contains("x: Int"),
					"expected parameter 'x: Int' in function, got '%s'", insert_text);

				// The call should pass 'x' as argument
				String call_text = get_edit_new_text(edits, 0);
				assert(call_text.contains("extracted(x)"),
					"expected call with 'x' arg, got '%s'", call_text);
				break;
			}
		}
		assert(found, "expected 'Extract function' with parameter");
	};
}

// ── Test: no extract function for empty selection ───────────────

fn void no_extract_function_for_empty_selection() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 21);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract function",
				"should not offer extract function for empty selection");
		}
	};
}

// ── Test: no extract function for NAME_EXPR ─────────────────────

fn void no_extract_function_for_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = y }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Select "y" (col 21 to col 22)
		Object* params = make_extract_params("file:///test.kt", 0, 21, 0, 22);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract function",
				"should not offer extract function for single name");
		}
	};
}

// ── Test: extract function action kind filter ───────────────────

fn void extract_function_filtered_by_quickfix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 1 + 2 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 21);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 26);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* diags = object::new_obj(tmem);
		Object* only = object::new_obj(tmem);
		only.push(object::new_string("quickfix", tmem));
		Object* context = object::new_obj(tmem);
		context.set("diagnostics", diags);
		context.set("only", only);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Extract function",
				"extract function should be filtered out by 'quickfix' only filter");
		}
	};
}

// ── Test: generate toString for data class ──────────────────────

fn void generate_to_string_for_data_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "data class User(val name: String, val age: Int) {\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor inside class (line 0, col 20)
		Object* params = make_extract_params("file:///test.kt", 0, 20, 0, 20);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Generate toString()") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("override fun toString()"),
					"expected toString override, got '%s'", text);
				assert(text.contains("User(name=$name, age=$age)"),
					"expected property interpolation, got '%s'", text);
				break;
			}
		}
		assert(found, "expected 'Generate toString()' action for data class");
	};
}

// ── Test: generate equals for data class ────────────────────────

fn void generate_equals_for_data_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "data class User(val name: String, val age: Int) {\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 20, 0, 20);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Generate equals()") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("override fun equals(other: Any?)"),
					"expected equals override, got '%s'", text);
				assert(text.contains("other !is User"),
					"expected type check, got '%s'", text);
				assert(text.contains("name == other.name"),
					"expected property comparison, got '%s'", text);
				assert(text.contains("age == other.age"),
					"expected property comparison, got '%s'", text);
				break;
			}
		}
		assert(found, "expected 'Generate equals()' action for data class");
	};
}

// ── Test: generate hashCode for data class ──────────────────────

fn void generate_hash_code_for_data_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "data class User(val name: String, val age: Int) {\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 20, 0, 20);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Generate hashCode()") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("override fun hashCode(): Int"),
					"expected hashCode override, got '%s'", text);
				assert(text.contains("name.hashCode()"),
					"expected property hashCode, got '%s'", text);
				assert(text.contains("31 * result + age.hashCode()"),
					"expected combined hashCode, got '%s'", text);
				break;
			}
		}
		assert(found, "expected 'Generate hashCode()' action for data class");
	};
}

// ── Test: no generate for non-data class ────────────────────────

fn void no_generate_for_non_data_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class User(val name: String) {\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 15, 0, 15);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.starts_with("Generate"),
				"should not offer generate for non-data class, got '%s'", title);
		}
	};
}

// ── Test: no generate when method already exists ────────────────

fn void no_generate_when_already_exists() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "data class User(val name: String) {\n    override fun toString(): String = \"custom\"\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 20, 0, 20);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Generate toString()",
				"should not offer generate toString when already defined");
		}
	};
}

// ── Test: generate all three for data class ─────────────────────

fn void generate_all_three_for_data_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "data class Point(val x: Int, val y: Int) {\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 20, 0, 20);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found_to_string = false;
		bool found_equals = false;
		bool found_hash_code = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Generate toString()") found_to_string = true;
			if (title == "Generate equals()") found_equals = true;
			if (title == "Generate hashCode()") found_hash_code = true;
		}
		assert(found_to_string, "expected Generate toString()");
		assert(found_equals, "expected Generate equals()");
		assert(found_hash_code, "expected Generate hashCode()");
	};
}

// ── Test: convert function to expression body ───────────────────

fn void convert_fun_to_expression_body() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun add(a: Int, b: Int): Int { return a + b }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on function (col 5)
		Object* params = make_extract_params("file:///test.kt", 0, 5, 0, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Convert to expression body") {
				found = true;
				String kind = get_action_kind(result, (usz)i);
				assert(kind == "refactor.rewrite", "expected refactor.rewrite, got '%s'", kind);

				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("= a + b"),
					"expected '= a + b', got '%s'", text);
				break;
			}
		}
		assert(found, "expected 'Convert to expression body' action");
	};
}

// ── Test: no convert for multi-statement function ───────────────

fn void no_convert_for_multi_statement_fun() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() { val x = 1; return x }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 5, 0, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Convert to expression body",
				"should not offer convert for multi-statement function");
		}
	};
}

// ── Test: no convert for empty function ─────────────────────────

fn void no_convert_for_empty_fun() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 5, 0, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Convert to expression body",
				"should not offer convert for empty function");
		}
	};
}

// ── Test: convert for function with expression statement ────────

fn void convert_fun_with_expression_statement() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Single expression call — can be expression body
		String content = "fun greet() { println(\"hello\") }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_extract_params("file:///test.kt", 0, 5, 0, 5);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title == "Convert to expression body") {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("= println"),
					"expected expression body with println, got '%s'", text);
				break;
			}
		}
		assert(found, "expected 'Convert to expression body' for single expression");
	};
}

// ── Test: convert filtered by quickfix only ─────────────────────

fn void convert_expression_body_filtered_by_quickfix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun add(a: Int, b: Int): Int { return a + b }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* td = object::new_obj(tmem);
		td.set("uri", "file:///test.kt");

		Object* start = object::new_obj(tmem);
		start.set("line", 0);
		start.set("character", 5);
		Object* end_pos = object::new_obj(tmem);
		end_pos.set("line", 0);
		end_pos.set("character", 5);
		Object* range = object::new_obj(tmem);
		range.set("start", start);
		range.set("end", end_pos);

		Object* diags = object::new_obj(tmem);
		Object* only = object::new_obj(tmem);
		only.push(object::new_string("quickfix", tmem));
		Object* context = object::new_obj(tmem);
		context.set("diagnostics", diags);
		context.set("only", only);

		Object* params = object::new_obj(tmem);
		params.set("textDocument", td);
		params.set("range", range);
		params.set("context", context);

		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(title != "Convert to expression body",
				"should be filtered out by quickfix only filter");
		}
	};
}

// ── Test: import all unresolved references ──────────────────────

fn void import_all_unresolved_references() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// Two unresolved references: KClass (kotlin.reflect) and Continuation (kotlin.coroutines)
		String content = "fun main() {\n    val c = KClass\n    val f = Continuation\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Build diagnostics
		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title.starts_with("Import all")) {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("import kotlin.reflect.KClass"),
					"expected KClass import, got '%s'", text);
				assert(text.contains("import kotlin.coroutines.Continuation"),
					"expected Continuation import, got '%s'", text);
				break;
			}
		}
		assert(found, "expected 'Import all' action for multiple unresolved references");
	};
}

// ── Test: no import all for single unresolved ───────────────────

fn void no_import_all_for_single_unresolved() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String content = `fun main() { val c = KClass }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		Object* params = make_code_action_params("file:///test.kt", diags);
		Object* result = code_actions::handle_code_action(&store, &workspace, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.starts_with("Import all"),
				"should not offer import all for single unresolved");
		}
	};
}

// ── Test: star import suggestion ────────────────────────────────

fn void star_import_suggestion() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// 3 imports from kotlin.reflect
		String content = "import kotlin.reflect.KClass\nimport kotlin.reflect.KFunction\nimport kotlin.reflect.KProperty\n\nfun main() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_code_action_params_source("file:///test.kt");
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			if (title.contains("import kotlin.reflect.*")) {
				found = true;
				Object* workspace_edit = get_action_edit(result, (usz)i);
				Object* edits = get_edits_for_uri(workspace_edit, "file:///test.kt");
				assert(edits != null);
				String text = get_edit_new_text(edits, 0);
				assert(text.contains("import kotlin.reflect.*"),
					"expected star import, got '%s'", text);
				break;
			}
		}
		assert(found, "expected star import suggestion for 3+ imports from same package");
	};
}

// ── Test: no star import for 2 imports ──────────────────────────

fn void no_star_import_for_two_imports() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Only 2 imports from kotlin.reflect
		String content = "import kotlin.reflect.KClass\nimport kotlin.reflect.KFunction\n\nfun main() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_code_action_params_source("file:///test.kt");
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		for (sz i = 0; i < result.get_len(); i++) {
			String title = get_action_title(result, (usz)i);
			assert(!title.contains("import kotlin.reflect.*"),
				"should not offer star import for only 2 imports");
		}
	};
}

// ── Test: java.lang.Thread no unresolved diagnostic ──

fn void jdk_java_lang_no_unresolved_diagnostic() @test {
	@pool() {
		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// Thread is from java.lang (auto-imported)
		String content = `fun main() { val t = Thread.currentThread() }`;

		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);
		Object* diags = diagnostics::build_diagnostics_array(content, pr, &workspace);

		// Should NOT have "Unresolved reference: 'Thread'" diagnostic
		for (usz i = 0; i < diags.get_len(); i++) {
			String msg = diags.get_at(i).get_string("message") ?? "";
			assert(msg != "Unresolved reference: 'Thread'",
				"should not flag Thread as unresolved (java.lang is auto-imported)");
		}
	};
}
