module kls::classpath_test @test;

import kls::deps::classpath;
import kls::server;

// ── find_substring tests ───────────────────────────────────────────

fn void test_find_substring_basic() {
	usz idx = classpath::find_substring("hello world", "world")!!;
	assert(idx == 6);
}

fn void test_find_substring_at_start() {
	usz idx = classpath::find_substring("hello world", "hello")!!;
	assert(idx == 0);
}

fn void test_find_substring_not_found() {
	usz? result = classpath::find_substring("hello world", "xyz");
	assert(@catch(result));
}

fn void test_find_substring_empty_needle() {
	usz? result = classpath::find_substring("hello", "");
	assert(@catch(result));
}

fn void test_find_substring_needle_too_long() {
	usz? result = classpath::find_substring("hi", "hello world");
	assert(@catch(result));
}

fn void test_find_substring_files_2_1_pattern() {
	String path = "/home/user/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/1.9.0/abc123/kotlin-stdlib-1.9.0.jar";
	usz idx = classpath::find_substring(path, "files-2.1/")!!;
	assert(idx == 36);
}

fn void test_find_substring_m2_repository_pattern() {
	String path = "/home/user/.m2/repository/org/jetbrains/kotlin/kotlin-stdlib/1.9.0/kotlin-stdlib-1.9.0.jar";
	usz idx = classpath::find_substring(path, ".m2/repository/")!!;
	assert(idx == 11);
}

// ── split_path_parts tests ─────────────────────────────────────────

fn void test_split_path_parts_basic() {
	String[4] parts;
	usz count = classpath::split_path_parts("a/b/c/d", &parts, 4);
	assert(count == 4);
	assert(parts[0] == "a");
	assert(parts[1] == "b");
	assert(parts[2] == "c");
	assert(parts[3] == "d");
}

fn void test_split_path_parts_max_limit() {
	String[2] parts;
	usz count = classpath::split_path_parts("a/b/c/d", &parts, 2);
	assert(count == 2);
	assert(parts[0] == "a");
	assert(parts[1] == "b");
}

fn void test_split_path_parts_single() {
	String[4] parts;
	usz count = classpath::split_path_parts("hello", &parts, 4);
	assert(count == 1);
	assert(parts[0] == "hello");
}

fn void test_split_path_parts_empty() {
	String[4] parts;
	usz count = classpath::split_path_parts("", &parts, 4);
	assert(count == 0);
}

fn void test_split_path_parts_trailing_slash() {
	String[4] parts;
	usz count = classpath::split_path_parts("a/b/", &parts, 4);
	assert(count == 2);
	assert(parts[0] == "a");
	assert(parts[1] == "b");
}

// ── extract_gav_from_path tests ────────────────────────────────────

fn void test_extract_gav_gradle_cache() {
	String group = "";
	String artifact = "";
	String version = "";
	classpath::extract_gav_from_path(
		"/home/user/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/1.9.0/abc123/kotlin-stdlib-1.9.0.jar",
		&group, &artifact, &version
	);
	assert(group == "org.jetbrains.kotlin", "expected org.jetbrains.kotlin, got '%s'", group);
	assert(artifact == "kotlin-stdlib", "expected kotlin-stdlib, got '%s'", artifact);
	assert(version == "1.9.0", "expected 1.9.0, got '%s'", version);
}

fn void test_extract_gav_maven_cache() {
	String group = "";
	String artifact = "";
	String version = "";
	classpath::extract_gav_from_path(
		"/home/user/.m2/repository/org/jetbrains/kotlin/kotlin-stdlib/1.9.0/kotlin-stdlib-1.9.0.jar",
		&group, &artifact, &version
	);
	assert(artifact == "kotlin-stdlib", "expected kotlin-stdlib, got '%s'", artifact);
	assert(version == "1.9.0", "expected 1.9.0, got '%s'", version);
	// Group should be "org.jetbrains.kotlin" (path segments joined with dots)
	assert(group == "org.jetbrains.kotlin", "expected org.jetbrains.kotlin, got '%s'", group);
}

fn void test_extract_gav_unknown_path() {
	String group = "";
	String artifact = "";
	String version = "";
	classpath::extract_gav_from_path(
		"/some/random/path/to/lib.jar",
		&group, &artifact, &version
	);
	assert(group == "");
	assert(artifact == "");
	assert(version == "");
}

// ── parse_gradle_output tests ──────────────────────────────────────

