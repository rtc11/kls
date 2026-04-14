module kls::classfile_test @test;

import kls::deps::classfile;

// ── descriptor_to_kotlin_type tests ────────────────────────────────

fn void test_descriptor_primitive_int() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("I", &ds);
	assert(ds.str_view() == "Int");
}

fn void test_descriptor_primitive_long() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("J", &ds);
	assert(ds.str_view() == "Long");
}

fn void test_descriptor_primitive_boolean() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("Z", &ds);
	assert(ds.str_view() == "Boolean");
}

fn void test_descriptor_primitive_double() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("D", &ds);
	assert(ds.str_view() == "Double");
}

fn void test_descriptor_primitive_float() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("F", &ds);
	assert(ds.str_view() == "Float");
}

fn void test_descriptor_primitive_byte() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("B", &ds);
	assert(ds.str_view() == "Byte");
}

fn void test_descriptor_primitive_char() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("C", &ds);
	assert(ds.str_view() == "Char");
}

fn void test_descriptor_primitive_short() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("S", &ds);
	assert(ds.str_view() == "Short");
}

fn void test_descriptor_void() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("V", &ds);
	assert(ds.str_view() == "Unit");
}

fn void test_descriptor_string() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("Ljava/lang/String;", &ds);
	assert(ds.str_view() == "String");
}

fn void test_descriptor_object() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("Ljava/lang/Object;", &ds);
	assert(ds.str_view() == "Any");
}

fn void test_descriptor_custom_class() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("Lcom/example/MyClass;", &ds);
	assert(ds.str_view() == "MyClass");
}

fn void test_descriptor_int_array() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("[I", &ds);
	assert(ds.str_view() == "IntArray");
}

fn void test_descriptor_byte_array() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("[B", &ds);
	assert(ds.str_view() == "ByteArray");
}

fn void test_descriptor_object_array() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("[Ljava/lang/String;", &ds);
	assert(ds.str_view() == "Array<String>");
}

fn void test_descriptor_list() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("Ljava/util/List;", &ds);
	assert(ds.str_view() == "List");
}

fn void test_descriptor_map() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("Ljava/util/Map;", &ds);
	assert(ds.str_view() == "Map");
}

fn void test_descriptor_empty() {
	DString ds;
	ds.tinit();
	classfile::descriptor_to_kotlin_type("", &ds);
	assert(ds.str_view() == "");
}

// ── method_descriptor_to_kotlin tests ──────────────────────────────

fn void test_method_void_no_args() {
	DString ds;
	ds.tinit();
	classfile::method_descriptor_to_kotlin("()V", &ds);
	assert(ds.str_view() == "(): Unit");
}

fn void test_method_int_arg_string_return() {
	DString ds;
	ds.tinit();
	classfile::method_descriptor_to_kotlin("(I)Ljava/lang/String;", &ds);
	assert(ds.str_view() == "(Int): String");
}

fn void test_method_multiple_args() {
	DString ds;
	ds.tinit();
	classfile::method_descriptor_to_kotlin("(ILjava/lang/String;Z)V", &ds);
	assert(ds.str_view() == "(Int, String, Boolean): Unit");
}

fn void test_method_no_args_int_return() {
	DString ds;
	ds.tinit();
	classfile::method_descriptor_to_kotlin("()I", &ds);
	assert(ds.str_view() == "(): Int");
}

fn void test_method_array_arg() {
	DString ds;
	ds.tinit();
	classfile::method_descriptor_to_kotlin("([I)V", &ds);
	assert(ds.str_view() == "(IntArray): Unit");
}

fn void test_method_empty() {
	DString ds;
	ds.tinit();
	classfile::method_descriptor_to_kotlin("", &ds);
	assert(ds.str_view() == "");
}

// ── jvm_name_to_package tests ──────────────────────────────────────

fn void test_package_basic() {
	assert(classfile::jvm_name_to_package("kotlin/collections/CollectionsKt") == "kotlin.collections");
}

fn void test_package_deep() {
	assert(classfile::jvm_name_to_package("org/jetbrains/kotlin/utils/Helper") == "org.jetbrains.kotlin.utils");
}

fn void test_package_no_slash() {
	assert(classfile::jvm_name_to_package("MyClass") == "");
}

fn void test_package_empty() {
	assert(classfile::jvm_name_to_package("") == "");
}

fn void test_package_single_level() {
	assert(classfile::jvm_name_to_package("kotlin/Unit") == "kotlin");
}

// ── jvm_name_to_simple tests ───────────────────────────────────────

fn void test_simple_basic() {
	assert(classfile::jvm_name_to_simple("kotlin/collections/CollectionsKt") == "CollectionsKt");
}

fn void test_simple_no_slash() {
	assert(classfile::jvm_name_to_simple("MyClass") == "MyClass");
}

fn void test_simple_empty() {
	assert(classfile::jvm_name_to_simple("") == "");
}

fn void test_simple_single_level() {
	assert(classfile::jvm_name_to_simple("kotlin/Unit") == "Unit");
}

// ── append_short_class_name tests ──────────────────────────────────

fn void test_short_name_java_lang() {
	DString ds;
	ds.tinit();
	classfile::append_short_class_name("java/lang/String", &ds);
	assert(ds.str_view() == "String");
}

fn void test_short_name_kotlin_unit() {
	DString ds;
	ds.tinit();
	classfile::append_short_class_name("kotlin/Unit", &ds);
	assert(ds.str_view() == "Unit");
}

fn void test_short_name_integer() {
	DString ds;
	ds.tinit();
	classfile::append_short_class_name("java/lang/Integer", &ds);
	assert(ds.str_view() == "Int");
}

