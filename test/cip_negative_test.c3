module kls::test::cip_neg_test;

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
			TypeRef* tr = &ti.node_types[i];
			return tr.nullable ? string::tformat("%s?", tr.name) : tr.name;
		}
		seen++;
	}
	return "<not-found>";
}

// NEGATIVE: a custom user fn `maybeRun(block)` with no contract should NOT
// propagate facts from the lambda body to the caller (lambda may not run).
fn void unknown_lambda_does_not_propagate() @test {
	@pool() {
		String src =
`fun maybeRun(block: () -> Unit) {}
fun use(x: String?) {
    maybeRun { requireNotNull(x) }
    val y = x
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected x to stay nullable, got '%s'", t);
		// x should remain String? — narrowing inside lambda must not leak.
		assert(t == "String?", "%s", msg);
	};
}

// NEGATIVE: forEach has no callsInPlace contract (in stdlib it's UNKNOWN).
// Smart-cast facts inside the lambda must not leak to the caller.
fn void foreach_does_not_propagate() @test {
	@pool() {
		String src =
`fun forEach(block: (Int) -> Unit) {}
fun use(x: String?) {
    forEach { requireNotNull(x) }
    val y = x
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected x to stay nullable, got '%s'", t);
		assert(t == "String?", "%s", msg);
	};
}
