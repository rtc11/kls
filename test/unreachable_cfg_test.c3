module kls::test::unreachable_cfg_test;

import kls::lsp::diagnostics;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::kotlin::ast;
import std::collections::object;

fn Object* build_diags(String src) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(src, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(src, pr, null, ti);
}

fn bool has_msg_containing(Object* arr, String needle) {
	for (usz i = 0; i < arr.get_len(); i++) {
		Object* d = arr.get_at(i);
		String msg = d.get_string("message")!!;
		if (msg.contains(needle)) return true;
	}
	return false;
}

// Probe: both branches of if/else diverge — code after should be flagged.
fn void unreachable_after_if_else_both_diverge() @test {
	@pool() {
		Object* d = build_diags(
`fun test(b: Boolean): Int {
    if (b) return 1 else return 2
    val x = 3
}`);
		assert(has_msg_containing(d, "Unreachable"),
			"both-diverge if/else fallthrough not flagged");
	};
}

// Probe: when with all arms returning — fallthrough unreachable.
fn void unreachable_after_exhaustive_when_all_return() @test {
	@pool() {
		Object* d = build_diags(
`fun test(x: Int): Int {
    when (x) {
        1 -> return 10
        else -> return 20
    }
    val y = 1
}`);
		assert(has_msg_containing(d, "Unreachable"),
			"when-all-return fallthrough not flagged");
	};
}

// Negative: only one branch diverges — fallthrough still reachable.
fn void no_unreachable_when_only_one_branch_diverges() @test {
	@pool() {
		Object* d = build_diags(
`fun test(b: Boolean): Int {
    if (b) return 1
    val x = 2
    return x
}`);
		assert(!has_msg_containing(d, "Unreachable"),
			"single-branch return should leave fallthrough reachable");
	};
}
