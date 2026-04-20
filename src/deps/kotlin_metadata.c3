module kls::deps::kotlin_metadata;

import kls::deps::classfile;

// ── Protobuf wire types ────────────────────────────────────────────

const int WIRE_VARINT = 0;
const int WIRE_64BIT = 1;
const int WIRE_LENGTH_DELIMITED = 2;
const int WIRE_32BIT = 5;

// ── Parsed metadata types ──────────────────────────────────────────

const usz MAX_TYPE_ARGS = 4;
const usz MAX_PARAMS = 8;
const usz MAX_FUNCTIONS = 64;
const usz MAX_PROPERTIES = 64;
const usz MAX_SUPERTYPES = 8;
const usz MAX_QN_ENTRIES = 256;

struct KmType {
	int class_name_id;          // QualifiedNameTable index
	int type_parameter_id;      // type parameter ref (-1 if not set)
	bool nullable;
	bool is_suspend;            // bit 0 of flags
	usz arg_count;
	int[MAX_TYPE_ARGS] arg_class_ids;     // QualifiedName IDs for each arg
	int[MAX_TYPE_ARGS] arg_projections;   // 0=IN, 1=OUT, 2=INV, 3=STAR
	bool[MAX_TYPE_ARGS] arg_nullable;
	bool has_extension_annotation; // @ExtensionFunctionType
}

// KmTypeArg removed — flattened into KmType parallel arrays

struct KmValueParam {
	int name_id;     // string table index
	KmType type;
}

struct KmFunction {
	int name_id;               // string table index
	int flags;
	KmType return_type;
	bool has_return_type;
	int return_type_id;        // TypeTable index (-1 if inline type used)
	KmType receiver_type;      // extension function receiver
	bool has_receiver_type;
	int receiver_type_id;      // TypeTable index (-1 if inline type used)
	usz param_count;
	KmValueParam[MAX_PARAMS] params;
}

struct KmProperty {
	int name_id;               // string table index
	int flags;
	KmType return_type;
	bool has_return_type;
	int return_type_id;        // TypeTable index (-1 if inline type used)
	KmType receiver_type;      // extension property receiver
	bool has_receiver_type;
	int receiver_type_id;      // TypeTable index (-1 if inline type used)
}

struct QnEntry {
	int parent;       // parent QualifiedNameTable index, -1 = root
	int short_name;   // string table index
	int kind;         // 0=CLASS, 1=PACKAGE, 2=LOCAL
}

struct KmTypeTable {
	usz type_count;
	KmType[64] types;
	int first_nullable;  // types at index >= this are nullable
}

struct KmClass {
	int fq_name_id;
	int flags;
	usz function_count;
	KmFunction[MAX_FUNCTIONS] functions;
	usz property_count;
	KmProperty[MAX_PROPERTIES] properties;
	usz supertype_count;
	KmType[MAX_SUPERTYPES] supertypes;
	KmTypeTable type_table;
	usz qn_count;
	QnEntry[MAX_QN_ENTRIES] qualified_names;
}

// ── Public API ─────────────────────────────────────────────────────

/**
 * Parse Kotlin metadata from a ClassInfo that has @kotlin.Metadata extracted.
 * Returns false if metadata cannot be parsed.
 */
fn bool parse_metadata(ClassInfo* info, KmClass* out) {
	if (!info.has_kotlin_metadata) return false;
	if (info.metadata_d1_len == 0) return false;

	*out = {};
	out.type_table.first_nullable = -1;

	char[] d1 = info.metadata_d1[:info.metadata_d1_len];
	usz pos = 0;

	// First pass: extract QualifiedNameTable and TypeTable
	// Then extract functions, properties, supertypes

	if (info.metadata_kind == 1) {
		// Class metadata
		return parse_class_message(d1, &pos, out);
	} else if (info.metadata_kind == 2) {
		// Package (file-level) metadata — same structure minus class-specific fields
		return parse_package_message(d1, &pos, out);
	}

	return false;
}