fn void test_parse_gradle_output_basic() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
		"KLS_JAR:/path/to/lib1.jar\nKLS_JAR:/path/to/lib2.jar\n"
	);
	assert(cp.jar_count == 2, "expected 2, got %d", (int)cp.jar_count);
	assert(cp.jars[0].path == "/path/to/lib1.jar");
	assert(cp.jars[1].path == "/path/to/lib2.jar");
}

fn void test_parse_gradle_output_with_noise() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
		"Some gradle log line\nKLS_JAR:/path/to/lib.jar\nAnother log line\n"
	);
	assert(cp.jar_count == 1);
	assert(cp.jars[0].path == "/path/to/lib.jar");
}

fn void test_parse_gradle_output_empty() {
	Classpath cp;
	cp.init();

	classpath::parse_gradle_output(&cp, "");
	assert(cp.jar_count == 0);
}

fn void test_parse_gradle_output_no_jars() {
	Classpath cp;
	cp.init();

	classpath::parse_gradle_output(&cp, "Just some output\nwith no jars\n");
	assert(cp.jar_count == 0);
}

fn void test_parse_gradle_output_crlf() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
		"KLS_JAR:/path/to/lib.jar\r\n"
	);
	assert(cp.jar_count == 1);
	assert(cp.jars[0].path == "/path/to/lib.jar");
}

// ── parse_maven_output tests ───────────────────────────────────────

fn void test_parse_maven_output_basic() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_maven_output(&cp,
		"/path/to/lib1.jar:/path/to/lib2.jar\n"
	);
	assert(cp.jar_count == 2, "expected 2, got %d", (int)cp.jar_count);
	assert(cp.jars[0].path == "/path/to/lib1.jar");
	assert(cp.jars[1].path == "/path/to/lib2.jar");
}

fn void test_parse_maven_output_skips_maven_logs() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_maven_output(&cp,
		"[INFO] Building project\n/path/to/lib.jar\n"
	);
	assert(cp.jar_count == 1);
	assert(cp.jars[0].path == "/path/to/lib.jar");
}

fn void test_parse_maven_output_empty() {
	Classpath cp;
	cp.init();

	classpath::parse_maven_output(&cp, "");
	assert(cp.jar_count == 0);
}

fn void test_parse_maven_output_only_jars() {
	Classpath cp;
	cp.init();
	defer cp.free();

	// Non-.jar entries should be skipped
	classpath::parse_maven_output(&cp,
		"/path/to/lib.jar:/path/to/classes\n"
	);
	assert(cp.jar_count == 1);
	assert(cp.jars[0].path == "/path/to/lib.jar");
}

// ── Classpath init/free tests ──────────────────────────────────────

fn void test_classpath_init() {
	Classpath cp;
	cp.init();
	assert(cp.build_system == NONE);
	assert(cp.jar_count == 0);
	assert(!cp.resolved);
}

fn void test_classpath_free_empty() {
	Classpath cp;
	cp.init();
	cp.free(); // Should not crash
	assert(cp.jar_count == 0);
}

// ── is_build_file tests ────────────────────────────────────────────

fn void test_is_build_file_gradle_kts() {
	assert(server::is_build_file("file:///project/build.gradle.kts"));
}

fn void test_is_build_file_gradle() {
	assert(server::is_build_file("file:///project/build.gradle"));
}

fn void test_is_build_file_pom() {
	assert(server::is_build_file("file:///project/pom.xml"));
}

fn void test_is_build_file_kt() {
	assert(!server::is_build_file("file:///project/Main.kt"));
}

fn void test_is_build_file_settings_gradle_kts() {
	assert(server::is_build_file("file:///project/settings.gradle.kts"));
}

fn void test_is_build_file_settings_gradle() {
	assert(server::is_build_file("file:///project/settings.gradle"));
}

fn void test_is_build_file_other() {
	assert(!server::is_build_file("file:///project/README.md"));
}

// ── build_system_name tests ────────────────────────────────────────

fn void test_build_system_name_gradle() {
	assert(classpath::build_system_name(GRADLE) == "Gradle");
}

fn void test_build_system_name_maven() {
	assert(classpath::build_system_name(MAVEN) == "Maven");
}

fn void test_build_system_name_none() {
	assert(classpath::build_system_name(NONE) == "None");
}

// ── parse_gradle_output multi-module tests ─────────────────────────

