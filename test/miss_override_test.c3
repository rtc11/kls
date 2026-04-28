module kls::test::miss_override_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::lsp::code_actions;
import kls::document;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;
import kls::config;

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

fn void warns_when_class_fun_matches_open_supertype() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Base {
    open fun greet() {}
}
class Sub : Base() {
    fun greet() {}
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(any_msg_contains(diags, "lacks 'override'"),
			"expected missing-override warning for Sub.greet");
	};
}

fn void no_warn_when_override_present() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Base {
    open fun greet() {}
}
class Sub : Base() {
    override fun greet() {}
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "lacks 'override'"),
			"override present — no warning expected");
	};
}

fn void no_warn_when_no_supertype_match() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Base {
    open fun greet() {}
}
class Sub : Base() {
    fun other() {}
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "lacks 'override'"),
			"distinct method name — no warning expected");
	};
}

fn void no_warn_when_arity_differs() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Base {
    open fun greet() {}
}
class Sub : Base() {
    fun greet(x: Int) {}
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "lacks 'override'"),
			"different arity — no warning expected");
	};
}

fn void no_warn_for_top_level_fun() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src = `fun greet() {}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "lacks 'override'"),
			"top-level fun has no enclosing class");
	};
}

fn void warns_for_interface_supertype_match() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`interface Greeter {
    fun greet()
}
class Hello : Greeter {
    fun greet() {}
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(any_msg_contains(diags, "lacks 'override'"),
			"expected warning for unmarked interface impl");
	};
}

fn void no_warn_for_operator_fun() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Base {
    open fun plus(other: Int): Int = 0
}
class Sub : Base() {
    operator fun plus(other: Int): Int = 1
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "lacks 'override'"),
			"operator fun skipped (could be unrelated)");
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

fn void quickfix_inserts_override_modifier() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String content =
`open class Base {
    open fun greet() {}
}
class Sub : Base() {
    fun greet() {}
}`;
		String uri = "file:///t.kt";
		Object* diags = build_diags_ws(&ws, uri, content);
		Object* diag = find_diag_with(diags, "lacks 'override'");
		assert(diag != null, "expected missing-override diag");

		DocumentStore store;
		store.init();
		defer store.free();
		store.open(uri, "kotlin", 1, content);

		Object* params = make_action_params(uri, diag);
		Object* result = code_actions::handle_code_action(&store, &ws, params)!!;

		bool found = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* a = result.get_at((usz)i);
			String title = a.get_string("title") ?? "";
			if (title == "Add 'override' modifier") {
				found = true;
				Object* edit = a.get("edit")!!;
				Object* changes = edit.get("changes")!!;
				Object* edits = changes.get(uri)!!;
				assert(edits.get_len() == 1, "expected 1 edit");
				Object* e = edits.get_at(0);
				String new_text = e.get_string("newText") ?? "";
				assert(new_text == "override ", "expected 'override ', got '%s'", new_text);
				break;
			}
		}
		assert(found, "expected 'Add override modifier' action");
	};
}
