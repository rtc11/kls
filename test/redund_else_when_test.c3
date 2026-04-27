module kls::test::redund_else_when_test;

import std::collections::object;
import kls::lsp::diagnostics;
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

fn void redundant_else_sealed_all_covered() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
fun area(s: Shape): Int {
    return when (s) {
        is Circle -> 1
        is Square -> 2
        else -> 0
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///s.kt", src);
		assert(any_msg_contains(diags, "'else' is redundant"),
			"expected 'else is redundant' warning");
	};
}

fn void redundant_else_enum_all_covered() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun pick(c: Color): Int {
    return when (c) {
        Color.RED -> 1
        Color.GREEN -> 2
        Color.BLUE -> 3
        else -> 0
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///c.kt", src);
		assert(any_msg_contains(diags, "'else' is redundant"),
			"expected 'else is redundant' warning for enum");
	};
}

fn void non_redundant_else_sealed_partial() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
fun area(s: Shape): Int {
    return when (s) {
        is Circle -> 1
        else -> 0
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///s.kt", src);
		assert(!any_msg_contains(diags, "'else' is redundant"),
			"else needed for missing Square — should NOT flag");
	};
}

fn void redundant_else_no_else_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`sealed class Shape
class Circle : Shape()
class Square : Shape()
fun area(s: Shape): Int {
    return when (s) {
        is Circle -> 1
        is Square -> 2
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///s.kt", src);
		assert(!any_msg_contains(diags, "'else' is redundant"),
			"no else arm — should NOT flag");
	};
}

fn void redundant_else_subjectless_when_skipped() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`fun pick(x: Int): Int {
    return when {
        x > 0 -> 1
        else -> 0
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///c.kt", src);
		assert(!any_msg_contains(diags, "'else' is redundant"),
			"subjectless when — should NOT flag");
	};
}

fn void redundant_else_non_sealed_class_skipped() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`open class Animal
class Dog : Animal()
fun describe(a: Animal): Int {
    return when (a) {
        is Dog -> 1
        else -> 0
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///a.kt", src);
		assert(!any_msg_contains(diags, "'else' is redundant"),
			"non-sealed class — should NOT flag");
	};
}
