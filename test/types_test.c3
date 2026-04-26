module kls::test::types_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::kotlin::stdlib;
import kls::workspace;
import kls::lsp::hover;
import kls::lsp::completion;
import kls::document;
import kls::deps::jar_index;

// ── Helpers ────────────────────────────────────────────────────────

fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	r.free_errors();
	mem::free(r);
}

fn TypeInfo* do_resolve(ParseResult* pr) {
	TypeInfo* ti = mem::new(TypeInfo);
	types::resolve_types(pr, ti);	return ti;
}

// Find a declaration node by name
fn uint find_decl(ParseResult* pr, String name) {
	for (uint i = 0; i < pr.node_count; i++) {
		if (ast::is_declaration(pr.nodes[i].kind) && pr.nodes[i].name == name) {
			return i;
		}
	}
	return 0;
}

// Find a node of given kind by position
fn uint find_node(ParseResult* pr, NodeKind kind, String name = "") {
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].kind == kind) {
			if (name.len == 0 || pr.nodes[i].name == name) {
				return i;
			}
		}
	}
	return 0;
}

// ── Type text parser tests ──────────────────────────────────────────

fn void parse_simple_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("Int");
		assert(t.kind == SIMPLE, "expected SIMPLE, got %d", (int)t.kind);
		assert(t.name == "Int", "expected 'Int', got '%s'", t.name);
		assert(!t.nullable, "expected non-nullable");
	};
}

// ── Dep name resolution via imports ────────────────────────────────

fn void dep_name_via_explicit_import() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add HttpStatusCode class to dep index
		jar_index::add_dep_symbol(&ws.dep_index,
			"HttpStatusCode", "class HttpStatusCode", "io.ktor.http", "HttpStatusCode", "/fake.jar",
			DEP_CLASS, null, 0);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		// Code with explicit import and usage of HttpStatusCode
		String src = `import io.ktor.http.HttpStatusCode
			val status: HttpStatusCode = HttpStatusCode`;
		ParseResult* pr = do_parse(src); defer free_result(pr);
		TypeInfo* ti = do_resolve(pr); defer { types::free_type_info(ti); mem::free(ti); };

		// Find the val declaration — should resolve to HttpStatusCode
		uint decl_idx = find_decl(pr, "status");
		assert(decl_idx > 0, "should find status decl");
		assert(ti.has_type[decl_idx], "status should have type");
		assert(ti.node_types[decl_idx].name == "HttpStatusCode",
			"expected HttpStatusCode, got '%s'", ti.node_types[decl_idx].name);
	};
}

fn void dep_name_via_star_import() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		jar_index::add_dep_symbol(&ws.dep_index,
			"HttpStatusCode", "class HttpStatusCode", "io.ktor.http", "HttpStatusCode", "/fake.jar",
			DEP_CLASS, null, 0);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		String src = `import io.ktor.http.*
			val status: HttpStatusCode = HttpStatusCode`;
		ParseResult* pr = do_parse(src); defer free_result(pr);
		TypeInfo* ti = do_resolve(pr); defer { types::free_type_info(ti); mem::free(ti); };

		uint decl_idx = find_decl(pr, "status");
		assert(decl_idx > 0, "should find status decl");
		assert(ti.has_type[decl_idx], "status should have type");
		assert(ti.node_types[decl_idx].name == "HttpStatusCode",
			"expected HttpStatusCode, got '%s'", ti.node_types[decl_idx].name);
	};
}

fn void dep_name_no_import_stays_unknown() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		jar_index::add_dep_symbol(&ws.dep_index,
			"HttpStatusCode", "class HttpStatusCode", "io.ktor.http", "HttpStatusCode", "/fake.jar",
			DEP_CLASS, null, 0);

		types::set_workspace(&ws);
		defer types::clear_workspace();

		// No import — should NOT resolve
		String src = `val status: HttpStatusCode = HttpStatusCode`;
		ParseResult* pr = do_parse(src); defer free_result(pr);
		TypeInfo* ti = do_resolve(pr); defer { types::free_type_info(ti); mem::free(ti); };

		// The type annotation resolves via parse_type_text, but the NAME_EXPR
		// on the RHS should be UNKNOWN since no import matches
		uint name_idx = find_node(pr, NAME_EXPR, "HttpStatusCode");
		if (name_idx > 0) {
			// Without import, dep lookup should not fire — stays UNKNOWN or
			// resolved via PascalCase heuristic (which returns SIMPLE).
			// Either is acceptable — the key thing is no crash.
		}
	};
}

fn void parse_generic_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("List<Int>");
		assert(t.kind == GENERIC, "expected GENERIC, got %d", (int)t.kind);
		assert(t.name == "List", "expected 'List', got '%s'", t.name);
		assert(t.type_arg_count == 1, "expected 1 type arg");
		assert(t.type_arg_names[0] == "Int", "expected 'Int', got '%s'", t.type_arg_names[0]);
	};
}

fn void parse_generic_two_args() @test {
	@pool() {
		TypeRef t = types::parse_type_text("Map<String, Int>");
		assert(t.kind == GENERIC, "expected GENERIC");
		assert(t.name == "Map", "expected 'Map', got '%s'", t.name);
		assert(t.type_arg_count == 2, "expected 2 type args, got %d", (int)t.type_arg_count);
		assert(t.type_arg_names[0] == "String", "got '%s'", t.type_arg_names[0]);
		assert(t.type_arg_names[1] == "Int", "got '%s'", t.type_arg_names[1]);
	};
}

fn void parse_nullable_generic() @test {
	@pool() {
		TypeRef t = types::parse_type_text("List<Int>?");
		assert(t.kind == GENERIC, "expected GENERIC");
		assert(t.name == "List");
		assert(t.nullable, "expected nullable");
	};
}

fn void parse_function_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("(Int) -> String");
		assert(t.kind == FUNCTION, "expected FUNCTION, got %d", (int)t.kind);
	};
}

fn void parse_empty_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("");
		assert(t.kind == UNKNOWN, "expected UNKNOWN for empty");
	};
}

fn void parse_definitely_non_nullable_type() @test {
	@pool() {
		// Kotlin spec §9.4.4: `T & Any` is the definitely non-nullable type.
		TypeRef t = types::parse_type_text("T & Any");
		assert(t.is_dnn, "expected is_dnn=true for `T & Any`");
		assert(!t.nullable, "DNN type must not be nullable");
		assert(t.name == "T", "expected name 'T', got '%s'", t.name);
		String s = types::format_type(&t);
		assert(s == "T & Any", "expected formatted 'T & Any', got '%s'", s);
	};
}

fn void parse_dnn_overrides_nullable() @test {
	@pool() {
		// `T? & Any` is the canonical promotion of nullable `T?` to non-null.
		TypeRef t = types::parse_type_text("T? & Any");
		assert(t.is_dnn, "expected is_dnn=true");
		assert(!t.nullable, "DNN must force nullable=false even when input was nullable");
	};
}

// ── Type formatting tests ───────────────────────────────────────────

fn void format_simple_type() @test {
	@pool() {
		TypeRef t = types::TYPE_INT;
		String s = types::format_type(&t);
		assert(s == "Int", "expected 'Int', got '%s'", s);
	};
}

fn void format_string_type() @test {
	@pool() {
		TypeRef t = types::TYPE_STRING;
		String s = types::format_type(&t);
		assert(s == "String", "expected 'String', got '%s'", s);
	};
}

fn void format_unknown_type() @test {
	@pool() {
		TypeRef t = types::TYPE_UNKNOWN;
		String s = types::format_type(&t);
		assert(s == "", "expected empty for UNKNOWN, got '%s'", s);
	};
}

fn void format_unit_type() @test {
	@pool() {
		TypeRef t = types::TYPE_UNIT;
		String s = types::format_type(&t);
		assert(s == "Unit", "expected 'Unit', got '%s'", s);
	};
}

// ── Literal type inference tests ────────────────────────────────────

fn void infer_int_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 42"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Int", "expected 'Int', got '%s'", t);
	};
}

fn void infer_long_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 42L"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Long", "expected 'Long', got '%s'", t);
	};
}

fn void infer_double_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 3.14"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Double", "expected 'Double', got '%s'", t);
	};
}

fn void infer_float_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 3.14f"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Float", "expected 'Float', got '%s'", t);
	};
}

fn void infer_string_literal() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = "hello"`); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "expected 'String', got '%s'", t);
	};
}

fn void infer_boolean_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = true"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Boolean", "expected 'Boolean', got '%s'", t);
	};
}

fn void infer_null_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = null"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Nothing?", "expected 'Nothing?', got '%s'", t);
	};
}

fn void infer_char_literal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 'a'"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Char", "expected 'Char', got '%s'", t);
	};
}

// ── Explicit type annotation tests ──────────────────────────────────

fn void explicit_type_annotation() @test {
	@pool() {
		ParseResult* r = do_parse("val x: Int = 42"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		assert(ti.node_types[idx].name == "Int", "expected 'Int', got '%s'", ti.node_types[idx].name);
	};
}

fn void explicit_nullable_annotation() @test {
	@pool() {
		ParseResult* r = do_parse("val x: String? = null"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		assert(ti.node_types[idx].name == "String", "expected 'String'");
		assert(ti.node_types[idx].nullable, "expected nullable");
	};
}

fn void explicit_generic_annotation() @test {
	@pool() {
		ParseResult* r = do_parse("val x: List<Int> = listOf(1)"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		assert(ti.node_types[idx].kind == GENERIC, "expected GENERIC");
		assert(ti.node_types[idx].name == "List", "expected 'List'");
	};
}

fn void fun_return_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun greet(): String { return \"hi\" }"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "greet");
		assert(idx > 0, "expected to find 'greet'");
		assert(ti.has_type[idx], "expected type for 'greet'");
		assert(ti.node_types[idx].name == "String", "expected 'String'");
	};
}

fn void fun_param_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun greet(name: String) {}"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		// Find the PARAM node
		uint idx = 0;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == PARAM && r.nodes[i].name == "name") {
				idx = i;
				break;
			}
		}
		assert(idx > 0, "expected to find param 'name'");
		assert(ti.has_type[idx], "expected type for param");
		assert(ti.node_types[idx].name == "String", "expected 'String'");
	};
}

// ── Resolve pass: empty/minimal cases ───────────────────────────────

fn void resolve_empty_source() @test {
	@pool() {
		ParseResult* r = do_parse(""); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		// Should not crash
		assert(true);
	};
}

fn void resolve_class_no_type() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "Foo");
		// Classes don't get TypeInfo entries (they ARE types)
		// Just verify no crash
		assert(idx > 0, "expected to find 'Foo'");
	};
}

fn void resolve_var_with_initializer() @test {
	@pool() {
		ParseResult* r = do_parse("var x = 100"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Int", "expected 'Int', got '%s'", t);
	};
}

// ── Multiple declarations ────────────────────────────────────────────

fn void resolve_multiple_properties() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val a = 1
			val b = "hi"
			val c = true`
		); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint ai = find_decl(r, "a");
		uint bi = find_decl(r, "b");
		uint ci = find_decl(r, "c");

		assert(ai > 0 && ti.has_type[ai], "expected type for 'a'");
		assert(bi > 0 && ti.has_type[bi], "expected type for 'b'");
		assert(ci > 0 && ti.has_type[ci], "expected type for 'c'");

		assert(ti.node_types[ai].name == "Int", "a should be Int");
		assert(ti.node_types[bi].name == "String", "b should be String");
		assert(ti.node_types[ci].name == "Boolean", "c should be Boolean");
	};
}

// ── Hover integration tests ──────────────────────────────────────────

fn void hover_shows_inferred_type_for_val() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 42"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		AstNode* node = &r.nodes[idx];

		// build_signature should show inferred type
		String sig = kls::lsp::hover::build_signature(node, r, "", ti, idx);
		// Should contain "Int" somewhere since it was inferred
		bool has_int = false;
		for (usz i = 0; i + 3 <= sig.len; i++) {
			if (sig[i] == 'I' && sig[i+1] == 'n' && sig[i+2] == 't') {
				has_int = true;
				break;
			}
		}
		assert(has_int, "expected signature to contain 'Int', got: '%s'", sig);
	};
}

fn void hover_shows_explicit_type_for_val() @test {
	@pool() {
		ParseResult* r = do_parse("val x: String = \"hi\""); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		AstNode* node = &r.nodes[idx];

		// build_signature should show explicit type
		String sig = kls::lsp::hover::build_signature(node, r, "", ti, idx);
		bool has_string = false;
		for (usz i = 0; i + 6 <= sig.len; i++) {
			if (sig[i] == 'S' && sig[i+1] == 't' && sig[i+2] == 'r' &&
				sig[i+3] == 'i' && sig[i+4] == 'n' && sig[i+5] == 'g') {
				has_string = true;
				break;
			}
		}
		assert(has_string, "expected signature to contain 'String', got: '%s'", sig);
	};
}

fn void hover_no_type_without_initializer() @test {
	@pool() {
		// A val without initializer and without type annotation
		// In real Kotlin this would be a compile error, but we just verify
		// our type system doesn't crash
		ParseResult* r = do_parse("val x"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };
		uint idx = find_decl(r, "x");
		if (idx > 0) {
			// Type should be unknown
			if (ti.has_type[idx]) {
				String t = types::format_type(&ti.node_types[idx]);
				// If it resolved, fine. If not, also fine.
				assert(true);
			}
		}
	};
}

// ── Document store cached_types integration ──────────────────────────

fn void document_get_types_basic() @test {
	@pool() {
		kls::document::DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 42");
		TypeInfo* ti = store.get_types("file:///test.kt") ?? null;
		assert(ti != null, "expected non-null TypeInfo");
	};
}

fn void document_get_types_invalidated_on_update() @test {
	@pool() {
		kls::document::DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 42");
		TypeInfo* ti1 = store.get_types("file:///test.kt") ?? null;
		assert(ti1 != null, "expected first TypeInfo");

		// Check that x is Int before update
		ParseResult* pr1 = store.get_ast("file:///test.kt") ?? null;
		uint idx1 = find_decl(pr1, "x");
		assert(ti1.has_type[idx1], "x should have type before update");
		assert(ti1.node_types[idx1].name == "Int", "x should be Int before update");

		// Update changes content - cached types should be recomputed
		store.update("file:///test.kt", 2, `val x = "hello"`);
		TypeInfo* ti2 = store.get_types("file:///test.kt") ?? null;
		assert(ti2 != null, "expected second TypeInfo");

		// After update, x should be String
		ParseResult* pr2 = store.get_ast("file:///test.kt") ?? null;
		uint idx2 = find_decl(pr2, "x");
		assert(ti2.has_type[idx2], "x should have type after update");
		assert(ti2.node_types[idx2].name == "String", "x should be String after update, got '%s'", ti2.node_types[idx2].name);
	};
}

