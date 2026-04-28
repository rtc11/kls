module kls::test::sam_lambda_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

// Helpers re-declared here (small surface) to avoid cross-test-module
// imports. Mirror code_actions_test.c3 patterns.

fn Object* mk_params(String uri, int line, int col) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* start = object::new_obj(tmem);
	start.set("line", line);
	start.set("character", col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", line);
	end_pos.set("character", col);
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

fn String find_title(Object* result, String title) {
	if (result == null) return "";
	for (usz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at(i);
		String t = action.get_string("title") ?? "";
		if (t != title) continue;
		Object* edit = action.get("edit") ?? null;
		if (edit == null) continue;
		Object* changes = edit.get("changes") ?? null;
		if (changes == null) continue;
		// All test files use file:///t.kt
		Object* edits = changes.get("file:///t.kt") ?? null;
		if (edits == null) continue;
		if (edits.get_len() == 0) continue;
		Object* e = edits.get_at(0);
		return e.get_string("newText") ?? "";
	}
	return "";
}

fn void object_to_lambda_simple() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Cursor on `object` keyword
		String content = `fun reg() { val l = object : Listener { override fun onClick(v: View) { println(v) } } }`;
		store.open("file:///t.kt", "kotlin", 1, content);

		Object* params = mk_params("file:///t.kt", 0, 20);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		String got = find_title(result, "Convert object literal to lambda");
		assert(got == "Listener { v -> println(v) }", "got '%s'", got);
	};
}

fn void object_to_lambda_no_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun r() { val r2 = object : Runnable { override fun run() { println("hi") } } }`;
		store.open("file:///t.kt", "kotlin", 1, content);

		Object* params = mk_params("file:///t.kt", 0, 19);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		String got = find_title(result, "Convert object literal to lambda");
		assert(got == "Runnable { println(\"hi\") }", "got '%s'", got);
	};
}

fn void object_to_lambda_two_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun r() { val c = object : Cmp { override fun compare(a: Int, b: Int): Int { return a - b } } }`;
		store.open("file:///t.kt", "kotlin", 1, content);

		Object* params = mk_params("file:///t.kt", 0, 18);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		String got = find_title(result, "Convert object literal to lambda");
		assert(got == "Cmp { a, b -> return a - b }", "got '%s'", got);
	};
}

fn void object_to_lambda_skips_multiple_methods() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Two override funs — not SAM
		String content = `fun r() { val l = object : L { override fun a() {} override fun b() {} } }`;
		store.open("file:///t.kt", "kotlin", 1, content);

		Object* params = mk_params("file:///t.kt", 0, 18);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		String got = find_title(result, "Convert object literal to lambda");
		assert(got == "", "expected no action, got '%s'", got);
	};
}

fn void object_to_lambda_skips_with_property() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Has a property — not pure SAM
		String content = `fun r() { val l = object : L { val x = 1; override fun a() {} } }`;
		store.open("file:///t.kt", "kotlin", 1, content);

		Object* params = mk_params("file:///t.kt", 0, 18);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		String got = find_title(result, "Convert object literal to lambda");
		assert(got == "", "expected no action, got '%s'", got);
	};
}

fn void object_to_lambda_skips_two_supertypes() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun r() { val l = object : A, B { override fun foo() {} } }`;
		store.open("file:///t.kt", "kotlin", 1, content);

		Object* params = mk_params("file:///t.kt", 0, 18);
		Object* result = code_actions::handle_code_action(&store, null, params)!!;
		String got = find_title(result, "Convert object literal to lambda");
		assert(got == "", "expected no action, got '%s'", got);
	};
}
