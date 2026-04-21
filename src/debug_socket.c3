module kls::debug_socket;

import std::net;
import std::net::tcp;
import std::net::os;
import std::io;
import std::io::file;
import std::encoding::json;
import std::collections::object;
import kls::log;
import kls::json_rpc;
import kls::workspace;
import kls::lsp::execute_command;

extern fn int getsockname(NativeSocket socket, SockAddrPtr address, Socklen_t* address_len);

// ── Debug server ───────────────────────────────────────────────────

struct DebugServer {
	TcpServerSocket server;
	bool active;
	int port;
	String port_file_path;    // heap-copied path to .kls-debug-port
}

faultdef DEBUG_BIND_ERROR, DEBUG_ACCEPT_ERROR, DEBUG_READ_ERROR;

/**
 * Start debug TCP server on localhost with ephemeral port.
 * Writes port number to <workspace_root>/.kls-debug-port for discovery.
 */
fn void DebugServer.start(DebugServer* self, String workspace_root) {
	if (try server = tcp::listen("127.0.0.1", 0, 4, REUSEADDR)) {
		self.server = server;
	} else {
		log::warn("[kls] Debug server: failed to bind, debug queries disabled");
		self.active = false;
		return;
	}

	// Query actual bound port via getsockname
	Socket info;
	info.ai_addrlen = (Socklen_t)info.ai_addr_storage.len;
	int result = getsockname(self.server.sock, (SockAddrPtr)&info.ai_addr_storage, &info.ai_addrlen);
	if (result < 0) {
		log::warn("[kls] Debug server: getsockname failed, debug queries disabled");
		(void)self.server.close();
		self.active = false;
		return;
	}

	// Port is bytes [2..3] of sockaddr_in, big-endian
	char[] port_bytes = info.ai_addr_storage[2:2];
	self.port = ((int)port_bytes[0] << 8) | (int)port_bytes[1];
	// Mask to unsigned range
	self.port = self.port & 0xFFFF;
	self.active = true;

	log::info("[kls] Debug server listening on 127.0.0.1:%d", self.port);

	// Write port file for tool discovery
	if (workspace_root.len > 0) {
		DString path_buf;
		path_buf.tinit();
		path_buf.appendf("%s/.kls-debug-port", workspace_root);
		String path = path_buf.str_view().copy(mem);
		self.port_file_path = path;

		DString port_str;
		port_str.tinit();
		port_str.appendf("%d", self.port);

		if (try f = file::open(path, "w")) {
			(void)f.write(port_str.str_view());
			(void)f.close();
			log::info("[kls] Debug port written to %s", path);
		} else {
			log::warn("[kls] Failed to write debug port file: %s", path);
		}
	}
}

/**
 * Get the NativeSocket fd for use in poll_ms.
 */
fn NativeSocket DebugServer.native_socket(DebugServer* self) {
	return self.server.sock;
}

/**
 * Accept a pending connection and handle one debug query.
 * Non-blocking: only call when poll indicates readability.
 */
