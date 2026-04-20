module kls::test::dap_launch_test;

import std::collections::object;
import kls::dap::launch;

// ── parse_launch_args ──────────────────────────────────────────────

fn void parse_null_args() @test {
	LaunchConfig config = launch::parse_launch_args(null);
	assert(config.main_class.len == 0);
	assert(config.workspace_path.len == 0);
	// null args returns zero-init struct, mode defaults to JAVA_MAIN (0)
	assert(config.mode == LaunchMode.JAVA_MAIN, "null args = zero-init = JAVA_MAIN");
}

fn void parse_gradle_test_args() @test {
	@pool() {
		Object* args = object::new_obj(tmem);
		args.set("workspacePath", "/home/user/project");
		args.set("gradleModule", ":apps:utsjekk");

		LaunchConfig config = launch::parse_launch_args(args);
		assert(config.workspace_path == "/home/user/project", "got: %s", config.workspace_path);
		assert(config.gradle_module == ":apps:utsjekk", "got: %s", config.gradle_module);
		assert(config.mode == LaunchMode.GRADLE_TEST);
	};
}

fn void parse_java_main_args() @test {
	@pool() {
		Object* args = object::new_obj(tmem);
		args.set("mainClass", "com.example.MainKt");
		args.set("cwd", "/project");
		args.set("args", "--verbose");
		args.set("jvmArgs", "-Xmx512m");

		LaunchConfig config = launch::parse_launch_args(args);
		assert(config.main_class == "com.example.MainKt", "got: %s", config.main_class);
		assert(config.workspace_path == "/project", "got: %s", config.workspace_path);
		assert(config.program_args == "--verbose");
		assert(config.jvm_args == "-Xmx512m");
		assert(config.mode == LaunchMode.JAVA_MAIN);
	};
}

fn void parse_workspace_path_fallback_to_cwd() @test {
	@pool() {
		Object* args = object::new_obj(tmem);
		args.set("cwd", "/fallback/path");

		LaunchConfig config = launch::parse_launch_args(args);
		assert(config.workspace_path == "/fallback/path", "got: %s", config.workspace_path);
	};
}

fn void parse_workspace_path_prefers_workspace_path() @test {
	@pool() {
		Object* args = object::new_obj(tmem);
		args.set("workspacePath", "/primary");
		args.set("cwd", "/fallback");

		LaunchConfig config = launch::parse_launch_args(args);
		assert(config.workspace_path == "/primary", "got: %s", config.workspace_path);
	};
}

// ── parse_jdwp_port ────────────────────────────────────────────────

fn void parse_port_from_jvm_output() @test {
	int port = launch::parse_jdwp_port("Listening for transport dt_socket at address: 5005");
	assert(port == 5005, "expected 5005, got %d", port);
}

fn void parse_port_from_gradle_output() @test {
	int port = launch::parse_jdwp_port(
		"> Task :test\nListening for transport dt_socket at address: 43210\nwaiting...");
	assert(port == 43210, "expected 43210, got %d", port);
}

fn void parse_port_no_match() @test {
	int port = launch::parse_jdwp_port("some random output");
	assert(port == 0, "expected 0, got %d", port);
}

fn void parse_port_empty_string() @test {
	int port = launch::parse_jdwp_port("");
	assert(port == 0, "expected 0, got %d", port);
}
