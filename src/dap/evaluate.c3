module kls::dap::evaluate;

import std::collections::object;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;
import kls::dap::variables;

// Handle evaluate request
// Supports "this" and local variable name lookups
fn Object* handle_evaluate(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	Object* body = object::new_obj(tmem);

	String expression = args.get_string("expression") ?? "";
	int frame_id = (int)(args.get_int("frameId") ?? 0);

	if (expression.len == 0) {
		body.set("result", "");
		body.set("variablesReference", 0);
		return body;
	}

	// Simple case: "this"
	if (expression == "this") {
		return evaluate_this(conn, id_mgr, frame_id);
	}

	// Dot-member access: "x.y" or "x.y.z" — evaluate base, then read field(s)
	for (usz i = 0; i < expression.len; i++) {
		if (expression[i] == '.') {
			String base = expression[:i];
			String field_chain = expression[i + 1..];
			return evaluate_dot_expr(conn, id_mgr, frame_id, base, field_chain);
		}
	}

	// Try local variable lookup
	return evaluate_local(conn, id_mgr, frame_id, expression);
}

fn Object* evaluate_this(JdwpConnection* conn, IdManager* id_mgr, int dap_frame_id) {
	Object* body = object::new_obj(tmem);

	FrameRef frame_ref;
	if (try ref = id_mgr.get_frame(dap_frame_id)) {
		frame_ref = ref;
	} else {
		body.set("result", "<no frame>");
		body.set("variablesReference", 0);
		return body;
	}

	// Get "this" from stack frame
	char[16] data;
	transport::put_long_be(data[..], 0, frame_ref.thread_id);
	transport::put_long_be(data[..], 8, frame_ref.frame_id);

	int cmd_id;
	if (try id = conn.send_command(protocol::CS_STACK_FRAME, protocol::SF_THIS_OBJECT, data[:16])) {
		cmd_id = id;
	} else {
		body.set("result", "<error>");
		body.set("variablesReference", 0);
		return body;
	}

	JdwpReply reply;
	if (try r = conn.read_reply()) {
		reply = r;
	} else {
		body.set("result", "<error>");
		body.set("variablesReference", 0);
		return body;
	}

	if (reply.error_code == 0 && reply.data.len >= 9) {
		char tag = reply.data[0];
		long object_id = transport::get_long_be(reply.data, 1);

		String val = variables::format_tagged_value(conn, tag, reply.data, 1);
		int child_ref = 0;

		if (object_id != 0) {
			VarRef var_ref;
			var_ref.thread_id = frame_ref.thread_id;
			var_ref.frame_id = frame_ref.frame_id;
			var_ref.scope = ScopeKind.THIS_OBJECT;
			var_ref.object_id = object_id;
			child_ref = id_mgr.register_var_ref(var_ref);
		}

		body.set("result", val);
		body.set("variablesReference", child_ref);
	} else {
		body.set("result", "<unavailable>");
		body.set("variablesReference", 0);
	}

	return body;
}

