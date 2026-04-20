module kls::document;

import std::collections;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::kotlin::incremental;
import kls::kotlin::token_cache;
import kls::workspace;

const usz MAX_SEMANTIC_DATA = 81920; // 16384 tokens * 5 ints

struct SemanticTokensCache {
	int[MAX_SEMANTIC_DATA] data;
	usz data_len;
	int result_id;
}

struct Document {
	String uri;
	String language_id;
	int version;
	String content;
	ParseResult* cached_ast;    // Lazily populated, heap-allocated
	TypeInfo* cached_types;     // Lazily populated, heap-allocated (parallel to cached_ast)
	ChunkMap* cached_chunks;    // Lazily populated, heap-allocated (parallel to cached_ast)
	TokenCache* cached_tokens;  // Lazily populated, heap-allocated for optimized fallback
	SemanticTokensCache* cached_semantic; // Lazily populated, heap-allocated for delta support
}

struct DocumentStore {
	HashMap{String, Document} docs;
	WorkspaceIndex* workspace;     // optional, set for cross-file type resolution
}

fn void DocumentStore.init(DocumentStore* self) {
	self.docs.init(mem);
	self.workspace = null;
}

fn void DocumentStore.free(DocumentStore* self) {
	// Free heap-allocated document strings and cached ASTs before
	// HashMap.free() clears entries.
	@pool() {
		foreach (&doc : self.docs.tvalues()) {
			if (doc.cached_ast != null) {
				doc.cached_ast.free_errors();
				mem::free(doc.cached_ast);
			}
			if (doc.cached_types != null) {
				mem::free(doc.cached_types);
			}
			if (doc.cached_chunks != null) {
				mem::free(doc.cached_chunks);
			}
			if (doc.cached_tokens != null) {
				mem::free(doc.cached_tokens);
			}
			if (doc.cached_semantic != null) {
				mem::free(doc.cached_semantic);
			}
			mem::free(doc.uri.ptr);
			mem::free(doc.language_id.ptr);
			mem::free(doc.content.ptr);
		}
	};
	self.docs.free();
}

fn void DocumentStore.open(DocumentStore* self, String uri, String language_id, int version, String content) {
	// Free old document strings and cached AST if re-opening the same URI
	if (try old = self.docs.get_ref(uri)) {
		if (old.cached_ast != null) {
			old.cached_ast.free_errors();
			mem::free(old.cached_ast);
		}
		if (old.cached_types != null) {
			mem::free(old.cached_types);
		}
		if (old.cached_chunks != null) {
			mem::free(old.cached_chunks);
		}
		if (old.cached_tokens != null) {
			mem::free(old.cached_tokens);
		}
		if (old.cached_semantic != null) {
			mem::free(old.cached_semantic);
		}
		mem::free(old.uri.ptr);
		mem::free(old.language_id.ptr);
		mem::free(old.content.ptr);
	}
	Document doc = {
		.uri = uri.copy(mem),
		.language_id = language_id.copy(mem),
		.version = version,
		.content = content.copy(mem),
		.cached_ast = null,
		.cached_types = null,
		.cached_chunks = null,
		.cached_tokens = null,
		.cached_semantic = null,
	};
	// HashMap copies keys internally (COPY_KEYS), so pass uri directly
	self.docs.set(uri, doc);
}

fn void DocumentStore.update(DocumentStore* self, String uri, int version, String content) {
	if (try doc = self.docs.get_ref(uri)) {
		// Full content replacement -- invalidate all caches
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
			doc.cached_ast = null;
		}
		if (doc.cached_types != null) {
			mem::free(doc.cached_types);
			doc.cached_types = null;
		}
		if (doc.cached_chunks != null) {
			mem::free(doc.cached_chunks);
			doc.cached_chunks = null;
		}
		if (doc.cached_tokens != null) {
			mem::free(doc.cached_tokens);
			doc.cached_tokens = null;
		}
		// Note: do NOT free cached_semantic here — delta needs previous result
		// to compute diff. It will be updated on next semanticTokens request.
		// Free old content before replacing
		mem::free(doc.content.ptr);
		doc.version = version;
		doc.content = content.copy(mem);
	}
}

/**
 * Invalidate cached ASTs and types on all open documents.
 * Called after dependency re-index so cross-file resolution picks up new deps.
 */
fn void DocumentStore.invalidate_all_caches(DocumentStore* self) {
	@pool() {
		foreach (&doc : self.docs.tvalues()) {
			if (doc.cached_ast != null) {
				doc.cached_ast.free_errors();
				mem::free(doc.cached_ast);
				doc.cached_ast = null;
			}
			if (doc.cached_types != null) {
				mem::free(doc.cached_types);
				doc.cached_types = null;
			}
			if (doc.cached_chunks != null) {
				mem::free(doc.cached_chunks);
				doc.cached_chunks = null;
			}
			if (doc.cached_tokens != null) {
				mem::free(doc.cached_tokens);
				doc.cached_tokens = null;
			}
			// Keep cached_semantic — delta support needs previous result
		}
	};
}

