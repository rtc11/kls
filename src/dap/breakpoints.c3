module kls::dap::breakpoints;

import std::collections::object;
import std::collections;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;

const int MAX_BREAKPOINTS = 256;

struct BreakpointManager {
	ActiveBreakpoint[MAX_BREAKPOINTS] breakpoints;
	usz count;
	int next_id;
}

struct ActiveBreakpoint {
	int dap_id;           // DAP breakpoint ID
	int jdwp_request_id;  // JDWP event request ID
	int prepare_request_id; // JDWP CLASS_PREPARE request ID (for pending bps)
	String source_path;   // file path (heap-copied)
	String class_sig_kt;  // heap-copied "Lcom/example/FooKt;" (for pending resolution)
	String class_sig_plain; // heap-copied "Lcom/example/Foo;" (for pending resolution)
	int line;
	int hit_count;        // hit count condition (0 = no count)
	bool verified;
}

fn void BreakpointManager.init(BreakpointManager* self) {
	self.count = 0;
	self.next_id = 1;
}

// Handle setBreakpoints request
// Clears existing breakpoints for the source, sets new ones
fn Object* handle_set_breakpoints(BreakpointManager* self, JdwpConnection* conn, Object* args) {
	if (args == null) return build_empty_response();

	// Get source path
	Object* source = args.get("source") ?? null;
	if (source == null) return build_empty_response();
	String source_path = source.get_string("path") ?? "";
	if (source_path.len == 0) return build_empty_response();

	// Clear existing breakpoints for this source
	clear_source_breakpoints(self, conn, source_path);

	// Get requested breakpoint lines
	Object* bp_list = args.get("breakpoints") ?? null;
	if (bp_list == null || !bp_list.is_array()) return build_empty_response();

	// Convert source path to JVM class signature — try both ClassKt and Class
	String class_sig_kt = source_path_to_class_sig(source_path, true);
	String class_sig_plain = source_path_to_class_sig(source_path, false);
	log::info("[dap] setBreakpoints: source=%s sig_kt=%s sig_plain=%s", source_path, class_sig_kt, class_sig_plain);

	// Look up class in VM — try Kt suffix first (file-level), then plain (class decl)
	long class_id = 0;
	char type_tag = 1;  // CLASS
	String[] sigs_to_try = { class_sig_kt, class_sig_plain };
	foreach (sig : sigs_to_try) {
		if (sig.len == 0) continue;
		if (try reply = protocol::get_classes_by_signature(conn, sig)) {
			if (reply.error_code == 0 && reply.data.len >= 4) {
				int class_count = transport::get_int_be(reply.data, 0);
				if (class_count > 0) {
					type_tag = reply.data[4];
					class_id = transport::get_long_be(reply.data, 5);
					break;
				}
			}
		}
	}

	log::info("[dap] Class lookup: class_id=%d", class_id);

	// Build response array
	Object* result_bps = object::new_obj(tmem);

	for (sz i = 0; i < bp_list.get_len(); i++) {
		Object* bp_req = bp_list.get_at(i);
		int line = (int)(bp_req.get_int("line") ?? 0);
		String hit_cond = bp_req.get_string("hitCondition") ?? "";
		int hit_count = 0;
		if (hit_cond.len > 0) {
			hit_count = (int)(hit_cond.to_int() ?? 0);
		}

		Object* bp_result = object::new_obj(tmem);
		int dap_id = self.next_id;
		self.next_id++;
		bp_result.set("id", dap_id);
		bp_result.set("line", line);

		if (class_id == 0) {
			// Class not loaded yet — register CLASS_PREPARE to get notified
			bp_result.set("verified", false);
			bp_result.set("message", "Class not loaded");

			// Register CLASS_PREPARE events for BOTH Kt and plain patterns
			// JDWP accepts any pattern (even non-matching), so register both
			int prepare_req_id = 0;
			int prepare_req_id_plain = 0;
			String match_pattern = sig_to_class_match(class_sig_kt);
			if (match_pattern.len > 0) {
				if (try reply = protocol::set_class_prepare_request(conn, match_pattern)) {
					if (reply.error_code == 0 && reply.data.len >= 4) {
						prepare_req_id = transport::get_int_be(reply.data, 0);
						log::info("[dap] CLASS_PREPARE request set (Kt): pattern=%s req_id=%d", match_pattern, prepare_req_id);
					}
				}
			}
			String match_pattern_plain = sig_to_class_match(class_sig_plain);
			if (match_pattern_plain.len > 0) {
				if (try reply = protocol::set_class_prepare_request(conn, match_pattern_plain)) {
					if (reply.error_code == 0 && reply.data.len >= 4) {
						prepare_req_id_plain = transport::get_int_be(reply.data, 0);
						log::info("[dap] CLASS_PREPARE request set (plain): pattern=%s req_id=%d", match_pattern_plain, prepare_req_id_plain);
					}
				}
			}
			// Use whichever is non-zero (prefer plain for class declarations)
			if (prepare_req_id == 0) prepare_req_id = prepare_req_id_plain;

			if (self.count < MAX_BREAKPOINTS) {
				ActiveBreakpoint bp;
				bp.dap_id = dap_id;
				bp.jdwp_request_id = 0;
				bp.prepare_request_id = prepare_req_id;
				bp.source_path = source_path.copy(mem);
				bp.class_sig_kt = class_sig_kt.copy(mem);
				bp.class_sig_plain = class_sig_plain.copy(mem);
				bp.line = line;
				bp.hit_count = hit_count;
				bp.verified = false;
				self.breakpoints[self.count] = bp;
				self.count++;
			}
		} else {
			// Find method containing this line, get bytecode offset
			long method_id = 0;
			long offset = 0;
			bool found = find_line_location(conn, class_id, line, &method_id, &offset);

			if (found) {
				// Set JDWP breakpoint (with or without hit count)
				int jdwp_req_id = 0;
				if (hit_count > 0) {
					if (try reply = protocol::set_breakpoint_with_count(conn, type_tag, class_id, method_id, offset, hit_count)) {
						if (reply.error_code == 0 && reply.data.len >= 4) {
							jdwp_req_id = transport::get_int_be(reply.data, 0);
						} else {
							log::err("[dap] JDWP set_breakpoint_with_count error=%d for line %d", (int)reply.error_code, line);
						}
					}
				} else {
					if (try reply = protocol::set_breakpoint(conn, type_tag, class_id, method_id, offset)) {
						if (reply.error_code == 0 && reply.data.len >= 4) {
							jdwp_req_id = transport::get_int_be(reply.data, 0);
						} else {
							log::err("[dap] JDWP set_breakpoint error=%d for line %d", (int)reply.error_code, line);
						}
					}
				}

				log::info("[dap] Breakpoint line %d: method=%d offset=%d jdwp_req=%d", line, method_id, offset, jdwp_req_id);

				bp_result.set("verified", jdwp_req_id != 0);
				if (jdwp_req_id == 0) {
					bp_result.set("message", "Failed to set breakpoint");
				}

				if (self.count < MAX_BREAKPOINTS) {
					ActiveBreakpoint bp;
					bp.dap_id = dap_id;
					bp.jdwp_request_id = jdwp_req_id;
					bp.source_path = source_path.copy(mem);
					bp.line = line;
					bp.hit_count = hit_count;
					bp.verified = jdwp_req_id != 0;
					self.breakpoints[self.count] = bp;
					self.count++;
				}
			} else {
				bp_result.set("verified", false);
				bp_result.set("message", "No code at this line");
			}
		}

		Object* src_obj = object::new_obj(tmem);
		src_obj.set("path", source_path);
		bp_result.set("source", src_obj);

		result_bps.push(bp_result);
	}

	Object* body = object::new_obj(tmem);
	body.set("breakpoints", result_bps);
	return body;
}

