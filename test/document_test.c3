module kls::document_test;

import kls::document;
import kls::kotlin::ast;

fn void open_and_get() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun main() {}");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.uri == "file:///test.kt", "unexpected uri: '%s'", doc.uri);
		assert(doc.language_id == "kotlin", "unexpected language_id: '%s'", doc.language_id);
		assert(doc.version == 1, "expected version 1, got %d", doc.version);
		assert(doc.content == "fun main() {}", "unexpected content: '%s'", doc.content);
	} else {
		assert(false, "document not found after open");
	}
}

fn void update_content() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "val x = 1");
	store.update("file:///test.kt", 2, "val x = 2");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.version == 2, "expected version 2, got %d", doc.version);
		assert(doc.content == "val x = 2", "unexpected content: '%s'", doc.content);
	} else {
		assert(false, "document not found after update");
	}
}

fn void close_removes_document() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun main() {}");
	store.close("file:///test.kt");
	if (try doc = store.get("file:///test.kt")) {
		assert(false, "document should not exist after close");
	}
}

fn void multiple_documents() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///a.kt", "kotlin", 1, "val a = 1");
	store.open("file:///b.kt", "kotlin", 1, "val b = 2");

	if (try doc = store.get("file:///a.kt")) {
		assert(doc.content == "val a = 1");
	} else {
		assert(false, "document a.kt not found");
	}

	if (try doc = store.get("file:///b.kt")) {
		assert(doc.content == "val b = 2");
	} else {
		assert(false, "document b.kt not found");
	}
}

fn void close_one_keeps_other() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///a.kt", "kotlin", 1, "val a = 1");
	store.open("file:///b.kt", "kotlin", 1, "val b = 2");
	store.close("file:///a.kt");

	if (try doc = store.get("file:///a.kt")) {
		assert(false, "a.kt should be gone after close");
	}

	if (try doc = store.get("file:///b.kt")) {
		assert(doc.content == "val b = 2");
	} else {
		assert(false, "b.kt should still exist");
	}
}

fn void get_nonexistent_returns_none() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	if (try doc = store.get("file:///nope.kt")) {
		assert(false, "should not find nonexistent document");
	}
	// Good - no document found
}

fn void update_nonexistent_is_safe() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// Should not crash
	store.update("file:///nope.kt", 1, "content");
}

fn void overwrite_on_reopen() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "old content");
	store.open("file:///test.kt", "kotlin", 2, "new content");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "new content", "expected new content after reopen");
		assert(doc.version == 2);
	} else {
		assert(false, "document not found after reopen");
	}
}

// ── AST caching tests ─────────────────────────────────────────────

fn void get_ast_returns_parse_result() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

	if (try pr = store.get_ast("file:///test.kt")) {
		assert(pr.node_count > 0, "expected parsed nodes, got 0");
		// FILE node should be first
		assert(pr.nodes[0].kind == FILE, "expected FILE root node");
	} else {
		assert(false, "get_ast returned fault for open document");
	}
}

fn void get_ast_returns_same_pointer_on_second_call() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "class Foo {}");

	ParseResult* first = store.get_ast("file:///test.kt")!!;
	ParseResult* second = store.get_ast("file:///test.kt")!!;
	assert(first == second, "expected same pointer on cached call");
}

fn void get_ast_invalidated_on_update() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun foo() {}");

	// First AST should have a function named "foo"
	ParseResult* before = store.get_ast("file:///test.kt")!!;
	assert(before.node_count >= 2, "expected at least 2 nodes");
	bool found_foo = false;
	for (uint i = 0; i < before.node_count; i++) {
		if (before.nodes[i].kind == FUN_DECL && before.nodes[i].name == "foo") {
			found_foo = true;
		}
	}
	assert(found_foo, "expected to find function 'foo' before update");

	// Update to different content
	store.update("file:///test.kt", 2, "fun bar() {}");
	ParseResult* after = store.get_ast("file:///test.kt")!!;

	// After update, should find "bar" instead of "foo"
	bool found_bar = false;
	for (uint i = 0; i < after.node_count; i++) {
		if (after.nodes[i].kind == FUN_DECL && after.nodes[i].name == "bar") {
			found_bar = true;
		}
	}
	assert(found_bar, "expected to find function 'bar' after update");
}

fn void get_ast_nonexistent_returns_fault() @test {
	DocumentStore store;
	store.init();
	defer store.free();

	if (try pr = store.get_ast("file:///nope.kt")) {
		assert(false, "should not find AST for nonexistent document");
	}
}

fn void get_ast_after_reopen_is_fresh() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "val x = 1");
	ParseResult* first = store.get_ast("file:///test.kt")!!;
	assert(first.node_count > 0);

	// Reopen with different content
	store.open("file:///test.kt", "kotlin", 2, "class Bar {}");
	ParseResult* second = store.get_ast("file:///test.kt")!!;

	// The new AST should reflect the new content (class Bar, not val x)
	bool found_bar = false;
	for (uint i = 0; i < second.node_count; i++) {
		if (second.nodes[i].kind == CLASS_DECL && second.nodes[i].name == "Bar") {
			found_bar = true;
		}
	}
	assert(found_bar, "expected to find class 'Bar' after reopen");
}

// ── position_to_byte_offset ───────────────────────────────────────

fn void byte_offset_first_char() @test {
	long off = document::position_to_byte_offset("fun main()", 0, 0);
	assert(off == 0, "expected 0, got %d", (int)off);
}

fn void byte_offset_middle_of_line() @test {
	long off = document::position_to_byte_offset("fun main()", 0, 4);
	assert(off == 4, "expected 4, got %d", (int)off);
}

