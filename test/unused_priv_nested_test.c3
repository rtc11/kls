module kls::test::unused_priv_nested_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

fn bool diag_contains(String content, String needle) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	Object* arr = diagnostics::build_diagnostics_array(content, pr, null, ti);
	for (sz i = 0; i < arr.get_len(); i++) {
		Object* d = arr.get_at((usz)i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

fn void unused_private_method_in_class_flagged() @test {
	@pool() {
		String c = `class Foo {
	private fun helper() {}
	fun publicApi() {}
}`;
		assert(diag_contains(c, "Function 'helper' is never used"),
			"unused private method in class should be flagged");
	};
}

fn void used_private_method_in_class_not_flagged() @test {
	@pool() {
		String c = `class Foo {
	private fun helper() = 1
	fun publicApi() = helper()
}`;
		assert(!diag_contains(c, "'helper' is never used"),
			"called private method should not be flagged");
	};
}

fn void unused_private_property_in_class_flagged() @test {
	@pool() {
		String c = `class Foo {
	private val secret = 42
	fun publicApi() {}
}`;
		assert(diag_contains(c, "Property 'secret' is never used"),
			"unused private property in class should be flagged");
	};
}

fn void unused_private_method_in_object_flagged() @test {
	@pool() {
		String c = `object Bar {
	private fun helper() {}
	fun publicApi() {}
}`;
		assert(diag_contains(c, "Function 'helper' is never used"),
			"unused private method in object should be flagged");
	};
}

fn void unused_private_method_in_companion_flagged() @test {
	@pool() {
		String c = `class Foo {
	companion object {
		private fun helper() {}
		fun publicApi() {}
	}
}`;
		assert(diag_contains(c, "Function 'helper' is never used"),
			"unused private method in companion should be flagged");
	};
}

fn void unused_private_method_in_interface_flagged() @test {
	@pool() {
		// Kotlin 1.4+ allows private methods in interfaces (default impls).
		String c = `interface I {
	private fun helper() {}
	fun publicApi() {}
}`;
		assert(diag_contains(c, "Function 'helper' is never used"),
			"unused private method in interface should be flagged");
	};
}

fn void used_private_property_via_this_not_flagged() @test {
	@pool() {
		String c = `class Foo {
	private val secret = 42
	fun publicApi(): Int = this.secret
}`;
		assert(!diag_contains(c, "'secret' is never used"),
			"this.secret should count as a reference");
	};
}

fn void used_via_member_access_in_other_method_not_flagged() @test {
	@pool() {
		String c = `class Foo {
	private val tag = "F"
	fun publicApi(): String = tag
}`;
		assert(!diag_contains(c, "'tag' is never used"),
			"bare-name reference within class should count");
	};
}

fn void overridden_member_not_flagged() @test {
	@pool() {
		// Override is excluded by existing MOD_OVERRIDE check.
		String c = `interface I { fun foo() }
class Impl : I {
	private fun helper() {}
	override fun foo() { helper() }
}`;
		assert(!diag_contains(c, "'helper' is never used"));
	};
}

fn void underscore_prefix_skipped() @test {
	@pool() {
		String c = `class Foo {
	private val _cache = 1
	fun publicApi() {}
}`;
		assert(!diag_contains(c, "'_cache' is never used"),
			"underscore prefix should be skipped");
	};
}

fn void cross_member_call_chain_not_flagged() @test {
	@pool() {
		String c = `class Foo {
	private fun a() = b()
	private fun b() = 1
	fun publicApi() = a()
}`;
		assert(!diag_contains(c, "'a' is never used"));
		assert(!diag_contains(c, "'b' is never used"));
	};
}

fn void nested_class_decl_inside_class_flagged() @test {
	@pool() {
		String c = `class Outer {
	private class Helper { fun work() {} }
	fun publicApi() {}
}`;
		assert(diag_contains(c, "Class 'Helper' is never used"),
			"unused private nested class should be flagged");
	};
}
