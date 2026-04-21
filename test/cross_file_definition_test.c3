module kls::test::cross_file_definition_test;

import std::collections::object;
import kls::document;
import kls::lsp::definition;
import kls::workspace;

// ── Helper: build params object ────────────────────────────────────

fn Object* make_params(String uri, int line, int character) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	return params;
}

// ── Cross-file: function defined in another file ───────────────────

fn void cross_file_function_definition() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines "helper" function
		String file_a = "fun helper() { println(\"help\") }";
		ws.index_file("file:///a.kt", file_a);

		// File B calls "helper" but does NOT define it
		String file_b = "fun main() { helper() }";
		store.open("file:///b.kt", "kotlin", 1, file_b);

		// Cursor on "helper" in file B at line 0, col 14
		Object* params = make_params("file:///b.kt", 0, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected cross-file Location result");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///a.kt", "expected URI to be file:///a.kt, got '%s'", uri);

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Cross-file: class defined in another file ──────────────────────

fn void cross_file_class_definition() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines "Widget" class
		String file_a = "class Widget {}";
		ws.index_file("file:///models.kt", file_a);

		// File B uses Widget
		String file_b = "fun create(): Widget = Widget()";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "Widget" at col 14 (return type)
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected cross-file Location for class");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///models.kt", "expected models.kt, got '%s'", uri);

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int col = start.get_int("character")!!;
		assert(col == 6, "expected col 6 for 'Widget', got %d", col);
	};
}

// ── Cross-file: prefers same-file definition over workspace ────────

fn void same_file_takes_priority_over_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Workspace has "greet" in another file
		String file_a = "fun greet() { println(\"hi\") }";
		ws.index_file("file:///other.kt", file_a);

		// Current file also defines "greet"
		String file_b = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "greet" call at line 1, col 13
		Object* params = make_params("file:///main.kt", 1, 13);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected Location");
		String uri = result.get_string("uri")!!;
		// Should resolve to same file, not workspace
		assert(uri == "file:///main.kt", "expected same file, got '%s'", uri);
	};
}

// ── Cross-file: call context prefers function kind ─────────────────

fn void cross_file_prefers_function_in_call_context() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Workspace has property "config" and function "config"
		String file_a = "val config = 42";
		ws.index_file("file:///a.kt", file_a);

		String file_b = "fun config(): Int = 0";
		ws.index_file("file:///b.kt", file_b);

		// Current file calls config()
		String file_c = "fun main() { config() }";
		store.open("file:///c.kt", "kotlin", 1, file_c);

		// Cursor on "config" call
		Object* params = make_params("file:///c.kt", 0, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected cross-file Location");
		String uri = result.get_string("uri")!!;
		// Should prefer the function in b.kt over the property in a.kt
		assert(uri == "file:///b.kt", "expected function in b.kt, got '%s'", uri);
	};
}

// ── Cross-file: no match in workspace returns null ─────────────────

fn void cross_file_no_match_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Workspace has unrelated symbols
		ws.index_file("file:///a.kt", "fun other() {}");

		// Current file references unknown identifier
		String file = "fun main() { unknownSymbol() }";
		store.open("file:///main.kt", "kotlin", 1, file);

		// Cursor on "unknownSymbol"
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result == null, "expected null when not found in workspace");
	};
}

// ── Cross-file: null workspace (backward compatibility) ────────────

fn void null_workspace_still_works_for_same_file() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// null workspace: same-file definition still works
		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = definition::handle_definition(&store, null, params)!!;

		assert(result != null, "expected same-file Location with null workspace");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///test.kt");
	};
}

// ── Cross-file: skips current document symbols ─────────────────────

fn void cross_file_skips_current_doc_symbols() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index the SAME file in workspace AND open it in document store
		String content = "fun main() { unknown() }";
		ws.index_file("file:///main.kt", content);
		store.open("file:///main.kt", "kotlin", 1, content);

		// "unknown" not declared in any file
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Should NOT find "main" from workspace index since it's the same file
		assert(result == null, "expected null, workspace should skip same-file symbols");
	};
}

