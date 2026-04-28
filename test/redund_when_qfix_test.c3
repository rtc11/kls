module kls::test::redund_when_qfix_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn Object* find_when_diag(String content, String needle) {
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
		if (msg.contains("Redundant 'when'") && msg.contains(needle)) return d;
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

fn String find_replace_text(Object* result, String title_needle) {
	for (sz i = 0; i < result.get_len(); i++) {
		Object* action = result.get_at((usz)i);
		String t = action.get_string("title") ?? "";
		if (!t.contains(title_needle)) continue;
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

fn String run_simplify_when(String content, String diag_needle, String title_needle) {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, content);

	Object* diag = find_when_diag(content, diag_needle);
	if (diag == null) return "<no-diag>";
	Object* params = build_qfix_params(diag);
	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	return find_replace_text(result, title_needle);
}

// ── Quickfix produces correct text ────────────────────────

fn void qfix_true_else_false_emits_cond() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Int): Boolean {
    return when {
        x > 0 -> true
        else -> false
    }
}`, "condition", "Replace with condition");
		assert(text == "x > 0", "expected 'x > 0', got '%s'", text);
	};
}

fn void qfix_false_else_true_emits_negated() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Int): Boolean {
    return when {
        x > 0 -> false
        else -> true
    }
}`, "negated", "Replace with negated condition");
		// `x > 0` is BINARY_EXPR → needs parens for negation
		assert(text == "!(x > 0)", "expected '!(x > 0)', got '%s'", text);
	};
}

fn void qfix_simple_name_no_parens() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(b: Boolean): Boolean {
    return when {
        b -> false
        else -> true
    }
}`, "negated", "Replace with negated condition");
		// NAME_EXPR → no parens
		assert(text == "!b", "expected '!b', got '%s'", text);
	};
}

fn void qfix_call_expr_no_parens() @test {
	@pool() {
		String text = run_simplify_when(
			`fun check(): Boolean = true
fun foo(): Boolean {
    return when {
        check() -> false
        else -> true
    }
}`, "negated", "Replace with negated condition");
		// CALL_EXPR → no parens needed
		assert(text == "!check()", "expected '!check()', got '%s'", text);
	};
}

fn void qfix_block_form_emits_cond() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Int): Boolean {
    return when {
        x > 0 -> {
            true
        }
        else -> {
            false
        }
    }
}`, "condition", "Replace with condition");
		assert(text == "x > 0", "expected 'x > 0' for block-wrapped, got '%s'", text);
	};
}

// ── Subject form quickfixes ─────────────────────────────

fn void qfix_subject_literal_eq() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Int): Boolean {
    return when (x) {
        1 -> true
        else -> false
    }
}`, "condition", "Replace with condition");
		assert(text == "x == 1", "expected 'x == 1', got '%s'", text);
	};
}

fn void qfix_subject_literal_ne() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Int): Boolean {
    return when (x) {
        1 -> false
        else -> true
    }
}`, "negated", "Replace with negated condition");
		assert(text == "x != 1", "expected 'x != 1', got '%s'", text);
	};
}

fn void qfix_subject_is_type() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Any?): Boolean {
    return when (x) {
        is String -> true
        else -> false
    }
}`, "condition", "Replace with condition");
		assert(text == "x is String", "expected 'x is String', got '%s'", text);
	};
}

fn void qfix_subject_is_type_negated() @test {
	@pool() {
		String text = run_simplify_when(
			`fun foo(x: Any?): Boolean {
    return when (x) {
        is String -> false
        else -> true
    }
}`, "negated", "Replace with negated condition");
		assert(text == "x !is String", "expected 'x !is String', got '%s'", text);
	};
}

fn void qfix_subject_dot_expr_eq() @test {
	@pool() {
		String text = run_simplify_when(
			`enum class Color { RED, BLUE }
fun foo(c: Color): Boolean {
    return when (c) {
        Color.RED -> true
        else -> false
    }
}`, "condition", "Replace with condition");
		assert(text == "c == Color.RED", "expected 'c == Color.RED', got '%s'", text);
	};
}