fn void byte_offset_second_line() @test {
	long off = document::position_to_byte_offset("abc\ndef", 1, 0);
	assert(off == 4, "expected 4, got %d", (int)off);
}

fn void byte_offset_second_line_col() @test {
	long off = document::position_to_byte_offset("abc\ndef", 1, 2);
	assert(off == 6, "expected 6, got %d", (int)off);
}

fn void byte_offset_past_end_line() @test {
	long off = document::position_to_byte_offset("abc", 5, 0);
	assert(off == -1, "expected -1 for line past end");
}

fn void byte_offset_past_end_col() @test {
	long off = document::position_to_byte_offset("abc", 0, 100);
	assert(off == -1, "expected -1 for col past end");
}

fn void byte_offset_end_of_content() @test {
	// Offset at the very end (past last char) should be valid (for insertions)
	long off = document::position_to_byte_offset("abc", 0, 3);
	assert(off == 3, "expected 3, got %d", (int)off);
}

fn void byte_offset_empty_string() @test {
	long off = document::position_to_byte_offset("", 0, 0);
	assert(off == 0, "expected 0 for empty string at 0,0, got %d", (int)off);
}

// ── Incremental changes (apply_change) ────────────────────────────

fn void incremental_insert_single_char() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// "val x = 1" -> insert 'y' before 'x' at offset 4
	store.open("file:///test.kt", "kotlin", 1, "val x = 1");
	store.apply_change("file:///test.kt", 2, 4, 4, "y");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "val yx = 1", "expected 'val yx = 1', got '%s'", doc.content);
		assert(doc.version == 2);
	} else {
		assert(false, "document not found after apply_change");
	}
}

fn void incremental_delete_single_char() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// "val x = 1" -> delete 'x' at offset 4..5
	store.open("file:///test.kt", "kotlin", 1, "val x = 1");
	store.apply_change("file:///test.kt", 2, 4, 5, "");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "val  = 1", "expected 'val  = 1', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_replace_range() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// "val x = 1" -> replace "x = 1" (offsets 4..9) with "y = 42"
	store.open("file:///test.kt", "kotlin", 1, "val x = 1");
	store.apply_change("file:///test.kt", 2, 4, 9, "y = 42");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "val y = 42", "expected 'val y = 42', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_insert_at_beginning() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun main() {}");
	store.apply_change("file:///test.kt", 2, 0, 0, "package com.example\n");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "package com.example\nfun main() {}",
			"unexpected content: '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_insert_at_end() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun main()");
	store.apply_change("file:///test.kt", 2, 10, 10, " {}");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "fun main() {}",
			"expected 'fun main() {}', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_multiline_change() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// "line1\nline2\nline3" -> replace "line2\n" (offsets 6..12) with "replaced\n"
	store.open("file:///test.kt", "kotlin", 1, "line1\nline2\nline3");
	store.apply_change("file:///test.kt", 2, 6, 12, "replaced\n");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "line1\nreplaced\nline3",
			"expected 'line1\\nreplaced\\nline3', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_replace_entire_content() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "old content");
	store.apply_change("file:///test.kt", 2, 0, 11, "new stuff");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "new stuff",
			"expected 'new stuff', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_multiple_changes_reverse_order() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// "abcdef" -> change1: replace 'c' (2..3) with 'C'
	//          -> change2: replace 'e' (4..5) with 'E'
	// Applied in reverse: change2 first, then change1
	store.open("file:///test.kt", "kotlin", 1, "abcdef");

	// Apply change2 first (higher offset)
	store.apply_change("file:///test.kt", 2, 4, 5, "E");
	// Apply change1 (lower offset, still valid because earlier offsets unaffected)
	store.apply_change("file:///test.kt", 2, 2, 3, "C");

	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "abCdEf",
			"expected 'abCdEf', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_invalidates_cached_ast() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun foo() {}");

	// Force AST cache
	ParseResult* before = store.get_ast("file:///test.kt")!!;
	assert(before.node_count >= 2);

	// Apply incremental change: replace "foo" (4..7) with "bar"
	store.apply_change("file:///test.kt", 2, 4, 7, "bar");

	// AST should be re-parsed with new content
	ParseResult* after = store.get_ast("file:///test.kt")!!;
	bool found_bar = false;
	for (uint i = 0; i < after.node_count; i++) {
		if (after.nodes[i].kind == FUN_DECL && after.nodes[i].name == "bar") {
			found_bar = true;
		}
	}
	assert(found_bar, "expected to find function 'bar' after incremental change");
}

fn void incremental_empty_to_content() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "");
	store.apply_change("file:///test.kt", 2, 0, 0, "fun main() {}");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "fun main() {}",
			"expected 'fun main() {}', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_content_to_empty() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	store.open("file:///test.kt", "kotlin", 1, "fun main() {}");
	store.apply_change("file:///test.kt", 2, 0, 14, "");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "",
			"expected empty content, got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}

fn void incremental_nonexistent_doc_is_safe() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// Should not crash when applying change to non-existent document
	store.apply_change("file:///nope.kt", 1, 0, 0, "hello");
}

fn void incremental_clamped_offsets() @test {
	DocumentStore store;
	store.init();
	defer store.free();
	// End offset past content length should be clamped
	store.open("file:///test.kt", "kotlin", 1, "abc");
	store.apply_change("file:///test.kt", 2, 1, 100, "XY");
	if (try doc = store.get("file:///test.kt")) {
		assert(doc.content == "aXY",
			"expected 'aXY', got '%s'", doc.content);
	} else {
		assert(false, "document not found");
	}
}
