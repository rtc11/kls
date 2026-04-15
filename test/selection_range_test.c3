module kls::test::selection_range_test;

import std::collections::object;
import kls::document;
import kls::lsp::selection_range;

// ── Helper: build params with multiple positions ───────────────────

fn Object* make_params(String uri, int[2][] positions) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos_arr = object::new_obj(tmem); // JSON array
	foreach (p : positions) {
		Object* pos = object::new_obj(tmem);
		pos.set("line", p[0]);
		pos.set("character", p[1]);
		pos_arr.push(pos);
	}

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("positions", pos_arr);
	return params;
}

// ── Helper: count depth of a SelectionRange chain ──────────────────

fn int chain_depth(Object* sel) {
	int depth = 0;
	Object* current = sel;
	while (current != null) {
		depth++;
		current = current.get("parent") ?? null;
	}
	return depth;
}

// ── Helper: get the outermost range in a chain ─────────────────────

fn Object* outermost(Object* sel) {
	Object* current = sel;
	while (true) {
		Object* p = current.get("parent") ?? null;
		if (p == null) return current;
		current = p;
	}
}

// ── Cursor inside function inside class ────────────────────────────

fn void selection_range_nested_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Line 0: class Foo {
		// Line 1:     fun bar() {
		// Line 2:         val x = 42
		// Line 3:     }
		// Line 4: }
		String content = "class Foo {\n    fun bar() {\n        val x = 42\n    }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 2, col 12
		int[2][] positions = { { 2, 12 } };
		Object* params = make_params("file:///test.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result != null, "expected result array");

		// Should have one entry for our one position
		assert(result.get_len() == 1, "expected 1 selection range, got %d", (int)result.get_len());

		Object* sel = result.get_at(0);
		assert(sel != null, "expected selection range at index 0");

		// The innermost range should contain the cursor
		Object* range = sel.get("range")!!;
		Object* start = range.get("start")!!;
		int sl = start.get_int("line")!!;
		int sc = start.get_int("character")!!;
		assert(sl <= 2, "inner start line should be <= 2, got %d", sl);

		// Chain must have depth >= 3 (at least: inner node, fun, class/file)
		int depth = chain_depth(sel);
		assert(depth >= 3, "expected depth >= 3, got %d", depth);

		// Outermost range should start at 0,0 (FILE node)
		Object* outer = outermost(sel);
		Object* outer_range = outer.get("range")!!;
		Object* outer_start = outer_range.get("start")!!;
		assert(outer_start.get_int("line")!! == 0, "outermost should start at line 0");
		assert(outer_start.get_int("character")!! == 0, "outermost should start at col 0");
	};
}

// ── Cursor at top-level package declaration ────────────────────────

fn void selection_range_package_decl() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "package com.example\n\nfun main() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "package" at line 0, col 2
		int[2][] positions = { { 0, 2 } };
		Object* params = make_params("file:///test.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result != null);
		Object* sel = result.get_at(0);

		// Should have at least 2 levels (package_decl + file)
		int depth = chain_depth(sel);
		assert(depth >= 2, "expected depth >= 2 for package decl, got %d", depth);

		// Outermost should be FILE
		Object* outer = outermost(sel);
		Object* outer_range = outer.get("range")!!;
		Object* outer_start = outer_range.get("start")!!;
		assert(outer_start.get_int("line")!! == 0);
		assert(outer_start.get_int("character")!! == 0);
	};
}

// ── Multiple positions in one request ──────────────────────────────

fn void selection_range_multiple_positions() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val a = 1\nval b = 2\nval c = 3";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Three positions: one per line
		int[2][] positions = { { 0, 4 }, { 1, 4 }, { 2, 4 } };
		Object* params = make_params("file:///test.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result != null);
		assert(result.get_len() == 3, "expected 3 results, got %d", (int)result.get_len());

		// Each should be non-null and have at least 2 levels (property + file)
		for (sz i = 0; i < 3; i++) {
			Object* sel = result.get_at(i);
			assert(sel != null, "expected non-null selection at index %d", (int)i);
			int depth = chain_depth(sel);
			assert(depth >= 2, "pos %d: expected depth >= 2, got %d", (int)i, depth);
		}
	};
}

// ── Cursor inside nested if block ──────────────────────────────────

fn void selection_range_nested_if() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Line 0: fun main() {
		// Line 1:     if (true) {
		// Line 2:         val x = 1
		// Line 3:     }
		// Line 4: }
		String content = "fun main() {\n    if (true) {\n        val x = 1\n    }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 2, col 12
		int[2][] positions = { { 2, 12 } };
		Object* params = make_params("file:///test.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result != null);
		Object* sel = result.get_at(0);

		// Should have depth >= 4 (inner node, if_expr/block, fun, file)
		int depth = chain_depth(sel);
		assert(depth >= 4, "expected depth >= 4 for nested if, got %d", depth);
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void selection_range_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		int[2][] positions = { { 0, 0 } };
		Object* params = make_params("file:///nonexistent.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Each parent range strictly contains child range ────────────────

fn void selection_range_parent_contains_child() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Outer {\n    class Inner {\n        fun doIt() {\n            val x = 1\n        }\n    }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 3, col 16
		int[2][] positions = { { 3, 16 } };
		Object* params = make_params("file:///test.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result != null);
		Object* sel = result.get_at(0);

		// Walk the chain and verify each parent strictly contains its child
		Object* current = sel;
		while (true) {
			Object* parent = current.get("parent") ?? null;
			if (parent == null) break;

			Object* cr = current.get("range")!!;
			Object* pr = parent.get("range")!!;

			int c_sl = cr.get("start")!!.get_int("line")!!;
			int c_sc = cr.get("start")!!.get_int("character")!!;
			int c_el = cr.get("end")!!.get_int("line")!!;
			int c_ec = cr.get("end")!!.get_int("character")!!;

			int p_sl = pr.get("start")!!.get_int("line")!!;
			int p_sc = pr.get("start")!!.get_int("character")!!;
			int p_el = pr.get("end")!!.get_int("line")!!;
			int p_ec = pr.get("end")!!.get_int("character")!!;

			// Parent start must be <= child start
			bool start_ok = (p_sl < c_sl) || (p_sl == c_sl && p_sc <= c_sc);
			assert(start_ok, "parent start (%d,%d) must be <= child start (%d,%d)",
				p_sl, p_sc, c_sl, c_sc);

			// Parent end must be >= child end
			bool end_ok = (p_el > c_el) || (p_el == c_el && p_ec >= c_ec);
			assert(end_ok, "parent end (%d,%d) must be >= child end (%d,%d)",
				p_el, p_ec, c_el, c_ec);

			// Must not be identical (dedup should prevent this)
			bool same = (p_sl == c_sl && p_sc == c_sc && p_el == c_el && p_ec == c_ec);
			assert(!same, "parent and child ranges must not be identical");

			current = parent;
		}
	};
}

// ── Empty file returns single file-level range ─────────────────────

fn void selection_range_empty_file() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "";
		store.open("file:///test.kt", "kotlin", 1, content);

		int[2][] positions = { { 0, 0 } };
		Object* params = make_params("file:///test.kt", positions);
		Object* result = selection_range::handle_selection_range(&store, params);

		assert(result != null);
		Object* sel = result.get_at(0);
		assert(sel != null, "expected a selection range even for empty file");

		// Should have depth 1 (just the file range)
		int depth = chain_depth(sel);
		assert(depth >= 1, "expected at least depth 1 for empty file, got %d", depth);
	};
}