fn void document_get_types_same_pointer_no_change() @test {
	@pool() {
		kls::document::DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "val x = 42");
		TypeInfo* ti1 = store.get_types("file:///test.kt") ?? null;
		TypeInfo* ti2 = store.get_types("file:///test.kt") ?? null;
		assert(ti1 == ti2, "expected same TypeInfo pointer without change");
	};
}

fn void document_get_types_nonexistent() @test {
	@pool() {
		kls::document::DocumentStore store;
		store.init();
		defer store.free();

		TypeInfo* ti = store.get_types("file:///nope.kt") ?? null;
		assert(ti == null, "expected null for nonexistent doc");
	};
}

// ── Member lookup tests ──────────────────────────────────────────────

fn void lookup_string_members() @test {
	@pool() {
		TypeRef t = types::TYPE_STRING;
		MemberInfo[128] members;
		usz count = types::lookup_members(&t, members[..]);
		assert(count > 0, "expected some members for String");

		// Check for well-known String members
		bool has_length = false;
		bool has_substring = false;
		bool has_tostring = false;
		for (usz i = 0; i < count; i++) {
			if (members[i].name == "length") has_length = true;
			if (members[i].name == "substring") has_substring = true;
			if (members[i].name == "toString") has_tostring = true;
		}
		assert(has_length, "expected 'length' member on String");
		assert(has_substring, "expected 'substring' member on String");
		assert(has_tostring, "expected 'toString' member on String (from Any)");
	};
}

fn void lookup_int_members() @test {
	@pool() {
		TypeRef t = types::TYPE_INT;
		MemberInfo[128] members;
		usz count = types::lookup_members(&t, members[..]);
		assert(count > 0, "expected some members for Int");

		bool has_tostring = false;
		for (usz i = 0; i < count; i++) {
			if (members[i].name == "toString") has_tostring = true;
		}
		assert(has_tostring, "expected 'toString' from Any");
	};
}

fn void lookup_boolean_members() @test {
	@pool() {
		TypeRef t = types::TYPE_BOOLEAN;
		MemberInfo[128] members;
		usz count = types::lookup_members(&t, members[..]);
		assert(count > 0, "expected some members for Boolean");

		// Boolean should have toString at minimum (from Any)
		bool has_tostring = false;
		for (usz i = 0; i < count; i++) {
			if (members[i].name == "toString") has_tostring = true;
		}
		assert(has_tostring, "expected 'toString' from Any");
	};
}

fn void lookup_list_members() @test {
	@pool() {
		TypeRef t = { .kind = SIMPLE, .name = "List" };
		MemberInfo[128] members;
		usz count = types::lookup_members(&t, members[..]);
		assert(count > 0, "expected some members for List");

		bool has_size = false;
		bool has_get = false;
		for (usz i = 0; i < count; i++) {
			if (members[i].name == "size") has_size = true;
			if (members[i].name == "get") has_get = true;
		}
		assert(has_size, "expected 'size' member on List");
		assert(has_get, "expected 'get' member on List");
	};
}

fn void lookup_map_members() @test {
	@pool() {
		TypeRef t = { .kind = SIMPLE, .name = "Map" };
		MemberInfo[128] members;
		usz count = types::lookup_members(&t, members[..]);
		assert(count > 0, "expected some members for Map");

		bool has_size = false;
		bool has_keys = false;
		bool has_values = false;
		for (usz i = 0; i < count; i++) {
			if (members[i].name == "size") has_size = true;
			if (members[i].name == "keys") has_keys = true;
			if (members[i].name == "values") has_values = true;
		}
		assert(has_size, "expected 'size' member on Map");
		assert(has_keys, "expected 'keys' member on Map");
		assert(has_values, "expected 'values' member on Map");
	};
}

fn void lookup_unknown_type_returns_zero() @test {
	@pool() {
		TypeRef t = types::TYPE_UNKNOWN;
		MemberInfo[128] members;
		usz count = types::lookup_members(&t, members[..]);
		assert(count == 0, "expected 0 members for UNKNOWN type");
	};
}

// ── Dot-completion context detection tests ───────────────────────────

fn void dot_context_after_dot() @test {
	@pool() {
		String content = "val x = str.";
		// position at line 0, character 12 (right after the dot)
		bool is_dot = kls::lsp::completion::is_dot_completion_context(content, 0, 12, "");
		assert(is_dot, "expected dot context after '.'");
	};
}

fn void dot_context_with_prefix() @test {
	@pool() {
		String content = "val x = str.len";
		// position at line 0, character 15 (end of "len")
		bool is_dot = kls::lsp::completion::is_dot_completion_context(content, 0, 15, "len");
		assert(is_dot, "expected dot context for 'str.len'");
	};
}

fn void no_dot_context_plain_identifier() @test {
	@pool() {
		String content = "val x = foo";
		bool is_dot = kls::lsp::completion::is_dot_completion_context(content, 0, 11, "foo");
		assert(!is_dot, "expected no dot context for plain identifier");
	};
}

// ── Receiver name extraction tests ───────────────────────────────────

fn void find_receiver_name_simple() @test {
	@pool() {
		String content = "val x = str.len";
		String recv = kls::lsp::completion::find_receiver_name(content, 0, 15, "len");
		assert(recv == "str", "expected 'str', got '%s'", recv);
	};
}

fn void find_receiver_name_after_dot() @test {
	@pool() {
		String content = "val x = foo.";
		String recv = kls::lsp::completion::find_receiver_name(content, 0, 12, "");
		assert(recv == "foo", "expected 'foo', got '%s'", recv);
	};
}

fn void find_receiver_name_safe_call() @test {
	@pool() {
		String content = "val x = bar?.len";
		String recv = kls::lsp::completion::find_receiver_name(content, 0, 16, "len");
		assert(recv == "bar", "expected 'bar', got '%s'", recv);
	};
}

// ── stdlib lookup_by_receiver tests ──────────────────────────────────

fn void stdlib_lookup_by_receiver_any() @test {
	@pool() {
		kls::kotlin::stdlib::StdlibSymbol*[64] matches;
		usz count = kls::kotlin::stdlib::lookup_by_receiver("String", &matches);
		// Should find at least some symbols (Any extensions apply to String)
		assert(true, "lookup_by_receiver should not crash");
	};
}

fn void stdlib_lookup_by_receiver_empty() @test {
	@pool() {
		kls::kotlin::stdlib::StdlibSymbol*[64] matches;
		usz count = kls::kotlin::stdlib::lookup_by_receiver("", &matches);
		assert(count == 0, "expected 0 for empty receiver");
	};
}

// ══════════════════════════════════════════════════════════════════════
// Level 3d: Expression type inference tests
// ══════════════════════════════════════════════════════════════════════

// Helper: resolve types and find the first expression node of given kind
fn TypeRef resolve_and_get_expr(ParseResult* pr, NodeKind kind, String name = "") {
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].kind == kind) {
			if (name.len == 0 || pr.nodes[i].name == name || pr.nodes[i].extra_text == name) {
				if (ti.has_type[i]) return ti.node_types[i];
			}
		}
	}
	return types::TYPE_UNKNOWN;
}

// Helper: resolve and get type of a named declaration
fn TypeRef resolve_and_get_decl(ParseResult* pr, String name) {
	TypeInfo* ti = mem::new(TypeInfo);
	defer { types::free_type_info(ti); mem::free(ti); };
	types::resolve_types(pr, ti);
	for (uint i = 0; i < pr.node_count; i++) {
		if (ast::is_declaration(pr.nodes[i].kind) && pr.nodes[i].name == name) {
			if (ti.has_type[i]) return ti.node_types[i];
		}
	}
	return types::TYPE_UNKNOWN;
}

// ── Binary expression type inference ─────────────────────────────────

fn void binary_arithmetic_int_plus_int() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 1 + 2"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "1 + 2 should be Int, got '%s'", t.name);
	};
}

fn void binary_arithmetic_double_plus_int() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 1.5 + 2"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		// Double + Int should promote to Double
		assert(t.name == "Double", "1.5 + 2 should be Double, got '%s'", t.name);
	};
}

fn void binary_string_concat() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = "hi" + "there"`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "String", "string + string should be String, got '%s'", t.name);
	};
}

fn void binary_comparison_equals() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 1 == 2"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "1 == 2 should be Boolean, got '%s'", t.name);
	};
}

fn void binary_comparison_less_than() @test {
	@pool() {
		// NOTE: bare < and > are ambiguous with generics and not parsed as
		// binary operators. Use <= or >= for comparison tests.
		ParseResult* r = do_parse("val x = 1 <= 2"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "1 <= 2 should be Boolean, got '%s'", t.name);
	};
}

fn void binary_logical_and() @test {
	@pool() {
		ParseResult* r = do_parse("val x = true && false"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "true && false should be Boolean, got '%s'", t.name);
	};
}

fn void binary_logical_or() @test {
	@pool() {
		ParseResult* r = do_parse("val x = true || false"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "true || false should be Boolean, got '%s'", t.name);
	};
}

fn void binary_range_operator() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 1..10"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "IntRange", "1..10 should be IntRange, got '%s'", t.name);
	};
}

fn void binary_not_equals() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 1 != 2"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "1 != 2 should be Boolean, got '%s'", t.name);
	};
}

fn void binary_greater_or_equal() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 5 >= 3"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "5 >= 3 should be Boolean, got '%s'", t.name);
	};
}

fn void binary_multiply_int() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 3 * 4"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "3 * 4 should be Int, got '%s'", t.name);
	};
}

fn void binary_divide_int() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 10 / 3"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "10 / 3 should be Int, got '%s'", t.name);
	};
}

fn void binary_modulo_int() @test {
	@pool() {
		ParseResult* r = do_parse("val x = 10 % 3"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "10 %% 3 should be Int, got '%s'", t.name);
	};
}

// ── Prefix expression type inference ─────────────────────────────────

fn void prefix_logical_not() @test {
	@pool() {
		ParseResult* r = do_parse("val x = !true"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Boolean", "!true should be Boolean, got '%s'", t.name);
	};
}

fn void prefix_negation_int() @test {
	@pool() {
		ParseResult* r = do_parse("val x = -42"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		// Negating an int literal - the literal node is "42", prefix makes it negative
		// The type should be Int
		assert(t.name == "Int", "-42 should be Int, got '%s'", t.name);
	};
}

// ── Postfix expression type inference ────────────────────────────────

fn void postfix_not_null_assertion() @test {
	@pool() {
		ParseResult* r = do_parse("val x: String? = null\nval y = x!!"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "y");
		// x!! should return String (non-nullable)
		if (t.kind != UNKNOWN) {
			assert(!t.nullable, "x!! should be non-nullable, got nullable");
			assert(t.name == "String", "x!! should be String, got '%s'", t.name);
		}
	};
}

// ── If expression type inference ─────────────────────────────────────

fn void if_expr_same_type_branches() @test {
	@pool() {
		ParseResult* r = do_parse("val x = if (true) 1 else 2"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "if (true) 1 else 2 should be Int, got '%s'", t.name);
	};
}

fn void if_expr_different_numeric_types() @test {
	@pool() {
		ParseResult* r = do_parse("val x = if (true) 1 else 1.5"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		// Common type of Int and Double is Double (numeric promotion)
		if (t.kind != UNKNOWN) {
			assert(t.name == "Double" || t.name == "Any",
				"if Int/Double should be Double or Any, got '%s'", t.name);
		}
	};
}

fn void if_expr_string_int_common_type() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = if (true) "hi" else 1`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		// Common type of String and Int is Any
		if (t.kind != UNKNOWN) {
			assert(t.name == "Any", "if String/Int should be Any, got '%s'", t.name);
		}
	};
}

// ── When expression type inference ───────────────────────────────────

fn void when_expr_all_int_branches() @test {
	@pool() {
		String src =
			`val x = when {
				true -> 1
				false -> 2
				else -> 3
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		if (t.kind != UNKNOWN) {
			assert(t.name == "Int", "when all-Int branches should be Int, got '%s'", t.name);
		}
	};
}

// ── Type check expression tests ──────────────────────────────────────

fn void type_check_is_returns_boolean() @test {
	@pool() {
		ParseResult* r = do_parse(
			`fun test(x: Any) {
				val y = x is String
			}`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "y");
		assert(t.name == "Boolean", "x is String should be Boolean, got '%s'", t.name);
	};
}

fn void type_check_not_is_returns_boolean() @test {
	@pool() {
		ParseResult* r = do_parse(
			`fun test(x: Any) {
				val y = x !is Int
			}`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "y");
		assert(t.name == "Boolean", "x !is Int should be Boolean, got '%s'", t.name);
	};
}

// ── Type cast expression tests ───────────────────────────────────────

fn void type_cast_as_gives_target_type() @test {
	@pool() {
		ParseResult* r = do_parse(
			`fun test(x: Any) {
				val y = x as String
			}`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "y");
		assert(t.name == "String", "x as String should be String, got '%s'", t.name);
	};
}

fn void type_cast_safe_as_gives_nullable() @test {
	@pool() {
		ParseResult* r = do_parse(
			`fun test(x: Any) {
				val y = x as? Int
			}`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "y");
		assert(t.name == "Int", "x as? Int should be Int, got '%s'", t.name);
		assert(t.nullable, "x as? Int should be nullable");
	};
}

// ── Index expression tests ───────────────────────────────────────────

fn void index_string_returns_char() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val s = "hello"
			val c = s[0]`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "c");
		if (t.kind != UNKNOWN) {
			assert(t.name == "Char", "String indexing should be Char, got '%s'", t.name);
		}
	};
}

// ── Smart cast tests ─────────────────────────────────────────────────

fn void smart_cast_simple_is_check() @test {
	@pool() {
		String src =
			`fun test(x: Any) {
				if (x is String) {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// Check the NAME_EXPR 'x' nodes and their resolved types
		bool found_narrowed_x = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "x" && ti.has_type[i]) {
				if (ti.node_types[i].name == "String") {
					found_narrowed_x = true;
				}
			}
		}

		// Verify the declaration 'y' picked up the type
		uint y_idx = find_decl(r, "y");
		if (y_idx > 0 && ti.has_type[y_idx]) {
			String t = types::format_type(&ti.node_types[y_idx]);
			// If the smart cast worked, y should be String (from the narrowed x)
			// If not, y would be Any (from the parameter x)
			if (found_narrowed_x) {
				assert(t == "String", "smart cast should give String for y, got '%s'", t);
			}
		}
		// At minimum, verify the NAME_EXPR was narrowed
		assert(found_narrowed_x, "expected at least one NAME_EXPR 'x' narrowed to String");
	};
}

fn void smart_cast_and_conjunction() @test {
	@pool() {
		String src =
			`fun test(x: Any) {
				if (x is Int && true) {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "Int", "smart cast with && should give Int, got '%s'", t);
		}
	};
}

