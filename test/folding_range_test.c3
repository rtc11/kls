module kls::test::folding_range_test;

import std::collections::object;
import kls::document;
import kls::lsp::folding_range;

// ── Helper ────────────────────────────────────────────────────────

fn Object* make_params(String uri) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	return params;
}

// ── Empty / unknown document ──────────────────────────────────────

fn void empty_document_returns_empty_array() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "");
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null, "expected empty array, not null");
		assert(result.get_len() == 0, "expected 0 ranges, got %d", (int)result.get_len());
	};
}

fn void unknown_document_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

fn void single_line_function_no_fold() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		assert(result.get_len() == 0, "single-line function should not fold, got %d ranges", (int)result.get_len());
	};
}

// ── Function folding ──────────────────────────────────────────────

fn void multiline_function_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun greet() {
    println("hello")
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Should have at least a fold for the function
		bool found_fun_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			int start_line = r.get_int("startLine")!!;
			int end_line = r.get_int("endLine")!!;
			if (start_line == 0 && end_line == 2) {
				found_fun_fold = true;
			}
		}
		assert(found_fun_fold, "expected a folding range for the function (lines 0-2)");
	};
}

// ── Class folding ─────────────────────────────────────────────────

fn void multiline_class_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`class Foo {
    val x = 1
    fun bar() {}
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_class_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			int start_line = r.get_int("startLine")!!;
			int end_line = r.get_int("endLine")!!;
			if (start_line == 0 && end_line == 3) {
				found_class_fold = true;
			}
		}
		assert(found_class_fold, "expected a folding range for the class (lines 0-3)");
	};
}

// ── Interface folding ─────────────────────────────────────────────

fn void multiline_interface_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`interface Drawable {
    fun draw()
    fun color(): String
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_iface_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			int start_line = r.get_int("startLine")!!;
			int end_line = r.get_int("endLine")!!;
			if (start_line == 0 && end_line == 3) {
				found_iface_fold = true;
			}
		}
		assert(found_iface_fold, "expected a folding range for the interface (lines 0-3)");
	};
}

// ── Import block folding ──────────────────────────────────────────

fn void import_block_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`import com.example.Foo
import com.example.Bar
import com.example.Baz

fun main() {}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_import_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			if (try kind = r.get_string("kind")) {
				if (kind == "imports") {
					int start_line = r.get_int("startLine")!!;
					int end_line = r.get_int("endLine")!!;
					assert(start_line == 0, "import fold should start at line 0, got %d", start_line);
					assert(end_line == 2, "import fold should end at line 2, got %d", end_line);
					found_import_fold = true;
				}
			}
		}
		assert(found_import_fold, "expected an imports folding range");
	};
}

fn void single_import_no_fold() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`import com.example.Foo

fun main() {}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			if (try kind = r.get_string("kind")) {
				assert(kind != "imports", "single import should not produce an imports fold");
			}
		}
	};
}

// ── Block comment folding ─────────────────────────────────────────

fn void multiline_block_comment_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`/*
 * This is a
 * multi-line comment
 */
fun main() {}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_comment_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			if (try kind = r.get_string("kind")) {
				if (kind == "comment") {
					int start_line = r.get_int("startLine")!!;
					int end_line = r.get_int("endLine")!!;
					assert(start_line == 0, "comment fold should start at line 0, got %d", start_line);
					assert(end_line == 3, "comment fold should end at line 3, got %d", end_line);
					found_comment_fold = true;
				}
			}
		}
		assert(found_comment_fold, "expected a comment folding range");
	};
}

fn void single_line_block_comment_no_fold() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "/* single line */ fun main() {}");
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			if (try kind = r.get_string("kind")) {
				assert(kind != "comment", "single-line comment should not fold");
			}
		}
	};
}

// ── KDoc comment folding ──────────────────────────────────────────

fn void kdoc_comment_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`/**
 * KDoc comment
 * for a function
 */
fun main() {}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_comment_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			if (try kind = r.get_string("kind")) {
				if (kind == "comment") {
					found_comment_fold = true;
				}
			}
		}
		assert(found_comment_fold, "expected a comment folding range for KDoc");
	};
}

// ── When expression folding ───────────────────────────────────────

