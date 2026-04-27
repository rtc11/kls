module kls::test::sealed_action_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

// ── Helpers ──────────────────────────────────────────────────────

fn Object* build_diags_ws(WorkspaceIndex* ws, String uri, String content) {
	ws.index_file(uri, content);
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); }
	types::set_workspace(ws);
	types::resolve_types(pr, ti);
	types::clear_workspace();
	return diagnostics::build_diagnostics_array(content, pr, ws, ti);
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

fn Object* make_params_with_diag(String uri, Object* diag) {
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

fn Object* find_action_titled(Object* actions, String title) {
	usz n = actions.get_len();
	for (usz i = 0; i < n; i++) {
		Object* a = actions.get_at(i);
		String t = a.get_string("title") ?? "";
		if (t == title) return a;
	}
	return null;
}

// ── Tests ────────────────────────────────────────────────────────

fn void sealed_missing_branches_emits_action() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		DocumentStore store;
		store.init();
		defer store.free();

		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
fun area(s: Shape): Int {
    when (s) {
        is Circle -> return 1
    }
    return 0
}`;
		String uri = "file:///shapes.kt";
		store.open(uri, "kotlin", 1, src);

		Object* diags = build_diags_ws(&ws, uri, src);
		Object* diag = find_diag_with(diags, "non-exhaustive");
		assert(diag != null, "expected non-exhaustive diagnostic");

		Object* params = make_params_with_diag(uri, diag);
		Object* result = code_actions::handle_code_action(&store, &ws, params)!!;
		Object* action = find_action_titled(result, "Add missing branches");
		assert(action != null, "expected 'Add missing branches' action");

		Object* edit = action.get("edit")!!;
		Object* changes = edit.get("changes")!!;
		Object* edits = changes.get(uri)!!;
		assert(edits.get_len() == 1, "expected single edit");

		String new_text = edits.get_at(0).get_string("newText")!!;
		assert(new_text.contains("is Square -> TODO()"),
			"new text should add missing 'is Square' arm");
	};
}

fn void sealed_with_else_no_action() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		DocumentStore store;
		store.init();
		defer store.free();

		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
fun area(s: Shape): Int {
    when (s) {
        is Circle -> return 1
        else -> return 0
    }
}`;
		String uri = "file:///shapes.kt";
		store.open(uri, "kotlin", 1, src);

		Object* diags = build_diags_ws(&ws, uri, src);
		Object* diag = find_diag_with(diags, "non-exhaustive");
		assert(diag == null, "should not emit non-exhaustive when else present");
	};
}

fn void sealed_multiple_missing_inserts_all() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		DocumentStore store;
		store.init();
		defer store.free();

		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
class Triangle : Shape()
fun area(s: Shape): Int {
    when (s) {
        is Circle -> return 1
    }
    return 0
}`;
		String uri = "file:///shapes.kt";
		store.open(uri, "kotlin", 1, src);

		Object* diags = build_diags_ws(&ws, uri, src);
		Object* diag = find_diag_with(diags, "non-exhaustive");
		assert(diag != null, "expected non-exhaustive diagnostic");

		Object* params = make_params_with_diag(uri, diag);
		Object* result = code_actions::handle_code_action(&store, &ws, params)!!;
		Object* action = find_action_titled(result, "Add missing branches");
		assert(action != null, "expected action");

		String new_text = action.get("edit")!!.get("changes")!!.get(uri)!!
			.get_at(0).get_string("newText")!!;
		assert(new_text.contains("is Square -> TODO()"), "missing Square");
		assert(new_text.contains("is Triangle -> TODO()"), "missing Triangle");
	};
}
