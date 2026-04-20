module kls::test::code_lens_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_lens;
import kls::kotlin::ast;
import kls::kotlin::parser;

// ── Helpers ──────────────────────────────────────────────────────

fn Object* make_params(String uri) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	return params;
}

fn DocumentStore make_store_with(String uri, String content) {
	DocumentStore store;
	store.init();
	store.open(uri, "kotlin", 1, content);
	return store;
}

// ── Tests ────────────────────────────────────────────────────────

fn void code_lens_empty_file() @test {
	@pool() {
		DocumentStore store = make_store_with("file:///test.kt", "");
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		assert(result.get_len() == 0, "expected 0 lenses, got %d", (int)result.get_len());
	};
}

fn void code_lens_top_level_main() @test {
	@pool() {
		String src = `fun main() {
	println("Hello")
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		assert(result.get_len() == 1, "expected 1 lens, got %d", (int)result.get_len());

		// Verify it's a Run lens
		Object* lens = result.get_at(0);
		Object* command = lens.get("command")!!;
		String title = command.get_string("title")!!;
		String cmd = command.get_string("command")!!;
		assert(title == "▶ Run", "expected title '▶ Run', got '%s'", title);
		assert(cmd == "kotlin.runMain", "expected command 'kotlin.runMain', got '%s'", cmd);
	};
}

fn void code_lens_main_not_in_class() @test {
	// fun main() inside a class should NOT get a Run lens
	@pool() {
		String src = `class App {
	fun main() {}
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		// Only the class itself is a top-level node; main() inside should not get a Run lens
		// The class has no @Test methods, so no lenses at all
		assert(result.get_len() == 0, "expected 0 lenses, got %d", (int)result.get_len());
	};
}

fn void code_lens_test_function() @test {
	@pool() {
		String src = `@Test fun myTest() {
	assert(true)
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		assert(result.get_len() == 1, "expected 1 lens, got %d", (int)result.get_len());

		Object* lens = result.get_at(0);
		Object* command = lens.get("command")!!;
		String title = command.get_string("title")!!;
		String cmd = command.get_string("command")!!;
		assert(title == "▶ Run Test", "expected '▶ Run Test', got '%s'", title);
		assert(cmd == "kotlin.runTest", "expected 'kotlin.runTest', got '%s'", cmd);
	};
}

fn void code_lens_class_with_test_methods() @test {
	@pool() {
		String src = `class MyTests {
	@Test fun testAdd() {}
	@Test fun testSub() {}
	fun helper() {}
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		// 1 class lens ("Run Tests") + 2 method lenses ("Run Test" each) = 3
		assert(result.get_len() == 3, "expected 3 lenses, got %d", (int)result.get_len());

		// First lens should be the class-level "Run Tests"
		Object* cls_lens = result.get_at(0);
		Object* cls_cmd = cls_lens.get("command")!!;
		String cls_title = cls_cmd.get_string("title")!!;
		assert(cls_title == "▶ Run Tests", "expected '▶ Run Tests', got '%s'", cls_title);

		// Second and third should be method-level "Run Test"
		Object* m1_lens = result.get_at(1);
		Object* m1_cmd = m1_lens.get("command")!!;
		String m1_title = m1_cmd.get_string("title")!!;
		assert(m1_title == "▶ Run Test", "expected '▶ Run Test', got '%s'", m1_title);

		Object* m2_lens = result.get_at(2);
		Object* m2_cmd = m2_lens.get("command")!!;
		String m2_title = m2_cmd.get_string("title")!!;
		assert(m2_title == "▶ Run Test", "expected '▶ Run Test', got '%s'", m2_title);
	};
}

fn void code_lens_class_without_tests() @test {
	@pool() {
		String src = `class Utils {
	fun helper() {}
	fun format() {}
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		assert(result.get_len() == 0, "expected 0 lenses, got %d", (int)result.get_len());
	};
}

fn void code_lens_test_arguments_include_class_name() @test {
	@pool() {
		String src = `class MyTests {
	@Test fun testAdd() {}
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		assert(result.get_len() >= 2, "expected at least 2 lenses");

		// The method-level lens (index 1) should have class name in arguments
		Object* method_lens = result.get_at(1);
		Object* command = method_lens.get("command")!!;
		Object* args = command.get("arguments")!!;
		// args[0] = uri, args[1] = class name, args[2] = function name
		String arg_class = args.get_at(1).s;
		String arg_func = args.get_at(2).s;
		assert(arg_class == "MyTests", "expected class 'MyTests', got '%s'", arg_class);
		assert(arg_func == "testAdd", "expected func 'testAdd', got '%s'", arg_func);
	};
}

fn void code_lens_main_and_test_combined() @test {
	@pool() {
		String src = `fun main() {}

@Test fun testSomething() {}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		// 1 Run lens for main + 1 Run Test lens
		assert(result.get_len() == 2, "expected 2 lenses, got %d", (int)result.get_len());
	};
}

fn void code_lens_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		Object* params = make_params("file:///unknown.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result == null, "expected null for unknown document");
	};
}

fn void code_lens_dotted_test_annotation() @test {
	@pool() {
		String src = "@org.junit.Test fun integrationTest() {}";
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		assert(result.get_len() == 1, "expected 1 lens, got %d", (int)result.get_len());

		Object* lens = result.get_at(0);
		Object* command = lens.get("command")!!;
		String title = command.get_string("title")!!;
		assert(title == "▶ Run Test", "expected '▶ Run Test', got '%s'", title);
	};
}

fn void code_lens_test_annotation_separate_line() @test {
	@pool() {
		String src = `import org.junit.jupiter.api.Test

internal class TsTest : ConsumerTestBase() {
    @Test
    fun myTest() {
        val _x = 1
    }

    @Test
    fun anotherTest() {}
}`;
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		// 1 class lens + 2 method lenses = 3
		assert(result.get_len() == 3, "expected 3 lenses, got %d", (int)result.get_len());

		Object* cls_lens = result.get_at(0);
		Object* cls_cmd = cls_lens.get("command")!!;
		String cls_title = cls_cmd.get_string("title")!!;
		assert(cls_title == "▶ Run Tests", "expected '▶ Run Tests', got '%s'", cls_title);
	};
}

fn void code_lens_backtick_function_name() @test {
	@pool() {
		String src = "class MyTests {\n    @Test\n    fun `test with spaces`() {\n        val _x = 1\n    }\n}";
		DocumentStore store = make_store_with("file:///test.kt", src);
		defer store.free();
		Object* params = make_params("file:///test.kt");
		Object* result = code_lens::handle_code_lens(&store, params)!!;
		assert(result != null, "expected non-null result");
		// 1 class lens + 1 method lens = 2
		assert(result.get_len() == 2, "expected 2 lenses, got %d", (int)result.get_len());

		// Method lens should have backtick function name
		Object* method_lens = result.get_at(1);
		Object* command = method_lens.get("command")!!;
		Object* args = command.get("arguments")!!;
		String func_name = args.get_at(2).s;
		assert(func_name == "test with spaces", "expected backtick name, got '%s'", func_name);
	};
}
