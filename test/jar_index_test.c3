module kls::test::jar_index_test;

import kls::deps::jar_index;
import kls::deps::classfile;

// ── has_dollar_in_class_name tests ─────────────────────────────────

fn void dollar_in_inner_class() @test {
	// Named nested classes are now indexed (e.g. ProcessingExceptionHandler$Response).
	assert(!jar_index::has_dollar_in_class_name("com/example/Outer$Inner.class"), "named nested class should be allowed through");
}

fn void dollar_not_in_simple_class() @test {
	assert(!jar_index::has_dollar_in_class_name("com/example/MyClass.class"), "no dollar in simple class");
}

fn void dollar_in_nested_inner() @test {
	// Multi-level named nesting still allowed (segment after first $ is alphabetic).
	assert(!jar_index::has_dollar_in_class_name("com/Outer$Mid$Inner.class"), "named nested chain should be allowed");
}

fn void dollar_no_package() @test {
	assert(!jar_index::has_dollar_in_class_name("Outer$Inner.class"), "named nested without package should be allowed");
}

fn void dollar_anonymous_class_skipped() @test {
	assert(jar_index::has_dollar_in_class_name("com/example/Foo$1.class"), "anonymous classes (digit suffix) should be skipped");
}

fn void dollar_local_synthetic_skipped() @test {
	assert(jar_index::has_dollar_in_class_name("com/example/Foo$12.class"), "multi-digit anonymous should be skipped");
}

fn void no_dollar_no_package() @test {
	assert(!jar_index::has_dollar_in_class_name("MyClass.class"), "no dollar in root class");
}

fn void dollar_not_in_directory_name() @test {
	// '$' in directory part, not class name
	assert(!jar_index::has_dollar_in_class_name("com/$special/MyClass.class"),
		"should not detect dollar in directory part");
}

// ── dep_kind_to_completion_kind tests ──────────────────────────────

fn void dep_kind_class() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_CLASS) == 7, "class -> 7");
}

fn void dep_kind_interface() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_INTERFACE) == 8, "interface -> 8");
}

fn void dep_kind_enum() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_ENUM) == 13, "enum -> 13");
}

fn void dep_kind_method() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_METHOD) == 2, "method -> 2");
}

fn void dep_kind_field() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_FIELD) == 5, "field -> 5");
}

fn void dep_kind_annotation() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_ANNOTATION) == 7, "annotation -> 7");
}

fn void dep_kind_object() @test {
	assert(jar_index::dep_kind_to_completion_kind(DEP_OBJECT) == 9, "object -> 9");
}

// ── DependencyIndex lookup tests ───────────────────────────────────

fn void lookup_by_name_found() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "String", "class String", "kotlin", "String",
			"/test.jar", DEP_CLASS, null, 0);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_name("String", &buf);
		assert(count == 1, "expected 1 match, got %d", (int)count);
		assert(buf[0].name == "String", "expected name 'String'");
		assert(buf[0].kind == DEP_CLASS, "expected DEP_CLASS");
	};
}

fn void lookup_by_name_not_found() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "String", "class String", "kotlin", "String",
			"/test.jar", DEP_CLASS, null, 0);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_name("Integer", &buf);
		assert(count == 0, "expected 0 matches");
	};
}

fn void lookup_by_name_multiple() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		// Two symbols named "of" (different classes)
		jar_index::add_dep_symbol(&idx, "of", "fun List.of()", "kotlin.collections", "List",
			"/test.jar", DEP_METHOD, null, 0);
		jar_index::add_dep_symbol(&idx, "of", "fun Map.of()", "kotlin.collections", "Map",
			"/test.jar", DEP_METHOD, null, 0);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_name("of", &buf);
		assert(count == 2, "expected 2 matches, got %d", (int)count);
	};
}

fn void lookup_by_prefix() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "String", "class String", "kotlin", "String",
			"/test.jar", DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&idx, "StringBuilder", "class StringBuilder", "kotlin.text", "StringBuilder",
			"/test.jar", DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&idx, "Int", "class Int", "kotlin", "Int",
			"/test.jar", DEP_CLASS, null, 0);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_prefix("Str", &buf);
		assert(count == 2, "expected 2 prefix matches, got %d", (int)count);
	};
}

fn void lookup_by_prefix_empty() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_prefix("", &buf);
		assert(count == 0, "empty prefix should return 0");
	};
}

fn void lookup_by_supertype() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		String[jar_index::MAX_DEP_SUPERTYPES] supers;
		supers[0] = "Collection";
		jar_index::add_dep_symbol(&idx, "List", "interface List", "kotlin.collections", "List",
			"/test.jar", DEP_INTERFACE, &supers, 1);
		jar_index::add_dep_symbol(&idx, "Set", "interface Set", "kotlin.collections", "Set",
			"/test.jar", DEP_INTERFACE, &supers, 1);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_supertype("Collection", &buf);
		assert(count == 2, "expected 2 subtypes of Collection, got %d", (int)count);
	};
}

fn void lookup_by_supertype_none() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "String", "class String", "kotlin", "String",
			"/test.jar", DEP_CLASS, null, 0);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_supertype("Serializable", &buf);
		assert(count == 0, "expected 0 subtypes");
	};
}

fn void lookup_empty_buffer() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "String", "class String", "kotlin", "String",
			"/test.jar", DEP_CLASS, null, 0);

		DepSymbol*[] empty_buf;
		usz count = idx.lookup_by_name("String", empty_buf);
		assert(count == 0, "zero-length buffer should return 0");
	};
}
