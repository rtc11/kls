module kls::test::let_identity_test;

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

const String NEEDLE = "Drop redundant 'let { it }' wrapping";

// ── Positive ──────────────────────────────────────────────────

fn void offered_for_safe_let_identity() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return x?.let { it }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void offered_for_plain_let_identity() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String): String {
	return x.let { it }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void offered_for_dot_chain_receiver() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class Box(val v: String?)
fun f(b: Box): String? {
	return b.v?.let { it }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 2, 16);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "b.v", "%s", new_text);
	};
}

// ── Negative ──────────────────────────────────────────────────

fn void not_offered_when_body_is_call_on_it() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): Int? {
	return x?.let { it.length }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "non-identity body should NOT be offered");
	};
}

fn void not_offered_when_explicit_param_used() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return x?.let { v -> v }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "explicit param should NOT be offered");
	};
}

fn void not_offered_when_multi_stmt_body() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return x?.let {
		println(it)
		it
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "multi-stmt body should NOT be offered");
	};
}

fn void not_offered_when_comment_present() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?): String? {
	return x?.let { /* keep */ it }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "comment should suppress action");
	};
}
