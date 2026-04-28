module kls::test::lateinit_to_lazy_test;

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

const String TITLE_NEEDLE = "Convert 'lateinit var' to 'val by lazy";

// ── Positive tests ─────────────────────────────────────────────

fn void offered_for_basic_class_member() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class C {
	lateinit var name: String
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		// cursor on `name`
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "val name: String by lazy { TODO(\"Initialize name\") }", "%s", new_text);
	};
}

fn void offered_in_interface() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`interface I {
	lateinit var foo: List<String>
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "val foo: List<String> by lazy { TODO(\"Initialize foo\") }", "%s", new_text);
	};
}

fn void offered_in_object() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`object O {
	lateinit var conn: Connection
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "val conn: Connection by lazy { TODO(\"Initialize conn\") }", "%s", new_text);
	};
}

fn void offered_in_companion() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class C {
	companion object {
		lateinit var instance: C
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		// cursor on `instance`
		Object* params = make_params(uri, 2, 16);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text == "val instance: C by lazy { TODO(\"Initialize instance\") }", "%s", new_text);
	};
}

// ── Negative tests ─────────────────────────────────────────────

fn void not_offered_for_non_lateinit_var() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class C {
	var name: String = ""
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 7);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action == null, "action must NOT be offered");
	};
}

fn void not_offered_for_val() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class C {
	val name: String = ""
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 7);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action == null, "action must NOT be offered");
	};
}

fn void not_offered_when_comment_present() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class C {
	lateinit var name: /* keep */ String
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action == null, "comment should suppress action");
	};
}

fn void not_offered_outside_property() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class C {
	lateinit var name: String
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		// cursor on `class` keyword line 0 col 0
		Object* params = make_params(uri, 0, 0);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, TITLE_NEEDLE);
		assert(action == null, "no PROPERTY_DECL at cursor");
	};
}
