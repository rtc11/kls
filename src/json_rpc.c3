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
 * Accepts Object* for id to support both integer and string JSON-RPC IDs.
 */
fn void send_response(Object* id, Object* result) {
	Object* response = object::new_obj(tmem);
	response.set("jsonrpc", "2.0");
	if (id != null) {
		response.set("id", id);
	}
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
 * Accepts Object* for id to support both integer and string JSON-RPC IDs.
 */
fn void send_error_response(Object* id, int code, String message) {
	Object* error_obj = object::new_obj(tmem);
	error_obj.set("code", code);
	error_obj.set("message", message);

	Object* response = object::new_obj(tmem);
	response.set("jsonrpc", "2.0");
	if (id != null) {
		response.set("id", id);
	}
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
	// Serialize JSON body to a temp DString using our
	// custom serializer that properly escapes strings.
	DString body;
	body.tinit();
	json_serialize(&body, msg);
	String body_str = body.str_view();

	// Write Content-Length header + body
	OutStream stdout = io::stdout();
	io::fprintf(stdout, "Content-Length: %d\r\n\r\n", body_str.len)!!;
	io::fprint(stdout, body_str)!!;
	stdout.flush()!!;
}

// ── Custom JSON serializer with proper string escaping ─────────────

/**
 * Append an RFC 8259 JSON-escaped string (with surrounding quotes) to out.
 * Escapes: \" \\ \n \r \t \b \f and control chars 0x00-0x1F as \u00XX.
 */
fn void json_escape_string(DString* out, String s) {
	out.appendf(`"`);
	foreach (c : s) {
		switch (c) {
			case '"':  out.appendf(`\"`);
			case '\\': out.appendf(`\\`);
			case '\n': out.appendf(`\n`);
			case '\r': out.appendf(`\r`);
			case '\t': out.appendf(`\t`);
			case '\b': out.appendf(`\b`);
			case 0x0C: out.appendf(`\f`); // form feed
			default:
				if (c < 0x20) {
					// Control character: emit \u00XX
					out.appendf(`\u00%s%s`,
						HEX_DIGITS[(c >> 4) & 0x0F],
						HEX_DIGITS[c & 0x0F]);
				} else {
					out.append_char(c);
				}
		}
	}
	out.appendf(`"`);
}

const String[16] HEX_DIGITS = {
	"0", "1", "2", "3", "4", "5", "6", "7",
	"8", "9", "a", "b", "c", "d", "e", "f",
};

/**
 * Recursively serialize an Object tree to a DString as valid JSON.
 * Unlike Object.to_format (appendf "%s"), this properly escapes
 * string values and map keys per RFC 8259.
 */
fn void json_serialize(DString* out, Object* obj) {
	if (obj.is_null()) {
		out.appendf("null");
		return;
	}
	if (obj.is_bool()) {
		out.appendf(obj.b ? "true" : "false");
		return;
	}
	if (obj.is_string()) {
		json_escape_string(out, obj.s);
		return;
	}
	if (obj.is_int()) {
		out.appendf("%d", (long)obj.i);
		return;
	}
	if (obj.is_float()) {
		out.appendf("%g", obj.f);
		return;
	}
	if (obj.is_array()) {
		out.appendf("[");
		for (sz i = 0; i < obj.get_len(); i++) {
			if (i > 0) out.appendf(",");
			json_serialize(out, obj.get_at(i));
		}
		out.appendf("]");
		return;
	}
	if (obj.is_map()) {
		out.appendf("{");
		bool first = true;
		obj.@each_entry(; String key, Object* value) {
			if (!first) out.appendf(",");
			first = false;
			json_escape_string(out, key);
			out.appendf(":");
			json_serialize(out, value);
		};
		out.appendf("}");
		return;
	}
	// Empty object (new_obj with no set/push) -> empty JSON object
	if (obj.is_empty()) {
		out.appendf("{}");
		return;
	}
	// Fallback for any other type (shouldn't happen in practice)
	out.appendf("null");
}
