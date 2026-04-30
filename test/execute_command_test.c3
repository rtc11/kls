module kls::test::execute_command_test;

import std::collections::object;
import kls::workspace;
import kls::lsp::execute_command;
import kls::deps::classpath;

// ── Tests ────────────────────────────────────────────────────────
// Note: handle_execute_command sends JSON-RPC notifications over stdout,
// so we only test pure helper functions here. Integration testing of the
// full executeCommand flow is done via the LSP client.

fn void build_execute_command_options_has_commands() @test {
	@pool() {
		Object* opts = execute_command::build_execute_command_options();
		assert(opts != null, "expected non-null options");
		Object* commands = opts.get("commands")!!;
		// 3 user-facing run/index commands + 8 debug-introspection commands.
		assert(commands.get_len() == 12, "expected 12 commands, got %d", (int)commands.get_len());
		assert(commands.get_at(0).s == "kotlin.runMain", "first command should be kotlin.runMain");
		assert(commands.get_at(1).s == "kotlin.runTest", "second command should be kotlin.runTest");
		assert(commands.get_at(2).s == "kotlin.queryIndex", "third command should be kotlin.queryIndex");
	};
}

fn void find_package_for_indexed_file() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Manually add a file entry to test the lookup
		WorkspaceFile wf = {
			.uri = "file:///tmp/test/src/Main.kt".copy(mem),
			.package_name = "com.example".copy(mem),
			.module_name = "",
			.symbol_start = 0,
			.symbol_count = 0,
		};
		ws.files.set(wf.uri, wf);

		String pkg = execute_command::find_package_for_uri(&ws, "file:///tmp/test/src/Main.kt");
		assert(pkg == "com.example", "expected 'com.example', got '%s'", pkg);
	};
}

fn void find_package_unknown_uri() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String pkg = execute_command::find_package_for_uri(&ws, "file:///unknown.kt");
		assert(pkg == "", "expected empty string for unknown URI");
	};
}

fn void find_module_for_unknown_uri() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String mod_name = execute_command::find_module_for_uri(&ws, "file:///unknown.kt");
		assert(mod_name == "", "expected empty string for unknown URI");
	};
}

fn void detect_gradle_wrapper_returns_gradle_when_no_wrapper() @test {
	@pool() {
		// /tmp unlikely to have gradlew
		String cmd = execute_command::detect_gradle_wrapper("/tmp");
		assert(cmd == "gradle", "expected 'gradle', got '%s'", cmd);
	};
}

fn void query_index_summary_mode() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String content = "package com.example\nclass Foo : Bar {\n    fun hello() {}\n}\nfun topLevel() {}";
		ws.index_file("file:///tmp/test/Foo.kt", content);

		// No args = summary mode
		Object* result = execute_command::execute_query_index(&ws, null);
		assert(result != null, "expected non-null result");
		assert(result.get_int("file_count")!! == 1, "expected 1 file");
		assert(result.get_int("symbol_count")!! > 0, "expected symbols");

		// Should have files array
		Object* files = result.get("files")!!;
		assert(files.get_len() == 1, "expected 1 file entry");
		Object* f = files.get_at(0);
		assert(f.get_string("package")!! == "com.example", "expected com.example package");
	};
}

fn void query_index_by_name() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String content = "package com.example\nclass Foo : Bar {\n    fun hello() {}\n}\nfun topLevel() {}";
		ws.index_file("file:///tmp/test/Foo.kt", content);

		// Query for "Foo"
		Object* args = object::new_obj(tmem);
		args.push(object::new_string("Foo", tmem));

		Object* result = execute_command::execute_query_index(&ws, args);
		assert(result != null, "expected non-null result");

		Object* symbols = result.get("symbols")!!;
		assert(symbols.get_len() >= 1, "expected at least 1 symbol for 'Foo'");

		Object* sym = symbols.get_at(0);
		assert(sym.get_string("name")!! == "Foo", "expected name 'Foo'");
		assert(sym.get_string("kind")!! == "class", "expected kind 'class'");
		assert(sym.get_string("package")!! == "com.example", "expected package 'com.example'");

		// Should have members for class Foo
		if (try members = result.get("members")) {
			assert(members.get_len() >= 1, "expected at least 1 member for 'Foo'");
		}
	};
}

fn void query_index_no_match() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String content = "class Foo {}";
		ws.index_file("file:///tmp/test/Foo.kt", content);

		Object* args = object::new_obj(tmem);
		args.push(object::new_string("NonExistent", tmem));

		Object* result = execute_command::execute_query_index(&ws, args);
		assert(result != null, "expected non-null result");

		Object* symbols = result.get("symbols")!!;
		assert(symbols.get_len() == 0, "expected 0 symbols for 'NonExistent'");
	};
}

// ── Debug introspection commands ─────────────────────────────────

import kls::document;

