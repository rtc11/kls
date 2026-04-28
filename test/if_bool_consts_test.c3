module kls::test::if_bool_consts_test;

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

// ── Tests ──────────────────────────────────────────────────────

fn void offered_for_then_true_else_false() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Boolean {
	return if (x) true else false
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void offered_for_complex_cond() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Int): Boolean {
	return if (x > 0) true else false
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x > 0", "%s", new_text);
	};
}

fn void offered_for_then_false_else_true() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Boolean {
	return if (x) false else true
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "!x", "%s", new_text);
	};
}

fn void negation_parens_for_complex_cond() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Int): Boolean {
	return if (x > 0) false else true
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "!(x > 0)", "%s", new_text);
	};
}

fn void offered_for_return_form() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Boolean {
	if (x) { return true } else { return false }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "return x", "%s", new_text);
	};
}

fn void offered_for_return_form_negated() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Boolean {
	if (x) { return false } else { return true }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "return !x", "%s", new_text);
	};
}

fn void offered_for_block_wrapped_expr_form() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Boolean {
	return if (x) { true } else { false }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x", "%s", new_text);
	};
}

fn void suppressed_when_comment_inside() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Boolean {
	return if (x) true /* keep */ else false
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action == null, "action suppressed by comment");
	};
}

fn void not_offered_when_mixed_forms() @test {
	@pool() {
		String uri = "file:///t.kt";
		// Then is bare literal expression form, else is return form.
		String content =
			`fun f(x: Boolean): Boolean {
	if (x) return true else false
	return false
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 4);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action == null, "no action for mixed forms");
	};
}

fn void not_offered_for_non_bool_literals() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: Boolean): Int {
	return if (x) 1 else 0
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Simplify boolean expression");
		assert(action == null, "no action for non-bool literals");
	};
}
