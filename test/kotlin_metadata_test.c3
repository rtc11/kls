module kls::kotlin_metadata_test @test;

import kls::deps::kotlin_metadata;
import kls::deps::classfile;

// ── Varint decoding ────────────────────────────────────────────────

fn void test_read_varint_single_byte() {
	char[] data = { 0x08 };
	usz pos = 0;
	ulong val = kotlin_metadata::read_varint(data, &pos);
	assert(val == 8);
	assert(pos == 1);
}

fn void test_read_varint_multi_byte() {
	char[] data = { 0xAC, 0x02 };
	usz pos = 0;
	ulong val = kotlin_metadata::read_varint(data, &pos);
	assert(val == 300);
	assert(pos == 2);
}

fn void test_read_varint_zero() {
	char[] data = { 0x00 };
	usz pos = 0;
	ulong val = kotlin_metadata::read_varint(data, &pos);
	assert(val == 0);
	assert(pos == 1);
}

// ── Tag decoding ───────────────────────────────────────────────────

fn void test_read_tag() {
	char[] data = { 0x08 };
	usz pos = 0;
	kotlin_metadata::FieldTag tag = kotlin_metadata::read_tag(data, &pos);
	assert(tag.field_number == 1);
	assert(tag.wire_type == 0);
}

fn void test_read_tag_length_delimited() {
	char[] data = { 0x12 };
	usz pos = 0;
	kotlin_metadata::FieldTag tag = kotlin_metadata::read_tag(data, &pos);
	assert(tag.field_number == 2);
	assert(tag.wire_type == 2);
}

// ── Type parsing ───────────────────────────────────────────────────

fn void test_parse_type_simple_class() {
	char[] data = { 0x30, 0x00 };
	KmType t = kotlin_metadata::parse_type(data, 0, data.len);
	assert(t.class_name_id == 0);
	assert(!t.nullable);
	assert(t.arg_count == 0);
}

fn void test_parse_type_nullable() {
	char[] data = { 0x30, 0x00, 0x18, 0x01 };
	KmType t = kotlin_metadata::parse_type(data, 0, data.len);
	assert(t.class_name_id == 0);
	assert(t.nullable);
}

fn void test_parse_type_with_type_arg() {
	char[] data = { 0x30, 0x00, 0x12, 0x06, 0x08, 0x02, 0x12, 0x02, 0x30, 0x01 };
	KmType t = kotlin_metadata::parse_type(data, 0, data.len);
	assert(t.class_name_id == 0);
	assert(t.arg_count == 1);
	assert(t.arg_class_ids[0] == 1);
	assert(t.arg_projections[0] == 2);
	assert(!t.arg_nullable[0]);
}

// ── Function parsing ───────────────────────────────────────────────

fn void test_parse_function_name_and_return() {
	char[] data = { 0x10, 0x05, 0x1a, 0x02, 0x30, 0x02 };
	KmFunction f = kotlin_metadata::parse_function(data, 0, data.len);
	assert(f.name_id == 5);
	assert(f.has_return_type);
	assert(f.return_type.class_name_id == 2);
	assert(!f.has_receiver_type);
}

fn void test_parse_function_with_receiver() {
	char[] data = { 0x10, 0x03, 0x2a, 0x02, 0x30, 0x01 };
	KmFunction f = kotlin_metadata::parse_function(data, 0, data.len);
	assert(f.name_id == 3);
	assert(f.has_receiver_type);
	assert(f.receiver_type.class_name_id == 1);
}

fn void test_parse_function_with_return_type_id() {
	char[] data = { 0x10, 0x00, 0x38, 0x04 };
	KmFunction f = kotlin_metadata::parse_function(data, 0, data.len);
	assert(f.name_id == 0);
	assert(f.has_return_type);
	assert(f.return_type_id == 4);
}

fn void test_parse_function_with_params() {
	char[] data = { 0x10, 0x01, 0x32, 0x06, 0x10, 0x07, 0x1a, 0x02, 0x30, 0x03 };
	KmFunction f = kotlin_metadata::parse_function(data, 0, data.len);
	assert(f.name_id == 1);
	assert(f.param_count == 1);
	assert(f.params[0].name_id == 7);
	assert(f.params[0].type.class_name_id == 3);
}

// ── Property parsing ───────────────────────────────────────────────

fn void test_parse_property_name_and_return() {
	char[] data = { 0x10, 0x02, 0x1a, 0x02, 0x30, 0x04 };
	KmProperty p = kotlin_metadata::parse_property(data, 0, data.len);
	assert(p.name_id == 2);
	assert(p.has_return_type);
	assert(p.return_type.class_name_id == 4);
}

// ── QualifiedNameTable parsing ─────────────────────────────────────

