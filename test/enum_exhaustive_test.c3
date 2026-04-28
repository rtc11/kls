module kls::test::enum_exhaustive_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

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

fn void enum_when_missing_entry_emits_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color): String {
    return when (c) {
        Color.RED -> "r"
        Color.GREEN -> "g"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(any_msg_contains(diags, "non-exhaustive"),
			"expected non-exhaustive warning for enum");
		assert(any_msg_contains(diags, "BLUE"),
			"warning should mention missing 'BLUE'");
	};
}

fn void enum_when_with_else_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color): String {
    return when (c) {
        Color.RED -> "r"
        else -> "other"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"else arm makes when exhaustive");
	};
}

fn void enum_when_all_entries_covered_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color): String {
    return when (c) {
        Color.RED -> "r"
        Color.GREEN -> "g"
        Color.BLUE -> "b"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"all entries covered means exhaustive");
	};
}
