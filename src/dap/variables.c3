module kls::dap::variables;

import std::collections::object;
import kls::log;
import kls::json_rpc;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;

// Handle scopes request — return scope list for a frame
fn Object* handle_scopes(IdManager* id_mgr, Object* args) {
	Object* body = object::new_obj(tmem);
	Object* scopes_arr = json_rpc::new_json_arr();

	int frame_id = (int)(args.get_int("frameId") ?? 0);

	FrameRef frame_ref;
	if (try ref = id_mgr.get_frame(frame_id)) {
		frame_ref = ref;
	} else {
		body.set("scopes", scopes_arr);
		return body;
	}

	// Create "Arguments" scope
	VarRef args_ref;
	args_ref.thread_id = frame_ref.thread_id;
	args_ref.frame_id = frame_ref.frame_id;
	args_ref.scope = ScopeKind.ARGUMENTS;
	args_ref.object_id = 0;
	args_ref.class_id = frame_ref.class_id;
	args_ref.method_id = frame_ref.method_id;
	args_ref.location = frame_ref.location;
	int args_var_ref = id_mgr.register_var_ref(args_ref);

	Object* args_scope = object::new_obj(tmem);
	args_scope.set("name", "Arguments");
	args_scope.set("variablesReference", args_var_ref);
	args_scope.set("expensive", false);
	scopes_arr.push(args_scope);

	// Create "Locals" scope
	VarRef locals_ref;
	locals_ref.thread_id = frame_ref.thread_id;
	locals_ref.frame_id = frame_ref.frame_id;
	locals_ref.scope = ScopeKind.LOCALS;
	locals_ref.object_id = 0;
	locals_ref.class_id = frame_ref.class_id;
	locals_ref.method_id = frame_ref.method_id;
	locals_ref.location = frame_ref.location;
	int locals_var_ref = id_mgr.register_var_ref(locals_ref);

	Object* locals_scope = object::new_obj(tmem);
	locals_scope.set("name", "Locals");
	locals_scope.set("variablesReference", locals_var_ref);
	locals_scope.set("expensive", false);
	scopes_arr.push(locals_scope);

	// Create "Static Fields" scope
	VarRef static_ref;
	static_ref.thread_id = frame_ref.thread_id;
	static_ref.frame_id = frame_ref.frame_id;
	static_ref.scope = ScopeKind.STATIC_FIELDS;
	static_ref.object_id = 0;
	static_ref.class_id = frame_ref.class_id;
	static_ref.method_id = 0;
	static_ref.location = 0;
	int static_var_ref = id_mgr.register_var_ref(static_ref);

	Object* static_scope = object::new_obj(tmem);
	static_scope.set("name", "Static Fields");
	static_scope.set("variablesReference", static_var_ref);
	static_scope.set("expensive", true);
	scopes_arr.push(static_scope);

	body.set("scopes", scopes_arr);
	return body;
}

// Handle variables request — return variables for a scope/object
fn Object* handle_variables(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	Object* body = object::new_obj(tmem);
	Object* vars_arr = json_rpc::new_json_arr();

	int var_ref = (int)(args.get_int("variablesReference") ?? 0);

	VarRef ref;
	if (try r = id_mgr.get_var_ref(var_ref)) {
		ref = r;
	} else {
		body.set("variables", vars_arr);
		return body;
	}

	if (ref.object_id != 0) {
		// Check if this is an array by looking up reference type signature
		bool is_array = false;
		if (try rt_reply = protocol::get_reference_type_signature(conn, ref.object_id)) {
			if (rt_reply.error_code == 0 && rt_reply.data.len >= 5) {
				int sig_len = transport::get_int_be(rt_reply.data, 0);
				if (sig_len > 0) {
					char first = rt_reply.data[4];
					if (first == '[') is_array = true;
				}
			}
		}
		// For arrays: check via ObjectReference.ReferenceType first
		if (!is_array) {
			char[8] rt_data;
			transport::put_long_be(rt_data[..], 0, ref.object_id);
			if (try rt_id = conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_REFERENCE_TYPE, rt_data[:8])) {
				if (try rt_reply = conn.read_reply()) {
					if (rt_reply.error_code == 0 && rt_reply.data.len >= 9) {
						char type_tag = rt_reply.data[0];
						if (type_tag == 3) is_array = true;  // JDWP typeTag 3 = ARRAY
						long type_id = transport::get_long_be(rt_reply.data, 1);
						if (!is_array) {
							// Check type signature
							if (try sig_reply = protocol::get_reference_type_signature(conn, type_id)) {
								if (sig_reply.error_code == 0 && sig_reply.data.len >= 5) {
									int sl = transport::get_int_be(sig_reply.data, 0);
									if (sl > 0 && sig_reply.data[4] == '[') is_array = true;
								}
							}
						}
					}
				}
			}
		}

		if (is_array) {
			get_array_elements(conn, id_mgr, ref.thread_id, ref.object_id, vars_arr);
		} else {
			// Expand object fields
			get_object_fields(conn, id_mgr, ref.thread_id, ref.object_id, vars_arr);
		}
	} else {
		// Scope-based variable fetch
		switch (ref.scope) {
			case ARGUMENTS:
				get_frame_args(conn, id_mgr, &ref, vars_arr);
			case LOCALS:
				get_frame_locals(conn, id_mgr, &ref, vars_arr);
			case STATIC_FIELDS:
				get_static_fields(conn, id_mgr, &ref, vars_arr);
			default:
				get_frame_locals(conn, id_mgr, &ref, vars_arr);
		}
	}

	body.set("variables", vars_arr);
	return body;
}

