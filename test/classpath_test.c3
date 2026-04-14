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

fn void test_is_build_file_other() {
	assert(!server::is_build_file("file:///project/settings.gradle"));
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
