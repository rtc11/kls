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

// ── Cross-file: property references across files ───────────────────

fn void cross_file_property_references() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines a val property
		String file_a = "val sharedConfig = 42\nfun setup() { println(sharedConfig) }";
		ws.index_file("file:///config.kt", file_a);
		store.open("file:///config.kt", "kotlin", 1, file_a);

		// File B references sharedConfig
		String file_b = "fun main() { println(sharedConfig) }";
		store.open("file:///main.kt", "kotlin", 1, file_b);

		// Cursor on "sharedConfig" in file B at col 21
		Object* params = make_params("file:///main.kt", 0, 21);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references array");
		// main.kt: 1 ref, config.kt: 2 refs (decl + usage) = 3
		usz total = result.get_len();
		assert(total == 3, "expected 3 references, got %d", (int)total);

		bool found_config = false;
		bool found_main = false;
		for (usz i = 0; i < result.get_len(); i++) {
			if (get_uri(result, i) == "file:///config.kt") found_config = true;
			if (get_uri(result, i) == "file:///main.kt") found_main = true;
		}
		assert(found_config, "expected references in config.kt");
		assert(found_main, "expected references in main.kt");
	};
}

// ── Cross-file: exclude declaration ────────────────────────────────

fn void cross_file_exclude_declaration() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A defines "worker" and calls it
		String file_a = "fun worker() {}\nfun init() { worker() }";
		ws.index_file("file:///a.kt", file_a);
		store.open("file:///a.kt", "kotlin", 1, file_a);

		// File B calls "worker"
		String file_b = "fun main() { worker() }";
		store.open("file:///b.kt", "kotlin", 1, file_b);

		// With include_declaration=true
		Object* params_incl = make_params("file:///b.kt", 0, 14, true);
		Object* result_incl = references::handle_references(&store, &ws, params_incl)!!;
		usz total_incl = result_incl.get_len();

		// With include_declaration=false
		Object* params_excl = make_params("file:///b.kt", 0, 14, false);
		Object* result_excl = references::handle_references(&store, &ws, params_excl)!!;
		usz total_excl = result_excl.get_len();

		// Excluding declaration should yield fewer or equal results
		assert(total_excl <= total_incl, "exclude_declaration should not add refs: excl=%d incl=%d", (int)total_excl, (int)total_incl);
	};
}

// ── Callable references: Type::member finds same-name usages ──────

fn void callable_ref_includes_member_usages() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// File A: class with companion fromString, plus a direct call
		String file_a =
			"class Header {\n"
			"    companion object {\n"
			"        fun fromString(s: String): Header = Header()\n"
			"    }\n"
			"}\n"
			"fun direct() { Header.fromString(\"x\") }\n";
		ws.index_file("file:///header.kt", file_a);
		store.open("file:///header.kt", "kotlin", 1, file_a);

		// File B: callable ref Header::fromString
		String file_b =
			"fun useIt() { listOf(\"a\").map(Header::fromString) }\n";
		store.open("file:///use.kt", "kotlin", 1, file_b);

		// Cursor on "fromString" inside Header::fromString. Col of 'f':
		// "fun useIt() { listOf(\"a\").map(Header::fromString) }"
		//  0         1         2         3         4
		//  0123456789012345678901234567890123456789012345678901
		//                                  ^ Header at 30, ::at 36, f at 38
		Object* params = make_params("file:///use.kt", 0, 38);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references array");
		usz total = result.get_len();
		// Should at least include: callable ref in use.kt, decl in header.kt,
		// direct call in header.kt -> >= 3
		assert(total >= 3, "expected >= 3 references for callable-ref member, got %d", (int)total);
	};
}

// Cursor on the *declaration* itself must include the callable-ref usage.
// This is the reverse of `callable_ref_includes_member_usages`: forward
// path (use → decl) was the original bug; this verifies the symmetric
// reverse path (decl → use) now also resolves through the same identity.
fn void callable_ref_references_from_decl_site() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String file_a =
			"class Header {\n"
			"    companion object {\n"
			"        fun fromString(s: String): Header = Header()\n"
			"    }\n"
			"}\n";
		ws.index_file("file:///header.kt", file_a);
		store.open("file:///header.kt", "kotlin", 1, file_a);

		String file_b =
			"fun useIt() { listOf(\"a\").map(Header::fromString) }\n";
		ws.index_file("file:///use.kt", file_b);
		store.open("file:///use.kt", "kotlin", 1, file_b);

		// Cursor on `fromString` at decl site (line 2, col 12 — after "        fun ").
		Object* params = make_params("file:///header.kt", 2, 12);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references array");

		// Walk results: at least one location must be in use.kt.
		bool found_use = false;
		usz n = result.get_len();
		for (usz i = 0; i < n; i++) {
			if (get_uri(result, i) == "file:///use.kt") {
				found_use = true;
				break;
			}
		}
		assert(found_use, "expected refs from decl-site to include callable-ref usage in use.kt");
	};
}

// Strict identity: two unrelated decls sharing a name must not cross-pollute.
// `A.foo` and `B.foo` are distinct decls. Refs from `A::foo` must not include
// `B::foo`. Verifies AST_NODE identity uses (uri, decl_idx) — name alone is not enough.
fn void strict_identity_excludes_unrelated_same_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Two unrelated classes, both with a `foo` member.
		String file_src =
			"class A {\n"
			"    companion object {\n"
			"        fun foo(): Int = 1\n"
			"    }\n"
			"}\n"
			"class B {\n"
			"    companion object {\n"
			"        fun foo(): Int = 2\n"
			"    }\n"
			"}\n"
			"fun useA() { A::foo }\n"
			"fun useB() { B::foo }\n";
		ws.index_file("file:///ab.kt", file_src);
		store.open("file:///ab.kt", "kotlin", 1, file_src);

		// Cursor on `foo` in `A::foo` — line 10 (0-indexed), col where 'f' starts.
		// "fun useA() { A::foo }"  — 'f' of foo at col 16.
		Object* params = make_params("file:///ab.kt", 10, 16);
		Object* result = references::handle_references(&store, &ws, params)!!;

		assert(result != null, "expected references array");

		// Every returned location must NOT be on a `B::foo` line or on B's decl.
		// A's decl is line 2; A's usage line 10. B's decl line 7; B's usage line 11.
		usz n = result.get_len();
		for (usz i = 0; i < n; i++) {
			int ln = get_line(result, i);
			assert(ln != 7, "B's foo decl (line 7) must not be in A::foo refs");
			assert(ln != 11, "B::foo usage (line 11) must not be in A::foo refs");
		}
		// Sanity: A's own decl + usage should be present.
		bool found_decl = false;
		bool found_usage = false;
		for (usz i = 0; i < n; i++) {
			int ln = get_line(result, i);
			if (ln == 2) found_decl = true;
			if (ln == 10) found_usage = true;
		}
		assert(found_decl, "expected A's foo decl (line 2) in refs");
		assert(found_usage, "expected A::foo usage (line 10) in refs");
	};
}