fn void test_parse_gradle_output_single_module() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::|/home/user/project
KLS_SRC:/home/user/project/src/main/kotlin
KLS_JAR:/path/to/lib.jar
`);
	assert(cp.module_count == 1, "expected 1 module, got %d", (int)cp.module_count);
	assert(cp.modules[0].name == ":", "expected ':', got '%s'", cp.modules[0].name);
	assert(cp.modules[0].dir == "/home/user/project");
	assert(cp.modules[0].src_root_count == 1);
	assert(cp.modules[0].src_roots[0] == "/home/user/project/src/main/kotlin");
	assert(cp.jar_count == 1);
	assert(cp.modules[0].jar_start == 0);
	assert(cp.modules[0].jar_count == 1);
}

fn void test_parse_gradle_output_multi_module() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_SRC:/home/user/project/core/src/main/kotlin
KLS_JAR:/path/to/lib1.jar
KLS_MODULE::app|/home/user/project/app
KLS_SRC:/home/user/project/app/src/main/kotlin
KLS_DEP::core
KLS_JAR:/path/to/lib2.jar
KLS_JAR:/path/to/lib3.jar
`);
	assert(cp.module_count == 2, "expected 2 modules, got %d", (int)cp.module_count);

	// Core module
	assert(cp.modules[0].name == ":core");
	assert(cp.modules[0].dir == "/home/user/project/core");
	assert(cp.modules[0].src_root_count == 1);
	assert(cp.modules[0].dep_module_count == 0);
	assert(cp.modules[0].jar_start == 0);
	assert(cp.modules[0].jar_count == 1);

	// App module
	assert(cp.modules[1].name == ":app");
	assert(cp.modules[1].dir == "/home/user/project/app");
	assert(cp.modules[1].src_root_count == 1);
	assert(cp.modules[1].dep_module_count == 1);
	assert(cp.modules[1].dep_modules[0] == ":core");
	assert(cp.modules[1].jar_start == 1);
	assert(cp.modules[1].jar_count == 2);

	assert(cp.jar_count == 3, "expected 3 JARs total, got %d", (int)cp.jar_count);
}

fn void test_parse_gradle_output_multiple_src_roots() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::lib|/home/user/project/lib
KLS_SRC:/home/user/project/lib/src/main/kotlin
KLS_SRC:/home/user/project/lib/src/main/java
KLS_SRC:/home/user/project/lib/src/test/kotlin
`);
	assert(cp.module_count == 1);
	assert(cp.modules[0].src_root_count == 3, "expected 3 src roots, got %d", (int)cp.modules[0].src_root_count);
	assert(cp.modules[0].src_roots[0] == "/home/user/project/lib/src/main/kotlin");
	assert(cp.modules[0].src_roots[1] == "/home/user/project/lib/src/main/java");
	assert(cp.modules[0].src_roots[2] == "/home/user/project/lib/src/test/kotlin");
}

fn void test_parse_gradle_output_multiple_deps() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::app|/home/user/project/app
KLS_DEP::core
KLS_DEP::data
KLS_DEP::common
`);
	assert(cp.modules[0].dep_module_count == 3);
	assert(cp.modules[0].dep_modules[0] == ":core");
	assert(cp.modules[0].dep_modules[1] == ":data");
	assert(cp.modules[0].dep_modules[2] == ":common");
}

fn void test_parse_gradle_output_jars_without_module() {
	// JARs without a preceding MODULE line should still be added
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp, "KLS_JAR:/path/to/orphan.jar\n");
	assert(cp.jar_count == 1);
	assert(cp.module_count == 0);
	assert(cp.jars[0].path == "/path/to/orphan.jar");
}

fn void test_parse_gradle_output_crlf_module() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
		"KLS_MODULE::core|/home/user/project/core\r\nKLS_SRC:/home/user/project/core/src/main/kotlin\r\nKLS_JAR:/path/to/lib.jar\r\n"
	);
	assert(cp.module_count == 1);
	assert(cp.modules[0].name == ":core");
	assert(cp.modules[0].dir == "/home/user/project/core");
	assert(cp.modules[0].src_root_count == 1);
	assert(cp.jar_count == 1);
}

// ── find_module tests ──────────────────────────────────────────────

