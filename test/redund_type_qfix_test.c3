module kls::test::redund_type_qfix_test;

import std::collections::object;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::document;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn Object* make_params_with_diag(String uri, Object* diag) {
	Object* range = diag.get("range") ?? null;
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* ctx = object::new_obj(tmem);
	Object* diags = object::new_obj(tmem);
	diags.push(diag);
	ctx.set("diagnostics", diags);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", ctx);
	return params;
}

// Build the real diag for the given content; return first matching one.
fn Object* find_redundant_type_diag(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	Object* diags = diagnostics::build_diagnostics_array(content, pr, null, ti);
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains("Explicitly given type is redundant")) return d;
	}
	return null;
}

fn String first_action_new_text(Object* actions, String title, String uri) {
	if (actions == null) return "";
	for (sz i = 0; i < actions.get_len(); i++) {
		Object* a = actions.get_at((usz)i);
		String t = a.get_string("title") ?? "";
		if (t != title) continue;
		Object* edit = a.get("edit") ?? null;
		if (edit == null) continue;
		Object* changes = edit.get("changes") ?? null;
		if (changes == null) continue;
		Object* edits = changes.get(uri) ?? null;
		if (edits == null) continue;
		if (edits.get_len() == 0) continue;
		return edits.get_at(0).get_string("newText") ?? "<no-newText>";
	}
	return "";
}

// Apply edit to source: returns content with [start_off, end_off) replaced by new_text.
fn String apply_edit(String content, Object* action, String uri) {
	Object* edit = action.get("edit") ?? null;
	if (edit == null) return content;
	Object* changes = edit.get("changes") ?? null;
	if (changes == null) return content;
	Object* edits = changes.get(uri) ?? null;
	if (edits == null) return content;
	Object* e = edits.get_at(0);
	Object* range = e.get("range") ?? null;
	Object* s = range.get("start") ?? null;
	Object* en = range.get("end") ?? null;
	uint sl = (uint)(s.get_int("line") ?? 0);
	uint sc = (uint)(s.get_int("character") ?? 0);
	uint el = (uint)(en.get_int("line") ?? 0);
	uint ec = (uint)(en.get_int("character") ?? 0);
	long so = document::position_to_byte_offset(content, sl, sc);
	long eo = document::position_to_byte_offset(content, el, ec);
	if (so < 0 || eo < 0) return content;
	String nt = e.get_string("newText") ?? "";
	DString out;
	out.tinit();
	out.append(content[:(usz)so]);
	out.append(nt);
	out.append(content[(usz)eo..]);
	return out.str_view();
}

fn Object* run_actions(String content, String uri) {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open(uri, "kotlin", 1, content);
	Object* diag = find_redundant_type_diag(content);
	if (diag == null) return null;
	Object* params = make_params_with_diag(uri, diag);
	return code_actions::handle_code_action(&store, null, params)!!;
}

// Local val: `val x: Int = 1` → `val x = 1`
fn void local_int_to_no_type() @test {
	@pool() {
		String c = "fun foo() { val x: Int = 1 }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		assert(actions != null, "should have actions");
		Object* a = null;
		for (sz i = 0; i < actions.get_len(); i++) {
			Object* x = actions.get_at((usz)i);
			String t = x.get_string("title") ?? "";
			if (t == "Remove explicit type specification") { a = x; break; }
		}
		assert(a != null, "should offer remove action");
		String result = apply_edit(c, a, uri);
		assert(result == "fun foo() { val x = 1 }", "got '%s'", result);
	};
}

// Top-level val: `val n: Int = 42` → `val n = 42`
fn void top_level_to_no_type() @test {
	@pool() {
		String c = "val n: Int = 42";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = null;
		for (sz i = 0; i < actions.get_len(); i++) {
			Object* x = actions.get_at((usz)i);
			String t = x.get_string("title") ?? "";
			if (t == "Remove explicit type specification") { a = x; break; }
		}
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == "val n = 42", "got '%s'", result);
	};
}

// String literal: `val s: String = "x"` → `val s = "x"`
fn void string_to_no_type() @test {
	@pool() {
		String c = `val s: String = "x"`;
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = null;
		for (sz i = 0; i < actions.get_len(); i++) {
			Object* x = actions.get_at((usz)i);
			String t = x.get_string("title") ?? "";
			if (t == "Remove explicit type specification") { a = x; break; }
		}
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == `val s = "x"`, "got '%s'", result);
	};
}

// var: `var n: Int = 0` → `var n = 0`
fn void var_int_to_no_type() @test {
	@pool() {
		String c = "fun foo() { var n: Int = 0; n = n + 1; println(n) }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = null;
		for (sz i = 0; i < actions.get_len(); i++) {
			Object* x = actions.get_at((usz)i);
			String t = x.get_string("title") ?? "";
			if (t == "Remove explicit type specification") { a = x; break; }
		}
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == "fun foo() { var n = 0; n = n + 1; println(n) }", "got '%s'", result);
	};
}
