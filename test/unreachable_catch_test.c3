module kls::test::unreachable_catch_test;

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

// ── Probe: Exception then IOException → warn ───────────────────

fn void exception_then_subtype_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	try { } catch (e: Exception) { } catch (e: RuntimeException) { }
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "unreachable"),
			"expected unreachable catch for RuntimeException after Exception");
	};
}

// ── Probe: Throwable then Exception → warn ─────────────────────

fn void throwable_then_exception_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	try { } catch (e: Throwable) { } catch (e: Exception) { }
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "unreachable"),
			"expected unreachable catch for Exception after Throwable");
	};
}

// ── Probe: RuntimeException then IllegalArgumentException → warn

fn void rte_then_iae_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	try { } catch (e: RuntimeException) { } catch (e: IllegalArgumentException) { }
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "unreachable"),
			"expected unreachable catch for IAE after RuntimeException");
	};
}

// ── Probe: sibling exceptions → no warn ────────────────────────

fn void sibling_exceptions_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	try { } catch (e: IllegalArgumentException) { } catch (e: IllegalStateException) { }
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "unreachable"),
			"should not warn for sibling RuntimeException subtypes");
	};
}

// ── Probe: single catch → no warn ──────────────────────────────

fn void single_catch_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	try { } catch (e: Exception) { }
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "unreachable"),
			"should not warn for single catch");
	};
}

// ── Probe: subtype before supertype → no warn ──────────────────

fn void subtype_before_supertype_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	try { } catch (e: IllegalArgumentException) { } catch (e: Exception) { }
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "unreachable"),
			"should not warn when subtype caught first (correct ordering)");
	};
}