// ── Cross-file: range includes full name length ────────────────────

fn void cross_file_range_covers_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String file_a = "class MyService {}";
		ws.index_file("file:///service.kt", file_a);

		String file_b = "fun use(): MyService = MyService()";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "MyService" at col 11
		Object* params = make_params("file:///main.kt", 0, 11);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected cross-file Location");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		Object* end_pos = range.get("end")!!;
		int start_col = start.get_int("character")!!;
		int end_col = end_pos.get_int("character")!!;
		// "MyService" = 9 chars, starts at col 6 (after "class ")
		assert(start_col == 6, "expected start col 6, got %d", start_col);
		assert(end_col == 15, "expected end col 15, got %d", end_col);
	};
}

// ── Cross-file: property defined in another file ───────────────────

fn void cross_file_property_definition() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines a top-level val
		String file_a = "val globalConfig = mapOf(\"key\" to \"value\")";
		ws.index_file("file:///config.kt", file_a);

		// File B references globalConfig
		String file_b = "fun main() { println(globalConfig) }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "globalConfig" at col 21
		Object* params = make_params("file:///main.kt", 0, 21);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected cross-file Location for property");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///config.kt", "expected config.kt, got '%s'", uri);

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int col = start.get_int("character")!!;
		// "val globalConfig" -> name starts at col 4
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Cross-file: symbol exists nowhere (empty workspace) ────────────

fn void cross_file_definition_not_found_empty_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Empty workspace — no files indexed
		String file = "fun main() { missingSymbol() }";
		store.open("file:///main.kt", "kotlin", 1, file);

		// Cursor on "missingSymbol"
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result == null, "expected null for symbol not found anywhere");
	};
}

// ── Cross-file: same class name different packages uses imports ─────

fn void cross_file_same_name_different_packages() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Two files define class Config in different packages
		String file_a = "package com.a\nclass Config {\n    fun load() {}\n}";
		String file_b = "package com.b\nclass Config {\n    fun save() {}\n}";
		store.open("file:///a/Config.kt", "kotlin", 1, file_a);
		store.open("file:///b/Config.kt", "kotlin", 1, file_b);
		ws.index_file("file:///a/Config.kt", file_a);
		ws.index_file("file:///b/Config.kt", file_b);

		// Main file imports com.a.Config — should resolve there
		String main_file = "package com.main\nimport com.a.Config\nfun main() { Config() }";
		store.open("file:///main.kt", "kotlin", 1, main_file);

		Object* params = make_params("file:///main.kt", 2, 14);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected a Location result");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///a/Config.kt", "should go to imported Config, got '%s'", uri);
	};
}

// ── Cross-file: receiver lambda member via workspace function ──────

fn void cross_file_receiver_lambda_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines Module class with "src" property
		String file_a = "class Module {\n    var src: String = \"\"\n}";
		ws.index_file("file:///module.kt", file_a);

		// File B defines buildModule taking Module.() -> Unit
		String file_b = "fun buildModule(block: Module.() -> Unit) { }";
		ws.index_file("file:///builder.kt", file_b);
		store.open("file:///builder.kt", "kotlin", 1, file_b);

		// File C calls buildModule { src = "test" }
		//                            ^ cursor on "src" (line 0, col 16)
		String file_c = "fun main() { buildModule { src = \"test\" } }";
		store.open("file:///main.kt", "kotlin", 1, file_c);

		Object* params = make_params("file:///main.kt", 0, 27);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected Location for receiver lambda member");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///module.kt", "expected module.kt, got '%s'", uri);
	};
}