fn void test_short_name_throwable() {
	DString ds;
	ds.tinit();
	classfile::append_short_class_name("java/lang/Throwable", &ds);
	assert(ds.str_view() == "Throwable");
}

fn void test_short_name_custom() {
	DString ds;
	ds.tinit();
	classfile::append_short_class_name("com/example/MyService", &ds);
	assert(ds.str_view() == "MyService");
}

fn void test_short_name_inner_class() {
	DString ds;
	ds.tinit();
	classfile::append_short_class_name("com/example/Outer$Inner", &ds);
	assert(ds.str_view() == "Outer.Inner");
}

// ── parse_class minimal test ───────────────────────────────────────

/**
 * Build a minimal valid .class file in memory and parse it.
 * The file has: magic, version, 5 CP entries (including class/utf8),
 * access flags = PUBLIC, this_class, super_class, 0 interfaces,
 * 0 fields, 0 methods, 0 attributes.
 */
fn void test_parse_class_minimal() {
	// Constant pool:
	// #1: UTF8 "TestClass"
	// #2: Class #1
	// #3: UTF8 "java/lang/Object"
	// #4: Class #3
	char[256] buf;
	usz pos = 0;

	// Magic
	buf[pos] = 0xCA; pos++;
	buf[pos] = 0xFE; pos++;
	buf[pos] = 0xBA; pos++;
	buf[pos] = 0xBE; pos++;

	// Minor version
	buf[pos] = 0; pos++;
	buf[pos] = 0; pos++;

	// Major version (52 = Java 8)
	buf[pos] = 0; pos++;
	buf[pos] = 52; pos++;

	// Constant pool count = 5 (entries 1-4)
	buf[pos] = 0; pos++;
	buf[pos] = 5; pos++;

	// #1: UTF8 "TestClass"
	buf[pos] = 1; pos++;  // tag
	buf[pos] = 0; pos++;  // length high
	buf[pos] = 9; pos++;  // length low
	String name = "TestClass";
	for (usz i = 0; i < name.len; i++) {
		buf[pos] = name[i]; pos++;
	}

	// #2: Class #1
	buf[pos] = 7; pos++;  // tag = CONSTANT_CLASS
	buf[pos] = 0; pos++;  // name_index high
	buf[pos] = 1; pos++;  // name_index low

	// #3: UTF8 "java/lang/Object"
	buf[pos] = 1; pos++;  // tag
	buf[pos] = 0; pos++;  // length high
	buf[pos] = 16; pos++; // length low
	String super_name = "java/lang/Object";
	for (usz i = 0; i < super_name.len; i++) {
		buf[pos] = super_name[i]; pos++;
	}

	// #4: Class #3
	buf[pos] = 7; pos++;  // tag = CONSTANT_CLASS
	buf[pos] = 0; pos++;  // name_index high
	buf[pos] = 3; pos++;  // name_index low

	// Access flags: ACC_PUBLIC | ACC_SUPER
	buf[pos] = 0; pos++;
	buf[pos] = 0x21; pos++;

	// this_class = #2
	buf[pos] = 0; pos++;
	buf[pos] = 2; pos++;

	// super_class = #4
	buf[pos] = 0; pos++;
	buf[pos] = 4; pos++;

	// interfaces_count = 0
	buf[pos] = 0; pos++;
	buf[pos] = 0; pos++;

	// fields_count = 0
	buf[pos] = 0; pos++;
	buf[pos] = 0; pos++;

	// methods_count = 0
	buf[pos] = 0; pos++;
	buf[pos] = 0; pos++;

	// attributes_count = 0
	buf[pos] = 0; pos++;
	buf[pos] = 0; pos++;

	ClassInfo info;
	classfile::parse_class(buf[:pos], &info)!!;

	assert(info.class_name == "TestClass", "expected 'TestClass', got '%s'", info.class_name);
	assert(info.super_name == "java/lang/Object", "expected 'java/lang/Object', got '%s'", info.super_name);
	assert(info.access_flags & classfile::ACC_PUBLIC != 0);
	assert(info.interface_count == 0);
	assert(info.method_count == 0);
	assert(info.field_count == 0);
}

fn void test_parse_class_invalid_magic() {
	char[10] buf = { 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 52, 0, 1 };
	ClassInfo info;
	assert(@catch(classfile::parse_class(&buf, &info)));
}

fn void test_parse_class_truncated() {
	char[4] buf = { 0xCA, 0xFE, 0xBA, 0xBE };
	ClassInfo info;
	assert(@catch(classfile::parse_class(&buf, &info)));
}

// ── read_u16/read_u32 tests ───────────────────────────────────────

fn void test_read_u16_basic() {
	char[2] buf = { 0x01, 0x23 };
	usz pos = 0;
	ushort val = classfile::read_u16(&buf, &pos)!!;
	assert(val == 0x0123);
	assert(pos == 2);
}

fn void test_read_u32_basic() {
	char[4] buf = { 0xCA, 0xFE, 0xBA, 0xBE };
	usz pos = 0;
	uint val = classfile::read_u32(&buf, &pos)!!;
	assert(val == 0xCAFEBABE);
	assert(pos == 4);
}

fn void test_read_u16_truncated() {
	char[1] buf = { 0x01 };
	usz pos = 0;
	assert(@catch(classfile::read_u16(&buf, &pos)));
}

fn void test_read_u32_truncated() {
	char[2] buf = { 0x01, 0x02 };
	usz pos = 0;
	assert(@catch(classfile::read_u32(&buf, &pos)));
}
