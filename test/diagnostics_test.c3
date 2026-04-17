module kls::test::diagnostics_test;

import std::collections::object;
import kls::lsp::diagnostics;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::document;
import kls::workspace;

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
		Object* result = build_test_diagnostics("fun f() { val _x = 1 && true || false }");
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
fun main() { val _x = 42 }`
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
fun main() { val _x: Foo = Foo() }`
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
fun main() { val _x = 42 }`
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
fun main() { val _x: Baz = Baz() }`
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
fun main() { val _x = 42 }`
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
fun main() { val _x: Foo = Foo(); val _y: Baz = Baz() }`
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
fun main() { val _x: Bar = Bar() }`
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
fun main() { val _x = 42 }`
		);
		assert(result.is_array());
		assert(result.get_len() == 1, "expected 1 diagnostic for unused single-segment import, got %d", (int)result.get_len());

		Object* diag = result.get_at(0);
		assert(diag.get_int("severity")!! == 4);
		String message = diag.get_string("message")!!;
		assert(message.contains("Unused import"));
	};
}

// ── Unresolved reference diagnostic tests ─────────────────────────

/**
 * Helper: build diagnostics with workspace context for unresolved reference tests.
 * Uses a real WorkspaceIndex to enable stdlib/dep lookups.
 */
fn Object* build_diagnostics_with_workspace(String content) {
	ParseResult* pr = mem::new(ParseResult);
	defer { pr.free_errors(); mem::free(pr); }
	parser::parse(content, pr);

	WorkspaceIndex workspace;
	workspace.init();
	defer workspace.free();

	return diagnostics::build_diagnostics_array(content, pr, &workspace);
}

fn void auto_imported_name_no_unresolved_diagnostic() @test {
	@pool() {
		// "println" is auto-imported from kotlin.io -- should not be flagged
		Object* result = build_diagnostics_with_workspace(
			`fun main() { println("hello") }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.starts_with("Unresolved reference"),
				"auto-imported name should not be flagged, got: %s", msg);
		}
	};
}

fn void local_var_no_unresolved_diagnostic() @test {
	@pool() {
		// "x" is declared locally -- should not be flagged
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val x = 42; println(x) }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.starts_with("Unresolved reference: 'x'"),
				"locally declared variable should not be flagged");
		}
	};
}

fn void stdlib_non_auto_import_gets_unresolved_diagnostic() @test {
	@pool() {
		// "KClass" is from kotlin.reflect, which is NOT auto-imported.
		// It IS in the stdlib index, so it should get an "Unresolved reference" hint.
		// Note: must be used as a value expression (NAME_EXPR), not type annotation.
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val c = KClass }`
		);
		assert(result.is_indexable());
		bool found_unresolved = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg == "Unresolved reference: 'KClass'") {
				found_unresolved = true;
				assert(diag.get_int("severity")!! == 4, "expected Hint severity");
			}
		}
		assert(found_unresolved, "expected unresolved reference diagnostic for KClass");
	};
}

fn void imported_name_no_unresolved_diagnostic() @test {
	@pool() {
		// "KClass" is explicitly imported -- should NOT be flagged
		Object* result = build_diagnostics_with_workspace(
			`import kotlin.reflect.KClass
fun main() { val c = KClass }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'KClass'"),
				"explicitly imported name should not be flagged");
		}
	};
}

fn void wildcard_import_prevents_unresolved_diagnostic() @test {
	@pool() {
		// Wildcard import covers the package -- should NOT be flagged
		Object* result = build_diagnostics_with_workspace(
			`import kotlin.reflect.*
fun main() { val c = KClass }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'KClass'"),
				"wildcard import should prevent unresolved reference diagnostic");
		}
	};
}