// Evaluate a local variable by name in the given frame
fn Object* evaluate_local(JdwpConnection* conn, IdManager* id_mgr, int dap_frame_id, String name) {
	Object* body = object::new_obj(tmem);

	FrameRef frame_ref;
	if (try ref = id_mgr.get_frame(dap_frame_id)) {
		frame_ref = ref;
	} else {
		body.set("result", "<no frame>");
		body.set("variablesReference", 0);
		return body;
	}

	// Get variable table for this method
	JdwpReply vt_reply;
	if (try r = protocol::get_variable_table(conn, frame_ref.class_id, frame_ref.method_id)) {
		vt_reply = r;
	} else {
		body.set("result", "<cannot read variables>");
		body.set("variablesReference", 0);
		return body;
	}

	if (vt_reply.error_code != 0 || vt_reply.data.len < 8) {
		body.set("result", "<variable table unavailable>");
		body.set("variablesReference", 0);
		return body;
	}

	// Parse variable table: skip argCnt (4 bytes), read slot count
	usz pos = 4;
	int slot_count = transport::get_int_be(vt_reply.data, pos); pos += 4;

	// Search for matching variable name
	int target_slot = -1;
	char target_tag = 0;
	for (int i = 0; i < slot_count; i++) {
		if (pos + 8 > vt_reply.data.len) break;
		pos += 8; // skip codeIndex (long)

		// Name
		if (pos + 4 > vt_reply.data.len) break;
		int name_len = transport::get_int_be(vt_reply.data, pos); pos += 4;
		String var_name = "";
		if (name_len > 0 && pos + (usz)name_len <= vt_reply.data.len) {
			var_name = (String)vt_reply.data[pos:name_len];
		}
		pos += (usz)name_len;

		// Signature
		if (pos + 4 > vt_reply.data.len) break;
		int sig_len = transport::get_int_be(vt_reply.data, pos); pos += 4;
		String sig = "";
		if (sig_len > 0 && pos + (usz)sig_len <= vt_reply.data.len) {
			sig = (String)vt_reply.data[pos:sig_len];
		}
		pos += (usz)sig_len;

		// Length + slot
		if (pos + 8 > vt_reply.data.len) break;
		pos += 4; // skip length
		int slot = transport::get_int_be(vt_reply.data, pos); pos += 4;

		if (var_name == name) {
			target_slot = slot;
			target_tag = variables::sig_to_tag(sig);
			break;
		}
	}

	if (target_slot < 0) {
		body.set("result", "<not found>");
		body.set("variablesReference", 0);
		return body;
	}

	// Read the value from the frame
	int[1] slots = { target_slot };
	char[1] tag_arr = { target_tag };
	JdwpReply val_reply;
	if (try r = protocol::get_frame_values(conn, frame_ref.thread_id, frame_ref.frame_id, slots[..], tag_arr[..])) {
		val_reply = r;
	} else {
		body.set("result", "<read error>");
		body.set("variablesReference", 0);
		return body;
	}

	if (val_reply.error_code != 0 || val_reply.data.len < 5) {
		body.set("result", "<unavailable>");
		body.set("variablesReference", 0);
		return body;
	}

	// Parse: count (4) + tag (1) + value
	usz vpos = 4;
	char val_tag = val_reply.data[vpos]; vpos++;
	int val_size = variables::tag_value_size(val_tag);

	if (vpos + (usz)val_size > val_reply.data.len) {
		body.set("result", "<truncated>");
		body.set("variablesReference", 0);
		return body;
	}

	String val_str = variables::format_tagged_value(conn, val_tag, val_reply.data, vpos);

	int child_ref = 0;
	if ((val_tag == 'L' || val_tag == '[' || val_tag == 's') && val_size == 8) {
		long obj_id = transport::get_long_be(val_reply.data, vpos);
		if (obj_id != 0) {
			VarRef var_ref;
			var_ref.thread_id = frame_ref.thread_id;
			var_ref.frame_id = frame_ref.frame_id;
			var_ref.scope = ScopeKind.THIS_OBJECT;
			var_ref.object_id = obj_id;
			var_ref.class_id = 0;
			var_ref.method_id = 0;
			child_ref = id_mgr.register_var_ref(var_ref);
		}
	}

	body.set("result", val_str);
	body.set("variablesReference", child_ref);
	return body;
}

/**
 * Evaluate a dot expression like "x.y" or "this.field.sub".
 * First evaluates the base (local variable or "this"), then reads
 * fields from the resulting object via JDWP ReferenceType.Fields.
 */
fn Object* evaluate_dot_expr(JdwpConnection* conn, IdManager* id_mgr, int dap_frame_id, String base, String field_chain) {
	Object* body = object::new_obj(tmem);

	// Evaluate the base to get an object ID
	Object* base_result;
	if (base == "this") {
		base_result = evaluate_this(conn, id_mgr, dap_frame_id);
	} else {
		base_result = evaluate_local(conn, id_mgr, dap_frame_id, base);
	}

	// Get the variablesReference from base — need object ID
	int base_var_ref = (int)(base_result.get_int("variablesReference") ?? 0);
	if (base_var_ref == 0) {
		// Base is not an object (primitive or not found)
		body.set("result", base_result.get_string("result") ?? "<error>");
		body.set("variablesReference", 0);
		return body;
	}

	// Get the VarRef to find the object ID
	VarRef var_ref;
	if (try ref = id_mgr.get_var_ref(base_var_ref)) {
		var_ref = ref;
	} else {
		body.set("result", "<cannot resolve base>");
		body.set("variablesReference", 0);
		return body;
	}

	// Walk the field chain (may contain more dots: "field.sub")
	long current_object_id = var_ref.object_id;
	long current_thread_id = var_ref.thread_id;
	long current_frame_id = var_ref.frame_id;

	// Split remaining fields by '.'
	String remaining = field_chain;
	while (remaining.len > 0) {
		// Extract next field name
		String field_name;
		String rest = "";
		bool found_dot = false;
		for (usz i = 0; i < remaining.len; i++) {
			if (remaining[i] == '.') {
				field_name = remaining[:i];
				rest = remaining[i + 1..];
				found_dot = true;
				break;
			}
		}
		if (!found_dot) {
			field_name = remaining;
		}

		// Read field from current object
		Object* field_result = read_object_field(conn, id_mgr, current_object_id, current_thread_id, current_frame_id, field_name);
		if (field_result == null) {
			body.set("result", "<field not found>");
			body.set("variablesReference", 0);
			return body;
		}

		if (!found_dot) {
			// Final field — return its result
			return field_result;
		}

		// Need to continue chaining — get object ID from field result
		int field_var_ref = (int)(field_result.get_int("variablesReference") ?? 0);
		if (field_var_ref == 0) {
			// Field is primitive, can't chain further
			return field_result;
		}

		if (try ref = id_mgr.get_var_ref(field_var_ref)) {
			current_object_id = ref.object_id;
		} else {
			return field_result;
		}

		remaining = rest;
	}

	body.set("result", "");
	body.set("variablesReference", 0);
	return body;
}

