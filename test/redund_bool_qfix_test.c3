module kls::test::redund_bool_qfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;

fn Object* make_diag(int line, int col, String message) {
	Object* d = object::new_obj(tmem);
	Object* range = object::new_obj(tmem);
	Object* start = object::new_obj(tmem);
	start.set("line", line);
	start.set("character", col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", line);
	end_pos.set("character", col + 1);
	range.set("start", start);
	range.set("end", end_pos);
	d.set("range", range);
	d.set("message", message);
	return d;
}

fn Object* make_params(String uri, Object* diag) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* start = object::new_obj(tmem);
	start.set("line", 0);
	start.set("character", 0);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", 0);
	end_pos.set("character", 0);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* diags = object::new_obj(tmem);
	if (diag != null) diags.push(diag);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

fn String find_action_text(Object* result, String title) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (t == title) {
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

// Helper: open doc + invoke quickfix; returns newText for the
// "Simplify boolean comparison" action or empty if not present.
fn String run_qfix(String content, int line, int col, String msg) {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, content);

	Object* diag = make_diag(line, col, msg);
	Object* params = make_params("file:///test.kt", diag);
	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	return find_action_text(result, "Simplify boolean comparison");
}

fn void rbc_qfix_eq_true() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(b: Boolean) {
    if (b == true) println("y")
}`,
			1, 8, // BINARY_EXPR `b == true` at line 1 col 8 (after `    if (`)
			"Redundant comparison to boolean literal: replace with expression");
		assert(text == "b", "expected 'b', got '%s'", text);
	};
}

fn void rbc_qfix_neq_true() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(b: Boolean) {
    if (b != true) println("n")
}`,
			1, 8,
			"Redundant comparison to boolean literal: replace with negated expression");
		assert(text == "!b", "expected '!b', got '%s'", text);
	};
}

fn void rbc_qfix_eq_false() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(b: Boolean) {
    if (b == false) println("n")
}`,
			1, 8,
			"Redundant comparison to boolean literal: replace with negated expression");
		assert(text == "!b", "expected '!b', got '%s'", text);
	};
}

fn void rbc_qfix_neq_false() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(b: Boolean) {
    if (b != false) println("y")
}`,
			1, 8,
			"Redundant comparison to boolean literal: replace with expression");
		assert(text == "b", "expected 'b', got '%s'", text);
	};
}

fn void rbc_qfix_literal_lhs() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(b: Boolean) {
    if (true == b) println("y")
}`,
			1, 8,
			"Redundant comparison to boolean literal: replace with expression");
		assert(text == "b", "expected 'b' (literal LHS), got '%s'", text);
	};
}

fn void rbc_qfix_call_negation() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(): Boolean = true
fun bar() {
    if (foo() == false) println("n")
}`,
			2, 8,
			"Redundant comparison to boolean literal: replace with negated expression");
		// CALL_EXPR atom — bare ! prefix.
		assert(text == "!foo()", "expected '!foo()', got '%s'", text);
	};
}

fn void rbc_qfix_paren_expr_negation() @test {
	@pool() {
		String text = run_qfix(
			`fun foo(a: Boolean, b: Boolean) {
    if ((a && b) == false) println("n")
}`,
			1, 8,
			"Redundant comparison to boolean literal: replace with negated expression");
		// PAREN_EXPR atom — bare ! prefix preserves existing parens.
		assert(text == "!(a && b)", "expected '!(a && b)', got '%s'", text);
	};
}

fn void rbc_qfix_dot_expr_no_paren() @test {
	@pool() {
		String text = run_qfix(
			`class Foo { val flag: Boolean = true }
fun bar(f: Foo) {
    if (f.flag == true) println("y")
}`,
			2, 8,
			"Redundant comparison to boolean literal: replace with expression");
		assert(text == "f.flag", "expected 'f.flag', got '%s'", text);
	};
}
