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

fn void class_decl_name_in_scope_no_diagnostic() @test {
	@pool() {
		// A class declared in the same file should be resolvable
		Object* result = build_diagnostics_with_workspace(
			`class Foo
fun main() { val x = Foo() }`
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

// ── Pull diagnostics tests (LSP 3.17) ────────────────────────────

/**
 * Helper: create a DocumentStore with one document and return it.
 * Caller must call store.free() when done.
 */
fn DocumentStore create_test_store(String uri, String content, int version = 1) {
	DocumentStore store;
	store.init();
	store.open(uri, "kotlin", version, content);
	return store;
}

/**
 * Helper: build textDocument/diagnostic params.
 */
fn Object* build_doc_diagnostic_params(String uri, String prev_result_id = "") {
	Object* params = object::new_obj(tmem);
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	params.set("textDocument", td);
	if (prev_result_id.len > 0) {
		params.set("previousResultId", prev_result_id);
	}
	return params;
}

fn void document_diagnostic_returns_full_report() @test {
	@pool() {
		DocumentStore store = create_test_store("file:///test.kt", "fun main() {}");
		defer store.free();

		Object* params = build_doc_diagnostic_params("file:///test.kt");
		Object* result = diagnostics::handle_document_diagnostic(&store, null, params);

		String kind = result.get_string("kind")!!;
		assert(kind == "full", "expected kind 'full'");

		// resultId should be present
		String result_id = result.get_string("resultId")!!;
		assert(result_id.len > 0, "expected non-empty resultId");
		assert(result_id == "v1", "expected resultId 'v1' for version 1");

		// items should be present (valid code = empty array)
		Object* items = result.get("items")!!;
		assert(items.is_indexable(), "expected items to be indexable");
	};
}

fn void document_diagnostic_returns_unchanged_when_same_version() @test {
	@pool() {
		DocumentStore store = create_test_store("file:///test.kt", "fun main() {}", 3);
		defer store.free();

		// First pull to get the result ID
		Object* params = build_doc_diagnostic_params("file:///test.kt", "v3");
		Object* result = diagnostics::handle_document_diagnostic(&store, null, params);

		String kind = result.get_string("kind")!!;
		assert(kind == "unchanged", "expected kind 'unchanged' when previousResultId matches");

		String result_id = result.get_string("resultId")!!;
		assert(result_id == "v3", "expected resultId 'v3'");

		// items should NOT be present for unchanged reports
		Object* items = result.get("items") ?? null;
		assert(items == null, "unchanged report should not have items");
	};
}

fn void document_diagnostic_returns_full_when_version_differs() @test {
	@pool() {
		DocumentStore store = create_test_store("file:///test.kt", "fun main() {}", 5);
		defer store.free();

		// Pass a stale result ID
		Object* params = build_doc_diagnostic_params("file:///test.kt", "v3");
		Object* result = diagnostics::handle_document_diagnostic(&store, null, params);

		String kind = result.get_string("kind")!!;
		assert(kind == "full", "expected kind 'full' when version differs");

		String result_id = result.get_string("resultId")!!;
		assert(result_id == "v5", "expected resultId 'v5' for version 5");

		Object* items = result.get("items")!!;
		assert(items.is_indexable(), "expected items in full report");
	};
}

fn void document_diagnostic_unknown_uri_returns_empty_full() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = build_doc_diagnostic_params("file:///nonexistent.kt");
		Object* result = diagnostics::handle_document_diagnostic(&store, null, params);

		String kind = result.get_string("kind")!!;
		assert(kind == "full", "expected kind 'full' for unknown URI");

		Object* items = result.get("items")!!;
		assert(items.is_indexable(), "expected items to be indexable");
		if (items.is_array()) {
			assert(items.get_len() == 0, "expected empty items for unknown URI");
		}
	};
}

fn void document_diagnostic_includes_errors() @test {
	@pool() {
		// '&' is an invalid token -- should produce a diagnostic
		DocumentStore store = create_test_store("file:///err.kt", "&");
		defer store.free();

		Object* params = build_doc_diagnostic_params("file:///err.kt");
		Object* result = diagnostics::handle_document_diagnostic(&store, null, params);

		String kind = result.get_string("kind")!!;
		assert(kind == "full");

		Object* items = result.get("items")!!;
		assert(items.is_array());
		assert(items.get_len() >= 1, "expected at least one diagnostic for invalid token");
	};
}

fn void workspace_diagnostic_returns_all_documents() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		store.open("file:///a.kt", "kotlin", 1, "fun a() {}");
		store.open("file:///b.kt", "kotlin", 2, "fun b() {}");

		// Build params with empty previousResultIds
		Object* params = object::new_obj(tmem);
		Object* prev_ids = object::new_obj(tmem);
		params.set("previousResultIds", prev_ids);

		Object* result = diagnostics::handle_workspace_diagnostic(&store, null, params);

		Object* items = result.get("items")!!;
		assert(items.is_array(), "expected items array");
		assert(items.get_len() == 2, "expected 2 workspace diagnostic reports");

		// Each item should have kind, uri, and version
		for (usz i = 0; i < items.get_len(); i++) {
			Object* report = items.get_at(i);
			String rk = report.get_string("kind")!!;
			assert(rk == "full", "expected kind 'full' for first pull");
			String uri = report.get_string("uri")!!;
			assert(uri.len > 0, "expected non-empty uri");
			// version should be present
			int ver = report.get_int("version")!!;
			assert(ver > 0, "expected positive version");
		}
	};
}

fn void workspace_diagnostic_uses_previous_result_ids() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		store.open("file:///unchanged.kt", "kotlin", 3, "fun unchanged() {}");
		store.open("file:///changed.kt", "kotlin", 5, "fun changed() {}");

		// Build params: unchanged.kt has current result ID, changed.kt has stale one
		Object* params = object::new_obj(tmem);
		Object* prev_ids = object::new_obj(tmem);

		Object* prev_unchanged = object::new_obj(tmem);
		prev_unchanged.set("uri", "file:///unchanged.kt");
		prev_unchanged.set("value", "v3"); // matches current version
		prev_ids.push(prev_unchanged);

		Object* prev_changed = object::new_obj(tmem);
		prev_changed.set("uri", "file:///changed.kt");
		prev_changed.set("value", "v2"); // stale -- version is now 5
		prev_ids.push(prev_changed);

		params.set("previousResultIds", prev_ids);

		Object* result = diagnostics::handle_workspace_diagnostic(&store, null, params);

		Object* items = result.get("items")!!;
		assert(items.is_array());
		assert(items.get_len() == 2);

		// Check each report -- one should be unchanged, one full
		bool found_unchanged = false;
		bool found_full = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* report = items.get_at(i);
			String uri = report.get_string("uri")!!;
			String rk = report.get_string("kind")!!;
			if (uri == "file:///unchanged.kt") {
				assert(rk == "unchanged", "unchanged.kt should have kind 'unchanged'");
				found_unchanged = true;
			} else if (uri == "file:///changed.kt") {
				assert(rk == "full", "changed.kt should have kind 'full'");
				found_full = true;
				// Full report should have items
				Object* report_items = report.get("items")!!;
				assert(report_items.is_indexable());
			}
		}
		assert(found_unchanged, "should have report for unchanged.kt");
		assert(found_full, "should have report for changed.kt");
	};
}
