module kls::kotlin_fallback_test @test;

import kls::deps::kotlin_fallback;
import kls::deps::jar_index;

// ── strip_bin_suffix tests ─────────────────────────────────────────

fn void test_strip_bin_suffix_unix() {
	String home = kotlin_fallback::strip_bin_suffix("/opt/homebrew/Cellar/kotlin/2.0.0/libexec/bin/kotlinc")!!;
	assert(home == "/opt/homebrew/Cellar/kotlin/2.0.0/libexec", "expected libexec path, got '%s'", home);
}

fn void test_strip_bin_suffix_sdkman() {
	String home = kotlin_fallback::strip_bin_suffix("/home/user/.sdkman/candidates/kotlin/current/bin/kotlinc")!!;
	assert(home == "/home/user/.sdkman/candidates/kotlin/current", "expected sdkman path, got '%s'", home);
}

fn void test_strip_bin_suffix_windows() {
	String home = kotlin_fallback::strip_bin_suffix("C:/kotlin/bin/kotlinc.bat")!!;
	assert(home == "C:/kotlin", "expected C:/kotlin, got '%s'", home);
}

fn void test_strip_bin_suffix_no_match() {
	String? result = kotlin_fallback::strip_bin_suffix("/usr/local/kotlinc");
	assert(@catch(result), "expected fault for non-matching path");
}

fn void test_strip_bin_suffix_empty() {
	String? result = kotlin_fallback::strip_bin_suffix("");
	assert(@catch(result), "expected fault for empty path");
}

fn void test_strip_bin_suffix_just_bin_kotlinc() {
	// Edge case: path is exactly "/bin/kotlinc"
	String home = kotlin_fallback::strip_bin_suffix("/bin/kotlinc")!!;
	assert(home == "", "expected empty string, got '%s'", home);
}

// ── has_stdlib_jar tests ───────────────────────────────────────────

fn void test_has_stdlib_jar_nonexistent() {
	// Non-existent path should return false
	assert(!kotlin_fallback::has_stdlib_jar("/nonexistent/kotlin/home"));
}

fn void test_has_stdlib_jar_empty() {
	assert(!kotlin_fallback::has_stdlib_jar(""));
}

// ── index_system_kotlin with empty dep_index ───────────────────────

fn void test_index_system_kotlin_does_not_crash() {
	// Even if no Kotlin is found, this should not crash
	DependencyIndex idx;
	idx.init();
	defer idx.free();

	// This will try to detect Kotlin - if none found, it should
	// just log and return without adding any symbols.
	// We can't assert on symbol count since it depends on the system,
	// but it should not crash.
	kotlin_fallback::index_system_kotlin(&idx);
	// If we get here without crashing, the test passes
}
