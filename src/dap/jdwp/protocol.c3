module kls::dap::jdwp::protocol;

import kls::dap::jdwp::transport;
import kls::log;

// ── JDWP Command Sets ─────────────────────────────────────────────

const char CS_VIRTUAL_MACHINE  = 1;
const char CS_REFERENCE_TYPE   = 2;
const char CS_CLASS_TYPE       = 3;
const char CS_ARRAY_TYPE       = 4;
const char CS_INTERFACE_TYPE   = 5;
const char CS_METHOD           = 6;
const char CS_OBJECT_REFERENCE = 9;
const char CS_STRING_REFERENCE = 10;
const char CS_THREAD_REFERENCE = 11;
const char CS_THREAD_GROUP     = 12;
const char CS_ARRAY_REFERENCE  = 13;
const char CS_CLASS_LOADER     = 14;
const char CS_EVENT_REQUEST    = 15;
const char CS_STACK_FRAME      = 16;
const char CS_CLASS_OBJECT     = 17;
const char CS_EVENT            = 64;  // composite event (VM -> debugger)

// ── VirtualMachine commands ────────────────────────────────────────

const char VM_VERSION          = 1;
const char VM_CLASSES_BY_SIG   = 2;
const char VM_ALL_CLASSES      = 3;
const char VM_ALL_THREADS      = 4;
const char VM_TOP_LEVEL_GROUPS = 5;
const char VM_DISPOSE          = 6;
const char VM_ID_SIZES         = 7;
const char VM_SUSPEND          = 8;
const char VM_RESUME           = 9;
const char VM_EXIT             = 10;
const char VM_CAPABILITIES     = 12;
const char VM_CLASS_PATHS      = 13;
const char VM_DISPOSE_OBJECTS  = 14;
const char VM_CAPABILITIES_NEW = 17;

// ── ReferenceType commands ─────────────────────────────────────────

const char RT_SIGNATURE         = 1;
const char RT_CLASS_LOADER      = 2;
const char RT_FIELDS            = 4;
const char RT_METHODS           = 5;
const char RT_SOURCE_FILE       = 7;
const char RT_INTERFACES        = 10;
const char RT_CLASS_OBJECT      = 11;
const char RT_SIGNATURE_WITH_GENERIC = 13;
const char RT_METHODS_WITH_GENERIC   = 15;

// ── ClassType commands ─────────────────────────────────────────────

const char CT_SUPERCLASS       = 1;
const char CT_SET_VALUES       = 2;
const char CT_INVOKE_METHOD    = 3;
const char CT_NEW_INSTANCE     = 4;

// ── Method commands ────────────────────────────────────────────────

const char M_LINE_TABLE        = 1;
const char M_VARIABLE_TABLE    = 2;
const char M_BYTECODES         = 3;
const char M_VARIABLE_TABLE_WITH_GENERIC = 5;

// ── ObjectReference commands ───────────────────────────────────────

const char OR_REFERENCE_TYPE   = 1;
const char OR_GET_VALUES       = 2;
const char OR_SET_VALUES       = 3;
const char OR_INVOKE_METHOD    = 6;

// ── StringReference commands ───────────────────────────────────────

const char SR_VALUE            = 1;

// ── ThreadReference commands ───────────────────────────────────────

const char TR_NAME             = 1;
const char TR_SUSPEND          = 2;
const char TR_RESUME           = 3;
const char TR_STATUS           = 4;
const char TR_THREAD_GROUP     = 5;
const char TR_FRAMES           = 6;
const char TR_FRAME_COUNT      = 7;
const char TR_STOP             = 10;
const char TR_SUSPEND_COUNT    = 12;

// ── StackFrame commands ────────────────────────────────────────────

const char SF_GET_VALUES       = 1;
const char SF_SET_VALUES       = 2;
const char SF_THIS_OBJECT      = 3;

// ── EventRequest commands ──────────────────────────────────────────

const char ER_SET              = 1;
const char ER_CLEAR            = 2;
const char ER_CLEAR_ALL        = 3;

// ── Event Kinds ────────────────────────────────────────────────────

const char EK_SINGLE_STEP      = 1;
const char EK_BREAKPOINT       = 2;
const char EK_FRAME_POP        = 3;
const char EK_EXCEPTION        = 4;
const char EK_USER_DEFINED     = 5;
const char EK_THREAD_START     = 6;
const char EK_THREAD_DEATH     = 7;
const char EK_CLASS_PREPARE    = 8;
const char EK_CLASS_UNLOAD     = 9;
const char EK_CLASS_LOAD       = 10;
const char EK_VM_START         = 90;
const char EK_VM_DEATH         = 99;

