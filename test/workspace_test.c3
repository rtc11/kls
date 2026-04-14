module kls::test::workspace_test;

import kls::workspace;
import kls::kotlin::symbols;

// ── scan_package tests ─────────────────────────────────────────────

fn void scan_package_simple() @test {
	@pool() {
		String pkg = workspace::scan_package("package com.example.app\n\nclass Foo {}");
		assert(pkg == "com.example.app", "expected 'com.example.app', got '%s'", pkg);
	};
}

fn void scan_package_single_segment() @test {
	@pool() {
		String pkg = workspace::scan_package("package myapp\n");
		assert(pkg == "myapp", "expected 'myapp', got '%s'", pkg);
	};
}

fn void scan_package_empty_content() @test {
	@pool() {
		String pkg = workspace::scan_package("");
		assert(pkg == "", "expected empty package for empty content");
	};
}

fn void scan_package_no_package() @test {
	@pool() {
		String pkg = workspace::scan_package("class Foo {}");
		assert(pkg == "", "expected empty package when no package declaration");
	};
}

fn void scan_package_deep_nesting() @test {
	@pool() {
		String pkg = workspace::scan_package("package com.example.domain.model\n");
		assert(pkg == "com.example.domain.model", "expected 'com.example.domain.model', got '%s'", pkg);
	};
}

// ── URI <-> path conversion tests ──────────────────────────────────

fn void uri_to_path_strips_file_prefix() @test {
	@pool() {
		String path = workspace::uri_to_path("file:///Users/foo/bar.kt");
		assert(path == "/Users/foo/bar.kt", "expected '/Users/foo/bar.kt', got '%s'", path);
	};
}

fn void uri_to_path_no_prefix() @test {
	@pool() {
		String path = workspace::uri_to_path("/Users/foo/bar.kt");
		assert(path == "/Users/foo/bar.kt", "expected '/Users/foo/bar.kt', got '%s'", path);
	};
}

fn void path_to_uri_adds_file_prefix() @test {
	@pool() {
		String uri = workspace::path_to_uri("/Users/foo/bar.kt");
		assert(uri == "file:///Users/foo/bar.kt", "expected 'file:///Users/foo/bar.kt', got '%s'", uri);
	};
}

// ── WorkspaceIndex basic operations ────────────────────────────────

fn void index_file_adds_symbols() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		String content = "package com.example\n\nfun greet() {}\nclass Foo {}";
		idx.index_file("file:///test.kt", content);

		usz count = idx.symbol_count();
		assert(count == 2, "expected 2 symbols, got %d", (int)count);
	};
}

fn void index_file_records_package() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		String content = "package com.example\n\nfun greet() {}";
		idx.index_file("file:///test.kt", content);

		// Lookup greet and check package
		if (try indices = idx.lookup_by_name("greet")) {
			assert(indices.len() == 1, "expected 1 index for 'greet'");
			WorkspaceSymbol* sym = idx.get_symbol((*indices)[0]);
			assert(sym.package_name == "com.example", "expected 'com.example', got '%s'", sym.package_name);
		} else {
			assert(false, "expected to find 'greet' in index");
		}
	};
}

fn void lookup_by_name_returns_correct_symbols() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///a.kt", "fun greet() {}\nclass Foo {}");
		idx.index_file("file:///b.kt", "fun greet(name: String) {}");

		// "greet" should appear in both files
		if (try indices = idx.lookup_by_name("greet")) {
			assert(indices.len() == 2, "expected 2 indices for 'greet', got %d", (int)indices.len());
		} else {
			assert(false, "expected to find 'greet' in index");
		}

		// "Foo" should appear in only one file
		if (try indices = idx.lookup_by_name("Foo")) {
			assert(indices.len() == 1, "expected 1 index for 'Foo'");
			WorkspaceSymbol* sym = idx.get_symbol((*indices)[0]);
			assert(sym.kind == SymbolKind.CLASS, "expected CLASS kind");
		} else {
			assert(false, "expected to find 'Foo' in index");
		}
	};
}

fn void lookup_nonexistent_returns_fault() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}");

		if (try indices = idx.lookup_by_name("nonexistent")) {
			assert(false, "expected fault for nonexistent name");
		}
		// No assertion needed -- reaching here means fault was returned correctly
	};
}

