module kls::dap::stacktrace;

import std::collections::object;
import std::io::path;
import std::io::file;
import kls::log;
import kls::json_rpc;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;

// Handle stackTrace request
fn Object* handle_stack_trace(JdwpConnection* conn, IdManager* id_mgr, Object* args, String workspace_path) {
	Object* body = object::new_obj(tmem);
	Object* frames_arr = json_rpc::new_json_arr();

	int dap_thread_id = (int)(args.get_int("threadId") ?? 0);
	int start_frame = (int)(args.get_int("startFrame") ?? 0);
	int levels = (int)(args.get_int("levels") ?? 20);

	long jdwp_tid = id_mgr.get_jdwp_thread_id(dap_thread_id) ?? 0;
	if (jdwp_tid == 0) {
		body.set("stackFrames", frames_arr);
		body.set("totalFrames", 0);
		return body;
	}

	// Get frames from JDWP
	JdwpReply reply;
	if (try r = protocol::get_thread_frames(conn, jdwp_tid, start_frame, levels)) {
		reply = r;
	} else {
		body.set("stackFrames", frames_arr);
		body.set("totalFrames", 0);
		return body;
	}

	if (reply.error_code != 0 || reply.data.len < 4) {
		body.set("stackFrames", frames_arr);
		body.set("totalFrames", 0);
		return body;
	}

	int frame_count = transport::get_int_be(reply.data, 0);
	usz pos = 4;

	for (int i = 0; i < frame_count; i++) {
		// Each frame: frameID(8) + location(typeTag(1) + classID(8) + methodID(8) + index(8))
		if (pos + 8 + 25 > reply.data.len) break;

		long frame_id = transport::get_long_be(reply.data, pos); pos += 8;
		char type_tag = reply.data[pos]; pos++;
		long class_id = transport::get_long_be(reply.data, pos); pos += 8;
		long method_id = transport::get_long_be(reply.data, pos); pos += 8;
		long location = transport::get_long_be(reply.data, pos); pos += 8;

		// Register frame for later variable inspection
		FrameRef ref;
		ref.thread_id = jdwp_tid;
		ref.frame_id = frame_id;
		ref.class_id = class_id;
		ref.method_id = method_id;
		ref.location = location;
		int dap_frame_id = id_mgr.register_frame(ref);

		// Get method name + class name
		String method_name = get_method_name(conn, class_id, method_id);
		String class_name = get_class_name(conn, class_id);

		// Get source line from line table
		int line = get_line_for_location(conn, class_id, method_id, location);

		// Get source file name
		String source_file = get_source_file_name(conn, class_id);

		// Build frame name
		DString frame_name;
		frame_name.tinit();
		frame_name.appendf("%s.%s", class_name, method_name);

		Object* frame = object::new_obj(tmem);
		frame.set("id", dap_frame_id);
		frame.set("name", frame_name.str_view());
		frame.set("line", line > 0 ? line : 1);
		frame.set("column", 1);

		// Presentation hint: mark JDK/library frames as "subtle"
		String hint = classify_frame_hint(class_name);
		if (hint.len > 0) {
			frame.set("presentationHint", hint);
		}

		if (source_file.len > 0) {
			Object* source = object::new_obj(tmem);
			source.set("name", source_file);
			// Resolve full path: workspace + src dir + package path + filename
			String full_path = resolve_source_path(workspace_path, class_name, source_file);
			if (full_path.len > 0) {
				source.set("path", full_path);
			}
			frame.set("source", source);
		}

		frames_arr.push(frame);
	}

	body.set("stackFrames", frames_arr);
	body.set("totalFrames", frame_count);
	return body;
}

// Get method name from JDWP
fn String get_method_name(JdwpConnection* conn, long class_id, long method_id) {
	JdwpReply reply;
	if (try r = protocol::get_methods(conn, class_id)) {
		reply = r;
	} else {
		return "<unknown>";
	}
	if (reply.error_code != 0 || reply.data.len < 4) return "<unknown>";

	int count = transport::get_int_be(reply.data, 0);
	usz pos = 4;

	for (int i = 0; i < count; i++) {
		if (pos + 8 > reply.data.len) break;
		long mid = transport::get_long_be(reply.data, pos); pos += 8;

		if (pos + 4 > reply.data.len) break;
		int name_len = transport::get_int_be(reply.data, pos); pos += 4;
		String name = "";
		if (name_len > 0 && pos + (usz)name_len <= reply.data.len) {
			name = (String)reply.data[pos:name_len];
		}
		pos += (usz)name_len;

		// Skip signature
		if (pos + 4 > reply.data.len) break;
		int sig_len = transport::get_int_be(reply.data, pos); pos += 4;
		pos += (usz)sig_len;

		// Skip modBits
		if (pos + 4 > reply.data.len) break;
		pos += 4;

		if (mid == method_id) return name;
	}

	return "<unknown>";
}

// Get class name from signature
fn String get_class_name(JdwpConnection* conn, long class_id) {
	JdwpReply reply;
	if (try r = protocol::get_reference_type_signature(conn, class_id)) {
		reply = r;
	} else {
		return "<unknown>";
	}
	if (reply.error_code != 0 || reply.data.len < 4) return "<unknown>";

	int sig_len = transport::get_int_be(reply.data, 0);
	if (sig_len <= 2 || 4 + (usz)sig_len > reply.data.len) return "<unknown>";

	// Signature like "Lcom/example/MainKt;" -> "com.example.MainKt"
	String sig = (String)reply.data[5:sig_len - 2];  // skip "L" and ";"

	// Replace / with .
	DString result;
	result.tinit();
	foreach (c : sig) {
		if (c == '/') {
			result.append_char('.');
		} else {
			result.append_char(c);
		}
	}
	return result.str_view();
}