// ── Step Depth ─────────────────────────────────────────────────────

const int STEP_INTO            = 0;
const int STEP_OVER            = 1;
const int STEP_OUT             = 2;

// ── Step Size ──────────────────────────────────────────────────────

const int STEP_MIN             = 0;
const int STEP_LINE            = 1;

// ── Suspend Policy ─────────────────────────────────────────────────

const char SP_NONE             = 0;
const char SP_EVENT_THREAD     = 1;
const char SP_ALL              = 2;

// ── Event Request Modifiers ────────────────────────────────────────

const char MOD_COUNT           = 1;
const char MOD_CONDITIONAL     = 2;
const char MOD_THREAD_ONLY     = 3;
const char MOD_CLASS_ONLY      = 4;
const char MOD_CLASS_MATCH     = 5;
const char MOD_CLASS_EXCLUDE   = 6;
const char MOD_LOCATION_ONLY   = 7;
const char MOD_EXCEPTION_ONLY  = 8;
const char MOD_FIELD_ONLY      = 9;
const char MOD_STEP            = 10;
const char MOD_INSTANCE_ONLY   = 11;

// ── JDWP ID sizes (set after VM_ID_SIZES call) ────────────────────

struct IdSizes {
	int field_id_size;
	int method_id_size;
	int object_id_size;
	int reference_type_id_size;
	int frame_id_size;
}

// Default: 8 bytes for all IDs (most JVMs)
fn IdSizes default_id_sizes() {
	return {
		.field_id_size = 8,
		.method_id_size = 8,
		.object_id_size = 8,
		.reference_type_id_size = 8,
		.frame_id_size = 8,
	};
}

// ── High-level JDWP commands ───────────────────────────────────────

// Query ID sizes from VM (must be first command after handshake)
fn IdSizes? query_id_sizes(JdwpConnection* conn) {
	int id = conn.send_command(CS_VIRTUAL_MACHINE, VM_ID_SIZES, {})!;
	JdwpReply reply = conn.read_reply()!;

	if (reply.error_code != 0) {
		log::err("[jdwp] IdSizes error: %d", (int)reply.error_code);
		return transport::JDWP_PROTOCOL_ERROR~;
	}

	if (reply.data.len < 20) {
		return transport::JDWP_PROTOCOL_ERROR~;
	}

	IdSizes sizes = {
		.field_id_size = transport::get_int_be(reply.data, 0),
		.method_id_size = transport::get_int_be(reply.data, 4),
		.object_id_size = transport::get_int_be(reply.data, 8),
		.reference_type_id_size = transport::get_int_be(reply.data, 12),
		.frame_id_size = transport::get_int_be(reply.data, 16),
	};
	return sizes;
}

// Get all threads
fn JdwpReply? get_all_threads(JdwpConnection* conn) {
	int id = conn.send_command(CS_VIRTUAL_MACHINE, VM_ALL_THREADS, {})!;
	return conn.read_reply();
}

// Get thread name
fn JdwpReply? get_thread_name(JdwpConnection* conn, long thread_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, thread_id);
	int id = conn.send_command(CS_THREAD_REFERENCE, TR_NAME, data[:8])!;
	return conn.read_reply();
}

// Resume VM
fn void? resume_vm(JdwpConnection* conn) {
	int id = conn.send_command(CS_VIRTUAL_MACHINE, VM_RESUME, {})!;
	JdwpReply reply = conn.read_reply()!;
	if (reply.error_code != 0) {
		log::err("[jdwp] Resume error: %d", (int)reply.error_code);
	}
}

// Suspend VM
fn void? suspend_vm(JdwpConnection* conn) {
	int id = conn.send_command(CS_VIRTUAL_MACHINE, VM_SUSPEND, {})!;
	JdwpReply reply = conn.read_reply()!;
	if (reply.error_code != 0) {
		log::err("[jdwp] Suspend error: %d", (int)reply.error_code);
	}
}

// Exit VM
fn void? exit_vm(JdwpConnection* conn, int exit_code) {
	char[4] data;
	transport::put_int_be(data[..], 0, exit_code);
	int id = conn.send_command(CS_VIRTUAL_MACHINE, VM_EXIT, data[:4])!;
	// May not get reply if VM exits immediately
}

