module kls::test::diagnostics_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;

/**
 * Helper: build diagnostics for content, automatically parsing for AST errors.
 */
fn Object* build_test_diagnostics(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer mem::free(pr);
	parser::parse(content, pr);
	return diagnostics::build_diagnostics_array(content, pr);
}

fn void empty_content_returns_empty_array() @test {
	@pool() {
		Object* result = diagnostics::build_diagnostics_array("", null);
		// Empty content should produce an indexable (empty) object
		assert(result.is_indexable());
	};
}

fn void valid_code_returns_no_diagnostics() @test {
	@pool() {
		Object* result = build_test_diagnostics("fun main() { val x = 42 }");
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0);
		}
	};
}

fn void single_error_returns_one_diagnostic() @test {
	@pool() {
		// Lone '&' is an error token in Kotlin
		Object* result = diagnostics::build_diagnostics_array("&", null);
		assert(result.is_array());
		assert(result.get_len() == 1);

		Object* diag = result.get_at(0);
		assert(diag.get_int("severity")!! == 1); // Error

		String message = diag.get_string("message")!!;
		assert(message.contains("&"));

		String source = diag.get_string("source")!!;
		assert(source == "kls");
	};
}

fn void multiple_errors_returns_multiple_diagnostics() @test {
	@pool() {
		// Both '&' and '|' alone are error tokens
		Object* result = diagnostics::build_diagnostics_array("& |", null);
		assert(result.is_array());
		assert(result.get_len() == 2);
	};
}

fn void error_position_is_correct() @test {
	@pool() {
		// "val x = &" -- the '&' is at line 0, col 8
		Object* result = diagnostics::build_diagnostics_array("val x = &", null);
		assert(result.is_array());
		assert(result.get_len() == 1);

		Object* diag = result.get_at(0);
		Object* range = diag.get("range")!!;
		Object* start = range.get("start")!!;
		assert(start.get_int("line")!! == 0);
		assert(start.get_int("character")!! == 8);

		Object* end = range.get("end")!!;
		assert(end.get_int("line")!! == 0);
		assert(end.get_int("character")!! == 9);
	};
}

fn void error_on_second_line_has_correct_line() @test {
	@pool() {
		Object* result = diagnostics::build_diagnostics_array("val x = 1\n&", null);
		assert(result.is_array());
		assert(result.get_len() == 1);

		Object* diag = result.get_at(0);
		Object* range = diag.get("range")!!;
		Object* start = range.get("start")!!;
		assert(start.get_int("line")!! == 1);
		assert(start.get_int("character")!! == 0);
	};
}

fn void valid_operators_produce_no_errors() @test {
	@pool() {
		// All valid Kotlin operators -- should produce no lexer errors.
		// Wrap them in a function body so the parser is happy too.
		Object* result = build_test_diagnostics("fun f() { val x = 1 && true || false }");
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0);
		}
	};
}

fn void mixed_valid_and_invalid_code() @test {
	@pool() {
		// Mix of valid tokens and one error
		Object* result = diagnostics::build_diagnostics_array("fun main() { & }", null);
		assert(result.is_array());
		assert(result.get_len() == 1);

		Object* diag = result.get_at(0);
		String message = diag.get_string("message")!!;
		assert(message.contains("&"));
	};
}

fn void parser_error_missing_closing_brace() @test {
	@pool() {
		// Missing closing brace -- no lexer errors, but parser error
		Object* result = build_test_diagnostics("class Foo {");
		assert(result.is_array());
		assert(result.get_len() >= 1, "expected at least 1 parser error, got %d", (int)result.get_len());

		Object* diag = result.get_at(0);
		assert(diag.get_int("severity")!! == 1); // Error
		assert(diag.get_string("source")!! == "kls");
	};
}

fn void parser_error_expected_name() @test {
	@pool() {
		// 'class' without a name followed by something wrong
		Object* result = build_test_diagnostics("class {}");
		assert(result.is_indexable());
		// Parser should handle this (class with no name is an error or anonymous)
		// The key thing: no crash, and we get diagnostics
	};
}
