module kls::dap::launch;

import std::io;
import std::io::file;
import std::os::process;
import std::os::env;
import std::io::path;
import std::thread;
import std::collections::object;
import kls::log;
import kls::deps::classpath;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;

faultdef LAUNCH_FAILED, NO_MAIN_CLASS, JDWP_PORT_NOT_FOUND, NO_GRADLEW;

enum LaunchMode : char {
	JAVA_MAIN,
	GRADLE_TEST,
}

struct LaunchResult {
	JdwpConnection conn;
	Process proc;
}

struct LaunchConfig {
	String main_class;       // e.g., "com.example.MainKt"
	String program_args;     // space-separated program arguments
	String jvm_args;         // extra JVM arguments
	String workspace_path;   // project root
	String gradle_module;    // e.g., ":apps:utsjekk" (for GRADLE_TEST mode)
	int jdwp_port;           // 0 = auto-detect from JVM output
	LaunchMode mode;
}

// Parse launch arguments from DAP launch request
fn LaunchConfig parse_launch_args(Object* args) {
	LaunchConfig config;
	if (args == null) return config;

	config.main_class = args.get_string("mainClass") ?? "";
	config.program_args = args.get_string("args") ?? "";
	config.jvm_args = args.get_string("jvmArgs") ?? "";
	config.gradle_module = args.get_string("gradleModule") ?? "";

	// Read workspace path from either "workspacePath" or "cwd"
	config.workspace_path = args.get_string("workspacePath") ?? "";
	if (config.workspace_path.len == 0) {
		config.workspace_path = args.get_string("cwd") ?? "";
	}

	// Auto-detect mode: if no mainClass, use gradle test
	if (config.main_class.len == 0) {
		config.mode = GRADLE_TEST;
	} else {
		config.mode = JAVA_MAIN;
	}

	return config;
}

// Launch JVM via gradle test --debug-jvm, return connection + process
fn LaunchResult? launch_gradle_test(LaunchConfig* config) {
	if (config.workspace_path.len == 0) {
		return LAUNCH_FAILED~;
	}

	// Detect gradlew
	DString gradlew_path;
	gradlew_path.tinit();
	gradlew_path.appendf("%s/gradlew", config.workspace_path);

	String gradle_cmd;
	if (file::is_file(gradlew_path.str_view())) {
		gradle_cmd = "./gradlew";
	} else {
		log::err("[dap] No gradlew found at %s", gradlew_path.str_view());
		return NO_GRADLEW~;
	}

	// Build gradle task: [:module]:cleanTest [:module]:test --debug-jvm
	// cleanTest forces re-execution so JDWP agent starts
	DString clean_task;
	clean_task.tinit();
	DString test_task;
	test_task.tinit();
	if (config.gradle_module.len > 0) {
		clean_task.appendf("%s:cleanTest", config.gradle_module);
		test_task.appendf("%s:test", config.gradle_module);
	} else {
		clean_task.append("cleanTest");
		test_task.append("test");
	}

	log::info("[dap] Launching: %s %s %s --debug-jvm --no-build-cache", gradle_cmd, clean_task.str_view(), test_task.str_view());

	// Build argv
	String[8] argv;
	int argc = 0;
	argv[argc] = gradle_cmd; argc++;
	argv[argc] = clean_task.str_view(); argc++;
	argv[argc] = test_task.str_view(); argc++;
	argv[argc] = "--debug-jvm"; argc++;
	argv[argc] = "--no-build-cache"; argc++;

	// chdir to workspace
	Path old_cwd;
	if (try cwd = path::tcwd()) {
		old_cwd = cwd;
	} else {
		log::err("[dap] Failed to get current directory");
		return LAUNCH_FAILED~;
	}
	path::chdir(config.workspace_path)!!;

	Process proc;
	if (try p = process::spawn(argv[:argc], SpawnOptions.ASYNC_OUTPUT | SpawnOptions.INHERIT_ENV)) {
		proc = p;
	} else {
		(void)path::chdir(old_cwd);
		log::err("[dap] Failed to spawn gradle");
		return LAUNCH_FAILED~;
	}

	(void)path::chdir(old_cwd);

	// Read stderr to find JDWP port — gradle is slow, allow up to 60s
	int port = 0;
	int attempts = 0;
	while (port == 0 && attempts < 600) {
		char[4096] buf;
		sz n = proc.read_stderr(&buf, buf.len) ?? 0;
		if (n > 0) {
			String line = (String)buf[:(usz)n];
			log::debug("[dap] gradle stderr: %s", line);
			port = parse_jdwp_port(line);
		}
		if (port == 0) {
			// Also check stdout — some gradle versions print there
			n = proc.read_stdout(&buf, buf.len) ?? 0;
			if (n > 0) {
				String line = (String)buf[:(usz)n];
				log::debug("[dap] gradle stdout: %s", line);
				port = parse_jdwp_port(line);
			}
		}
		if (port == 0) {
			thread::sleep_ms(100);
			attempts++;
		}
	}

	if (port == 0) {
		log::err("[dap] Failed to detect JDWP port from gradle output after %d attempts", attempts);
		(void)proc.destroy();
		return JDWP_PORT_NOT_FOUND~;
	}

	log::info("[dap] JDWP agent listening on port %d", port);

	// Connect to JDWP
	if (try conn = transport::connect("127.0.0.1", port)) {
		LaunchResult result;
		result.conn = conn;
		result.proc = proc;
		return result;
	}

	// JDWP connect failed — kill orphan process
	log::err("[dap] Failed to connect to JDWP on port %d, destroying process", port);
	(void)proc.destroy();
	return LAUNCH_FAILED~;
}

