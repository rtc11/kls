module kls::test::document_link_test;

import std::collections::object;
import kls::document;
import kls::workspace;
import kls::lsp::document_link;

// ── Helper ──────────────────────────────────────────────────────

fn Object* make_params(String uri) {
	Object* params = object::new_obj(tmem);
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	params.set("textDocument", td);
	return params;
}

// ── URL link tests ──────────────────────────────────────────────

fn void url_in_line_comment() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `// See https://kotlinlang.org/docs/reference/
fun main() {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* result = document_link::handle_document_link(&store, null, make_params("file:///test.kt"))!!;
		assert(result.is_array(), "expected links array");
		assert(result.get_len() >= 1, "expected at least 1 URL link, got %d", (int)result.get_len());

		Object* link = result.get_at(0);
		String target = link.get_string("target") ?? "";
		assert(target.contains("kotlinlang.org"), "expected kotlinlang.org URL, got '%s'", target);

		// Check range is on line 0
		Object* range = link.get("range")!!;
		Object* start = range.get("start")!!;
		assert(start.get_int("line")!! == 0, "expected line 0");
	};
}

fn void url_in_block_comment() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `/**
 * Documentation: http://example.com/docs
 */
fun main() {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* result = document_link::handle_document_link(&store, null, make_params("file:///test.kt"))!!;
		assert(result.is_array(), "expected links array");
		assert(result.get_len() >= 1, "expected at least 1 URL link, got %d", (int)result.get_len());

		Object* link = result.get_at(0);
		String target = link.get_string("target") ?? "";
		assert(target == "http://example.com/docs", "expected http://example.com/docs, got '%s'", target);

		// URL is on line 1
		Object* range = link.get("range")!!;
		Object* start = range.get("start")!!;
		assert(start.get_int("line")!! == 1, "expected line 1");
	};
}

fn void multiple_urls() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `// https://first.com/path
// https://second.com/other`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* result = document_link::handle_document_link(&store, null, make_params("file:///test.kt"))!!;
		assert(result.is_array(), "expected links array");
		assert(result.get_len() == 2, "expected 2 URL links, got %d", (int)result.get_len());

		String t0 = result.get_at(0).get_string("target") ?? "";
		String t1 = result.get_at(1).get_string("target") ?? "";
		assert(t0.contains("first.com"), "first link should contain first.com");
		assert(t1.contains("second.com"), "second link should contain second.com");
	};
}

fn void no_urls_no_links() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `fun main() {
    val _x = 42
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* result = document_link::handle_document_link(&store, null, make_params("file:///test.kt"))!!;
		assert(result.is_indexable());
		assert(result.get_len() == 0, "expected no links, got %d", (int)result.get_len());
	};
}

fn void url_strips_trailing_punctuation() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = `// See https://example.com/path.`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* result = document_link::handle_document_link(&store, null, make_params("file:///test.kt"))!!;
		assert(result.is_array(), "expected links array");
		assert(result.get_len() >= 1, "expected at least 1 link");

		String target = result.get_at(0).get_string("target") ?? "";
		assert(target == "https://example.com/path", "should strip trailing dot, got '%s'", target);
	};
}

fn void https_url_range_correct() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "// " is 3 chars, URL starts at col 3
		String content = `// https://example.com`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* result = document_link::handle_document_link(&store, null, make_params("file:///test.kt"))!!;
		assert(result.is_array());
		assert(result.get_len() == 1);

		Object* range = result.get_at(0).get("range")!!;
		Object* start = range.get("start")!!;
		Object* end_pos = range.get("end")!!;
		assert(start.get_int("character")!! == 3, "URL should start at col 3");
		assert(end_pos.get_int("character")!! == 22, "URL should end at col 22");
	};
}
