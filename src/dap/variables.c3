module kls::dap::variables;

import std::collections::object;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;

// Handle scopes request — return scope list for a frame
fn Object* handle_scopes(IdManager* id_mgr, Object* args) {
	Object* body = object::new_obj(tmem);
	Object* scopes_arr = object::new_obj(tmem);  // JSON array

	int frame_id = (int)(args.get_int("frameId") ?? 0);

	FrameRef frame_ref;
	if (try ref = id_mgr.get_frame(frame_id)) {
		frame_ref = ref;
	} else {
		body.set("scopes", scopes_arr);
		return body;
	}

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

	body.set("scopes", scopes_arr);
	return body;
}

// Handle variables request — return variables for a scope/object
fn Object* handle_variables(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	Object* body = object::new_obj(tmem);
	Object* vars_arr = object::new_obj(tmem);  // JSON array

	int var_ref = (int)(args.get_int("variablesReference") ?? 0);

	VarRef ref;
	if (try r = id_mgr.get_var_ref(var_ref)) {
		ref = r;
	} else {
		body.set("variables", vars_arr);
		return body;
	}

	if (ref.object_id != 0) {
		// Expand object fields
		get_object_fields(conn, id_mgr, ref.thread_id, ref.object_id, vars_arr);
	} else {
		// Get locals from frame
		get_frame_locals(conn, id_mgr, &ref, vars_arr);
	}

	body.set("variables", vars_arr);
	return body;
}

// Get local variables from a stack frame
fn void get_frame_locals(JdwpConnection* conn, IdManager* id_mgr, VarRef* ref, Object* vars_arr) {
	// First get "this" if available
	get_this_object(conn, id_mgr, ref, vars_arr);

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

		// Skip "this" (slot 0 for instance methods) — already handled above
		if (name == "this") continue;

		// Filter by scope: variable is alive when codeIndex <= currentPC < codeIndex + length
		if (current_pc < code_index || current_pc >= code_index + (long)length) continue;

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

				String val_str = format_tagged_value(conn, val_tag, reply.data, vpos);

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

				String val_str = format_tagged_value(conn, val_tag, reply.data, vpos);

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
						String val_str = format_tagged_value(conn, tag, gv_reply.data, 5);

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

// Format a JDWP tagged value as string
fn String format_tagged_value(JdwpConnection* conn, char tag, char[] data, usz offset) {
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
					out.appendf("Object@%d", obj_id);
				}
			}
		case '[':  // array reference
			if (offset + 8 <= data.len) {
				long arr_id = transport::get_long_be(data, offset);
				if (arr_id == 0) {
					out.appendf("null");
				} else {
					out.appendf("Array@%d", arr_id);
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
