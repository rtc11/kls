module kls::test::workspace_test;

import kls::workspace;
import kls::kotlin::symbols;
import kls::kotlin::ast;
import kls::kotlin::parser;

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

// ── Member cache tests ─────────────────────────────────────────────

fn void member_cache_populated_on_index() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		String content =
`class MyService {
    fun fetchData(): String { return "" }
    fun process(input: String): Int { return 0 }
    val name: String = ""
    var count: Int = 0
}`;
		idx.index_file("file:///service.kt", content);

		// lookup_members should find "MyService"
		if (try members = idx.lookup_members("MyService")) {
			assert(members.len() == 4, "expected 4 members, got %d", (int)members.len());

			// Check function members
			bool found_fetch = false;
			bool found_process = false;
			bool found_name = false;
			bool found_count = false;
			for (usz i = 0; i < members.len(); i++) {
				MemberDecl* m = &(*members)[i];
				if (m.name == "fetchData") {
					found_fetch = true;
					assert(m.node_kind == FUN_DECL, "expected FUN_DECL for fetchData");
					assert(m.type_text == "String", "expected String return type, got '%s'", m.type_text);
					assert(m.param_count == 0, "fetchData has no params");
				}
				if (m.name == "process") {
					found_process = true;
					assert(m.node_kind == FUN_DECL, "expected FUN_DECL for process");
					assert(m.param_count == 1, "expected 1 param, got %d", (int)m.param_count);
					assert(m.param_names[0] == "input", "expected param name 'input', got '%s'", m.param_names[0]);
					assert(m.param_types[0] == "String", "expected param type 'String', got '%s'", m.param_types[0]);
				}
				if (m.name == "name") {
					found_name = true;
					assert(m.node_kind == PROPERTY_DECL, "expected PROPERTY_DECL for name");
					assert(m.type_text == "String", "expected String type, got '%s'", m.type_text);
				}
				if (m.name == "count") {
					found_count = true;
					assert(m.node_kind == PROPERTY_DECL, "expected PROPERTY_DECL for count");
					assert((m.mod_flags & ast::MOD_VAR) != 0, "expected VAR flag for count");
				}
			}
			assert(found_fetch, "expected 'fetchData' in member cache");
			assert(found_process, "expected 'process' in member cache");
			assert(found_name, "expected 'name' in member cache");
			assert(found_count, "expected 'count' in member cache");
		} else {
			assert(false, "expected member cache to have 'MyService' entries");
		}
	};
}

fn void member_cache_data_class_params() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///user.kt", "data class User(val name: String, val age: Int)");

		if (try members = idx.lookup_members("User")) {
			assert(members.len() == 2, "expected 2 members for data class, got %d", (int)members.len());

			bool found_name = false;
			bool found_age = false;
			for (usz i = 0; i < members.len(); i++) {
				MemberDecl* m = &(*members)[i];
				if (m.name == "name") {
					found_name = true;
					assert(m.node_kind == PARAM, "expected PARAM for data class val");
					assert(m.type_text == "String", "expected String type");
					assert((m.mod_flags & ast::MOD_FINAL) != 0, "expected FINAL flag for val");
				}
				if (m.name == "age") {
					found_age = true;
					assert(m.type_text == "Int", "expected Int type");
				}
			}
			assert(found_name, "expected 'name' member");
			assert(found_age, "expected 'age' member");
		} else {
			assert(false, "expected member cache for 'User'");
		}
	};
}

fn void member_cache_interface_members() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		String content =
`interface Repository {
    fun findAll(): List
    fun findById(id: Int): String
    val count: Int
}`;
		idx.index_file("file:///repo.kt", content);

		if (try members = idx.lookup_members("Repository")) {
			assert(members.len() == 3, "expected 3 members, got %d", (int)members.len());
		} else {
			assert(false, "expected member cache for 'Repository'");
		}
	};
}

fn void member_cache_invalidated_on_reindex() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		// First version
		String content1 =
`class Config {
    val host: String = "localhost"
    var port: Int = 8080
}`;
		idx.index_file("file:///config.kt", content1);

		if (try members = idx.lookup_members("Config")) {
			assert(members.len() == 2, "expected 2 members initially");
		} else {
			assert(false, "expected Config in member cache");
		}

		// Re-index with different members
		String content2 =
`class Config {
    val host: String = "localhost"
    var port: Int = 8080
    val timeout: Int = 30
}`;
		idx.index_file("file:///config.kt", content2);

		if (try members = idx.lookup_members("Config")) {
			assert(members.len() == 3, "expected 3 members after re-index, got %d", (int)members.len());

			bool found_timeout = false;
			for (usz i = 0; i < members.len(); i++) {
				MemberDecl* m = &(*members)[i];
				if (m.name == "timeout") found_timeout = true;
			}
			assert(found_timeout, "expected 'timeout' after re-index");
		} else {
			assert(false, "expected Config in member cache after re-index");
		}
	};
}