// Clear all breakpoints for a source path
fn void clear_source_breakpoints(BreakpointManager* self, JdwpConnection* conn, String source_path) {
	usz write_idx = 0;
	for (usz i = 0; i < self.count; i++) {
		if (self.breakpoints[i].source_path == source_path) {
			// Clear JDWP event request
			if (self.breakpoints[i].jdwp_request_id != 0) {
				if (catch excuse = protocol::clear_event_request(conn, protocol::EK_BREAKPOINT, self.breakpoints[i].jdwp_request_id)) {
					log::err("[dap] Failed to clear breakpoint: %s", excuse);
				}
			}
			// Don't copy to write_idx — this entry is removed
		} else {
			if (write_idx != i) {
				self.breakpoints[write_idx] = self.breakpoints[i];
			}
			write_idx++;
		}
	}
	self.count = write_idx;
}

// Find bytecode location for a source line
fn bool find_line_location(JdwpConnection* conn, long class_id, int line, long* out_method_id, long* out_offset) {
	// Get methods for class
	JdwpReply methods_reply;
	if (try r = protocol::get_methods(conn, class_id)) {
		methods_reply = r;
	} else {
		return false;
	}
	if (methods_reply.error_code != 0) return false;
	if (methods_reply.data.len < 4) return false;

	int method_count = transport::get_int_be(methods_reply.data, 0);
	usz pos = 4;

	// Iterate methods, check line table for each
	for (int m = 0; m < method_count; m++) {
		if (pos + 8 + 4 + 4 >= methods_reply.data.len) break;
		long method_id = transport::get_long_be(methods_reply.data, pos); pos += 8;

		// Skip name (length-prefixed string)
		int name_len = transport::get_int_be(methods_reply.data, pos); pos += 4;
		pos += (usz)name_len;

		// Skip signature
		if (pos + 4 > methods_reply.data.len) break;
		int sig_len = transport::get_int_be(methods_reply.data, pos); pos += 4;
		pos += (usz)sig_len;

		// Skip modBits
		if (pos + 4 > methods_reply.data.len) break;
		pos += 4;

		// Get line table for this method
		JdwpReply lt_reply;
		if (try r = protocol::get_line_table(conn, class_id, method_id)) {
			lt_reply = r;
		} else {
			continue;
		}
		if (lt_reply.error_code != 0) continue;
		if (lt_reply.data.len < 8 + 8 + 4) continue;

		// Line table: start(8) + end(8) + count(4) + entries[lineCodeIndex(8) + lineNumber(4)]
		int lt_count = transport::get_int_be(lt_reply.data, 16);
		usz lt_pos = 20;

		for (int e = 0; e < lt_count; e++) {
			if (lt_pos + 12 > lt_reply.data.len) break;
			long code_index = transport::get_long_be(lt_reply.data, lt_pos); lt_pos += 8;
			int line_number = transport::get_int_be(lt_reply.data, lt_pos); lt_pos += 4;

			if (line_number == line) {
				*out_method_id = method_id;
				*out_offset = code_index;
				return true;
			}
		}
	}

	return false;
}

