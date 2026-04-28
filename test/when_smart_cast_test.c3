module kls::test::when_smart_cast_test;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

// ── Helpers ──────────────────────────────────────────────────────

/**
 * Resolve types for `src` in workspace `ws` and return the type name of
 * the `occurrence`-th NAME_EXPR with the given identifier name (0-indexed).
 * Returns sentinel strings on failure for use in assertion messages.
 */
fn String type_name_of_name_at(String src, String name, uint occurrence) {
	WorkspaceIndex ws;
	ws.init();
	defer ws.free();
	ws.index_file("file:///t.kt", src);

	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(src, pr);

	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); }
	types::set_workspace(&ws);
	types::resolve_types(pr, ti);
	types::clear_workspace();

	uint seen = 0;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != NAME_EXPR) continue;
		if (n.name != name) continue;
		if (seen == occurrence) {
			if (!ti.has_type[i]) return "<no-type>";
			return ti.node_types[i].name;
		}
		seen++;
	}
	return "<not-found>";
}

// ── Tests ────────────────────────────────────────────────────────

fn void when_is_narrows_subject_in_arm_with_block_body() @test {
	@pool() {
		String src =
`fun describe(x: Any) {
    when (x) {
        is String -> {
            val y = x
        }
        else -> {}
    }
}`;
		// Occurrence 1 = `x` in `val y = x` (occurrence 0 = subject)
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

fn void when_is_narrows_subject_in_bare_expression_arm() @test {
	@pool() {
		String src =
`fun describe(x: Any) {
    when (x) {
        is String -> x
        else -> 0
    }
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

fn void when_is_narrows_in_return_when_expression() @test {
	@pool() {
		// Regression: `return when (x) {...}` previously prevented narrowing
		// because lower_return didn't lower the WHEN_EXPR value child.
		String src =
`fun describe(x: Any): String {
    return when (x) {
        is String -> x
        else -> "other"
    }
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

fn void when_is_narrows_inside_dot_chain_in_arm() @test {
	@pool() {
		String src =
`fun len(x: Any): Int {
    return when (x) {
        is String -> x.length
        else -> 0
    }
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

fn void when_else_branch_does_not_narrow() @test {
	@pool() {
		// `else` arm should NOT narrow x to String — x stays as Any
		String src =
`fun describe(x: Any) {
    when (x) {
        is String -> {}
        else -> {
            val y = x
        }
    }
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected Any in else, got '%s'", t);
		assert(t == "Any", "%s", msg);
	};
}
