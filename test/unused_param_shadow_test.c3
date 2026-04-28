module kls::test::unused_param_shadow_test;

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

// abstract fn body — should NOT warn (no body to use it in)
fn void abstract_param_no_warn() @test {
	@pool() {
		String content =
			`abstract class C {
	abstract fun foo(x: Int)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'x' is never used"), "abstract fn body absent — should not flag");
	};
}

fn void expect_param_no_warn() @test {
	@pool() {
		String content =
			`expect fun foo(x: Int)
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'x' is never used"), "expect fn — no body — should not flag");
	};
}

fn void external_param_no_warn() @test {
	@pool() {
		String content =
			`external fun foo(x: Int)
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'x' is never used"), "external fn — no body — should not flag");
	};
}

fn void lambda_param_used() @test {
	@pool() {
		String content =
			`fun foo() {
	val f = { x: Int -> x + 1 }
	println(f(5))
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'x' is never used"), "lambda x is used");
	};
}

// Outer x unused; inner fn shadows with own x — outer must still flag.
fn void nested_fn_shadow_flags_outer() @test {
	@pool() {
		String content =
			`fun outer(x: Int) {
	fun inner(x: Int) {
		println(x)
	}
	inner(1)
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Parameter 'x' is never used"), "outer x unused even with inner shadowing");
	};
}

// Lambda shadow same name — outer still flagged.
fn void lambda_shadow_flags_outer() @test {
	@pool() {
		String content =
			`fun outer(x: Int) {
	val f = { x: Int -> x + 1 }
	println(f(2))
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Parameter 'x' is never used"), "outer x unused, lambda x shadows");
	};
}

// for (x in ...) shadow — outer x still flagged.
fn void for_shadow_flags_outer() @test {
	@pool() {
		String content =
			`fun outer(x: Int) {
	for (x in 0..10) {
		println(x)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Parameter 'x' is never used"), "outer x unused, for x shadows");
	};
}

// catch (x: Exception) shadow — outer x still flagged.
fn void catch_shadow_flags_outer() @test {
	@pool() {
		String content =
			`fun outer(x: Int) {
	try {
		println("hi")
	} catch (x: Exception) {
		println(x)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Parameter 'x' is never used"), "outer x unused, catch x shadows");
	};
}

// val x in inner block shadows — outer x flagged.
fn void block_val_shadow_flags_outer() @test {
	@pool() {
		String content =
			`fun outer(x: Int) {
	run {
		val x = 1
		println(x)
	}
}
`;
		Object* diags = build_diags(content);
		assert(has(diags, "Parameter 'x' is never used"), "outer x unused, inner val x shadows");
	};
}

// Use BEFORE inner shadow declaration counts — outer NOT flagged.
fn void use_before_block_shadow_keeps_outer_used() @test {
	@pool() {
		String content =
			`fun outer(x: Int) {
	println(x)
	val x2 = 1
	println(x2)
}
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'x' is never used"), "outer x used before any shadow");
	};
}

// Used only in default value of another param
fn void used_in_default_value() @test {
	@pool() {
		String content =
			`fun foo(x: Int, y: Int = x * 2): Int = y
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'x' is never used"), "x used in y's default");
	};
}

fn void used_in_string_template() @test {
	@pool() {
		String content =
			`fun foo(name: String): String = "Hello, $name"
`;
		Object* diags = build_diags(content);
		assert(!has(diags, "Parameter 'name' is never used"), "name used in template");
	};
}
