module kls::test::redund_explicit_type_test;

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

// ── Positive cases (warn) ────────────────────────────────────────

fn void int_literal_redundant() @test {
	@pool() {
		String content = `fun foo() { val x: Int = 1 }
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Explicitly given type is redundant"), "Int = 1");
	};
}

fn void string_literal_redundant() @test {
	@pool() {
		String content = `fun foo() { val s: String = "x" }
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Explicitly given type is redundant"), "String literal");
	};
}

fn void top_level_redundant() @test {
	@pool() {
		String content = `val n: Int = 42
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Explicitly given type is redundant"), "top-level Int");
	};
}

fn void member_val_redundant() @test {
	@pool() {
		String content =
			`class C {
	val x: Int = 5
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Explicitly given type is redundant"), "member Int");
	};
}

fn void boolean_literal_redundant() @test {
	@pool() {
		String content = `fun foo() { val b: Boolean = true }
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Explicitly given type is redundant"), "Boolean true");
	};
}

fn void var_redundant() @test {
	@pool() {
		String content = `fun foo() { var n: Int = 0; n = n + 1; println(n) }
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Explicitly given type is redundant"), "var n: Int = 0");
	};
}

// ── Negative cases (no warn) ─────────────────────────────────────

fn void diff_type_no_warn() @test {
	@pool() {
		String content = `fun foo() { val x: Long = 1 }
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Explicitly given type is redundant"), "Long ≠ Int");
	};
}

fn void no_type_no_warn() @test {
	@pool() {
		String content = `fun foo() { val x = 1 }
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Explicitly given type is redundant"), "no explicit type");
	};
}

fn void nullable_widening_no_warn() @test {
	@pool() {
		String content = `fun foo() { val x: Int? = 1 }
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Explicitly given type is redundant"), "Int? widens Int");
	};
}

fn void no_initializer_no_warn() @test {
	@pool() {
		String content =
			`class C {
	val x: Int

	constructor(n: Int) { x = n }
}
`;
		Object* diags = build_diags(content);
		// No initializer expression — no comparison possible.
		assert(!has(diags, "Explicitly given type is redundant"), "no initializer");
	};
}

fn void lateinit_no_warn() @test {
	@pool() {
		String content =
			`class C {
	lateinit var name: String
}
`;
		Object* diags = build_diags(content);
		// lateinit requires explicit type — never redundant.
		assert(!has(diags, "Explicitly given type is redundant"), "lateinit");
	};
}

fn void delegated_no_warn() @test {
	@pool() {
		String content =
			`import kotlin.properties.Delegates
class C {
	var n: Int by Delegates.notNull()
}
`;
		Object* diags = build_diags(content);
		// `by` delegate root — type may be required by delegate API.
		assert(!has(diags, "Explicitly given type is redundant"), "by-delegated");
	};
}