fn void member_cache_no_class_returns_fault() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		// Index a file with only functions, no classes
		idx.index_file("file:///utils.kt", "fun helperFunction() {}");

		// Should not have any member cache entries
		if (try members = idx.lookup_members("helperFunction")) {
			assert(false, "should not cache members for a function");
		}
	};
}

fn void member_cache_nested_class() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		String content =
`class Outer {
    fun outerMethod(): String { return "" }
    class Inner {
        fun innerMethod(): Int { return 0 }
    }
}`;
		idx.index_file("file:///outer.kt", content);

		if (try members = idx.lookup_members("Outer")) {
			bool found_method = false;
			bool found_inner = false;
			for (usz i = 0; i < members.len(); i++) {
				MemberDecl* m = &(*members)[i];
				if (m.name == "outerMethod") found_method = true;
				if (m.name == "Inner") {
					found_inner = true;
					assert(m.node_kind == CLASS_DECL, "expected CLASS_DECL for Inner");
				}
			}
			assert(found_method, "expected 'outerMethod'");
			assert(found_inner, "expected 'Inner' nested class");
		} else {
			assert(false, "expected member cache for 'Outer'");
		}
	};
}

fn void member_cache_uri_stored() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		idx.index_file("file:///models/user.kt", "class User { fun getName(): String { return \"\" } }");

		if (try members = idx.lookup_members("User")) {
			assert(members.len() >= 1, "expected at least 1 member");
			MemberDecl* m = &(*members)[0];
			assert(m.uri == "file:///models/user.kt", "expected URI to match, got '%s'", m.uri);
		} else {
			assert(false, "expected member cache for 'User'");
		}
	};
}

fn void member_cache_line_col_stored() @test {
	@pool() {
		WorkspaceIndex idx;
		idx.init();
		defer idx.free();

		String content =
`class Calc {
    fun add(a: Int, b: Int): Int { return a + b }
}`;
		idx.index_file("file:///calc.kt", content);

		if (try members = idx.lookup_members("Calc")) {
			assert(members.len() == 1, "expected 1 member");
			MemberDecl* m = &(*members)[0];
			assert(m.name == "add", "expected 'add'");
			assert(m.line == 1, "expected line 1, got %d", m.line);
			assert(m.param_count == 2, "expected 2 params, got %d", (int)m.param_count);
			assert(m.param_names[0] == "a", "expected first param 'a'");
			assert(m.param_names[1] == "b", "expected second param 'b'");
			assert(m.param_types[0] == "Int", "expected first param type 'Int'");
			assert(m.param_types[1] == "Int", "expected second param type 'Int'");
			assert(m.type_text == "Int", "expected return type 'Int'");
		} else {
			assert(false, "expected member cache for 'Calc'");
		}
	};
}

// ── Import map tests ───────────────────────────────────────────────

fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	r.free_errors();
	mem::free(r);
}

fn void import_map_explicit_import() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.Foo
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);
		assert(map.package_name == "com.example", "expected package 'com.example', got '%s'", map.package_name);
		assert(map.import_count == 1, "expected 1 import, got %d", (int)map.import_count);
		assert(map.import_names[0] == "Foo", "expected import name 'Foo', got '%s'", map.import_names[0]);
		assert(map.import_paths[0] == "com.other.Foo", "expected import path 'com.other.Foo', got '%s'", map.import_paths[0]);
		assert(!map.is_star[0], "expected non-star import");
	};
}

fn void import_map_star_import() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.*
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);
		assert(map.import_count == 1, "expected 1 import, got %d", (int)map.import_count);
		assert(map.is_star[0], "expected star import");
		assert(map.star_packages[0] == "com.other", "expected star package 'com.other', got '%s'", map.star_packages[0]);
	};
}

fn void import_map_aliased_import() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.Foo as MyFoo
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);
		assert(map.import_count == 1, "expected 1 import, got %d", (int)map.import_count);
		assert(map.import_names[0] == "MyFoo", "expected alias 'MyFoo', got '%s'", map.import_names[0]);
		assert(map.import_paths[0] == "com.other.Foo", "expected path 'com.other.Foo', got '%s'", map.import_paths[0]);
	};
}

fn void import_visibility_same_package() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);

		WorkspaceSymbol sym = { .name = "Foo", .package_name = "com.example" };
		String visible = workspace::is_symbol_visible(&sym, &map, "Foo");
		assert(visible.len > 0, "same-package symbol should be visible");
		assert(visible == "Foo", "visible name should be 'Foo', got '%s'", visible);
	};
}