// Get function arguments from a stack frame
fn void get_frame_args(JdwpConnection* conn, IdManager* id_mgr, VarRef* ref, Object* vars_arr) {
	// "this" goes in arguments scope
	get_this_object(conn, id_mgr, ref, vars_arr);
	get_frame_vars_filtered(conn, id_mgr, ref, vars_arr, true);
}

// Get local variables from a stack frame (non-argument locals only)
fn void get_frame_locals(JdwpConnection* conn, IdManager* id_mgr, VarRef* ref, Object* vars_arr) {
	get_frame_vars_filtered(conn, id_mgr, ref, vars_arr, false);
}

// Get variables from a frame, filtered by args_only:
// args_only=true: return slots < arg_count (excluding "this")
// args_only=false: return slots >= arg_count
fn void get_frame_vars_filtered(JdwpConnection* conn, IdManager* id_mgr, VarRef* ref, Object* vars_arr, bool args_only) {
	// Get variable table for the method
	if (ref.class_id == 0 || ref.method_id == 0) return;

	bool use_generic = false;
	JdwpReply vt_reply;
	if (try r = protocol::get_variable_table(conn, ref.class_id, ref.method_id)) {
		vt_reply = r;
	} else {
		return;
	}
	// Fallback to VariableTableWithGeneric if plain VariableTable fails (error 101 = ABSENT_INFORMATION)
	if (vt_reply.error_code != 0 || vt_reply.data.len < 8) {
		log::debug("[dap] VariableTable error_code=%d data_len=%d, trying VariableTableWithGeneric",
			(int)vt_reply.error_code, (int)vt_reply.data.len);
		if (try r = protocol::get_variable_table_with_generic(conn, ref.class_id, ref.method_id)) {
			vt_reply = r;
			use_generic = true;
		} else {
			return;
		}
		if (vt_reply.error_code != 0 || vt_reply.data.len < 8) {
			log::debug("[dap] VariableTableWithGeneric also failed: error_code=%d", (int)vt_reply.error_code);
			return;
		}
	}

	// Variable table: argCnt(4) + slots(4) + entries[codeIndex(8) + name(4+N) + signature(4+N) + length(4) + slot(4)]
	int arg_count = transport::get_int_be(vt_reply.data, 0);
	int slot_count = transport::get_int_be(vt_reply.data, 4);
	usz pos = 8;

	// Collect visible variables — filter by code index scope
	long current_pc = ref.location;
	const int MAX_LOCALS = 64;
	int[MAX_LOCALS] slots;
	char[MAX_LOCALS] tags;
	String[MAX_LOCALS] names;
	String[MAX_LOCALS] sigs;
	int local_count = 0;

	for (int i = 0; i < slot_count && local_count < MAX_LOCALS; i++) {
		if (pos + 8 > vt_reply.data.len) break;
		long code_index = transport::get_long_be(vt_reply.data, pos); pos += 8;

		// Name
		if (pos + 4 > vt_reply.data.len) break;
		int name_len = transport::get_int_be(vt_reply.data, pos); pos += 4;
		String name = "";
		if (name_len > 0 && pos + (usz)name_len <= vt_reply.data.len) {
			name = (String)vt_reply.data[pos:name_len];
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

		// VariableTableWithGeneric has an extra genericSignature string per entry — skip it
		if (use_generic) {
			if (pos + 4 > vt_reply.data.len) break;
			int gen_sig_len = transport::get_int_be(vt_reply.data, pos); pos += 4;
			pos += (usz)gen_sig_len;
		}

		// Length + slot
		if (pos + 8 > vt_reply.data.len) break;
		int length = transport::get_int_be(vt_reply.data, pos); pos += 4;
		int slot = transport::get_int_be(vt_reply.data, pos); pos += 4;

		// Skip "this" (slot 0 for instance methods) — handled in Arguments scope
		if (name == "this") continue;

		// Filter by scope: variable is alive when codeIndex <= currentPC < codeIndex + length
		if (current_pc < code_index || current_pc >= code_index + (long)length) continue;

		// Split args vs locals: slots < arg_count are arguments
		if (args_only && slot >= arg_count) continue;
		if (!args_only && slot < arg_count) continue;

		// Map JVM signature to JDWP tag
		char tag = sig_to_tag(sig);

		slots[local_count] = slot;
		tags[local_count] = tag;
		names[local_count] = name;
		sigs[local_count] = sig;
		local_count++;
	}

	log::debug("[dap] Variable table: arg_count=%d slot_count=%d local_count=%d use_generic=%s pc=%d",
		arg_count, slot_count, local_count, use_generic ? "true" : "false", (int)current_pc);

	if (local_count == 0) return;

	// Try batch GetValues first; fall back to individual requests on error (e.g. INVALID_SLOT)
	bool batch_ok = false;
	if (try reply = protocol::get_frame_values(conn, ref.thread_id, ref.frame_id, slots[:local_count], tags[:local_count])) {
		if (reply.error_code == 0 && reply.data.len >= 4) {
			batch_ok = true;
			int val_count = transport::get_int_be(reply.data, 0);
			usz vpos = 4;

			for (int i = 0; i < val_count && i < local_count; i++) {
				if (vpos >= reply.data.len) break;
				char val_tag = reply.data[vpos]; vpos++;

				int val_size = tag_value_size(val_tag);
				if (vpos + (usz)val_size > reply.data.len) break;

				String val_str = format_tagged_value(conn, val_tag, reply.data, vpos, ref.thread_id);

				int child_ref = 0;
				if ((val_tag == 'L' || val_tag == '[' || val_tag == 's') && val_size == 8) {
					long obj_id = transport::get_long_be(reply.data, vpos);
					if (obj_id != 0) {
						VarRef child_vr;
						child_vr.thread_id = ref.thread_id;
						child_vr.frame_id = ref.frame_id;
						child_vr.scope = ScopeKind.THIS_OBJECT;
						child_vr.object_id = obj_id;
						child_vr.class_id = 0;
						child_vr.method_id = 0;
						child_ref = id_mgr.register_var_ref(child_vr);
					}
				}

				Object* var_obj = object::new_obj(tmem);
				var_obj.set("name", names[i]);
				var_obj.set("value", val_str);
				var_obj.set("type", sig_to_type_name(sigs[i]));
				var_obj.set("variablesReference", child_ref);
				vars_arr.push(var_obj);

				vpos += (usz)val_size;
			}
		} else {
			log::debug("[dap] Batch GetValues failed: error_code=%d, falling back to individual requests",
				(int)reply.error_code);
		}
	}

	// Fallback: request each slot individually
	if (!batch_ok) {
		for (int i = 0; i < local_count; i++) {
			int[1] single_slot = { slots[i] };
			char[1] single_tag = { tags[i] };
			if (try reply = protocol::get_frame_values(conn, ref.thread_id, ref.frame_id, single_slot[..], single_tag[..])) {
				if (reply.error_code != 0 || reply.data.len < 5) continue;

				int val_count = transport::get_int_be(reply.data, 0);
				if (val_count == 0) continue;
				usz vpos = 4;
				if (vpos >= reply.data.len) continue;
				char val_tag = reply.data[vpos]; vpos++;

				int val_size = tag_value_size(val_tag);
				if (vpos + (usz)val_size > reply.data.len) continue;

				String val_str = format_tagged_value(conn, val_tag, reply.data, vpos, ref.thread_id);

				int child_ref = 0;
				if ((val_tag == 'L' || val_tag == '[' || val_tag == 's') && val_size == 8) {
					long obj_id = transport::get_long_be(reply.data, vpos);
					if (obj_id != 0) {
						VarRef child_vr;
						child_vr.thread_id = ref.thread_id;
						child_vr.frame_id = ref.frame_id;
						child_vr.scope = ScopeKind.THIS_OBJECT;
						child_vr.object_id = obj_id;
						child_vr.class_id = 0;
						child_vr.method_id = 0;
						child_ref = id_mgr.register_var_ref(child_vr);
					}
				}

				Object* var_obj = object::new_obj(tmem);
				var_obj.set("name", names[i]);
				var_obj.set("value", val_str);
				var_obj.set("type", sig_to_type_name(sigs[i]));
				var_obj.set("variablesReference", child_ref);
				vars_arr.push(var_obj);
			}
		}
	}
}

// Get "this" object from a stack frame
fn void get_this_object(JdwpConnection* conn, IdManager* id_mgr, VarRef* ref, Object* vars_arr) {
	char[16] data;
	transport::put_long_be(data[..], 0, ref.thread_id);
	transport::put_long_be(data[..], 8, ref.frame_id);

	int cmd_id;
	if (try id = conn.send_command(protocol::CS_STACK_FRAME, protocol::SF_THIS_OBJECT, data[:16])) {
		cmd_id = id;
	} else {
		return;
	}

	JdwpReply reply;
	if (try r = conn.read_reply()) {
		reply = r;
	} else {
		return;
	}

	if (reply.error_code == 0 && reply.data.len >= 9) {
		char tag = reply.data[0];
		long object_id = transport::get_long_be(reply.data, 1);

		if (object_id != 0) {
			VarRef this_ref;
			this_ref.thread_id = ref.thread_id;
			this_ref.frame_id = ref.frame_id;
			this_ref.scope = ScopeKind.THIS_OBJECT;
			this_ref.object_id = object_id;
			this_ref.class_id = 0;
			this_ref.method_id = 0;
			int child_ref = id_mgr.register_var_ref(this_ref);

			Object* this_var = object::new_obj(tmem);
			this_var.set("name", "this");
			this_var.set("value", tag_to_type_name(tag));
			this_var.set("type", tag_to_type_name(tag));
			this_var.set("variablesReference", child_ref);
			vars_arr.push(this_var);
		}
	}
}

// Map JVM type signature first char to JDWP tag
fn char sig_to_tag(String sig) {
	if (sig.len == 0) return 'L';
	switch (sig[0]) {
		case 'B': return 'B';
		case 'C': return 'C';
		case 'D': return 'D';
		case 'F': return 'F';
		case 'I': return 'I';
		case 'J': return 'J';
		case 'S': return 'S';
		case 'Z': return 'Z';
		case '[': return '[';
		case 'L':
			if (sig == "Ljava/lang/String;") return 's';
			return 'L';
		default: return 'L';
	}
}

// Size of value data for a JDWP tag
fn int tag_value_size(char tag) {
	switch (tag) {
		case 'B': return 1;
		case 'Z': return 1;
		case 'C': return 2;
		case 'S': return 2;
		case 'F': return 4;
		case 'I': return 4;
		case 'D': return 8;
		case 'J': return 8;
		case 'L': return 8;
		case '[': return 8;
		case 's': return 8;
		case 'V': return 0;
		default: return 8;
	}
}

// Map JVM signature to human-readable type name
fn String sig_to_type_name(String sig) {
	if (sig.len == 0) return "Unknown";
	switch (sig[0]) {
		case 'B': return "Byte";
		case 'C': return "Char";
		case 'D': return "Double";
		case 'F': return "Float";
		case 'I': return "Int";
		case 'J': return "Long";
		case 'S': return "Short";
		case 'Z': return "Boolean";
		case 'V': return "Void";
		case '[': return "Array";
		case 'L':
			if (sig == "Ljava/lang/String;") return "String";
			// Extract class name: Lcom/example/Foo; -> Foo
			if (sig.len > 2) {
				String inner = sig[1:sig.len - 2]; // strip L and ;
				// Find last /
				usz last_slash = 0;
				for (usz i = 0; i < inner.len; i++) {
					if (inner[i] == '/') last_slash = i + 1;
				}
				return inner[last_slash..];
			}
			return "Object";
		default: return "Unknown";
	}
}

// Get static fields for a class
fn void get_static_fields(JdwpConnection* conn, IdManager* id_mgr, VarRef* ref, Object* vars_arr) {
	if (ref.class_id == 0) return;

	// Get fields for class
	char[8] type_data;
	transport::put_long_be(type_data[..], 0, ref.class_id);
	int cmd_id;
	if (try id = conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_FIELDS, type_data[:8])) {
		cmd_id = id;
	} else {
		return;
	}

	JdwpReply fields_reply;
	if (try r = conn.read_reply()) {
		fields_reply = r;
	} else {
		return;
	}
	if (fields_reply.error_code != 0 || fields_reply.data.len < 4) return;

	int field_count = transport::get_int_be(fields_reply.data, 0);
	usz pos = 4;

	// Collect static field IDs, names, sigs
	const int MAX_STATIC = 64;
	long[MAX_STATIC] field_ids;
	String[MAX_STATIC] field_names;
	String[MAX_STATIC] field_sigs;
	int static_count = 0;

	for (int i = 0; i < field_count && static_count < MAX_STATIC; i++) {
		if (pos + 8 > fields_reply.data.len) break;
		long field_id = transport::get_long_be(fields_reply.data, pos); pos += 8;

		if (pos + 4 > fields_reply.data.len) break;
		int name_len = transport::get_int_be(fields_reply.data, pos); pos += 4;
		String name = "";
		if (name_len > 0 && pos + (usz)name_len <= fields_reply.data.len) {
			name = (String)fields_reply.data[pos:name_len];
		}
		pos += (usz)name_len;

		if (pos + 4 > fields_reply.data.len) break;
		int sig_len = transport::get_int_be(fields_reply.data, pos); pos += 4;
		String sig = "";
		if (sig_len > 0 && pos + (usz)sig_len <= fields_reply.data.len) {
			sig = (String)fields_reply.data[pos:sig_len];
		}
		pos += (usz)sig_len;

		if (pos + 4 > fields_reply.data.len) break;
		int mod_bits = transport::get_int_be(fields_reply.data, pos); pos += 4;

		// Only static fields
		if (mod_bits & 0x0008 == 0) continue;

		field_ids[static_count] = field_id;
		field_names[static_count] = name;
		field_sigs[static_count] = sig;
		static_count++;
	}

	if (static_count == 0) return;

	// Get static field values via ReferenceType.GetValues
	// Data: refTypeID(8) + fieldCount(4) + fieldIDs(8*N)
	usz data_len = 8 + 4 + (usz)static_count * 8;
	char[] gv_data = mem::talloc_array(char, data_len);
	transport::put_long_be(gv_data, 0, ref.class_id);
	transport::put_int_be(gv_data, 8, static_count);
	for (int i = 0; i < static_count; i++) {
		transport::put_long_be(gv_data, 12 + (usz)i * 8, field_ids[i]);
	}

	if (try id = conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_GET_VALUES, gv_data[:data_len])) {
		cmd_id = id;
	} else {
		return;
	}

	JdwpReply val_reply;
	if (try r = conn.read_reply()) {
		val_reply = r;
	} else {
		return;
	}
	if (val_reply.error_code != 0 || val_reply.data.len < 4) return;

	int val_count = transport::get_int_be(val_reply.data, 0);
	usz vpos = 4;

	for (int i = 0; i < val_count && i < static_count; i++) {
		if (vpos >= val_reply.data.len) break;
		char val_tag = val_reply.data[vpos]; vpos++;

		int val_size = tag_value_size(val_tag);
		if (vpos + (usz)val_size > val_reply.data.len) break;

		String val_str = format_tagged_value(conn, val_tag, val_reply.data, vpos, ref.thread_id);

		int child_ref = 0;
		if ((val_tag == 'L' || val_tag == '[' || val_tag == 's') && val_size == 8) {
			long obj_id = transport::get_long_be(val_reply.data, vpos);
			if (obj_id != 0) {
				VarRef child_vr;
				child_vr.thread_id = ref.thread_id;
				child_vr.frame_id = 0;
				child_vr.scope = ScopeKind.THIS_OBJECT;
				child_vr.object_id = obj_id;
				child_vr.class_id = 0;
				child_vr.method_id = 0;
				child_ref = id_mgr.register_var_ref(child_vr);
			}
		}

		Object* var_obj = object::new_obj(tmem);
		var_obj.set("name", field_names[i]);
		var_obj.set("value", val_str);
		var_obj.set("type", sig_to_type_name(field_sigs[i]));
		var_obj.set("variablesReference", child_ref);
		vars_arr.push(var_obj);

		vpos += (usz)val_size;
	}
}

