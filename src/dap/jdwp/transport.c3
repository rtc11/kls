module kls::dap::jdwp::transport;

import std::net::tcp;
import std::io;
import kls::log;

const String JDWP_HANDSHAKE = "JDWP-Handshake";
const usz HEADER_SIZE = 11;  // 4 (length) + 4 (id) + 1 (flags) + 1 (cmdset) + 1 (cmd)
const usz REPLY_HEADER_SIZE = 11;  // 4 (length) + 4 (id) + 1 (flags) + 2 (error code)
const char REPLY_FLAG = 0x80;

faultdef
	JDWP_HANDSHAKE_FAILED,
	JDWP_CONNECTION_FAILED,
	JDWP_READ_ERROR,
	JDWP_WRITE_ERROR,
	JDWP_PROTOCOL_ERROR;

// JDWP command packet (outgoing)
struct JdwpCommand {
	int id;
	char command_set;
	char command;
	char[] data;
}

// JDWP reply packet (incoming)
struct JdwpReply {
	int id;
	ushort error_code;
	char[] data;
}

// Buffered event packet (command packet from VM stashed by read_reply)
const usz MAX_BUFFERED_EVENTS = 32;

struct BufferedPacket {
	char[11] header;
	char[] data;       // heap-allocated
	bool valid;
}

// JDWP connection wrapping a TCP socket
struct JdwpConnection {
	TcpSocket socket;
	int next_id;
	bool connected;
	// Event buffer: events received while waiting for a reply
	BufferedPacket[MAX_BUFFERED_EVENTS] event_buf;
	usz event_buf_count;
}

// Connect to JDWP agent and perform handshake
fn JdwpConnection? connect(String host, int port) {
	log::info("[jdwp] Connecting to %s:%d...", host, port);

	TcpSocket sock = tcp::connect(host, (ushort)port)!;

	// Send handshake
	char[14] hs_buf;
	for (usz i = 0; i < JDWP_HANDSHAKE.len; i++) {
		hs_buf[i] = JDWP_HANDSHAKE[i];
	}
	usz written = sock.write(hs_buf[:14]) ?? 0;
	if (written != 14) {
		sock.close()!!;
		return JDWP_HANDSHAKE_FAILED~;
	}

	// Read handshake response
	char[14] response_buf;
	read_exact(&sock, response_buf[:14])!;

	String response = (String)response_buf[:14];
	if (response != JDWP_HANDSHAKE) {
		sock.close()!!;
		return JDWP_HANDSHAKE_FAILED~;
	}

	log::info("[jdwp] Handshake successful");

	JdwpConnection conn = {
		.socket = sock,
		.next_id = 1,
		.connected = true,
	};
	return conn;
}

// Send a JDWP command and return its ID
fn int? JdwpConnection.send_command(JdwpConnection* self, char command_set, char command, char[] data) {
	int id = self.next_id;
	self.next_id++;

	int length = (int)(HEADER_SIZE + data.len);

	// Build header (big-endian)
	char[11] header;
	put_int_be(header[..], 0, length);
	put_int_be(header[..], 4, id);
	header[8] = 0;  // flags = 0 for command
	header[9] = command_set;
	header[10] = command;

	usz written = self.socket.write(header[:11]) ?? 0;
	if (written != 11) return JDWP_WRITE_ERROR~;

	if (data.len > 0) {
		written = self.socket.write(data) ?? 0;
		if (written != data.len) return JDWP_WRITE_ERROR~;
	}

	log::debug("[jdwp] Sent command set=%d cmd=%d id=%d len=%d", (int)command_set, (int)command, id, length);
	return id;
}

// Read a JDWP reply packet
fn JdwpReply? JdwpConnection.read_reply(JdwpConnection* self) {
	char[11] header;
	read_exact(&self.socket, header[:11])!;

	int length = get_int_be(header[..], 0);
	int id = get_int_be(header[..], 4);
	char flags = header[8];

	if ((flags & REPLY_FLAG) == 0) {
		// This is a command packet (event), not a reply — buffer it
		int data_len = length - (int)HEADER_SIZE;
		char[] evt_data;
		if (data_len > 0) {
			evt_data = mem::alloc_array(char, (usz)data_len);
			read_exact(&self.socket, evt_data)!;
		}
		if (self.event_buf_count < MAX_BUFFERED_EVENTS) {
			BufferedPacket* bp = &self.event_buf[self.event_buf_count];
			bp.header = header;
			bp.data = evt_data;
			bp.valid = true;
			self.event_buf_count++;
			log::debug("[jdwp] Buffered event packet id=%d (buf count=%d)", id, (int)self.event_buf_count);
		} else {
			log::err("[jdwp] Event buffer full, dropping event id=%d", id);
			if (data_len > 0) mem::free(evt_data.ptr);
		}
		// Retry reading for actual reply
		return self.read_reply();
	}

	ushort error_code = get_ushort_be(header[..], 9);
	int data_len = length - (int)REPLY_HEADER_SIZE;

	char[] data;
	if (data_len > 0) {
		data = mem::talloc_array(char, (usz)data_len);
		read_exact(&self.socket, data)!;
	}

	log::debug("[jdwp] Reply id=%d error=%d data_len=%d", id, (int)error_code, data_len);

	JdwpReply result = {
		.id = id,
		.error_code = error_code,
		.data = data,
	};
	return result;
}

