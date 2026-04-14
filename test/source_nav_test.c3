module kls::test::source_nav_test;

import std::collections::object;
import kls::deps::source_nav;
import kls::deps::jar_index;

// ── Test: build_source_candidates ──────────────────────────────────

fn void test_candidates_basic_class() @test {
	@pool() {
		String[8] candidates;
		usz count = source_nav::build_source_candidates("kotlin.collections", "ArrayList", &candidates, 8);

		assert(count == 2, "expected 2 candidates, got %d", (int)count);
		assert(candidates[0] == "kotlin/collections/ArrayList.kt", "expected .kt candidate, got '%s'", candidates[0]);
		assert(candidates[1] == "kotlin/collections/ArrayList.java", "expected .java candidate, got '%s'", candidates[1]);
	};
}

fn void test_candidates_kt_facade() @test {
	@pool() {
		String[8] candidates;
		usz count = source_nav::build_source_candidates("kotlin.collections", "CollectionsKt", &candidates, 8);

		assert(count == 4, "expected 4 candidates for Kt facade, got %d", (int)count);
		assert(candidates[0] == "kotlin/collections/CollectionsKt.kt", "got '%s'", candidates[0]);
		assert(candidates[1] == "kotlin/collections/CollectionsKt.java", "got '%s'", candidates[1]);
		assert(candidates[2] == "kotlin/collections/Collections.kt", "got '%s'", candidates[2]);
		assert(candidates[3] == "kotlin/collections/_Collections.kt", "got '%s'", candidates[3]);
	};
}

fn void test_candidates_empty_package() @test {
	@pool() {
		String[8] candidates;
		usz count = source_nav::build_source_candidates("", "Main", &candidates, 8);

		assert(count == 2, "expected 2 candidates, got %d", (int)count);
		assert(candidates[0] == "Main.kt", "got '%s'", candidates[0]);
		assert(candidates[1] == "Main.java", "got '%s'", candidates[1]);
	};
}

fn void test_candidates_empty_class_name() @test {
	@pool() {
		String[8] candidates;
		usz count = source_nav::build_source_candidates("kotlin", "", &candidates, 8);
		assert(count == 0, "expected 0 candidates for empty class name");
	};
}

fn void test_candidates_deep_package() @test {
	@pool() {
		String[8] candidates;
		usz count = source_nav::build_source_candidates("com.example.app.ui", "MainScreen", &candidates, 8);

		assert(count == 2, "expected 2 candidates, got %d", (int)count);
		assert(candidates[0] == "com/example/app/ui/MainScreen.kt", "got '%s'", candidates[0]);
		assert(candidates[1] == "com/example/app/ui/MainScreen.java", "got '%s'", candidates[1]);
	};
}

fn void test_candidates_max_limit() @test {
	@pool() {
		String[2] candidates;
		usz count = source_nav::build_source_candidates("kotlin.collections", "CollectionsKt", &candidates, 2);

		// Should be capped at 2 even though Kt facade generates 4
		assert(count == 2, "expected 2 candidates (capped), got %d", (int)count);
	};
}

// ── Test: simple_hash ──────────────────────────────────────────────

fn void test_hash_deterministic() @test {
	uint h1 = source_nav::simple_hash("/path/to/jar.jar");
	uint h2 = source_nav::simple_hash("/path/to/jar.jar");
	assert(h1 == h2, "hash should be deterministic");
}

fn void test_hash_different_inputs() @test {
	uint h1 = source_nav::simple_hash("/path/to/a.jar");
	uint h2 = source_nav::simple_hash("/path/to/b.jar");
	assert(h1 != h2, "different inputs should produce different hashes");
}

fn void test_hash_empty() @test {
	uint h = source_nav::simple_hash("");
	assert(h == 5381, "empty string hash should be 5381 (djb2 initial)");
}

// ── Test: find_symbol_position ─────────────────────────────────────

fn void test_find_fun_position() @test {
	@pool() {
		String content = "package kotlin.collections\n\nfun listOf(): List<Any> = emptyList()";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "listOf", DEP_METHOD, &line, &col);

		assert(found, "should find 'listOf' function");
		assert(line == 2, "expected line 2, got %d", (int)line);
		assert(col == 4, "expected col 4, got %d", (int)col);
	};
}

fn void test_find_class_position() @test {
	@pool() {
		String content = "package kotlin\n\nopen class ArrayList<E> : MutableList<E> {\n}";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "ArrayList", DEP_CLASS, &line, &col);

		assert(found, "should find 'ArrayList' class");
		assert(line == 2, "expected line 2, got %d", (int)line);
		assert(col == 11, "expected col 11, got %d", (int)col);
	};
}

