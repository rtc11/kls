module kls::test::signature_help_test;

import std::collections::object;
import kls::document;
import kls::lsp::signature_help;

// ── Helper: build params object ────────────────────────────────────

fn Object* make_params(String uri, int line, int character) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	return params;
}

// ── Basic function call: cursor after ( ────────────────────────────

fn void sig_help_after_open_paren() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "greet" is at col 4, call "greet(" at col 28
		String content = "fun greet(name: String) {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor right after '(' in greet() -- line 1, col 19
		// Line 1: "fun main() { greet() }"
		//          0123456789012345678901
		//                                greet starts at 14, ( at 19, cursor at 20
		Object* params = make_params("file:///test.kt", 1, 20);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");

		Object* sigs = result.get("signatures")!!;
		int active_param = result.get_int("activeParameter")!!;
		assert(active_param == 0, "expected activeParameter 0, got %d", active_param);

		// Check the signature label
		Object* sig0 = sigs.get_at(0);
		String label = sig0.get_string("label")!!;
		assert(label.contains("greet"), "label should contain 'greet', got '%s'", label);
		assert(label.contains("name: String"), "label should contain 'name: String', got '%s'", label);
	};
}

// ── Two parameters: cursor after first comma ───────────────────────

fn void sig_help_second_param() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun add(a: Int, b: Int): Int { return a + b }\nfun main() { add(1, 2) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "fun main() { add(1, 2) }"
		//          0123456789012345678901234
		//                            add( at 17, 1 at 18, comma at 19, space at 20, 2 at 21
		Object* params = make_params("file:///test.kt", 1, 21);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		int active_param = result.get_int("activeParameter")!!;
		assert(active_param == 1, "expected activeParameter 1, got %d", active_param);

		// Check signature has both params
		Object* sigs = result.get("signatures")!!;
		Object* sig0 = sigs.get_at(0);
		String label = sig0.get_string("label")!!;
		assert(label.contains("a: Int"), "label should contain 'a: Int', got '%s'", label);
		assert(label.contains("b: Int"), "label should contain 'b: Int', got '%s'", label);
	};
}

// ── Three parameters: cursor after second comma ────────────────────

fn void sig_help_third_param() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun make(x: Int, y: Int, z: Int) {}\nfun main() { make(1, 2, 3) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "fun main() { make(1, 2, 3) }"
		//          0         1         2
		//          0123456789012345678901234567
		//                             make( at 18, 1 at 19, comma at 20, 2 at 22, comma at 23, 3 at 25
		Object* params = make_params("file:///test.kt", 1, 26);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		int active_param = result.get_int("activeParameter")!!;
		assert(active_param == 2, "expected activeParameter 2, got %d", active_param);
	};
}

// ── No call at cursor: returns null ────────────────────────────────

fn void sig_help_not_in_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet(name: String) {}\nval x = 42";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "val x = 42" which is not inside any call
		Object* params = make_params("file:///test.kt", 1, 4);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result == null, "expected null when not in a call");
	};
}

// ── Function with no parameters ────────────────────────────────────

fn void sig_help_no_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun doWork() {}\nfun main() { doWork() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "fun main() { doWork() }"
		//          0123456789012345678901
		//                         doWork( at 19, cursor at 20
		Object* params = make_params("file:///test.kt", 1, 20);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");

		Object* sigs = result.get("signatures")!!;
		Object* sig0 = sigs.get_at(0);
		String label = sig0.get_string("label")!!;
		assert(label.contains("doWork"), "label should contain 'doWork', got '%s'", label);
		assert(label.contains("()"), "label should contain empty parens, got '%s'", label);
	};
}

// ── Function with return type ──────────────────────────────────────

fn void sig_help_with_return_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun compute(n: Int): String { return \"\" }\nfun main() { compute(5) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "fun main() { compute(5) }"
		//          0         1         2
		//          0123456789012345678901234
		//                          compute( at 20, cursor at 21
		Object* params = make_params("file:///test.kt", 1, 22);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		Object* sigs = result.get("signatures")!!;
		Object* sig0 = sigs.get_at(0);
		String label = sig0.get_string("label")!!;
		assert(label.contains(": String"), "label should contain return type, got '%s'", label);
	};
}

// ── Parameter label offsets are correct ────────────────────────────