// Close JDWP connection
fn void JdwpConnection.close(JdwpConnection* self) {
	if (self.connected) {
		self.socket.close()!!;
		self.connected = false;
		// Free buffered events
		for (usz i = 0; i < self.event_buf_count; i++) {
			if (self.event_buf[i].valid && self.event_buf[i].data.len > 0) {
				mem::free(self.event_buf[i].data.ptr);
			}
			self.event_buf[i].valid = false;
		}
		self.event_buf_count = 0;
		log::info("[jdwp] Connection closed");
	}
}

// Check if there are buffered events
fn bool JdwpConnection.has_buffered_events(JdwpConnection* self) {
	return self.event_buf_count > 0;
}

// Pop the oldest buffered event. Returns header and data. Caller must free data.
fn bool JdwpConnection.pop_buffered_event(JdwpConnection* self, char[] header_out, char[]* data_out) {
	if (self.event_buf_count == 0) return false;

	// Copy from slot 0
	for (usz i = 0; i < 11; i++) header_out[i] = self.event_buf[0].header[i];
	*data_out = self.event_buf[0].data;

	// Shift remaining down
	for (usz i = 1; i < self.event_buf_count; i++) {
		self.event_buf[i - 1] = self.event_buf[i];
	}
	self.event_buf_count--;
	return true;
}

// ── Helpers ────────────────────────────────────────────────────────

// Read exact N bytes from socket
fn void? read_exact(TcpSocket* sock, char[] buf) {
	usz total = 0;
	while (total < buf.len) {
		sz n = sock.read(buf[total..]) ?? 0;
		if (n <= 0) return JDWP_READ_ERROR~;
		total += (usz)n;
	}
}

// Big-endian int encode
fn void put_int_be(char[] buf, usz offset, int val) {
	buf[offset]     = (char)((val >> 24) & 0xFF);
	buf[offset + 1] = (char)((val >> 16) & 0xFF);
	buf[offset + 2] = (char)((val >> 8) & 0xFF);
	buf[offset + 3] = (char)(val & 0xFF);
}

// Big-endian int decode
fn int get_int_be(char[] buf, usz offset) {
	return ((int)buf[offset] << 24)
		| ((int)buf[offset + 1] << 16)
		| ((int)buf[offset + 2] << 8)
		| (int)buf[offset + 3];
}

// Big-endian ushort decode
fn ushort get_ushort_be(char[] buf, usz offset) {
	return (ushort)(((int)buf[offset] << 8) | (int)buf[offset + 1]);
}

// Big-endian long encode
fn void put_long_be(char[] buf, usz offset, long val) {
	buf[offset]     = (char)((val >> 56) & 0xFF);
	buf[offset + 1] = (char)((val >> 48) & 0xFF);
	buf[offset + 2] = (char)((val >> 40) & 0xFF);
	buf[offset + 3] = (char)((val >> 32) & 0xFF);
	buf[offset + 4] = (char)((val >> 24) & 0xFF);
	buf[offset + 5] = (char)((val >> 16) & 0xFF);
	buf[offset + 6] = (char)((val >> 8) & 0xFF);
	buf[offset + 7] = (char)(val & 0xFF);
}

// Big-endian long decode
fn long get_long_be(char[] buf, usz offset) {
	return ((long)buf[offset] << 56)
		| ((long)buf[offset + 1] << 48)
		| ((long)buf[offset + 2] << 40)
		| ((long)buf[offset + 3] << 32)
		| ((long)buf[offset + 4] << 24)
		| ((long)buf[offset + 5] << 16)
		| ((long)buf[offset + 6] << 8)
		| (long)buf[offset + 7];
}
