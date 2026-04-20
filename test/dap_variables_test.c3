module kls::test::dap_variables_test;

import kls::dap::variables;

// ── sig_to_tag ─────────────────────────────────────────────────────

fn void sig_to_tag_primitives() @test {
	assert(variables::sig_to_tag("I") == 'I', "Int");
	assert(variables::sig_to_tag("J") == 'J', "Long");
	assert(variables::sig_to_tag("Z") == 'Z', "Boolean");
	assert(variables::sig_to_tag("B") == 'B', "Byte");
	assert(variables::sig_to_tag("C") == 'C', "Char");
	assert(variables::sig_to_tag("S") == 'S', "Short");
	assert(variables::sig_to_tag("F") == 'F', "Float");
	assert(variables::sig_to_tag("D") == 'D', "Double");
}

fn void sig_to_tag_string() @test {
	assert(variables::sig_to_tag("Ljava/lang/String;") == 's', "String -> 's'");
}

fn void sig_to_tag_object() @test {
	assert(variables::sig_to_tag("Lcom/example/Foo;") == 'L', "Object -> 'L'");
}

fn void sig_to_tag_array() @test {
	assert(variables::sig_to_tag("[I") == '[', "int[] -> '['");
	assert(variables::sig_to_tag("[Ljava/lang/String;") == '[', "String[] -> '['");
}

fn void sig_to_tag_empty() @test {
	assert(variables::sig_to_tag("") == 'L', "empty -> 'L' default");
}

// ── tag_value_size ─────────────────────────────────────────────────

fn void tag_value_sizes() @test {
	assert(variables::tag_value_size('B') == 1, "byte=1");
	assert(variables::tag_value_size('Z') == 1, "boolean=1");
	assert(variables::tag_value_size('C') == 2, "char=2");
	assert(variables::tag_value_size('S') == 2, "short=2");
	assert(variables::tag_value_size('I') == 4, "int=4");
	assert(variables::tag_value_size('F') == 4, "float=4");
	assert(variables::tag_value_size('J') == 8, "long=8");
	assert(variables::tag_value_size('D') == 8, "double=8");
	assert(variables::tag_value_size('L') == 8, "object=8");
	assert(variables::tag_value_size('[') == 8, "array=8");
	assert(variables::tag_value_size('s') == 8, "string=8");
	assert(variables::tag_value_size('V') == 0, "void=0");
}

// ── sig_to_type_name ───────────────────────────────────────────────

fn void sig_to_type_name_primitives() @test {
	assert(variables::sig_to_type_name("I") == "Int");
	assert(variables::sig_to_type_name("J") == "Long");
	assert(variables::sig_to_type_name("Z") == "Boolean");
	assert(variables::sig_to_type_name("B") == "Byte");
	assert(variables::sig_to_type_name("C") == "Char");
	assert(variables::sig_to_type_name("S") == "Short");
	assert(variables::sig_to_type_name("F") == "Float");
	assert(variables::sig_to_type_name("D") == "Double");
	assert(variables::sig_to_type_name("V") == "Void");
}

fn void sig_to_type_name_string() @test {
	assert(variables::sig_to_type_name("Ljava/lang/String;") == "String");
}

fn void sig_to_type_name_class() @test {
	String name = variables::sig_to_type_name("Lcom/example/Foo;");
	assert(name == "Foo", "expected Foo, got: %s", name);
}

fn void sig_to_type_name_nested_class() @test {
	String name = variables::sig_to_type_name("Lcom/example/deep/Bar;");
	assert(name == "Bar", "expected Bar, got: %s", name);
}

fn void sig_to_type_name_array() @test {
	assert(variables::sig_to_type_name("[I") == "Array");
}

fn void sig_to_type_name_empty() @test {
	assert(variables::sig_to_type_name("") == "Unknown");
}

// ── tag_to_type_name ───────────────────────────────────────────────

fn void tag_to_type_name_all() @test {
	assert(variables::tag_to_type_name('B') == "Byte");
	assert(variables::tag_to_type_name('C') == "Char");
	assert(variables::tag_to_type_name('D') == "Double");
	assert(variables::tag_to_type_name('F') == "Float");
	assert(variables::tag_to_type_name('I') == "Int");
	assert(variables::tag_to_type_name('J') == "Long");
	assert(variables::tag_to_type_name('S') == "Short");
	assert(variables::tag_to_type_name('Z') == "Boolean");
	assert(variables::tag_to_type_name('s') == "String");
	assert(variables::tag_to_type_name('L') == "Object");
	assert(variables::tag_to_type_name('[') == "Array");
	assert(variables::tag_to_type_name('V') == "Void");
	assert(variables::tag_to_type_name('?') == "Unknown");
}
