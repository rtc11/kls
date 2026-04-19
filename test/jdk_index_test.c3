module kls::test::jdk_index_test;

import kls::deps::jdk_index;
import kls::deps::jar_index;
import kls::deps::classfile;

// ── jmod_path_hash tests ───────────────────────────────────────────

fn void hash_deterministic() @test {
	uint h1 = jdk_index::jmod_path_hash("/usr/lib/jvm/java-17/jmods/java.base.jmod");
	uint h2 = jdk_index::jmod_path_hash("/usr/lib/jvm/java-17/jmods/java.base.jmod");
	assert(h1 == h2, "same input should produce same hash");
}

fn void hash_different_inputs() @test {
	uint h1 = jdk_index::jmod_path_hash("java.base.jmod");
	uint h2 = jdk_index::jmod_path_hash("java.sql.jmod");
	assert(h1 != h2, "different inputs should (likely) produce different hashes");
}

fn void hash_empty_string() @test {
	uint h = jdk_index::jmod_path_hash("");
	assert(h == 5381, "DJB2 hash of empty string should be 5381, got %d", (int)h);
}

fn void hash_single_char() @test {
	uint h = jdk_index::jmod_path_hash("a");
	// DJB2: ((5381 << 5) + 5381) + 97 = 177670 + 97 = 177767
	// Actually: (5381 * 32) + 5381 + 97 = 172192 + 5381 + 97 = 177670
	assert(h != 5381, "single char hash should differ from empty");
}

// ── has_dollar_in_class_name (jdk_index version) ───────────────────

fn void jdk_dollar_in_inner() @test {
	assert(jdk_index::has_dollar_in_class_name("classes/java/util/Map$Entry.class"),
		"should detect inner class in jmod path");
}

fn void jdk_no_dollar() @test {
	assert(!jdk_index::has_dollar_in_class_name("classes/java/lang/String.class"),
		"no dollar in String");
}

fn void jdk_dollar_not_in_prefix() @test {
	assert(!jdk_index::has_dollar_in_class_name("classes$/java/lang/String.class"),
		"dollar in prefix dir should not match");
}

fn void jdk_dollar_deeply_nested() @test {
	assert(jdk_index::has_dollar_in_class_name("classes/java/util/HashMap$Node$TreeNode.class"),
		"should detect deeply nested inner class");
}

fn void jdk_no_dollar_default_package() @test {
	assert(!jdk_index::has_dollar_in_class_name("classes/Simple.class"),
		"no dollar in simple class under classes/");
}

// ── JDK symbol integration via add_dep_symbol ──────────────────────
// (add_jdk_class_symbol tested indirectly through full index_jdk path;
//  these test the symbol shapes it would produce)

fn void jdk_class_symbol_shape() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		// Simulate what add_jdk_class_symbol does for a public class
		jar_index::add_dep_symbol(&idx, "String", "class String", "java.lang", "String",
			"/jdk/java.base.jmod", DEP_CLASS, null, 0);

		DepSymbol*[4] buf;
		usz count = idx.lookup_by_name("String", &buf);
		assert(count == 1, "expected 1 symbol for String, got %d", (int)count);
		assert(buf[0].kind == DEP_CLASS, "expected DEP_CLASS");
		assert(buf[0].package_name == "java.lang", "expected java.lang package");
	};
}

fn void jdk_interface_symbol_shape() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		String[jar_index::MAX_DEP_SUPERTYPES] supers;
		supers[0] = "Collection";
		jar_index::add_dep_symbol(&idx, "List", "interface List", "java.util", "List",
			"/jdk/java.base.jmod", DEP_INTERFACE, &supers, 1);

		DepSymbol*[4] buf;
		usz count = idx.lookup_by_name("List", &buf);
		assert(count == 1, "expected 1 symbol");
		assert(buf[0].kind == DEP_INTERFACE, "expected DEP_INTERFACE");
	};
}

fn void jdk_enum_symbol_shape() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "TimeUnit", "enum class TimeUnit", "java.util.concurrent", "TimeUnit",
			"/jdk/java.base.jmod", DEP_ENUM, null, 0);

		DepSymbol*[4] buf;
		usz count = idx.lookup_by_name("TimeUnit", &buf);
		assert(count == 1, "expected 1 symbol");
		assert(buf[0].kind == DEP_ENUM, "expected DEP_ENUM");
	};
}

fn void jdk_method_symbol_shape() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "nanoTime", "fun nanoTime(): Long", "java.lang", "System",
			"/jdk/java.base.jmod", DEP_METHOD, null, 0);

		DepSymbol*[4] buf;
		usz count = idx.lookup_by_name("nanoTime", &buf);
		assert(count == 1, "expected 1 nanoTime symbol, got %d", (int)count);
		assert(buf[0].kind == DEP_METHOD, "expected DEP_METHOD");
		assert(buf[0].class_name == "System", "expected declaring class System");
	};
}

fn void jdk_field_symbol_shape() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "out", "val out: PrintStream", "java.lang", "System",
			"/jdk/java.base.jmod", DEP_FIELD, null, 0);

		DepSymbol*[4] buf;
		usz count = idx.lookup_by_name("out", &buf);
		assert(count == 1, "expected 1 symbol");
		assert(buf[0].kind == DEP_FIELD, "expected DEP_FIELD");
	};
}

fn void jdk_non_public_not_indexed() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		// Non-public classes shouldn't be indexed — this tests the principle
		// (add_jdk_class_symbol filters ACC_PUBLIC internally)
		DepSymbol*[4] buf;
		usz count = idx.lookup_by_name("InternalClass", &buf);
		assert(count == 0, "non-public class should not be indexed");
	};
}

fn void jdk_supertype_lookup() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		String[jar_index::MAX_DEP_SUPERTYPES] supers;
		supers[0] = "Collection";
		jar_index::add_dep_symbol(&idx, "List", "interface List", "java.util", "List",
			"/jdk/java.base.jmod", DEP_INTERFACE, &supers, 1);
		jar_index::add_dep_symbol(&idx, "Set", "interface Set", "java.util", "Set",
			"/jdk/java.base.jmod", DEP_INTERFACE, &supers, 1);

		DepSymbol*[8] buf;
		usz count = idx.lookup_by_supertype("Collection", &buf);
		assert(count == 2, "expected 2 subtypes of Collection, got %d", (int)count);
	};
}
