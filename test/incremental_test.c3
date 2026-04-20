module kls::test::incremental_test;

import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::incremental;
import kls::document;

// ── Helpers ─────────────────────────────────────────────────────────

fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	r.free_errors();
	mem::free(r);
}

fn ChunkMap* do_build_chunks(ParseResult* r, String src) {
	ChunkMap* map = mem::new(ChunkMap);
	incremental::build_chunk_map(r, map, src);
	return map;
}

// ── Chunk map building ──────────────────────────────────────────────

fn void chunk_map_empty_file() @test {
	@pool() {
		String src = "";
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);
		assert(map.chunk_count == 0, "expected 0 chunks, got %d", (int)map.chunk_count);
	};
}

fn void chunk_map_package_only() @test {
	@pool() {
		String src = "package com.example";
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);
		assert(map.chunk_count == 0, "expected 0 declaration chunks");
		assert(map.preamble_end_byte > 0, "expected preamble to have content");
	};
}

fn void chunk_map_single_function() @test {
	@pool() {
		String src = `fun main() { println("hello") }`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);
		assert(map.chunk_count == 1, "expected 1 chunk, got %d", (int)map.chunk_count);
		assert(map.chunks[0].byte_start == 0);
		assert(map.chunks[0].node_start > 0, "node_start should be > 0 (FILE is 0)");
	};
}

fn void chunk_map_multiple_declarations() @test {
	@pool() {
		String src =
`package com.example

import kotlin.io.println

fun foo() {}

fun bar() {}

class Baz {}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);
		assert(map.chunk_count == 3, "expected 3 chunks (foo, bar, Baz), got %d", (int)map.chunk_count);
		assert(map.preamble_end_byte > 0, "expected preamble region");
	};
}

fn void chunk_map_class_with_members() @test {
	@pool() {
		String src =
`class MyClass {
    fun method1() {}
    fun method2() {}
    val prop: Int = 0
}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);
		assert(map.chunk_count == 1, "expected 1 top-level chunk");
		assert(map.chunks[0].member_count >= 3, "expected at least 3 members, got %d",
			(int)map.chunks[0].member_count);
	};
}

// ── Edit analysis ───────────────────────────────────────────────────

fn void edit_in_preamble_forces_full_reparse() @test {
	@pool() {
		String src =
`package com.example

fun foo() {}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);

		// Edit in the package declaration
		EditAnalysis analysis = incremental::analyze_edit(map, 8, 15);
		assert(analysis.needs_full_reparse, "expected full reparse for preamble edit");
	};
}

fn void edit_in_single_function() @test {
	@pool() {
		String src =
`package com.example

fun foo() { val x = 1 }

fun bar() { val y = 2 }`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);

		// Edit inside foo's body (should be within chunk 0)
		Chunk* foo_chunk = &map.chunks[0];
		uint edit_pos = foo_chunk.byte_start + 12; // somewhere inside the function
		EditAnalysis analysis = incremental::analyze_edit(map, edit_pos, edit_pos + 1);
		assert(!analysis.needs_full_reparse, "should not need full reparse");
		assert(analysis.found_chunk, "should find containing chunk");
		assert(analysis.chunk_idx == 0, "should be chunk 0 (foo)");
	};
}

fn void edit_in_class_member() @test {
	@pool() {
		String src =
`class MyClass {
    fun method1() { val x = 1 }
    fun method2() { val y = 2 }
}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);

		assert(map.chunk_count >= 1, "expected at least 1 chunk");
		Chunk* class_chunk = &map.chunks[0];
		assert(class_chunk.member_count >= 2, "expected at least 2 members, got %d",
			(int)class_chunk.member_count);

		// Edit inside method1 (first member)
		MemberChunk* m1 = &class_chunk.members[0];
		uint edit_pos = m1.byte_start + 10;
		EditAnalysis analysis = incremental::analyze_edit(map, edit_pos, edit_pos + 1);
		assert(!analysis.needs_full_reparse, "should not need full reparse");
		assert(analysis.found_chunk, "should find containing chunk");
		assert(analysis.found_member, "should find containing member");
		assert(analysis.member_idx == 0, "should be member 0");
	};
}

