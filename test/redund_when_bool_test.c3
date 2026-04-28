module kls::test::redund_when_bool_test;

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

fn bool has(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		String m = diags.get_at((usz)i).get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

// ── Subject-less when returning bool literals ─────────────

fn void subjectless_true_else_false_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return when {
		x > 0 -> true
		else -> false
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Redundant 'when'"), "expected diag for true/false");
	};
}

fn void subjectless_false_else_true_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return when {
		x > 0 -> false
		else -> true
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "negated condition"), "expected negated diag");
	};
}

fn void subjectless_block_form_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return when {
		x > 0 -> {
			true
		}
		else -> {
			false
		}
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Redundant 'when'"), "block-wrapped literal should still flag");
	};
}

// ── Negative cases ────────────────────────────────────────

fn void with_subject_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return when (x) {
		1 -> true
		else -> false
	}
}
`;
		Object* diags = build_diags(content);
		// Subject form deferred; should NOT flag
		assert(!has(diags, "Redundant 'when'"), "subject form should not flag (deferred)");
	};
}

fn void three_branches_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return when {
		x > 0 -> true
		x < 0 -> false
		else -> true
	}
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Redundant 'when'"), "3-branch form not handled");
	};
}

fn void non_bool_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Int {
	return when {
		x > 0 -> 1
		else -> 0
	}
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Redundant 'when'"), "non-bool literals should not flag");
	};
}

fn void same_literal_no_warn() @test {
	@pool() {
		String content =
			`fun foo(x: Int): Boolean {
	return when {
		x > 0 -> true
		else -> true
	}
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Redundant 'when'"), "same literal both arms is different smell");
	};
}
