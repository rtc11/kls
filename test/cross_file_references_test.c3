module kls::test::cross_file_references_test;

import std::collections::object;
import kls::document;
import kls::lsp::references;
import kls::workspace;

// ── Helper ─────────────────────────────────────────────────────────

fn Object* make_params(String uri, int line, int character, bool include_declaration = true) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* ctx = object::new_obj(tmem);
	ctx.set("includeDeclaration", include_declaration);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	params.set("context", ctx);
	return params;
}

fn int get_line(Object* locations, usz index) {
	Object* loc = locations.get_at(index);
	return loc.get("range")!!.get("start")!!.get_int("line")!!;
}

fn String get_uri(Object* locations, usz index) {
	Object* loc = locations.get_at(index);
	return loc.get_string("uri")!!;
}

// ── Cross-file: function references across files ───────────────────

fn void cross_file_function_references() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines and uses "helper"
		String file_a = "fun helper() {}\nfun other() { helper() }";
		ws.index_file("file:///a.kt", file_a);
		store.open("file:///a.kt", "kotlin", 1, file_a);

		// File B (current) calls "helper"
		String file_b = "fun main() { helper() }";
		store.open("file:///b.kt", "kotlin", 1, file_b);

		// Cursor on "helper" in file B at col 14
		Object* params = make_params("file:///b.kt", 0, 14);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references array");
		// Same-file: 1 (the call in b.kt)
		// Cross-file from a.kt: 2 (declaration + call)
		// Total = 3
		usz total = result.get_len();
		assert(total == 3, "expected 3 references, got %d", (int)total);

		// First ref is from current file (b.kt)
		assert(get_uri(result, 0) == "file:///b.kt");

		// Remaining refs are from a.kt
		assert(get_uri(result, 1) == "file:///a.kt");
		assert(get_uri(result, 2) == "file:///a.kt");
	};
}

// ── Cross-file: class references across files ──────────────────────

fn void cross_file_class_references() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines Widget
		String file_a = "class Widget {}";
		ws.index_file("file:///models.kt", file_a);
		store.open("file:///models.kt", "kotlin", 1, file_a);

		// File B uses Widget
		String file_b = "fun create(): Widget = Widget()";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "Widget" at col 14 (return type) in main.kt
		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references array");
		// main.kt has 2 occurrences of "Widget", models.kt has 1
		usz total = result.get_len();
		assert(total == 3, "expected 3 references, got %d", (int)total);
	};
}

// ── Cross-file: null workspace (backward compat) ───────────────────

fn void null_workspace_same_file_only() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = references::handle_references(&store, null, params)!!;

		assert(result != null, "expected references");
		assert(result.get_len() == 2, "expected 2 same-file refs, got %d", (int)result.get_len());
	};
}

// ── Cross-file: no workspace match adds no extra refs ──────────────

fn void cross_file_no_match_no_extra_refs() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Workspace has unrelated symbols
		ws.index_file("file:///other.kt", "fun unrelated() {}");

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references");
		// Only same-file refs
		assert(result.get_len() == 2, "expected 2 refs, got %d", (int)result.get_len());
	};
}

// ── Cross-file: URIs are correct in cross-file locations ───────────

fn void cross_file_uris_correct() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String file_a = "fun doWork() {}";
		ws.index_file("file:///utils/worker.kt", file_a);
		store.open("file:///utils/worker.kt", "kotlin", 1, file_a);

		String file_b = "fun main() { doWork() }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references");
		// Check that cross-file location has correct URI
		bool found_worker = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_uri(result, i) == "file:///utils/worker.kt") {
				found_worker = true;
			}
		}
		assert(found_worker, "expected reference in utils/worker.kt");
	};
}

// ── Cross-file: multiple files with same symbol ────────────────────

fn void cross_file_multiple_files() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Two files define "process"
		String file_a = "fun process() {}";
		ws.index_file("file:///a.kt", file_a);
		store.open("file:///a.kt", "kotlin", 1, file_a);

		String file_b = "fun process(x: Int) {}";
		ws.index_file("file:///b.kt", file_b);
		store.open("file:///b.kt", "kotlin", 1, file_b);

		// Current file references "process"
		String file_c = "fun main() { process() }";
		store.open("file:///c.kt", "kotlin", 1, file_c);

		Object* params = make_params("file:///c.kt", 0, 14);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references");
		// c.kt: 1 ref, a.kt: 1 ref, b.kt: 1 ref = 3 total
		usz total = result.get_len();
		assert(total == 3, "expected 3 references from 3 files, got %d", (int)total);
	};
}
