module kls::test::can_be_const_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::lsp::code_actions;
import kls::document;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;
import kls::config;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	return diagnostics::build_diagnostics_array(content, pr);
}

fn bool any_msg_contains(Object* diags, String needle) {
	usz n = diags.get_len();
	for (usz i = 0; i < n; i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

fn Object* find_diag_with(Object* diags, String needle) {
	usz n = diags.get_len();
	for (usz i = 0; i < n; i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return d;
	}
	return null;
}

// ── Diagnostic tests ──────────────────────────────────────────────

fn void hint_top_level_int_literal() @test {
	@pool() {
		Object* diags = build_diags(`val MAX = 42`);
		assert(any_msg_contains(diags, "could be 'const'"),
			"expected can-be-const hint for top-level Int literal");
	};
}

fn void hint_top_level_string_literal() @test {
	@pool() {
		Object* diags = build_diags(`val NAME = "kls"`);
		assert(any_msg_contains(diags, "could be 'const'"),
			"expected can-be-const hint for top-level String literal");
	};
}

fn void hint_object_member_literal() @test {
	@pool() {
		Object* diags = build_diags(
`object Constants {
    val PI = 3
}`);
		assert(any_msg_contains(diags, "could be 'const'"),
			"expected can-be-const hint for object member literal");
	};
}

fn void no_hint_for_var() @test {
	@pool() {
		Object* diags = build_diags(`var X = 1`);
		assert(!any_msg_contains(diags, "could be 'const'"),
			"var cannot be const");
	};
}

fn void no_hint_for_already_const() @test {
	@pool() {
		Object* diags = build_diags(`const val X = 1`);
		assert(!any_msg_contains(diags, "could be 'const'"),
			"already const — no hint expected");
	};
}

fn void no_hint_for_class_member() @test {
	@pool() {
		Object* diags = build_diags(
`class Foo {
    val X = 1
}`);
		assert(!any_msg_contains(diags, "could be 'const'"),
			"const not allowed inside class — no hint expected");
	};
}

fn void no_hint_for_string_with_template() @test {
	@pool() {
		Object* diags = build_diags(`val X = "hello $name"`);
		assert(!any_msg_contains(diags, "could be 'const'"),
			"string template with interpolation not const");
	};
}

fn void no_hint_for_null_initializer() @test {
	@pool() {
		Object* diags = build_diags(`val X: String? = null`);
		assert(!any_msg_contains(diags, "could be 'const'"),
			"null is not a compile-time constant for const val");
	};
}

fn void no_hint_for_call_initializer() @test {
	@pool() {
		Object* diags = build_diags(`val X = compute()`);
		assert(!any_msg_contains(diags, "could be 'const'"),
			"function call is not a compile-time constant");
	};
}

// ── Quickfix test ──────────────────────────────────────────────────

fn Object* make_action_params(String uri, Object* diag) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", diag.get("range")!!);
	Object* ctx = object::new_obj(tmem);
	Object* diags_arr = object::new_obj(tmem);
	diags_arr.push(diag);
	ctx.set("diagnostics", diags_arr);
	params.set("context", ctx);
	return params;
}

fn void quickfix_inserts_const_modifier() @test {
	@pool() {
		String content = `val MAX = 42`;
		String uri = "file:///t.kt";

		Object* diags = build_diags(content);
		Object* diag = find_diag_with(diags, "could be 'const'");
		assert(diag != null, "expected can-be-const diag");

		DocumentStore store;
		store.init();
		defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* params = make_action_params(uri, diag);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* a = result.get_at((usz)i);
			String title = a.get_string("title") ?? "";
			if (title == "Add 'const' modifier") {
				found = true;
				Object* edit = a.get("edit")!!;
				Object* changes = edit.get("changes")!!;
				Object* edits = changes.get(uri)!!;
				assert(edits.get_len() == 1, "expected 1 edit");
				Object* e = edits.get_at(0);
				String new_text = e.get_string("newText") ?? "";
				assert(new_text == "const ", "expected 'const ', got '%s'", new_text);
				break;
			}
		}
		assert(found, "expected 'Add const modifier' action");
	};
}