/**
 * Read a single field from a JDWP object by field name.
 * Returns an evaluate-style result object or null if field not found.
 */
fn Object* read_object_field(JdwpConnection* conn, IdManager* id_mgr, long object_id, long thread_id, long frame_id, String field_name) {
	if (object_id == 0) return null;

	// Get the object's reference type
	char[8] ref_data;
	transport::put_long_be(ref_data[..], 0, object_id);

	if (try id = conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_REFERENCE_TYPE, ref_data[:8])) {
		if (try reply = conn.read_reply()) {
			if (reply.error_code != 0 || reply.data.len < 9) return null;
			// tag (1) + typeID (8)
			long type_id = transport::get_long_be(reply.data, 1);

			// Get fields of the type
			char[8] type_data;
			transport::put_long_be(type_data[..], 0, type_id);
			if (try fid = conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_FIELDS, type_data[:8])) {
				if (try freply = conn.read_reply()) {
					if (freply.error_code != 0 || freply.data.len < 4) return null;

					int field_count = transport::get_int_be(freply.data, 0);
					usz fpos = 4;

					// Find matching field
					for (int fi = 0; fi < field_count; fi++) {
						if (fpos + 8 > freply.data.len) break;
						long fid_val = transport::get_long_be(freply.data, fpos); fpos += 8;

						// Name
						if (fpos + 4 > freply.data.len) break;
						int name_len = transport::get_int_be(freply.data, fpos); fpos += 4;
						String fname = "";
						if (name_len > 0 && fpos + (usz)name_len <= freply.data.len) {
							fname = (String)freply.data[fpos:(usz)name_len];
						}
						fpos += (usz)name_len;

						// Signature
						if (fpos + 4 > freply.data.len) break;
						int sig_len = transport::get_int_be(freply.data, fpos); fpos += 4;
						fpos += (usz)sig_len;

						// modBits
						if (fpos + 4 > freply.data.len) break;
						fpos += 4;

						if (fname == field_name) {
							// Found — read field value
							return read_field_value(conn, id_mgr, object_id, thread_id, frame_id, fid_val);
						}
					}
				}
			}
		}
	}
	return null;
}

/**
 * Read a field value from an object by JDWP field ID.
 */
fn Object* read_field_value(JdwpConnection* conn, IdManager* id_mgr, long object_id, long thread_id, long frame_id, long field_id) {
	Object* body = object::new_obj(tmem);

	// ObjectReference.GetValues: objectID (8) + field_count (4) + fieldID (8)
	char[20] data;
	transport::put_long_be(data[..], 0, object_id);
	transport::put_int_be(data[..], 8, 1); // 1 field
	transport::put_long_be(data[..], 12, field_id);

	if (try id = conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_GET_VALUES, data[:20])) {
		if (try reply = conn.read_reply()) {
			if (reply.error_code == 0 && reply.data.len >= 5) {
				// count (4) + tag (1) + value
				usz vpos = 4;
				char val_tag = reply.data[vpos]; vpos++;
				int val_size = variables::tag_value_size(val_tag);

				if (vpos + (usz)val_size <= reply.data.len) {
					String val_str = variables::format_tagged_value(conn, val_tag, reply.data, vpos);
					int child_ref = 0;

					if ((val_tag == 'L' || val_tag == '[' || val_tag == 's') && val_size == 8) {
						long obj_id = transport::get_long_be(reply.data, vpos);
						if (obj_id != 0) {
							VarRef var_ref;
							var_ref.thread_id = thread_id;
							var_ref.frame_id = frame_id;
							var_ref.scope = ScopeKind.THIS_OBJECT;
							var_ref.object_id = obj_id;
							var_ref.class_id = 0;
							var_ref.method_id = 0;
							child_ref = id_mgr.register_var_ref(var_ref);
						}
					}

					body.set("result", val_str);
					body.set("variablesReference", child_ref);
					return body;
				}
			}
		}
	}

	body.set("result", "<error>");
	body.set("variablesReference", 0);
	return body;
}