fn void function_param_no_unresolved_diagnostic() @test {
	@pool() {
		// Function parameter "x" should be in scope and not flagged
		Object* result = build_diagnostics_with_workspace(
			`fun process(x: Int) { println(x) }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'x'"),
				"function parameter should not be flagged");
		}
	};
}

fn void unknown_name_not_in_any_index_no_diagnostic() @test {
	@pool() {
		// "xyzFooBarNonExistent" is not in any index -- should NOT be flagged
		// (we only flag names that we can actually suggest an import for)
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val x = xyzFooBarNonExistent() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("xyzFooBarNonExistent"),
				"unknown name not in any index should not be flagged");
		}
	};
}

fn void dot_member_not_flagged_as_unresolved() @test {
	@pool() {
		// In "x.foo()", "foo" is a member call -- should not be flagged
		// even if "foo" isn't in any index (requires type info to resolve)
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val x = "hello"; x.uppercase() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'uppercase'"),
				"dot member should not be flagged as unresolved");
		}
	};
}

fn void named_argument_label_not_flagged_as_unresolved() @test {
	@pool() {
		// Named arguments like `type = "jar"` in constructor calls should not
		// be flagged -- `type` is a parameter name label, not a variable reference.
		Object* result = build_diagnostics_with_workspace(
			`data class Lib(val group: String, val type: String = "jar")
fun main() { val lib = Lib(group = "com.example", type = "pom") }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'type'"),
				"named argument label 'type' should not be flagged as unresolved, got: %s", msg);
			assert(!msg.contains("Unresolved reference: 'group'"),
				"named argument label 'group' should not be flagged as unresolved, got: %s", msg);
		}
	};
}

fn void named_argument_value_still_checked() @test {
	@pool() {
		// The value side of a named argument should still be checked.
		// Here `KClass` is used as a value -- it's in stdlib but not auto-imported.
		Object* result = build_diagnostics_with_workspace(
			`fun foo(x: Any) {}
fun main() { foo(x = KClass) }`
		);
		assert(result.is_indexable());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg == "Unresolved reference: 'KClass'") {
				found = true;
			}
			// The label 'x' should NOT be flagged
			assert(!msg.contains("Unresolved reference: 'x'"),
				"named argument label 'x' should not be flagged, got: %s", msg);
		}
		assert(found, "value 'KClass' in named arg should still be flagged as unresolved");
	};
}

fn void class_decl_name_in_scope_no_diagnostic() @test {
	@pool() {
		// A class declared in the same file should be resolvable
		Object* result = build_diagnostics_with_workspace(
			`class Foo
fun main() { val _x = Foo() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'Foo'"),
				"locally declared class should not be flagged");
		}
	};
}

fn void unresolved_diagnostic_has_correct_position() @test {
	@pool() {
		// KClass starts at a known position -- verify the diagnostic range
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val c = KClass }` // KClass at col 21
		);
		assert(result.is_indexable());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg == "Unresolved reference: 'KClass'") {
				found = true;
				Object* range = diag.get("range")!!;
				Object* start = range.get("start")!!;
				assert(start.get_int("line")!! == 0, "expected line 0");
				assert(start.get_int("character")!! == 21, "expected col 21, got %d",
					start.get_int("character")!!);
				Object* end_pos = range.get("end")!!;
				assert(end_pos.get_int("character")!! == 27, "expected end col 27, got %d",
					end_pos.get_int("character")!!);
			}
		}
		assert(found, "expected unresolved reference diagnostic for KClass");
	};
}

// ── JDK symbol tests ──────────────────────────────────────────────

fn void jdk_uuid_gets_unresolved_diagnostic() @test {
	@pool() {
		// UUID is from java.util (not auto-imported) -- should get diagnostic
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val id = UUID.randomUUID() }`
		);
		assert(result.is_indexable());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg == "Unresolved reference: 'UUID'") {
				found = true;
			}
		}
		assert(found, "expected unresolved reference diagnostic for UUID");
	};
}

fn void jdk_java_lang_thread_no_unresolved_diagnostic() @test {
	@pool() {
		// Thread is from java.lang (auto-imported on Kotlin/JVM)
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val t = Thread.currentThread() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(msg != "Unresolved reference: 'Thread'",
				"java.lang.Thread should not be flagged (auto-imported)");
		}
	};
}

fn void jdk_file_gets_unresolved_diagnostic() @test {
	@pool() {
		// File is from java.io (not auto-imported)
		Object* result = build_diagnostics_with_workspace(
			`fun main() { val f = File("/tmp") }`
		);
		assert(result.is_indexable());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg == "Unresolved reference: 'File'") {
				found = true;
			}
		}
		assert(found, "expected unresolved reference diagnostic for File");
	};
}

fn void jdk_imported_uuid_no_unresolved_diagnostic() @test {
	@pool() {
		// UUID is explicitly imported -- no diagnostic
		Object* result = build_diagnostics_with_workspace(
			`import java.util.UUID
fun main() { val id = UUID.randomUUID() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(msg != "Unresolved reference: 'UUID'",
				"imported UUID should not be flagged as unresolved");
		}
	};
}

