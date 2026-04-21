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

// ── JVM StringTableTypes Record ────────────────────────────────────

const int STT_OP_NONE = 0;
const int STT_OP_INTERNAL_TO_CLASS_ID = 1;  // replace '$' with '.'
const int STT_OP_DESC_TO_CLASS_ID = 2;       // substring(1, len-1) then replace '$' with '.'

struct SttRecord {
	int predefined_index;     // -1 if not predefined
	int operation;            // STT_OP_*
	String override_string;   // non-empty if record has explicit string field
	// substring_index and replace_char omitted for now (rare)
}

// Kotlin predefined strings (0-indexed, prefix "kotlin" implied by format)
const String[44] PREDEFINED_STRINGS = {
	"kotlin/Any", "kotlin/Nothing", "kotlin/Unit", "kotlin/Throwable",
	"kotlin/Number", "kotlin/Byte", "kotlin/Double", "kotlin/Float",
	"kotlin/Int", "kotlin/Long", "kotlin/Short", "kotlin/Boolean",
	"kotlin/Char", "kotlin/CharSequence", "kotlin/String", "kotlin/Comparable",
	"kotlin/Enum", "kotlin/Array", "kotlin/ByteArray", "kotlin/DoubleArray",
	"kotlin/FloatArray", "kotlin/IntArray", "kotlin/LongArray", "kotlin/ShortArray",
	"kotlin/BooleanArray", "kotlin/CharArray", "kotlin/Cloneable", "kotlin/Annotation",
	"kotlin/collections/Iterable", "kotlin/collections/MutableIterable",
	"kotlin/collections/Collection", "kotlin/collections/MutableCollection",
	"kotlin/collections/List", "kotlin/collections/MutableList",
	"kotlin/collections/Set", "kotlin/collections/MutableSet",
	"kotlin/collections/Map", "kotlin/collections/MutableMap",
	"kotlin/collections/Map.Entry", "kotlin/collections/MutableMap.MutableEntry",
	"kotlin/collections/Iterator", "kotlin/collections/MutableIterator",
	"kotlin/collections/ListIterator", "kotlin/collections/MutableListIterator",
};

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
	// JVM StringTableTypes: maps string IDs to resolved strings
	usz stt_record_count;
	SttRecord[128] stt_records;  // expanded (one per string index)
}

// ── JVM String Table Prefix ────────────────────────────────────────

/**
 * Parse the JvmStringTableTypes prefix in Kotlin JVM metadata d1.
 * JVM metadata d1 = writeDelimitedTo(StringTableTypes) + Package/Class protobuf.
 * writeDelimitedTo writes: varint(message_byte_size) + message_bytes.
 * Populates km.stt_records with expanded records (one per string index).
 */