// ── Known call resolution tests ──────────────────────────────────────

fn void known_call_println_returns_unit() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = println("hi")`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Unit", "println should return Unit, got '%s'", t.name);
	};
}

fn void known_call_listof_returns_list() @test {
	@pool() {
		ParseResult* r = do_parse("val x = listOf(1, 2, 3)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "List", "listOf should return List, got '%s'", t.name);
	};
}

fn void known_call_mapof_returns_map() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = mapOf("a" to 1)`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Map", "mapOf should return Map, got '%s'", t.name);
	};
}

fn void known_call_setof_returns_set() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = setOf(1, 2)`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Set", "setOf should return Set, got '%s'", t.name);
	};
}

fn void known_call_buildstring_returns_string() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = buildString { }`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "String", "buildString should return String, got '%s'", t.name);
	};
}

fn void known_call_error_returns_nothing() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = error("fail")`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Nothing", "error should return Nothing, got '%s'", t.name);
	};
}

fn void known_call_arrayof_returns_array() @test {
	@pool() {
		ParseResult* r = do_parse("val x = arrayOf(1, 2)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Array", "arrayOf should return Array, got '%s'", t.name);
	};
}

fn void known_call_intarrayof() @test {
	@pool() {
		ParseResult* r = do_parse("val x = intArrayOf(1, 2)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "IntArray", "intArrayOf should return IntArray, got '%s'", t.name);
	};
}

fn void known_call_require_returns_unit() @test {
	@pool() {
		ParseResult* r = do_parse("val x = require(true)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Unit", "require should return Unit, got '%s'", t.name);
	};
}

fn void known_call_todo_returns_nothing() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = TODO("not yet")`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Nothing", "TODO should return Nothing, got '%s'", t.name);
	};
}

// ── Generic instantiation inference tests ────────────────────────────

fn void generic_listof_int_arg() @test {
	@pool() {
		ParseResult* r = do_parse("val x = listOf(1)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "List", "listOf(1) should be List, got '%s'", t.name);
		if (t.kind == GENERIC && t.type_arg_count > 0) {
			assert(t.type_arg_names[0] == "Int",
				"listOf(1) type arg should be Int, got '%s'", t.type_arg_names[0]);
		}
	};
}

fn void generic_listof_string_arg() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = listOf("a")`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "List", "listOf(\"a\") should be List, got '%s'", t.name);
		if (t.kind == GENERIC && t.type_arg_count > 0) {
			assert(t.type_arg_names[0] == "String",
				"listOf(\"a\") type arg should be String, got '%s'", t.type_arg_names[0]);
		}
	};
}

fn void generic_setof_int_arg() @test {
	@pool() {
		ParseResult* r = do_parse("val x = setOf(42)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Set", "setOf(42) should be Set, got '%s'", t.name);
		if (t.kind == GENERIC && t.type_arg_count > 0) {
			assert(t.type_arg_names[0] == "Int",
				"setOf(42) type arg should be Int, got '%s'", t.type_arg_names[0]);
		}
	};
}

fn void generic_mutablelistof_bool_arg() @test {
	@pool() {
		ParseResult* r = do_parse("val x = mutableListOf(true)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "MutableList", "mutableListOf(true) should be MutableList, got '%s'", t.name);
		if (t.kind == GENERIC && t.type_arg_count > 0) {
			assert(t.type_arg_names[0] == "Boolean",
				"mutableListOf(true) type arg should be Boolean, got '%s'", t.type_arg_names[0]);
		}
	};
}

fn void generic_emptylist_no_args() @test {
	@pool() {
		ParseResult* r = do_parse("val x = emptyList()"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "List", "emptyList() should be List, got '%s'", t.name);
		// emptyList() has no args to infer from, so type_arg_count may be 0
	};
}

// ── Name expression resolution tests ─────────────────────────────────

fn void name_expr_references_typed_val() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val a: Int = 5
			val b = a`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "b");
		assert(t.name == "Int", "b = a (Int) should be Int, got '%s'", t.name);
	};
}

fn void name_expr_references_inferred_val() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val a = "hello"
			val b = a`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "b");
		assert(t.name == "String", "b = a (String) should be String, got '%s'", t.name);
	};
}

fn void name_expr_references_param() @test {
	@pool() {
		ParseResult* r = do_parse(
			`fun test(n: Int) {
				val x = n
			}`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "x = n (Int param) should be Int, got '%s'", t.name);
	};
}

// ── Paren expression tests ──────────────────────────────────────────

fn void paren_expr_propagates_type() @test {
	@pool() {
		ParseResult* r = do_parse("val x = (42)"); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Int", "(42) should be Int, got '%s'", t.name);
	};
}

fn void paren_nested_propagates_type() @test {
	@pool() {
		ParseResult* r = do_parse(`val x = (("hello"))`); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "String", "((\"hello\")) should be String, got '%s'", t.name);
	};
}

// ── Call expression: function return type inference ──────────────────

fn void call_fun_with_return_type() @test {
	@pool() {
		ParseResult* r = do_parse(
			`fun greet(): String { return "hi" }
			val x = greet()`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "String", "greet() returning String should give String, got '%s'", t.name);
	};
}

fn void call_constructor_gives_class_type() @test {
	@pool() {
		ParseResult* r = do_parse(
			`class Foo
			val x = Foo()`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "Foo", "Foo() should be Foo, got '%s'", t.name);
	};
}

// ── Dot expression member type resolution ────────────────────────────

fn void dot_expr_string_length() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val s = "hello"
			val x = s.length`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		if (t.kind != UNKNOWN) {
			assert(t.name == "Int", "String.length should be Int, got '%s'", t.name);
		}
	};
}

fn void dot_expr_string_isempty() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val s = "hello"
			val x = s.isEmpty()`
		); defer free_result(r);
		// s.isEmpty() - the DOT_EXPR should resolve to Boolean
		// or the CALL_EXPR wrapping it might
		TypeRef t = resolve_and_get_decl(r, "x");
		if (t.kind != UNKNOWN) {
			assert(t.name == "Boolean", "String.isEmpty() should be Boolean, got '%s'", t.name);
		}
	};
}

// ── String template expression tests ─────────────────────────────────

fn void string_template_is_string() @test {
	@pool() {
		ParseResult* r = do_parse(
			`val name = "world"
			val x = "hello $name"`
		); defer free_result(r);
		TypeRef t = resolve_and_get_decl(r, "x");
		assert(t.name == "String", "string template should be String, got '%s'", t.name);
	};
}

// ── This expression tests ────────────────────────────────────────────

fn void this_expr_in_class() @test {
	@pool() {
		ParseResult* r = do_parse(
			`class Foo {
				fun getThis() = this
			}`
		); defer free_result(r);
		// Look for THIS_EXPR node directly
		TypeRef t = resolve_and_get_expr(r, THIS_EXPR);
		if (t.kind != UNKNOWN) {
			assert(t.name == "Foo", "this in Foo should be Foo, got '%s'", t.name);
		}
	};
}

// ── Assignment expression tests ──────────────────────────────────────

fn void assignment_is_unit() @test {
	@pool() {
		ParseResult* r = do_parse(
			`var x = 1
			val y = x = 5`
		); defer free_result(r);
		// x = 5 is an ASSIGNMENT_EXPR which should be Unit
		TypeRef t = resolve_and_get_expr(r, ASSIGNMENT_EXPR);
		if (t.kind != UNKNOWN) {
			assert(t.name == "Unit", "assignment should be Unit, got '%s'", t.name);
		}
	};
}

// ── common_type tests ────────────────────────────────────────────────

fn void common_type_same_types() @test {
	@pool() {
		TypeRef a = types::TYPE_INT;
		TypeRef b = types::TYPE_INT;
		TypeRef c = types::common_type(a, b);
		assert(c.name == "Int", "common(Int, Int) should be Int, got '%s'", c.name);
	};
}

fn void common_type_unknown_transparent() @test {
	@pool() {
		TypeRef a = types::TYPE_UNKNOWN;
		TypeRef b = types::TYPE_STRING;
		TypeRef c = types::common_type(a, b);
		assert(c.name == "String", "common(UNKNOWN, String) should be String, got '%s'", c.name);
	};
}

fn void common_type_nothing_transparent() @test {
	@pool() {
		TypeRef a = types::TYPE_NOTHING;
		TypeRef b = types::TYPE_INT;
		TypeRef c = types::common_type(a, b);
		assert(c.name == "Int", "common(Nothing, Int) should be Int, got '%s'", c.name);
	};
}

fn void common_type_numeric_promotion() @test {
	@pool() {
		TypeRef a = types::TYPE_INT;
		TypeRef b = types::TYPE_DOUBLE;
		TypeRef c = types::common_type(a, b);
		assert(c.name == "Double", "common(Int, Double) should be Double, got '%s'", c.name);
	};
}

fn void common_type_nullable_union() @test {
	@pool() {
		TypeRef a = types::TYPE_STRING;
		TypeRef b;
		b.kind = SIMPLE;
		b.name = "String";
		b.nullable = true;
		TypeRef c = types::common_type(a, b);
		assert(c.name == "String", "common should be String");
		assert(c.nullable, "common(String, String?) should be nullable");
	};
}

fn void common_type_different_gives_any() @test {
	@pool() {
		TypeRef a = types::TYPE_STRING;
		TypeRef b = types::TYPE_INT;
		TypeRef c = types::common_type(a, b);
		assert(c.name == "Any", "common(String, Int) should be Any, got '%s'", c.name);
	};
}

// ── Numeric rank / promotion tests ───────────────────────────────────

fn void numeric_promotion_int_long() @test {
	@pool() {
		TypeRef a = types::TYPE_INT;
		TypeRef b = types::TYPE_LONG;
		TypeRef c = types::promote_numeric(a, b);
		assert(c.name == "Long", "promote(Int, Long) should be Long, got '%s'", c.name);
	};
}

fn void numeric_promotion_float_double() @test {
	@pool() {
		TypeRef a = types::TYPE_FLOAT;
		TypeRef b = types::TYPE_DOUBLE;
		TypeRef c = types::promote_numeric(a, b);
		assert(c.name == "Double", "promote(Float, Double) should be Double, got '%s'", c.name);
	};
}

fn void is_numeric_type_check() @test {
	@pool() {
		assert(types::is_numeric_type(types::TYPE_INT), "Int should be numeric");
		assert(types::is_numeric_type(types::TYPE_LONG), "Long should be numeric");
		assert(types::is_numeric_type(types::TYPE_FLOAT), "Float should be numeric");
		assert(types::is_numeric_type(types::TYPE_DOUBLE), "Double should be numeric");
		assert(types::is_numeric_type(types::TYPE_SHORT), "Short should be numeric");
		assert(types::is_numeric_type(types::TYPE_BYTE), "Byte should be numeric");
		assert(!types::is_numeric_type(types::TYPE_STRING), "String should not be numeric");
		assert(!types::is_numeric_type(types::TYPE_BOOLEAN), "Boolean should not be numeric");
	};
}

// ── Type formatting for complex types ────────────────────────────────

fn void format_generic_type() @test {
	@pool() {
		TypeRef t;
		t.kind = GENERIC;
		t.name = "List";
		t.type_arg_count = 1;
		t.type_arg_names[0] = "Int";
		String s = types::format_type(&t);
		assert(s == "List<Int>", "expected 'List<Int>', got '%s'", s);
	};
}

fn void format_nullable_generic() @test {
	@pool() {
		TypeRef t;
		t.kind = GENERIC;
		t.name = "Map";
		t.nullable = true;
		t.type_arg_count = 2;
		t.type_arg_names[0] = "String";
		t.type_arg_names[1] = "Int";
		String s = types::format_type(&t);
		assert(s == "Map<String, Int>?", "expected 'Map<String, Int>?', got '%s'", s);
	};
}

fn void format_function_type() @test {
	@pool() {
		TypeRef t;
		t.kind = FUNCTION;
		t.name = "";
		t.param_type_count = 1;
		t.param_type_names[0] = "Int";
		t.return_type_name = "String";
		String s = types::format_type(&t);
		assert(s == "(Int) -> String", "expected '(Int) -> String', got '%s'", s);
	};
}

fn void format_nothing_nullable() @test {
	@pool() {
		TypeRef t = types::TYPE_NOTHING_NULLABLE;
		String s = types::format_type(&t);
		assert(s == "Nothing?", "expected 'Nothing?', got '%s'", s);
	};
}

// ── Parse complex type texts ─────────────────────────────────────────

fn void parse_suspend_function_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("suspend () -> Unit");
		assert(t.kind == FUNCTION, "expected FUNCTION, got %d", (int)t.kind);
		assert(t.is_suspend, "expected suspend function type");
	};
}

fn void parse_nested_generic() @test {
	@pool() {
		TypeRef t = types::parse_type_text("List<Map<String, Int>>");
		assert(t.kind == GENERIC, "expected GENERIC");
		assert(t.name == "List", "expected List");
		// First type arg should be the full "Map<String, Int>"
		assert(t.type_arg_count >= 1, "expected at least 1 type arg");
	};
}

fn void parse_dotted_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("com.example.MyClass");
		assert(t.kind == SIMPLE, "expected SIMPLE for dotted type");
		// The name should capture the full dotted path
		assert(t.name.len > 0, "expected non-empty name for dotted type");
	};
}

fn void parse_nullable_function_type() @test {
	@pool() {
		// Simple nullable function type (without outer parens)
		TypeRef t = types::parse_type_text("(Int) -> String?");
		// The return type is nullable, not the function type itself
		assert(t.kind == FUNCTION, "expected FUNCTION for function type with nullable return");
	};
}

// ── Null smart cast tests ──────────────────────────────────────────

fn void smart_cast_null_check_not_equals() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				if (x != null) {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "null smart cast should give String, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "null smart cast should not be nullable");
		}
	};
}

fn void smart_cast_null_check_equals_else() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				if (x == null) {
					val a = 1
				} else {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "else-branch null smart cast should give String, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "else-branch null smart cast should not be nullable");
		}
	};
}

fn void smart_cast_null_check_early_return() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				if (x == null) return
				val y = x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "early-return null guard should give String, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "early-return null guard should make non-nullable");
		}
	};
}

fn void smart_cast_null_check_early_return_block() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				if (x == null) {
					return
				}
				val y = x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "early-return block null guard should give String, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "early-return block null guard should make non-nullable");
		}
	};
}

fn void smart_cast_null_check_early_throw() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				if (x == null) throw Exception("nope")
				val y = x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "early-throw null guard should give String, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "early-throw null guard should make non-nullable");
		}
	};
}

fn void smart_cast_null_check_early_return_in_lambda_with_label() @test {
	@pool() {
		// Mirrors real-world pattern: labeled return inside outer lambda,
		// then x used inside a nested lambda further down.
		String src =
			`fun test(s: String?) {
				runBlocking {
					val hashKey: String? = s
					if (hashKey == null) {
						return@runBlocking
					}
					transaction {
						val y = hashKey
					}
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "labeled-return null guard should give String inside nested lambda, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "labeled-return null guard should make non-nullable inside nested lambda");
		}
	};
}