fn void test_parse_qn_table() {
	char[] data = {
		0x0a, 0x04, 0x08, 0x00, 0x18, 0x01,
		0x0a, 0x04, 0x08, 0x01, 0x10, 0x00
	};

	KmClass* km = mem::new(KmClass);
	*km = {};
	kotlin_metadata::parse_qualified_name_table(data, 0, data.len, km);

	assert(km.qn_count == 2);
	assert(km.qualified_names[0].short_name == 0);
	assert(km.qualified_names[0].parent == -1);
	assert(km.qualified_names[0].kind == 1);
	assert(km.qualified_names[1].short_name == 1);
	assert(km.qualified_names[1].parent == 0);
	assert(km.qualified_names[1].kind == 0);
	mem::free(km);
}

// ── TypeTable parsing ──────────────────────────────────────────────

fn void test_parse_type_table() {
	char[] data = { 0x0a, 0x02, 0x30, 0x05, 0x10, 0x00 };

	KmTypeTable tt = {};
	tt.first_nullable = -1;
	kotlin_metadata::parse_type_table(data, 0, data.len, &tt);

	assert(tt.type_count == 1);
	assert(tt.types[0].class_name_id == 5);
	assert(tt.first_nullable == 0);
}

// ── resolve_type_name / resolve_type_fqn ───────────────────────────

fn void test_resolve_type_name() {
	KmClass* km = mem::new(KmClass);
	*km = {};
	km.qn_count = 2;
	km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 1 };
	km.qualified_names[1] = { .short_name = 1, .parent = 0, .kind = 0 };

	String[3] d2 = { "kotlin", "String", "Int" };
	String name = kotlin_metadata::resolve_type_name(km, 1, &d2, 3);
	assert(name == "String");
	mem::free(km);
}

fn void test_resolve_type_fqn() {
	@pool() {
		KmClass* km = mem::new(KmClass);
		*km = {};
		km.qn_count = 2;
		km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 1 };
		km.qualified_names[1] = { .short_name = 1, .parent = 0, .kind = 0 };

		String[3] d2 = { "kotlin", "String", "Int" };
		String fqn = kotlin_metadata::resolve_type_fqn(km, 1, &d2, 3);
		assert(fqn == "kotlin.String");
		mem::free(km);
	};
}

fn void test_resolve_type_name_out_of_range() {
	KmClass* km = mem::new(KmClass);
	*km = {};
	String[1] d2 = { "x" };
	String name = kotlin_metadata::resolve_type_name(km, 5, &d2, 1);
	assert(name == "");
	mem::free(km);
}

// ── resolve_km_type_to_string ──────────────────────────────────────

fn void test_resolve_type_string_simple() {
	@pool() {
		KmClass* km = mem::new(KmClass);
		*km = {};
		km.qn_count = 1;
		km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 0 };

		String[1] d2 = { "String" };
		KmType t = { .class_name_id = 0, .type_parameter_id = -1 };
		String result = kotlin_metadata::resolve_km_type_to_string(&t, km, &d2, 1);
		assert(result == "String");
		mem::free(km);
	};
}

fn void test_resolve_type_string_nullable() {
	@pool() {
		KmClass* km = mem::new(KmClass);
		*km = {};
		km.qn_count = 1;
		km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 0 };

		String[1] d2 = { "Int" };
		KmType t = { .class_name_id = 0, .type_parameter_id = -1, .nullable = true };
		String result = kotlin_metadata::resolve_km_type_to_string(&t, km, &d2, 1);
		assert(result == "Int?");
		mem::free(km);
	};
}

fn void test_resolve_type_string_with_args() {
	@pool() {
		KmClass* km = mem::new(KmClass);
		*km = {};
		km.qn_count = 2;
		km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 0 };
		km.qualified_names[1] = { .short_name = 1, .parent = -1, .kind = 0 };

		String[2] d2 = { "List", "String" };
		KmType t = { .class_name_id = 0, .type_parameter_id = -1, .arg_count = 1 };
		t.arg_class_ids[0] = 1;
		t.arg_projections[0] = 2;

		String result = kotlin_metadata::resolve_km_type_to_string(&t, km, &d2, 2);
		assert(result == "List<String>");
		mem::free(km);
	};
}

fn void test_resolve_type_string_function_type() {
	@pool() {
		KmClass* km = mem::new(KmClass);
		*km = {};
		km.qn_count = 3;
		km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 0 };
		km.qualified_names[1] = { .short_name = 1, .parent = -1, .kind = 0 };
		km.qualified_names[2] = { .short_name = 2, .parent = -1, .kind = 0 };

		String[3] d2 = { "Function1", "Int", "String" };
		KmType t = { .class_name_id = 0, .type_parameter_id = -1, .arg_count = 2 };
		t.arg_class_ids[0] = 1;
		t.arg_class_ids[1] = 2;
		t.arg_projections[0] = 2;
		t.arg_projections[1] = 2;

		String result = kotlin_metadata::resolve_km_type_to_string(&t, km, &d2, 3);
		assert(result == "(Int) -> String");
		mem::free(km);
	};
}