fn void parse_jvm_string_table_prefix(char[] data, usz* pos, KmClass* km) {
	if (*pos >= data.len) return;
	ulong msg_len = read_varint(data, pos);
	usz msg_end = *pos + (usz)msg_len;
	if (msg_end > data.len) msg_end = data.len;

	km.stt_record_count = 0;

	// Parse StringTableTypes message: field 1 = Record (repeated, length-delimited)
	while (*pos < msg_end) {
		usz prev = *pos;
		FieldTag tag = read_tag(data, pos);
		if (*pos > msg_end || *pos == prev) break;

		if (tag.field_number == 1 && tag.wire_type == WIRE_LENGTH_DELIMITED) {
			ulong rec_len = read_varint(data, pos);
			usz rec_end = *pos + (usz)rec_len;
			if (rec_end > msg_end) rec_end = msg_end;

			// Parse Record fields
			int range = 1;
			int predefined_idx = -1;
			int operation = STT_OP_NONE;
			String override_str = "";

			while (*pos < rec_end) {
				usz rprev = *pos;
				FieldTag rtag = read_tag(data, pos);
				if (*pos > rec_end || *pos == rprev) break;

				switch (rtag.field_number) {
					case 1: // range (varint)
						range = (int)read_varint(data, pos);
					case 2: // predefined_index (varint)
						predefined_idx = (int)read_varint(data, pos);
					case 3: // operation (varint enum)
						operation = (int)read_varint(data, pos);
					case 6: // string (length-delimited)
						if (rtag.wire_type == WIRE_LENGTH_DELIMITED) {
							ulong slen = read_varint(data, pos);
							usz s_end = *pos + (usz)slen;
							if (s_end > rec_end) s_end = rec_end;
							override_str = (String)data[*pos..s_end - 1];
							*pos = s_end;
						} else {
							skip_field(data, pos, rtag.wire_type);
						}
					default:
						skip_field(data, pos, rtag.wire_type);
				}
			}
			*pos = rec_end;

			// Expand range: add `range` copies of this record
			for (int r = 0; r < range && km.stt_record_count < 128; r++) {
				km.stt_records[km.stt_record_count] = {
					.predefined_index = predefined_idx,
					.operation = operation,
					.override_string = override_str,
				};
				km.stt_record_count++;
			}
		} else {
			skip_field(data, pos, tag.wire_type);
		}
	}

	*pos = msg_end;
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

	// JVM metadata d1 starts with a length-delimited StringTableTypes message
	// (writeDelimitedTo format), followed by the actual Package/Class protobuf.
	parse_jvm_string_table_prefix(d1, &pos, out);

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
 * Resolve a string table index using JVM StringTableTypes records.
 * Falls back to d2[id] if no records or out of range.
 */
fn String jvm_resolve_string(KmClass* km, int id, String[] d2, usz d2_len) {
	if (id < 0) return "";

	// If we have StringTableTypes records, use them
	if (km.stt_record_count > 0 && (usz)id < km.stt_record_count) {
		SttRecord* rec = &km.stt_records[id];

		// Check for explicit override string
		if (rec.override_string.len > 0) return rec.override_string;

		// Check for predefined string
		if (rec.predefined_index >= 0 && (usz)rec.predefined_index < 44) {
			return PREDEFINED_STRINGS[rec.predefined_index];
		}

		// Use d2 string with optional operation
		if ((usz)id >= d2_len) return "";
		String s = d2[id];

		if (rec.operation == STT_OP_INTERNAL_TO_CLASS_ID) {
			// Replace '$' with '.' for inner classes: kotlin/Map$Entry -> kotlin/Map.Entry
			return s; // For now return as-is; $ replacement done at use site if needed
		} else if (rec.operation == STT_OP_DESC_TO_CLASS_ID) {
			// Trim L...;  descriptor format: Lkotlin/String; -> kotlin/String
			if (s.len >= 2 && s[0] == 'L' && s[s.len - 1] == ';') {
				return s[1..s.len - 2];
			}
		}

		return s;
	}

	// Fallback: direct d2 lookup (no records — shouldn't happen for JVM metadata)
	if ((usz)id < d2_len) return d2[id];
	return "";
}

/**
 * Resolve a type name ID (class_name_id from KmType) to a simple class name.
 * For JVM metadata, uses StringTableTypes records.
 * For non-JVM, falls back to QualifiedNameTable.
 */
fn String resolve_type_name(KmClass* km, int class_name_id, String[] d2, usz d2_len) {
	// JVM path: use StringTableTypes records
	if (km.stt_record_count > 0) {
		String fqn = jvm_resolve_string(km, class_name_id, d2, d2_len);
		if (fqn.len == 0) return "";
		// Extract simple name: "kotlin/collections/List" -> "List"
		// Find last '/' or '.'
		usz last_sep = 0;
		bool found_sep = false;
		for (usz i = 0; i < fqn.len; i++) {
			if (fqn[i] == '/' || fqn[i] == '.') {
				last_sep = i;
				found_sep = true;
			}
		}
		if (found_sep) return fqn[last_sep + 1..];
		return fqn;
	}

	// Non-JVM fallback: QualifiedNameTable
	if (class_name_id < 0 || (usz)class_name_id >= km.qn_count) return "";
	int str_id = km.qualified_names[class_name_id].short_name;
	if (str_id < 0 || (usz)str_id >= d2_len) return "";
	return d2[str_id];
}

/**
 * Resolve a type name ID to a fully qualified name.
 * For JVM metadata, uses StringTableTypes records (already FQ).
 * For non-JVM, walks QualifiedNameTable parent chain.
 */
fn String resolve_type_fqn(KmClass* km, int class_name_id, String[] d2, usz d2_len) {
	// JVM path: StringTableTypes already gives FQ names
	if (km.stt_record_count > 0) {
		String fqn = jvm_resolve_string(km, class_name_id, d2, d2_len);
		if (fqn.len == 0) return "";
		// Convert internal format to dot-separated: "kotlin/collections/List" -> "kotlin.collections.List"
		DString result;
		result.tinit();
		for (usz i = 0; i < fqn.len; i++) {
			if (fqn[i] == '/') {
				result.appendf(".");
			} else {
				result.appendf("%c", fqn[i]);
			}
		}
		return result.str_view();
	}

	// Non-JVM fallback
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		switch (tag.field_number) {
			case 1: // flags
				int flags = (int)read_varint(data, &pos);
				t.is_suspend = (flags & 1) != 0;
			case 2: // argument (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (t.arg_count < MAX_TYPE_ARGS) {
						parse_type_argument_into(data, pos, sub_end, &t, t.arg_count);
						t.arg_count++;
					}
					pos = sub_end;
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
					if (ann_end > end) ann_end = end;
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		switch (tag.field_number) {
			case 1: // projection
				parent.arg_projections[arg_idx] = (int)read_varint(data, &pos);
			case 2: // type (length-delimited) — extract class_name_id and nullable
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					KmType inner = parse_type(data, pos, sub_end);
					parent.arg_class_ids[arg_idx] = inner.class_name_id;
					parent.arg_nullable[arg_idx] = inner.nullable;
					pos = sub_end;
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
	if (end > data.len) end = data.len;
	usz pos = start;
	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		switch (tag.field_number) {
			case 2: // name (varint, string index)
				vp.name_id = (int)read_varint(data, &pos);
			case 3: // type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					vp.type = parse_type(data, pos, sub_end);
					pos = sub_end;
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		switch (tag.field_number) {
			case 9: // flags
				f.flags = (int)read_varint(data, &pos);
			case 2: // name (varint, string index)
				f.name_id = (int)read_varint(data, &pos);
			case 3: // return_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					f.return_type = parse_type(data, pos, sub_end);
					f.has_return_type = true;
					pos = sub_end;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 5: // receiver_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					f.receiver_type = parse_type(data, pos, sub_end);
					f.has_receiver_type = true;
					pos = sub_end;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 6: // value_parameter (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (f.param_count < MAX_PARAMS) {
						f.params[f.param_count] = parse_value_parameter(data, pos, sub_end);
						f.param_count++;
					}
					pos = sub_end;
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		switch (tag.field_number) {
			case 11: // flags
				p.flags = (int)read_varint(data, &pos);
			case 2: // name (varint, string index)
				p.name_id = (int)read_varint(data, &pos);
			case 3: // return_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					p.return_type = parse_type(data, pos, sub_end);
					p.has_return_type = true;
					pos = sub_end;
				} else {
					skip_field(data, &pos, tag.wire_type);
				}
			case 5: // receiver_type (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					p.receiver_type = parse_type(data, pos, sub_end);
					p.has_receiver_type = true;
					pos = sub_end;
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		switch (tag.field_number) {
			case 1: // type (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, &pos);
					usz sub_end = pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (tt.type_count < 64) {
						tt.types[tt.type_count] = parse_type(data, pos, sub_end);
						tt.type_count++;
					}
					pos = sub_end;
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
	if (end > data.len) end = data.len;
	usz pos = start;

	while (pos < end) {
		usz prev = pos;
		FieldTag tag = read_tag(data, &pos);
		if (pos > end || pos == prev) break;

		if (tag.field_number == 1 && tag.wire_type == WIRE_LENGTH_DELIMITED) {
			// QualifiedName entry
			ulong len = read_varint(data, &pos);
			usz entry_end = pos + (usz)len;
			if (entry_end > end) entry_end = end;

			if (out.qn_count < MAX_QN_ENTRIES) {
				QnEntry* entry = &out.qualified_names[out.qn_count];
				entry.parent = -1;
				entry.short_name = -1;
				entry.kind = 0; // CLASS

				usz epos = pos;
				while (epos < entry_end) {
					usz eprev = epos;
					FieldTag etag = read_tag(data, &epos);
					if (epos > entry_end || epos == eprev) break;
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
		usz prev = *pos;
		FieldTag tag = read_tag(data, pos);
		if (*pos > end || *pos == prev) break;

		switch (tag.field_number) {
			case 1: // flags
				out.flags = (int)read_varint(data, pos);
			case 3: // fq_name (varint)
				out.fq_name_id = (int)read_varint(data, pos);
			case 6: // supertype (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (out.supertype_count < MAX_SUPERTYPES) {
						out.supertypes[out.supertype_count] = parse_type(data, *pos, sub_end);
						out.supertype_count++;
					}
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 2: // supertype_id (packed varint)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz packed_end = *pos + (usz)len;
					if (packed_end > end) packed_end = end;
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
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (out.function_count < MAX_FUNCTIONS) {
						out.functions[out.function_count] = parse_function(data, *pos, sub_end);
						out.function_count++;
					}
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 10: // property (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (out.property_count < MAX_PROPERTIES) {
						out.properties[out.property_count] = parse_property(data, *pos, sub_end);
						out.property_count++;
					}
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 30: // type_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					parse_type_table(data, *pos, sub_end, &out.type_table);
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 31: // qualified_name_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					parse_qualified_name_table(data, *pos, sub_end, out);
					*pos = sub_end;
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
		usz prev = *pos;
		FieldTag tag = read_tag(data, pos);
		if (*pos > end || *pos == prev) break;

		switch (tag.field_number) {
			case 3: // function (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (out.function_count < MAX_FUNCTIONS) {
						out.functions[out.function_count] = parse_function(data, *pos, sub_end);
						out.function_count++;
					}
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 4: // property (length-delimited, repeated)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					if (out.property_count < MAX_PROPERTIES) {
						out.properties[out.property_count] = parse_property(data, *pos, sub_end);
						out.property_count++;
					}
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 30: // type_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					parse_type_table(data, *pos, sub_end, &out.type_table);
					*pos = sub_end;
				} else {
					skip_field(data, pos, tag.wire_type);
				}
			case 31: // qualified_name_table (length-delimited)
				if (tag.wire_type == WIRE_LENGTH_DELIMITED) {
					ulong len = read_varint(data, pos);
					usz sub_end = *pos + (usz)len;
					if (sub_end > end) sub_end = end;
					parse_qualified_name_table(data, *pos, sub_end, out);
					*pos = sub_end;
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