// ── Incremental re-parse ────────────────────────────────────────────

fn void incremental_reparse_function_body() @test {
	@pool() {
		String old_src =
`package com.example

fun foo() { val x = 1 }

fun bar() { val y = 2 }`;

		String new_src =
`package com.example

fun foo() { val x = 42 }

fun bar() { val y = 2 }`;

		ParseResult* r = do_parse(old_src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, old_src); defer mem::free(map);

		uint old_bar_start = map.chunks[1].byte_start;

		// The edit changes "1" to "42" — one byte longer
		// Find the position of "1" in foo's body
		Chunk* foo_chunk = &map.chunks[0];
		// "val x = 1" — the "1" is at some offset within foo
		// In old_src: "fun foo() { val x = 1 }" starts at chunk byte_start
		// We'll find "= 1 " and replace "1" with "42"
		uint edit_start = foo_chunk.byte_start + 20; // approximate position of "1"
		// Find exact position
		for (uint i = foo_chunk.byte_start; i < foo_chunk.byte_end; i++) {
			if (old_src[i] == '1' && i > foo_chunk.byte_start + 15) {
				edit_start = i;
				break;
			}
		}

		bool ok = incremental::try_incremental_reparse(
			r, map, old_src, new_src,
			edit_start, edit_start + 1, 2);  // "1" -> "42"

		assert(ok, "incremental reparse should succeed");

		// Verify bar's chunk was shifted by 1 byte
		assert(map.chunks[1].byte_start == old_bar_start + 1,
			"bar should shift by 1 byte, old=%d new=%d",
			(int)old_bar_start, (int)map.chunks[1].byte_start);

		// Verify node count is reasonable
		assert(r.node_count > 0, "should have nodes");
	};
}

fn void incremental_reparse_fallback_for_multispan() @test {
	@pool() {
		String old_src =
`fun foo() {}

fun bar() {}`;

		ParseResult* r = do_parse(old_src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, old_src); defer mem::free(map);

		// Edit that spans both functions (delete everything between them)
		bool ok = incremental::try_incremental_reparse(
			r, map, old_src, old_src, 5, (uint)old_src.len - 5, 0);

		assert(!ok, "should fall back to full reparse for spanning edit");
	};
}

// ── Document store integration ──────────────────────────────────────

fn void document_store_incremental_change() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String src =
`fun foo() { val x = 1 }

fun bar() { val y = 2 }`;

		store.open("test://file.kt", "kotlin", 1, src);

		// Force AST + chunk map to be built
		ParseResult* ast1 = store.get_ast("test://file.kt")!!;
		uint original_node_count = ast1.node_count;

		// Apply a change: replace "1" with "42" in foo
		// Find the byte offset of "1" in "val x = 1"
		Document* doc = store.get("test://file.kt")!!;
		uint edit_pos = 0;
		for (uint i = 0; i < (uint)doc.content.len; i++) {
			if (doc.content[i] == '1' && i > 10) {
				edit_pos = i;
				break;
			}
		}

		store.apply_change("test://file.kt", 2, edit_pos, edit_pos + 1, "42");

		// The AST should still be valid (incremental update)
		doc = store.get("test://file.kt")!!;
		if (doc.cached_ast != null) {
			// Incremental succeeded -- AST was preserved
			assert(doc.cached_ast.node_count > 0, "AST should have nodes after incremental update");
		}
		// Either way, get_ast should work
		ParseResult* ast2 = store.get_ast("test://file.kt")!!;
		assert(ast2.node_count > 0, "should have nodes");
	};
}

// ── parse_chunk entry point ─────────────────────────────────────────

