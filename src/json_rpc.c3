module kls::json_rpc;

import std::io;
import std::encoding::json;
import std::collections::object;
import std::core::mem;

// JSON-RPC 2.0 error codes
const int PARSE_ERROR = -32700;
const int INVALID_REQUEST = -32600;
const int METHOD_NOT_FOUND = -32601;
const int INVALID_PARAMS = -32602;
const int INTERNAL_ERROR = -32603;
const int SERVER_NOT_INITIALIZED = -32002;

faultdef
	UNEXPECTED_EOF,
	INVALID_HEADER,
	CONTENT_LENGTH_MISSING,
	READ_ERROR;

/**
 * Read a complete LSP message from stdin.
 * Parses Content-Length header, then reads the JSON body.
 * Returns the raw JSON string (temp-allocated).
 */
fn String? read_message() {
	InStream stdin = io::stdin();

	// Read headers until blank line
	int content_length = -1;
	while (true) {
		String line = io::treadline(stdin)!;

		// Strip trailing \r if present
		if (line.len > 0 && line[line.len - 1] == '\r') {
			line = line[:line.len - 1];
		}

		// Blank line = end of headers
		if (line.len == 0) break;

		// Parse Content-Length header
		if (line.starts_with("Content-Length: ")) {
			String num_str = line["Content-Length: ".len..];
			content_length = num_str.to_int()!;
		}
		// Ignore other headers (e.g., Content-Type)
	}

	if (content_length < 0) {
		return CONTENT_LENGTH_MISSING~;
	}

	// Read exactly content_length bytes
	char[] buf = mem::talloc_array(char, (usz)content_length);
	usz bytes_read = 0;
	while (bytes_read < (usz)content_length) {
		char[] remaining = buf[bytes_read..];
		usz n = stdin.read(remaining)!;
		if (n == 0) {
			return UNEXPECTED_EOF~;
		}
		bytes_read += n;
	}

	return (String)buf[:(usz)content_length];
}

/**
 * Send a JSON-RPC response with a result.
 */
fn void send_response(int id, Object* result) {
	Object* response = object::new_obj(tmem);
	response.set("jsonrpc", "2.0");
	response.set("id", id);
	if (result != null) {
		response.set("result", result);
	} else {
		// null result (e.g., shutdown)
		Object* null_val = object::new_null();
		response.set("result", null_val);
	}

	write_message(response);
}

/**
 * Send a JSON-RPC error response.
 */
fn void send_error_response(int id, int code, String message) {
	Object* error_obj = object::new_obj(tmem);
	error_obj.set("code", code);
	error_obj.set("message", message);

	Object* response = object::new_obj(tmem);
	response.set("jsonrpc", "2.0");
	response.set("id", id);
	response.set("error", error_obj);

	write_message(response);
}

/**
 * Send a JSON-RPC notification (no id).
 */
fn void send_notification(String method, Object* params) {
	Object* msg = object::new_obj(tmem);
	msg.set("jsonrpc", "2.0");
	msg.set("method", method);
	if (params != null) {
		msg.set("params", params);
	}

	write_message(msg);
}

/**
 * Write a JSON object as an LSP message to stdout.
 */
fn void write_message(Object* msg) {
	// Serialize JSON body to a temp DString
	DString body;
	body.tinit();
	body.appendf("%s", msg);
	String body_str = body.str_view();

	// Write Content-Length header + body
	OutStream stdout = io::stdout();
	io::fprintf(stdout, "Content-Length: %d\r\n\r\n", body_str.len)!!;
	io::fprint(stdout, body_str)!!;
	stdout.flush()!!;
}