fn void remove_file_clears_symbols() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}\nclass Foo {}");
		assert(idx.symbol_count() == 2, "expected 2 symbols after indexing");

		idx.remove_file("file:///test.kt");
		assert(idx.symbol_count() == 0, "expected 0 symbols after removal");

		// Name index should also be cleared
		if (try indices = idx.lookup_by_name("greet")) {
			assert(false, "expected fault for removed name");
		}
	};
}

fn void reindex_file_replaces_old_symbols() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}");
		assert(idx.symbol_count() == 1, "expected 1 symbol initially");

		// Re-index with different content
		idx.index_file("file:///test.kt", "fun hello() {}\nfun world() {}");
		assert(idx.symbol_count() == 2, "expected 2 symbols after re-index");

		// Old name should be gone
		if (try indices = idx.lookup_by_name("greet")) {
			assert(false, "expected 'greet' to be removed after re-index");
		}

		// New names should be present
		if (try indices = idx.lookup_by_name("hello")) {
			assert(indices.len() == 1, "expected 1 index for 'hello'");
		} else {
			assert(false, "expected to find 'hello'");
		}
	};
}

fn void index_multiple_files() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///models.kt", "package com.app.models\n\ndata class User(val name: String)\ninterface Repository {}");
		idx.index_file("file:///service.kt", "package com.app.service\n\nfun fetchUsers(): List<User> {}\nobject UserCache {}");

		// Check total count (User, name, Repository from models + fetchUsers, UserCache from service)
		usz total = idx.symbol_count();
		assert(total >= 4, "expected at least 4 symbols, got %d", (int)total);

		// Check cross-file lookup
		if (try indices = idx.lookup_by_name("User")) {
			assert(indices.len() >= 1, "expected User symbol");
			WorkspaceSymbol* sym = idx.get_symbol((*indices)[0]);
			assert(sym.package_name == "com.app.models", "expected 'com.app.models', got '%s'", sym.package_name);
			assert(sym.uri == "file:///models.kt", "expected URI 'file:///models.kt', got '%s'", sym.uri);
		} else {
			assert(false, "expected to find 'User'");
		}
	};
}

fn void symbol_has_correct_lsp_kind() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}\nclass Foo {}\ninterface Bar {}\nobject Baz {}\nval x = 1\ntypealias MyStr = String");

		if (try indices = idx.lookup_by_name("greet")) {
			assert(idx.get_symbol((*indices)[0]).lsp_kind == 12, "expected Function=12");
		}
		if (try indices = idx.lookup_by_name("Foo")) {
			assert(idx.get_symbol((*indices)[0]).lsp_kind == 5, "expected Class=5");
		}
		if (try indices = idx.lookup_by_name("Bar")) {
			assert(idx.get_symbol((*indices)[0]).lsp_kind == 11, "expected Interface=11");
		}
		if (try indices = idx.lookup_by_name("Baz")) {
			assert(idx.get_symbol((*indices)[0]).lsp_kind == 2, "expected Module=2");
		}
		if (try indices = idx.lookup_by_name("x")) {
			assert(idx.get_symbol((*indices)[0]).lsp_kind == 7, "expected Property=7");
		}
		if (try indices = idx.lookup_by_name("MyStr")) {
			assert(idx.get_symbol((*indices)[0]).lsp_kind == 5, "expected Class=5 for typealias");
		}
	};
}

fn void symbol_has_correct_position() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///test.kt", "fun greet() {}");

		if (try indices = idx.lookup_by_name("greet")) {
			WorkspaceSymbol* sym = idx.get_symbol((*indices)[0]);
			assert(sym.line == 0, "expected line 0, got %d", (int)sym.line);
			assert(sym.col == 4, "expected col 4, got %d", (int)sym.col);
			assert(sym.name_len == 5, "expected name_len 5, got %d", (int)sym.name_len);
		} else {
			assert(false, "expected to find 'greet'");
		}
	};
}

fn void remove_one_file_keeps_other() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///a.kt", "fun alpha() {}");
		idx.index_file("file:///b.kt", "fun beta() {}");

		idx.remove_file("file:///a.kt");

		// alpha should be gone
		if (try indices = idx.lookup_by_name("alpha")) {
			assert(false, "expected 'alpha' to be removed");
		}

		// beta should still be there
		if (try indices = idx.lookup_by_name("beta")) {
			assert(indices.len() == 1, "expected 1 index for 'beta'");
		} else {
			assert(false, "expected to find 'beta'");
		}
	};
}

