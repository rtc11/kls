module kls::test::token_cache_test;

import kls::kotlin::token_cache;
import kls::kotlin::token;
import kls::kotlin::lexer;
import std::core::mem;

// ── Helper: heap-allocate a TokenCache (too large for stack) ───────

fn TokenCache* new_cache() {
	return mem::new(TokenCache);
}

fn void free_cache(TokenCache* c) {
	mem::free(c);
}

// ── Helper: verify cache tokens match full lex ─────────────────────

fn void assert_cache_matches_lex(TokenCache* cache, String source) {
	Lexer lex = lexer::init(source);
	uint i = 0;
	while (i < cache.count) {
		Token expected = lex.next();
		Token cached = cache.tokens[i];
		assert(cached.kind == expected.kind,
			"token %d kind mismatch: expected %d, got %d", (int)i, (int)expected.kind, (int)cached.kind);
		assert(cached.offset == expected.offset,
			"token %d offset mismatch: expected %d, got %d", (int)i, (int)expected.offset, (int)cached.offset);
		if (expected.kind == EOF) break;
		i++;
	}
}

// ── build_cache tests ──────────────────────────────────────────────

fn void build_cache_empty_source() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "");
		assert(cache.count == 1, "expected 1 (EOF), got %d", (int)cache.count);
		assert(cache.tokens[0].kind == EOF, "expected EOF token");
	};
}

fn void build_cache_single_token() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "x");
		assert(cache.count == 2, "expected 2 tokens, got %d", (int)cache.count);
		assert(cache.tokens[0].kind == IDENTIFIER, "expected IDENTIFIER");
		assert(cache.tokens[0].text == "x", "expected 'x'");
		assert(cache.tokens[1].kind == EOF, "expected EOF");
	};
}

fn void build_cache_multiple_tokens() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "fun main() {}");
		assert(cache.count == 7, "expected 7 tokens, got %d", (int)cache.count);
		assert(cache.tokens[0].kind == KW_FUN, "expected KW_FUN");
		assert(cache.tokens[1].kind == IDENTIFIER, "expected IDENTIFIER 'main'");
		assert(cache.tokens[cache.count - 1].kind == EOF, "last token should be EOF");
	};
}

fn void build_cache_skips_whitespace_comments() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "  val  x  // comment\n  = 42");
		assert(cache.count == 5, "expected 5 tokens, got %d", (int)cache.count);
		assert(cache.tokens[0].kind == KW_VAL, "expected KW_VAL");
		assert(cache.tokens[1].kind == IDENTIFIER, "expected IDENTIFIER");
	};
}

fn void build_cache_offsets_correct() @test {
	@pool() {
		String source = "val x = 42";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, source);
		assert_cache_matches_lex(cache, source);
	};
}

// ── patch: insert at end ───────────────────────────────────────────

fn void patch_insert_at_end() @test {
	@pool() {
		String old_src = "val x";
		String new_src = "val x = 1";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, old_src);

		bool ok = cache.patch(new_src, old_src, 5, 5, 4);
		assert(ok, "patch should succeed");
		assert(cache.count >= 5, "expected at least 5 tokens, got %d", (int)cache.count);
		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
		assert(cache.tokens[cache.count - 1].offset == (uint)new_src.len, "EOF offset should match source len");
	};
}

// ── patch: insert at start ─────────────────────────────────────────

fn void patch_insert_at_start() @test {
	@pool() {
		String old_src = "x";
		String new_src = "val x";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, old_src);

		bool ok = cache.patch(new_src, old_src, 0, 0, 4);
		assert(ok, "patch should succeed");
		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
	};
}

// ── patch: delete tokens ───────────────────────────────────────────

fn void patch_delete_token() @test {
	@pool() {
		String old_src = "val x = 1";
		String new_src = "val x";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, old_src);

		uint old_count = cache.count;
		bool ok = cache.patch(new_src, old_src, 5, 9, 0);
		assert(ok, "patch should succeed");
		assert(cache.count < old_count, "token count should decrease");
		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
	};
}

// ── patch: replace within single token ─────────────────────────────

fn void patch_rename_identifier() @test {
	@pool() {
		String old_src = "val foo = 1";
		String new_src = "val bar = 1";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, old_src);

		bool ok = cache.patch(new_src, old_src, 4, 7, 3);
		assert(ok, "patch should succeed");

		bool found_bar = false;
		for (uint i = 0; i < cache.count; i++) {
			if (cache.tokens[i].kind == IDENTIFIER && cache.tokens[i].text == "bar") {
				found_bar = true;
				break;
			}
		}
		assert(found_bar, "should find renamed identifier 'bar'");
	};
}

// ── patch: replace spanning multiple tokens ────────────────────────

fn void patch_replace_multiple_tokens() @test {
	@pool() {
		String old_src = "val x = 1 + 2";
		String new_src = "val x = 99";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, old_src);

		bool ok = cache.patch(new_src, old_src, 8, 13, 2);
		assert(ok, "patch should succeed");
		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
		assert(cache.tokens[cache.count - 1].offset == (uint)new_src.len, "EOF offset should match new source");
	};
}

