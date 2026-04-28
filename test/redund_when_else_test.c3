module kls::test::redundant_when_else_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::workspace;
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

fn bool any_diag_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

const String NEEDLE = "Redundant 'when'";

// ── Positive ──────────────────────────────────────────────────

fn void hint_for_subjectless_when_with_only_else() @test {
	@pool() {
		String content =
			`fun f(): Int {
	return when {
		else -> 42
	}
}
`;
		Object* d = build_diags(content);
		assert(any_diag_contains(d, NEEDLE), "expected hint");
	};
}

fn void hint_for_subject_when_with_only_else() @test {
	@pool() {
		String content =
			`fun f(x: Int): Int {
	return when (x) {
		else -> 0
	}
}
`;
		Object* d = build_diags(content);
		assert(any_diag_contains(d, NEEDLE), "expected hint");
	};
}

fn void hint_for_when_with_block_body() @test {
	@pool() {
		String content =
			`fun f(): String {
	return when {
		else -> {
			val x = 1
			"v=$x"
		}
	}
}
`;
		Object* d = build_diags(content);
		assert(any_diag_contains(d, NEEDLE), "expected hint");
	};
}

// ── Negative ──────────────────────────────────────────────────

fn void no_hint_when_two_arms() @test {
	@pool() {
		String content =
			`fun f(x: Int): Int {
	return when (x) {
		0 -> 1
		else -> 2
	}
}
`;
		Object* d = build_diags(content);
		assert(!any_diag_contains(d, NEEDLE), "should not hint");
	};
}

fn void no_hint_for_single_non_else_arm() @test {
	@pool() {
		String content =
			`fun f(x: Int): Int {
	return when (x) {
		0 -> 1
	}
}
`;
		Object* d = build_diags(content);
		assert(!any_diag_contains(d, NEEDLE), "single non-else arm should not hint");
	};
}

fn void no_hint_for_subjectless_with_cond_arm() @test {
	@pool() {
		String content =
			`fun f(x: Int): Int {
	return when {
		x > 0 -> 1
		else -> 0
	}
}
`;
		Object* d = build_diags(content);
		assert(!any_diag_contains(d, NEEDLE), "cond-then-else should not hint");
	};
}
