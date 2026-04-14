module kls::deps::classfile;

import std::io;

// ── JVM class file constants ───────────────────────────────────────

const uint MAGIC = 0xCAFEBABE;

// Constant pool tags
const char CONSTANT_UTF8               = 1;
const char CONSTANT_INTEGER            = 3;
const char CONSTANT_FLOAT              = 4;
const char CONSTANT_LONG               = 5;
const char CONSTANT_DOUBLE             = 6;
const char CONSTANT_CLASS              = 7;
const char CONSTANT_STRING             = 8;
const char CONSTANT_FIELDREF           = 9;
const char CONSTANT_METHODREF          = 10;
const char CONSTANT_INTERFACE_METHODREF = 11;
const char CONSTANT_NAME_AND_TYPE      = 12;
const char CONSTANT_METHOD_HANDLE      = 15;
const char CONSTANT_METHOD_TYPE        = 16;
const char CONSTANT_DYNAMIC            = 17;
const char CONSTANT_INVOKE_DYNAMIC     = 18;
const char CONSTANT_MODULE             = 19;
const char CONSTANT_PACKAGE            = 20;

// Access flags
const ushort ACC_PUBLIC       = 0x0001;
const ushort ACC_PRIVATE      = 0x0002;
const ushort ACC_PROTECTED    = 0x0004;
const ushort ACC_STATIC       = 0x0008;
const ushort ACC_FINAL        = 0x0010;
const ushort ACC_SUPER        = 0x0020;
const ushort ACC_BRIDGE       = 0x0040;
const ushort ACC_VARARGS      = 0x0080;
const ushort ACC_INTERFACE    = 0x0200;
const ushort ACC_ABSTRACT     = 0x0400;
const ushort ACC_SYNTHETIC    = 0x1000;
const ushort ACC_ANNOTATION   = 0x2000;
const ushort ACC_ENUM         = 0x4000;

// ── Constant pool entry ────────────────────────────────────────────

struct CpEntry {
	char tag;
	// For UTF8: the string data (points into class file bytes)
	String utf8_val;
	// For Class, String, MethodType, Module, Package: name_index
	ushort name_index;
	// For FieldRef, MethodRef, InterfaceMethodRef, NameAndType, Dynamic, InvokeDynamic:
	ushort class_index;
	ushort name_and_type_index;
	// For NameAndType:
	ushort descriptor_index;
}

// ── Parsed member (method or field) ────────────────────────────────

struct ClassMember {
	ushort access_flags;
	String name;          // resolved from constant pool
	String descriptor;    // resolved from constant pool
}

// ── Parsed class file ──────────────────────────────────────────────

const usz MAX_MEMBERS = 512;

struct ClassInfo {
	ushort access_flags;
	String class_name;         // e.g. "kotlin/collections/CollectionsKt"
	String super_name;         // e.g. "java/lang/Object"
	String[32] interfaces;     // interface names
	usz interface_count;
	ClassMember[MAX_MEMBERS] methods;
	usz method_count;
	ClassMember[MAX_MEMBERS] fields;
	usz field_count;
}

// ── Parse errors ───────────────────────────────────────────────────

faultdef
	INVALID_MAGIC,
	TRUNCATED,
	INVALID_CP_TAG,
	INVALID_INDEX;

// ── Main parse function ────────────────────────────────────────────

/**
 * Parse a JVM .class file from raw bytes.
 * Extracts class name, super class, interfaces, and public methods/fields.
 * All strings point into the input data (zero-copy for class file bytes).
 */