// Convert JVM class signature to ClassMatch pattern
// "Lcom/example/FooKt;" -> "com.example.FooKt*"
fn String sig_to_class_match(String sig) {
	if (sig.len < 3) return "";
	// Strip leading 'L' and trailing ';'
	String inner = sig[1:sig.len - 2];

	DString pattern;
	pattern.tinit();
	foreach (c : inner) {
		if (c == '/') {
			pattern.append_char('.');
		} else {
			pattern.append_char(c);
		}
	}
	pattern.append("*");
	return pattern.str_view();
}

// Resolve pending (unverified) breakpoints when a class is prepared
// Called from server when CLASS_PREPARE event is received
fn void resolve_pending_breakpoints(BreakpointManager* self, JdwpConnection* conn, String class_sig, long class_id, char type_tag, DapBreakpointUpdate[] updates, usz* update_count) {
	for (usz i = 0; i < self.count; i++) {
		if (self.breakpoints[i].verified) continue;
		if (self.breakpoints[i].jdwp_request_id != 0) continue;

		// Check if this pending breakpoint matches the prepared class
		bool matches = false;
		if (self.breakpoints[i].class_sig_kt == class_sig) matches = true;
		if (self.breakpoints[i].class_sig_plain == class_sig) matches = true;

		// Also handle inner classes: Lcom/example/FooKt$bar$1; matches Lcom/example/FooKt;
		if (!matches) {
			if (self.breakpoints[i].class_sig_kt.len > 2 && class_sig.len > 2) {
				String prefix = self.breakpoints[i].class_sig_kt[1:self.breakpoints[i].class_sig_kt.len - 2];
				String candidate = class_sig[1:class_sig.len - 2];
				if (candidate.starts_with(prefix)) matches = true;
			}
			if (!matches && self.breakpoints[i].class_sig_plain.len > 2 && class_sig.len > 2) {
				String prefix = self.breakpoints[i].class_sig_plain[1:self.breakpoints[i].class_sig_plain.len - 2];
				String candidate = class_sig[1:class_sig.len - 2];
				if (candidate.starts_with(prefix)) matches = true;
			}
		}

		if (!matches) continue;

		log::info("[dap] Resolving pending breakpoint: dap_id=%d line=%d class=%s", self.breakpoints[i].dap_id, self.breakpoints[i].line, class_sig);

		// Try to set the JDWP breakpoint now
		long method_id = 0;
		long offset = 0;
		bool found = find_line_location(conn, class_id, self.breakpoints[i].line, &method_id, &offset);

		if (found) {
			int jdwp_req_id = 0;
			if (self.breakpoints[i].hit_count > 0) {
				if (try reply = protocol::set_breakpoint_with_count(conn, type_tag, class_id, method_id, offset, self.breakpoints[i].hit_count)) {
					if (reply.error_code == 0 && reply.data.len >= 4) {
						jdwp_req_id = transport::get_int_be(reply.data, 0);
					}
				}
			} else {
				if (try reply = protocol::set_breakpoint(conn, type_tag, class_id, method_id, offset)) {
					if (reply.error_code == 0 && reply.data.len >= 4) {
						jdwp_req_id = transport::get_int_be(reply.data, 0);
					}
				}
			}

			if (jdwp_req_id != 0) {
				self.breakpoints[i].jdwp_request_id = jdwp_req_id;
				self.breakpoints[i].verified = true;
				log::info("[dap] Breakpoint verified: dap_id=%d jdwp_req=%d", self.breakpoints[i].dap_id, jdwp_req_id);

				if (*update_count < updates.len) {
					DapBreakpointUpdate upd;
					upd.dap_id = self.breakpoints[i].dap_id;
					upd.line = self.breakpoints[i].line;
					upd.verified = true;
					upd.source_path = self.breakpoints[i].source_path;
					updates[*update_count] = upd;
					*update_count = *update_count + 1;
				}
			}
		}

		// Clear the CLASS_PREPARE request
		if (self.breakpoints[i].prepare_request_id != 0) {
			if (catch excuse = protocol::clear_event_request(conn, protocol::EK_CLASS_PREPARE, self.breakpoints[i].prepare_request_id)) {
				log::debug("[dap] Failed to clear CLASS_PREPARE request: %s", excuse);
			}
			self.breakpoints[i].prepare_request_id = 0;
		}
	}
}

