module kls::test::unsafe_null_recv_qfix_test;

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

fn Object* find_unsafe_null_diag(String content) {
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
		if (m.contains("Only safe (?.) or non-null asserted")) return d;
	}
	return null;
}

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
	Object* diag = find_unsafe_null_diag(content);
	if (diag == null) return null;
	Object* params = make_params_with_diag(uri, diag);
	return code_actions::handle_code_action(&store, null, params)!!;
}

fn Object* find_action(Object* actions, String title) {
	if (actions == null) return null;
	for (sz i = 0; i < actions.get_len(); i++) {
		Object* x = actions.get_at((usz)i);
		String t = x.get_string("title") ?? "";
		if (t == title) return x;
	}
	return null;
}

fn void offers_both_actions() @test {
	@pool() {
		String c = "fun test(s: String?) { s.length }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		assert(actions != null, "should have actions");
		assert(actions.get_len() >= 2, "expected >=2 actions, got %d", (int)actions.get_len());
		assert(find_action(actions, "Replace '.' with safe call '?.'") != null,
			"missing safe-call action");
		assert(find_action(actions, "Assert non-null with '!!'") != null,
			"missing not-null-assert action");
	};
}

fn void safe_call_action_replaces_dot() @test {
	@pool() {
		String c = "fun test(s: String?) { s.length }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = find_action(actions, "Replace '.' with safe call '?.'");
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == "fun test(s: String?) { s?.length }", "got '%s'", result);
	};
}

fn void not_null_action_inserts_assertion() @test {
	@pool() {
		String c = "fun test(s: String?) { s.length }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = find_action(actions, "Assert non-null with '!!'");
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == "fun test(s: String?) { s!!.length }", "got '%s'", result);
	};
}

fn void safe_call_action_on_method_call() @test {
	@pool() {
		String c = "fun test(s: String?) { s.toUpperCase() }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = find_action(actions, "Replace '.' with safe call '?.'");
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == "fun test(s: String?) { s?.toUpperCase() }", "got '%s'", result);
	};
}

fn void not_null_action_on_method_call() @test {
	@pool() {
		String c = "fun test(s: String?) { s.toUpperCase() }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = find_action(actions, "Assert non-null with '!!'");
		assert(a != null);
		String result = apply_edit(c, a, uri);
		assert(result == "fun test(s: String?) { s!!.toUpperCase() }", "got '%s'", result);
	};
}

fn void safe_call_marked_preferred() @test {
	@pool() {
		String c = "fun test(s: String?) { s.length }";
		String uri = "file:///t.kt";
		Object* actions = run_actions(c, uri);
		Object* a = find_action(actions, "Replace '.' with safe call '?.'");
		assert(a != null);
		bool pref = (bool)(a.get("isPreferred").b ?? false);
		assert(pref, "safe-call action should be preferred");
	};
}