// Get array elements via JDWP
fn void get_array_elements(JdwpConnection* conn, IdManager* id_mgr, long thread_id, long array_id, Object* vars_arr) {
	// Get array length
	int arr_len = 0;
	if (try reply = protocol::get_array_length(conn, array_id)) {
		if (reply.error_code == 0 && reply.data.len >= 4) {
			arr_len = transport::get_int_be(reply.data, 0);
		}
	}
	if (arr_len == 0) return;

	// Add length pseudo-variable
	Object* len_var = object::new_obj(tmem);
	len_var.set("name", "length");
	DString len_str;
	len_str.tinit();
	len_str.appendf("%d", arr_len);
	len_var.set("value", len_str.str_view());
	len_var.set("type", "Int");
	len_var.set("variablesReference", 0);
	vars_arr.push(len_var);

	// Cap at 100 elements
	int fetch_count = arr_len > 100 ? 100 : arr_len;

	if (try reply = protocol::get_array_values(conn, array_id, 0, fetch_count)) {
		if (reply.error_code != 0 || reply.data.len < 5) return;

		char elem_tag = reply.data[0];
		int count = transport::get_int_be(reply.data, 1);
		usz pos = 5;

		// Object arrays: each element tagged (tag + 8-byte objectID)
		// Primitive arrays: elements untagged, raw values
		bool is_object_array = (elem_tag == 'L' || elem_tag == '[' || elem_tag == 's');

		for (int i = 0; i < count && i < fetch_count; i++) {
			DString idx_name;
			idx_name.tinit();
			idx_name.appendf("[%d]", i);

			char val_tag;
			if (is_object_array) {
				if (pos >= reply.data.len) break;
				val_tag = reply.data[pos]; pos++;
			} else {
				val_tag = elem_tag;
			}

			int val_size = tag_value_size(val_tag);
			if (pos + (usz)val_size > reply.data.len) break;

			String val_str = format_tagged_value(conn, val_tag, reply.data, pos, thread_id);

			int child_ref = 0;
			if ((val_tag == 'L' || val_tag == '[' || val_tag == 's') && val_size == 8) {
				long obj_id = transport::get_long_be(reply.data, pos);
				if (obj_id != 0) {
					VarRef child_vr;
					child_vr.thread_id = thread_id;
					child_vr.frame_id = 0;
					child_vr.scope = ScopeKind.THIS_OBJECT;
					child_vr.object_id = obj_id;
					child_vr.class_id = 0;
					child_vr.method_id = 0;
					child_ref = id_mgr.register_var_ref(child_vr);
				}
			}

			Object* var_obj = object::new_obj(tmem);
			var_obj.set("name", idx_name.str_view());
			var_obj.set("value", val_str);
			var_obj.set("type", tag_to_type_name(val_tag));
			var_obj.set("variablesReference", child_ref);
			vars_arr.push(var_obj);

			pos += (usz)val_size;
		}
	}
}

