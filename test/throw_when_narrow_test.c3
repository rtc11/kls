module kls::test::throw_when_narrow_test;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

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

fn void throw_when_arm_narrows_subject() @test {
	@pool() {
		// `throw when (x) { is RuntimeException -> x; else -> RuntimeException() }`
		// Inside `is RuntimeException -> x`, x should be narrowed.
		String src =
`fun rethrow(x: Any) {
    throw when (x) {
        is RuntimeException -> x
        else -> RuntimeException()
    }
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected RuntimeException, got '%s'", t);
		assert(t == "RuntimeException", "%s", msg);
	};
}

fn void throw_if_expr_narrows_in_branch() @test {
	@pool() {
		// `throw if (x is IllegalStateException) x else RuntimeException()`
		// In the then branch, x narrows to IllegalStateException.
		String src =
`fun rethrow(x: Throwable) {
    throw if (x is IllegalStateException) x else RuntimeException()
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected IllegalStateException, got '%s'", t);
		assert(t == "IllegalStateException", "%s", msg);
	};
}
