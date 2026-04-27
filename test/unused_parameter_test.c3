module kls::test::unused_parameter_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::config;

fn Object* build_diags(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); }
	types::resolve_types(pr, ti);
	return diagnostics::build_diagnostics_array(content, pr, null, ti);
}

fn bool any_message_contains(Object* diags, String needle) {
	usz n = diags.get_len();
	for (usz i = 0; i < n; i++) {
		Object* d = diags.get_at(i);
		String msg = d.get_string("message") ?? "";
		if (msg.contains(needle)) return true;
	}
	return false;
}

fn void unused_param_warned() @test {
	@pool() {
		String src = `fun foo(x: Int) {}`;
		Object* diags = build_diags(src);
		assert(any_message_contains(diags, "Parameter 'x' is never used"),
			"expected unused-parameter hint for `x`");
	};
}

fn void underscore_param_no_warning() @test {
	@pool() {
		String src = `fun foo(_: Int) {}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Parameter '_' is never used"),
			"underscore convention — should not warn");
	};
}

fn void used_param_no_warning() @test {
	@pool() {
		String src = `fun foo(x: Int) { println(x) }`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Parameter 'x' is never used"),
			"x is used — should not warn");
	};
}

fn void override_param_no_warning() @test {
	@pool() {
		String src = `class C { override fun foo(x: Int) {} }`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Parameter 'x' is never used"),
			"override params dictated by supertype — should not warn");
	};
}

fn void primary_ctor_val_no_warning() @test {
	@pool() {
		String src = `class C(val x: Int)`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Parameter 'x' is never used"),
			"primary-ctor val is a public property — should not warn");
	};
}

fn void unused_param_disabled_via_config() @test {
	@pool() {
		bool saved = config::g_config.unused_parameter_diagnostic;
		config::g_config.unused_parameter_diagnostic = false;
		defer config::g_config.unused_parameter_diagnostic = saved;

		String src = `fun foo(x: Int) {}`;
		Object* diags = build_diags(src);
		assert(!any_message_contains(diags, "Parameter 'x' is never used"),
			"should NOT warn when unused_parameter_diagnostic is disabled");
	};
}
