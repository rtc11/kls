module kls::test::call_hierarchy_test;

import std::collections::object;
import kls::document;
import kls::lsp::call_hierarchy;
import kls::workspace;

// ── Helper: build textDocument/position params ─────────────────────

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

// ── Helper: build callHierarchy item params ────────────────────────

fn Object* make_item_params(String name, String uri, int line, int col) {
	Object* sel_start = object::new_obj(tmem);
	sel_start.set("line", line);
	sel_start.set("character", col);

	Object* sel_end = object::new_obj(tmem);
	sel_end.set("line", line);
	sel_end.set("character", col + (int)name.len);

	Object* sel_range = object::new_obj(tmem);
	sel_range.set("start", sel_start);
	sel_range.set("end", sel_end);

	Object* range = object::new_obj(tmem);
	range.set("start", sel_start);
	range.set("end", sel_end);

	Object* item = object::new_obj(tmem);
	item.set("name", name);
	item.set("kind", 12);
	item.set("uri", uri);
	item.set("range", range);
	item.set("selectionRange", sel_range);

	Object* params = object::new_obj(tmem);
	params.set("item", item);
	return params;
}

// ── prepareCallHierarchy: cursor on function declaration ───────────

fn void prepare_on_function_declaration() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun greet() {}
fun main() { greet() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" declaration at line 0, col 4
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = call_hierarchy::handle_prepare(&store, null, params);

		assert(result != null, "expected CallHierarchyItem array");
		assert(result.get_len() == 1, "expected 1 item, got %d", (int)result.get_len());

		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "greet", "expected 'greet', got '%s'", name);

		int kind = item.get_int("kind")!!;
		assert(kind == 12, "expected kind 12 (Function), got %d", kind);
	};
}

// ── prepareCallHierarchy: cursor on function call ──────────────────

fn void prepare_on_function_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun greet() {}
fun main() { greet() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" call at line 1, col 14
		Object* params = make_params("file:///test.kt", 1, 14);
		Object* result = call_hierarchy::handle_prepare(&store, null, params);

		assert(result != null, "expected CallHierarchyItem array");
		assert(result.get_len() == 1, "expected 1 item");

		Object* item = result.get_at(0);
		String name = item.get_string("name")!!;
		assert(name == "greet", "expected 'greet', got '%s'", name);
	};
}

// ── prepareCallHierarchy: cursor on non-function returns null ──────

fn void prepare_on_variable_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `val x = 42`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" — a property, not a function
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = call_hierarchy::handle_prepare(&store, null, params);

		// Should be null — x is a property, not a function
		assert(result == null, "expected null for non-function");
	};
}

// ── incomingCalls: simple case ─────────────────────────────────────

fn void incoming_calls_simple() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun greet() {}
fun main() { greet() }
fun test() { greet() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Build incoming call params for greet at line 0, col 4
		Object* params = make_item_params("greet", "file:///test.kt", 0, 4);
		Object* result = call_hierarchy::handle_incoming_calls(&store, null, params);

		assert(result != null, "expected incoming calls");
		// main and test both call greet
		assert(result.get_len() == 2, "expected 2 callers, got %d", (int)result.get_len());

		// Each entry should have "from" with a name and "fromRanges"
		Object* call0 = result.get_at(0);
		Object* from0 = call0.get("from")!!;
		String from_name0 = from0.get_string("name")!!;
		assert(from_name0 == "main" || from_name0 == "test",
			"expected 'main' or 'test', got '%s'", from_name0);
	};
}

// ── outgoingCalls: simple case ─────────────────────────────────────

fn void outgoing_calls_simple() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun foo() {}
fun bar() {}
fun main() { foo(); bar() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Outgoing calls from main at line 2, col 4
		Object* params = make_item_params("main", "file:///test.kt", 2, 4);
		Object* result = call_hierarchy::handle_outgoing_calls(&store, null, params);

		assert(result != null, "expected outgoing calls");
		assert(result.get_len() == 2, "expected 2 outgoing calls, got %d", (int)result.get_len());

		// Each entry should have "to" with a name
		Object* call0 = result.get_at(0);
		Object* to0 = call0.get("to")!!;
		String to_name0 = to0.get_string("name")!!;
		assert(to_name0 == "foo" || to_name0 == "bar",
			"expected 'foo' or 'bar', got '%s'", to_name0);
	};
}

// ── outgoingCalls: no calls returns null ────────────────────────────

fn void outgoing_calls_empty() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() { val x = 42 }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_item_params("main", "file:///test.kt", 0, 4);
		Object* result = call_hierarchy::handle_outgoing_calls(&store, null, params);

		assert(result == null, "expected null when no outgoing calls");
	};
}

// ── incomingCalls: multiple calls from same function ───────────────

fn void incoming_calls_multiple_from_same() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun greet() {}
fun main() { greet(); greet() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_item_params("greet", "file:///test.kt", 0, 4);
		Object* result = call_hierarchy::handle_incoming_calls(&store, null, params);

		assert(result != null, "expected incoming calls");
		// Should be 1 caller (main) with 2 fromRanges
		assert(result.get_len() == 1, "expected 1 caller, got %d", (int)result.get_len());

		Object* call0 = result.get_at(0);
		Object* ranges = call0.get("fromRanges")!!;
		assert(ranges.get_len() == 2, "expected 2 fromRanges, got %d", (int)ranges.get_len());
	};
}