fn void test_find_module_found() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_MODULE::app|/home/user/project/app
`);
	GradleModule* m = cp.find_module(":core");
	assert(m != null, "expected to find :core module");
	assert(m.name == ":core");
	assert(m.dir == "/home/user/project/core");
}

fn void test_find_module_not_found() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp, "KLS_MODULE::core|/home/user/project/core\n");
	GradleModule* m = cp.find_module(":nonexistent");
	assert(m == null, "expected null for nonexistent module");
}

fn void test_find_module_empty_classpath() {
	Classpath cp;
	cp.init();
	GradleModule* m = cp.find_module(":core");
	assert(m == null);
}

// ── find_module_for_path tests ─────────────────────────────────────

fn void test_find_module_for_path_matches_src_root() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_SRC:/home/user/project/core/src/main/kotlin
KLS_MODULE::app|/home/user/project/app
KLS_SRC:/home/user/project/app/src/main/kotlin
`);

	GradleModule* m = cp.find_module_for_path("/home/user/project/core/src/main/kotlin/com/example/Foo.kt");
	assert(m != null, "expected to find module for core file");
	assert(m.name == ":core");
}

fn void test_find_module_for_path_second_module() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_SRC:/home/user/project/core/src/main/kotlin
KLS_MODULE::app|/home/user/project/app
KLS_SRC:/home/user/project/app/src/main/kotlin
`);

	GradleModule* m = cp.find_module_for_path("/home/user/project/app/src/main/kotlin/com/example/Main.kt");
	assert(m != null, "expected to find module for app file");
	assert(m.name == ":app");
}

fn void test_find_module_for_path_no_match() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_SRC:/home/user/project/core/src/main/kotlin
`);

	GradleModule* m = cp.find_module_for_path("/home/user/other-project/src/main/kotlin/Foo.kt");
	assert(m == null, "expected null for path outside all modules");
}

fn void test_find_module_for_path_test_source_root() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::lib|/home/user/project/lib
KLS_SRC:/home/user/project/lib/src/main/kotlin
KLS_SRC:/home/user/project/lib/src/test/kotlin
`);

	GradleModule* m = cp.find_module_for_path("/home/user/project/lib/src/test/kotlin/com/example/FooTest.kt");
	assert(m != null, "expected to find module for test file");
	assert(m.name == ":lib");
}

fn void test_find_module_for_path_empty_classpath() {
	Classpath cp;
	cp.init();
	GradleModule* m = cp.find_module_for_path("/some/path/File.kt");
	assert(m == null);
}

// ── module_depends_on tests ────────────────────────────────────────

fn void test_module_depends_on_self() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp, "KLS_MODULE::core|/home/user/project/core\n");
	assert(cp.module_depends_on(":core", ":core"), "module should depend on itself");
}

fn void test_module_depends_on_direct() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_MODULE::app|/home/user/project/app
KLS_DEP::core
`);
	assert(cp.module_depends_on(":app", ":core"), "app should depend on core");
}

fn void test_module_depends_on_not_reverse() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::core|/home/user/project/core
KLS_MODULE::app|/home/user/project/app
KLS_DEP::core
`);
	assert(!cp.module_depends_on(":core", ":app"), "core should NOT depend on app");
}

fn void test_module_depends_on_transitive() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::common|/home/user/project/common
KLS_MODULE::core|/home/user/project/core
KLS_DEP::common
KLS_MODULE::app|/home/user/project/app
KLS_DEP::core
`);
	// app -> core -> common
	assert(cp.module_depends_on(":app", ":core"), "app -> core");
	assert(cp.module_depends_on(":app", ":common"), "app -> core -> common (transitive)");
	assert(!cp.module_depends_on(":common", ":app"), "common should NOT depend on app");
}

fn void test_module_depends_on_no_modules_permissive() {
	Classpath cp;
	cp.init();
	// No modules = single-project mode, everything should be visible
	assert(cp.module_depends_on(":any", ":other"), "no modules means permissive");
}

fn void test_module_depends_on_unknown_module_permissive() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp, "KLS_MODULE::core|/home/user/project/core\n");
	// Unknown 'from' module should be permissive
	assert(cp.module_depends_on(":unknown", ":core"), "unknown module should be permissive");
}

fn void test_module_depends_on_no_path() {
	Classpath cp;
	cp.init();
	defer cp.free();

	classpath::parse_gradle_output(&cp,
`KLS_MODULE::a|/home/user/project/a
KLS_MODULE::b|/home/user/project/b
KLS_MODULE::c|/home/user/project/c
`);
	// No deps between any of them
	assert(!cp.module_depends_on(":a", ":b"), "a should not depend on b");
	assert(!cp.module_depends_on(":b", ":c"), "b should not depend on c");
	assert(!cp.module_depends_on(":a", ":c"), "a should not depend on c");
}

// ── Classpath init includes module_count ───────────────────────────

fn void test_classpath_init_modules() {
	Classpath cp;
	cp.init();
	assert(cp.module_count == 0);
}