fn void DebugServer.accept_and_handle(DebugServer* self, WorkspaceIndex* workspace) {
	if (!self.active) return;

	TcpSocket client;
	if (try c = tcp::accept(&self.server)) {
		client = c;
	} else {
		log::debug("[kls] Debug server: accept failed");
		return;
	}

	log::debug("[kls] Debug client connected");

	// Read Content-Length header from client
	// We read byte-by-byte looking for \r\n\r\n
	char[512] header_buf;
	usz header_len = 0;
	bool found_header_end = false;

	while (header_len < header_buf.len - 1) {
		char[1] b;
		sz n = client.read(b[0..0]) ?? 0;
		if (n <= 0) break;
		header_buf[header_len] = b[0];
		header_len++;

		// Check for \r\n\r\n
		if (header_len >= 4 &&
			header_buf[header_len - 4] == '\r' &&
			header_buf[header_len - 3] == '\n' &&
			header_buf[header_len - 2] == '\r' &&
			header_buf[header_len - 1] == '\n') {
			found_header_end = true;
			break;
		}
	}

	if (!found_header_end) {
		log::debug("[kls] Debug client: no valid header");
		(void)client.close();
		return;
	}

	// Parse Content-Length
	String header_str = (String)header_buf[:header_len];
	int content_length = parse_content_length(header_str);
	if (content_length <= 0 || content_length > 1024 * 1024) {
		log::debug("[kls] Debug client: invalid Content-Length: %d", content_length);
		(void)client.close();
		return;
	}

	// Read body
	char[65536] body_buf;
	if ((usz)content_length > body_buf.len) {
		log::debug("[kls] Debug client: body too large: %d", content_length);
		(void)client.close();
		return;
	}

	usz body_read = 0;
	while (body_read < (usz)content_length) {
		sz n = client.read(body_buf[body_read..]) ?? 0;
		if (n <= 0) break;
		body_read += (usz)n;
	}

	if (body_read < (usz)content_length) {
		log::debug("[kls] Debug client: incomplete body (%d/%d)", (int)body_read, content_length);
		(void)client.close();
		return;
	}

	String body = (String)body_buf[:(usz)content_length];
	log::debug("[kls] Debug request: %s", body);

	// Parse JSON-RPC
	Object* msg;
	if (try parsed = std::encoding::json::tparse_string(body)) {
		msg = parsed;
	} else {
		send_debug_error(&client, 0, -32700, "Parse error");
		(void)client.close();
		return;
	}

	int request_id = 0;
	if (try id_val = msg.get_int("id")) {
		request_id = (int)id_val;
	}

	String method = msg.get_string("method") ?? "";
	Object* params = msg.get("params") ?? null;

	// Dispatch
	if (method == "workspace/executeCommand") {
		if (params != null) {
			if (try result = execute_command::handle_execute_command(workspace, params)) {
				send_debug_response(&client, request_id, result);
			} else {
				send_debug_error(&client, request_id, -32602, "Invalid params");
			}
		} else {
			send_debug_error(&client, request_id, -32602, "Missing params");
		}
	} else {
		send_debug_error(&client, request_id, -32601, "Method not found");
	}

	(void)client.close();
	log::debug("[kls] Debug client disconnected");
}

/**
 * Stop debug server and clean up port file.
 */
fn void DebugServer.stop(DebugServer* self) {
	if (!self.active) return;

	(void)self.server.close();
	self.active = false;

	// Remove port file
	if (self.port_file_path.len > 0) {
		(void)file::delete(self.port_file_path);
		mem::free(self.port_file_path.ptr);
		self.port_file_path = "";
	}

	log::info("[kls] Debug server stopped");
}

// ── Helpers ────────────────────────────────────────────────────────

fn int parse_content_length(String header) {
	// Look for "Content-Length: <number>"
	usz i = 0;
	while (i < header.len) {
		if (header[i..].starts_with("Content-Length:")) {
			usz num_start = i + "Content-Length:".len;
			// Skip whitespace
			while (num_start < header.len && header[num_start] == ' ') {
				num_start++;
			}
			// Parse digits
			int val = 0;
			while (num_start < header.len && header[num_start] >= '0' && header[num_start] <= '9') {
				val = val * 10 + (int)(header[num_start] - '0');
				num_start++;
			}
			return val;
		}
		i++;
	}
	return 0;
}

fn void send_debug_response(TcpSocket* client, int id, Object* result) {
	Object* response = object::new_obj(tmem);
	response.set("jsonrpc", "2.0");
	response.set("id", id);
	if (result != null) {
		response.set("result", result);
	} else {
		response.set("result", object::new_null());
	}

	DString body;
	body.tinit();
	body.appendf("%s", response);

	DString frame;
	frame.tinit();
	frame.appendf("Content-Length: %d\r\n\r\n%s", body.str_view().len, body.str_view());

	(void)client.write(frame.str_view());
}

fn void send_debug_error(TcpSocket* client, int id, int code, String message) {
	Object* response = object::new_obj(tmem);
	response.set("jsonrpc", "2.0");
	response.set("id", id);
	Object* err = object::new_obj(tmem);
	err.set("code", code);
	err.set("message", message);
	response.set("error", err);

	DString body;
	body.tinit();
	body.appendf("%s", response);

	DString frame;
	frame.tinit();
	frame.appendf("Content-Length: %d\r\n\r\n%s", body.str_view().len, body.str_view());

	(void)client.write(frame.str_view());
}