// Get classes by signature (e.g., "Lcom/example/Main;")
fn JdwpReply? get_classes_by_signature(JdwpConnection* conn, String signature) {
	// Data: length-prefixed UTF-8 string
	int str_len = (int)signature.len;
	char[] data = mem::talloc_array(char, 4 + signature.len);
	transport::put_int_be(data[..], 0, str_len);
	for (usz i = 0; i < signature.len; i++) {
		data[4 + i] = signature[i];
	}
	int id = conn.send_command(CS_VIRTUAL_MACHINE, VM_CLASSES_BY_SIG, data)!;
	return conn.read_reply();
}

// Set breakpoint at location
fn JdwpReply? set_breakpoint(JdwpConnection* conn, char type_tag, long class_id, long method_id, long offset) {
	// EventRequest.Set: eventKind=BREAKPOINT, suspendPolicy=ALL, modifiers=[LocationOnly]
	char[] data = mem::talloc_array(char, 1 + 1 + 4 + 1 + 1 + 8 + 8 + 8);
	usz pos = 0;
	data[pos] = EK_BREAKPOINT; pos++;
	data[pos] = SP_ALL; pos++;
	transport::put_int_be(data[..], pos, 1); pos += 4;  // 1 modifier
	data[pos] = MOD_LOCATION_ONLY; pos++;
	data[pos] = type_tag; pos++;
	transport::put_long_be(data[..], pos, class_id); pos += 8;
	transport::put_long_be(data[..], pos, method_id); pos += 8;
	transport::put_long_be(data[..], pos, offset); pos += 8;

	int id = conn.send_command(CS_EVENT_REQUEST, ER_SET, data[:pos])!;
	return conn.read_reply();
}

// Set CLASS_PREPARE event request with class match pattern
// pattern: e.g. "abetal.ts.TsTest*" (uses JDWP ClassMatch modifier)
fn JdwpReply? set_class_prepare_request(JdwpConnection* conn, String class_pattern) {
	// EventRequest.Set: eventKind=CLASS_PREPARE, suspendPolicy=ALL, modifiers=[ClassMatch]
	usz data_len = 1 + 1 + 4 + 1 + 4 + class_pattern.len;
	char[] data = mem::talloc_array(char, data_len);
	usz pos = 0;
	data[pos] = EK_CLASS_PREPARE; pos++;
	data[pos] = SP_ALL; pos++;
	transport::put_int_be(data[..], pos, 1); pos += 4;  // 1 modifier
	data[pos] = MOD_CLASS_MATCH; pos++;
	transport::put_int_be(data[..], pos, (int)class_pattern.len); pos += 4;
	for (usz i = 0; i < class_pattern.len; i++) {
		data[pos] = class_pattern[i]; pos++;
	}

	int id = conn.send_command(CS_EVENT_REQUEST, ER_SET, data[:pos])!;
	return conn.read_reply();
}

// Set exception breakpoint (class_id=0 for all exceptions)
fn JdwpReply? set_exception_request(JdwpConnection* conn, long exception_class_id, bool catch_caught, bool catch_uncaught) {
	// EventRequest.Set: eventKind=EXCEPTION, suspendPolicy=ALL
	// ExceptionOnly modifier: classId=0 means all exceptions
	char[] data = mem::talloc_array(char, 1 + 1 + 4 + 1 + 8 + 1 + 1);
	usz pos = 0;
	data[pos] = EK_EXCEPTION; pos++;
	data[pos] = SP_ALL; pos++;
	transport::put_int_be(data[..], pos, 1); pos += 4;  // 1 modifier
	data[pos] = MOD_EXCEPTION_ONLY; pos++;
	transport::put_long_be(data[..], pos, exception_class_id); pos += 8;
	data[pos] = catch_caught ? 1 : 0; pos++;
	data[pos] = catch_uncaught ? 1 : 0; pos++;

	int id = conn.send_command(CS_EVENT_REQUEST, ER_SET, data[:pos])!;
	return conn.read_reply();
}

// Clear event request
fn void? clear_event_request(JdwpConnection* conn, char event_kind, int request_id) {
	char[5] data;
	data[0] = event_kind;
	transport::put_int_be(data[..], 1, request_id);
	int id = conn.send_command(CS_EVENT_REQUEST, ER_CLEAR, data[:5])!;
	JdwpReply reply = conn.read_reply()!;
	if (reply.error_code != 0) {
		log::err("[jdwp] Clear event request error: %d", (int)reply.error_code);
	}
}

// Get thread frames
fn JdwpReply? get_thread_frames(JdwpConnection* conn, long thread_id, int start_frame, int length) {
	char[20] data;
	transport::put_long_be(data[..], 0, thread_id);
	transport::put_int_be(data[..], 8, start_frame);
	transport::put_int_be(data[..], 12, length);
	int id = conn.send_command(CS_THREAD_REFERENCE, TR_FRAMES, data[:16])!;
	return conn.read_reply();
}

