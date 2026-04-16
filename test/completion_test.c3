module kls::test::completion_test;

import std::collections::object;
import kls::lsp::completion;

// ── get_prefix_at_position ─────────────────────────────────────────

fn void prefix_empty_content() @test {
	String prefix = completion::get_prefix_at_position("", 0, 0);
	assert(prefix == "", "expected empty prefix for empty content, got '%s'", prefix);
}

fn void prefix_at_start_of_line() @test {
	String prefix = completion::get_prefix_at_position("fun main()", 0, 0);
	assert(prefix == "", "expected empty prefix at start, got '%s'", prefix);
}

fn void prefix_mid_identifier() @test {
	// "fun" at cols 0,1,2 -- cursor at col 2 means we've typed "fu"
	String prefix = completion::get_prefix_at_position("fun main()", 0, 2);
	assert(prefix == "fu", "expected 'fu', got '%s'", prefix);
}

fn void prefix_end_of_identifier() @test {
	// cursor at col 3 = end of "fun"
	String prefix = completion::get_prefix_at_position("fun main()", 0, 3);
	assert(prefix == "fun", "expected 'fun', got '%s'", prefix);
}

fn void prefix_after_space() @test {
	// col 4 is start of "main", cursor right at 'm' -- nothing typed yet
	// actually col 3 is space, col 4 is 'm'. cursor at 4 means we're
	// between the space and 'm', no chars consumed yet
	String prefix = completion::get_prefix_at_position("fun main()", 0, 4);
	assert(prefix == "", "expected empty prefix at start of identifier, got '%s'", prefix);
}

fn void prefix_mid_second_identifier() @test {
	// "main" starts at col 4, cursor at col 6 means we've typed "ma"
	String prefix = completion::get_prefix_at_position("fun main()", 0, 6);
	assert(prefix == "ma", "expected 'ma', got '%s'", prefix);
}

fn void prefix_full_second_identifier() @test {
	// "main" ends at col 8 (exclusive), cursor at col 8
	String prefix = completion::get_prefix_at_position("fun main()", 0, 8);
	assert(prefix == "main", "expected 'main', got '%s'", prefix);
}

fn void prefix_on_second_line() @test {
	// "val x = 1\nfu" -- line 1, col 2 should give prefix "fu"
	String prefix = completion::get_prefix_at_position("val x = 1\nfu", 1, 2);
	assert(prefix == "fu", "expected 'fu', got '%s'", prefix);
}

fn void prefix_after_dot() @test {
	// "obj.me" -- cursor at col 6, prefix should be "me"
	String prefix = completion::get_prefix_at_position("obj.me", 0, 6);
	assert(prefix == "me", "expected 'me', got '%s'", prefix);
}

fn void prefix_right_after_dot() @test {
	// "obj." -- cursor at col 4, nothing after dot
	String prefix = completion::get_prefix_at_position("obj.", 0, 4);
	assert(prefix == "", "expected empty prefix right after dot, got '%s'", prefix);
}

fn void prefix_after_paren() @test {
	// "foo(b" -- cursor at col 5, prefix should be "b"
	String prefix = completion::get_prefix_at_position("foo(b", 0, 5);
	assert(prefix == "b", "expected 'b', got '%s'", prefix);
}

// ── keyword completions ────────────────────────────────────────────

fn void keywords_with_prefix_fu() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_keyword_completions(items, "fu");

		// Should include "fun" but not "for" or "val"
		bool found_fun = false;
		bool found_for = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "fun") found_fun = true;
			if (label == "for") found_for = true;
		}
		assert(found_fun, "expected 'fun' in completions for prefix 'fu'");
		assert(!found_for, "'for' should not match prefix 'fu'");
	};
}

fn void keywords_with_prefix_val_exact_excluded() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_keyword_completions(items, "val");

		// "val" exact match should be excluded, "value" and "vararg" should not match
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			assert(label != "val", "'val' exact match should be excluded");
		}
		// "value" starts with "val", should be present
		bool found_value = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "value") found_value = true;
		}
		assert(found_value, "expected 'value' in completions for prefix 'val'");
	};
}

