module kls::test::redundant_if_bool_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool has_diag_message_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Probe: if (cond) true else false → warn ───────────────────

fn void true_else_false_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return if (x > 0) true else false
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Redundant 'if'"),
			"expected redundant if diagnostic for true/false branches");
	};
}

// ── Probe: if (cond) false else true → warn ───────────────────

fn void false_else_true_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return if (x > 0) false else true
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "negated"),
			"expected redundant if (negated) diagnostic for false/true branches");
	};
}

// ── Probe: block form → warn ──────────────────────────────────

fn void block_form_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Boolean): Boolean {
	return if (x) { true } else { false }
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Redundant 'if'"),
			"expected redundant if diagnostic for block form");
	};
}

// ── Probe: non-bool branches → no warn ────────────────────────

fn void non_bool_branches_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Int {
	return if (x > 0) 1 else 2
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Redundant 'if'"),
			"should not warn for non-bool branches");
	};
}

// ── Probe: mixed types → no warn ──────────────────────────────

fn void mixed_types_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Boolean): Any {
	return if (x) true else 0
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Redundant 'if'"),
			"should not warn for mixed-type branches");
	};
}

// ── Probe: no else → no warn ──────────────────────────────────

fn void no_else_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Boolean) {
	if (x) println("yes")
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Redundant 'if'"),
			"should not warn when no else branch");
	};
}

// ── Quickfix tests ────────────────────────────────────────────

import kls::document;
import kls::lsp::code_actions;

fn Object* run_code_actions(String content, String uri) {
	DocumentStore store;
	store.init();
	store.open(uri, "kotlin", 1, content);
	Object* diags = build_diags(content);

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
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);

	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	store.free();
	return result;
}

fn String find_action_new_text(Object* actions, String title_needle) {
	for (sz i = 0; i < actions.get_len(); i++) {
		Object* a = actions.get_at((usz)i);
		String title = a.get_string("title") ?? "";
		if (!title.contains(title_needle)) continue;
		Object* edit = a.get("edit") ?? null;
		if (edit == null) continue;
		Object* changes = edit.get("changes") ?? null;
		if (changes == null) continue;
		// Iterate keys -- there should be exactly one URI
		Object*? edits = null;
		// Hack: try the test uri
		edits = changes.get("file:///test.kt");
		if (catch edits) continue;
		if (edits.get_len() == 0) continue;
		return edits.get_at(0).get_string("newText") ?? "";
	}
	return "";
}

fn void quickfix_true_else_false_replaces_with_cond() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return if (x > 0) true else false
}
`;
		Object* actions = run_code_actions(content, "file:///test.kt");
		String new_text = find_action_new_text(actions, "Replace with condition");
		assert(new_text == "x > 0", "expected newText 'x > 0', got '%s'", new_text);
	};
}

fn void quickfix_false_else_true_replaces_with_negation() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return if (x > 0) false else true
}
`;
		Object* actions = run_code_actions(content, "file:///test.kt");
		String new_text = find_action_new_text(actions, "negated");
		assert(new_text == "!(x > 0)", "expected newText '!(x > 0)', got '%s'", new_text);
	};
}

fn void quickfix_simple_name_no_parens() @test {
	@pool() {
		String content =
			`fun foo(b: Boolean): Boolean {
	return if (b) false else true
}
`;
		Object* actions = run_code_actions(content, "file:///test.kt");
		String new_text = find_action_new_text(actions, "negated");
		assert(new_text == "!b", "expected newText '!b', got '%s'", new_text);
	};
}
