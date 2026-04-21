module kls::dap::threads;

import std::collections::object;
import kls::log;
import kls::json_rpc;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;

// Handle threads request — list all VM threads
fn Object* handle_threads(JdwpConnection* conn, IdManager* id_mgr) {
	Object* body = object::new_obj(tmem);
	Object* threads_arr = json_rpc::new_json_arr();

	JdwpReply reply;
	if (try r = protocol::get_all_threads(conn)) {
		reply = r;
	} else {
		body.set("threads", threads_arr);
		return body;
	}

	if (reply.error_code != 0 || reply.data.len < 4) {
		body.set("threads", threads_arr);
		return body;
	}

	int count = transport::get_int_be(reply.data, 0);
	usz pos = 4;

	for (int i = 0; i < count; i++) {
		if (pos + 8 > reply.data.len) break;
		long jdwp_tid = transport::get_long_be(reply.data, pos); pos += 8;

		int dap_tid = id_mgr.get_or_create_thread_id(jdwp_tid);

		// Get thread name
		String name = "Thread";
		if (try name_reply = protocol::get_thread_name(conn, jdwp_tid)) {
			if (name_reply.error_code == 0 && name_reply.data.len >= 4) {
				int name_len = transport::get_int_be(name_reply.data, 0);
				if (name_len > 0 && 4 + (usz)name_len <= name_reply.data.len) {
					name = (String)name_reply.data[4:name_len];
				}
			}
		}

		Object* thread = object::new_obj(tmem);
		thread.set("id", dap_tid);
		thread.set("name", name);
		threads_arr.push(thread);
	}

	body.set("threads", threads_arr);
	return body;
}
