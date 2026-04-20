module kls::dap::events;

import std::collections::object;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;

// Event kind constants (from JDWP composite event)
const char COMPOSITE_EVENT = 100;  // command set 64, command 100

struct JdwpEvent {
	char suspend_policy;
	char event_kind;
	int request_id;
	long thread_id;
	// Location fields (for breakpoint/step events)
	char type_tag;
	long class_id;
	long method_id;
	long location;
	// CLASS_PREPARE fields
	String class_signature;
}

// Try to read and parse a JDWP event (called when poll says socket readable)
// Checks buffered events first (stashed by read_reply during synchronous commands)
// Returns null if no event available or on error
fn JdwpEvent? read_event(JdwpConnection* conn) {
	char[11] header;
	char[] data;
	bool from_buffer = false;

	// Check buffered events first
	if (conn.has_buffered_events()) {
		if (conn.pop_buffered_event(header[..], &data)) {
			from_buffer = true;
			log::debug("[dap] Processing buffered event (remaining=%d)", (int)conn.event_buf_count);
		}
	}

	// Free heap-allocated buffer data when done (class_signature points into it,
	// but caller copies what it needs within @pool scope)
	defer if (from_buffer && data.len > 0) mem::free(data.ptr);

	if (!from_buffer) {
		// Read from socket
		transport::read_exact(&conn.socket, header[:11])!;

		int length = transport::get_int_be(header[..], 0);
		int id = transport::get_int_be(header[..], 4);
		char flags = header[8];

		int data_len = length - 11;
		if (data_len > 0) {
			data = mem::talloc_array(char, (usz)data_len);
			transport::read_exact(&conn.socket, data)!;
		}

		// Event packets have flags=0 (command packet from VM)
		if ((flags & transport::REPLY_FLAG) != 0) {
			log::debug("[dap] read_event got reply packet id=%d, discarding", id);
			return transport::JDWP_PROTOCOL_ERROR~;
		}
	}

	// Composite event: command set = 64, command = 100
	char cmd_set = header[9];
	char cmd = header[10];
	if (cmd_set != protocol::CS_EVENT || cmd != COMPOSITE_EVENT) {
		return transport::JDWP_PROTOCOL_ERROR~;
	}

	// Parse composite event
	// Format: suspendPolicy(1) + eventCount(4) + events[]
	if (data.len < 5) return transport::JDWP_PROTOCOL_ERROR~;

	char suspend_policy = data[0];
	int event_count = transport::get_int_be(data, 1);

	if (event_count < 1) return transport::JDWP_PROTOCOL_ERROR~;

	// Parse first event (handle one at a time for now)
	usz pos = 5;
	if (pos >= data.len) return transport::JDWP_PROTOCOL_ERROR~;

	char event_kind = data[pos]; pos++;

	JdwpEvent event;
	event.suspend_policy = suspend_policy;
	event.event_kind = event_kind;

	switch (event_kind) {
		case protocol::EK_VM_START:
			// requestID(4) + thread(8)
			if (pos + 12 > data.len) return transport::JDWP_PROTOCOL_ERROR~;
			event.request_id = transport::get_int_be(data, pos); pos += 4;
			event.thread_id = transport::get_long_be(data, pos); pos += 8;

		case protocol::EK_SINGLE_STEP:
		case protocol::EK_BREAKPOINT:
			// requestID(4) + thread(8) + location(1+8+8+8)
			if (pos + 4 + 8 + 25 > data.len) return transport::JDWP_PROTOCOL_ERROR~;
			event.request_id = transport::get_int_be(data, pos); pos += 4;
			event.thread_id = transport::get_long_be(data, pos); pos += 8;
			event.type_tag = data[pos]; pos++;
			event.class_id = transport::get_long_be(data, pos); pos += 8;
			event.method_id = transport::get_long_be(data, pos); pos += 8;
			event.location = transport::get_long_be(data, pos); pos += 8;

		case protocol::EK_CLASS_PREPARE:
			// requestID(4) + thread(8) + typeTag(1) + typeID(8) + signature(4+N) + status(4)
			if (pos + 4 + 8 + 1 + 8 > data.len) return transport::JDWP_PROTOCOL_ERROR~;
			event.request_id = transport::get_int_be(data, pos); pos += 4;
			event.thread_id = transport::get_long_be(data, pos); pos += 8;
			event.type_tag = data[pos]; pos++;
			event.class_id = transport::get_long_be(data, pos); pos += 8;
			// Read class signature
			if (pos + 4 > data.len) return transport::JDWP_PROTOCOL_ERROR~;
			int sig_len = transport::get_int_be(data, pos); pos += 4;
			if (sig_len > 0 && pos + (usz)sig_len <= data.len) {
				event.class_signature = ((String)data[pos:sig_len]).tcopy();
			}
			pos += (usz)sig_len;
			// Skip status(4)
			pos += 4;

		case protocol::EK_THREAD_START:
		case protocol::EK_THREAD_DEATH:
			// requestID(4) + thread(8)
			if (pos + 12 > data.len) return transport::JDWP_PROTOCOL_ERROR~;
			event.request_id = transport::get_int_be(data, pos); pos += 4;
			event.thread_id = transport::get_long_be(data, pos); pos += 8;

		case protocol::EK_VM_DEATH:
			// requestID(4)
			if (pos + 4 > data.len) return transport::JDWP_PROTOCOL_ERROR~;
			event.request_id = transport::get_int_be(data, pos); pos += 4;

		default:
			log::debug("[dap] Unhandled event kind: %d", (int)event_kind);
			return transport::JDWP_PROTOCOL_ERROR~;
	}

	return event;
}

// Convert JDWP event to DAP event body + event name
// Returns event name (e.g., "stopped", "thread", "terminated")
fn String event_to_dap(JdwpEvent* event, IdManager* id_mgr, Object* body) {
	switch (event.event_kind) {
		case protocol::EK_BREAKPOINT:
			int dap_tid = id_mgr.get_or_create_thread_id(event.thread_id);
			body.set("reason", "breakpoint");
			body.set("threadId", dap_tid);
			body.set("allThreadsStopped", true);
			return "stopped";

		case protocol::EK_SINGLE_STEP:
			int dap_tid = id_mgr.get_or_create_thread_id(event.thread_id);
			body.set("reason", "step");
			body.set("threadId", dap_tid);
			body.set("allThreadsStopped", true);
			return "stopped";

		case protocol::EK_CLASS_PREPARE:
			// Not a DAP event — handled specially by server
			return "_class_prepare";

		case protocol::EK_THREAD_START:
			int dap_tid = id_mgr.get_or_create_thread_id(event.thread_id);
			body.set("reason", "started");
			body.set("threadId", dap_tid);
			return "thread";

		case protocol::EK_THREAD_DEATH:
			int dap_tid = id_mgr.get_or_create_thread_id(event.thread_id);
			body.set("reason", "exited");
			body.set("threadId", dap_tid);
			return "thread";

		case protocol::EK_VM_DEATH:
			return "terminated";

		case protocol::EK_VM_START:
			// Initial thread start — usually silent
			int dap_tid = id_mgr.get_or_create_thread_id(event.thread_id);
			body.set("reason", "started");
			body.set("threadId", dap_tid);
			return "thread";

		default:
			return "";
	}
}