// Get object fields via JDWP
fn void get_object_fields(JdwpConnection* conn, IdManager* id_mgr, long thread_id, long object_id, Object* vars_arr) {
	// Get reference type of object
	char[8] data;
	transport::put_long_be(data[..], 0, object_id);

	int cmd_id;
	if (try id = conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_REFERENCE_TYPE, data[:8])) {
		cmd_id = id;
	} else {
		return;
	}

	JdwpReply rt_reply;
	if (try r = conn.read_reply()) {
		rt_reply = r;
	} else {
		return;
	}

	if (rt_reply.error_code != 0 || rt_reply.data.len < 9) return;
	// typeTag(1) + typeID(8)
	long type_id = transport::get_long_be(rt_reply.data, 1);

	// Get fields for this type
	char[8] type_data;
	transport::put_long_be(type_data[..], 0, type_id);
	if (try id = conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_FIELDS, type_data[:8])) {
		cmd_id = id;
	} else {
		return;
	}

	JdwpReply fields_reply;
	if (try r = conn.read_reply()) {
		fields_reply = r;
	} else {
		return;
	}

	if (fields_reply.error_code != 0 || fields_reply.data.len < 4) return;

	int field_count = transport::get_int_be(fields_reply.data, 0);
	usz pos = 4;

	// Collect field IDs and names for GetValues
	for (int i = 0; i < field_count && i < 50; i++) {  // limit to 50 fields
		if (pos + 8 > fields_reply.data.len) break;
		long field_id = transport::get_long_be(fields_reply.data, pos); pos += 8;

		// Read name
		if (pos + 4 > fields_reply.data.len) break;
		int name_len = transport::get_int_be(fields_reply.data, pos); pos += 4;
		String name = "";
		if (name_len > 0 && pos + (usz)name_len <= fields_reply.data.len) {
			name = (String)fields_reply.data[pos:name_len];
		}
		pos += (usz)name_len;

		// Skip signature
		if (pos + 4 > fields_reply.data.len) break;
		int sig_len = transport::get_int_be(fields_reply.data, pos); pos += 4;
		pos += (usz)sig_len;

		// Skip modBits
		if (pos + 4 > fields_reply.data.len) break;
		int mod_bits = transport::get_int_be(fields_reply.data, pos); pos += 4;

		// Skip static fields
		if (mod_bits & 0x0008 != 0) continue;

		// Get field value
		// ObjectReference.GetValues: objectID(8) + fieldCount(4) + fieldIDs(8*N)
		char[20] gv_data;
		transport::put_long_be(gv_data[..], 0, object_id);
		transport::put_int_be(gv_data[..], 8, 1);
		transport::put_long_be(gv_data[..], 12, field_id);

		if (try gv_id = conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_GET_VALUES, gv_data[:20])) {
			if (try gv_reply = conn.read_reply()) {
				if (gv_reply.error_code == 0 && gv_reply.data.len >= 5) {
					// values count(4) + tagged-value(tag(1) + value)
					int val_count = transport::get_int_be(gv_reply.data, 0);
					if (val_count > 0 && gv_reply.data.len > 4) {
						char tag = gv_reply.data[4];
						String val_str = format_tagged_value(conn, tag, gv_reply.data, 5, thread_id);

						int child_ref = 0;
						// If object type, register for expansion
						if (tag == 'L' || tag == '[') {
							if (gv_reply.data.len >= 13) {
								long child_id = transport::get_long_be(gv_reply.data, 5);
								if (child_id != 0) {
									VarRef child_vr;
									child_vr.thread_id = thread_id;
									child_vr.frame_id = 0;
									child_vr.scope = ScopeKind.THIS_OBJECT;
									child_vr.object_id = child_id;
									child_ref = id_mgr.register_var_ref(child_vr);
								}
							}
						}

						Object* var_obj = object::new_obj(tmem);
						var_obj.set("name", name);
						var_obj.set("value", val_str);
						var_obj.set("type", tag_to_type_name(tag));
						var_obj.set("variablesReference", child_ref);
						vars_arr.push(var_obj);
					}
				}
			}
		}
	}
}