fn void jdk_wildcard_import_prevents_uuid_diagnostic() @test {
	@pool() {
		// java.util.* covers UUID
		Object* result = build_diagnostics_with_workspace(
			`import java.util.*
fun main() { val id = UUID.randomUUID() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(msg != "Unresolved reference: 'UUID'",
				"wildcard import should prevent UUID diagnostic");
		}
	};
}

// ── Receiver lambda member resolution tests ───────────────────────

fn void receiver_lambda_member_not_flagged_as_unresolved() @test {
	@pool() {
		// Module.() -> Unit lambda: `src` is a member of Module via data class var param
		Object* result = build_diagnostics_with_workspace(
			`data class Module(var src: String = "")

fun module(block: Module.() -> Unit) {}

fun main() {
    module { src = "example" }
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'src'"),
				"receiver lambda member 'src' should not be flagged as unresolved, got: %s", msg);
		}
	};
}

fn void receiver_lambda_multiple_members_not_flagged() @test {
	@pool() {
		// Multiple members accessed inside a receiver lambda
		Object* result = build_diagnostics_with_workspace(
			`data class Config(var name: String = "", var debug: Boolean = false)

fun configure(block: Config.() -> Unit) {}

fun main() {
    configure {
        name = "myapp"
        debug = true
    }
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'name'"),
				"receiver lambda member 'name' should not be flagged");
			assert(!msg.contains("Unresolved reference: 'debug'"),
				"receiver lambda member 'debug' should not be flagged");
		}
	};
}

fn void receiver_lambda_class_with_fun_member() @test {
	@pool() {
		// Class with a function member accessed inside receiver lambda
		Object* result = build_diagnostics_with_workspace(
			`class Builder {
    fun add(item: String) {}
}

fun build(block: Builder.() -> Unit) {}

fun main() {
    build {
        add("item1")
    }
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'add'"),
				"receiver lambda fun member 'add' should not be flagged");
		}
	};
}

fn void receiver_lambda_class_with_property_member() @test {
	@pool() {
		// Class with a property member accessed inside receiver lambda
		Object* result = build_diagnostics_with_workspace(
			`class Settings {
    var timeout: Int = 30
}

fun settings(block: Settings.() -> Unit) {}

fun main() {
    settings {
        timeout = 60
    }
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'timeout'"),
				"receiver lambda property member 'timeout' should not be flagged");
		}
	};
}

fn void non_member_in_receiver_lambda_still_checked() @test {
	@pool() {
		// A name that is NOT a member of the receiver class should still
		// go through normal resolution (not blindly skipped)
		Object* result = build_diagnostics_with_workspace(
			`data class Module(var src: String = "")

fun module(block: Module.() -> Unit) {}

fun main() {
    val x = 42
    module {
        src = "example"
        println(x)
    }
}`
		);
		assert(result.is_indexable());
		// 'x' is a local variable -- should be resolved via is_name_in_scope
		// 'println' is auto-imported from kotlin.io -- should be resolved
		// 'src' is a receiver lambda member -- should be resolved
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'x'"),
				"local var 'x' should be resolved in receiver lambda");
			assert(!msg.contains("Unresolved reference: 'src'"),
				"receiver member 'src' should be resolved");
		}
	};
}

fn void receiver_lambda_non_existing_member_not_suppressed() @test {
	@pool() {
		// A name inside a receiver lambda that is NOT a member of the
		// receiver class should NOT be suppressed (if class is in same file)
		// Note: this will only flag if the name is in some index (e.g. stdlib)
		// For completely unknown names, we don't flag at all (existing behavior)
		Object* result = build_diagnostics_with_workspace(
			`data class Module(var src: String = "")

fun module(block: Module.() -> Unit) {}

fun main() {
    module {
        src = "example"
    }
}`
		);
		// No false positives for 'src'
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'src'"),
				"receiver member 'src' should not be flagged");
		}
	};
}

fn void receiver_lambda_member_via_dot_call() @test {
	@pool() {
		// Realistic pattern: class has a member function with receiver lambda
		// and the call is via a dot expression (obj.method { ... })
		Object* result = build_diagnostics_with_workspace(
			`data class Module(var src: String = "", var name: String = "")

class Builder {
    fun module(block: Module.() -> Unit) {}
}

fun main() {
    val b = Builder()
    b.module {
        name = "example"
        src = "src/main"
    }
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'src'"),
				"receiver lambda member 'src' via dot call should not be flagged, got: %s", msg);
			assert(!msg.contains("Unresolved reference: 'name'"),
				"receiver lambda member 'name' via dot call should not be flagged, got: %s", msg);
		}
	};
}