fn void? parse_class(char[] data, ClassInfo* info) {
	usz pos = 0;

	// Magic number
	if (data.len < 10) return TRUNCATED~;
	uint magic = read_u32(data, &pos)!;
	if (magic != MAGIC) return INVALID_MAGIC~;

	// Version (skip)
	ushort minor = read_u16(data, &pos)!;
	ushort major = read_u16(data, &pos)!;

	// ── Constant pool ──────────────────────────────────────────
	ushort cp_count = read_u16(data, &pos)!;
	// CP indices are 1-based; entry 0 is unused
	usz cp_len = (usz)cp_count;
	CpEntry[] cp = mem::talloc_array(CpEntry, cp_len);

	for (usz i = 1; i < cp_len; i++) {
		if (pos >= data.len) return TRUNCATED~;
		char tag = data[pos];
		pos++;
		cp[i].tag = tag;

		switch (tag) {
			case CONSTANT_UTF8:
				ushort len = read_u16(data, &pos)!;
				if (pos + (usz)len > data.len) return TRUNCATED~;
				cp[i].utf8_val = (String)data[pos:len];
				pos += (usz)len;

			case CONSTANT_INTEGER:
			case CONSTANT_FLOAT:
				pos += 4; // skip 4 bytes

			case CONSTANT_LONG:
			case CONSTANT_DOUBLE:
				pos += 8; // skip 8 bytes
				i++; // long/double take two CP entries

			case CONSTANT_CLASS:
			case CONSTANT_STRING:
			case CONSTANT_METHOD_TYPE:
			case CONSTANT_MODULE:
			case CONSTANT_PACKAGE:
				cp[i].name_index = read_u16(data, &pos)!;

			case CONSTANT_FIELDREF:
			case CONSTANT_METHODREF:
			case CONSTANT_INTERFACE_METHODREF:
				cp[i].class_index = read_u16(data, &pos)!;
				cp[i].name_and_type_index = read_u16(data, &pos)!;

			case CONSTANT_NAME_AND_TYPE:
				cp[i].name_index = read_u16(data, &pos)!;
				cp[i].descriptor_index = read_u16(data, &pos)!;

			case CONSTANT_METHOD_HANDLE:
				pos += 3; // reference_kind (1) + reference_index (2)

			case CONSTANT_DYNAMIC:
			case CONSTANT_INVOKE_DYNAMIC:
				pos += 4; // bootstrap_method_attr_index (2) + name_and_type_index (2)

			default:
				return INVALID_CP_TAG~;
		}
	}

	// ── Class info ──────────────────────────────────────────────
	info.access_flags = read_u16(data, &pos)!;
	ushort this_class = read_u16(data, &pos)!;
	ushort super_class = read_u16(data, &pos)!;

	info.class_name = resolve_class_name(cp, cp_len, this_class) ?? "";
	info.super_name = super_class > 0 ? (resolve_class_name(cp, cp_len, super_class) ?? "") : "";

	// ── Interfaces ──────────────────────────────────────────────
	ushort iface_count = read_u16(data, &pos)!;
	info.interface_count = 0;
	for (usz i = 0; i < (usz)iface_count; i++) {
		ushort iface_idx = read_u16(data, &pos)!;
		if (info.interface_count < 32) {
			info.interfaces[info.interface_count] = resolve_class_name(cp, cp_len, iface_idx) ?? "";
			info.interface_count++;
		}
	}

	// ── Fields ──────────────────────────────────────────────────
	ushort field_count = read_u16(data, &pos)!;
	info.field_count = 0;
	for (usz i = 0; i < (usz)field_count; i++) {
		ushort flags = read_u16(data, &pos)!;
		ushort name_idx = read_u16(data, &pos)!;
		ushort desc_idx = read_u16(data, &pos)!;
		skip_attributes(data, &pos)!;

		// Only collect public non-synthetic fields
		if ((flags & ACC_PUBLIC) != 0 && (flags & ACC_SYNTHETIC) == 0) {
			if (info.field_count < MAX_MEMBERS) {
				info.fields[info.field_count] = {
					.access_flags = flags,
					.name = resolve_utf8(cp, cp_len, name_idx) ?? "",
					.descriptor = resolve_utf8(cp, cp_len, desc_idx) ?? "",
				};
				info.field_count++;
			}
		}
	}

	// ── Methods ─────────────────────────────────────────────────
	ushort method_count = read_u16(data, &pos)!;
	info.method_count = 0;
	for (usz i = 0; i < (usz)method_count; i++) {
		ushort flags = read_u16(data, &pos)!;
		ushort name_idx = read_u16(data, &pos)!;
		ushort desc_idx = read_u16(data, &pos)!;
		skip_attributes(data, &pos)!;

		// Only collect public non-synthetic, non-bridge methods
		if ((flags & ACC_PUBLIC) != 0 && (flags & ACC_SYNTHETIC) == 0 && (flags & ACC_BRIDGE) == 0) {
			if (info.method_count < MAX_MEMBERS) {
				info.methods[info.method_count] = {
					.access_flags = flags,
					.name = resolve_utf8(cp, cp_len, name_idx) ?? "",
					.descriptor = resolve_utf8(cp, cp_len, desc_idx) ?? "",
				};
				info.method_count++;
			}
		}
	}
}

// ── Constant pool resolution ───────────────────────────────────────

fn String? resolve_utf8(CpEntry[] cp, usz cp_len, ushort index) {
	if (index == 0 || (usz)index >= cp_len) return INVALID_INDEX~;
	if (cp[index].tag != CONSTANT_UTF8) return INVALID_INDEX~;
	return cp[index].utf8_val;
}