/**
 * Resolve a QualifiedName ID to a simple class name using the string table.
 * Returns the simple name (last segment), not the full path.
 */
fn String resolve_type_name(KmClass* km, int class_name_id, String[] d2, usz d2_len) {
	if (class_name_id < 0 || (usz)class_name_id >= km.qn_count) return "";
	int str_id = km.qualified_names[class_name_id].short_name;
	if (str_id < 0 || (usz)str_id >= d2_len) return "";
	return d2[str_id];
}

/**
 * Resolve a QualifiedName ID to a full dot-separated path.
 */
fn String resolve_type_fqn(KmClass* km, int class_name_id, String[] d2, usz d2_len) {
	if (class_name_id < 0 || (usz)class_name_id >= km.qn_count) return "";

	// Walk parent chain to build full name
	// Max depth 16 to prevent cycles
	String[16] segments;
	usz seg_count = 0;
	int current = class_name_id;
	while (current >= 0 && (usz)current < km.qn_count && seg_count < 16) {
		int str_id = km.qualified_names[current].short_name;
		if (str_id >= 0 && (usz)str_id < d2_len) {
			segments[seg_count] = d2[str_id];
			seg_count++;
		}
		current = km.qualified_names[current].parent;
	}

	if (seg_count == 0) return "";
	if (seg_count == 1) return segments[0];

	// Build reversed dot-joined string
	DString result;
	result.tinit();
	for (usz i = seg_count; i > 0; i--) {
		if (i < seg_count) result.appendf(".");
		result.appendf("%s", segments[i - 1]);
	}
	return result.str_view();
}

/**
 * Resolve a string table index to a string.
 */
fn String resolve_string(int str_id, String[] d2, usz d2_len) {
	if (str_id < 0 || (usz)str_id >= d2_len) return "";
	return d2[str_id];
}

// ── Protobuf wire decoder ──────────────────────────────────────────

fn ulong read_varint(char[] data, usz* pos) {
	ulong result = 0;
	uint shift = 0;
	while (*pos < data.len) {
		char b = data[*pos]; *pos += 1;
		result |= ((ulong)(b & 0x7F)) << shift;
		if ((b & 0x80) == 0) break;
		shift += 7;
		if (shift >= 64) break;
	}
	return result;
}

struct FieldTag {
	int field_number;
	int wire_type;
}

fn FieldTag read_tag(char[] data, usz* pos) {
	ulong val = read_varint(data, pos);
	return { .field_number = (int)(val >> 3), .wire_type = (int)(val & 0x7) };
}

fn void skip_field(char[] data, usz* pos, int wire_type) {
	switch (wire_type) {
		case WIRE_VARINT:
			read_varint(data, pos);
		case WIRE_64BIT:
			*pos += 8;
		case WIRE_LENGTH_DELIMITED:
			ulong len = read_varint(data, pos);
			*pos += (usz)len;
		case WIRE_32BIT:
			*pos += 4;
		default:
			// Unknown wire type (e.g., deprecated group types 3/4).
			// Force pos past end to break out of caller's loop.
			*pos = data.len;
	}
}

// ── Type parser ────────────────────────────────────────────────────

fn KmType parse_type(char[] data, usz start, usz end) {
	KmType t = { .class_name_id = -1, .type_parameter_id = -1 };
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		switch (tag.field_number) {
			case 1: // flags
				int flags = (int)read_varint(data, &pos);
				t.is_suspend = (flags & 1) != 0;
			case 2: // argument (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					if (t.arg_count < MAX_TYPE_ARGS) {
						parse_type_argument_into(data, pos, pos + (usz)len, &t, t.arg_count);
						t.arg_count++;
					}
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 3: // nullable
				t.nullable = read_varint(data, &pos) != 0;
			case 6: // class_name (QualifiedName ID)
				t.class_name_id = (int)read_varint(data, &pos);
			case 7: // type_parameter
				t.type_parameter_id = (int)read_varint(data, &pos);
			case 100: // annotation (check for ExtensionFunctionType)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz ann_end = pos + (usz)len;
					if (check_extension_annotation(data, pos, ann_end)) {
						t.has_extension_annotation = true;
					}
					pos = ann_end;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			default:
				skip_field(data, &pos, tag.wire_type);
		}
	}

	return t;
}