fn void destructuring_lambda_param_no_unresolved() @test {
	@pool() {
		Object* result = build_diagnostics_with_workspace(
`fun foo() {
    list.map { (_, dp) -> dp.name }
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'dp'"),
				"destructuring lambda param 'dp' should not be flagged, got: %s", msg);
		}
	};
}

fn void same_package_symbol_no_unresolved() @test {
	@pool() {
		// Index a file that declares AggregateService in package abetal
		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();
		workspace.index_file("file:///test/AggregateService.kt",
			"package abetal\nobject AggregateService {\n    fun utledSimulering() {}\n}");

		// The file under test is also in package abetal and references AggregateService
		String content =
`package abetal
fun foo() {
    AggregateService.utledSimulering()
}`;
		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);

		Object* result = diagnostics::build_diagnostics_array(content, pr, &workspace);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'AggregateService'"),
				"same-package symbol should not be flagged, got: %s", msg);
		}
	};
}

fn void extension_function_implicit_this_member_not_flagged() @test {
	@pool() {
		Object* result = build_diagnostics_with_workspace(
			`import no.trygdeetaten.skjema.oppdrag.Oppdrag

private fun Oppdrag.info(): String {
    val last = oppdrag110.oppdragsLinje150s.last()
    return oppdrag110.kodeFagomraade
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'oppdrag110'"),
				"extension function implicit this member should not be flagged, got: %s", msg);
		}
	};
}