fn String? resolve_class_name(CpEntry[] cp, usz cp_len, ushort index) {
	if (index == 0 || (usz)index >= cp_len) return INVALID_INDEX~;
	if (cp[index].tag != CONSTANT_CLASS) return INVALID_INDEX~;
	return resolve_utf8(cp, cp_len, cp[index].name_index);
}

// ── Attribute skipping ─────────────────────────────────────────────

fn void? skip_attributes(char[] data, usz* pos) {
	ushort attr_count = read_u16(data, pos)!;
	for (usz i = 0; i < (usz)attr_count; i++) {
		read_u16(data, pos)!; // name_index
		uint attr_len = read_u32(data, pos)!;
		if (*pos + (usz)attr_len > data.len) return TRUNCATED~;
		*pos += (usz)attr_len;
	}
}

// ── Binary reading helpers ─────────────────────────────────────────

fn uint? read_u32(char[] data, usz* pos) {
	if (*pos + 4 > data.len) return TRUNCATED~;
	uint val = ((uint)data[*pos] << 24)
		| ((uint)data[*pos + 1] << 16)
		| ((uint)data[*pos + 2] << 8)
		| (uint)data[*pos + 3];
	*pos += 4;
	return val;
}

fn ushort? read_u16(char[] data, usz* pos) {
	if (*pos + 2 > data.len) return TRUNCATED~;
	ushort val = (ushort)(((ushort)data[*pos] << 8) | (ushort)data[*pos + 1]);
	*pos += 2;
	return val;
}

// ── JVM descriptor -> Kotlin type conversion ───────────────────────

/**
 * Convert a JVM type descriptor to a human-readable Kotlin type string.
 * E.g., "Ljava/lang/String;" -> "String", "I" -> "Int", "[B" -> "ByteArray"
 * Writes into the provided DString.
 */
fn void descriptor_to_kotlin_type(String desc, DString* out) {
	if (desc.len == 0) return;

	usz pos = 0;
	append_type(desc, &pos, out);
}

/**
 * Convert a JVM method descriptor to a Kotlin-style parameter list and return type.
 * E.g., "(ILjava/lang/String;)V" -> "(Int, String): Unit"
 */
fn void method_descriptor_to_kotlin(String desc, DString* out) {
	if (desc.len == 0 || desc[0] != '(') return;

	usz pos = 1; // skip '('
	out.appendf("(");
	bool first = true;

	while (pos < desc.len && desc[pos] != ')') {
		if (!first) out.appendf(", ");
		first = false;
		append_type(desc, &pos, out);
	}

	out.appendf(")");

	if (pos < desc.len && desc[pos] == ')') {
		pos++; // skip ')'
		out.appendf(": ");
		append_type(desc, &pos, out);
	}
}

fn void append_type(String desc, usz* pos, DString* out) {
	if (*pos >= desc.len) return;

	switch (desc[*pos]) {
		case 'V': out.appendf("Unit"); (*pos)++;
		case 'Z': out.appendf("Boolean"); (*pos)++;
		case 'B': out.appendf("Byte"); (*pos)++;
		case 'C': out.appendf("Char"); (*pos)++;
		case 'S': out.appendf("Short"); (*pos)++;
		case 'I': out.appendf("Int"); (*pos)++;
		case 'J': out.appendf("Long"); (*pos)++;
		case 'F': out.appendf("Float"); (*pos)++;
		case 'D': out.appendf("Double"); (*pos)++;

		case '[':
			(*pos)++; // skip '['
			if (*pos < desc.len) {
				// Check for primitive arrays -> Kotlin special names
				switch (desc[*pos]) {
					case 'Z': out.appendf("BooleanArray"); (*pos)++;
					case 'B': out.appendf("ByteArray"); (*pos)++;
					case 'C': out.appendf("CharArray"); (*pos)++;
					case 'S': out.appendf("ShortArray"); (*pos)++;
					case 'I': out.appendf("IntArray"); (*pos)++;
					case 'J': out.appendf("LongArray"); (*pos)++;
					case 'F': out.appendf("FloatArray"); (*pos)++;
					case 'D': out.appendf("DoubleArray"); (*pos)++;
					default:
						out.appendf("Array<");
						append_type(desc, pos, out);
						out.appendf(">");
				}
			}

		case 'L':
			(*pos)++; // skip 'L'
			usz start = *pos;
			while (*pos < desc.len && desc[*pos] != ';') {
				(*pos)++;
			}
			if (*pos > start) {
				String full_name = desc[start..*pos - 1];
				// Convert "java/lang/String" to just "String" etc.
				append_short_class_name(full_name, out);
			}
			if (*pos < desc.len) (*pos)++; // skip ';'

		default:
			out.appendf("?");
			(*pos)++;
	}
}