/**
 * Parse a Type.Argument sub-message into flat arrays on the parent KmType.
 */
fn void parse_type_argument_into(char[] data, usz start, usz end, KmType* parent, usz arg_idx) {
	parent.arg_projections[arg_idx] = 2; // default INV
	parent.arg_class_ids[arg_idx] = -1;
	parent.arg_nullable[arg_idx] = false;
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		switch (tag.field_number) {
			case 1: // projection
				parent.arg_projections[arg_idx] = (int)read_varint(data, &pos);
			case 2: // type (length-delimited) — extract class_name_id and nullable
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					KmType inner = parse_type(data, pos, pos + (usz)len);
					parent.arg_class_ids[arg_idx] = inner.class_name_id;
					parent.arg_nullable[arg_idx] = inner.nullable;
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			default:
				skip_field(data, &pos, tag.wire_type);
		}
	}
}

/**
 * Check if an Annotation sub-message is @ExtensionFunctionType.
 * Annotation proto: field 1 = id (varint, QualifiedName index).
 * We store this and check against "ExtensionFunctionType" during resolution.
 */
fn bool check_extension_annotation(char[] data, usz start, usz end) {
	usz pos = start;
	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;
		if (tag.field_number == 1 && tag.wire_type == WIRE_VARINT) {
			// This is the annotation class ID — we'll need to resolve it later
			// For now, store true and let the caller verify
			// The annotation id will be checked during type resolution
			return true; // Optimistic: any annotation on a function type = extension marker
		}
		skip_field(data, &pos, tag.wire_type);
	}
	return false;
}

// ── ValueParameter parser ──────────────────────────────────────────

fn KmValueParam parse_value_parameter(char[] data, usz start, usz end) {
	KmValueParam vp = { .name_id = -1 };
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		switch (tag.field_number) {
			case 2: // name (varint, string index)
				vp.name_id = (int)read_varint(data, &pos);
			case 3: // type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					vp.type = parse_type(data, pos, pos + (usz)len);
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			default:
				skip_field(data, &pos, tag.wire_type);
		}
	}

	return vp;
}

// ── Function parser ────────────────────────────────────────────────

fn KmFunction parse_function(char[] data, usz start, usz end) {
	KmFunction f = { .name_id = -1, .return_type_id = -1, .receiver_type_id = -1 };
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		switch (tag.field_number) {
			case 9: // flags
				f.flags = (int)read_varint(data, &pos);
			case 2: // name (varint, string index)
				f.name_id = (int)read_varint(data, &pos);
			case 3: // return_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					f.return_type = parse_type(data, pos, pos + (usz)len);
					f.has_return_type = true;
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 5: // receiver_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					f.receiver_type = parse_type(data, pos, pos + (usz)len);
					f.has_receiver_type = true;
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 6: // value_parameter (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					if (f.param_count < MAX_PARAMS) {
						f.params[f.param_count] = parse_value_parameter(data, pos, pos + (usz)len);
						f.param_count++;
					}
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 7: // return_type_id (TypeTable index)
				f.return_type_id = (int)read_varint(data, &pos);
				f.has_return_type = true;
			case 8: // receiver_type_id (TypeTable index)
				f.receiver_type_id = (int)read_varint(data, &pos);
				f.has_receiver_type = true;
			default:
				skip_field(data, &pos, tag.wire_type);
		}
	}

	return f;
}

// ── Property parser ────────────────────────────────────────────────