// ── patch: insert creating new tokens ──────────────────────────────

fn void patch_insert_new_tokens() @test {
	@pool() {
		String old_src = "val x = 1";
		String new_src = "val x = 1 + y";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, old_src);

		uint old_count = cache.count;
		bool ok = cache.patch(new_src, old_src, 9, 9, 4);
		assert(ok, "patch should succeed");
		assert(cache.count > old_count, "should have more tokens");
	};
}

// ── patch: sequential patches ──────────────────────────────────────

fn void patch_sequential() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "val x = 1");

		bool ok1 = cache.patch("val x = 12", "val x = 1", 9, 9, 1);
		assert(ok1, "first patch should succeed");

		bool ok2 = cache.patch("val x = 123", "val x = 12", 10, 10, 1);
		assert(ok2, "second patch should succeed");

		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
	};
}

// ── patch: delete entire content ───────────────────────────────────

fn void patch_delete_all() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "val x = 1");

		bool ok = cache.patch("", "val x = 1", 0, 9, 0);
		if (ok) {
			assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
		}
	};
}

// ── patch: no-op edit ──────────────────────────────────────────────

fn void patch_noop_edit() @test {
	@pool() {
		String src = "val x = 1";
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, src);

		// Empty edit at offset 5 (between tokens)
		bool ok = cache.patch(src, src, 5, 5, 0);
		// No-op may re-lex boundary region — just verify no crash + EOF last
		if (ok) {
			assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
		}
	};
}

// ── patch: insert in middle ────────────────────────────────────────

fn void patch_insert_middle() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		token_cache::build_cache(cache, "val x = 1");

		String new_src = "val myX = 1";
		bool ok = cache.patch(new_src, "val x = 1", 4, 5, 3);
		assert(ok, "patch should succeed");
		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
		assert(cache.tokens[cache.count - 1].offset == (uint)new_src.len, "EOF offset = source len");
	};
}

// ── patch: multiline source ────────────────────────────────────────

fn void patch_multiline() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		String old_src = "fun foo() {\n    val x = 1\n}";
		token_cache::build_cache(cache, old_src);

		String new_src = "fun foo() {\n    val x = 42\n}";
		bool ok = cache.patch(new_src, old_src, 24, 25, 2);
		assert(ok, "patch should succeed");
		assert(cache.tokens[cache.count - 1].kind == EOF, "last should be EOF");
	};
}

// ── patch: line numbers shift when inserting newline ───────────────

fn void patch_line_numbers_shift_on_newline_insert() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		// Line 0: "val x = 1\n", Line 1: "val y = 2"
		String old_src = "val x = 1\nval y = 2";
		token_cache::build_cache(cache, old_src);

		// Verify y is on line 1 before edit
		bool found_y = false;
		for (uint i = 0; i < cache.count; i++) {
			if (cache.tokens[i].kind == IDENTIFIER && cache.tokens[i].text == "y") {
				assert(cache.tokens[i].line == 1, "y should be on line 1 before edit, got %d", (int)cache.tokens[i].line);
				found_y = true;
				break;
			}
		}
		assert(found_y, "should find identifier y");

		// Insert a blank line after first line: "val x = 1\n\nval y = 2"
		String new_src = "val x = 1\n\nval y = 2";
		bool ok = cache.patch(new_src, old_src, 10, 10, 1); // insert '\n' at offset 10
		assert(ok, "patch should succeed");

		// Now y should be on line 2
		for (uint i = 0; i < cache.count; i++) {
			if (cache.tokens[i].kind == IDENTIFIER && cache.tokens[i].text == "y") {
				assert(cache.tokens[i].line == 2, "y should be on line 2 after insert, got %d", (int)cache.tokens[i].line);
				break;
			}
		}
	};
}

// ── patch: line numbers shift when deleting newline ────────────────

fn void patch_line_numbers_shift_on_newline_delete() @test {
	@pool() {
		TokenCache* cache = new_cache();
		defer free_cache(cache);
		// Line 0: "val x = 1\n", Line 1: "\n", Line 2: "val y = 2"
		String old_src = "val x = 1\n\nval y = 2";
		token_cache::build_cache(cache, old_src);

		// Verify y on line 2
		for (uint i = 0; i < cache.count; i++) {
			if (cache.tokens[i].kind == IDENTIFIER && cache.tokens[i].text == "y") {
				assert(cache.tokens[i].line == 2, "y should be on line 2, got %d", (int)cache.tokens[i].line);
				break;
			}
		}

		// Delete the blank line: remove '\n' at offset 10
		String new_src = "val x = 1\nval y = 2";
		bool ok = cache.patch(new_src, old_src, 10, 11, 0);
		assert(ok, "patch should succeed");

		// Now y should be on line 1
		for (uint i = 0; i < cache.count; i++) {
			if (cache.tokens[i].kind == IDENTIFIER && cache.tokens[i].text == "y") {
				assert(cache.tokens[i].line == 1, "y should be on line 1 after delete, got %d", (int)cache.tokens[i].line);
				break;
			}
		}
	};
}
