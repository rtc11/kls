module kls::test::unit_typed_test;

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

fn int count(Object* diags, String needle) {
	int n = 0;
	for (sz i = 0; i < diags.get_len(); i++) {
		String m = diags.get_at((usz)i).get_string("message") ?? "";
		if (m.contains(needle)) n++;
	}
	return n;
}

// ── Positive ────────────────────────────────────────────────────

fn void unit_param_warns() @test {
	@pool() {
		Object* diags = build_diags("fun foo(x: Unit) {}\n");
		assert(has(diags, "has type Unit"), "param flagged");
	};
}

fn void unit_property_warns() @test {
	@pool() {
		Object* diags = build_diags("val x: Unit = Unit\n");
		assert(has(diags, "has type Unit"), "property flagged");
	};
}

fn void nullable_unit_warns() @test {
	@pool() {
		// Unit? is also pointless: only values are Unit and null.
		Object* diags = build_diags("fun foo(x: Unit?) {}\n");
		assert(has(diags, "has type Unit"), "Unit? flagged");
	};
}

fn void qualified_unit_warns() @test {
	@pool() {
		Object* diags = build_diags("fun foo(x: kotlin.Unit) {}\n");
		assert(has(diags, "has type Unit"), "kotlin.Unit flagged");
	};
}

fn void multiple_params_each_flagged() @test {
	@pool() {
		Object* diags = build_diags("fun foo(a: Unit, b: Int, c: Unit) {}\n");
		assert(count(diags, "has type Unit") == 2, "two warnings");
	};
}

// ── Negative: must NOT trigger ──────────────────────────────────

fn void int_param_no_warn() @test {
	@pool() {
		Object* diags = build_diags("fun foo(x: Int) {}\n");
		assert(!has(diags, "has type Unit"), "Int not flagged");
	};
}

fn void unit_return_type_not_flagged() @test {
	@pool() {
		// Function return-type Unit is the legitimate explicit case.
		Object* diags = build_diags("fun foo(): Unit {}\n");
		assert(!has(diags, "has type Unit"), "return type not flagged");
	};
}

fn void underscore_param_skipped() @test {
	@pool() {
		Object* diags = build_diags("fun foo(_x: Unit) {}\n");
		assert(!has(diags, "has type Unit"), "underscore opt-out");
	};
}

fn void override_param_skipped() @test {
	@pool() {
		// Override signature is dictated by parent — user can't change it.
		String content =
			`open class B { open fun f(x: Unit) {} }
class C : B() { override fun f(x: Unit) {} }
`;
		Object* diags = build_diags(content);
		// Base class still gets one warning, but override doesn't add a second.
		assert(count(diags, "has type Unit") == 1, "only base flagged, not override");
	};
}

fn void primary_ctor_val_param_not_double_flagged() @test {
	@pool() {
		// Primary-ctor `val x: Unit` produces both a PARAM (with MOD_FINAL)
		// and a PROPERTY_DECL. We skip the PARAM side to avoid duplicates.
		// Whether the PROPERTY_DECL side is flagged depends on whether the
		// parser emits a synthesized PROPERTY_DECL with a name_line — we
		// only assert no double-counting here.
		Object* diags = build_diags("class A(val x: Unit)\n");
		assert(count(diags, "has type Unit") <= 1, "no duplicate flag");
	};
}

fn void no_type_annotation_no_warn() @test {
	@pool() {
		// Implicit Unit return — no annotation, no warning.
		Object* diags = build_diags("fun foo() {}\n");
		assert(!has(diags, "has type Unit"), "implicit no-warn");
	};
}

fn void severity_is_warning() @test {
	@pool() {
		Object* diags = build_diags("fun foo(x: Unit) {}\n");
		bool found = false;
		for (sz i = 0; i < diags.get_len(); i++) {
			Object* d = diags.get_at((usz)i);
			String m = d.get_string("message") ?? "";
			if (!m.contains("has type Unit")) continue;
			int sev = d.get_int("severity") ?? 0;
			assert(sev == 2, "Warning severity");
			found = true;
		}
		assert(found, "found");
	};
}
