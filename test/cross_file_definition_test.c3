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
