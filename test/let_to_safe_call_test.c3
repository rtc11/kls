module kls::test::let_to_safe_call_test;

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

fn void offered_for_safe_call_let_with_call() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?) {
	x?.let { it.length }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x?.length", "%s", new_text);
	};
}

fn void offered_for_call_with_args() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?) {
	x?.let { it.substring(0, 3) }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x?.substring(0, 3)", "%s", new_text);
	};
}

fn void offered_for_plain_dot_let() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String) {
	x.let { it.length }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "x.length", "%s", new_text);
	};
}

fn void not_offered_when_explicit_param() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?) {
	x?.let { s -> s.length }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action == null, "no action when lambda has explicit param");
	};
}

fn void not_offered_when_args_use_it() @test {
	@pool() {
		String uri = "file:///t.kt";
		// `it` appears as both receiver and argument – rewriting would lose
		// the local binding for the second use.
		String content =
			`fun f(x: String?) {
	x?.let { it.startsWith(it) }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action == null, "no action when args reference it");
	};
}

fn void not_offered_when_inner_dot_is_safe_call() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?) {
	x?.let { it?.length }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action == null, "no action for inner safe call");
	};
}

fn void not_offered_for_multi_statement_lambda() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?) {
	x?.let {
		println(it)
		it.length
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action == null, "no action for multi-statement lambda");
	};
}

fn void suppressed_when_comment_inside() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`fun f(x: String?) {
	x?.let { /* keep */ it.length }
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 8);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "Replace 'let' with safe call");
		assert(action == null, "no action when comment inside");
	};
}
