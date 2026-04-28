module kls::test::unnecessary_not_null_test;

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

// ── Probe: declared non-null type → warn ───────────────────────

fn void declared_non_null_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	val x: String = "hi"
	println(x!!)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected 'Unnecessary !!' diagnostic for declared non-null");
	};
}

// ── Probe: nullable type → no warning ───────────────────────────

fn void nullable_type_no_warning() @test {
	@pool() {
		String content =
			`fun foo() {
	val x: String? = "hi"
	println(x!!)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Unnecessary"),
			"should not warn for nullable type");
	};
}

// ── Probe: flow-narrowed via != null check → warn ──────────────

fn void flow_narrowed_warns() @test {
	@pool() {
		String content =
			`fun foo(x: String?) {
	if (x != null) {
		println(x!!)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning when smart-cast narrowed to non-null");
	};
}

// ── Probe: string literal → warn ────────────────────────────────

fn void literal_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	val x = "literal"!!
	println(x)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning for literal!!");
	};
}

// ── Probe: this!! → warn ────────────────────────────────────────

fn void this_warns() @test {
	@pool() {
		String content =
			`class C {
	fun foo() {
		println(this!!)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning for this!!");
	};
}

// ── Probe: nullable param without narrowing → no warning ────────

fn void nullable_param_no_narrowing_no_warning() @test {
	@pool() {
		String content =
			`fun foo(x: String?) {
	println(x!!)
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Unnecessary"),
			"should not warn for unconditional !! on nullable param");
	};
}

// ── Probe edge cases for gaps ───────────────────────────────────

// !! on result of safe call where receiver is non-null — `x.foo!!` should narrow if foo returns non-null
fn void chained_call_non_null_warns() @test {
	@pool() {
		String content =
			`fun bar(): String = "hi"
fun foo() {
	val y = bar()!!
	println(y)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning for non-null fn result !!");
	};
}

// !! after `as` cast to non-null type
fn void as_cast_non_null_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Any) {
	val y = (x as String)!!
	println(y)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning for `as String` followed by !!");
	};
}

// !! on `is` check result inside narrowed branch
fn void is_check_narrows_warns() @test {
	@pool() {
		String content =
			`fun foo(x: Any?) {
	if (x is String) {
		println(x!!)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning when smart-cast via `is` to non-null type");
	};
}

// !! on requireNotNull result
fn void require_not_null_warns() @test {
	@pool() {
		String content =
			`fun foo(x: String?) {
	requireNotNull(x)
	println(x!!)
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Unnecessary"),
			"expected warning after requireNotNull narrows to non-null");
	};
}
