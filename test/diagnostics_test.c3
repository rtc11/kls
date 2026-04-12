module kls::test::diagnostics_test;

import std::collections::object;
import kls::lsp::diagnostics;

fn void empty_content_returns_empty_array() @test {
	@pool() {
		Object* result = diagnostics::build_diagnostics_array("");
		// Empty content should produce an indexable (empty) object
		assert(result.is_indexable());
	};
}

fn void valid_code_returns_no_diagnostics() @test {
	@pool() {
		Object* result = diagnostics::build_diagnostics_array("fun main() { val x = 42 }");
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0);
		}
	};
}

fn void single_error_returns_one_diagnostic() @test {
	@pool() {
		// Lone '&' is an error token in Kotlin
		Object* result = diagnostics::build_diagnostics_array("&");
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
		Object* result = diagnostics::build_diagnostics_array("& |");
		assert(result.is_array());
		assert(result.get_len() == 2);
	};
}

fn void error_position_is_correct() @test {
	@pool() {
		// "val x = &" -- the '&' is at line 0, col 8
		Object* result = diagnostics::build_diagnostics_array("val x = &");
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
		Object* result = diagnostics::build_diagnostics_array("val x = 1\n&");
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
		// All valid Kotlin operators
		Object* result = diagnostics::build_diagnostics_array("&& || !! ?. ?: == != + - * / %");
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0);
		}
	};
}

fn void mixed_valid_and_invalid_code() @test {
	@pool() {
		// Mix of valid tokens and one error
		Object* result = diagnostics::build_diagnostics_array("fun main() { & }");
		assert(result.is_array());
		assert(result.get_len() == 1);

		Object* diag = result.get_at(0);
		String message = diag.get_string("message")!!;
		assert(message.contains("&"));
	};
}