// ── Regression: extension fn body referencing non-member class ─────
//
// Crash repro: cursor on `Processor` inside `fun Topology.f() { Processor(...) }`
// where `Processor` is NOT a member of `Topology` but IS a class declared
// elsewhere in the workspace. Previously crashed with SIGSEGV in
// find_extension_receiver_member_definition because it passed null store
// to find_member_in_workspace_class which dereferenced it on cache miss.
fn void extension_receiver_non_member_no_crash() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A: Topology class with some unrelated members
		String file_a = "class Topology { fun consume() {} }";
		ws.index_file("file:///topology.kt", file_a);

		// File B: Processor class (not a member of Topology)
		String file_b = "class Processor { val x: Int = 0 }";
		ws.index_file("file:///processor.kt", file_b);

		// File C: extension function on Topology referencing Processor.
		// Cursor on `Processor` (line 0, col offset of P).
		// Text: "fun Topology.oppdrag() { Processor() }"
		//        0         1         2         3
		//        0123456789012345678901234567890123456789
		// 'P' of Processor at col 25.
		String file_c = "fun Topology.oppdrag() { Processor() }";
		ws.index_file("file:///kafka.kt", file_c);
		store.open("file:///kafka.kt", "kotlin", 1, file_c);

		Object* params = make_params("file:///kafka.kt", 0, 25);
		// Must NOT crash. Result may be null or the Processor location.
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// If non-null, must point at Processor declaration in file B.
		if (result != null) {
			String uri = result.get_string("uri")!!;
			assert(uri == "file:///processor.kt",
				"expected processor.kt, got '%s'", uri);
		}
	};
}

// ── Regression: this.method() inside trailing-lambda (receiver lambda) ─

fn void this_method_in_receiver_lambda_resolves_to_lambda_receiver() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A: ConsumedStream class with branch (taking receiver lambda)
		// and processor (the target).
		String stream =
			"class ConsumedStream<K, V> {\n"
			"    fun branch(pred: (V) -> Boolean, block: ConsumedStream<K, V>.() -> Unit) {}\n"
			"    fun processor(p: Any): ConsumedStream<K, V> = this\n"
			"}\n";
		ws.index_file("file:///stream.kt", stream);

		// File B: this.processor inside branch trailing lambda.
		// Line 2 col offsets:
		// 0:        "fun use(s: ConsumedStream<String, Int>) {"
		// 1:        "    s.branch({ true }) {"
		// 2:        "        this.processor(\"x\")"
		// '.' before processor at col 12, 'p' of processor at col 13.
		String use =
			"fun use(s: ConsumedStream<String, Int>) {\n"
			"    s.branch({ true }) {\n"
			"        this.processor(\"x\")\n"
			"    }\n"
			"}\n";
		store.open("file:///use.kt", "kotlin", 1, use);

		Object* params = make_params("file:///use.kt", 2, 13);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected definition result for this.processor");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///stream.kt",
			"expected stream.kt, got '%s'", uri);
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 2,
			"expected processor at line 2 of stream.kt, got %d", line);
	};
}

// ── Regression: chained call obj.factory(...).method on class method ─

fn void chained_call_resolves_to_return_type_method() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Topology.consume returns ConsumedStream; ConsumedStream.processor
		// is the target.
		String stream =
			"class ConsumedStream<K, V> {\n"
			"    fun processor(p: Any): ConsumedStream<K, V> = this\n"
			"}\n"
			"class Topology {\n"
			"    fun consume(topic: String): ConsumedStream<String, Int> = ConsumedStream()\n"
			"}\n";
		ws.index_file("file:///stream.kt", stream);

		// File B: extension on Topology calls implicit-this consume(...).processor(...)
		// Line 1: "    consume(\"t\").processor(\"x\")"
		// indices: 0:'    consume("t").processor("x")'
		// '.' before processor at col 19, 'p' of processor at col 20.
		String use =
			"fun Topology.use() {\n"
			"    consume(\"t\").processor(\"x\")\n"
			"}\n";
		store.open("file:///use.kt", "kotlin", 1, use);

		Object* params = make_params("file:///use.kt", 1, 20);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected definition for chained .processor");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///stream.kt",
			"expected stream.kt, got '%s'", uri);
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 1,
			"expected processor at line 1 of stream.kt, got %d", line);
	};
}
