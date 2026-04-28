module kls::test::unused_private_decl_test;

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

fn void unused_private_fn() @test {
	@pool() {
		String content =
			`private fun helper() = 42

fun main() {
	println("hi")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Function 'helper' is never used"), "private fn helper unused");
	};
}

fn void unused_private_top_val() @test {
	@pool() {
		String content =
			`private val SECRET = "shh"

fun main() {
	println("hi")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Property 'SECRET' is never used"), "top-level private val unused");
	};
}

fn void unused_private_top_var() @test {
	@pool() {
		String content =
			`private var counter = 0

fun main() {
	println("hi")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Property 'counter' is never used"), "top-level private var unused");
	};
}

fn void unused_private_class() @test {
	@pool() {
		String content =
			`private class Helper {
	fun run() {}
}

fun main() {
	println("hi")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Class 'Helper' is never used"), "private class never used");
	};
}

fn void unused_private_object() @test {
	@pool() {
		String content =
			`private object Singleton

fun main() {
	println("hi")
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Object 'Singleton' is never used"), "private object never used");
	};
}

// ── Negative cases (no warn) ─────────────────────────────────────

fn void used_private_fn() @test {
	@pool() {
		String content =
			`private fun helper() = 42

fun main() {
	println(helper())
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'helper' is never used"), "helper is called");
	};
}

fn void used_private_val_in_template() @test {
	@pool() {
		String content =
			`private val name = "world"

fun main() {
	println("hello $name")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'name' is never used"), "name read in string template");
	};
}

fn void used_private_class_as_type() @test {
	@pool() {
		String content =
			`private class Helper

fun make(): Helper = Helper()
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'Helper' is never used"), "Helper used as type and ctor call");
	};
}

fn void used_private_class_in_generic() @test {
	@pool() {
		String content =
			`private class Box

fun make(): List<Box> = listOf(Box())
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'Box' is never used"), "Box appears inside generic type arg");
	};
}

// Member-private (not top-level) — out of current scope, no warn.
fn void used_private_member_fn() @test {
	@pool() {
		String content =
			`class C {
	private fun helper() = 42
	fun main() = helper()
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'helper' is never used"), "private member helper called");
	};
}

fn void unused_private_member_fn_not_flagged() @test {
	@pool() {
		String content =
			`class C {
	private fun helper() = 42
}
`;
		Object* diags = build_diags(content);
		// Member-private decls are now in scope (extended in feature 28).
		assert(has(diags, "'helper' is never used"), "private class member helper should be flagged");
	};
}

// Skipped categories.
fn void underscore_prefix_no_warn() @test {
	@pool() {
		String content =
			`private val _internal = 1

fun main() {}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'_internal' is never used"), "underscore-prefixed names skipped");
	};
}

fn void main_fn_no_warn() @test {
	@pool() {
		String content =
			`private fun main() {
	println("hi")
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "'main' is never used"), "main is the entry point");
	};
}

fn void operator_fn_no_warn() @test {
	@pool() {
		String content =
			`private operator fun Int.times(s: String) = s.repeat(this)

fun main() {
	println(3 * "ab")
}
`;
		Object* diags = build_diags(content);
		// Operator fns are called via syntax — never by bare name.
		assert(!has(diags, "'times' is never used"), "operator fns excluded");
	};
}