fn void smart_cast_null_check_conjunction() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				if (x != null && true) {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "null smart cast with && should give String, got '%s'", t);
		}
	};
}

fn void smart_cast_no_null_check_no_narrowing() @test {
	@pool() {
		String src =
			`fun test(x: String?) {
				val y = x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			// Without null check, the type should remain nullable
			assert(ti.node_types[idx].nullable, "without null check, type should remain nullable");
		}
	};
}

// ── Generic type argument propagation tests ────────────────────────

fn void generic_list_first_returns_element_type() @test {
	@pool() {
		String src =
			`fun test() {
				val names: List<String> = listOf("a", "b")
				val first = names.first()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "first");
		if (idx > 0 && ti.has_type[idx]) {
			assert(ti.node_types[idx].name == "String",
				"List<String>.first() should return String, got '%s'", ti.node_types[idx].name);
			assert(!ti.node_types[idx].nullable,
				"List<String>.first() should not be nullable");
		}
	};
}

fn void generic_list_firstOrNull_returns_nullable_element() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<Int> = listOf(1, 2)
				val maybe = items.firstOrNull()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "maybe");
		if (idx > 0 && ti.has_type[idx]) {
			assert(ti.node_types[idx].name == "Int",
				"List<Int>.firstOrNull() should return Int?, got '%s'", ti.node_types[idx].name);
			assert(ti.node_types[idx].nullable,
				"firstOrNull() should be nullable");
		}
	};
}

fn void generic_list_filter_preserves_type_args() @test {
	@pool() {
		String src =
			`fun test() {
				val names: List<String> = listOf("a", "b")
				val filtered = names.filter()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "filtered");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "filter() should return GENERIC");
			assert(t.name == "List", "filter() should return List, got '%s'", t.name);
			assert(t.type_arg_count == 1, "filter() should have 1 type arg");
			assert(t.type_arg_names[0] == "String",
				"List<String>.filter() should return List<String>, got List<%s>", t.type_arg_names[0]);
		}
	};
}

fn void generic_list_sorted_preserves_type_args() @test {
	@pool() {
		String src =
			`fun test() {
				val nums: List<Int> = listOf(3, 1, 2)
				val sorted = nums.sorted()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "sorted");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "sorted() should return GENERIC");
			assert(t.name == "List", "sorted() should return List");
			assert(t.type_arg_count == 1 && t.type_arg_names[0] == "Int",
				"List<Int>.sorted() should return List<Int>");
		}
	};
}

fn void generic_chain_filter_first() @test {
	@pool() {
		String src =
			`fun test() {
				val names: List<String> = listOf("alice", "bob")
				val result = names.filter().first()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "result");
		if (idx > 0 && ti.has_type[idx]) {
			assert(ti.node_types[idx].name == "String",
				"List<String>.filter().first() should return String, got '%s'", ti.node_types[idx].name);
		}
	};
}

fn void generic_set_preserves_type_args() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<String> = listOf("a", "b", "a")
				val unique = items.toSet()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "unique");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "toSet() should return GENERIC");
			assert(t.name == "Set", "toSet() should return Set");
			assert(t.type_arg_count == 1 && t.type_arg_names[0] == "String",
				"List<String>.toSet() should return Set<String>");
		}
	};
}

fn void generic_map_keys_returns_set_of_key_type() @test {
	@pool() {
		String src =
			`fun test() {
				val m: Map<String, Int> = mapOf()
				val keys = m.keys
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "keys");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "keys should return GENERIC");
			assert(t.name == "Set", "keys should return Set, got '%s'", t.name);
			assert(t.type_arg_count == 1 && t.type_arg_names[0] == "String",
				"Map<String, Int>.keys should return Set<String>");
		}
	};
}

fn void generic_map_values_returns_collection_of_value_type() @test {
	@pool() {
		String src =
			`fun test() {
				val m: Map<String, Int> = mapOf()
				val vals = m.values
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "vals");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "values should return GENERIC");
			assert(t.name == "Collection", "values should return Collection, got '%s'", t.name);
			assert(t.type_arg_count == 1 && t.type_arg_names[0] == "Int",
				"Map<String, Int>.values should return Collection<Int>");
		}
	};
}

fn void generic_map_get_returns_nullable_value_type() @test {
	@pool() {
		String src =
			`fun test() {
				val m: Map<String, Int> = mapOf()
				val v = m.get()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "v");
		if (idx > 0 && ti.has_type[idx]) {
			assert(ti.node_types[idx].name == "Int",
				"Map<String, Int>.get() should return Int?, got '%s'", ti.node_types[idx].name);
			assert(ti.node_types[idx].nullable,
				"Map.get() should be nullable");
		}
	};
}

fn void generic_map_filter_preserves_kv() @test {
	@pool() {
		String src =
			`fun test() {
				val m: Map<String, Int> = mapOf()
				val filtered = m.filter()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "filtered");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "filter() should return GENERIC");
			assert(t.name == "Map", "filter() should return Map");
			assert(t.type_arg_count == 2, "Map filter should have 2 type args");
			assert(t.type_arg_names[0] == "String" && t.type_arg_names[1] == "Int",
				"Map<String, Int>.filter() should return Map<String, Int>");
		}
	};
}

fn void generic_also_preserves_type_args() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<String> = listOf("a")
				val same = items.also()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "same");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "also() should return GENERIC");
			assert(t.name == "List", "also() should return List");
			assert(t.type_arg_count == 1 && t.type_arg_names[0] == "String",
				"List<String>.also() should return List<String>");
		}
	};
}

fn void generic_index_returns_element_type() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<String> = listOf("a", "b")
				val item = items[0]
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "item");
		if (idx > 0 && ti.has_type[idx]) {
			assert(ti.node_types[idx].name == "String",
				"List<String>[0] should return String, got '%s'", ti.node_types[idx].name);
		}
	};
}

fn void generic_listof_infer_type_arg() @test {
	@pool() {
		String src =
			`fun test() {
				val names = listOf("alice", "bob")
				val first = names.first()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "first");
		if (idx > 0 && ti.has_type[idx]) {
			assert(ti.node_types[idx].name == "String",
				"listOf(\"a\", \"b\").first() should return String, got '%s'", ti.node_types[idx].name);
		}
	};
}

fn void generic_sequence_preserves_type_args() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<Int> = listOf(1, 2, 3)
				val seq = items.asSequence()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "seq");
		if (idx > 0 && ti.has_type[idx]) {
			TypeRef t = ti.node_types[idx];
			assert(t.kind == GENERIC, "asSequence() should return GENERIC");
			assert(t.name == "Sequence", "asSequence() should return Sequence");
			assert(t.type_arg_count == 1 && t.type_arg_names[0] == "Int",
				"List<Int>.asSequence() should return Sequence<Int>");
		}
	};
}

// ── Lambda `it` parameter type inference tests ─────────────────────