fn void when_expression_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun classify(x: Int): String {
    return when (x) {
        1 -> "one"
        2 -> "two"
        else -> "other"
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Should have folds for the function and the when expression
		assert(result.get_len() >= 2, "expected at least 2 folding ranges, got %d", (int)result.get_len());
	};
}

// ── If expression folding ─────────────────────────────────────────

fn void if_expression_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun check(x: Int) {
    if (x > 0) {
        println("positive")
    } else {
        println("non-positive")
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Should have folds for the function and the if expression
		assert(result.get_len() >= 2, "expected at least 2 folding ranges, got %d", (int)result.get_len());
	};
}

// ── Lambda expression folding ─────────────────────────────────────

fn void lambda_expression_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun process() {
    listOf(1, 2, 3).map {
        it * 2
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Should have folds for the function and the lambda
		assert(result.get_len() >= 2, "expected at least 2 folding ranges, got %d", (int)result.get_len());
	};
}

// ── Nested structures fold independently ──────────────────────────

fn void nested_class_and_function_fold() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`class Outer {
    fun method() {
        println("hello")
    }
    class Inner {
        fun innerMethod() {
            println("inner")
        }
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Outer class + method + Inner class + innerMethod = at least 4 folds
		assert(result.get_len() >= 4, "expected at least 4 folding ranges for nested structures, got %d", (int)result.get_len());
	};
}

// ── Try/catch folding ─────────────────────────────────────────────

fn void try_catch_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun safe() {
    try {
        riskyOperation()
    } catch (e: Exception) {
        handleError(e)
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Function + try + catch = at least 3 folds
		assert(result.get_len() >= 3, "expected at least 3 folding ranges for try/catch, got %d", (int)result.get_len());
	};
}

// ── For loop folding ──────────────────────────────────────────────

fn void for_loop_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun iterate() {
    for (i in 1..10) {
        println(i)
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Function + for loop = at least 2 folds
		assert(result.get_len() >= 2, "expected at least 2 folding ranges for for loop, got %d", (int)result.get_len());
	};
}

// ── While loop folding ────────────────────────────────────────────

fn void while_loop_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`fun loop() {
    while (true) {
        doSomething()
    }
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		// Function + while loop = at least 2 folds
		assert(result.get_len() >= 2, "expected at least 2 folding ranges for while loop, got %d", (int)result.get_len());
	};
}

// ── Object declaration folding ────────────────────────────────────

fn void object_declaration_folds() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`object Singleton {
    val name = "test"
    fun greet() {}
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_object_fold = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			int start_line = r.get_int("startLine")!!;
			int end_line = r.get_int("endLine")!!;
			if (start_line == 0 && end_line == 3) {
				found_object_fold = true;
			}
		}
		assert(found_object_fold, "expected a folding range for the object declaration (lines 0-3)");
	};
}

// ── Combined: imports + comments + code ───────────────────────────

fn void combined_imports_comments_code() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`import com.example.Foo
import com.example.Bar

/**
 * Main function
 */
fun main() {
    println("hello")
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		bool found_imports = false;
		bool found_comment = false;
		bool found_function = false;
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			if (try kind = r.get_string("kind")) {
				if (kind == "imports") found_imports = true;
				if (kind == "comment") found_comment = true;
			} else {
				int start_line = r.get_int("startLine")!!;
				int end_line = r.get_int("endLine")!!;
				if (start_line == 6 && end_line == 8) found_function = true;
			}
		}
		assert(found_imports, "expected imports folding range");
		assert(found_comment, "expected comment folding range");
		assert(found_function, "expected function folding range");
	};
}

// ── Folding range has correct fields ──────────────────────────────

fn void folding_range_has_correct_fields() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1,
			`class Foo {
    val x = 1
}`
		);
		Object* params = make_params("file:///test.kt");
		Object* result = folding_range::handle_folding_range(&store, params);

		assert(result != null);
		assert(result.get_len() >= 1, "expected at least 1 range");

		// Find the class fold
		for (sz i = 0; i < result.get_len(); i++) {
			Object* r = result.get_at(i);
			int start_line = r.get_int("startLine")!!;
			if (start_line == 0) {
				// Verify all required fields are present
				r.get_int("startLine")!!;
				r.get_int("startCharacter")!!;
				r.get_int("endLine")!!;
				r.get_int("endCharacter")!!;
				// kind is optional for non-comment/non-import ranges
				return;
			}
		}
		assert(false, "expected a folding range starting at line 0");
	};
}
