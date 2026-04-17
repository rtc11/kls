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
		assert(commands.get_len() == 2, "expected 2 commands, got %d", (int)commands.get_len());
		assert(commands.get_at(0).s == "kotlin.runMain", "first command should be kotlin.runMain");
		assert(commands.get_at(1).s == "kotlin.runTest", "second command should be kotlin.runTest");
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
