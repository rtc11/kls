module kls::test::cross_file_hover_test;

import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::workspace;

// ── Helper ─────────────────────────────────────────────────────────

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

fn String get_hover_value(Object* result) {
	Object* contents = result.get("contents")!!;
	return contents.get_string("value")!!;
}

// ── Cross-file hover: function from workspace ──────────────────────

fn void cross_file_hover_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines "helperFunction" with params and return type
		String file_a = "fun helperFunction(name: String): Int { return 42 }";
		ws.index_file("file:///utils.kt", file_a);
		store.open("file:///utils.kt", "kotlin", 1, file_a);

		// Current file references "helperFunction" but doesn't define it
		String file_b = "fun main() { helperFunction(\"test\") }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "helperFunction" at col 14
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result");
		String value = get_hover_value(result);
		assert(value.contains("fun helperFunction"), "expected 'fun helperFunction' in hover, got: '%s'", value);
		assert(value.contains("name: String"), "expected param info in hover, got: '%s'", value);
	};
}

// ── Cross-file hover: class from workspace ─────────────────────────

fn void cross_file_hover_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String file_a = "data class UserProfile(val name: String, val age: Int)";
		ws.index_file("file:///models.kt", file_a);
		store.open("file:///models.kt", "kotlin", 1, file_a);

		String file_b = "fun create(): UserProfile = UserProfile(\"Alice\", 30)";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "UserProfile" at col 14
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result");
		String value = get_hover_value(result);
		assert(value.contains("class UserProfile"), "expected 'class UserProfile' in hover, got: '%s'", value);
	};
}

// ── Cross-file hover: same-file takes priority ─────────────────────

fn void cross_file_hover_same_file_priority() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Workspace has "greet" in another file
		ws.index_file("file:///other.kt", "fun greet(): String { return \"hi\" }");

		// Current file also defines "greet" with different signature
		String content = "fun greet(name: String) {}\nfun main() { greet(\"test\") }";
		store.open("file:///main.kt", "kotlin", 1, content);

		// Cursor on "greet" call at line 1, col 13
		Object* params = make_params("file:///main.kt", 1, 13);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result");
		String value = get_hover_value(result);
		// Should show same-file signature (with name: String param), not workspace version
		assert(value.contains("name: String"), "expected same-file param, got: '%s'", value);
	};
}

// ── Cross-file hover: null workspace (backward compat) ─────────────

fn void hover_null_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = hover::handle_hover(&store, null, params)!!;

		assert(result != null, "expected hover result with null workspace");
		String value = get_hover_value(result);
		assert(value.contains("fun greet"), "expected 'fun greet' in hover");
	};
}

// ── Cross-file hover: basic fallback when file not on disk ─────────

fn void cross_file_hover_basic_fallback() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a file that isn't open in document store and doesn't exist on disk
		// The workspace has the symbol info but we can't parse the file
		ws.index_file("file:///nonexistent/utils.kt", "fun helper() {}");

		String file_b = "fun main() { helper() }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "helper"
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result (basic fallback)");
		String value = get_hover_value(result);
		// Should show basic workspace symbol info
		assert(value.contains("fun helper"), "expected 'fun helper' in basic fallback, got: '%s'", value);
	};
}

// ── Cross-file hover: interface from workspace ─────────────────────

fn void cross_file_hover_interface() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String file_a = "interface Repository {}";
		ws.index_file("file:///api.kt", file_a);
		store.open("file:///api.kt", "kotlin", 1, file_a);

		String file_b = "fun use(r: Repository) {}";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "Repository" at col 11
		Object* params = make_params("file:///main.kt", 0, 11);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result");
		String value = get_hover_value(result);
		assert(value.contains("interface Repository"), "expected 'interface Repository', got: '%s'", value);
	};
}

// ── Cross-file hover: no match still shows basic identifier ────────

fn void cross_file_hover_no_match_falls_to_describe_token() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Workspace has nothing matching
		ws.index_file("file:///a.kt", "fun other() {}");

		String file = "fun main() { unknownThing() }";
		store.open("file:///main.kt", "kotlin", 1, file);

		// Cursor on "unknownThing" at col 14
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected basic hover for unresolved identifier");
		String value = get_hover_value(result);
		assert(value.contains("unknownThing"), "expected identifier name in hover");
	};
}

// ── Cross-file hover: package name shown ───────────────────────────

fn void cross_file_hover_shows_package() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File with package declaration - but file isn't open in store and doesn't exist on disk
		// So we'll get basic fallback which includes package info
		ws.index_file("file:///nonexistent/models.kt", "package com.example.app\n\nclass Widget {}");

		String file = "fun use(w: Widget) {}";
		store.open("file:///main.kt", "kotlin", 1, file);

		Object* params = make_params("file:///main.kt", 0, 11);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result");
		String value = get_hover_value(result);
		assert(value.contains("Widget"), "expected 'Widget' in hover");
		assert(value.contains("com.example.app"), "expected package name in hover, got: '%s'", value);
	};
}

// ── Cross-file hover: object declaration from workspace ────────────

fn void cross_file_hover_object() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String file_a = "object AppConfig {\n    val debug = false\n}";
		ws.index_file("file:///config.kt", file_a);
		store.open("file:///config.kt", "kotlin", 1, file_a);

		String file_b = "fun main() { println(AppConfig.debug) }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "AppConfig" at col 21
		Object* params = make_params("file:///main.kt", 0, 21);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		assert(result != null, "expected hover result for object");
		String value = get_hover_value(result);
		assert(value.contains("AppConfig"), "expected 'AppConfig' in hover, got: '%s'", value);
	};
}

// ── Cross-file hover: unknown symbol with empty workspace ──────────

fn void cross_file_hover_unknown_empty_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Empty workspace — no files indexed
		String file = "fun main() { somethingUnknown() }";
		store.open("file:///main.kt", "kotlin", 1, file);

		// Cursor on "somethingUnknown" at col 14
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = hover::handle_hover(&store, &ws, params)!!;

		// Should still return something (basic identifier hover) or null
		// Either way, no crash
		if (result != null) {
			String value = get_hover_value(result);
			assert(value.contains("somethingUnknown"), "expected identifier in hover");
		}
	};
}