fn void test_resolve_type_string_extension_function() {
	@pool() {
		KmClass* km = mem::new(KmClass);
		*km = {};
		km.qn_count = 3;
		km.qualified_names[0] = { .short_name = 0, .parent = -1, .kind = 0 };
		km.qualified_names[1] = { .short_name = 1, .parent = -1, .kind = 0 };
		km.qualified_names[2] = { .short_name = 2, .parent = -1, .kind = 0 };

		String[3] d2 = { "Function1", "String", "Unit" };
		KmType t = { .class_name_id = 0, .type_parameter_id = -1, .arg_count = 2, .has_extension_annotation = true };
		t.arg_class_ids[0] = 1;
		t.arg_class_ids[1] = 2;
		t.arg_projections[0] = 2;
		t.arg_projections[1] = 2;

		String result = kotlin_metadata::resolve_km_type_to_string(&t, km, &d2, 3);
		assert(result == "String.() -> Unit");
		mem::free(km);
	};
}

// ── parse_metadata integration (ClassInfo → KmClass) ───────────────

fn void test_parse_metadata_no_metadata() {
	ClassInfo info = {};
	info.has_kotlin_metadata = false;

	KmClass* km = mem::new(KmClass);
	*km = {};
	bool ok = kotlin_metadata::parse_metadata(&info, km);
	assert(!ok);
	mem::free(km);
}

fn void test_parse_metadata_empty_d1() {
	ClassInfo info = {};
	info.has_kotlin_metadata = true;
	info.metadata_d1_len = 0;
	info.metadata_kind = 1;

	KmClass* km = mem::new(KmClass);
	*km = {};
	bool ok = kotlin_metadata::parse_metadata(&info, km);
	assert(!ok);
	mem::free(km);
}

fn void test_parse_metadata_unknown_kind() {
	char[4] buf = { 0x08, 0x00, 0x18, 0x00 };
	ClassInfo info = {};
	info.has_kotlin_metadata = true;
	info.metadata_d1 = &buf;
	info.metadata_d1_len = 4;
	info.metadata_kind = 99;

	KmClass* km = mem::new(KmClass);
	*km = {};
	bool ok = kotlin_metadata::parse_metadata(&info, km);
	assert(!ok);
	mem::free(km);
}

// ── skip_field ─────────────────────────────────────────────────────

fn void test_skip_varint() {
	char[] data = { 0xAC, 0x02, 0x42 };
	usz pos = 0;
	kotlin_metadata::skip_field(data, &pos, kotlin_metadata::WIRE_VARINT);
	assert(pos == 2);
}

fn void test_skip_length_delimited() {
	char[] data = { 0x03, 0xAA, 0xBB, 0xCC, 0x42 };
	usz pos = 0;
	kotlin_metadata::skip_field(data, &pos, kotlin_metadata::WIRE_LENGTH_DELIMITED);
	assert(pos == 4);
}

fn void test_skip_32bit() {
	char[] data = { 0x01, 0x02, 0x03, 0x04, 0x42 };
	usz pos = 0;
	kotlin_metadata::skip_field(data, &pos, kotlin_metadata::WIRE_32BIT);
	assert(pos == 4);
}

fn void test_skip_64bit() {
	char[] data = { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x42 };
	usz pos = 0;
	kotlin_metadata::skip_field(data, &pos, kotlin_metadata::WIRE_64BIT);
	assert(pos == 8);
}

// ── is_function_type_name ──────────────────────────────────────────

fn void test_is_function_type() {
	assert(kotlin_metadata::is_function_type_name("Function0"));
	assert(kotlin_metadata::is_function_type_name("Function1"));
	assert(kotlin_metadata::is_function_type_name("Function22"));
	assert(kotlin_metadata::is_function_type_name("SuspendFunction0"));
	assert(!kotlin_metadata::is_function_type_name("String"));
	assert(!kotlin_metadata::is_function_type_name("Fun"));
}

// ── resolve_string ─────────────────────────────────────────────────

fn void test_resolve_string() {
	String[3] d2 = { "hello", "world", "test" };
	assert(kotlin_metadata::resolve_string(0, &d2, 3) == "hello");
	assert(kotlin_metadata::resolve_string(2, &d2, 3) == "test");
	assert(kotlin_metadata::resolve_string(-1, &d2, 3) == "");
	assert(kotlin_metadata::resolve_string(5, &d2, 3) == "");
}