struct DapBreakpointUpdate {
	int dap_id;
	int line;
	bool verified;
	String source_path;
}

// Convert source path to JVM class signature
// e.g., .../src/main/kotlin/com/example/Main.kt -> Lcom/example/MainKt; (with_kt=true)
//                                                -> Lcom/example/Main;  (with_kt=false)
fn String source_path_to_class_sig(String path, bool with_kt) {
	// Find "src/main/kotlin/" or "src/main/java/" or "src/" or "test/" or "main/" prefix
	String[] markers = { "src/main/kotlin/", "src/main/java/", "src/test/kotlin/", "src/test/java/", "src/", "test/", "main/" };
	String relative = "";

	foreach (marker : markers) {
		for (usz i = 0; i + marker.len <= path.len; i++) {
			if (path[i:marker.len] == marker) {
				relative = path[i + marker.len..];
				break;
			}
		}
		if (relative.len > 0) break;
	}

	if (relative.len == 0) return "";

	// Remove .kt or .java extension
	if (relative.len > 3 && relative[relative.len - 3..] == ".kt") {
		relative = relative[:relative.len - 3];
	} else if (relative.len > 5 && relative[relative.len - 5..] == ".java") {
		relative = relative[:relative.len - 5];
	} else {
		return "";
	}

	// Build "L" + path with / + optional "Kt" + ";"
	DString sig;
	sig.tinit();
	sig.append("L");
	sig.append(relative);
	if (with_kt) {
		sig.append("Kt;");
	} else {
		sig.append(";");
	}

	return sig.str_view();
}