// Invoke toString() on an object, return result or empty string on failure
fn String invoke_to_string(JdwpConnection* conn, long object_id, long thread_id) {
	if (thread_id == 0 || object_id == 0) return "";

	// Get reference type of object
	char[8] rt_data;
	transport::put_long_be(rt_data[..], 0, object_id);
	int cmd_id;
	if (try id = conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_REFERENCE_TYPE, rt_data[:8])) {
		cmd_id = id;
	} else {
		return "";
	}
	JdwpReply rt_reply;
	if (try r = conn.read_reply()) {
		rt_reply = r;
	} else {
		return "";
	}
	if (rt_reply.error_code != 0 || rt_reply.data.len < 9) return "";
	long type_id = transport::get_long_be(rt_reply.data, 1);

	// Find toString method (signature "()Ljava/lang/String;")
	JdwpReply methods_reply;
	if (try r = protocol::get_methods(conn, type_id)) {
		methods_reply = r;
	} else {
		return "";
	}
	if (methods_reply.error_code != 0 || methods_reply.data.len < 4) return "";

	int method_count = transport::get_int_be(methods_reply.data, 0);
	usz pos = 4;
	long to_string_id = 0;

	for (int i = 0; i < method_count; i++) {
		if (pos + 8 > methods_reply.data.len) break;
		long mid = transport::get_long_be(methods_reply.data, pos); pos += 8;

		if (pos + 4 > methods_reply.data.len) break;
		int name_len = transport::get_int_be(methods_reply.data, pos); pos += 4;
		String name = "";
		if (name_len > 0 && pos + (usz)name_len <= methods_reply.data.len) {
			name = (String)methods_reply.data[pos:name_len];
		}
		pos += (usz)name_len;

		if (pos + 4 > methods_reply.data.len) break;
		int sig_len = transport::get_int_be(methods_reply.data, pos); pos += 4;
		String sig = "";
		if (sig_len > 0 && pos + (usz)sig_len <= methods_reply.data.len) {
			sig = (String)methods_reply.data[pos:sig_len];
		}
		pos += (usz)sig_len;

		if (pos + 4 > methods_reply.data.len) break;
		pos += 4;  // modBits

		if (name == "toString" && sig == "()Ljava/lang/String;") {
			to_string_id = mid;
			break;
		}
	}

	if (to_string_id == 0) return "";

	// Invoke: no args, INVOKE_SINGLE_THREADED (0x01)
	char[] empty_tags = {};
	long[] empty_vals = {};
	if (try reply = protocol::invoke_object_method(conn, object_id, thread_id, type_id, to_string_id, empty_tags, empty_vals, 0x01)) {
		if (reply.error_code != 0 || reply.data.len < 1) return "";
		char ret_tag = reply.data[0];
		if (ret_tag == 's' && reply.data.len >= 9) {
			long str_id = transport::get_long_be(reply.data, 1);
			if (str_id != 0) {
				// Check for exception at offset 9 (tag + 8-byte objectID)
				if (reply.data.len >= 18) {
					char exc_tag = reply.data[9];
					long exc_id = transport::get_long_be(reply.data, 10);
					if (exc_id != 0) return "";  // toString() threw exception
				}
				if (try sr = protocol::get_string_value(conn, str_id)) {
					if (sr.error_code == 0 && sr.data.len >= 4) {
						int slen = transport::get_int_be(sr.data, 0);
						if (slen > 0 && 4 + (usz)slen <= sr.data.len) {
							return (String)sr.data[4:slen];
						}
					}
				}
			}
		}
	}
	return "";
}

