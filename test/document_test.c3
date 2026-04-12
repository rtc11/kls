module kls::document_test;

import kls::document;

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
