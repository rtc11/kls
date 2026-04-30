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

// Multi-condition arm covers multiple entries (Kotlin spec §17.3 —
// `c1, c2 -> body` is shorthand for separate arms with the same body).
// All entries covered across two arms — must NOT warn.
fn void enum_when_multi_cond_all_covered_no_warning() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color): String {
    return when (c) {
        Color.RED, Color.GREEN -> "rg"
        Color.BLUE -> "b"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"multi-cond covers all entries — exhaustive");
	};
}

// Multi-condition arm leaves one entry uncovered — must still warn,
// and the missing entry must be the uncovered one (not the multi-cond
// covered ones).
fn void enum_when_multi_cond_missing_one_warns() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color): String {
    return when (c) {
        Color.RED, Color.GREEN -> "rg"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(any_msg_contains(diags, "non-exhaustive"),
			"missing BLUE — must warn");
		assert(any_msg_contains(diags, "BLUE"),
			"missing entry name BLUE must appear");
		assert(!any_msg_contains(diags, "RED"),
			"RED is covered by multi-cond — must not appear in missing list");
		assert(!any_msg_contains(diags, "GREEN"),
			"GREEN is covered by multi-cond — must not appear in missing list");
	};
}

// Mixed bare / qualified entries inside one multi-cond arm (e.g. after
// `import Color.*` — bare `RED, GREEN` and qualified `Color.BLUE` both
// recognised).
fn void enum_when_multi_cond_bare_and_qualified_covered() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color): String {
    return when (c) {
        RED, Color.GREEN -> "rg"
        Color.BLUE -> "b"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		assert(!any_msg_contains(diags, "non-exhaustive"),
			"mixed bare + qualified entries cover all — exhaustive");
	};
}

// `in` patterns over an enum subject can never cover an entry by name
// (range patterns don't apply to enums in Kotlin), so an arm of the
// form `in someSet -> ...` must NOT count toward coverage; the
// remaining entries are still missing.
fn void enum_when_in_pattern_does_not_cover_entries() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();
		String src =
`enum class Color { RED, GREEN, BLUE }
fun describe(c: Color, primary: Set<Color>): String {
    return when (c) {
        in primary -> "p"
        Color.RED -> "r"
    }
}`;
		Object* diags = build_diags_ws(&ws, "file:///t.kt", src);
		// `in primary` covers nothing by name, only Color.RED is named —
		// GREEN and BLUE remain missing.
		assert(any_msg_contains(diags, "non-exhaustive"),
			"in-pattern adds no coverage; arms must still warn");
		assert(any_msg_contains(diags, "GREEN"), "GREEN must be missing");
		assert(any_msg_contains(diags, "BLUE"), "BLUE must be missing");
	};
}