// ── Exception Breakpoints ──────────────────────────────────────────

const int MAX_EXCEPTION_BPS = 32;

struct ExceptionBpManager {
	ExceptionBp[MAX_EXCEPTION_BPS] entries;
	usz count;
}

struct ExceptionBp {
	int jdwp_request_id;
	String filter_id;       // "all", "uncaught", "caught"
}

fn void ExceptionBpManager.init(ExceptionBpManager* self) {
	self.count = 0;
}

// Handle setExceptionBreakpoints request
// DAP filters: "all" (caught+uncaught), "uncaught", "caught"
fn Object* handle_set_exception_breakpoints(ExceptionBpManager* self, JdwpConnection* conn, Object* args) {
	// Clear existing exception breakpoints
	for (usz i = 0; i < self.count; i++) {
		if (self.entries[i].jdwp_request_id != 0) {
			if (catch excuse = protocol::clear_event_request(conn, protocol::EK_EXCEPTION, self.entries[i].jdwp_request_id)) {
				log::err("[dap] Failed to clear exception bp: %s", excuse);
			}
		}
	}
	self.count = 0;

	Object* filters = args.get("filters") ?? null;
	Object* result_bps = object::new_obj(tmem);

	if (filters == null || !filters.is_array()) {
		Object* body = object::new_obj(tmem);
		body.set("breakpoints", result_bps);
		return body;
	}

	for (sz i = 0; i < filters.get_len(); i++) {
		String filter_id = filters.get_string_at(i) ?? "";

		bool catch_caught = false;
		bool catch_uncaught = false;
		if (filter_id == "all") {
			catch_caught = true;
			catch_uncaught = true;
		} else if (filter_id == "uncaught") {
			catch_uncaught = true;
		} else if (filter_id == "caught") {
			catch_caught = true;
		}

		Object* bp_result = object::new_obj(tmem);

		// Set JDWP exception event request (class_id=0 means all exceptions)
		int jdwp_req_id = 0;
		if (try reply = protocol::set_exception_request(conn, 0, catch_caught, catch_uncaught)) {
			if (reply.error_code == 0 && reply.data.len >= 4) {
				jdwp_req_id = transport::get_int_be(reply.data, 0);
			}
		}

		bp_result.set("verified", jdwp_req_id != 0);
		if (jdwp_req_id == 0) {
			bp_result.set("message", "Failed to set exception breakpoint");
		}

		if (self.count < MAX_EXCEPTION_BPS) {
			ExceptionBp entry;
			entry.jdwp_request_id = jdwp_req_id;
			entry.filter_id = filter_id;
			self.entries[self.count] = entry;
			self.count++;
		}

		result_bps.push(bp_result);
	}

	Object* body = object::new_obj(tmem);
	body.set("breakpoints", result_bps);
	return body;
}

fn Object* build_empty_response() {
	Object* body = object::new_obj(tmem);
	body.set("breakpoints", object::new_obj(tmem));
	return body;
}

// ── Function Breakpoints ───────────────────────────────────────────

const int MAX_FUNC_BREAKPOINTS = 64;

struct FuncBpManager {
	FuncBreakpoint[MAX_FUNC_BREAKPOINTS] entries;
	usz count;
	int next_id;
}

struct FuncBreakpoint {
	int dap_id;
	int jdwp_request_id;
	String name;  // function name (heap-copied)
}

fn void FuncBpManager.init(FuncBpManager* self) {
	self.count = 0;
	self.next_id = 1;
}