fn void test_find_interface_position() @test {
	@pool() {
		String content = "package kotlin.collections\n\ninterface MutableList<E> : List<E> {}";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "MutableList", DEP_INTERFACE, &line, &col);

		assert(found, "should find 'MutableList' interface");
		assert(line == 2, "expected line 2, got %d", (int)line);
		assert(col == 10, "expected col 10, got %d", (int)col);
	};
}

fn void test_find_val_position() @test {
	@pool() {
		String content = "package kotlin\n\nval MAX_VALUE: Int = 2147483647";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "MAX_VALUE", DEP_FIELD, &line, &col);

		assert(found, "should find 'MAX_VALUE' val");
		assert(line == 2, "expected line 2, got %d", (int)line);
		assert(col == 4, "expected col 4, got %d", (int)col);
	};
}

fn void test_find_symbol_fallback_to_identifier() @test {
	@pool() {
		// No keyword before "helper", but identifier appears
		String content = "package test\n\nhelper()";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "helper", DEP_METHOD, &line, &col);

		assert(found, "should find 'helper' as fallback identifier");
		assert(line == 2, "expected line 2, got %d", (int)line);
		assert(col == 0, "expected col 0, got %d", (int)col);
	};
}

fn void test_find_symbol_not_found() @test {
	@pool() {
		String content = "package test\n\nfun main() {}";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "nonexistent", DEP_METHOD, &line, &col);

		assert(!found, "should not find nonexistent symbol");
	};
}

fn void test_find_symbol_empty_content() @test {
	@pool() {
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position("", "test", DEP_METHOD, &line, &col);
		assert(!found, "should not find in empty content");
	};
}

fn void test_find_symbol_empty_name() @test {
	@pool() {
		String content = "fun test() {}";
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "", DEP_METHOD, &line, &col);
		assert(!found, "should not find empty name");
	};
}

fn void test_find_fun_skips_non_matching_keyword() @test {
	@pool() {
		// "process" appears after "val" (field context) then after "fun" (method context)
		String content = "val process: Int = 1\nfun process() {}";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "process", DEP_METHOD, &line, &col);

		assert(found, "should find 'process' function");
		assert(line == 1, "expected line 1 (fun), got %d", (int)line);
		assert(col == 4, "expected col 4, got %d", (int)col);
	};
}

fn void test_find_class_skips_fun() @test {
	@pool() {
		// "Item" appears as function parameter then as class declaration
		String content = "fun getItem(): Item = Item()\nclass Item(val name: String)";

		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "Item", DEP_CLASS, &line, &col);

		assert(found, "should find 'Item' class");
		assert(line == 1, "expected line 1 (class), got %d", (int)line);
		assert(col == 6, "expected col 6, got %d", (int)col);
	};
}

// ── Test: derive_source_jar_path (non-existent files) ──────────────

fn void test_derive_source_jar_nonexistent() @test {
	@pool() {
		String result = source_nav::derive_source_jar_path("/nonexistent/path/lib-1.0.jar");
		assert(result.len == 0, "should return empty for nonexistent source jar");
	};
}

fn void test_derive_source_jar_not_jar() @test {
	@pool() {
		String result = source_nav::derive_source_jar_path("/some/path/lib.zip");
		assert(result.len == 0, "should return empty for non-.jar path");
	};
}

// ── Test: get_cache_dir ────────────────────────────────────────────

fn void test_cache_dir_not_empty() @test {
	@pool() {
		String dir = source_nav::get_cache_dir();
		assert(dir.len > 0, "cache dir should not be empty");
		assert(dir.ends_with("kls-sources"), "cache dir should end with kls-sources, got '%s'", dir);
	};
}

// ── Test: find_definition_in_deps with null/empty index ────────────

fn void test_find_def_null_index() @test {
	@pool() {
		Object* result = source_nav::find_definition_in_deps(null, "listOf", true);
		assert(result == null, "should return null for null index");
	};
}

fn void test_find_def_empty_index() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		Object* result = source_nav::find_definition_in_deps(&idx, "listOf", true);
		assert(result == null, "should return null when symbol not found");
	};
}

fn void test_find_def_uninitialized_index() @test {
	@pool() {
		DependencyIndex idx;
		idx.initialized = false;

		Object* result = source_nav::find_definition_in_deps(&idx, "listOf", true);
		assert(result == null, "should return null for uninitialized index");
	};
}