fn void parse_chunk_single_function() @test {
	@pool() {
		String src = `fun hello() { val x = 1 }`;
		ParseResult* r = mem::new(ParseResult); defer { r.free_errors(); mem::free(r); };
		parser::parse_chunk(src, r, 0, (uint)src.len, 0);

		assert(r.node_count > 0, "parse_chunk should produce nodes");
		// First node should be a FUN_DECL
		assert(r.nodes[0].kind == FUN_DECL, "expected FUN_DECL, got %d", (int)r.nodes[0].kind);
		assert(r.nodes[0].name == "hello", "expected name 'hello', got '%s'", r.nodes[0].name);
	};
}

fn void parse_chunk_with_offset() @test {
	@pool() {
		String src =
`package test

fun foo() {}`;
		// Parse only the function part (skip package)
		// Find where "fun" starts
		uint fun_start = 0;
		for (uint i = 0; i < (uint)src.len - 2; i++) {
			if (src[i] == 'f' && src[i+1] == 'u' && src[i+2] == 'n') {
				fun_start = i;
				break;
			}
		}

		ParseResult* r = mem::new(ParseResult); defer { r.free_errors(); mem::free(r); };
		parser::parse_chunk(src, r, fun_start, (uint)src.len, 2); // line 2

		assert(r.node_count > 0, "parse_chunk should produce nodes");
		assert(r.nodes[0].kind == FUN_DECL, "expected FUN_DECL");
		assert(r.nodes[0].start_line == 2, "expected start_line=2, got %d", (int)r.nodes[0].start_line);
	};
}

// ── Chunk map: subtree end detection ────────────────────────────────

fn void subtree_end_simple() @test {
	@pool() {
		String src = `fun foo() { val x = 1 }`;
		ParseResult* r = do_parse(src); defer free_result(r);

		// FILE node is 0, FUN_DECL is 1
		uint end = incremental::find_subtree_end(r, 1);
		assert(end == r.node_count, "subtree of only decl should span to end");
	};
}

fn void subtree_end_with_siblings() @test {
	@pool() {
		String src =
`fun foo() {}

fun bar() {}`;
		ParseResult* r = do_parse(src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, src); defer mem::free(map);

		assert(map.chunk_count == 2, "expected 2 chunks");

		// First chunk should not extend into second
		Chunk* c0 = &map.chunks[0];
		Chunk* c1 = &map.chunks[1];
		assert(c0.node_end <= c1.node_start,
			"first chunk end (%d) should be <= second chunk start (%d)",
			(int)c0.node_end, (int)c1.node_start);
	};
}

// ── Error preservation across incremental reparse ──────────────────

fn void incremental_preserves_errors_from_unchanged_regions() @test {
	@pool() {
		// Source with syntax error in first function and valid second function
		String old_src =
`fun foo( { val x = 1 }

fun bar() { val y = 2 }`;
		ParseResult* r = do_parse(old_src); defer free_result(r);
		ChunkMap* map = do_build_chunks(r, old_src); defer mem::free(map);

		// Should have parse error from foo() (missing closing paren)
		usz errors_before = r.error_count;
		assert(errors_before > 0, "expected parse errors from foo(), got 0");

		// Edit bar(): change "2" to "3" — doesn't touch foo()
		String new_src =
`fun foo( { val x = 1 }

fun bar() { val y = 3 }`;
		uint edit_start = 39; // position of '2'
		uint edit_end = 40;   // end of '2'
		usz new_text_len = 1; // '3'

		bool ok = incremental::try_incremental_reparse(
			r, map, old_src, new_src, edit_start, edit_end, new_text_len);

		// Whether incremental succeeded or not, if it did, errors from foo() should survive
		if (ok) {
			assert(r.error_count >= errors_before,
				"errors from unchanged foo() should be preserved: had %d, now %d",
				(int)errors_before, (int)r.error_count);
		}
	};
}