// Handle setFunctionBreakpoints request
// Sets breakpoints at the first line of methods matching the given names.
// Searches all loaded classes for matching method names.
fn Object* handle_set_function_breakpoints(FuncBpManager* self, JdwpConnection* conn, Object* args) {
	// Clear existing function breakpoints
	for (usz i = 0; i < self.count; i++) {
		if (self.entries[i].jdwp_request_id != 0) {
			if (catch excuse = protocol::clear_event_request(conn, protocol::EK_BREAKPOINT, self.entries[i].jdwp_request_id)) {
				log::err("[dap] Failed to clear function bp: %s", excuse);
			}
		}
	}
	self.count = 0;

	Object* bp_list = args.get("breakpoints") ?? null;
	Object* result_bps = object::new_obj(tmem);

	if (bp_list == null || !bp_list.is_array()) {
		Object* body = object::new_obj(tmem);
		body.set("breakpoints", result_bps);
		return body;
	}

	// Get all loaded classes once
	JdwpReply classes_reply;
	bool have_classes = false;
	if (try r = protocol::get_all_classes(conn)) {
		if (r.error_code == 0) {
			classes_reply = r;
			have_classes = true;
		}
	}

	for (sz i = 0; i < bp_list.get_len(); i++) {
		Object* bp_req = bp_list.get_at(i);
		String name = bp_req.get_string("name") ?? "";

		Object* bp_result = object::new_obj(tmem);
		int dap_id = self.next_id;
		self.next_id++;
		bp_result.set("id", dap_id);

		if (name.len == 0 || !have_classes) {
			bp_result.set("verified", false);
			bp_result.set("message", "Function not found");
			result_bps.push(bp_result);
			continue;
		}

		// Parse "ClassName.methodName" or just "methodName"
		String class_hint = "";
		String method_name = name;
		for (usz j = name.len; j > 0; j--) {
			if (name[j - 1] == '.') {
				class_hint = name[:j - 1];
				method_name = name[j..];
				break;
			}
		}

		// Search loaded classes for matching method
		int jdwp_req_id = 0;
		bool found = find_and_set_method_breakpoint(conn, &classes_reply, class_hint, method_name, &jdwp_req_id);

		bp_result.set("verified", found && jdwp_req_id != 0);
		if (!found) {
			bp_result.set("message", "Function not found");
		} else if (jdwp_req_id == 0) {
			bp_result.set("message", "Failed to set breakpoint");
		}

		if (self.count < MAX_FUNC_BREAKPOINTS) {
			FuncBreakpoint entry;
			entry.dap_id = dap_id;
			entry.jdwp_request_id = jdwp_req_id;
			entry.name = name.copy(mem);
			self.entries[self.count] = entry;
			self.count++;
		}

		result_bps.push(bp_result);
	}

	Object* body = object::new_obj(tmem);
	body.set("breakpoints", result_bps);
	return body;
}

// Search all loaded classes for a method and set breakpoint at its first line
fn bool find_and_set_method_breakpoint(JdwpConnection* conn, JdwpReply* classes_reply, String class_hint, String method_name, int* out_req_id) {
	if (classes_reply.data.len < 4) return false;

	int class_count = transport::get_int_be(classes_reply.data, 0);
	usz pos = 4;

	for (int ci = 0; ci < class_count; ci++) {
		if (pos + 1 + 8 + 4 > classes_reply.data.len) break;
		char type_tag = classes_reply.data[pos]; pos++;
		long type_id = transport::get_long_be(classes_reply.data, pos); pos += 8;

		// Signature (length-prefixed UTF-8)
		int sig_len = transport::get_int_be(classes_reply.data, pos); pos += 4;
		String sig = "";
		if (sig_len > 0 && pos + (usz)sig_len <= classes_reply.data.len) {
			sig = (String)classes_reply.data[pos:(usz)sig_len];
		}
		pos += (usz)sig_len;

		// Status (4 bytes)
		if (pos + 4 > classes_reply.data.len) break;
		pos += 4;

		// Skip non-class types and system classes
		if (type_tag != 1 && type_tag != 2) continue; // only CLASS and INTERFACE
		if (sig.len < 3) continue;

		// If class_hint given, check if signature matches
		if (class_hint.len > 0) {
			// Convert "com.example.Foo" to "com/example/Foo"
			// Check if sig contains the class hint
			if (!sig_matches_class_hint(sig, class_hint)) continue;
		}

		// Search methods of this class for matching name
		if (try_set_breakpoint_on_method(conn, type_tag, type_id, method_name, out_req_id)) {
			return true;
		}
	}

	return false;
}

