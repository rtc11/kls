module kls::lsp::execute_command;

import std::collections::object;
import std::os::process;
import std::io;
import std::io::file;
import std::io::path;
import std::thread;
import kls::log;
import kls::json_rpc;
import kls::workspace;
import kls::deps::classpath;
import kls::lsp::progress;

// ── Command IDs (must match code_lens.c3) ──────────────────────────

const String CMD_RUN_MAIN = "kotlin.runMain";
const String CMD_RUN_TEST = "kotlin.runTest";

/**
 * Handle workspace/executeCommand request.
 * Commands:
 *   kotlin.runMain  [uri, "", "main"]       — run main() via Gradle or kotlinc
 *   kotlin.runTest  [uri, className, funcName] — run test via Gradle
 *
 * Returns null on success. Sends window/logMessage with output.
 */
fn Object* handle_execute_command(WorkspaceIndex* workspace, Object* params) {
	String command = params.get_string("command") ?? "";
	Object* args = params.get("arguments") ?? null;

	if (command.len == 0) {
		log::err("[kls] executeCommand: missing command");
		return null;
	}

	log::info("[kls] executeCommand: %s", command);

	switch (command) {
		case CMD_RUN_MAIN:
			execute_run_main(workspace, args);
		case CMD_RUN_TEST:
			execute_run_test(workspace, args);
		default:
			log::err("[kls] executeCommand: unknown command '%s'", command);
			show_message(3, "Unknown command: ");
	}

	return null;
}

/**
 * Build the executeCommand options for server capabilities.
 * Lists all commands the server supports.
 */
fn Object* build_execute_command_options() {
	Object* opts = object::new_obj(tmem);
	Object* commands = object::new_obj(tmem);
	commands.push(object::new_string(CMD_RUN_MAIN, tmem));
	commands.push(object::new_string(CMD_RUN_TEST, tmem));
	opts.set("commands", commands);
	return opts;
}

// ── Run main ───────────────────────────────────────────────────────

fn void execute_run_main(WorkspaceIndex* workspace, Object* args) {
	String uri = "";
	if (args != null && args.get_len() >= 1) {
		uri = args.get_at(0).s;
	}

	String root = workspace.root_path;
	if (root.len == 0) {
		show_message(1, "No workspace root configured");
		return;
	}

	switch (workspace.classpath.build_system) {
		case GRADLE:
			// Determine module for this URI
			String mod_name = find_module_for_uri(workspace, uri);
			String task;
			if (mod_name.len > 0 && mod_name != ":") {
				DString buf;
				buf.tinit();
				buf.appendf("%s:run", mod_name);
				task = buf.str_view();
			} else {
				task = "run";
			}
			run_gradle(root, task);

		case MAVEN:
			run_command(root, {"mvn", "compile", "exec:java"});

		case NONE:
			// Standalone: try kotlinc + kotlin
			run_standalone_main(root, uri);
	}
}

// ── Run test ───────────────────────────────────────────────────────