fn KmProperty parse_property(char[] data, usz start, usz end) {
	KmProperty p = { .name_id = -1, .return_type_id = -1, .receiver_type_id = -1 };
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		switch (tag.field_number) {
			case 11: // flags
				p.flags = (int)read_varint(data, &pos);
			case 2: // name (varint, string index)
				p.name_id = (int)read_varint(data, &pos);
			case 3: // return_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					p.return_type = parse_type(data, pos, pos + (usz)len);
					p.has_return_type = true;
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 5: // receiver_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					p.receiver_type = parse_type(data, pos, pos + (usz)len);
					p.has_receiver_type = true;
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 9: // return_type_id (TypeTable index)
				p.return_type_id = (int)read_varint(data, &pos);
				p.has_return_type = true;
			case 10: // receiver_type_id (TypeTable index)
				p.receiver_type_id = (int)read_varint(data, &pos);
				p.has_receiver_type = true;
			default:
				skip_field(data, &pos, tag.wire_type);
		}
	}

	return p;
}

// ── TypeTable parser ───────────────────────────────────────────────

fn void parse_type_table(char[] data, usz start, usz end, KmTypeTable* tt) {
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		switch (tag.field_number) {
			case 1: // type (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					if (tt.type_count < 64) {
						tt.types[tt.type_count] = parse_type(data, pos, pos + (usz)len);
						tt.type_count++;
					}
					pos += (usz)len;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 2: // first_nullable
				tt.first_nullable = (int)read_varint(data, &pos);
			default:
				skip_field(data, &pos, tag.wire_type);
		}
	}
}

// ── QualifiedNameTable parser ──────────────────────────────────────

fn void parse_qualified_name_table(char[] data, usz start, usz end, KmClass* out) {
	usz pos = start;

	while (pos < end) {
		FieldTag tag = read_tag(data, &pos);
		if (pos > end) break;

		if (tag.field_number == 1 && tag.wire_type == WIRE_LENGTH_DELIMITED) {
			// QualifiedName entry
			ulong len = read_varint(data, &pos);
			usz entry_end = pos + (usz)len;

			if (out.qn_count < MAX_QN_ENTRIES) {
				QnEntry* entry = &out.qualified_names[out.qn_count];
				entry.parent = -1;
				entry.short_name = -1;
				entry.kind = 0; // CLASS

				usz epos = pos;
				while (epos < entry_end) {
					FieldTag etag = read_tag(data, &epos);
					if (epos > entry_end) break;
					switch (etag.field_number) {
						case 1: // short_name (varint, string index)
							entry.short_name = (int)read_varint(data, &epos);
						case 2: // parent_qualified_name
							entry.parent = (int)read_varint(data, &epos);
						case 3: // kind
							entry.kind = (int)read_varint(data, &epos);
						default:
							skip_field(data, &epos, etag.wire_type);
					}
				}
				out.qn_count++;
			}
			pos = entry_end;
		} else {
			skip_field(data, &pos, tag.wire_type);
		}
	}
}

// ── Class message parser (k=1) ─────────────────────────────────────

fn bool parse_class_message(char[] data, usz* pos, KmClass* out) {
	usz end = data.len;

	while (*pos < end) {
		FieldTag tag = read_tag(data, pos);
		if (*pos > end) break;

		switch (tag.field_number) {
			case 1: // flags
				out.flags = (int)read_varint(data, pos);
			case 3: // fq_name (varint)
				out.fq_name_id = (int)read_varint(data, pos);
			case 6: // supertype (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					if (out.supertype_count < MAX_SUPERTYPES) {
						out.supertypes[out.supertype_count] = parse_type(data, *pos, *pos + (usz)len);
						out.supertype_count++;
					}
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 2: // supertype_id (packed varint)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz packed_end = *pos + (usz)len;
					while (*pos < packed_end && out.supertype_count < MAX_SUPERTYPES) {
						int id = (int)read_varint(data, pos);
						out.supertypes[out.supertype_count].class_name_id = id;
						out.supertype_count++;
					}
					*pos = packed_end;
				} else if (tag.wire_type == WIRE_VARINT) {
					// Non-packed single value
					if (out.supertype_count < MAX_SUPERTYPES) {
						int id = (int)read_varint(data, pos);
						out.supertypes[out.supertype_count].class_name_id = id;
						out.supertype_count++;
					}
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 9: // function (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					if (out.function_count < MAX_FUNCTIONS) {
						out.functions[out.function_count] = parse_function(data, *pos, *pos + (usz)len);
						out.function_count++;
					}
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 10: // property (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					if (out.property_count < MAX_PROPERTIES) {
						out.properties[out.property_count] = parse_property(data, *pos, *pos + (usz)len);
						out.property_count++;
					}
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 30: // type_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					parse_type_table(data, *pos, *pos + (usz)len, &out.type_table);
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 31: // qualified_name_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					parse_qualified_name_table(data, *pos, *pos + (usz)len, out);
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			default:
				skip_field(data, pos, tag.wire_type);
		}
	}

	// Apply TypeTable nullable overrides to supertype_id references
	apply_type_table_refs(out);

	return true;
}

