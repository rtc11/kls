module kls::dap::evaluate;

import std::collections::object;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;
import kls::dap::variables;

// Handle evaluate request
// Currently supports simple name lookups only (no expression parsing)
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

	// For now, return expression as-is with note about limited evaluation
	body.set("result", expression);
	body.set("variablesReference", 0);
	return body;
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
