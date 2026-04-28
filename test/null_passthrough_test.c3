module kls::test::null_passthrough_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::kotlin::ast;
import kls::kotlin::parser;

fn Object* make_params(String uri, int line, int col) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* s = object::new_obj(tmem);
	s.set("line", line);
	s.set("character", col);
	Object* e = object::new_obj(tmem);
	e.set("line", line);
	e.set("character", col);
	Object* range = object::new_obj(tmem);
	range.set("start", s);
	range.set("end", e);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", object::new_obj(tmem));
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
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

const String NEEDLE = "Simplify null pass-through";

// ── Positive ──────────────────────────────────────────────────

fn void offered_for_ne_form_x_else_null() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (x != null) x else null
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		// cursor inside the if expression
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void offered_for_eq_form_null_else_x() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (x == null) null else x
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void offered_with_block_branches() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (x != null) { x } else { null }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void offered_with_null_on_left() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (null != x) x else null
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

// ── Negative ──────────────────────────────────────────────────

fn void not_offered_when_branches_swapped() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (x != null) null else x
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "swapped branches should NOT be offered");
	};
}

fn void not_offered_for_different_name() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?, y: String?): String? {
	return if (x != null) y else null
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "different name should NOT be offered");
	};
}

fn void not_offered_with_comment() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (x != null) x /* keep */ else null
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "comment should suppress action");
	};
}

fn void not_offered_for_unrelated_cond() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return if (x.hashCode() > 0) x else null
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 18);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "non-null check cond should NOT be offered");
	};
}