fn void execute_run_test(WorkspaceIndex* workspace, Object* args) {
	String uri = "";
	String class_name = "";
	String func_name = "";
	if (args != null) {
		if (args.get_len() >= 1) uri = args.get_at(0).s;
		if (args.get_len() >= 2) class_name = args.get_at(1).s;
		if (args.get_len() >= 3) func_name = args.get_at(2).s;
	}

	String root = workspace.root_path;
	if (root.len == 0) {
		show_message(1, "No workspace root configured");
		return;
	}

	// Build test filter
	DString filter;
	filter.tinit();

	// Find package for fully-qualified test name
	String pkg = find_package_for_uri(workspace, uri);

	if (class_name.len > 0 && func_name.len > 0) {
		// Specific test method
		if (pkg.len > 0) {
			filter.appendf("%s.%s.%s", pkg, class_name, func_name);
		} else {
			filter.appendf("%s.%s", class_name, func_name);
		}
	} else if (class_name.len > 0) {
		// All tests in class
		if (pkg.len > 0) {
			filter.appendf("%s.%s", pkg, class_name);
		} else {
			filter.appendf("%s", class_name);
		}
	} else {
		// Top-level test function (no class)
		if (func_name.len > 0) {
			if (pkg.len > 0) {
				filter.appendf("%s.%s", pkg, func_name);
			} else {
				filter.appendf("%s", func_name);
			}
		}
	}

	switch (workspace.classpath.build_system) {
		case GRADLE:
			String mod_name = find_module_for_uri(workspace, uri);
			DString task;
			task.tinit();
			if (mod_name.len > 0 && mod_name != ":") {
				task.appendf("%s:test", mod_name);
			} else {
				task.appendf("test");
			}

			if (filter.str_view().len > 0) {
				run_gradle_with_filter(root, task.str_view(), filter.str_view());
			} else {
				run_gradle(root, task.str_view());
			}

		case MAVEN:
			if (filter.str_view().len > 0) {
				DString arg;
				arg.tinit();
				arg.appendf("-Dtest=%s", filter.str_view());
				run_command(root, {"mvn", "test", arg.str_view()});
			} else {
				run_command(root, {"mvn", "test"});
			}

		case NONE:
			show_message(1, "No build system found — cannot run tests without Gradle or Maven");
	}
}

// ── Helpers ────────────────────────────────────────────────────────

fn void run_gradle(String root, String task) {
	// Detect wrapper
	String gradle_cmd = detect_gradle_wrapper(root);

	DString msg;
	msg.tinit();
	msg.appendf("Running: %s %s", gradle_cmd, task);
	show_message(3, msg.str_view());

	run_command(root, {gradle_cmd, task, "--console=plain", "-q"});
}

fn void run_gradle_with_filter(String root, String task, String filter) {
	String gradle_cmd = detect_gradle_wrapper(root);

	DString test_arg;
	test_arg.tinit();
	test_arg.appendf("--tests=%s", filter);

	DString msg;
	msg.tinit();
	msg.appendf("Running: %s %s %s", gradle_cmd, task, test_arg.str_view());
	show_message(3, msg.str_view());

	run_command(root, {gradle_cmd, task, test_arg.str_view(), "--console=plain"});
}

fn String detect_gradle_wrapper(String root) {
	// Check for gradlew in workspace root
	DString wrapper_path;
	wrapper_path.tinit();
	wrapper_path.appendf("%s/gradlew", root);

	if (file::is_file(wrapper_path.str_view())) {
		return "./gradlew";
	}
	return "gradle";
}

fn void run_standalone_main(String root, String uri) {
	// Convert URI to relative path for kotlinc
	String file_path = workspace::uri_to_path(uri);
	if (file_path.len == 0) {
		show_message(1, "Cannot determine file path");
		return;
	}

	show_message(3, "Compiling and running with kotlinc...");

	// kotlinc file.kt -include-runtime -d /tmp/kls_run.jar && kotlin -jar /tmp/kls_run.jar
	DString jar_path;
	jar_path.tinit();
	// Use hash of file path for unique JAR name (avoid collisions from same-length paths)
	uint path_hash = 5381;
	foreach (c : file_path) {
		path_hash = path_hash * 33 + (uint)c;
	}
	jar_path.appendf("/tmp/kls_run_%x.jar", path_hash);

	run_command(root, {"kotlinc", file_path, "-include-runtime", "-d", jar_path.str_view()});

	// If compile succeeded, run it
	run_command(root, {"kotlin", "-jar", jar_path.str_view()});
}

