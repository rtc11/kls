module kls::test::javadoc_test;

import kls::deps::javadoc;

// ── clean_javadoc: inline tags ────────────────────────────────────

fn void clean_code_tag() @test {
	@pool() {
		String input = "Returns the {@code nanoTime} value";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("`nanoTime`"),
			"expected `nanoTime` in result, got: '%s'", result);
	};
}

fn void clean_link_tag_with_hash() @test {
	@pool() {
		String input = "See {@link System#currentTimeMillis()}";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("System.currentTimeMillis()"),
			"expected System.currentTimeMillis() in result, got: '%s'", result);
	};
}

fn void clean_link_tag_class_only() @test {
	@pool() {
		String input = "Returns a {@link String}";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("String"),
			"expected String in result, got: '%s'", result);
		assert(!result.contains("{@"),
			"should not contain raw tag, got: '%s'", result);
	};
}

fn void clean_link_tag_with_display_text() @test {
	@pool() {
		String input = "See {@link System#nanoTime() the docs}";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("the docs"),
			"expected display text 'the docs' in result, got: '%s'", result);
	};
}

fn void clean_linkplain_tag() @test {
	@pool() {
		String input = "Use {@linkplain Thread#sleep sleep}";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("sleep"),
			"expected 'sleep' in result, got: '%s'", result);
		assert(!result.contains("{@"),
			"should not contain raw tag, got: '%s'", result);
	};
}

fn void clean_literal_tag() @test {
	@pool() {
		String input = "Must be {@literal > 0}";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("> 0"),
			"expected '> 0' in result, got: '%s'", result);
	};
}

// ── clean_javadoc: HTML tags ──────────────────────────────────────

fn void clean_paragraph_tag() @test {
	@pool() {
		String input = "First paragraph.<p>Second paragraph.";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("First paragraph."),
			"expected first paragraph, got: '%s'", result);
		assert(result.contains("Second paragraph."),
			"expected second paragraph, got: '%s'", result);
		assert(!result.contains("<p>"),
			"should not contain <p> tag, got: '%s'", result);
	};
}

fn void clean_sup_tag() @test {
	@pool() {
		String input = "2<sup>63</sup> nanoseconds";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("^63"),
			"expected ^63 in result, got: '%s'", result);
		assert(!result.contains("<sup>"),
			"should not contain <sup> tag, got: '%s'", result);
	};
}

fn void clean_strips_unknown_html() @test {
	@pool() {
		String input = "Text with <blockquote>quote</blockquote> and more";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("Text with"),
			"expected 'Text with', got: '%s'", result);
		assert(result.contains("quote"),
			"expected 'quote', got: '%s'", result);
		assert(result.contains("and more"),
			"expected 'and more', got: '%s'", result);
		assert(!result.contains("<blockquote>"),
			"should not contain HTML tag, got: '%s'", result);
	};
}

fn void clean_pre_code_block() @test {
	@pool() {
		String input = "Example: <pre> {@code\nlong t = System.nanoTime();}</pre>";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("```"),
			"expected fenced code block, got: '%s'", result);
		assert(result.contains("long t = System.nanoTime();"),
			"expected code content, got: '%s'", result);
	};
}

// ── clean_javadoc: block tags ─────────────────────────────────────

fn void clean_param_tag() @test {
	@pool() {
		String input = "Does something.\n@param name the name";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("**name**"),
			"expected bold param name, got: '%s'", result);
		assert(result.contains("the name"),
			"expected param description, got: '%s'", result);
	};
}

fn void clean_return_tag() @test {
	@pool() {
		String input = "Does something.\n@return the result";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("**Returns:**"),
			"expected Returns label, got: '%s'", result);
		assert(result.contains("the result"),
			"expected return description, got: '%s'", result);
	};
}

fn void clean_throws_tag() @test {
	@pool() {
		String input = "Does something.\n@throws IllegalArgumentException if invalid";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("**Throws**"),
			"expected Throws label, got: '%s'", result);
		assert(result.contains("IllegalArgumentException"),
			"expected exception name, got: '%s'", result);
		assert(result.contains("if invalid"),
			"expected throws description, got: '%s'", result);
	};
}

fn void clean_since_stripped() @test {
	@pool() {
		String input = "Does something.\n@since 1.5";
		String result = javadoc::clean_javadoc(input);
		assert(!result.contains("@since"),
			"@since should be stripped, got: '%s'", result);
		assert(!result.contains("1.5"),
			"since version should be stripped, got: '%s'", result);
	};
}

fn void clean_see_stripped() @test {
	@pool() {
		String input = "Does something.\n@see OtherClass";
		String result = javadoc::clean_javadoc(input);
		assert(!result.contains("@see"),
			"@see should be stripped, got: '%s'", result);
	};
}

// ── clean_javadoc: combined/realistic ─────────────────────────────

fn void clean_realistic_nanotime_javadoc() @test {
	@pool() {
		String input =
			"Returns the current value of the running Java Virtual Machine's\n"
			"high-resolution time source, in nanoseconds.\n"
			"\n"
			"<p>This method provides nanosecond precision, but not necessarily\n"
			"nanosecond resolution (that is, how frequently the value changes)\n"
			"- no guarantees are made except that the resolution is at least as\n"
			"good as that of {@link #currentTimeMillis()}.\n"
			"\n"
			"@return the current value of the running Java Virtual Machine's\n"
			"        high-resolution time source, in nanoseconds\n"
			"@since 1.5";
		String result = javadoc::clean_javadoc(input);
		assert(result.contains("high-resolution time source"),
			"expected description text, got: '%s'", result);
		assert(result.contains("currentTimeMillis()"),
			"expected resolved link, got: '%s'", result);
		assert(result.contains("**Returns:**"),
			"expected Returns label, got: '%s'", result);
		assert(!result.contains("{@link"),
			"should not contain raw @link tag, got: '%s'", result);
		assert(!result.contains("@since"),
			"@since should be stripped, got: '%s'", result);
	};
}

// ── line_col_to_offset ────────────────────────────────────────────

fn void line_col_to_offset_first_line() @test {
	String content = "public class Foo {}";
	uint off = javadoc::line_col_to_offset(content, 0, 7);
	assert(off == 7, "expected 7, got %d", (int)off);
}

fn void line_col_to_offset_second_line() @test {
	String content = "package foo;\npublic class Bar {}";
	uint off = javadoc::line_col_to_offset(content, 1, 0);
	assert(off == 13, "expected 13, got %d", (int)off);
}

fn void line_col_to_offset_with_col() @test {
	String content = "line0\nline1\nline2";
	uint off = javadoc::line_col_to_offset(content, 2, 3);
	// line0\n = 6 bytes, line1\n = 6 bytes, + col 3 = 15
	assert(off == 15, "expected 15, got %d", (int)off);
}
