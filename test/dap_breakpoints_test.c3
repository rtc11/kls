module kls::test::dap_breakpoints_test;

import std::collections::object;
import kls::dap::breakpoints;

// ── BreakpointManager init ─────────────────────────────────────────

fn void bp_manager_init() @test {
	BreakpointManager mgr;
	mgr.init();
	assert(mgr.count == 0, "expected count=0, got %d", (int)mgr.count);
	assert(mgr.next_id == 1, "expected next_id=1, got %d", mgr.next_id);
}

fn void exception_bp_manager_init() @test {
	ExceptionBpManager mgr;
	mgr.init();
	assert(mgr.count == 0, "expected count=0, got %d", (int)mgr.count);
}

// ── source_path_to_class_sig ───────────────────────────────────────

fn void path_to_sig_main_kotlin_with_kt() @test {
	@pool() {
		String sig = breakpoints::source_path_to_class_sig(
			"/project/src/main/kotlin/com/example/Main.kt", true);
		assert(sig == "Lcom/example/MainKt;", "got: %s", sig);
	};
}

fn void path_to_sig_main_kotlin_without_kt() @test {
	@pool() {
		String sig = breakpoints::source_path_to_class_sig(
			"/project/src/main/kotlin/com/example/Main.kt", false);
		assert(sig == "Lcom/example/Main;", "got: %s", sig);
	};
}

fn void path_to_sig_test_kotlin() @test {
	@pool() {
		String sig = breakpoints::source_path_to_class_sig(
			"/project/src/test/kotlin/com/example/FooTest.kt", true);
		assert(sig == "Lcom/example/FooTestKt;", "got: %s", sig);
	};
}

fn void path_to_sig_java_file() @test {
	@pool() {
		String sig = breakpoints::source_path_to_class_sig(
			"/project/src/main/java/com/example/Util.java", false);
		assert(sig == "Lcom/example/Util;", "got: %s", sig);
	};
}

fn void path_to_sig_no_marker_returns_empty() @test {
	@pool() {
		String sig = breakpoints::source_path_to_class_sig("/random/path/Foo.txt", true);
		assert(sig.len == 0, "expected empty for non-kotlin/java file");
	};
}

fn void path_to_sig_nested_package() @test {
	@pool() {
		String sig = breakpoints::source_path_to_class_sig(
			"/project/src/main/kotlin/com/example/deep/nested/Thing.kt", true);
		assert(sig == "Lcom/example/deep/nested/ThingKt;", "got: %s", sig);
	};
}

// ── sig_to_class_match ─────────────────────────────────────────────

fn void sig_to_match_basic() @test {
	@pool() {
		String pattern = breakpoints::sig_to_class_match("Lcom/example/FooKt;");
		assert(pattern == "com.example.FooKt*", "got: %s", pattern);
	};
}

fn void sig_to_match_single_class() @test {
	@pool() {
		String pattern = breakpoints::sig_to_class_match("LMain;");
		assert(pattern == "Main*", "got: %s", pattern);
	};
}

fn void sig_to_match_short_sig_returns_empty() @test {
	@pool() {
		String pattern = breakpoints::sig_to_class_match("L;");
		assert(pattern.len == 0, "expected empty for too-short sig");
	};
}

// ── build_empty_response ───────────────────────────────────────────

fn void empty_response_has_breakpoints_field() @test {
	@pool() {
		Object* body = breakpoints::build_empty_response();
		assert(body != null, "expected non-null body");
		Object* bps = body.get("breakpoints") ?? null;
		assert(bps != null, "expected breakpoints field");
	};
}