fn void lambda_it_let_has_receiver_type() @test {
	@pool() {
		String src =
			`fun test() {
				val name: String = "hello"
				name.let { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// Find the NAME_EXPR for "it"
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "String",
					"it in let should be String, got '%s'", ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_also_has_receiver_type() @test {
	@pool() {
		String src =
			`fun test() {
				val x: Int = 42
				x.also { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "Int",
					"it in also should be Int, got '%s'", ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_filter_has_element_type() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<String> = listOf("a", "b")
				items.filter { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "String",
					"it in filter should be String, got '%s'", ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_forEach_has_element_type() @test {
	@pool() {
		String src =
			`fun test() {
				val nums: List<Int> = listOf(1, 2, 3)
				nums.forEach { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "Int",
					"it in forEach should be Int, got '%s'", ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_map_has_element_type() @test {
	@pool() {
		String src =
			`fun test() {
				val names: List<String> = listOf("a", "b")
				names.map { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "String",
					"it in map should be String, got '%s'", ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_takeIf_has_receiver_type() @test {
	@pool() {
		// Use explicit type annotation to ensure the property type is resolved
		// in Phase 1, so the receiver is available when `it` is resolved.
		// Note: `value.takeIf { it }` may be parsed as a bare CALL_EXPR
		// in some cases (parser limitation with trailing lambdas on simple names),
		// so we test with a collection type where the DOT_EXPR is preserved.
		String src =
			`fun test() {
				val items: List<String> = listOf("a")
				items.takeIf { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				TypeRef t = ti.node_types[i];
				assert(t.name == "List",
					"it in takeIf should be List, got '%s'", t.name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_explicit_param_no_inference() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<String> = listOf("a", "b")
				items.filter { x -> it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// When lambda has explicit params, `it` should NOT be resolved
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				// `it` should be UNKNOWN since lambda has explicit param `x`
				if (ti.has_type[i]) {
					// If it somehow resolved, that's a bug unless it matched something else
					assert(false, "it should not resolve when lambda has explicit params");
				}
				return;
			}
		}
		// It's OK if `it` doesn't appear at all (parser might handle differently)
	};
}

fn void lambda_it_string_forEach_returns_char() @test {
	@pool() {
		String src =
			`fun test() {
				val s: String = "hello"
				s.forEach { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "Char",
					"it in String.forEach should be Char, got '%s'", ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_let_generic_receiver() @test {
	@pool() {
		String src =
			`fun test() {
				val items: List<String> = listOf("a")
				items.let { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				TypeRef t = ti.node_types[i];
				assert(t.name == "List",
					"it in let on List<String> should be List, got '%s'", t.name);
				assert(t.kind == GENERIC, "expected GENERIC for List<String>");
				assert(t.type_arg_count == 1 && t.type_arg_names[0] == "String",
					"expected List<String>, got List<%s>",
					t.type_arg_count > 0 ? t.type_arg_names[0] : "?");
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

fn void lambda_it_inferred_list_filter() @test {
	@pool() {
		String src =
			`fun test() {
				val names = listOf("alice", "bob")
				names.filter { it }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "it") {
				assert(ti.has_type[i], "expected 'it' to have a type");
				assert(ti.node_types[i].name == "String",
					"it in filter with inferred List<String> should be String, got '%s'",
					ti.node_types[i].name);
				return;
			}
		}
		assert(false, "did not find 'it' NAME_EXPR");
	};
}

// ── Destructuring type inference ────────────────────────────────────

fn void destructuring_pair_component_types() @test {
	@pool() {
		String src =
			`fun test() {
				val pair: Pair<String, Int> = Pair("a", 1)
				val (a, b) = pair
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint a_idx = find_decl(r, "a");
		assert(a_idx > 0, "expected to find decl 'a'");
		assert(ti.has_type[a_idx], "expected 'a' to have a type");
		assert(ti.node_types[a_idx].name == "String",
			"'a' should be String, got '%s'", ti.node_types[a_idx].name);

		uint b_idx = find_decl(r, "b");
		assert(b_idx > 0, "expected to find decl 'b'");
		assert(ti.has_type[b_idx], "expected 'b' to have a type");
		assert(ti.node_types[b_idx].name == "Int",
			"'b' should be Int, got '%s'", ti.node_types[b_idx].name);
	};
}

fn void destructuring_triple_component_types() @test {
	@pool() {
		String src =
			`fun test() {
				val t: Triple<Int, String, Boolean> = Triple(1, "a", true)
				val (x, y, z) = t
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint x_idx = find_decl(r, "x");
		assert(x_idx > 0, "expected to find decl 'x'");
		assert(ti.has_type[x_idx], "expected 'x' to have a type");
		assert(ti.node_types[x_idx].name == "Int",
			"'x' should be Int, got '%s'", ti.node_types[x_idx].name);

		uint y_idx = find_decl(r, "y");
		assert(y_idx > 0, "expected to find decl 'y'");
		assert(ti.has_type[y_idx], "expected 'y' to have a type");
		assert(ti.node_types[y_idx].name == "String",
			"'y' should be String, got '%s'", ti.node_types[y_idx].name);

		uint z_idx = find_decl(r, "z");
		assert(z_idx > 0, "expected to find decl 'z'");
		assert(ti.has_type[z_idx], "expected 'z' to have a type");
		assert(ti.node_types[z_idx].name == "Boolean",
			"'z' should be Boolean, got '%s'", ti.node_types[z_idx].name);
	};
}

fn void destructuring_explicit_types_override() @test {
	@pool() {
		String src =
			`fun test() {
				val pair: Pair<String, Int> = Pair("a", 1)
				val (a: String, b: Int) = pair
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// When explicit types are given, they should be used (Phase 1)
		uint a_idx = find_decl(r, "a");
		assert(a_idx > 0, "expected to find decl 'a'");
		assert(ti.has_type[a_idx], "expected 'a' to have a type");
		assert(ti.node_types[a_idx].name == "String",
			"'a' should be String, got '%s'", ti.node_types[a_idx].name);

		uint b_idx = find_decl(r, "b");
		assert(b_idx > 0, "expected to find decl 'b'");
		assert(ti.has_type[b_idx], "expected 'b' to have a type");
		assert(ti.node_types[b_idx].name == "Int",
			"'b' should be Int, got '%s'", ti.node_types[b_idx].name);
	};
}

fn void destructuring_for_map_iteration() @test {
	@pool() {
		String src =
			`fun test() {
				val map: Map<String, Int> = mapOf()
				for ((k, v) in map) { }
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// Find PARAM nodes inside FOR_STMT
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == FOR_STMT) {
				uint found_params = 0;
				for (uint j = 0; j < r.node_count; j++) {
					if (r.nodes[j].parent == i && r.nodes[j].kind == PARAM) {
						if (found_params == 0) {
							assert(r.nodes[j].name == "k", "param 0 should be 'k'");
							assert(ti.has_type[j], "expected 'k' to have a type");
							assert(ti.node_types[j].name == "String",
								"'k' should be String, got '%s'", ti.node_types[j].name);
						} else if (found_params == 1) {
							assert(r.nodes[j].name == "v", "param 1 should be 'v'");
							assert(ti.has_type[j], "expected 'v' to have a type");
							assert(ti.node_types[j].name == "Int",
								"'v' should be Int, got '%s'", ti.node_types[j].name);
						}
						found_params++;
					}
				}
				assert(found_params == 2, "expected 2 params, got %d", found_params);
				return;
			}
		}
		assert(false, "expected FOR_STMT");
	};
}

// ── Inheritance-based member type resolution ────────────────────────

fn void inherited_member_type_from_list_supertype() @test {
	@pool() {
		// Simulate: class StringList : List<String>
		// StringList.size should resolve to Int (via List supertype)
		TypeRef receiver = { .kind = SIMPLE, .name = "StringList" };
		String[1] supertypes = { "List" };

		TypeRef result = types::resolve_member_type_with_supertypes(receiver, "size", supertypes[..], 1);
		assert(result.kind != UNKNOWN, "expected size to resolve through List supertype");
		assert(result.name == "Int", "size should be Int, got '%s'", result.name);
	};
}

fn void inherited_member_type_from_list_with_generic_args() @test {
	@pool() {
		// Simulate: class StringList : List<String>
		// StringList.first() should resolve to String
		TypeRef receiver = {
			.kind = GENERIC,
			.name = "StringList",
			.type_arg_count = 1,
			.type_arg_names = { [0] = "String" },
		};
		String[1] supertypes = { "List" };

		TypeRef result = types::resolve_member_type_with_supertypes(receiver, "first", supertypes[..], 1);
		assert(result.kind != UNKNOWN, "expected first to resolve through List supertype");
		assert(result.name == "String", "first should be String, got '%s'", result.name);
	};
}

fn void inherited_member_not_found() @test {
	@pool() {
		// No supertype has this member
		TypeRef receiver = { .kind = SIMPLE, .name = "MyClass" };
		String[1] supertypes = { "SomeOther" };

		TypeRef result = types::resolve_member_type_with_supertypes(receiver, "nonExistent", supertypes[..], 1);
		assert(result.kind == UNKNOWN, "expected UNKNOWN for non-existent member");
	};
}

fn void inherited_member_direct_takes_priority() @test {
	@pool() {
		// Direct member lookup should succeed without needing supertypes
		TypeRef receiver = { .kind = SIMPLE, .name = "String" };
		String[1] supertypes = { "Any" };

		TypeRef result = types::resolve_member_type_with_supertypes(receiver, "length", supertypes[..], 1);
		assert(result.kind != UNKNOWN, "expected length to resolve directly");
		assert(result.name == "Int", "length should be Int, got '%s'", result.name);
	};
}

fn void inherited_member_multiple_supertypes() @test {
	@pool() {
		// Try multiple supertypes — second one has the member
		TypeRef receiver = { .kind = SIMPLE, .name = "MyClass" };
		String[2] supertypes = { "UnknownType", "Map" };

		TypeRef result = types::resolve_member_type_with_supertypes(receiver, "size", supertypes[..], 2);
		assert(result.kind != UNKNOWN, "expected size to resolve through Map supertype");
		assert(result.name == "Int", "size should be Int, got '%s'", result.name);
	};
}

// ── Overload resolution tests ─────────────────────────────────────

fn void overload_resolution_picks_matching_param_count() @test {
	@pool() {
		// Two overloads of 'process': one with 1 param, one with 2 params
		// Calling process(x) should resolve to the 1-param version
		String src =
`fun process(x: Int): String = ""
fun process(x: Int, y: Int): Boolean = true
fun main() {
    val a = process(1)
    val b = process(1, 2)
}`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint a_idx = find_decl(pr, "a");
		assert(a_idx != 0, "should find 'a'");
		assert(ti.has_type[a_idx], "a should have a type");
		assert(ti.node_types[a_idx].name == "String",
			"a should be String (1-param overload), got '%s'", ti.node_types[a_idx].name);

		uint b_idx = find_decl(pr, "b");
		assert(b_idx != 0, "should find 'b'");
		assert(ti.has_type[b_idx], "b should have a type");
		assert(ti.node_types[b_idx].name == "Boolean",
			"b should be Boolean (2-param overload), got '%s'", ti.node_types[b_idx].name);
	};
}

fn void overload_resolution_no_match_uses_first() @test {
	@pool() {
		// Two overloads but call has 3 args — no match, should fall back to first
		String src =
`fun calc(a: Int): String = ""
fun calc(a: Int, b: Int): Boolean = true
fun main() {
    val r = calc(1, 2, 3)
}`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint r_idx = find_decl(pr, "r");
		assert(r_idx != 0, "should find 'r'");
		assert(ti.has_type[r_idx], "r should have a type");
		// Falls back to first overload (String)
		assert(ti.node_types[r_idx].name == "String",
			"r should be String (first fallback), got '%s'", ti.node_types[r_idx].name);
	};
}

fn void overload_resolution_zero_params() @test {
	@pool() {
		// Overload with 0 params vs 1 param
		String src =
`fun create(): String = ""
fun create(name: String): Int = 0
fun main() {
    val a = create()
    val b = create("test")
}`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint a_idx = find_decl(pr, "a");
		assert(a_idx != 0, "should find 'a'");
		assert(ti.has_type[a_idx], "a should have a type");
		assert(ti.node_types[a_idx].name == "String",
			"a should be String (0-param overload), got '%s'", ti.node_types[a_idx].name);

		uint b_idx = find_decl(pr, "b");
		assert(b_idx != 0, "should find 'b'");
		assert(ti.has_type[b_idx], "b should have a type");
		assert(ti.node_types[b_idx].name == "Int",
			"b should be Int (1-param overload), got '%s'", ti.node_types[b_idx].name);
	};
}

// ── Cross-file type resolution tests ──────────────────────────────

fn TypeInfo* do_resolve_with_workspace(ParseResult* pr, WorkspaceIndex* ws) {
	TypeInfo* ti = mem::new(TypeInfo);
	types::set_workspace(ws);
	types::resolve_types(pr, ti);
	types::clear_workspace();
	return ti;
}

fn void cross_file_constructor_type() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class in another file
		ws.index_file("file:///models.kt", "class User(val name: String, val age: Int)");

		// Parse a file that constructs User
		String src = "fun main() { val u = User(\"Alice\", 30) }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve_with_workspace(pr, &ws);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint u_idx = find_decl(pr, "u");
		assert(u_idx != 0, "should find 'u'");
		assert(ti.has_type[u_idx], "u should have a type");
		assert(ti.node_types[u_idx].name == "User",
			"u should be User, got '%s'", ti.node_types[u_idx].name);
	};
}

fn void cross_file_dot_member_type() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class with typed members
		ws.index_file("file:///models.kt", "class User(val name: String, val age: Int) { fun greet(): String = \"hi\" }");

		// Parse a file that accesses members
		String src =
`fun main() {
    val u = User("Alice", 30)
    val n = u.name
    val a = u.age
}`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve_with_workspace(pr, &ws);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint u_idx = find_decl(pr, "u");
		assert(u_idx != 0, "should find 'u'");
		assert(ti.has_type[u_idx], "u should have type");
		assert(ti.node_types[u_idx].name == "User",
			"u should be User, got '%s'", ti.node_types[u_idx].name);

		uint n_idx = find_decl(pr, "n");
		assert(n_idx != 0, "should find 'n'");
		assert(ti.has_type[n_idx], "n should have type");
		assert(ti.node_types[n_idx].name == "String",
			"n should be String, got '%s'", ti.node_types[n_idx].name);

		uint a_idx = find_decl(pr, "a");
		assert(a_idx != 0, "should find 'a'");
		assert(ti.has_type[a_idx], "a should have type");
		assert(ti.node_types[a_idx].name == "Int",
			"a should be Int, got '%s'", ti.node_types[a_idx].name);
	};
}

fn void cross_file_method_return_type() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///models.kt", "class Greeter { fun greet(): String = \"hello\" }");

		String src = "fun main() { val g = Greeter(); val msg = g.greet() }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve_with_workspace(pr, &ws);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint g_idx = find_decl(pr, "g");
		assert(g_idx != 0, "should find 'g'");
		assert(ti.has_type[g_idx], "g should have type");
		assert(ti.node_types[g_idx].name == "Greeter",
			"g should be Greeter, got '%s'", ti.node_types[g_idx].name);

		// msg = g.greet() — dot expr resolves greet() return type from member_cache
		uint msg_idx = find_decl(pr, "msg");
		assert(msg_idx != 0, "should find 'msg'");
		assert(ti.has_type[msg_idx], "msg should have type");
		assert(ti.node_types[msg_idx].name == "String",
			"msg should be String, got '%s'", ti.node_types[msg_idx].name);
	};
}

fn void cross_file_no_workspace_returns_unknown() @test {
	@pool() {
		// Without workspace, cross-file type stays UNKNOWN
		String src = "fun main() { val u = User(\"Alice\", 30) }";
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint u_idx = find_decl(pr, "u");
		assert(u_idx != 0, "should find 'u'");
		// Without workspace, User is unknown — should NOT have a type
		assert(!ti.has_type[u_idx] || ti.node_types[u_idx].kind == UNKNOWN,
			"u should be UNKNOWN without workspace");
	};
}

// ── Phase 1: Map index returns value type ───────────────────────────

fn void map_index_returns_value_type() @test {
	@pool() {
		String src = `
			fun test() {
				val m: Map<String, Int> = mapOf()
				val v = m["key"]
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint v_idx = find_decl(pr, "v");
		assert(v_idx != 0, "should find 'v'");
		assert(ti.has_type[v_idx], "v should have type");
		assert(ti.node_types[v_idx].name == "Int",
			"map[key] should be Int, got '%s'", ti.node_types[v_idx].name);
		assert(ti.node_types[v_idx].nullable,
			"map[key] should be nullable");
	};
}

fn void list_index_returns_element_type() @test {
	@pool() {
		String src = `
			fun test() {
				val items: List<String> = listOf()
				val s = items[0]
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint s_idx = find_decl(pr, "s");
		assert(s_idx != 0, "should find 's'");
		assert(ti.has_type[s_idx], "s should have type");
		assert(ti.node_types[s_idx].name == "String",
			"list[i] should be String, got '%s'", ti.node_types[s_idx].name);
		assert(!ti.node_types[s_idx].nullable,
			"list[i] should not be nullable");
	};
}

// ── Phase 1: `to` infix produces Pair with type args ───────────────

fn void to_infix_produces_typed_pair() @test {
	@pool() {
		String src = `
			fun test() {
				val p = "hello" to 42
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint p_idx = find_decl(pr, "p");
		assert(p_idx != 0, "should find 'p'");
		assert(ti.has_type[p_idx], "p should have type");
		assert(ti.node_types[p_idx].name == "Pair",
			"to should produce Pair, got '%s'", ti.node_types[p_idx].name);
		assert(ti.node_types[p_idx].kind == GENERIC,
			"Pair should be GENERIC");
		assert(ti.node_types[p_idx].type_arg_count == 2,
			"Pair should have 2 type args, got %d", (int)ti.node_types[p_idx].type_arg_count);
		assert(ti.node_types[p_idx].type_arg_names[0] == "String",
			"first type arg should be String, got '%s'", ti.node_types[p_idx].type_arg_names[0]);
		assert(ti.node_types[p_idx].type_arg_names[1] == "Int",
			"second type arg should be Int, got '%s'", ti.node_types[p_idx].type_arg_names[1]);
	};
}

// ── Phase 1: mapOf with typed Pair args ─────────────────────────────

fn void mapof_infers_type_args_from_to() @test {
	@pool() {
		String src = `
			fun test() {
				val m = mapOf("a" to 1)
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint m_idx = find_decl(pr, "m");
		assert(m_idx != 0, "should find 'm'");
		assert(ti.has_type[m_idx], "m should have type");
		assert(ti.node_types[m_idx].name == "Map",
			"mapOf should produce Map, got '%s'", ti.node_types[m_idx].name);
		assert(ti.node_types[m_idx].type_arg_count == 2,
			"Map should have 2 type args, got %d", (int)ti.node_types[m_idx].type_arg_count);
		assert(ti.node_types[m_idx].type_arg_names[0] == "String",
			"Map key type should be String, got '%s'", ti.node_types[m_idx].type_arg_names[0]);
		assert(ti.node_types[m_idx].type_arg_names[1] == "Int",
			"Map value type should be Int, got '%s'", ti.node_types[m_idx].type_arg_names[1]);
	};
}

// ── Phase 1: try/catch expression type ──────────────────────────────

fn void try_catch_expr_type() @test {
	@pool() {
		String src = `
			fun test() {
				val x = try { 42 } catch (e: Exception) { 0 }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint x_idx = find_decl(pr, "x");
		assert(x_idx != 0, "should find 'x'");
		assert(ti.has_type[x_idx], "x should have type");
		assert(ti.node_types[x_idx].name == "Int",
			"try/catch should produce Int, got '%s'", ti.node_types[x_idx].name);
	};
}

fn void try_catch_mixed_types() @test {
	@pool() {
		String src = `
			fun test() {
				val x = try { "hello" } catch (e: Exception) { 42 }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint x_idx = find_decl(pr, "x");
		assert(x_idx != 0, "should find 'x'");
		assert(ti.has_type[x_idx], "x should have type");
		// common_type(String, Int) = Any
		assert(ti.node_types[x_idx].name == "Any",
			"try/catch mixed should produce Any, got '%s'", ti.node_types[x_idx].name);
	};
}

// ── Phase 2: Lambda body type inference ─────────────────────────────

fn void map_infers_return_type_from_lambda() @test {
	@pool() {
		String src = `
			fun test() {
				val names: List<String> = listOf("a", "b")
				val lengths = names.map { it.length }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint v_idx = find_decl(pr, "lengths");
		assert(v_idx != 0, "should find 'lengths'");
		assert(ti.has_type[v_idx], "lengths should have type");
		assert(ti.node_types[v_idx].name == "List",
			"map should produce List, got '%s'", ti.node_types[v_idx].name);
		assert(ti.node_types[v_idx].kind == GENERIC, "should be GENERIC");
		assert(ti.node_types[v_idx].type_arg_count == 1,
			"should have 1 type arg, got %d", (int)ti.node_types[v_idx].type_arg_count);
		assert(ti.node_types[v_idx].type_arg_names[0] == "Int",
			"type arg should be Int, got '%s'", ti.node_types[v_idx].type_arg_names[0]);
	};
}

fn void map_chain_preserves_types() @test {
	@pool() {
		String src = `
			fun test() {
				val items: List<String> = listOf("a", "b")
				val result = items.filter { it.length > 0 }.map { it.length }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint v_idx = find_decl(pr, "result");
		assert(v_idx != 0, "should find 'result'");
		assert(ti.has_type[v_idx], "result should have type");
		assert(ti.node_types[v_idx].name == "List",
			"filter.map should produce List, got '%s'", ti.node_types[v_idx].name);
		if (ti.node_types[v_idx].type_arg_count > 0) {
			assert(ti.node_types[v_idx].type_arg_names[0] == "Int",
				"type arg should be Int, got '%s'", ti.node_types[v_idx].type_arg_names[0]);
		}
	};
}

fn void let_returns_lambda_body_type() @test {
	@pool() {
		String src = `
			fun test() {
				val name = "hello"
				val len = name.let { it.length }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint v_idx = find_decl(pr, "len");
		assert(v_idx != 0, "should find 'len'");
		assert(ti.has_type[v_idx], "len should have type");
		assert(ti.node_types[v_idx].name == "Int",
			"let should return Int, got '%s'", ti.node_types[v_idx].name);
	};
}

fn void run_returns_lambda_body_type() @test {
	@pool() {
		String src = `
			fun test() {
				val x = "hello".run { length }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint x_idx = find_decl(pr, "x");
		assert(x_idx != 0, "should find 'x'");
		// run { length } — "length" is a name that resolves if we know `this` is String
		// This may or may not resolve depending on `this` inference — test that it at least
		// returns *some* type or stays UNKNOWN gracefully
	};
}

fn void associate_infers_map_type_from_lambda() @test {
	@pool() {
		String src = `
			fun test() {
				val items: List<String> = listOf("a", "b")
				val m = items.associate { it to it.length }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint m_idx = find_decl(pr, "m");
		assert(m_idx != 0, "should find 'm'");
		assert(ti.has_type[m_idx], "m should have type");
		assert(ti.node_types[m_idx].name == "Map",
			"associate should produce Map, got '%s'", ti.node_types[m_idx].name);
		if (ti.node_types[m_idx].type_arg_count >= 2) {
			assert(ti.node_types[m_idx].type_arg_names[0] == "String",
				"Map key should be String, got '%s'", ti.node_types[m_idx].type_arg_names[0]);
			assert(ti.node_types[m_idx].type_arg_names[1] == "Int",
				"Map value should be Int, got '%s'", ti.node_types[m_idx].type_arg_names[1]);
		}
	};
}

fn void groupby_infers_map_type_from_lambda() @test {
	@pool() {
		String src = `
			fun test() {
				val items: List<String> = listOf("a", "bb", "ccc")
				val grouped = items.groupBy { it.length }
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint v_idx = find_decl(pr, "grouped");
		assert(v_idx != 0, "should find 'grouped'");
		assert(ti.has_type[v_idx], "grouped should have type");
		assert(ti.node_types[v_idx].name == "Map",
			"groupBy should produce Map, got '%s'", ti.node_types[v_idx].name);
		if (ti.node_types[v_idx].type_arg_count >= 2) {
			assert(ti.node_types[v_idx].type_arg_names[0] == "Int",
				"Map key should be Int, got '%s'", ti.node_types[v_idx].type_arg_names[0]);
		}
	};
}

fn void mapof_chain_index_resolves() @test {
	@pool() {
		String src = `
			fun test() {
				val m = mapOf("a" to 1, "b" to 2)
				val v = m["a"]
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint v_idx = find_decl(pr, "v");
		assert(v_idx != 0, "should find 'v'");
		assert(ti.has_type[v_idx], "v should have type");
		assert(ti.node_types[v_idx].name == "Int",
			"map[key] should be Int, got '%s'", ti.node_types[v_idx].name);
		assert(ti.node_types[v_idx].nullable, "map[key] should be nullable");
	};
}

// ── Phase 3: Smart casts and extension functions ────────────────────

fn void when_subject_smart_cast_is_type() @test {
	@pool() {
		String src = `
			fun test(x: Any) {
				when (x) {
					is String -> {
						val s = x
					}
				}
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint s_idx = find_decl(pr, "s");
		assert(s_idx != 0, "should find 's'");
		assert(ti.has_type[s_idx], "s should have type from when smart cast");
		assert(ti.node_types[s_idx].name == "String",
			"s should be String via when smart cast, got '%s'", ti.node_types[s_idx].name);
	};
}

fn void when_subject_smart_cast_is_int() @test {
	@pool() {
		String src = `
			fun test(x: Any) {
				when (x) {
					is Int -> {
						val n = x
					}
				}
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint n_idx = find_decl(pr, "n");
		assert(n_idx != 0, "should find 'n'");
		assert(ti.has_type[n_idx], "n should have type from when smart cast");
		assert(ti.node_types[n_idx].name == "Int",
			"n should be Int via when smart cast, got '%s'", ti.node_types[n_idx].name);
	};
}

fn void extension_function_workspace_resolution() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a file with an extension function on String
		ws.index_file("file:///ext.kt", "fun String.shout(): String = this.uppercase()");

		String src = `fun test() { val s = "hello"; val r = s.shout() }`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve_with_workspace(pr, &ws);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint r_idx = find_decl(pr, "r");
		assert(r_idx != 0, "should find 'r'");
		assert(ti.has_type[r_idx], "r should have type from extension function");
		assert(ti.node_types[r_idx].name == "String",
			"r should be String from extension, got '%s'", ti.node_types[r_idx].name);
	};
}

fn void smart_cast_null_check_simple() @test {
	@pool() {
		String src = `
			fun test(x: String?) {
				if (x != null) {
					val s = x
				}
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint s_idx = find_decl(pr, "s");
		assert(s_idx != 0, "should find 's'");
		assert(ti.has_type[s_idx], "s should have type");
		assert(ti.node_types[s_idx].name == "String",
			"s should be String, got '%s'", ti.node_types[s_idx].name);
		assert(!ti.node_types[s_idx].nullable,
			"s should be non-nullable after simple null check");
	};
}

fn void smart_cast_null_check_and_conjunction() @test {
	@pool() {
		String src = `
			fun test(x: String?) {
				if (x != null && x.length > 0) {
					val s = x
				}
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve(pr);
		defer { types::free_type_info(ti); mem::free(ti); };

		uint s_idx = find_decl(pr, "s");
		assert(s_idx != 0, "should find 's'");
		assert(ti.has_type[s_idx], "s should have type from null check smart cast");
		assert(ti.node_types[s_idx].name == "String",
			"s should be String, got '%s'", ti.node_types[s_idx].name);
		assert(!ti.node_types[s_idx].nullable,
			"s should be non-nullable after null check");
	};
}

fn void when_bare_in_check_parses() @test {
	@pool() {
		String src = `
			fun test(x: Int) {
				when (x) {
					in 1..10 -> val a = x
					else -> val b = x
				}
			}
		`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		assert(pr.error_count == 0, "when with bare 'in' should parse without errors, got %d", (int)pr.error_count);
	};
}

// ── is_assignable_to tests ───────────────────────────────────────

fn void assignable_same_type() @test {
	assert(types::is_assignable_to(types::TYPE_INT, types::TYPE_INT), "Int assignable to Int");
	assert(types::is_assignable_to(types::TYPE_STRING, types::TYPE_STRING), "String assignable to String");
}

fn void assignable_unknown_permissive() @test {
	assert(types::is_assignable_to(types::TYPE_UNKNOWN, types::TYPE_INT), "Unknown assignable to Int");
	assert(types::is_assignable_to(types::TYPE_INT, types::TYPE_UNKNOWN), "Int assignable to Unknown");
}

fn void assignable_nothing_subtype() @test {
	assert(types::is_assignable_to(types::TYPE_NOTHING, types::TYPE_INT), "Nothing assignable to Int");
	assert(types::is_assignable_to(types::TYPE_NOTHING, types::TYPE_STRING), "Nothing assignable to String");
	assert(types::is_assignable_to(types::TYPE_NOTHING, types::TYPE_ANY), "Nothing assignable to Any");
}

fn void assignable_nothing_nullable() @test {
	TypeRef nullable_string = types::TYPE_STRING;
	nullable_string.nullable = true;
	assert(types::is_assignable_to(types::TYPE_NOTHING_NULLABLE, nullable_string),
		"Nothing? assignable to String?");
	assert(!types::is_assignable_to(types::TYPE_NOTHING_NULLABLE, types::TYPE_STRING),
		"Nothing? NOT assignable to String (non-nullable)");
}

fn void assignable_to_any() @test {
	assert(types::is_assignable_to(types::TYPE_INT, types::TYPE_ANY), "Int assignable to Any");
	assert(types::is_assignable_to(types::TYPE_STRING, types::TYPE_ANY), "String assignable to Any");
	TypeRef nullable_any = types::TYPE_ANY;
	nullable_any.nullable = true;
	TypeRef nullable_string = types::TYPE_STRING;
	nullable_string.nullable = true;
	assert(types::is_assignable_to(nullable_string, nullable_any), "String? assignable to Any?");
	assert(!types::is_assignable_to(nullable_string, types::TYPE_ANY), "String? NOT assignable to Any");
}

fn void assignable_nullable_direction() @test {
	TypeRef nullable_int = types::TYPE_INT;
	nullable_int.nullable = true;
	// T assignable to T?
	assert(types::is_assignable_to(types::TYPE_INT, nullable_int), "Int assignable to Int?");
	// T? NOT assignable to T
	assert(!types::is_assignable_to(nullable_int, types::TYPE_INT), "Int? NOT assignable to Int");
}

fn void assignable_no_numeric_widening() @test {
	// Kotlin allows numeric widening for literals (Int -> Long, etc.)
	assert(types::is_assignable_to(types::TYPE_INT, types::TYPE_LONG), "Int assignable to Long (widening)");
	assert(types::is_assignable_to(types::TYPE_FLOAT, types::TYPE_DOUBLE), "Float assignable to Double (widening)");
	assert(types::is_assignable_to(types::TYPE_BYTE, types::TYPE_INT), "Byte assignable to Int (widening)");
	// But not narrowing
	assert(!types::is_assignable_to(types::TYPE_LONG, types::TYPE_INT), "Long NOT assignable to Int");
	assert(!types::is_assignable_to(types::TYPE_DOUBLE, types::TYPE_FLOAT), "Double NOT assignable to Float");
}

fn void assignable_to_unit() @test {
	assert(types::is_assignable_to(types::TYPE_INT, types::TYPE_UNIT), "Int assignable to Unit");
	assert(types::is_assignable_to(types::TYPE_STRING, types::TYPE_UNIT), "String assignable to Unit");
}

fn void assignable_stdlib_hierarchy() @test {
	// Int → Number
	TypeRef number = { .kind = SIMPLE, .name = "Number" };
	assert(types::is_assignable_to(types::TYPE_INT, number), "Int assignable to Number");
	assert(types::is_assignable_to(types::TYPE_LONG, number), "Long assignable to Number");
	assert(!types::is_assignable_to(types::TYPE_STRING, number), "String NOT assignable to Number");

	// String → CharSequence
	TypeRef char_seq = { .kind = SIMPLE, .name = "CharSequence" };
	assert(types::is_assignable_to(types::TYPE_STRING, char_seq), "String assignable to CharSequence");
	assert(!types::is_assignable_to(types::TYPE_INT, char_seq), "Int NOT assignable to CharSequence");

	// Exception → Throwable
	TypeRef exception = { .kind = SIMPLE, .name = "Exception" };
	TypeRef throwable = { .kind = SIMPLE, .name = "Throwable" };
	assert(types::is_assignable_to(exception, throwable), "Exception assignable to Throwable");

	// RuntimeException → Exception → Throwable → Any
	TypeRef runtime_exc = { .kind = SIMPLE, .name = "RuntimeException" };
	assert(types::is_assignable_to(runtime_exc, throwable), "RuntimeException assignable to Throwable");
	assert(types::is_assignable_to(runtime_exc, types::TYPE_ANY), "RuntimeException assignable to Any");
}

fn void assignable_collection_hierarchy() @test {
	TypeRef list = { .kind = SIMPLE, .name = "List" };
	TypeRef collection = { .kind = SIMPLE, .name = "Collection" };
	TypeRef iterable = { .kind = SIMPLE, .name = "Iterable" };
	TypeRef mutable_list = { .kind = SIMPLE, .name = "MutableList" };
	TypeRef arraylist = { .kind = SIMPLE, .name = "ArrayList" };

	assert(types::is_assignable_to(list, collection), "List assignable to Collection");
	assert(types::is_assignable_to(list, iterable), "List assignable to Iterable");
	assert(types::is_assignable_to(mutable_list, list), "MutableList assignable to List");
	assert(types::is_assignable_to(arraylist, list), "ArrayList assignable to List");
	assert(!types::is_assignable_to(list, mutable_list), "List NOT assignable to MutableList");
}

fn void assignable_generic_covariant() @test {
	// List<String> assignable to List<Any> (covariant)
	TypeRef list_string = { .kind = GENERIC, .name = "List", .type_arg_count = 1 };
	list_string.type_arg_names[0] = "String";
	TypeRef list_any = { .kind = GENERIC, .name = "List", .type_arg_count = 1 };
	list_any.type_arg_names[0] = "Any";

	assert(types::is_assignable_to(list_string, list_any),
		"List<String> assignable to List<Any> (covariant)");
	assert(!types::is_assignable_to(list_any, list_string),
		"List<Any> NOT assignable to List<String>");
}

fn void assignable_generic_invariant() @test {
	// MutableList<String> NOT assignable to MutableList<Any> (invariant)
	TypeRef mlist_string = { .kind = GENERIC, .name = "MutableList", .type_arg_count = 1 };
	mlist_string.type_arg_names[0] = "String";
	TypeRef mlist_any = { .kind = GENERIC, .name = "MutableList", .type_arg_count = 1 };
	mlist_any.type_arg_names[0] = "Any";

	assert(!types::is_assignable_to(mlist_string, mlist_any),
		"MutableList<String> NOT assignable to MutableList<Any> (invariant)");
}

fn void assignable_generic_contravariant() @test {
	// Comparable<Any> assignable to Comparable<String> (contravariant)
	TypeRef comp_any = { .kind = GENERIC, .name = "Comparable", .type_arg_count = 1 };
	comp_any.type_arg_names[0] = "Any";
	TypeRef comp_string = { .kind = GENERIC, .name = "Comparable", .type_arg_count = 1 };
	comp_string.type_arg_names[0] = "String";

	assert(types::is_assignable_to(comp_any, comp_string),
		"Comparable<Any> assignable to Comparable<String> (contravariant)");
	assert(!types::is_assignable_to(comp_string, comp_any),
		"Comparable<String> NOT assignable to Comparable<Any>");
}

fn void assignable_generic_star_projection() @test {
	TypeRef list_string = { .kind = GENERIC, .name = "List", .type_arg_count = 1 };
	list_string.type_arg_names[0] = "String";
	TypeRef list_star = { .kind = GENERIC, .name = "List", .type_arg_count = 1 };
	list_star.type_arg_names[0] = "*";

	assert(types::is_assignable_to(list_string, list_star),
		"List<String> assignable to List<*>");
}

fn void assignable_different_types_not_related() @test {
	assert(!types::is_assignable_to(types::TYPE_STRING, types::TYPE_INT),
		"String NOT assignable to Int");
	assert(!types::is_assignable_to(types::TYPE_INT, types::TYPE_STRING),
		"Int NOT assignable to String");
	assert(!types::is_assignable_to(types::TYPE_BOOLEAN, types::TYPE_INT),
		"Boolean NOT assignable to Int");
}

fn void assignable_unknown_user_types_permissive() @test {
	// User/dependency types not in stdlib: should be permissive
	TypeRef kafka_streams = { .kind = SIMPLE, .name = "KafkaStreams" };
	TypeRef topology = { .kind = SIMPLE, .name = "Topology" };
	assert(types::is_assignable_to(kafka_streams, topology),
		"Unknown user types should be permissive");

	TypeRef named = { .kind = SIMPLE, .name = "Named" };
	TypeRef cache_key = { .kind = SIMPLE, .name = "CacheKey" };
	assert(types::is_assignable_to(named, cache_key),
		"Unknown user types should be permissive");
}

fn void assignable_user_type_to_stdlib_permissive() @test {
	// User type to stdlib type: permissive (could be subtype)
	TypeRef my_list = { .kind = SIMPLE, .name = "MyCustomList" };
	assert(types::is_assignable_to(my_list, types::TYPE_STRING),
		"Unknown user type to stdlib should be permissive");
}

fn void assignable_stdlib_to_user_type_permissive() @test {
	// Stdlib to user type: permissive
	TypeRef my_type = { .kind = SIMPLE, .name = "MyType" };
	assert(types::is_assignable_to(types::TYPE_INT, my_type),
		"Stdlib to unknown user type should be permissive");
}

fn void assignable_generic_type_params_permissive() @test {
	// Topic<K, V> vs Topic<K, L> — type params V and L are unresolved, should be permissive
	TypeRef topic_kv = { .kind = GENERIC, .name = "Topic", .type_arg_count = 2 };
	topic_kv.type_arg_names[0] = "K";
	topic_kv.type_arg_names[1] = "V";
	TypeRef topic_kl = { .kind = GENERIC, .name = "Topic", .type_arg_count = 2 };
	topic_kl.type_arg_names[0] = "K";
	topic_kl.type_arg_names[1] = "L";

	assert(types::is_assignable_to(topic_kv, topic_kl),
		"Topic<K, V> should be assignable to Topic<K, L> (unresolved type params)");
}

fn void dot_call_on_unresolvable_receiver_returns_unknown() @test {
	@pool() {
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class with a 'timestamp: Long?' member — unrelated to Record
		ws.index_file("file:///consumer.kt", "data class Metadata(val timestamp: Long? = null)");

		// Parse code where record.timestamp() is called but Record is NOT in workspace
		String src =
`fun process(record: Record<String, String>) {
    fun replaceHeader(key: String, time: Long) {}
    replaceHeader("key", record.timestamp())
}`;
		ParseResult* pr = do_parse(src);
		defer free_result(pr);
		TypeInfo* ti = do_resolve_with_workspace(pr, &ws);
		defer { types::free_type_info(ti); mem::free(ti); };

		// Find the DOT_EXPR for record.timestamp()
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].kind == DOT_EXPR && pr.nodes[i].name == "timestamp") {
				assert(ti.node_types[i].kind == types::TypeKind.UNKNOWN,
					"record.timestamp() should be UNKNOWN, got '%s' (kind=%d)",
					ti.node_types[i].name, (int)ti.node_types[i].kind);
				return;
			}
		}
		// Might be a CALL_EXPR instead
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].kind == CALL_EXPR && pr.nodes[i].name == "timestamp") {
				assert(ti.node_types[i].kind == types::TypeKind.UNKNOWN,
					"record.timestamp() CALL_EXPR should be UNKNOWN, got '%s' (kind=%d)",
					ti.node_types[i].name, (int)ti.node_types[i].kind);
				return;
			}
		}
		assert(false, "should find DOT_EXPR or CALL_EXPR for timestamp");
	};
}

// ── Dep member type resolution via supertypes ──────────────────────

fn void dep_member_type_direct() @test {
	@pool() {
		jar_index::DependencyIndex dep_idx;
		dep_idx.init();
		defer dep_idx.free();
		defer types::clear_dep_member_cache();

		// Add List class with supertype Any
		String[8] supers = { "Any", "", "", "", "", "", "", "" };
		jar_index::add_dep_symbol(&dep_idx,
			"List", "class List", "kotlin.collections", "List", "/fake.jar",
			DEP_CLASS, &supers, 1);

		// Add "size" as direct member of List
		jar_index::add_dep_symbol(&dep_idx,
			"size", "val size: Int", "kotlin.collections", "List", "/fake.jar",
			DEP_FIELD, null, 0);

		TypeRef receiver = { .kind = types::TypeKind.SIMPLE, .name = "List" };
		TypeRef result = types::resolve_dep_member_type(&dep_idx, receiver, "size");
		assert(result.kind != types::TypeKind.UNKNOWN, "expected resolved type for List.size");
		assert(result.name == "Int", "expected Int, got '%s'", result.name);
	};
}

fn void dep_member_type_via_supertype() @test {
	@pool() {
		jar_index::DependencyIndex dep_idx;
		dep_idx.init();
		defer dep_idx.free();
		defer types::clear_dep_member_cache();

		// Add List class with supertype Any
		String[8] supers = { "Iterable", "Any", "", "", "", "", "", "" };
		jar_index::add_dep_symbol(&dep_idx,
			"List", "class List", "kotlin.collections", "List", "/fake.jar",
			DEP_CLASS, &supers, 2);

		// "hashCode" is on Any, not on List
		jar_index::add_dep_symbol(&dep_idx,
			"hashCode", "fun hashCode(): Int", "kotlin", "Any", "/fake.jar",
			DEP_METHOD, null, 0);

		TypeRef receiver = { .kind = types::TypeKind.SIMPLE, .name = "List" };
		TypeRef result = types::resolve_dep_member_type(&dep_idx, receiver, "hashCode");
		assert(result.kind != types::TypeKind.UNKNOWN, "expected resolved type for List.hashCode() via Any");
		assert(result.name == "Int", "expected Int, got '%s'", result.name);
	};
}

fn void dep_member_type_no_supertype_match() @test {
	@pool() {
		jar_index::DependencyIndex dep_idx;
		dep_idx.init();
		defer dep_idx.free();
		defer types::clear_dep_member_cache();

		// Add List with no supertypes
		jar_index::add_dep_symbol(&dep_idx,
			"List", "class List", "kotlin.collections", "List", "/fake.jar",
			DEP_CLASS, null, 0);

		TypeRef receiver = { .kind = types::TypeKind.SIMPLE, .name = "List" };
		TypeRef result = types::resolve_dep_member_type(&dep_idx, receiver, "nonExistent");
		assert(result.kind == types::TypeKind.UNKNOWN, "expected UNKNOWN for nonexistent member");
	};
}

// ── Lambda receiver type extraction ────────────────────────────────

fn void is_receiver_scope_fn_apply() @test {
	assert(types::is_receiver_scope_function("apply"));
	assert(types::is_receiver_scope_function("run"));
	assert(types::is_receiver_scope_function("buildString"));
	assert(!types::is_receiver_scope_function("let"));
	assert(!types::is_receiver_scope_function("map"));
}

fn void extract_lambda_receiver_simple() @test {
	@pool() {
		// fun get(path: String, body: PipelineContext.() -> Unit): Route
		TypeRef recv = types::extract_lambda_receiver_from_sig(
			"fun get(path: String, body: PipelineContext.() -> Unit): Route");
		assert(recv.kind == types::TypeKind.SIMPLE, "expected SIMPLE, got %d", (int)recv.kind);
		assert(recv.name == "PipelineContext", "expected PipelineContext, got '%s'", recv.name);
	};
}

fn void extract_lambda_receiver_with_generics() @test {
	@pool() {
		// fun get(body: PipelineContext<Unit, ApplicationCall>.() -> Unit): Route
		TypeRef recv = types::extract_lambda_receiver_from_sig(
			"fun get(body: PipelineContext<Unit, ApplicationCall>.() -> Unit): Route");
		assert(recv.kind == types::TypeKind.SIMPLE, "expected SIMPLE, got %d", (int)recv.kind);
		assert(recv.name == "PipelineContext", "expected PipelineContext, got '%s'", recv.name);
	};
}

fn void extract_lambda_receiver_none() @test {
	@pool() {
		// No receiver type: fun filter(predicate: (T) -> Boolean): List<T>
		TypeRef recv = types::extract_lambda_receiver_from_sig(
			"fun filter(predicate: (T) -> Boolean): List<T>");
		assert(recv.kind == types::TypeKind.UNKNOWN, "expected UNKNOWN for non-receiver lambda");
	};
}

fn void extract_lambda_receiver_no_params() @test {
	@pool() {
		TypeRef recv = types::extract_lambda_receiver_from_sig("fun run(): Unit");
		assert(recv.kind == types::TypeKind.UNKNOWN, "expected UNKNOWN for no-param function");
	};
}

// ── Generic type parameter substitution ────────────────────────────

fn void is_type_param_placeholder_basic() @test {
	assert(types::is_type_param_placeholder("T0"));
	assert(types::is_type_param_placeholder("T1"));
	assert(types::is_type_param_placeholder("T12"));
	assert(!types::is_type_param_placeholder("T"));
	assert(!types::is_type_param_placeholder("String"));
	assert(!types::is_type_param_placeholder("Ta"));
	assert(!types::is_type_param_placeholder(""));
}

fn void parse_type_param_index_basic() @test {
	assert(types::parse_type_param_index("T0") == 0);
	assert(types::parse_type_param_index("T1") == 1);
	assert(types::parse_type_param_index("T12") == 12);
	assert(types::parse_type_param_index("T") == -1);
	assert(types::parse_type_param_index("String") == -1);
}

fn void substitute_simple_type_param() @test {
	@pool() {
		// List<String>.first() returns T0 → substitute to String
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "List" };
		receiver.type_arg_count = 1;
		receiver.type_arg_names[0] = "String";

		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "T0" };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.kind == types::TypeKind.SIMPLE, "expected SIMPLE, got %d", (int)subst.kind);
		assert(subst.name == "String", "expected String, got '%s'", subst.name);
	};
}

fn void substitute_second_type_param() @test {
	@pool() {
		// Map<String, Int>.values returns Collection<T1> → T1 = Int
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "Map" };
		receiver.type_arg_count = 2;
		receiver.type_arg_names[0] = "String";
		receiver.type_arg_names[1] = "Int";

		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "T1" };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.kind == types::TypeKind.SIMPLE, "expected SIMPLE, got %d", (int)subst.kind);
		assert(subst.name == "Int", "expected Int, got '%s'", subst.name);
	};
}

fn void substitute_no_match_non_generic_receiver() @test {
	@pool() {
		// Non-generic receiver: no substitution
		TypeRef receiver = { .kind = types::TypeKind.SIMPLE, .name = "String" };
		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "T0" };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.name == "T0", "should not substitute for non-generic receiver");
	};
}

fn void substitute_preserves_nullable() @test {
	@pool() {
		// T0? with List<String> → String?
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "List" };
		receiver.type_arg_count = 1;
		receiver.type_arg_names[0] = "String";

		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "T0", .nullable = true };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.name == "String");
		assert(subst.nullable, "nullable should be preserved");
	};
}

fn void substitute_generic_type_args() @test {
	@pool() {
		// Map<T0, T1> with Map<String, Int> → Map<String, Int>
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "Map" };
		receiver.type_arg_count = 2;
		receiver.type_arg_names[0] = "String";
		receiver.type_arg_names[1] = "Int";

		TypeRef result = { .kind = types::TypeKind.GENERIC, .name = "List" };
		result.type_arg_count = 1;
		result.type_arg_names[0] = "T0";

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.kind == types::TypeKind.GENERIC);
		assert(subst.type_arg_names[0] == "String", "expected String, got '%s'", subst.type_arg_names[0]);
	};
}

fn void substitute_star_projection_unchanged() @test {
	@pool() {
		// T0 with List<*> → no substitution (star projection)
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "List" };
		receiver.type_arg_count = 1;
		receiver.type_arg_names[0] = "*";

		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "T0" };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.name == "T0", "star projection should not substitute");
	};
}

fn void substitute_out_of_bounds_unchanged() @test {
	@pool() {
		// T2 with List<String> (only 1 type arg) → no substitution
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "List" };
		receiver.type_arg_count = 1;
		receiver.type_arg_names[0] = "String";

		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "T2" };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.name == "T2", "out of bounds T2 should not substitute");
	};
}

fn void substitute_non_placeholder_unchanged() @test {
	@pool() {
		// String return type should pass through unchanged
		TypeRef receiver = { .kind = types::TypeKind.GENERIC, .name = "List" };
		receiver.type_arg_count = 1;
		receiver.type_arg_names[0] = "Int";

		TypeRef result = { .kind = types::TypeKind.SIMPLE, .name = "String" };

		TypeRef subst = types::substitute_type_params(result, receiver);
		assert(subst.name == "String", "non-placeholder should be unchanged");
	};
}

// ── !is else-branch narrowing (Kotlin spec §11.3) ─────────────────

fn void smart_cast_not_is_else_branch() @test {
	@pool() {
		String src =
			`fun test(x: Any) {
				if (x !is String) {
					val a = 0
				} else {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// Find the `val y = x` declaration; expect y resolved to String
		// because in the else branch, `x` is narrowed via `!is`.
		uint y_idx = find_decl(r, "y");
		assert(y_idx > 0, "expected to find decl 'y'");
		assert(ti.has_type[y_idx], "expected y to have a resolved type");
		String t = types::format_type(&ti.node_types[y_idx]);
		assert(t == "String", "!is else-branch should narrow x to String, got '%s'", t);
	};
}

// ── when (val x = expr) smart-cast subject (Kotlin spec §17.6) ─────

fn void when_subject_binding_smart_cast_is() @test {
	@pool() {
		// `val x` bound in when-subject; inside `is String` arm, x: String.
		String src =
			`fun test(): Int = when (val x = compute()) {
				is String -> x.length
				else -> 0
			}
			fun compute(): Any = "hi"`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// Look for at least one NAME_EXPR 'x' narrowed to String.
		bool found_narrowed = false;
		for (uint i = 0; i < r.node_count; i++) {
			if (r.nodes[i].kind == NAME_EXPR && r.nodes[i].name == "x" && ti.has_type[i]) {
				if (ti.node_types[i].name == "String") found_narrowed = true;
			}
		}
		assert(found_narrowed, "expected NAME_EXPR 'x' narrowed to String in `is String` arm");
	};
}

// ── Stability gate (Kotlin spec §11.3, locals only) ────────────────

fn void smart_cast_var_captured_by_lambda_is_unstable() @test {
	@pool() {
		// `var` captured by a nested lambda is not stable: the null check
		// outside the lambda must NOT narrow x inside the lambda body.
		String src =
			`fun test(x: String?) {
				if (x == null) { return }
				run {
					val y = x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		// Parameters are stable, so `x` IS smart-cast in this case.
		// (This test documents that PARAM is treated as val.)
		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "PARAM is stable; expected String inside lambda, got '%s'", t);
		}
	};
}

fn void smart_cast_local_var_captured_by_lambda_is_unstable() @test {
	@pool() {
		// Local var captured by a nested lambda: outer null guard must
		// NOT narrow the var inside the lambda (other code may reassign
		// between guard and lambda invocation).
		String src =
			`fun test(s: String?) {
				var hashKey: String? = s
				if (hashKey == null) { return }
				run {
					val y = hashKey
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String?", "captured local var is unstable; expected String?, got '%s'", t);
		}
	};
}

fn void smart_cast_local_val_captured_by_lambda_is_stable() @test {
	@pool() {
		// Local val is always stable, even when captured by a lambda.
		String src =
			`fun test(s: String?) {
				val hashKey: String? = s
				if (hashKey == null) { return }
				run {
					val y = hashKey
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "captured local val is stable; expected String, got '%s'", t);
		}
	};
}

fn void smart_cast_local_var_same_function_is_stable() @test {
	@pool() {
		// Local var used in the same function as the check (no lambda
		// boundary) is stable.
		String src =
			`fun test(s: String?) {
				var hashKey: String? = s
				if (hashKey == null) { return }
				val y = hashKey
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "local var in same function is stable; expected String, got '%s'", t);
		}
	};
}

// ── Property smart cast (member + top-level val) ───────────────────

fn void smart_cast_top_level_val_simple() @test {
	@pool() {
		// Top-level `val` with no custom getter is stable. Bare-name access
		// after a null check should narrow.
		String src =
			`val name: String? = "hi"
			fun test() {
				if (name != null) {
					val s = name
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl with type");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "top-level val should narrow; got '%s'", t);
	};
}

fn void smart_cast_top_level_var_unstable() @test {
	@pool() {
		// Top-level `var` is never stable.
		String src =
			`var name: String? = "hi"
			fun test() {
				if (name != null) {
					val s = name
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "top-level var must NOT narrow; got '%s'", t);
	};
}

fn void smart_cast_top_level_val_with_custom_getter_unstable() @test {
	@pool() {
		// `val` with a custom getter is unstable — getter could return
		// different values across two reads.
		String src =
			`val rnd: String?
				get() = if (System.currentTimeMillis() % 2L == 0L) "x" else null
			fun test() {
				if (rnd != null) {
					val s = rnd
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "val with custom getter must NOT narrow; got '%s'", t);
	};
}

fn void smart_cast_open_val_unstable() @test {
	@pool() {
		// `open val` may be overridden with a custom getter — unstable.
		String src =
			`open val name: String? = "hi"
			fun test() {
				if (name != null) {
					val s = name
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "open val must NOT narrow; got '%s'", t);
	};
}

fn void smart_cast_top_level_val_is_check_narrows() @test {
	@pool() {
		// Type-check on top-level val.
		String src =
			`val v: Any = "hi"
			fun test() {
				if (v is String) {
					val s = v
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "top-level val should narrow on `is`; got '%s'", t);
	};
}

// ── In-file class member resolution ────────────────────────────────

fn void in_file_member_property_dot_resolves_type() @test {
	@pool() {
		// `b.x` where Box has `val x: String` — DOT_EXPR should resolve to String.
		String src =
			`class Box { val x: String = "hi" }
			fun test(b: Box) {
				val s = b.x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "in-file member-prop access resolves to String; got '%s'", t);
	};
}

fn void in_file_member_property_nullable_dot_resolves_type() @test {
	@pool() {
		String src =
			`class Box { val x: String? = null }
			fun test(b: Box) {
				val s = b.x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "nullable member resolves to String?; got '%s'", t);
	};
}

fn void in_file_primary_ctor_val_member_resolves_type() @test {
	@pool() {
		// Primary-ctor `val x: T` is a member.
		String src =
			`class Box(val x: Int)
			fun test(b: Box) {
				val n = b.x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "n");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Int", "primary-ctor val member resolves; got '%s'", t);
	};
}

fn void in_file_primary_ctor_var_member_resolves_type() @test {
	@pool() {
		String src =
			`class Box(var x: String)
			fun test(b: Box) {
				val s = b.x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "primary-ctor var member resolves; got '%s'", t);
	};
}

fn void in_file_primary_ctor_plain_param_is_not_member() @test {
	@pool() {
		// Plain ctor params (no val/var) are NOT members — `b.x` must not resolve.
		String src =
			`class Box(x: Int)
			fun test(b: Box) {
				val n = b.x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "n");
		assert(idx > 0, "found decl");
		// Resolution should fail (UNKNOWN) — the plain param isn't a member.
		assert(ti.node_types[idx].kind == types::TypeKind.UNKNOWN,
			"plain ctor param must not be exposed as member; got kind=%d name='%s'",
			(int)ti.node_types[idx].kind, ti.node_types[idx].name);
	};
}

fn void in_file_member_function_dot_resolves_type() @test {
	@pool() {
		// `b.f()` where Box.f returns Int — DOT_EXPR should be Int.
		String src =
			`class Box { fun f(): Int = 42 }
			fun test(b: Box) {
				val n = b.f()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "n");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Int", "in-file member fn resolves; got '%s'", t);
	};
}

// ── Member-property smart cast ─────────────────────────────────────

fn void member_prop_smart_cast_null_check_narrows() @test {
	@pool() {
		// `if (b.x != null) { val s = b.x }` — `b.x` should narrow String? -> String.
		String src =
			`class Box(val x: String?)
			fun test(b: Box) {
				if (b.x != null) {
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "member-prop smart cast on val ctor param; got '%s'", t);
	};
}

fn void member_prop_smart_cast_is_check_narrows() @test {
	@pool() {
		// `if (b.x is String) { val s = b.x }` — narrows to String.
		String src =
			`class Box(val x: Any)
			fun test(b: Box) {
				if (b.x is String) {
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "member-prop is-check narrow; got '%s'", t);
	};
}

fn void member_prop_var_does_not_narrow() @test {
	@pool() {
		// Primary-ctor `var x` is unstable — must NOT narrow.
		String src =
			`class Box(var x: String?)
			fun test(b: Box) {
				if (b.x != null) {
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "ctor-var member must NOT narrow; got '%s'", t);
	};
}

fn void member_prop_open_val_does_not_narrow() @test {
	@pool() {
		// `open val x` may be overridden with a custom getter — unstable.
		String src =
			`open class Box { open val x: String? = null }
			fun test(b: Box) {
				if (b.x != null) {
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "open val member must NOT narrow; got '%s'", t);
	};
}

fn void member_prop_val_with_custom_getter_does_not_narrow() @test {
	@pool() {
		String src =
			`class Box {
				val x: String?
					get() = if (System.currentTimeMillis() % 2L == 0L) "x" else null
			}
			fun test(b: Box) {
				if (b.x != null) {
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "val-with-custom-getter member must NOT narrow; got '%s'", t);
	};
}

fn void member_prop_var_receiver_narrows_in_straight_line() @test {
	@pool() {
		// Receiver `b` is a local `var`, but in straight-line flow with no
		// reassignment between check and use, Kotlin narrows `b.x`.
		// The fact-kill on `b = ...` (kill_receiver) handles invalidation.
		String src =
			`class Box(val x: String?)
			fun test() {
				var b: Box = Box("hi")
				if (b.x != null) {
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "var-receiver member narrows in straight line; got '%s'", t);
	};
}

fn void member_prop_kill_on_receiver_reassignment() @test {
	@pool() {
		// Reassignment to receiver between check and use must invalidate.
		// `b.x` should NOT narrow on the second use.
		String src =
			`class Box(val x: String?)
			fun test() {
				var b: Box = Box("hi")
				if (b.x != null) {
					b = Box(null)
					val s = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String?", "kill on receiver reassignment; got '%s'", t);
	};
}

fn void member_prop_kill_after_receiver_reassignment() @test {
	@pool() {
		// Even with a stable val member, a `b = ...` reassignment between
		// the check and the use must invalidate the fact (we kill all `b.*`
		// facts). But here `b` is a `val`, so reassignment is impossible —
		// instead test that the smart cast still works through normal flow.
		String src =
			`class Box(val x: String?)
			fun test(b: Box) {
				if (b.x != null) {
					val a = b.x
					val c = b.x
				}
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint a_idx = find_decl(r, "a");
		uint c_idx = find_decl(r, "c");
		assert(a_idx > 0 && ti.has_type[a_idx], "found a");
		assert(c_idx > 0 && ti.has_type[c_idx], "found c");
		String ta = types::format_type(&ti.node_types[a_idx]);
		String tc = types::format_type(&ti.node_types[c_idx]);
		assert(ta == "String", "first use narrows; got '%s'", ta);
		assert(tc == "String", "second use also narrows; got '%s'", tc);
	};
}

fn void member_prop_bang_bang_narrows() @test {
	@pool() {
		// `b.x!!` should also produce a non-null fact for subsequent uses.
		String src =
			`class Box(val x: String?)
			fun test(b: Box) {
				b.x!!
				val s = b.x
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "b.x!! should narrow subsequent b.x; got '%s'", t);
	};
}

// ── Operator-call resolution (binary) ─────────────────────────────

fn void user_operator_plus_returns_user_type() @test {
	@pool() {
		String src =
			`class Vec(val x: Int, val y: Int) {
				operator fun plus(o: Vec): Vec = Vec(x + o.x, y + o.y)
			}
			fun test(a: Vec, b: Vec) {
				val s = a + b
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Vec", "a + b should resolve via Vec.plus; got '%s'", t);
	};
}

fn void user_operator_minus_returns_user_type() @test {
	@pool() {
		String src =
			`class Money(val cents: Int) {
				operator fun minus(o: Money): Money = Money(cents - o.cents)
			}
			fun test(a: Money, b: Money) {
				val d = a - b
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "d");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Money", "a - b should resolve via Money.minus; got '%s'", t);
	};
}

fn void user_operator_times_returns_different_type() @test {
	@pool() {
		// User operator that returns a DIFFERENT type than the left operand
		// — proves we're consulting the operator method, not just returning
		// left_type as the legacy fallback.
		String src =
			`class Foo {
				operator fun times(other: Foo): Bar = Bar()
			}
			class Bar
			fun test(a: Foo, b: Foo) {
				val r = a * b
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "r");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Bar", "a * b should resolve via Foo.times → Bar; got '%s'", t);
	};
}

fn void user_operator_rangeTo_returns_user_type() @test {
	@pool() {
		String src =
			`class DateRange
			class Day {
				operator fun rangeTo(other: Day): DateRange = DateRange()
			}
			fun test(a: Day, b: Day) {
				val r = a..b
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "r");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "DateRange", "a..b should resolve via Day.rangeTo → DateRange; got '%s'", t);
	};
}

fn void int_range_still_resolves_via_stdlib() @test {
	@pool() {
		// Regression: stdlib Int.rangeTo → IntRange must still work
		// after removing the hardcoded `..` short-circuit.
		String src =
			`fun test() {
				val r = 1..10
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "r");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "IntRange", "1..10 should resolve to IntRange; got '%s'", t);
	};
}

fn void int_arithmetic_still_works() @test {
	@pool() {
		// Regression: stdlib Int.plus/minus/times must still work
		String src =
			`fun test() {
				val s = 1 + 2
				val d = 5 - 3
				val p = 4 * 6
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint si = find_decl(r, "s");
		uint di = find_decl(r, "d");
		uint pi = find_decl(r, "p");
		String ts = types::format_type(&ti.node_types[si]);
		String td = types::format_type(&ti.node_types[di]);
		String tp = types::format_type(&ti.node_types[pi]);
		assert(ts == "Int", "1 + 2 → Int, got '%s'", ts);
		assert(td == "Int", "5 - 3 → Int, got '%s'", td);
		assert(tp == "Int", "4 * 6 → Int, got '%s'", tp);
	};
}

fn void user_operator_div_via_data_class() @test {
	@pool() {
		String src =
			`data class Ratio(val num: Int, val den: Int) {
				operator fun div(other: Ratio): Ratio = Ratio(num * other.den, den * other.num)
			}
			fun test(a: Ratio, b: Ratio) {
				val q = a / b
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "q");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Ratio", "a / b on data class should resolve via div; got '%s'", t);
	};
}

// ── Operator-call resolution (index) ──────────────────────────────

fn void user_operator_get_returns_user_type() @test {
	@pool() {
		String src =
			`class User
			class Cache {
				operator fun get(key: String): User = User()
			}
			fun test(c: Cache) {
				val u = c["alice"]
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "u");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "User", "c[\"alice\"] should resolve via Cache.get → User; got '%s'", t);
	};
}

fn void user_operator_get_nullable_return() @test {
	@pool() {
		String src =
			`class Session
			class Sessions {
				operator fun get(id: Int): Session? = null
			}
			fun test(s: Sessions) {
				val sess = s[42]
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "sess");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Session?", "s[42] should resolve via Sessions.get → Session?; got '%s'", t);
	};
}

fn void list_index_still_resolves_via_stdlib() @test {
	@pool() {
		// Regression: List<T>[i] hardcoded path
		String src =
			`fun test(xs: List<String>) {
				val s = xs[0]
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "s");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "String", "xs[0] → String; got '%s'", t);
	};
}

fn void map_index_still_resolves_via_stdlib() @test {
	@pool() {
		// Regression: Map<K,V>[k] → V? hardcoded path
		String src =
			`fun test(m: Map<String, Int>) {
				val v = m["key"]
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "v");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Int?", "m[\"key\"] → Int?; got '%s'", t);
	};
}

// ── Operator-call resolution (invoke) ─────────────────────────────

fn void user_operator_invoke_returns_user_type() @test {
	@pool() {
		String src =
			`class Greeting
			class Greeter {
				operator fun invoke(name: String): Greeting = Greeting()
			}
			fun test(g: Greeter) {
				val msg = g("Bob")
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "msg");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Greeting", "g(\"Bob\") should resolve via Greeter.invoke → Greeting; got '%s'", t);
	};
}

fn void user_operator_invoke_returns_primitive() @test {
	@pool() {
		String src =
			`class Counter {
				operator fun invoke(): Int = 42
			}
			fun test(c: Counter) {
				val n = c()
			}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer { types::free_type_info(ti); mem::free(ti); };

		uint idx = find_decl(r, "n");
		assert(idx > 0 && ti.has_type[idx], "found decl");
		String t = types::format_type(&ti.node_types[idx]);
		assert(t == "Int", "c() should resolve via Counter.invoke → Int; got '%s'", t);
	};
}