fn void keywords_empty_prefix_returns_all() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_keyword_completions(items, "");

		// Should have all keywords
		usz count = items.get_len();
		assert(count == completion::KOTLIN_KEYWORDS.len,
			"expected %d keywords, got %d", (int)completion::KOTLIN_KEYWORDS.len, (int)count);
	};
}

// ── identifier completions ─────────────────────────────────────────

fn void identifiers_from_document() @test {
	@pool() {
		String content = "val myVariable = 1\nval myOther = myV";
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, content, "myV");

		bool found = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "myVariable") found = true;
		}
		assert(found, "expected 'myVariable' in identifier completions for prefix 'myV'");
	};
}

fn void identifiers_dedup() @test {
	@pool() {
		// "x" appears 3 times, should only show once
		String content = "val x = 1\nval y = x\nval z = x";
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, content, "x");

		// "x" is an exact match of prefix, so should be excluded
		assert(items.get_len() == 0, "expected 0 items (exact match excluded), got %d", (int)items.get_len());
	};
}

fn void identifiers_dedup_non_exact() @test {
	@pool() {
		// "xyz" appears twice, prefix is "xy" -- should only get one "xyz"
		String content = "val xyz = 1\nval a = xyz";
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, content, "xy");

		usz count = 0;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "xyz") count++;
		}
		assert(count == 1, "expected 1 'xyz', got %d", (int)count);
	};
}

fn void identifiers_empty_prefix() @test {
	@pool() {
		String content = "val abc = 1\nval def = 2";
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, content, "");

		// Should find "abc" and "def" (identifiers only, not keywords)
		bool found_abc = false;
		bool found_def = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "abc") found_abc = true;
			if (label == "def") found_def = true;
		}
		assert(found_abc, "expected 'abc' in completions");
		assert(found_def, "expected 'def' in completions");
	};
}

fn void identifiers_empty_content() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, "", "foo");
		assert(items.get_len() == 0, "expected 0 items for empty content");
	};
}

fn void identifiers_no_match() @test {
	@pool() {
		String content = "val abc = 1";
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, content, "xyz");
		assert(items.get_len() == 0, "expected 0 items for non-matching prefix");
	};
}

// ── completion item structure ──────────────────────────────────────

fn void keyword_item_has_correct_kind() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_keyword_completions(items, "fu");

		Object* item = items.get_at(0);
		int kind = item.get_int("kind")!!;
		assert(kind == completion::COMPLETION_KIND_KEYWORD,
			"expected kind %d, got %d", completion::COMPLETION_KIND_KEYWORD, kind);

		String detail = item.get_string("detail")!!;
		assert(detail == "Keyword", "expected detail 'Keyword', got '%s'", detail);
	};
}

fn void identifier_item_has_correct_kind() @test {
	@pool() {
		String content = "val myVar = 1";
		Object* items = object::new_obj(tmem);
		completion::add_identifier_completions(items, content, "my");

		Object* item = items.get_at(0);
		int kind = item.get_int("kind")!!;
		assert(kind == completion::COMPLETION_KIND_VARIABLE,
			"expected kind %d, got %d", completion::COMPLETION_KIND_VARIABLE, kind);

		String detail = item.get_string("detail")!!;
		assert(detail == "Identifier", "expected detail 'Identifier', got '%s'", detail);
	};
}

// ── Type argument context detection ────────────────────────────────

fn void type_arg_context_inside_angle_brackets() @test {
	// "List<" then cursor -- should be type argument context
	bool result = completion::is_type_argument_context("val x: List<", 0, 12, "");
	assert(result, "expected type argument context inside List<");
}

fn void type_arg_context_not_in_normal_code() @test {
	bool result = completion::is_type_argument_context("val x = 1", 0, 9, "");
	assert(!result, "should not be type argument context in normal code");
}

fn void type_arg_context_after_comma() @test {
	// "Map<String, " then cursor
	bool result = completion::is_type_argument_context("val x: Map<String, ", 0, 19, "");
	assert(result, "expected type argument context after comma in Map<String, ");
}
