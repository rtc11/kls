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
	defer { pr.free_errors(); mem::free(pr); }
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

// ── Unused import diagnostic tag tests ────────────────────────────

fn void unused_import_gets_unnecessary_tag() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`import com.example.Foo
fun main() { val x = 42 }`
		);
		assert(result.is_array());
		assert(result.get_len() == 1, "expected 1 diagnostic, got %d", (int)result.get_len());

		Object* diag = result.get_at(0);
		assert(diag.get_int("severity")!! == 4); // Hint
		assert(diag.get_string("source")!! == "kls");

		String message = diag.get_string("message")!!;
		assert(message.contains("Unused import"));
		assert(message.contains("com.example.Foo"));

		// Check tags array contains DiagnosticTag.Unnecessary (1)
		Object* tags = diag.get("tags")!!;
		assert(tags.is_array());
		assert(tags.get_len() == 1);
		assert(tags.get_int_at(0)!! == 1);
	};
}

fn void used_import_has_no_diagnostic() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`import com.example.Foo
fun main() { val x: Foo = Foo() }`
		);
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0, "expected 0 diagnostics for used import, got %d", (int)result.get_len());
		}
	};
}

fn void wildcard_import_not_flagged() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`import com.example.*
fun main() { val x = 42 }`
		);
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0, "expected 0 diagnostics for wildcard import, got %d", (int)result.get_len());
		}
	};
}

fn void aliased_import_used_by_alias() @test {
	@pool() {
		// Import is aliased; the alias name is used in the code
		Object* result = build_test_diagnostics(
			`import com.example.Bar as Baz
fun main() { val x: Baz = Baz() }`
		);
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0, "expected 0 diagnostics for used alias, got %d", (int)result.get_len());
		}
	};
}

fn void aliased_import_unused() @test {
	@pool() {
		// Import is aliased but the alias name is never used
		Object* result = build_test_diagnostics(
			`import com.example.Bar as Baz
fun main() { val x = 42 }`
		);
		assert(result.is_array());
		assert(result.get_len() == 1, "expected 1 diagnostic for unused alias, got %d", (int)result.get_len());

		Object* diag = result.get_at(0);
		assert(diag.get_int("severity")!! == 4); // Hint
		String message = diag.get_string("message")!!;
		assert(message.contains("Unused import"));
	};
}

fn void multiple_imports_some_unused() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`import com.example.Foo
import com.example.Bar
import com.example.Baz
fun main() { val x: Foo = Foo(); val y: Baz = Baz() }`
		);
		assert(result.is_array());
		// Only Bar is unused
		assert(result.get_len() == 1, "expected 1 unused import diagnostic, got %d", (int)result.get_len());

		Object* diag = result.get_at(0);
		String message = diag.get_string("message")!!;
		assert(message.contains("Bar"));
	};
}

fn void import_used_in_type_annotation() @test {
	@pool() {
		// The imported name appears only as a type annotation
		Object* result = build_test_diagnostics(
			`import com.example.MyType
fun process(x: MyType) {}`
		);
		assert(result.is_indexable());
		if (result.is_array()) {
			assert(result.get_len() == 0, "expected 0 diagnostics when import used as type, got %d", (int)result.get_len());
		}
	};
}

fn void import_name_in_other_import_not_counted() @test {
	@pool() {
		// "Foo" appears in another import path but not in code body
		Object* result = build_test_diagnostics(
			`import com.example.Foo
import com.other.Foo.Bar
fun main() { val x: Bar = Bar() }`
		);
		assert(result.is_array());
		// The first import (Foo) is unused -- its name only appears inside
		// another import path, which should be skipped.
		// The second import (Bar) is used in code.
		bool found_unused_foo = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			if (diag.get_int("severity")!! == 4) { // Hint = unused import
				String msg = diag.get_string("message")!!;
				if (msg.contains("com.example.Foo")) {
					found_unused_foo = true;
				}
			}
		}
		assert(found_unused_foo, "expected unused import diagnostic for com.example.Foo");
	};
}

fn void no_unused_import_when_lexer_errors_present() @test {
	@pool() {
		// When there are lexer errors, unused import analysis is skipped
		Object* result = diagnostics::build_diagnostics_array(
			`import com.example.Foo
fun main() { & }`, null
		);
		assert(result.is_array());
		// Should only have lexer error for '&', no unused import diagnostic
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			assert(diag.get_int("severity")!! != 4, "should not have Hint diagnostics when lexer errors present");
		}
	};
}

fn void single_segment_import_unused() @test {
	@pool() {
		// Single-segment import (no dots)
		Object* result = build_test_diagnostics(
			`import Foo
fun main() { val x = 42 }`
		);
		assert(result.is_array());
		assert(result.get_len() == 1, "expected 1 diagnostic for unused single-segment import, got %d", (int)result.get_len());

		Object* diag = result.get_at(0);
		assert(diag.get_int("severity")!! == 4);
		String message = diag.get_string("message")!!;
		assert(message.contains("Unused import"));
	};
}