// Format a JDWP tagged value as string
fn String format_tagged_value(JdwpConnection* conn, char tag, char[] data, usz offset, long thread_id) {
	DString out;
	out.tinit();

	switch (tag) {
		case 'B':  // byte
			if (offset < data.len) out.appendf("%d", (int)(ichar)data[offset]);
		case 'C':  // char
			if (offset + 2 <= data.len) {
				ushort ch = transport::get_ushort_be(data, offset);
				out.appendf("'%c'", (char)ch);
			}
		case 'D':  // double (8 bytes)
			if (offset + 8 <= data.len) {
				long bits = transport::get_long_be(data, offset);
				double val = *((double*)&bits);
				out.appendf("%g", val);
			}
		case 'F':  // float (4 bytes)
			if (offset + 4 <= data.len) {
				int bits = transport::get_int_be(data, offset);
				float val = *((float*)&bits);
				out.appendf("%g", val);
			}
		case 'I':  // int
			if (offset + 4 <= data.len) {
				int val = transport::get_int_be(data, offset);
				out.appendf("%d", val);
			}
		case 'J':  // long
			if (offset + 8 <= data.len) {
				long val = transport::get_long_be(data, offset);
				out.appendf("%d", val);
			}
		case 'S':  // short
			if (offset + 2 <= data.len) {
				ushort val = transport::get_ushort_be(data, offset);
				out.appendf("%d", (int)(short)val);
			}
		case 'Z':  // boolean
			if (offset < data.len) out.appendf("%s", data[offset] != 0 ? "true" : "false");
		case 's':  // string reference
			if (offset + 8 <= data.len) {
				long str_id = transport::get_long_be(data, offset);
				if (str_id != 0) {
					if (try reply = protocol::get_string_value(conn, str_id)) {
						if (reply.error_code == 0 && reply.data.len >= 4) {
							int len = transport::get_int_be(reply.data, 0);
							if (len > 0 && 4 + (usz)len <= reply.data.len) {
								out.appendf(`"%s"`, (String)reply.data[4:len]);
								return out.str_view();
							}
						}
					}
				}
				out.appendf("null");
			}
		case 'L':  // object reference
			if (offset + 8 <= data.len) {
				long obj_id = transport::get_long_be(data, offset);
				if (obj_id == 0) {
					out.appendf("null");
				} else {
					// Try toString() for meaningful display
					String ts = invoke_to_string(conn, obj_id, thread_id);
					if (ts.len > 0) {
						out.appendf("%s", ts);
					} else {
						out.appendf("Object@%d", obj_id);
					}
				}
			}
		case '[':  // array reference
			if (offset + 8 <= data.len) {
				long arr_id = transport::get_long_be(data, offset);
				if (arr_id == 0) {
					out.appendf("null");
				} else {
					// Show array with length
					if (try len_reply = protocol::get_array_length(conn, arr_id)) {
						if (len_reply.error_code == 0 && len_reply.data.len >= 4) {
							int arr_len = transport::get_int_be(len_reply.data, 0);
							out.appendf("Array[%d]", arr_len);
						} else {
							out.appendf("Array");
						}
					} else {
						out.appendf("Array");
					}
				}
			}
		case 'V':  // void
			out.appendf("void");
		default:
			out.appendf("<tag=%c>", tag);
	}

	return out.str_view();
}

// Map JDWP type tag to human-readable type name
fn String tag_to_type_name(char tag) {
	switch (tag) {
		case 'B': return "Byte";
		case 'C': return "Char";
		case 'D': return "Double";
		case 'F': return "Float";
		case 'I': return "Int";
		case 'J': return "Long";
		case 'S': return "Short";
		case 'Z': return "Boolean";
		case 's': return "String";
		case 'L': return "Object";
		case '[': return "Array";
		case 'V': return "Void";
		default:  return "Unknown";
	}
}