fn void list_documents_returns_open_docs() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///tmp/test/A.kt", "kotlin", 1, "package p\nclass A {}");
		store.open("file:///tmp/test/B.kt", "kotlin", 1, "package p\nclass B {}");

		Object* result = execute_command::execute_list_documents(&store);
		assert(result != null, "expected result");
		assert(result.get_int("count")!! == 2, "expected 2 documents, got %d", (int)result.get_int("count")!!);
		Object* docs = result.get("documents")!!;
		assert(docs.get_len() == 2, "expected 2 entries");

		// last_edited_uri should be set to one of the opens
		String last = result.get_string("last_edited_uri") ?? "";
		assert(last.len > 0 && (last == "file:///tmp/test/A.kt" || last == "file:///tmp/test/B.kt"),
			"expected last_edited_uri set, got '%s'", last);
	};
}

fn void list_documents_records_last_edited() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///tmp/test/A.kt", "kotlin", 1, "class A {}");
		store.open("file:///tmp/test/B.kt", "kotlin", 1, "class B {}");
		store.update("file:///tmp/test/A.kt", 2, "class A { fun foo() {} }");

		Object* result = execute_command::execute_last_edited(&store);
		assert(result.get_string("uri")!! == "file:///tmp/test/A.kt",
			"expected last_edited = A.kt after update");
	};
}

fn void ast_at_returns_node_chain() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "class Foo { val bar: Int = 42 }" — line 0, "bar" starts at col 16
		store.open("file:///tmp/T.kt", "kotlin", 1, "class Foo { val bar: Int = 42 }");

		Object* args = object::new_obj(tmem);
		args.push(object::new_string("file:///tmp/T.kt", tmem));
		args.push(object::new_int(0, tmem));
		args.push(object::new_int(17, tmem));   // inside "bar"

		Object* result = execute_command::execute_ast_at(&store, args);
		assert(result != null, "expected result");
		assert(result.get("found")!!.b, "expected found=true");
		Object* chain = result.get("chain")!!;
		assert(chain.get_len() >= 2, "expected at least 2 nodes in chain (decl + class), got %d",
			(int)chain.get_len());
	};
}

fn void diagnostics_for_uri_returns_array() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Valid Kotlin: should produce 0 diagnostics.
		store.open("file:///tmp/T.kt", "kotlin", 1, "fun main() { println(\"hi\") }");

		Object* args = object::new_obj(tmem);
		args.push(object::new_string("file:///tmp/T.kt", tmem));

		Object* result = execute_command::execute_diagnostics_for_uri(&store, null, args);
		assert(result != null, "expected result");
		Object* ok_field = result.get("ok") ?? null;
		// On error path wrap_err returns {ok:false, error:...}; on success we
		// return {uri, diagnostics} with no `ok` field.
		assert(ok_field == null, "expected success path (no ok field), got error: %s",
			result.get_string("error") ?? "?");
		Object* diags = result.get("diagnostics")!!;
		assert(diags != null, "expected diagnostics array");
	};
}

fn void last_cursor_returns_null_when_unset() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* result = execute_command::execute_last_cursor(&store);
		assert(result != null, "expected result");
		// uri/line/character all null
		assert(result.get("uri")!!.is_null(), "expected null uri");
		assert(result.get("line")!!.is_null(), "expected null line");
		assert(result.get("character")!!.is_null(), "expected null character");
	};
}

fn void last_cursor_records_position() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///tmp/test/A.kt", "kotlin", 1, "class A {\n  fun foo() {}\n}");
		store.record_cursor("file:///tmp/test/A.kt", 1, 6);

		Object* result = execute_command::execute_last_cursor(&store);
		assert(result.get_string("uri")!! == "file:///tmp/test/A.kt",
			"expected uri = A.kt");
		assert(result.get_int("line")!! == 1, "expected line=1, got %d", (int)result.get_int("line")!!);
		assert(result.get_int("character")!! == 6, "expected character=6, got %d", (int)result.get_int("character")!!);
	};
}

fn void last_cursor_cleared_on_close() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///tmp/test/A.kt", "kotlin", 1, "class A {}");
		store.record_cursor("file:///tmp/test/A.kt", 0, 6);
		store.close("file:///tmp/test/A.kt");

		Object* result = execute_command::execute_last_cursor(&store);
		assert(result.get("uri")!!.is_null(), "expected null uri after close");
	};
}

fn void last_cursor_ignores_unknown_uri() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Recording for a not-open URI is still allowed (editor may push
		// position before didOpen processed); just stores the raw URI.
		store.record_cursor("file:///tmp/test/Ghost.kt", 3, 14);

		Object* result = execute_command::execute_last_cursor(&store);
		assert(result.get_string("uri")!! == "file:///tmp/test/Ghost.kt",
			"expected ghost uri preserved");
		assert(result.get_int("line")!! == 3, "expected line=3");
		assert(result.get_int("character")!! == 14, "expected character=14");
	};
}

fn void last_cursor_rejects_negative() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.record_cursor("file:///tmp/test/A.kt", -1, 5);
		Object* r = execute_command::execute_last_cursor(&store);
		assert(r.get("uri")!!.is_null(), "negative line rejected");
	};
}
