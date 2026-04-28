module kls::test::unused_param_qfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	return diagnostics::build_diagnostics_array(content, pr);
}

// Find first "Parameter 'x' is never used" diagnostic; return null if none.
fn Object* find_unused_param_diag(Object* diags) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.starts_with("Parameter '") && m.contains("is never used")) return d;
	}
	return null;
}

fn Object* make_params_with_diag(String uri, Object* diag) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* start = object::new_obj(tmem);
	start.set("line", 0);
	start.set("character", 0);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", 999);
	end_pos.set("character", 0);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* diags_arr = object::new_obj(tmem);
	diags_arr.push(diag);

	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags_arr);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

fn String find_action_title(Object* actions, String needle) {
	for (sz i = 0; i < actions.get_len(); i++) {
		String t = actions.get_at((usz)i).get_string("title") ?? "";
		if (t.contains(needle)) return t;
	}
	return "";
}

fn Object* find_action_with_title(Object* actions, String needle) {
	for (sz i = 0; i < actions.get_len(); i++) {
		Object* a = actions.get_at((usz)i);
		String t = a.get_string("title") ?? "";
		if (t.contains(needle)) return a;
	}
	return null;
}

fn String first_edit_new_text(Object* action, String uri) {
	Object* edit = action.get("edit") ?? null;
	if (edit == null) return "";
	Object* changes = edit.get("changes") ?? null;
	if (changes == null) return "";
	Object* edits = changes.get(uri) ?? null;
	if (edits == null) return "";
	if (edits.get_len() == 0) return "";
	return edits.get_at(0).get_string("newText") ?? "";
}

// ── Tests ──────────────────────────────────────────────────────

fn void rename_offered_for_unused_param() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(x: Int): Int { return 42 }\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		assert(d != null, "unused-param diag emitted");

		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;

		Object* action = find_action_with_title(res, "Rename to '_'");
		assert(action != null, "Rename to '_' action offered");

		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "_", "new text is underscore");
	};
}

fn void rename_marked_preferred() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(x: Int) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		assert(d != null, "diag exists");

		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Rename to '_'");
		assert(action != null, "action offered");

		bool preferred;
		if (try v = action.get_bool("isPreferred")) { preferred = v; }
		assert(preferred, "marked isPreferred");
	};
}

fn void rename_carries_diagnostic() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(unused: String) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Rename to '_'");
		assert(action != null, "action present");

		Object* attached = action.get("diagnostics") ?? null;
		assert(attached != null, "diagnostics attached");
		assert(attached.get_len() == 1, "exactly one diag attached");
	};
}

fn void rename_kind_is_quickfix() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(x: Int) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Rename to '_'");
		assert(action != null, "found");
		String kind = action.get_string("kind") ?? "";
		assert(kind == "quickfix", "kind is quickfix");
	};
}

fn void no_action_when_no_diag() @test {
	// Fully-used param => no diagnostic => dispatcher offers no rename action.
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(x: Int): Int { return x }\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		assert(find_unused_param_diag(diags) == null, "no unused-param diag");

		// Also feed a synthetic non-matching diag and confirm dispatcher
		// does not produce the rename action.
		Object* fake = object::new_obj(tmem);
		Object* range = object::new_obj(tmem);
		Object* s = object::new_obj(tmem); s.set("line", 0); s.set("character", 0);
		Object* e = object::new_obj(tmem); e.set("line", 0); e.set("character", 1);
		range.set("start", s); range.set("end", e);
		fake.set("range", range);
		fake.set("severity", 4);
		fake.set("source", "kls");
		fake.set("message", "Unrelated message");
		Object* params = make_params_with_diag(uri, fake);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		assert(find_action_with_title(res, "Rename to '_'") == null,
			"no rename action for unrelated diag");
	};
}

fn void rename_replaces_only_param_name() @test {
	// Apply the edit and verify the result has _ at the param name position
	// while leaving the surrounding text intact.
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(unused: String, y: Int): Int { return y }\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		assert(d != null, "diag");
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Rename to '_'");
		assert(action != null, "action");

		// Apply edit to the source text and check the result.
		Object* edit = action.get("edit") ?? null;
		Object* changes = edit.get("changes") ?? null;
		Object* edits = changes.get(uri) ?? null;
		Object* e = edits.get_at(0);
		Object* range = e.get("range") ?? null;
		Object* s = range.get("start") ?? null;
		int sl = s.get_int("line") ?? 0;
		int sc = s.get_int("character") ?? 0;
		Object* en = range.get("end") ?? null;
		int el = en.get_int("line") ?? 0;
		int ec = en.get_int("character") ?? 0;

		assert(sl == 0 && el == 0, "single-line edit");
		// "unused" starts at column 8 (after "fun foo(") and is 6 chars long.
		assert(sc == 8, "start col 8");
		assert(ec == 14, "end col 14");
	};
}

// ── Prefix-with-_ variant ──────────────────────────────────────

fn void prefix_offered_alongside_rename() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(event: String) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		assert(d != null, "diag");
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;

		assert(find_action_with_title(res, "Rename to '_'") != null, "rename present");
		assert(find_action_with_title(res, "Prefix with '_'") != null, "prefix present");
	};
}

fn void prefix_inserts_underscore_at_name_start() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(event: String) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Prefix with '_'");
		assert(action != null, "found");

		Object* edit = action.get("edit") ?? null;
		Object* changes = edit.get("changes") ?? null;
		Object* edits = changes.get(uri) ?? null;
		Object* e = edits.get_at(0);
		String new_text = e.get_string("newText") ?? "";
		assert(new_text == "_", "underscore");

		// Zero-width insertion at the name's start col (8 = after "fun foo(").
		Object* range = e.get("range") ?? null;
		Object* s = range.get("start") ?? null;
		Object* en = range.get("end") ?? null;
		int sc = s.get_int("character") ?? 0;
		int ec = en.get_int("character") ?? 0;
		assert(sc == 8, "starts at name col");
		assert(ec == 8, "zero width");
	};
}

fn void prefix_kind_quickfix_carries_diag() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(x: Int) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Prefix with '_'");
		assert(action != null, "found");
		String kind = action.get_string("kind") ?? "";
		assert(kind == "quickfix", "quickfix kind");
		Object* attached = action.get("diagnostics") ?? null;
		assert(attached != null && attached.get_len() == 1, "diag attached");
	};
}

fn void rename_preferred_over_prefix() @test {
	// The 'Rename to _' action remains the preferred one (auto-fix on save).
	@pool() {
		String uri = "file:///t.kt";
		String content = "fun foo(x: Int) {}\n";
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* diags = build_diags(content);
		Object* d = find_unused_param_diag(diags);
		Object* params = make_params_with_diag(uri, d);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;

		Object* rename = find_action_with_title(res, "Rename to '_'");
		Object* prefix = find_action_with_title(res, "Prefix with '_'");
		bool rp; bool pp;
		if (try v = rename.get_bool("isPreferred")) { rp = v; }
		if (try v = prefix.get_bool("isPreferred")) { pp = v; }
		assert(rp, "rename is preferred");
		assert(!pp, "prefix is not preferred");
	};
}