// Check if a JVM signature like "Lcom/example/Foo;" matches a class hint like "com.example.Foo" or "Foo"
fn bool sig_matches_class_hint(String sig, String hint) {
	if (sig.len < 3) return false;
	// Strip L...;
	String inner = sig[1:sig.len - 2];

	// Simple name match: hint is just "Foo", check if class name ends with it
	if (hint.len <= inner.len) {
		// Convert hint dots to slashes for comparison
		bool has_dots = false;
		foreach (c : hint) {
			if (c == '.') { has_dots = true; break; }
		}

		if (!has_dots) {
			// Simple name: check if inner ends with /hint or equals hint
			if (inner == hint) return true;
			if (inner.len > hint.len && inner[inner.len - hint.len - 1] == '/') {
				return inner[inner.len - hint.len..] == hint;
			}
			return false;
		}

		// Dotted name: convert to slashed and compare
		DString slashed;
		slashed.tinit();
		foreach (c : hint) {
			if (c == '.') {
				slashed.append_char('/');
			} else {
				slashed.append_char(c);
			}
		}
		String s = slashed.str_view();
		if (inner == s) return true;
		// Also check suffix match
		if (inner.len > s.len && inner[inner.len - s.len - 1] == '/') {
			return inner[inner.len - s.len..] == s;
		}
	}
	return false;
}

// Try to find a method by name in a class and set a breakpoint at its first line
fn bool try_set_breakpoint_on_method(JdwpConnection* conn, char type_tag, long class_id, String method_name, int* out_req_id) {
	JdwpReply methods_reply;
	if (try r = protocol::get_methods(conn, class_id)) {
		methods_reply = r;
	} else {
		return false;
	}
	if (methods_reply.error_code != 0 || methods_reply.data.len < 4) return false;

	int method_count = transport::get_int_be(methods_reply.data, 0);
	usz pos = 4;

	for (int m = 0; m < method_count; m++) {
		if (pos + 8 > methods_reply.data.len) break;
		long method_id = transport::get_long_be(methods_reply.data, pos); pos += 8;

		// Name
		if (pos + 4 > methods_reply.data.len) break;
		int name_len = transport::get_int_be(methods_reply.data, pos); pos += 4;
		String mname = "";
		if (name_len > 0 && pos + (usz)name_len <= methods_reply.data.len) {
			mname = (String)methods_reply.data[pos:(usz)name_len];
		}
		pos += (usz)name_len;

		// Signature
		if (pos + 4 > methods_reply.data.len) break;
		int sig_len = transport::get_int_be(methods_reply.data, pos); pos += 4;
		pos += (usz)sig_len;

		// modBits
		if (pos + 4 > methods_reply.data.len) break;
		pos += 4;

		if (mname != method_name) continue;

		// Found matching method — get first line from line table
		long first_offset = 0;
		if (try lt = protocol::get_line_table(conn, class_id, method_id)) {
			if (lt.error_code == 0 && lt.data.len >= 20) {
				int lt_count = transport::get_int_be(lt.data, 16);
				if (lt_count > 0 && lt.data.len >= 32) {
					first_offset = transport::get_long_be(lt.data, 20);
				}
			}
		}

		// Set breakpoint at method entry (first bytecode offset)
		if (try reply = protocol::set_breakpoint(conn, type_tag, class_id, method_id, first_offset)) {
			if (reply.error_code == 0 && reply.data.len >= 4) {
				*out_req_id = transport::get_int_be(reply.data, 0);
				return true;
			}
		}
	}

	return false;
}