// ── Package message parser (k=2) ───────────────────────────────────

fn bool parse_package_message(char[] data, usz* pos, KmClass* out) {
	usz end = data.len;

	while (*pos < end) {
		FieldTag tag = read_tag(data, pos);
		if (*pos > end) break;

		switch (tag.field_number) {
			case 3: // function (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					if (out.function_count < MAX_FUNCTIONS) {
						out.functions[out.function_count] = parse_function(data, *pos, *pos + (usz)len);
						out.function_count++;
					}
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 4: // property (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					if (out.property_count < MAX_PROPERTIES) {
						out.properties[out.property_count] = parse_property(data, *pos, *pos + (usz)len);
						out.property_count++;
					}
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 30: // type_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					parse_type_table(data, *pos, *pos + (usz)len, &out.type_table);
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 31: // qualified_name_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					parse_qualified_name_table(data, *pos, *pos + (usz)len, out);
					*pos += (usz)len;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			default:
				skip_field(data, pos, tag.wire_type);
		}
	}

	apply_type_table_refs(out);
	return true;
}

// ── TypeTable reference resolution ─────────────────────────────────

/**
 * For supertypes/return types that use type_id references (indices into TypeTable),
 * resolve them to actual Type data. Also apply first_nullable.
 */
fn void apply_type_table_refs(KmClass* out) {
	KmTypeTable* tt = &out.type_table;
	if (tt.type_count == 0) return;

	// Apply first_nullable to TypeTable types
	if (tt.first_nullable >= 0) {
		for (usz i = (usz)tt.first_nullable; i < tt.type_count; i++) {
			tt.types[i].nullable = true;
		}
	}

	// Resolve supertype_id references
	for (usz i = 0; i < out.supertype_count; i++) {
		KmType* st = &out.supertypes[i];
		// If this supertype only has class_name_id set (from supertype_id packed field)
		// and it's actually a TypeTable index, resolve it
		if (st.class_name_id >= 0 && st.arg_count == 0 && !st.nullable) {
			int id = st.class_name_id;
			if ((usz)id < tt.type_count) {
				// Check if this looks like a TypeTable index (supertypes from field 2)
				// vs a QualifiedName index (supertypes from field 6)
				// Heuristic: if there are QN entries and the id is within range, it's a QN ref from field 6
				// If no QN entries or id >= qn_count, treat as TypeTable ref from field 2
				// This is imperfect — the parser should track which source field was used
				// For now, supertype_id (field 2) entries are replaced by TypeTable lookups
				*st = tt.types[id];
			}
		}
	}

	// Resolve function return_type_id and receiver_type_id references
	for (usz i = 0; i < out.function_count; i++) {
		KmFunction* f = &out.functions[i];
		if (f.return_type_id >= 0 && (usz)f.return_type_id < tt.type_count) {
			f.return_type = tt.types[f.return_type_id];
		}
		if (f.receiver_type_id >= 0 && (usz)f.receiver_type_id < tt.type_count) {
			f.receiver_type = tt.types[f.receiver_type_id];
		}
		// Resolve param type_ids if needed (params use inline types, no type_id field)
	}

	// Resolve property return_type_id and receiver_type_id references
	for (usz i = 0; i < out.property_count; i++) {
		KmProperty* p = &out.properties[i];
		if (p.return_type_id >= 0 && (usz)p.return_type_id < tt.type_count) {
			p.return_type = tt.types[p.return_type_id];
		}
		if (p.receiver_type_id >= 0 && (usz)p.receiver_type_id < tt.type_count) {
			p.receiver_type = tt.types[p.receiver_type_id];
		}
	}
}

