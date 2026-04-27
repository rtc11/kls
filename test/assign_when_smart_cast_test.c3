module kls::test::assign_when_sc_test;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

// Helper: see when_smart_cast_test.c3 for canonical version.
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

fn void assign_when_is_narrows_subject_in_arm() @test {
	@pool() {
		// Regression probe: `result = when (x) { is String -> x; ... }`
		// requires lower_stmt to descend ASSIGNMENT_EXPR's RHS so the
		// WHEN_EXPR produces COND nodes for smart-cast narrowing.
		String src =
`fun describe(x: Any) {
    var result: String = ""
    result = when (x) {
        is String -> x
        else -> "other"
    }
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

fn void assign_if_is_narrows_then_branch() @test {
	@pool() {
		String src =
`fun describe(x: Any) {
    var result: String = ""
    result = if (x is String) x else "other"
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}
