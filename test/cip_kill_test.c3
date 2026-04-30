module kls::test::cip_kill_test;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::workspace;

// Resolve the type displayed for the `occurrence`-th NAME_EXPR named
// `name` in `src`. Mirrors helper used in cip_propagation_test /
// cip_negative_test.
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

// Resolve the type for the `occurrence`-th DOT_EXPR matching `recv.member`
// (looking at the DOT_EXPR's own resolved type — i.e. the type of the
// member access).
fn String type_name_of_dot_at(String src, String recv, String member, uint occurrence) {
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
		// First child is receiver; check it's NAME_EXPR(recv).
		uint rcv = uint.max;
		for (uint c = n.children_start; c < pr.node_count; c++) {
			if (pr.nodes[c].parent != i) continue;
			rcv = c;
			break;
		}
		if (rcv == uint.max) continue;
		AstNode* rn = &pr.nodes[rcv];
		if (rn.kind != NAME_EXPR) continue;
		if (rn.name != recv) continue;
		if (seen == occurrence) {
			if (!ti.has_type[i]) return "<no-type>";
			TypeRef* tr = &ti.node_types[i];
			return tr.nullable ? string::tformat("%s?", tr.name) : tr.name;
		}
		seen++;
	}
	return "<not-found>";
}

// A member smart cast established before a forEach { … } that
// reassigns the member must be invalidated after the forEach,
// even though forEach has no callsInPlace contract (UNKNOWN
// invocation kind — the lambda may run zero+ times). Kotlin spec
// §11.3: smart casts are invalidated by possible mutation.
fn void unknown_lambda_kills_member_smart_cast() @test {
	@pool() {
		String src =
`class B { var x: String? = null }
fun forEach(block: (Int) -> Unit) {}
fun use(b: B) {
    if (b.x == null) return
    forEach { b.x = null }
    val y = b.x
}`;
		// `b.x` after the forEach should be String? again (member fact killed).
		String t = type_name_of_dot_at(src, "b", "x", 1);
		String msg = string::tformat("expected String?, got '%s'", t);
		assert(t == "String?", "%s", msg);
	};
}

// Same but with a contract-bearing scope function (also = EXACTLY_ONCE):
// the assignment inside DOES kill the smart cast — and contract
// propagation already accounts for facts established by the lambda body.
fn void exactly_once_lambda_assignment_kills_smart_cast() @test {
	@pool() {
		String src =
`class B { var x: String? = null }
fun use(b: B, y: Int) {
    if (b.x == null) return
    y.also { b.x = null }
    val z = b.x
}`;
		String t = type_name_of_dot_at(src, "b", "x", 1);
		String msg = string::tformat("expected String?, got '%s'", t);
		assert(t == "String?", "%s", msg);
	};
}

// Custom user fn with no contract — assignment inside its lambda must
// still invalidate the caller's member smart cast.
fn void user_unknown_lambda_kills_smart_cast() @test {
	@pool() {
		String src =
`class B { var x: String? = null }
fun maybeRun(block: () -> Unit) {}
fun use(b: B) {
    if (b.x == null) return
    maybeRun { b.x = null }
    val y = b.x
}`;
		String t = type_name_of_dot_at(src, "b", "x", 1);
		String msg = string::tformat("expected String?, got '%s'", t);
		assert(t == "String?", "%s", msg);
	};
}

// Nested lambda assignment: even deep inside another (non-cip) lambda,
// reassignment must propagate kill outwards.
fn void nested_unknown_lambda_kills_smart_cast() @test {
	@pool() {
		String src =
`class B { var x: String? = null }
fun maybeRun(block: () -> Unit) {}
fun forEach(block: (Int) -> Unit) {}
fun use(b: B) {
    if (b.x == null) return
    maybeRun { forEach { b.x = null } }
    val y = b.x
}`;
		String t = type_name_of_dot_at(src, "b", "x", 1);
		String msg = string::tformat("expected String?, got '%s'", t);
		assert(t == "String?", "%s", msg);
	};
}

// Note: local-var reassignment inside an UNKNOWN lambda is already
// blocked at the type-resolution layer by the stability gate
// (`is_stable_for_smart_cast`): a local var captured by a nested
// function-like is unstable when used from a different enclosing
// function — so a smart cast established in the outer function is
// not applied at the use site once the var is captured. The kill
// pass added in flow.c3 specifically covers MEMBER reassignments
// (`b.x = ...`) and receiver reassignments (`b = ...`) that bypass
// the capture-aware stability check, since member smart casts
// otherwise persist across calls.