fn void set_root_stores_path() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.set_root("file:///Users/test/project");
		assert(idx.root_uri == "file:///Users/test/project", "expected root_uri match");
		assert(idx.root_path == "/Users/test/project", "expected root_path match");
	};
}

// ── #8: scan_package with soft keyword segments ────────────────────

fn void scan_package_soft_keyword_data() @test {
	@pool() {
		String pkg = workspace::scan_package("package data.model\n\nclass Foo {}");
		assert(pkg == "data.model", "expected 'data.model', got '%s'", pkg);
	};
}

fn void scan_package_soft_keyword_value() @test {
	@pool() {
		String pkg = workspace::scan_package("package value.types\n");
		assert(pkg == "value.types", "expected 'value.types', got '%s'", pkg);
	};
}

fn void scan_package_soft_keyword_annotation() @test {
	@pool() {
		String pkg = workspace::scan_package("package annotation.processor\n");
		assert(pkg == "annotation.processor", "expected 'annotation.processor', got '%s'", pkg);
	};
}

fn void scan_package_soft_keyword_inner() @test {
	@pool() {
		String pkg = workspace::scan_package("package inner.core\n");
		assert(pkg == "inner.core", "expected 'inner.core', got '%s'", pkg);
	};
}

// ── #11: remove_file compacts symbols correctly ────────────────────

fn void remove_file_compacts_symbols() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		// Index three files
		idx.index_file("file:///a.kt", "fun alpha() {}");
		idx.index_file("file:///b.kt", "fun beta() {}\nclass Bravo {}");
		idx.index_file("file:///c.kt", "fun charlie() {}");

		// Check initial state
		assert(idx.symbol_count() == 4, "expected 4 symbols initially, got %d", (int)idx.symbol_count());

		// Remove the middle file
		idx.remove_file("file:///b.kt");

		// Should have 2 symbols now (alpha + charlie), not 4 with gaps
		assert(idx.symbol_count() == 2, "expected 2 symbols after compaction, got %d", (int)idx.symbol_count());

		// alpha should still be findable
		if (try indices = idx.lookup_by_name("alpha")) {
			assert(indices.len() == 1, "expected 1 index for 'alpha'");
		} else {
			assert(false, "expected to find 'alpha' after compaction");
		}

		// charlie should still be findable
		if (try indices = idx.lookup_by_name("charlie")) {
			assert(indices.len() == 1, "expected 1 index for 'charlie'");
		} else {
			assert(false, "expected to find 'charlie' after compaction");
		}

		// beta and Bravo should be gone
		if (try indices = idx.lookup_by_name("beta")) {
			assert(false, "expected 'beta' to be removed");
		}
		if (try indices = idx.lookup_by_name("Bravo")) {
			assert(false, "expected 'Bravo' to be removed");
		}
	};
}

fn void remove_file_compaction_preserves_reindex() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///a.kt", "fun alpha() {}");
		idx.index_file("file:///b.kt", "fun beta() {}");
		idx.index_file("file:///c.kt", "fun charlie() {}");

		// Remove middle file, then re-index it with different content
		idx.remove_file("file:///b.kt");
		idx.index_file("file:///b.kt", "fun bravo() {}\nfun baker() {}");

		// Should have 4 symbols: alpha, bravo, baker, charlie
		assert(idx.symbol_count() == 4, "expected 4 symbols after re-index, got %d", (int)idx.symbol_count());

		// Old name should be gone
		if (try indices = idx.lookup_by_name("beta")) {
			assert(false, "expected 'beta' to be gone after re-index");
		}

		// New names should be present
		if (try indices = idx.lookup_by_name("bravo")) {
			assert(indices.len() == 1, "expected 1 index for 'bravo'");
		} else {
			assert(false, "expected to find 'bravo'");
		}
		if (try indices = idx.lookup_by_name("baker")) {
			assert(indices.len() == 1, "expected 1 index for 'baker'");
		} else {
			assert(false, "expected to find 'baker'");
		}
	};
}