fn void run_command(String workdir, String[] argv) {
	if (argv.len == 0) return;

	progress::create("kls-exec");
	progress::begin("kls-exec", "Running...", 0);

	// chdir to workspace root (C3 process spawn has no workdir option)
	Path old_cwd;
	if (try cwd = path::tcwd()) {
		old_cwd = cwd;
	} else {
		show_message(1, "Failed to get current directory");
		progress::end("kls-exec", "Failed");
		return;
	}

	if (catch excuse = path::chdir(workdir)) {
		DString msg;
		msg.tinit();
		msg.appendf("Failed to chdir to %s: %s", workdir, excuse);
		show_message(1, msg.str_view());
		progress::end("kls-exec", "Failed");
		return;
	}

	Process proc;
	if (try p = process::spawn(argv, SpawnOptions.ASYNC_OUTPUT | SpawnOptions.INHERIT_ENV)) {
		proc = p;
	} else {
		path::chdir(old_cwd)!!;
		show_message(1, "Failed to start process");
		progress::end("kls-exec", "Failed");
		return;
	}

	// Restore working directory immediately after spawn
	path::chdir(old_cwd)!!;

	// Drain stdout and stderr while process runs
	DString output;
	output.tinit();
	DString err_output;
	err_output.tinit();
	char[4096] out_buf;
	char[4096] err_buf;

	while (true) {
		bool running = proc.is_running() ?? false;

		bool got_data = true;
		while (got_data) {
			got_data = false;

			sz n_out = proc.read_stdout(&out_buf, out_buf.len) ?? 0;
			if (n_out > 0) {
				got_data = true;
				output.appendf("%s", (String)out_buf[:(usz)n_out]);
			}

			sz n_err = proc.read_stderr(&err_buf, err_buf.len) ?? 0;
			if (n_err > 0) {
				got_data = true;
				err_output.appendf("%s", (String)err_buf[:(usz)n_err]);
			}
		}

		if (!running) break;
		thread::sleep_ms(50);
	}

	// Final drain
	bool got_final = true;
	while (got_final) {
		got_final = false;
		sz n_out = proc.read_stdout(&out_buf, out_buf.len) ?? 0;
		if (n_out > 0) {
			got_final = true;
			output.appendf("%s", (String)out_buf[:(usz)n_out]);
		}
		sz n_err = proc.read_stderr(&err_buf, err_buf.len) ?? 0;
		if (n_err > 0) {
			got_final = true;
			err_output.appendf("%s", (String)err_buf[:(usz)n_err]);
		}
	}

	(void)proc.destroy();

	// Report results — check stderr for errors
	bool has_errors = err_output.str_view().len > 0;
	if (!has_errors) {
		if (output.str_view().len > 0) {
			show_message(3, output.str_view());
		} else {
			show_message(3, "Command completed successfully");
		}
		progress::end("kls-exec", "Done");
		log::info("[kls] Command succeeded (exit 0)");
	} else {
		DString msg;
		msg.tinit();
		msg.appendf("Command produced errors");
		msg.appendf("\n%s", err_output.str_view());
		if (output.str_view().len > 0) {
			msg.appendf("\n%s", output.str_view());
		}
		show_message(1, msg.str_view());
		progress::end("kls-exec", "Failed");
		log::err("[kls] Command failed");
	}
}

/**
 * Send window/showMessage notification.
 * type: 1=Error, 2=Warning, 3=Info, 4=Log
 */
fn void show_message(int type, String message) {
	Object* params = object::new_obj(tmem);
	params.set("type", type);
	params.set("message", message);
	json_rpc::send_notification("window/showMessage", params);
}

/**
 * Find the Gradle module name for a given file URI.
 */
fn String find_module_for_uri(WorkspaceIndex* workspace, String uri) {
	if (try file_entry = workspace.files.get(uri)) {
		return file_entry.module_name;
	}
	return "";
}

/**
 * Find the package name for a given file URI.
 */
fn String find_package_for_uri(WorkspaceIndex* workspace, String uri) {
	if (try file_entry = workspace.files.get(uri)) {
		return file_entry.package_name;
	}
	return "";
}
