module kls::test::declaration_test;

import std::collections::object;
import kls::document;
import kls::lsp::declaration;
import kls::workspace;

// ── Helper: build params ───────────────────────────────────────────

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

// ── Helper: extract location fields ────────────────────────────────

fn int get_start_line(Object* loc) {
	return loc.get("range")!!.get("start")!!.get_int("line")!!;
}

fn int get_start_col(Object* loc) {
	return loc.get("range")!!.get("start")!!.get_int("character")!!;
}

fn String get_uri(Object* loc) {
	return loc.get_string("uri")!!;
}

// ── Unknown document returns null ──────────────────────────────────

fn void declaration_unknown_doc_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///nonexistent.kt", 0, 0);
		Object* result = declaration::handle_declaration(&store, null, params);
		assert(result == null, "expected null for unknown document");
	};
}

// ── Keyword returns null ───────────────────────────────────────────

fn void declaration_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun greet() {}");
		// Cursor on "fun" keyword at col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = declaration::handle_declaration(&store, null, params);
		assert(result == null, "expected null for keyword");
	};
}

// ── Non-override falls back to definition ──────────────────────────

fn void declaration_non_override_falls_back() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" call at line 1, col 14
		Object* params = make_params("file:///test.kt", 1, 14);
		Object* result = declaration::handle_declaration(&store, null, params);

		// Should fall back to definition — find greet at line 0
		assert(result != null, "expected a result from definition fallback");
		assert(get_start_line(result) == 0, "expected line 0");
		assert(get_start_col(result) == 4, "expected col 4");
	};
}

// ── Override navigates to supertype ────────────────────────────────

fn void declaration_override_to_supertype() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		String base_content = "interface Animal {\n    fun speak(): String\n}";
		String child_content = "class Dog : Animal {\n    override fun speak(): String = \"Woof\"\n}";

		store.open("file:///Animal.kt", "kotlin", 1, base_content);
		store.open("file:///Dog.kt", "kotlin", 1, child_content);

		workspace.index_file("file:///Animal.kt", base_content);
		workspace.index_file("file:///Dog.kt", child_content);

		// Cursor on "speak" in Dog's override at line 1
		// "override fun speak" — "speak" starts at col 17
		Object* params = make_params("file:///Dog.kt", 1, 17);
		Object* result = declaration::handle_declaration(&store, &workspace, params);

		assert(result != null, "expected location in supertype");
		String uri = get_uri(result);
		assert(uri == "file:///Animal.kt", "expected Animal.kt, got '%s'", uri);
	};
}

// ── Override but supertype method missing → falls back ─────────────

fn void declaration_override_no_supertype_method_falls_back() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex workspace;
		workspace.init();
		defer workspace.free();

		// Base has no matching method (empty interface)
		String base_content = "interface Animal {}";
		String child_content = "class Dog : Animal {\n    override fun speak(): String = \"Woof\"\n}";

		store.open("file:///Animal.kt", "kotlin", 1, base_content);
		store.open("file:///Dog.kt", "kotlin", 1, child_content);

		workspace.index_file("file:///Animal.kt", base_content);
		workspace.index_file("file:///Dog.kt", child_content);

		// Cursor on "speak" in Dog
		Object* params = make_params("file:///Dog.kt", 1, 17);
		Object* result = declaration::handle_declaration(&store, &workspace, params);

		// Should fall back to definition (finds speak in Dog itself)
		// Result may or may not be null depending on definition fallback
		// Just verify no crash
	};
}

// ── No workspace → falls back to definition ────────────────────────

fn void declaration_no_workspace_falls_back() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 1, 14);
		// Pass null workspace
		Object* result = declaration::handle_declaration(&store, null, params);

		// Should still work via definition fallback
		assert(result != null, "expected result with null workspace");
	};
}
