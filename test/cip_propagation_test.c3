module kls::test::cip_test;

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

// Probe: run { requireNotNull(x) } executes lambda exactly once,
// so x should be non-null after the call.
fn void run_block_propagates_require_not_null() @test {
	@pool() {
		String src =
`fun use(x: String?) {
    run { requireNotNull(x) }
    val y = x
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

// Probe: with(obj) { requireNotNull(x) } — same propagation.
fn void with_propagates_require_not_null() @test {
	@pool() {
		String src =
`fun use(x: String?, obj: Any) {
    with(obj) { requireNotNull(x) }
    val y = x
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}

// Probe: also { requireNotNull(x) } on receiver — lambda exactly once.
fn void also_propagates_require_not_null() @test {
	@pool() {
		String src =
`fun use(x: String?, y: Int) {
    y.also { requireNotNull(x) }
    val z = x
}`;
		String t = type_name_of_name_at(src, "x", 1);
		String msg = string::tformat("expected String, got '%s'", t);
		assert(t == "String", "%s", msg);
	};
}