/**
 * Convert a JVM internal class name to a short Kotlin type name.
 * Handles common kotlin.* and java.lang.* mappings.
 */
fn void append_short_class_name(String full_name, DString* out) {
	// Common JVM -> Kotlin mappings
	if (full_name == "java/lang/String") { out.appendf("String"); return; }
	if (full_name == "java/lang/Object") { out.appendf("Any"); return; }
	if (full_name == "java/lang/Integer") { out.appendf("Int"); return; }
	if (full_name == "java/lang/Long") { out.appendf("Long"); return; }
	if (full_name == "java/lang/Boolean") { out.appendf("Boolean"); return; }
	if (full_name == "java/lang/Double") { out.appendf("Double"); return; }
	if (full_name == "java/lang/Float") { out.appendf("Float"); return; }
	if (full_name == "java/lang/Byte") { out.appendf("Byte"); return; }
	if (full_name == "java/lang/Short") { out.appendf("Short"); return; }
	if (full_name == "java/lang/Character") { out.appendf("Char"); return; }
	if (full_name == "java/lang/Void") { out.appendf("Unit"); return; }
	if (full_name == "java/lang/Iterable") { out.appendf("Iterable"); return; }
	if (full_name == "java/util/List") { out.appendf("List"); return; }
	if (full_name == "java/util/Map") { out.appendf("Map"); return; }
	if (full_name == "java/util/Set") { out.appendf("Set"); return; }
	if (full_name == "java/util/Collection") { out.appendf("Collection"); return; }
	if (full_name == "java/util/Iterator") { out.appendf("Iterator"); return; }
	if (full_name == "java/lang/Comparable") { out.appendf("Comparable"); return; }
	if (full_name == "java/lang/Throwable") { out.appendf("Throwable"); return; }
	if (full_name == "java/lang/Exception") { out.appendf("Exception"); return; }
	if (full_name == "java/lang/RuntimeException") { out.appendf("RuntimeException"); return; }
	if (full_name == "kotlin/Unit") { out.appendf("Unit"); return; }
	if (full_name == "kotlin/Nothing") { out.appendf("Nothing"); return; }
	if (full_name == "kotlin/Any") { out.appendf("Any"); return; }

	// For other classes, take just the simple name after the last '/'
	usz last_slash = 0;
	bool found_slash = false;
	for (usz i = 0; i < full_name.len; i++) {
		if (full_name[i] == '/') {
			last_slash = i;
			found_slash = true;
		}
	}

	if (found_slash) {
		String simple = full_name[last_slash + 1..];
		// Replace '$' with '.' for inner classes
		for (usz i = 0; i < simple.len; i++) {
			if (simple[i] == '$') {
				out.appendf(".");
			} else {
				out.appendf("%c", simple[i]);
			}
		}
	} else {
		out.appendf("%s", full_name);
	}
}

// ── Class name utilities ───────────────────────────────────────────

/**
 * Convert a JVM internal name (e.g. "kotlin/collections/CollectionsKt")
 * to a package name (e.g. "kotlin.collections").
 */
fn String jvm_name_to_package(String jvm_name) {
	if (jvm_name.len == 0) return "";

	// Find last '/'
	usz last_slash = 0;
	bool found = false;
	for (usz i = 0; i < jvm_name.len; i++) {
		if (jvm_name[i] == '/') {
			last_slash = i;
			found = true;
		}
	}

	if (!found) return "";

	// Replace '/' with '.' in the package portion
	DString ds;
	ds.tinit();
	for (usz i = 0; i < last_slash; i++) {
		if (jvm_name[i] == '/') {
			ds.appendf(".");
		} else {
			ds.appendf("%c", jvm_name[i]);
		}
	}
	return ds.str_view();
}

/**
 * Extract the simple class name from a JVM internal name.
 * "kotlin/collections/CollectionsKt" -> "CollectionsKt"
 */
fn String jvm_name_to_simple(String jvm_name) {
	if (jvm_name.len == 0) return "";

	usz last_slash = 0;
	bool found = false;
	for (usz i = 0; i < jvm_name.len; i++) {
		if (jvm_name[i] == '/') {
			last_slash = i;
			found = true;
		}
	}

	if (found) {
		return jvm_name[last_slash + 1..];
	}
	return jvm_name;
}