// Launch JVM with JDWP agent, return connection + process
fn LaunchResult? launch_and_connect(LaunchConfig* config, Classpath* cp) {
	if (config.main_class.len == 0) {
		return NO_MAIN_CLASS~;
	}

	// Build classpath string from resolved JARs
	DString cp_str;
	cp_str.tinit();
	for (usz i = 0; i < cp.jar_count; i++) {
		if (i > 0) cp_str.append(":");
		cp_str.append(cp.jars[i].path);
	}

	// Build JVM command with JDWP agent
	// address=*:0 means pick random port, suspend=y means wait for debugger
	String[16] argv;
	int argc = 0;

	argv[argc] = "java"; argc++;
	argv[argc] = "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:0"; argc++;

	if (config.jvm_args.len > 0) {
		argv[argc] = config.jvm_args; argc++;
	}

	if (cp_str.str_view().len > 0) {
		argv[argc] = "-cp"; argc++;
		argv[argc] = cp_str.str_view(); argc++;
	}

	argv[argc] = config.main_class; argc++;

	if (config.program_args.len > 0) {
		argv[argc] = config.program_args; argc++;
	}

	log::info("[dap] Launching: java -agentlib:jdwp ... %s", config.main_class);

	Path old_cwd;
	if (config.workspace_path.len > 0) {
		if (try cwd = path::tcwd()) {
			old_cwd = cwd;
		} else {
			log::err("[dap] Failed to get current directory");
			return LAUNCH_FAILED~;
		}
		path::chdir(config.workspace_path)!!;
	}

	Process proc;
	if (try p = process::spawn(argv[:argc], SpawnOptions.ASYNC_OUTPUT | SpawnOptions.INHERIT_ENV)) {
		proc = p;
	} else {
		if (config.workspace_path.len > 0) (void)path::chdir(old_cwd);
		return LAUNCH_FAILED~;
	}

	if (config.workspace_path.len > 0) (void)path::chdir(old_cwd);

	// Read stderr to find "Listening for transport dt_socket at address: <port>"
	int port = 0;
	int attempts = 0;
	while (port == 0 && attempts < 100) {
		char[512] buf;
		sz n = proc.read_stderr(&buf, buf.len) ?? 0;
		if (n > 0) {
			String line = (String)buf[:(usz)n];
			log::debug("[dap] JVM stderr: %s", line);
			port = parse_jdwp_port(line);
		}
		if (port == 0) {
			thread::sleep_ms(50);
			attempts++;
		}
	}

	if (port == 0) {
		log::err("[dap] Failed to detect JDWP port from JVM output");
		(void)proc.destroy();
		return JDWP_PORT_NOT_FOUND~;
	}

	log::info("[dap] JDWP agent listening on port %d", port);

	if (try conn = transport::connect("127.0.0.1", port)) {
		LaunchResult result;
		result.conn = conn;
		result.proc = proc;
		return result;
	}

	log::err("[dap] Failed to connect to JDWP on port %d, destroying process", port);
	(void)proc.destroy();
	return LAUNCH_FAILED~;
}

// Parse JDWP port from JVM stderr output
// Looks for: "Listening for transport dt_socket at address: <port>"
fn int parse_jdwp_port(String output) {
	String needle = "address: ";
	for (usz i = 0; i + needle.len < output.len; i++) {
		if (output[i:needle.len] == needle) {
			usz start = i + needle.len;
			usz end = start;
			while (end < output.len && output[end] >= '0' && output[end] <= '9') {
				end++;
			}
			if (end > start) {
				String num = output[start..end - 1];
				return num.to_int() ?? 0;
			}
		}
	}
	return 0;
}
