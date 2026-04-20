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
