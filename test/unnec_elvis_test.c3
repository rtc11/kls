module kls::test::unnec_elvis_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool has_diag_message_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Probe: declared non-null val → warn ────────────────────────

fn void declared_non_null_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	val s: String = "hi"
	val x = s ?: "default"
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Elvis operator (?:) on non-null"),
			"expected unnecessary elvis for declared non-null");
	};
}

// ── Probe: nullable type → no warn ─────────────────────────────

fn void nullable_no_warn() @test {
	@pool() {
		String content =
			`fun foo(s: String?) {
	val x = s ?: "default"
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Elvis operator (?:)"),
			"should not warn for nullable LHS");
	};
}

// ── Probe: string literal LHS → warn ───────────────────────────

fn void string_template_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = "literal" ?: "default"
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Elvis operator (?:) on non-null"),
			"expected unnecessary elvis for string literal");
	};
}

// ── Probe: int literal LHS → warn ──────────────────────────────

fn void int_literal_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = 42 ?: 0
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Elvis operator (?:) on non-null"),
			"expected unnecessary elvis for int literal");
	};
}

// ── Probe: null literal LHS → no warn ──────────────────────────

fn void null_literal_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = null ?: "default"
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Elvis operator (?:)"),
			"should not warn when LHS is null literal");
	};
}

// ── Probe: smart-cast non-null → warn ──────────────────────────

fn void smart_cast_non_null_warns() @test {
	@pool() {
		String content =
			`fun foo(s: String?) {
	if (s != null) {
		val x = s ?: "default"
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Elvis operator (?:) on non-null"),
			"expected unnecessary elvis after smart cast");
	};
}

// ── Probe: this in non-null context → warn ─────────────────────

fn void this_in_non_null_context_warns() @test {
	@pool() {
		String content =
			`class Foo {
	fun bar(): Foo {
		return this ?: this
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Elvis operator (?:) on non-null"),
			"expected unnecessary elvis for this");
	};
}

// ── Quickfix tests ────────────────────────────────────────────

import kls::document;
import kls::lsp::code_actions;

fn Object* run_code_actions(String content, String uri) {
	DocumentStore store;
	store.init();
	store.open(uri, "kotlin", 1, content);
	Object* diags = build_diags(content);

	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* start = object::new_obj(tmem);
	start.set("line", 0);
	start.set("character", 0);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", 999);
	end_pos.set("character", 0);
	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", diags);
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);

	Object* result = code_actions::handle_code_action(&store, null, params)!!;
	store.free();
	return result;
}

fn String find_action_new_text(Object* actions, String title_needle) {
	for (sz i = 0; i < actions.get_len(); i++) {
		Object* a = actions.get_at((usz)i);
		String title = a.get_string("title") ?? "";
		if (!title.contains(title_needle)) continue;
		Object* edit = a.get("edit") ?? null;
		if (edit == null) continue;
		Object* changes = edit.get("changes") ?? null;
		if (changes == null) continue;
		Object*? edits = changes.get("file:///test.kt");
		if (catch edits) continue;
		if (edits.get_len() == 0) continue;
		return edits.get_at(0).get_string("newText") ?? "";
	}
	return "";
}

fn void quickfix_replaces_with_lhs() @test {
	@pool() {
		String content =
			`fun foo() {
	val s: String = "hi"
	val x = s ?: "default"
}
`;
		Object* actions = run_code_actions(content, "file:///test.kt");
		String new_text = find_action_new_text(actions, "Remove redundant '?:'");
		assert(new_text == "s", "expected newText='s' but got '%s'", new_text);
	};
}

fn void quickfix_string_literal_lhs() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = "literal" ?: "default"
}
`;
		Object* actions = run_code_actions(content, "file:///test.kt");
		String new_text = find_action_new_text(actions, "Remove redundant '?:'");
		assert(new_text == "\"literal\"", "expected newText=\"literal\" but got '%s'", new_text);
	};
}