// Get source line number for bytecode location
fn int get_line_for_location(JdwpConnection* conn, long class_id, long method_id, long location) {
	JdwpReply reply;
	if (try r = protocol::get_line_table(conn, class_id, method_id)) {
		reply = r;
	} else {
		return 0;
	}
	if (reply.error_code != 0 || reply.data.len < 20) return 0;

	int lt_count = transport::get_int_be(reply.data, 16);
	usz pos = 20;

	int best_line = 0;
	for (int i = 0; i < lt_count; i++) {
		if (pos + 12 > reply.data.len) break;
		long code_index = transport::get_long_be(reply.data, pos); pos += 8;
		int line_number = transport::get_int_be(reply.data, pos); pos += 4;

		if (code_index <= location) {
			best_line = line_number;
		} else {
			break;
		}
	}

	return best_line;
}

// Get source file name
fn String get_source_file_name(JdwpConnection* conn, long class_id) {
	JdwpReply reply;
	if (try r = protocol::get_source_file(conn, class_id)) {
		reply = r;
	} else {
		return "";
	}
	if (reply.error_code != 0 || reply.data.len < 4) return "";

	int name_len = transport::get_int_be(reply.data, 0);
	if (name_len <= 0 || 4 + (usz)name_len > reply.data.len) return "";

	return (String)reply.data[4:name_len];
}

// Resolve source file path from class name + source file name
// class_name: "com.example.MainKt" (dots as separators)
// source_file: "Main.kt"
// Try common source dirs under workspace_path
fn String resolve_source_path(String workspace_path, String class_name, String source_file) {
	if (workspace_path.len == 0) return "";

	// Extract package path from class name: "com.example.MainKt" -> "com/example"
	DString pkg_path;
	pkg_path.tinit();
	usz last_dot = 0;
	for (usz i = 0; i < class_name.len; i++) {
		if (class_name[i] == '.') last_dot = i;
	}
	// Everything before last dot is the package
	for (usz i = 0; i < last_dot; i++) {
		if (class_name[i] == '.') {
			pkg_path.append_char('/');
		} else {
			pkg_path.append_char(class_name[i]);
		}
	}

	String[] src_dirs = {
		"src/main/kotlin",
		"src/main/java",
		"src/test/kotlin",
		"src/test/java",
		"src",
		"main",
		"test",
	};

	// Try source dirs directly under workspace root
	foreach (src_dir : src_dirs) {
		DString candidate;
		candidate.tinit();
		candidate.appendf("%s/%s", workspace_path, src_dir);
		if (pkg_path.len() > 0) {
			candidate.appendf("/%s", pkg_path.str_view());
		}
		candidate.appendf("/%s", source_file);

		if (file::is_file(candidate.str_view())) {
			return candidate.str_view();
		}
	}

	// Try source dirs under submodule directories (e.g., apps/utsjekk/test/...)
	// Scan workspace for subdirectories that contain source dirs
	String[] module_prefixes = { "apps", "libs", "models" };
	foreach (prefix : module_prefixes) {
		DString prefix_path;
		prefix_path.tinit();
		prefix_path.appendf("%s/%s", workspace_path, prefix);

		// List subdirs under prefix (e.g., apps/utsjekk, apps/abetal)
		// Try each subdir + src_dir combo
		if (try dir = file::open(prefix_path.str_view(), "r")) {
			(void)dir.close();
			// Directory exists — try well-known sub-module patterns
			// We don't have readdir, so try the package-based approach:
			// The class name package might contain the module name
			// e.g., class "utsjekk.iverksetting.FooKt" → try apps/utsjekk/test/utsjekk/iverksetting/
			foreach (src_dir : src_dirs) {
				DString candidate;
				candidate.tinit();
				// Extract first package segment as potential module name
				String first_pkg = "";
				for (usz i = 0; i < pkg_path.len(); i++) {
					if (pkg_path.str_view()[i] == '/') {
						first_pkg = pkg_path.str_view()[:i];
						break;
					}
				}
				if (first_pkg.len > 0) {
					candidate.appendf("%s/%s/%s/%s", workspace_path, prefix, first_pkg, src_dir);
					if (pkg_path.len() > 0) {
						candidate.appendf("/%s", pkg_path.str_view());
					}
					candidate.appendf("/%s", source_file);
					if (file::is_file(candidate.str_view())) {
						return candidate.str_view();
					}
				}
			}
		}
	}

	return "";
}

// Classify stack frame presentation hint based on class name
fn String classify_frame_hint(String class_name) {
	String[] library_prefixes = {
		"java.", "javax.", "jdk.", "sun.", "com.sun.",
		"kotlin.", "kotlinx.",
		"org.junit.", "org.gradle.",
		"java.lang.invoke.", "java.lang.reflect.",
	};
	foreach (prefix : library_prefixes) {
		if (class_name.len >= prefix.len && class_name[:prefix.len] == prefix) {
			return "subtle";
		}
	}
	return "";
}
