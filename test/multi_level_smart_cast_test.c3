module kls::test::ml_smart_cast_test;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

// Find the Nth DOT_EXPR whose .name matches.
fn String type_name_of_dot(String src, String member, uint occurrence) {
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
		if (n.kind != DOT_EXPR) continue;
		if (n.name != member) continue;
		if (seen == occurrence) {
			if (!ti.has_type[i]) return "<no-type>";
			TypeRef* tr = &ti.node_types[i];
			return tr.nullable ? string::tformat("%s?", tr.name) : tr.name;
		}
		seen++;
	}
	return "<not-found>";
}

// Probe: a.b.c smart cast through != null check.
fn void multi_level_member_smart_cast_via_not_null() @test {
	@pool() {
		String src =
`class C(val name: String)
class B(val c: C?)
class A(val b: B)
fun use(a: A) {
    if (a.b.c != null) {
        val x = a.b.c
    }
}`;
		// DOT_EXPR `a.b.c` occurs twice: in the if-cond and in val x = a.b.c.
		// We want occurrence 1 (the use after narrowing).
		String t = type_name_of_dot(src, "c", 1);
		String msg = string::tformat("expected C (non-null), got '%s'", t);
		assert(t == "C", "%s", msg);
	};
}

// Multi-level via elvis-return.
fn void multi_level_member_elvis_return() @test {
	@pool() {
		String src =
`class C(val name: String)
class B(val c: C?)
class A(val b: B)
fun use(a: A): String {
    val v = a.b.c ?: return "none"
    return a.b.c.name
}`;
		// `a.b.c` after elvis-return should be C (non-null).
		// Occurrences of DOT_EXPR with name="c": [0] cond `a.b.c`, [1] in
		// the return `a.b.c.name`'s receiver chain.
		String t = type_name_of_dot(src, "c", 1);
		String msg = string::tformat("expected C, got '%s'", t);
		assert(t == "C", "%s", msg);
	};
}

// Negative: receiver reassignment kills the multi-level fact.
fn void multi_level_member_killed_on_receiver_reassign() @test {
	@pool() {
		String src =
`class C(val name: String)
class B(val c: C?)
class A(var b: B)
fun use(a: A, fresh: B) {
    if (a.b.c != null) {
        a.b = fresh
        val x = a.b.c
    }
}`;
		// After `a.b = fresh`, a.b.c is no longer narrowed.
		String t = type_name_of_dot(src, "c", 1);
		String msg = string::tformat("expected C? after kill, got '%s'", t);
		assert(t == "C?", "%s", msg);
	};
}