/**
 * Apply a single incremental change to a document.
 * The change replaces the byte range [start_offset, end_offset) with new_text.
 * Attempts incremental re-parse if a chunk map is available; falls back to
 * full invalidation otherwise.
 */
fn void DocumentStore.apply_change(DocumentStore* self, String uri, int version,
		uint start_offset, uint end_offset, String new_text) {
	if (try doc = self.docs.get_ref(uri)) {
		String old_content = doc.content;

		// Clamp offsets to content bounds
		uint s = start_offset > (uint)old_content.len ? (uint)old_content.len : start_offset;
		uint e = end_offset > (uint)old_content.len ? (uint)old_content.len : end_offset;
		if (e < s) e = s;

		usz prefix_len = (usz)s;
		usz suffix_len = old_content.len - (usz)e;
		usz new_len = prefix_len + new_text.len + suffix_len;

		// Build the new content
		char* buf = mem::alloc_array(char, new_len);
		if (prefix_len > 0) {
			mem::copy(buf, old_content.ptr, prefix_len);
		}
		if (new_text.len > 0) {
			mem::copy(&buf[prefix_len], new_text.ptr, new_text.len);
		}
		if (suffix_len > 0) {
			mem::copy(&buf[prefix_len + new_text.len], &old_content.ptr[(usz)e], suffix_len);
		}

		String new_content = (String)buf[:new_len];

		// Try incremental re-parse if we have a cached AST and chunk map
		bool incremental_ok = false;
		if (doc.cached_ast != null && doc.cached_chunks != null) {
			incremental_ok = incremental::try_incremental_reparse(
				doc.cached_ast, doc.cached_chunks,
				old_content, new_content,
				s, e, new_text.len);

			if (incremental_ok) {
				// Incremental parse succeeded -- invalidate types only
				// (types depend on the AST which was updated in-place)
				if (doc.cached_types != null) {
					mem::free(doc.cached_types);
					doc.cached_types = null;
				}
				// Update name/type_text/extra_text String slices that point into
				// old source -- they now need to point into new source.
				// Since String slices point into the source buffer and we replaced
				// it, we need to rebase them. The parser stored slices into the
				// source passed to parse_chunk (which was new_content), so the
				// re-parsed chunk's strings already point to new_content.
				// Strings in unchanged nodes still point to old_content which
				// we're about to free. We must fix these up.
				rebase_string_slices(doc.cached_ast, old_content, new_content, s, e, new_text.len);
			}
		}

		if (!incremental_ok) {
			// Full invalidation -- next get_ast() will re-parse
			if (doc.cached_ast != null) {
				doc.cached_ast.free_errors();
				mem::free(doc.cached_ast);
				doc.cached_ast = null;
			}
			if (doc.cached_types != null) {
				mem::free(doc.cached_types);
				doc.cached_types = null;
			}
			if (doc.cached_chunks != null) {
				mem::free(doc.cached_chunks);
				doc.cached_chunks = null;
			}

			// Optimized fallback: try to patch the token cache so the
			// next full parse can benefit from cached lex results.
			// If patching fails, the cache is rebuilt on next get_ast().
			if (doc.cached_tokens != null) {
				bool patch_ok = doc.cached_tokens.patch(new_content, old_content, s, e, new_text.len);
				if (!patch_ok) {
					mem::free(doc.cached_tokens);
					doc.cached_tokens = null;
				}
			}
		} else {
			// Incremental succeeded -- also patch token cache if available
			if (doc.cached_tokens != null) {
				bool patch_ok = doc.cached_tokens.patch(new_content, old_content, s, e, new_text.len);
				if (!patch_ok) {
					mem::free(doc.cached_tokens);
					doc.cached_tokens = null;
				}
			}
		}

		mem::free(old_content.ptr);
		doc.version = version;
		doc.content = new_content;
	}
}

/**
 * Rebase String slices in AstNode fields (name, type_text, extra_text,
 * annotation_text) from old_content to new_content after an incremental edit.
 *
 * Strings that pointed into the old source before the edit region just need
 * their pointer updated (same offset in new buffer). Strings after the edit
 * need offset adjustment by the byte delta.
 */
fn void rebase_string_slices(ParseResult* result, String old_content, String new_content,
		uint edit_start, uint edit_end, usz new_text_len) {
	int byte_delta = (int)new_text_len - (int)(edit_end - edit_start);

	for (uint i = 0; i < result.node_count; i++) {
		AstNode* n = &result.nodes[i];

		// Rebase each string field that's a slice into old source
		rebase_slice(&n.name, old_content, new_content, edit_start, byte_delta);
		rebase_slice(&n.type_text, old_content, new_content, edit_start, byte_delta);
		rebase_slice(&n.extra_text, old_content, new_content, edit_start, byte_delta);
		rebase_slice(&n.annotation_text, old_content, new_content, edit_start, byte_delta);
	}
}

