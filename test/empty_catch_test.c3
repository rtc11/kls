module kls::test::empty_catch_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	return diagnostics::build_diagnostics_array(content, pr);
}

fn bool has_diag_message_contains(Object* diags, String needle) {
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) return true;
	}
	return false;
}

fn int count_diag_message_contains(Object* diags, String needle) {
	int n = 0;
	for (sz i = 0; i < diags.get_len(); i++) {
		Object* d = diags.get_at((usz)i);
		String m = d.get_string("message") ?? "";
		if (m.contains(needle)) n++;
	}
	return n;
}

// ── Probe: empty catch → hint ──────────────────────────────────

fn void empty_catch_warns() @test {
	@pool() {
		String content =
			`fun foo() {
	try {
		println("x")
	} catch (e: Exception) {}
}
`;
		Object* diags = build_diags(content);
		assert(has_diag_message_contains(diags, "Empty catch block"),
			"expected empty catch hint");
	};
}

// ── Probe: non-empty catch → no hint ───────────────────────────

fn void non_empty_catch_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	try {
		println("x")
	} catch (e: Exception) {
		println(e)
	}
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Empty catch block"),
			"should not warn for non-empty catch");
	};
}

// ── Probe: rethrow catch → no hint ─────────────────────────────

fn void rethrow_catch_no_warn() @test {
	@pool() {
		String content =
			`fun foo() {
	try {
		println("x")
	} catch (e: Exception) {
		throw e
	}
}
`;
		Object* diags = build_diags(content);
		assert(!has_diag_message_contains(diags, "Empty catch block"),
			"should not warn for rethrow catch");
	};
}

// ── Probe: multiple catches, only empty flagged ────────────────

fn void only_empty_catches_flagged() @test {
	@pool() {
		String content =
			`fun foo() {
	try {
		println("x")
	} catch (e: IllegalArgumentException) {}
	catch (e: NullPointerException) {
		println(e)
	}
	catch (e: Exception) {}
}
`;
		Object* diags = build_diags(content);
		int n = count_diag_message_contains(diags, "Empty catch block");
		assert(n == 2, "expected 2 empty-catch hints, got %d", n);
	};
}