fn void sig_help_param_label_offsets() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet(name: String, age: Int) {}\nfun main() { greet(\"\", 0) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor inside the call
		Object* params = make_params("file:///test.kt", 1, 20);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");

		Object* sigs = result.get("signatures")!!;
		Object* sig0 = sigs.get_at(0);

		// Check parameters array exists
		Object* sig_params = sig0.get("parameters")!!;
		// We should have 2 parameters
		Object* p0 = sig_params.get_at(0);
		Object* p1 = sig_params.get_at(1);

		// Each parameter should have a label as [start, end] offsets
		Object* p0_label = p0.get("label")!!;
		Object* p1_label = p1.get("label")!!;

		// Verify offsets make sense by checking the label string
		String label = sig0.get_string("label")!!;

		int p0_start = p0_label.get_int_at(0)!!;
		int p0_end = p0_label.get_int_at(1)!!;
		int p1_start = p1_label.get_int_at(0)!!;
		int p1_end = p1_label.get_int_at(1)!!;

		// First param should start before second param
		assert(p0_start < p1_start, "first param start should be before second");
		assert(p0_end <= p1_start, "first param end should be before second start");

		// Extract the parameter text from the label using the offsets
		String p0_text = label[(usz)p0_start..(usz)p0_end - 1];
		String p1_text = label[(usz)p1_start..(usz)p1_end - 1];
		assert(p0_text == "name: String", "first param should be 'name: String', got '%s'", p0_text);
		assert(p1_text == "age: Int", "second param should be 'age: Int', got '%s'", p1_text);
	};
}

// ── Nested calls: inner call should be detected ────────────────────

fn void sig_help_nested_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun outer(x: Int) {}\nfun inner(y: String): Int { return 0 }\nfun main() { outer(inner()) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 2: "fun main() { outer(inner()) }"
		//          0         1         2
		//          01234567890123456789012345678
		//                            outer( at 19, inner( at 25, cursor at 26
		Object* params = make_params("file:///test.kt", 2, 26);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		Object* sigs = result.get("signatures")!!;
		Object* sig0 = sigs.get_at(0);
		String label = sig0.get_string("label")!!;

		// Should get the inner function's signature since cursor is inside inner()
		assert(label.contains("inner"), "expected inner function signature, got '%s'", label);
	};
}

// ── Function with modifier keywords ────────────────────────────────

fn void sig_help_with_modifiers() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "suspend fun fetch(url: String): String { return \"\" }\nfun main() { fetch(\"\") }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "fun main() { fetch("") }"
		//          0         1         2
		//          0123456789012345678901234
		//                          fetch( at 19, cursor at 20
		Object* params = make_params("file:///test.kt", 1, 20);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		Object* sigs = result.get("signatures")!!;
		Object* sig0 = sigs.get_at(0);
		String label = sig0.get_string("label")!!;
		assert(label.contains("suspend"), "label should contain 'suspend', got '%s'", label);
		assert(label.contains("fun fetch"), "label should contain 'fun fetch', got '%s'", label);
	};
}

// ── Cursor on comma position triggers next param ───────────────────

fn void sig_help_cursor_right_after_comma() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun add(a: Int, b: Int) {}\nfun main() { add(1,) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Line 1: "fun main() { add(1,) }"
		//          0         1
		//          0123456789012345678901
		//                         add( at 17, 1 at 18, comma at 19, cursor at 20
		Object* params = make_params("file:///test.kt", 1, 20);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		int active_param = result.get_int("activeParameter")!!;
		assert(active_param == 1, "expected activeParameter 1 after comma, got %d", active_param);
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void sig_help_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Active parameter is clamped to param count ─────────────────────

fn void sig_help_active_param_clamped() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Function takes 1 param but call has extra commas (typing error)
		String content = "fun greet(name: String) {}\nfun main() { greet(a, b, c) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor after the last comma: activeParameter would be 2, but
		// the function only has 1 parameter, so it should be clamped to 0 (index of last param)
		// Line 1: "fun main() { greet(a, b, c) }"
		//          0         1         2
		//          012345678901234567890123456789
		//                              greet( at 19, a at 20, comma at 21, b at 23, comma at 24, c at 26
		Object* params = make_params("file:///test.kt", 1, 26);
		Object* result = signature_help::handle_signature_help(&store, params);

		assert(result != null, "expected SignatureHelp result");
		int active_param = result.get_int("activeParameter")!!;
		assert(active_param == 0, "expected activeParameter clamped to 0, got %d", active_param);
	};
}
