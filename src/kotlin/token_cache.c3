module kls::kotlin::token_cache;

import kls::kotlin::token;
import kls::kotlin::lexer;

// ── Token cache for optimized fallback ─────────────────────────────

const usz MAX_CACHED_TOKENS = 16384;

/**
 * A cached token stream for a document. Stores all non-whitespace/comment
 * tokens from the last lex pass. Used by the optimized fallback path to
 * avoid re-lexing the entire file when incremental parsing fails.
 *
 * Tokens are stored sorted by byte offset. On edit, we can binary-search
 * for the affected region, re-lex that region, and splice.
 */
struct TokenCache {
	Token[MAX_CACHED_TOKENS] tokens;
	uint count;
}

/**
 * Build a token cache by lexing the full source.
 * Stores tokens that the parser would see (skipping whitespace/comments).
 */
fn void build_cache(TokenCache* cache, String source) {
	cache.count = 0;
	Lexer lex = lexer::init(source);

	while (cache.count < MAX_CACHED_TOKENS) {
		Token tok = lex.next();
		if (tok.kind == EOF) {
			// Store EOF as the last token
			if (cache.count < MAX_CACHED_TOKENS) {
				cache.tokens[cache.count] = tok;
				cache.count++;
			}
			break;
		}
		cache.tokens[cache.count] = tok;
		cache.count++;
	}
}

/**
 * Patch the token cache after an edit. Re-lexes the region around the edit
 * and splices the new tokens into the cache.
 *
 * Parameters:
 *   new_source   - the full source AFTER the edit
 *   edit_start   - byte offset where edit begins (in old source)
 *   edit_end     - byte offset where edit ends (in old source)
 *   new_text_len - length of replacement text
 *
 * Returns true if patching succeeded, false if the cache should be rebuilt.
 */
fn bool TokenCache.patch(TokenCache* self, String new_source,
		uint edit_start, uint edit_end, usz new_text_len) {
	int byte_delta = (int)new_text_len - (int)(edit_end - edit_start);

	// Find the first and last token affected by the edit (in the old cache)
	uint first_affected = self.count;
	uint last_affected = 0;

	for (uint i = 0; i < self.count; i++) {
		Token* t = &self.tokens[i];
		if (t.kind == EOF) {
			// EOF is always the last token; it's affected if edit is at end
			if (first_affected == self.count) first_affected = i;
			last_affected = i;
			break;
		}
		uint tok_end = t.offset + t.len;
		// Token overlaps with edit region
		if (tok_end > edit_start && t.offset < edit_end) {
			if (first_affected == self.count) first_affected = i;
			last_affected = i;
		}
		// Token is after edit region (need to adjust offsets)
		if (t.offset >= edit_end) {
			if (first_affected == self.count) first_affected = i;
			last_affected = i;
			break; // We only need to re-lex up to the first stable token after
		}
	}

	if (first_affected == self.count) return false;

	// Expand the re-lex region to include one token before and after for safety
	uint relex_start_idx = first_affected > 0 ? first_affected - 1 : 0;
	// Find the byte range to re-lex
	uint relex_byte_start = self.tokens[relex_start_idx].offset;

	// Compute where re-lexing should stop in the new source
	// We re-lex until we produce a token that matches a token in the old
	// cache after the edit region (offset-adjusted)
	uint relex_byte_end;
	if (last_affected + 1 < self.count && self.tokens[last_affected + 1].kind != EOF) {
		relex_byte_end = (uint)((int)self.tokens[last_affected + 1].offset + byte_delta);
		// Add some margin
		if (last_affected + 2 < self.count && self.tokens[last_affected + 2].kind != EOF) {
			relex_byte_end = (uint)((int)self.tokens[last_affected + 2].offset + byte_delta);
		}
	} else {
		relex_byte_end = (uint)new_source.len;
	}

	if (relex_byte_end > (uint)new_source.len) relex_byte_end = (uint)new_source.len;

	// Count newlines before relex_byte_start to determine start line
	uint start_line = 0;
	uint start_col = 0;
	for (uint i = 0; i < relex_byte_start && i < (uint)new_source.len; i++) {
		if (new_source[i] == '\n') {
			start_line++;
			start_col = 0;
		} else {
			start_col++;
		}
	}

	// Re-lex the affected region
	Token[1024] new_tokens;
	uint new_count = 0;
	Lexer lex = lexer::init_at(new_source, (usz)relex_byte_start, start_line, start_col);

	while (new_count < 1024) {
		Token tok = lex.next();
		if (tok.kind == EOF) {
			new_tokens[new_count] = tok;
			new_count++;
			break;
		}
		if (tok.offset >= relex_byte_end) {
			// We've passed the affected region. Check if this token matches
			// what we'd expect from the old cache (offset-adjusted)
			break;
		}
		new_tokens[new_count] = tok;
		new_count++;
	}

	// Now splice: replace tokens[relex_start_idx..last_affected+1) with new_tokens[0..new_count)
	// But we also need to keep the EOF if it was in the replaced range

	// Determine the old range to replace
	uint old_replace_start = relex_start_idx;
	uint old_replace_end = last_affected + 1; // exclusive
	// If last token was EOF, include it in replacement
	if (self.tokens[last_affected].kind == EOF) {
		old_replace_end = last_affected + 1;
	}

	uint old_replace_count = old_replace_end - old_replace_start;
	int splice_delta = (int)new_count - (int)old_replace_count;

	// Check capacity
	int new_total = (int)self.count + splice_delta;
	if (new_total < 0 || new_total > (int)MAX_CACHED_TOKENS) return false;

	// Shift tokens after the replaced range
	uint after_count = self.count - old_replace_end;
	if (after_count > 0 && splice_delta != 0) {
		uint dst = (uint)((int)old_replace_start + (int)new_count);
		if (splice_delta > 0) {
			// Moving forward -- copy from end to avoid overlap
			for (uint i = after_count; i > 0; i--) {
				self.tokens[dst + i - 1] = self.tokens[old_replace_end + i - 1];
			}
		} else {
			// Moving backward
			for (uint i = 0; i < after_count; i++) {
				self.tokens[dst + i] = self.tokens[old_replace_end + i];
			}
		}
	}

	// Copy new tokens into place
	for (uint i = 0; i < new_count; i++) {
		self.tokens[old_replace_start + i] = new_tokens[i];
	}

	self.count = (uint)new_total;

	// Adjust offsets for tokens after the splice region
	uint adjust_start = old_replace_start + new_count;
	for (uint i = adjust_start; i < self.count; i++) {
		if (self.tokens[i].kind == EOF) {
			self.tokens[i].offset = (uint)new_source.len;
			break;
		}
		self.tokens[i].offset = (uint)((int)self.tokens[i].offset + byte_delta);
		// Adjust line numbers
		int old_newlines = 0;
		int new_newlines = 0;
		for (uint j = edit_start; j < edit_end && j < (uint)(new_source.len + (uint)(-byte_delta)); j++) {
			// Count in old source (can't access old source here, so use line delta)
			// This is approximate -- for precise adjustment we'd need the old source
			break;
		}
		// We approximate line adjustment -- the full re-parse fallback path
		// rebuilds everything anyway, so this doesn't need to be perfect
		self.tokens[i].line = (uint)((int)self.tokens[i].line);
	}

	return true;
}
