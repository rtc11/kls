module kls::test::sealed_exhaustive_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;
import kls::config;

/**
 * Build diagnostics with workspace context (sealed-subtype enumeration
 * needs workspace.super_index).
 */
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

fn void sealed_when_missing_subtype_emits_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
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
		Object* diags = build_diags_ws(&ws, "file:///shapes.kt", src);
		assert(any_msg_contains(diags, "non-exhaustive") || any_msg_contains(diags, "Square"),
			"expected non-exhaustive warning mentioning missing 'Square'");
	};
}

fn void sealed_when_with_else_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
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
		Object* diags = build_diags_ws(&ws, "file:///shapes.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"with else arm should not emit non-exhaustive warning");
	};
}

fn void sealed_when_all_subtypes_covered_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
fun area(s: Shape): Int {
    when (s) {
        is Circle -> return 1
        is Square -> return 2
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///shapes.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"all subtypes covered should not emit non-exhaustive warning");
	};
}

fn void non_sealed_when_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Shape
class Circle : Shape()
fun area(s: Shape): Int {
    when (s) {
        is Circle -> return 1
    }
    return 0
}`;
		Object* diags = build_diags_ws(&ws, "file:///shapes.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"non-sealed parent should not emit exhaustiveness warning");
	};
}
