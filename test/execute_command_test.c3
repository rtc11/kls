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
		assert(commands.get_len() == 3, "expected 3 commands, got %d", (int)commands.get_len());
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