fn void extension_function_with_local_class_member_check() @test {
	@pool() {
		Object* result = build_diagnostics_with_workspace(
			`class MyClass(val name: String)

fun MyClass.greet(): String {
    return name
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'name'"),
				"extension function member 'name' should not be flagged, got: %s", msg);
		}
	};
}

fn void star_imported_workspace_function_not_flagged() @test {
	@pool() {
		// Index a file that declares bytes() in package libs.kafka
		// Mirrors the real Serde.kt structure: object Serde { ... } then top-level fun bytes()
		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();
		workspace.index_file("file:///libs/kafka/Serde.kt",
`package libs.kafka
object Serde {
    inline fun xml() = Unit
    inline fun json() = Unit
    fun string() = Unit
}
fun string() = Unit
fun bytes() = Unit
inline fun json() = Unit
inline fun xml() = Unit`);

		// Verify bytes is actually indexed
		if (try indices = workspace.lookup_by_name("bytes")) {
			assert(indices.len() > 0, "expected 'bytes' in workspace index");
		} else {
			assert(false, "bytes not found in workspace index at all");
		}

		// The file under test star-imports libs.kafka and calls bytes()
		// Uses actual Kafka.kt structure with multiple imports and Topic calls
		String content =
`package abetal

import libs.kafka.*
import libs.kafka.processor.EnrichMetadataProcessor
import libs.kafka.processor.Processor
import libs.kafka.stream.MappedStream
import libs.utils.appLog
import libs.utils.intoUids
import libs.utils.sha256
import models.*

const val FS_KEY = "fagsystem"

object Topics {
    val dp = Topic("teamdagpenger.utbetaling.v1", bytes())
    val aap = Topic("aap.utbetaling.v1", bytes())
    val ts = Topic("tilleggsstonader.utbetaling.v1", bytes())
}`;
		ParseResult* pr = mem::new(ParseResult);
		defer { pr.free_errors(); mem::free(pr); }
		parser::parse(content, pr);

		Object* result = diagnostics::build_diagnostics_array(content, pr, &workspace);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("Unresolved reference: 'bytes'"),
				"star-imported workspace function should not be flagged, got: %s", msg);
		}
	};
}

// ── Deprecated usage diagnostic tests ─────────────────────────────

fn void deprecated_function_usage_gets_tag() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`@Deprecated("use newFoo instead")
fun oldFoo() {}

fun main() { oldFoo() }`
		);
		assert(result.is_array());
		bool found_deprecated = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg.contains("deprecated")) {
				found_deprecated = true;
				assert(diag.get_int("severity")!! == 4, "deprecated should be Hint severity");
				Object* tags = diag.get("tags")!!;
				assert(tags.is_array());
				assert(tags.get_len() == 1);
				assert(tags.get_int_at(0)!! == 2, "expected DiagnosticTag.Deprecated (2)");
			}
		}
		assert(found_deprecated, "expected a deprecated diagnostic for oldFoo usage");
	};
}

fn void deprecated_class_usage_gets_tag() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`@Deprecated("use NewClass")
class OldClass

fun main() { val _x = OldClass() }`
		);
		assert(result.is_array());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg.contains("'OldClass' is deprecated")) {
				found = true;
				Object* tags = diag.get("tags")!!;
				assert(tags.get_int_at(0)!! == 2);
			}
		}
		assert(found, "expected deprecated diagnostic for OldClass");
	};
}

fn void non_deprecated_no_tag() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`fun normalFun() {}
fun main() { normalFun() }`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("deprecated"), "no deprecated diagnostics expected, got: %s", msg);
		}
	};
}

// ── Unused local variable diagnostic tests ────────────────────────

fn void unused_val_gets_unnecessary_tag() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`fun main() {
    val unused = 42
}`
		);
		assert(result.is_array());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg.contains("'unused' is never used")) {
				found = true;
				assert(diag.get_int("severity")!! == 4, "unused local should be Hint");
				Object* tags = diag.get("tags")!!;
				assert(tags.get_int_at(0)!! == 1, "expected DiagnosticTag.Unnecessary (1)");
				assert(msg.contains("Value"), "val should say 'Value', got: %s", msg);
			}
		}
		assert(found, "expected unused local diagnostic");
	};
}

fn void unused_var_says_variable() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`fun main() {
    var unused = 42
}`
		);
		assert(result.is_array());
		bool found = false;
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			if (msg.contains("'unused' is never used")) {
				found = true;
				assert(msg.contains("Variable"), "var should say 'Variable', got: %s", msg);
			}
		}
		assert(found, "expected unused var diagnostic");
	};
}

fn void used_local_no_diagnostic() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`fun main() {
    val x = 42
    println(x)
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("is never used"), "used local should not be flagged, got: %s", msg);
		}
	};
}

fn void underscore_prefix_not_flagged() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`fun main() {
    val _ignored = 42
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("is never used"), "_prefix should not be flagged, got: %s", msg);
		}
	};
}

fn void top_level_val_not_flagged() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`val topLevel = 42`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("is never used"), "top-level val should not be flagged, got: %s", msg);
		}
	};
}

fn void class_property_not_flagged() @test {
	@pool() {
		Object* result = build_test_diagnostics(
			`class Foo {
    val bar = 42
}`
		);
		assert(result.is_indexable());
		for (usz i = 0; i < result.get_len(); i++) {
			Object* diag = result.get_at(i);
			String msg = diag.get_string("message") ?? "";
			assert(!msg.contains("is never used"), "class property should not be flagged, got: %s", msg);
		}
	};
}
