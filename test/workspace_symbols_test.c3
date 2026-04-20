module kls::test::workspace_symbols_test;

import std::collections::object;
import kls::workspace;
import kls::lsp::workspace_symbols;

// ── Helper: build params object ────────────────────────────────────

fn Object* make_params(String query) {
	Object* params = object::new_obj(tmem);
	params.set("query", query);
	return params;
}

// ── Basic workspace symbol tests ───────────────────────────────────

fn void workspace_symbol_empty_query_returns_all() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}\nclass Foo {}");

		Object* params = make_params("");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result != null, "expected result array");
		assert(result.get_len() == 2, "expected 2 symbols, got %d", (int)result.get_len());
	};
}

fn void workspace_symbol_filters_by_query() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}\nclass Foo {}\nfun getUser() {}");

		Object* params = make_params("gre");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result != null, "expected result array");
		assert(result.get_len() == 1, "expected 1 symbol matching 'gre', got %d", (int)result.get_len());

		Object* sym = result.get_at(0);
		String name = sym.get_string("name")!!;
		assert(name == "greet", "expected 'greet', got '%s'", name);
	};
}

fn void workspace_symbol_case_insensitive() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "class MyClass {}\nfun myFunction() {}");

		// Search with lowercase should find MyClass
		Object* params = make_params("myclass");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result.get_len() == 1, "expected 1 symbol, got %d", (int)result.get_len());
		String name = result.get_at(0).get_string("name")!!;
		assert(name == "MyClass", "expected 'MyClass', got '%s'", name);
	};
}

fn void workspace_symbol_no_match_returns_empty() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}");

		Object* params = make_params("nonexistent");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result != null, "expected result array");
		assert(result.get_len() == 0, "expected 0 symbols, got %d", (int)result.get_len());
	};
}

fn void workspace_symbol_has_correct_kind() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}");

		Object* params = make_params("greet");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		Object* sym = result.get_at(0);
		int kind = sym.get_int("kind")!!;
		assert(kind == 12, "expected Function=12, got %d", kind);
	};
}

fn void workspace_symbol_has_location() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///models.kt", "package com.app\n\nclass User {}");

		Object* params = make_params("User");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result.get_len() == 1, "expected 1 symbol");
		Object* sym = result.get_at(0);

		// Check location
		Object* location = sym.get("location")!!;
		String uri = location.get_string("uri")!!;
		assert(uri == "file:///models.kt", "expected URI 'file:///models.kt', got '%s'", uri);

		Object* range = location.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 2, "expected line 2, got %d", line);
		assert(col == 6, "expected col 6, got %d", col);
	};
}

fn void workspace_symbol_has_container_name() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "package com.example\n\nclass Foo {}");

		Object* params = make_params("Foo");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		Object* sym = result.get_at(0);
		String container = sym.get_string("containerName")!!;
		assert(container == "com.example", "expected 'com.example', got '%s'", container);
	};
}

fn void workspace_symbol_cross_file() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///a.kt", "fun alpha() {}\nfun beta() {}");
		idx.index_file("file:///b.kt", "fun gamma() {}\nclass Delta {}");

		// Search for "a" should match alpha, beta, gamma, Delta
		Object* params = make_params("a");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		// alpha, gamma, Delta all contain 'a'
		assert(result.get_len() >= 3, "expected at least 3 symbols containing 'a', got %d", (int)result.get_len());
	};
}

fn void workspace_symbol_empty_index() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		Object* params = make_params("anything");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result != null, "expected result array");
		assert(result.get_len() == 0, "expected 0 symbols for empty index");
	};
}

fn void workspace_symbol_substring_match() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun getUserById() {}\nfun createUser() {}");

		// "User" is a substring of both function names
		Object* params = make_params("User");
		Object* result = workspace_symbols::handle_workspace_symbol(&idx, params)!!;

		assert(result.get_len() == 2, "expected 2 symbols containing 'User', got %d", (int)result.get_len());
	};
}
