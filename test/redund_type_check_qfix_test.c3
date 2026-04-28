module kls::test::redund_type_check_qfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

// Build real diagnostics for content, return one whose message contains
// "Type check is always" + needle. Returns null if none.
fn Object* find_type_check_diag(String content, String needle) {
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
		if (msg.contains("Type check is always") && msg.contains(needle)) return d;
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

fn String find_action_text_by_title_prefix(Object* result, String prefix) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (!t.starts_with(prefix)) continue;
		Object* edit = action.get("edit") ?? null;
		if (edit == null) return "";
		Object* changes = edit.get("changes") ?? null;
		if (changes == null) return "";
		Object* edits = changes.get("file:///test.kt") ?? null;
		if (edits == null) return "";
		Object* e = edits.get_at(0);
		return e.get_string("newText") ?? "";
	}
	return "";
}

// Returns "" if no Replace-with action found at all (used to assert
// the quickfix is suppressed for side-effecting subjects).
fn String run_replace_type_check(String content, String diag_needle) {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, content);

	Object* diag = find_type_check_diag(content, diag_needle);
	if (diag == null) return "<NO_DIAG>";
	Object* params = build_qfix_params(diag);
	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	return find_action_text_by_title_prefix(result, "Replace with");
}

fn void rtcq_is_int_to_true() @test {
	@pool() {
		String text = run_replace_type_check(
			`fun foo() {
    val x: Int = 1
    if (x is Int) println("y")
}`,
			"true");
		assert(text == "true", "expected 'true', got '%s'", text);
	};
}

fn void rtcq_neg_is_to_false() @test {
	@pool() {
		String text = run_replace_type_check(
			`fun foo() {
    val x: Int = 1
    if (x !is Int) println("never")
}`,
			"false");
		assert(text == "false", "expected 'false', got '%s'", text);
	};
}

fn void rtcq_subtype_to_true() @test {
	@pool() {
		String text = run_replace_type_check(
			`fun foo() {
    val x: Int = 1
    if (x is Number) println("y")
}`,
			"true");
		assert(text == "true", "expected 'true' (subtype), got '%s'", text);
	};
}

fn void rtcq_dot_expr_subject_to_true() @test {
	@pool() {
		String text = run_replace_type_check(
			`class C { val v: Int = 1 }
fun bar(c: C) {
    if (c.v is Int) println("y")
}`,
			"true");
		assert(text == "true", "expected 'true' (DOT_EXPR subject), got '%s'", text);
	};
}

fn void rtcq_call_expr_subject_skipped() @test {
	@pool() {
		String text = run_replace_type_check(
			`fun foo(): Int = 1
fun bar() {
    if (foo() is Int) println("y")
}`,
			"true");
		// CALL_EXPR subject has potential side effects; quickfix must NOT be offered.
		// Empty string means no "Replace with" action found in result.
		assert(text == "" || text == "<NO_DIAG>",
			"CALL_EXPR subject should NOT get replace-with-literal quickfix, got '%s'", text);
	};
}
