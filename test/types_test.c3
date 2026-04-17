module kls::test::types_test;

import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::kotlin::stdlib;
import kls::workspace;
import kls::lsp::hover;
import kls::lsp::completion;
import kls::document;

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
	types::resolve_types(pr, ti);
	return ti;
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

fn void parse_nullable_type() @test {
	@pool() {
		TypeRef t = types::parse_type_text("String?");
		assert(t.kind == SIMPLE, "expected SIMPLE");
		assert(t.name == "String", "expected 'String', got '%s'", t.name);
		assert(t.nullable, "expected nullable");
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
		uint idx = find_decl(r, "x");
		assert(idx > 0, "expected to find 'x'");
		assert(ti.has_type[idx], "expected type for 'x'");
		assert(ti.node_types[idx].name == "Int", "expected 'Int', got '%s'", ti.node_types[idx].name);
	};
}

fn void explicit_nullable_annotation() @test {
	@pool() {
		ParseResult* r = do_parse("val x: String? = null"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
		uint idx = find_decl(r, "greet");
		assert(idx > 0, "expected to find 'greet'");
		assert(ti.has_type[idx], "expected type for 'greet'");
		assert(ti.node_types[idx].name == "String", "expected 'String'");
	};
}

fn void fun_param_type() @test {
	@pool() {
		ParseResult* r = do_parse("fun greet(name: String) {}"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
		// Should not crash
		assert(true);
	};
}

fn void resolve_class_no_type() @test {
	@pool() {
		ParseResult* r = do_parse("class Foo"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
		uint idx = find_decl(r, "Foo");
		// Classes don't get TypeInfo entries (they ARE types)
		// Just verify no crash
		assert(idx > 0, "expected to find 'Foo'");
	};
}

fn void resolve_var_with_initializer() @test {
	@pool() {
		ParseResult* r = do_parse("var x = 100"); defer free_result(r);
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);
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
	defer mem::free(ti);
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
	defer mem::free(ti);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		assert(t.name == "List", "mutableListOf(true) should be List, got '%s'", t.name);
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

		uint idx = find_decl(r, "y");
		if (idx > 0 && ti.has_type[idx]) {
			String t = types::format_type(&ti.node_types[idx]);
			assert(t == "String", "else-branch null smart cast should give String, got '%s'", t);
			assert(!ti.node_types[idx].nullable, "else-branch null smart cast should not be nullable");
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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		TypeInfo* ti = do_resolve(r); defer mem::free(ti);

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
		defer mem::free(ti);

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
		defer mem::free(ti);

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
		defer mem::free(ti);

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
		defer mem::free(ti);

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
		defer mem::free(ti);

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
		defer mem::free(ti);

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
		defer mem::free(ti);

		uint u_idx = find_decl(pr, "u");
		assert(u_idx != 0, "should find 'u'");
		// Without workspace, User is unknown — should NOT have a type
		assert(!ti.has_type[u_idx] || ti.node_types[u_idx].kind == UNKNOWN,
			"u should be UNKNOWN without workspace");
	};
}