/**
 * Rebase a single String slice from old source to new source.
 */
fn void rebase_slice(String* s, String old_content, String new_content,
		uint edit_start, int byte_delta) {
	if (s.len == 0) return;

	// Check if the string points into old_content
	if (s.ptr >= old_content.ptr && s.ptr < old_content.ptr + old_content.len) {
		usz offset_in_old = (usz)(s.ptr - old_content.ptr);

		if (offset_in_old < (usz)edit_start) {
			// Before the edit: same offset in new content
			*s = new_content[offset_in_old : s.len];
		} else if (offset_in_old >= (usz)edit_start) {
			// After (or in) the edit region: adjust by byte_delta
			usz new_offset = (usz)((int)offset_in_old + byte_delta);
			if (new_offset + s.len <= new_content.len) {
				*s = new_content[new_offset : s.len];
			} else {
				// String extends past end -- clear it
				*s = "";
			}
		}
	}
	// If it points into new_content already (re-parsed chunk), leave it alone
}

// ── Position / offset utilities ───────────────────────────────────

/**
 * Convert an LSP position (0-based line, 0-based character) to a byte
 * offset in the source string. Returns -1 if the position is past the end.
 *
 * This is the canonical implementation used by both incremental sync and
 * all LSP feature handlers (hover, completion, signature help, etc.).
 */
fn long position_to_byte_offset(String content, uint line, uint character) {
	uint current_line = 0;
	usz i = 0;

	// Skip to the target line
	while (i < content.len && current_line < line) {
		if (content[i] == '\n') {
			current_line++;
		}
		i++;
	}

	if (current_line < line) {
		return -1; // Line is past end of content
	}

	// Add character offset
	usz offset = i + (usz)character;
	if (offset > content.len) {
		return -1;
	}

	return (long)offset;
}

fn void DocumentStore.close(DocumentStore* self, String uri) {
	// Free document strings and cached AST/types/chunks before HashMap.remove() frees the entry
	if (try doc = self.docs.get_ref(uri)) {
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
		}
		if (doc.cached_types != null) {
			mem::free(doc.cached_types);
		}
		if (doc.cached_chunks != null) {
			mem::free(doc.cached_chunks);
		}
		if (doc.cached_tokens != null) {
			mem::free(doc.cached_tokens);
		}
		if (doc.cached_semantic != null) {
			mem::free(doc.cached_semantic);
		}
		mem::free(doc.uri.ptr);
		mem::free(doc.language_id.ptr);
		mem::free(doc.content.ptr);
	}
	// HashMap.remove() frees its internal key copy
	self.docs.remove(uri);
}

fn Document*? DocumentStore.get(DocumentStore* self, String uri) {
	return self.docs.get_ref(uri);
}

/**
 * Get a cached ParseResult for a document, parsing lazily on first access.
 * The returned pointer is owned by the Document and must NOT be freed by the caller.
 * Returns a fault if the document is not found.
 */
fn ParseResult*? DocumentStore.get_ast(DocumentStore* self, String uri) {
	Document* doc = self.docs.get_ref(uri)!;

	if (doc.cached_ast == null) {
		doc.cached_ast = mem::new(ParseResult);
		parser::parse(doc.content, doc.cached_ast);

		// Build chunk map for incremental parsing
		if (doc.cached_chunks == null) {
			doc.cached_chunks = mem::new(ChunkMap);
		}
		incremental::build_chunk_map(doc.cached_ast, doc.cached_chunks, doc.content);

		// Build token cache for optimized fallback
		if (doc.cached_tokens == null) {
			doc.cached_tokens = mem::new(TokenCache);
		}
		token_cache::build_cache(doc.cached_tokens, doc.content);
	}

	return doc.cached_ast;
}

/**
 * Get a cached TypeInfo for a document, resolving lazily on first access.
 * Requires get_ast() to have been called first (or calls it internally).
 * The returned pointer is owned by the Document and must NOT be freed by the caller.
 * Returns a fault if the document is not found.
 */
fn TypeInfo*? DocumentStore.get_types(DocumentStore* self, String uri) {
	Document* doc = self.docs.get_ref(uri)!;

	if (doc.cached_types == null) {
		// Ensure AST is available first
		if (doc.cached_ast == null) {
			doc.cached_ast = mem::new(ParseResult);
			parser::parse(doc.content, doc.cached_ast);
		}
		doc.cached_types = mem::new(TypeInfo);
		if (self.workspace != null) {
			types::set_workspace(self.workspace);
		}
		types::resolve_types(doc.cached_ast, doc.cached_types);
		types::clear_workspace();
	}

	return doc.cached_types;
}