fn void import_visibility_explicit_import() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.Foo
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);

		WorkspaceSymbol sym = { .name = "Foo", .package_name = "com.other" };
		String visible = workspace::is_symbol_visible(&sym, &map, "Foo");
		assert(visible.len > 0, "explicitly imported symbol should be visible");
	};
}

fn void import_visibility_star_import() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.*
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);

		WorkspaceSymbol sym = { .name = "Foo", .package_name = "com.other" };
		String visible = workspace::is_symbol_visible(&sym, &map, "Foo");
		assert(visible.len > 0, "star-imported symbol should be visible");
	};
}

fn void import_visibility_not_imported() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.Bar
			class Baz {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);

		WorkspaceSymbol sym = { .name = "Foo", .package_name = "com.unrelated" };
		String visible = workspace::is_symbol_visible(&sym, &map, "Foo");
		assert(visible.len == 0, "non-imported symbol from different package should not be visible");
	};
}

fn void import_visibility_aliased_import() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.other.Foo as MyFoo
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);

		WorkspaceSymbol sym = { .name = "Foo", .package_name = "com.other" };

		// Lookup with alias name should succeed
		String visible_alias = workspace::is_symbol_visible(&sym, &map, "MyFoo");
		assert(visible_alias.len > 0, "aliased import should be visible with alias name");
		assert(visible_alias == "MyFoo", "visible name should be alias 'MyFoo', got '%s'", visible_alias);

		// Lookup with real name should NOT match (alias replaces the name)
		String visible_real = workspace::is_symbol_visible(&sym, &map, "Foo");
		assert(visible_real.len == 0, "aliased import should NOT be visible with real name");
	};
}

fn void import_visibility_no_package_symbol() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);

		// Symbol with no package — NOT visible from a file with a package declaration
		// (reduces false positives from package-less files leaking globally)
		WorkspaceSymbol sym = { .name = "Foo", .package_name = "" };
		String visible = workspace::is_symbol_visible(&sym, &map, "Foo");
		assert(visible.len == 0, "no-package symbol should NOT be visible from packaged file");

		// But visible from a file that also has no package
		ParseResult* r2 = do_parse(`class Baz {}`); defer free_result(r2);
		ImportMap map2 = workspace::build_import_map(r2);
		String visible2 = workspace::is_symbol_visible(&sym, &map2, "Foo");
		assert(visible2.len > 0, "no-package symbol should be visible from no-package file");
	};
}

fn void import_map_multiple_imports() @test {
	@pool() {
		ParseResult* r = do_parse(
			`package com.example
			import com.a.Foo
			import com.b.*
			import com.c.Baz as MyBaz
			class Bar {}`); defer free_result(r);

		ImportMap map = workspace::build_import_map(r);
		assert(map.import_count == 3, "expected 3 imports, got %d", (int)map.import_count);
		assert(map.import_names[0] == "Foo", "import 0 name");
		assert(!map.is_star[0], "import 0 not star");
		assert(map.is_star[1], "import 1 is star");
		assert(map.star_packages[1] == "com.b", "import 1 star package");
		assert(map.import_names[2] == "MyBaz", "import 2 alias");
	};
}

// ── get_symbol bounds-check sentinel ───────────────────────────────

fn void get_symbol_out_of_bounds_returns_sentinel() @test {
	WorkspaceIndex idx;
	idx.init();
	defer idx.free();

	idx.index_file("file:///t.kt", "package p\nclass Foo {}");
	usz n = idx.symbols.len();
	assert(n > 0, "expected at least one symbol");

	// Stale / out-of-bounds index must return sentinel, not crash.
	WorkspaceSymbol* s = idx.get_symbol(n + 100);
	assert(s != null, "sentinel must be non-null");
	assert(s.name.len == 0, "sentinel must have empty name");
	assert(s.uri.len == 0, "sentinel must have empty uri");
}

fn void get_symbol_after_remove_file_handles_stale_indices() @test {
	WorkspaceIndex idx;
	idx.init();
	defer idx.free();

	idx.index_file("file:///a.kt", "package p\nclass A {}\nclass B {}");
	usz before = idx.symbols.len();
	idx.remove_file("file:///a.kt");
	usz after = idx.symbols.len();
	assert(after < before, "remove_file should compact symbols");

	// Indices that were valid before remove_file are now out of range.
	WorkspaceSymbol* s = idx.get_symbol(before - 1);
	assert(s.name.len == 0, "stale index must yield sentinel");
}