// Get method line table
fn JdwpReply? get_line_table(JdwpConnection* conn, long ref_type_id, long method_id) {
	char[16] data;
	transport::put_long_be(data[..], 0, ref_type_id);
	transport::put_long_be(data[..], 8, method_id);
	int id = conn.send_command(CS_METHOD, M_LINE_TABLE, data[:16])!;
	return conn.read_reply();
}

// Get method variable table
fn JdwpReply? get_variable_table(JdwpConnection* conn, long ref_type_id, long method_id) {
	char[16] data;
	transport::put_long_be(data[..], 0, ref_type_id);
	transport::put_long_be(data[..], 8, method_id);
	int id = conn.send_command(CS_METHOD, M_VARIABLE_TABLE, data[:16])!;
	return conn.read_reply();
}

// Get stack frame values
fn JdwpReply? get_frame_values(JdwpConnection* conn, long thread_id, long frame_id, int[] slots, char[] tags) {
	usz count = (usz)slots.len;
	char[] data = mem::talloc_array(char, 8 + 8 + 4 + count * 5);
	usz pos = 0;
	transport::put_long_be(data[..], pos, thread_id); pos += 8;
	transport::put_long_be(data[..], pos, frame_id); pos += 8;
	transport::put_int_be(data[..], pos, (int)count); pos += 4;
	for (usz i = 0; i < count; i++) {
		transport::put_int_be(data[..], pos, slots[i]); pos += 4;
		data[pos] = tags[i]; pos++;
	}
	int id = conn.send_command(CS_STACK_FRAME, SF_GET_VALUES, data[:pos])!;
	return conn.read_reply();
}

// Get reference type signature
fn JdwpReply? get_reference_type_signature(JdwpConnection* conn, long ref_type_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, ref_type_id);
	int id = conn.send_command(CS_REFERENCE_TYPE, RT_SIGNATURE, data[:8])!;
	return conn.read_reply();
}

// Get reference type source file
fn JdwpReply? get_source_file(JdwpConnection* conn, long ref_type_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, ref_type_id);
	int id = conn.send_command(CS_REFERENCE_TYPE, RT_SOURCE_FILE, data[:8])!;
	return conn.read_reply();
}

// Get reference type methods
fn JdwpReply? get_methods(JdwpConnection* conn, long ref_type_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, ref_type_id);
	int id = conn.send_command(CS_REFERENCE_TYPE, RT_METHODS, data[:8])!;
	return conn.read_reply();
}

// Resume a single thread
fn void? resume_thread(JdwpConnection* conn, long thread_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, thread_id);
	int id = conn.send_command(CS_THREAD_REFERENCE, TR_RESUME, data[:8])!;
	JdwpReply reply = conn.read_reply()!;
	if (reply.error_code != 0) {
		log::err("[jdwp] Resume thread error: %d", (int)reply.error_code);
	}
}

// Suspend a single thread
fn void? suspend_thread(JdwpConnection* conn, long thread_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, thread_id);
	int id = conn.send_command(CS_THREAD_REFERENCE, TR_SUSPEND, data[:8])!;
	JdwpReply reply = conn.read_reply()!;
	if (reply.error_code != 0) {
		log::err("[jdwp] Suspend thread error: %d", (int)reply.error_code);
	}
}

// Set single-step event request
fn JdwpReply? set_single_step(JdwpConnection* conn, long thread_id, int step_size, int step_depth) {
	// EventRequest.Set: eventKind=SINGLE_STEP, suspendPolicy=ALL, modifiers=[Step]
	char[1 + 1 + 4 + 1 + 8 + 4 + 4] data;
	usz pos = 0;
	data[pos] = EK_SINGLE_STEP; pos++;
	data[pos] = SP_ALL; pos++;
	transport::put_int_be(data[..], pos, 1); pos += 4;  // 1 modifier
	data[pos] = MOD_STEP; pos++;
	transport::put_long_be(data[..], pos, thread_id); pos += 8;
	transport::put_int_be(data[..], pos, step_size); pos += 4;
	transport::put_int_be(data[..], pos, step_depth); pos += 4;

	int id = conn.send_command(CS_EVENT_REQUEST, ER_SET, data[:pos])!;
	return conn.read_reply();
}

// Get string value from StringReference
fn JdwpReply? get_string_value(JdwpConnection* conn, long string_id) {
	char[8] data;
	transport::put_long_be(data[..], 0, string_id);
	int id = conn.send_command(CS_STRING_REFERENCE, SR_VALUE, data[:8])!;
	return conn.read_reply();
}
