module kls::test::pair_to_infix_test;

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

const String NEEDLE = "Replace 'Pair(a, b)' with 'a to b'";

// ── Positive ──────────────────────────────────────────────────

fn void offered_for_simple_names() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(a: Int, b: String) {
	val p = Pair(a, b)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "a to b", "%s", new_text);
	};
}

fn void offered_for_literals() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f() {
	val p = Pair(1, "two")
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "1 to \"two\"", "%s", new_text);
	};
}

fn void offered_for_dot_expr() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class Box(val v: Int)
fun f(a: Box, b: Box) {
	val p = Pair(a.v, b.v)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 2, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "a.v to b.v", "%s", new_text);
	};
}

fn void wraps_complex_args() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(a: Int, b: Int) {
	val p = Pair(a + 1, b - 1)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "(a + 1) to (b - 1)", "%s", new_text);
	};
}

// ── Negative ──────────────────────────────────────────────────

fn void not_offered_for_named_args() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(a: Int, b: String) {
	val p = Pair(first = a, second = b)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "named args should be left alone");
	};
}

fn void not_offered_for_wrong_arity() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(a: Int) {
	val p = Triple(a, a, a)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "Triple is not a Pair");
	};
}

fn void not_offered_with_comment() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(a: Int, b: Int) {
	val p = Pair(a, /* keep */ b)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 12);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, NEEDLE);
		assert(action == null, "comment should suppress action");
	};
}
