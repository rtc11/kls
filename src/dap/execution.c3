module kls::dap::execution;

import std::collections::object;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;

// Handle continue request
fn Object* handle_continue(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	// Clear transient frame/var refs
	id_mgr.clear_transient();

	int dap_thread_id = (int)(args.get_int("threadId") ?? 0);

	if (dap_thread_id != 0) {
		// Single thread continue
		if (try jdwp_tid = id_mgr.get_jdwp_thread_id(dap_thread_id)) {
			if (catch excuse = protocol::resume_thread(conn, jdwp_tid)) {
				log::err("[dap] Failed to resume thread: %s", excuse);
			}
		}
	} else {
		// Resume all
		if (catch excuse = protocol::resume_vm(conn)) {
			log::err("[dap] Failed to resume VM: %s", excuse);
		}
	}

	Object* body = object::new_obj(tmem);
	body.set("allThreadsContinued", dap_thread_id == 0);
	return body;
}

// Handle next (step over) request
fn Object* handle_next(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	return do_step(conn, id_mgr, args, protocol::STEP_OVER);
}

// Handle stepIn request
fn Object* handle_step_in(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	return do_step(conn, id_mgr, args, protocol::STEP_INTO);
}

// Handle stepOut request
fn Object* handle_step_out(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	return do_step(conn, id_mgr, args, protocol::STEP_OUT);
}

// Handle pause request
fn Object* handle_pause(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	int dap_thread_id = (int)(args.get_int("threadId") ?? 0);

	if (dap_thread_id != 0) {
		if (try jdwp_tid = id_mgr.get_jdwp_thread_id(dap_thread_id)) {
			if (catch excuse = protocol::suspend_thread(conn, jdwp_tid)) {
				log::err("[dap] Failed to suspend thread: %s", excuse);
			}
		}
	} else {
		if (catch excuse = protocol::suspend_vm(conn)) {
			log::err("[dap] Failed to suspend VM: %s", excuse);
		}
	}

	return object::new_obj(tmem);
}

// Common step implementation
fn Object* do_step(JdwpConnection* conn, IdManager* id_mgr, Object* args, int step_depth) {
	id_mgr.clear_transient();

	int dap_thread_id = (int)(args.get_int("threadId") ?? 0);
	if (dap_thread_id == 0) {
		log::err("[dap] Step request missing threadId");
		return object::new_obj(tmem);
	}

	long jdwp_tid = id_mgr.get_jdwp_thread_id(dap_thread_id) ?? 0;
	if (jdwp_tid == 0) {
		log::err("[dap] Unknown thread ID: %d", dap_thread_id);
		return object::new_obj(tmem);
	}

	// Set single-step event request, then resume thread
	if (try reply = protocol::set_single_step(conn, jdwp_tid, protocol::STEP_LINE, step_depth)) {
		if (reply.error_code != 0) {
			log::err("[dap] Step request failed: error=%d", (int)reply.error_code);
		}
	}

	// Resume to execute step
	if (catch excuse = protocol::resume_thread(conn, jdwp_tid)) {
		log::err("[dap] Failed to resume thread for step: %s", excuse);
	}

	return object::new_obj(tmem);
}
