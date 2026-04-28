module kls::test::var_can_be_val_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool has_diag_message_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Probe: var never reassigned → emit hint ─────────────────────

fn void var_never_reassigned_emits_hint() @test {
	@pool() {
		String content =
			`fun foo() {
	var x = 42
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Variable 'x' can be 'val'"),
			"expected 'can be val' hint");
	};
}

// ── Probe: var reassigned via `=` → no hint ─────────────────────

fn void var_reassigned_no_hint() @test {
	@pool() {
		String content =
			`fun foo() {
	var x = 42
	x = 99
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Variable 'x' can be 'val'"),
			"should not emit hint when reassigned");
	};
}

// ── Probe: var with `++` → no hint ──────────────────────────────

fn void var_postfix_inc_no_hint() @test {
	@pool() {
		String content =
			`fun foo() {
	var x = 42
	x++
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Variable 'x' can be 'val'"),
			"should not emit hint with x++");
	};
}

// ── Probe: var with `+=` → no hint ──────────────────────────────

fn void var_compound_assign_no_hint() @test {
	@pool() {
		String content =
			`fun foo() {
	var x = 42
	x += 1
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Variable 'x' can be 'val'"),
			"should not emit hint with x +=");
	};
}

// ── Probe: val never reassigned → no hint (already val) ─────────

fn void val_no_hint() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = 42
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "can be 'val'"),
			"should not emit hint for val");
	};
}

// ── Probe: top-level var → no hint (skip top-level) ─────────────

fn void top_level_var_no_hint() @test {
	@pool() {
		String content =
			`var topX = 42
fun use() = topX
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Variable 'topX' can be 'val'"),
			"should not emit hint for top-level var");
	};
}

// ── Probe: var reassigned via prefix `--` → no hint ─────────────

fn void var_prefix_dec_no_hint() @test {
	@pool() {
		// Use semicolon to avoid `42 --x` being parsed as binary expr
		String content =
			`fun foo() {
	var x = 42;
	--x;
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Variable 'x' can be 'val'"),
			"should not emit hint with --x");
	};
}
