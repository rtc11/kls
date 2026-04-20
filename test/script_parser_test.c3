module kls::test::script_parser_test;

import kls::kotlin::parser;
import kls::kotlin::ast;

// ── Helper ──────────────────────────────────────────────────────────

fn ParseResult* do_parse_script(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result, is_script: true);
	return result;
}

fn void free_result(ParseResult* r) {
	for (uint i = 0; i < r.node_count; i++) {
		String ann = r.nodes[i].annotation_text;
		if (ann.len > 0) {
			bool has_space = false;
			foreach (c : ann) {
				if (c == ' ') { has_space = true; break; }
			}
			if (has_space) {
				mem::free((void*)ann.ptr);
			}
		}
	}
	r.free_errors();
	mem::free(r);
}

fn AstNode* file_node(ParseResult* r) {
	return &r.nodes[0];
}

fn AstNode* child(ParseResult* r, AstNode* parent, uint n) {
	return ast::get_child(r, parent, n)!!;
}

// ── Script mode flag ────────────────────────────────────────────────

fn void script_flag_set() @test {
	@pool() {
		ParseResult* r = do_parse_script(""); defer free_result(r);
		assert(r.is_script, "expected is_script to be true");
	};
}

fn void non_script_flag_unset() @test {
	@pool() {
		ParseResult* r = mem::new(ParseResult); defer free_result(r);
		parser::parse("", r);
		assert(!r.is_script, "expected is_script to be false");
	};
}

// ── Top-level expression calls (plugins {}, dependencies {}) ────────

fn void script_top_level_call_with_trailing_lambda() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`plugins {
				id("org.jetbrains.kotlin.jvm")
			}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

fn void script_dependencies_block() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`dependencies {
				implementation("org.jetbrains:annotations:24.0.0")
				testImplementation("junit:junit:4.13.2")
			}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Top-level val/var ───────────────────────────────────────────────

fn void script_top_level_val() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`val kotlinVersion = "1.9.0"
			println(kotlinVersion)`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
		// First child should be PROPERTY_DECL
		AstNode* f = file_node(r);
		assert(f.child_count >= 1, "expected at least 1 child");
		AstNode* prop = child(r, f, 0);
		assert(prop.kind == PROPERTY_DECL, "expected PROPERTY_DECL, got %d", (int)prop.kind);
	};
}

// ── Mixed declarations and expressions ──────────────────────────────

fn void script_mixed_decl_and_expr() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`import org.gradle.api.tasks

			val version = "1.0"

			plugins {
				kotlin("jvm")
			}

			fun helper(): String = version

			dependencies {
				implementation("com.example:lib:$version")
			}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Property access chains ──────────────────────────────────────────

fn void script_property_access_chain() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`tasks.register("build") {
				doLast {
					println("done")
				}
			}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Assignment at top level ─────────────────────────────────────────

fn void script_top_level_assignment() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`group = "com.example"
			version = "1.0-SNAPSHOT"`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors, got %d", (int)r.error_count);
	};
}

// ── Normal .kt still rejects top-level expressions ──────────────────

fn void non_script_rejects_top_level_expr() @test {
	@pool() {
		ParseResult* r = mem::new(ParseResult); defer free_result(r);
		parser::parse(`println("hello")`, r);
		assert(r.error_count > 0, "expected errors for top-level expr in non-script");
	};
}

// ── Realistic build.gradle.kts ──────────────────────────────────────

fn void script_realistic_gradle_build() @test {
	@pool() {
		ParseResult* r = do_parse_script(
			`plugins {
				kotlin("jvm") version "1.9.0"
				application
			}

			group = "com.example"
			version = "1.0-SNAPSHOT"

			repositories {
				mavenCentral()
			}

			dependencies {
				implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
				testImplementation(kotlin("test"))
			}

			tasks.test {
				useJUnitPlatform()
			}

			application {
				mainClass.set("com.example.MainKt")
			}`
		); defer free_result(r);
		assert(r.error_count == 0, "expected no errors for realistic build.gradle.kts, got %d", (int)r.error_count);
	};
}
