module kls::test::useless_cast_qfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

// Build a real diagnostic for the given source, find one whose
// message contains `needle`, and return that diagnostic. Returns null
// if none found.
fn Object* find_useless_cast_diag(String content, String needle) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); }
	types::resolve_types(pr, ti);
	Object* diags = diagnostics::build_diagnostics_array(content, pr, null, ti);
	for (usz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains("Useless cast") && msg.contains(needle)) return d;
	}
	return null;
}

fn Object* build_qfix_params(Object* diag) {
	Object* td = object::new_obj(tmem);
	td.set("uri", "file:///test.kt");
	Object* range = diag.get("range") ?? null;
	Object* diags = object::new_obj(tmem);
	diags.push(diag);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

fn String find_remove_cast_text(Object* result) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (t == "Remove useless cast") {
			Object* edit = action.get("edit") ?? null;
			if (edit == null) return "";
			Object* changes = edit.get("changes") ?? null;
			if (changes == null) return "";
			Object* edits = changes.get("file:///test.kt") ?? null;
			if (edits == null) return "";
			Object* e = edits.get_at(0);
			return e.get_string("newText") ?? "";
		}
	}
	return "";
}

fn String run_remove_useless_cast(String content, String diag_needle) {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, content);

	Object* diag = find_useless_cast_diag(content, diag_needle);
	if (diag == null) return "";
	Object* params = build_qfix_params(diag);
	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	return find_remove_cast_text(result);
}

fn void uc_qfix_same_type() @test {
	@pool() {
		String text = run_remove_useless_cast(
			`fun foo() {
    val x: Int = 1
    val y = x as Int
}`,
			"Int");
		assert(text == "x", "expected 'x', got '%s'", text);
	};
}

fn void uc_qfix_subtype() @test {
	@pool() {
		String text = run_remove_useless_cast(
			`fun foo() {
    val x: Int = 1
    val y = x as Number
}`,
			"Number");
		assert(text == "x", "expected 'x' (subtype case), got '%s'", text);
	};
}

fn void uc_qfix_nullable_widening() @test {
	@pool() {
		String text = run_remove_useless_cast(
			`fun foo() {
    val x: Int = 1
    val y = x as Int?
}`,
			"Int?");
		assert(text == "x", "expected 'x' (nullable widening), got '%s'", text);
	};
}

fn void uc_qfix_call_expr() @test {
	@pool() {
		String text = run_remove_useless_cast(
			`fun foo(): Int = 1
fun bar() {
    val y = foo() as Int
}`,
			"Int");
		assert(text == "foo()", "expected 'foo()', got '%s'", text);
	};
}

fn void uc_qfix_dot_expr() @test {
	@pool() {
		String text = run_remove_useless_cast(
			`class C { val v: Int = 1 }
fun bar(c: C) {
    val y = c.v as Int
}`,
			"Int");
		assert(text == "c.v", "expected 'c.v', got '%s'", text);
	};
}