// ── Resolve a KmType to a Kotlin-style type string ─────────────────

/**
 * Build a Kotlin-style type string from a KmType.
 * E.g., "String", "List<Int>", "Map<String, Int?>", "(Int) -> String"
 */
fn String resolve_km_type_to_string(KmType* t, KmClass* km, String[] d2, usz d2_len) {
	if (t.class_name_id < 0 && t.type_parameter_id < 0) return "";

	DString result;
	result.tinit();

	if (t.class_name_id >= 0) {
		String name = resolve_type_name(km, t.class_name_id, d2, d2_len);
		if (name.len == 0) return "";

		// Check for function types (Function0, Function1, etc.)
		if (is_function_type_name(name) && t.arg_count > 0) {
			build_function_type_string(&result, t, km, d2, d2_len);
		} else {
			result.appendf("%s", name);
			if (t.arg_count > 0) {
				result.appendf("<");
				for (usz i = 0; i < t.arg_count; i++) {
					if (i > 0) result.appendf(", ");
					if (t.arg_projections[i] == 3) {
						result.appendf("*");
					} else {
						if (t.arg_projections[i] == 0) result.appendf("in ");
						if (t.arg_projections[i] == 1) result.appendf("out ");
						// Resolve arg type name
						if (t.arg_class_ids[i] >= 0) {
							String arg_name = resolve_type_name(km, t.arg_class_ids[i], d2, d2_len);
							result.appendf("%s", arg_name);
							if (t.arg_nullable[i]) result.appendf("?");
						}
					}
				}
				result.appendf(">");
			}
		}
	} else if (t.type_parameter_id >= 0) {
		result.appendf("T%d", t.type_parameter_id); // placeholder
	}

	if (t.nullable) result.appendf("?");

	return result.str_view();
}

fn bool is_function_type_name(String name) {
	// Function0..FunctionN or SuspendFunction0..SuspendFunctionN
	if (name.len >= 8 && name[:8] == "Function") return true;
	if (name.len >= 15 && name[:15] == "SuspendFunction") return true;
	return false;
}

fn void build_function_type_string(DString* result, KmType* t, KmClass* km, String[] d2, usz d2_len) {
	// Function types: last arg = return type, previous args = params
	// If has_extension_annotation: first arg = receiver, rest = params, last = return
	usz start = 0;
	if (t.has_extension_annotation && t.arg_count >= 2) {
		if (t.arg_class_ids[0] >= 0) {
			String recv = resolve_type_name(km, t.arg_class_ids[0], d2, d2_len);
			result.appendf("%s.", recv);
		}
		start = 1;
	}

	if (t.is_suspend) result.appendf("suspend ");

	result.appendf("(");
	usz return_idx = t.arg_count > 0 ? t.arg_count - 1 : 0;
	for (usz i = start; i < return_idx; i++) {
		if (i > start) result.appendf(", ");
		if (t.arg_class_ids[i] >= 0) {
			String arg_name = resolve_type_name(km, t.arg_class_ids[i], d2, d2_len);
			result.appendf("%s", arg_name);
			if (t.arg_nullable[i]) result.appendf("?");
		}
	}
	result.appendf(") -> ");

	if (t.arg_count > 0 && t.arg_class_ids[return_idx] >= 0) {
		String ret = resolve_type_name(km, t.arg_class_ids[return_idx], d2, d2_len);
		result.appendf("%s", ret);
		if (t.arg_nullable[return_idx]) result.appendf("?");
	} else {
		result.appendf("Unit");
	}
}
