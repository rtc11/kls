module kls::document;

import std::collections;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;

struct Document {
	String uri;
	String language_id;
	int version;
	String content;
	ParseResult* cached_ast;    // Lazily populated, heap-allocated
	TypeInfo* cached_types;     // Lazily populated, heap-allocated (parallel to cached_ast)
}

struct DocumentStore {
	HashMap{String, Document} docs;
}

fn void DocumentStore.init(DocumentStore* self) {
	self.docs.init(mem);
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
	};
	// HashMap copies keys internally (COPY_KEYS), so pass uri directly
	self.docs.set(uri, doc);
}

fn void DocumentStore.update(DocumentStore* self, String uri, int version, String content) {
	if (try doc = self.docs.get_ref(uri)) {
		// Invalidate cached AST and types before replacing content
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
			doc.cached_ast = null;
		}
		if (doc.cached_types != null) {
			mem::free(doc.cached_types);
			doc.cached_types = null;
		}
		// Free old content before replacing
		mem::free(doc.content.ptr);
		doc.version = version;
		doc.content = content.copy(mem);
	}
}

/**
 * Apply a single incremental change to a document.
 * The change replaces the byte range [start_offset, end_offset) with new_text.
 * Invalidates the cached AST.
 */
fn void DocumentStore.apply_change(DocumentStore* self, String uri, int version,
		uint start_offset, uint end_offset, String new_text) {
	if (try doc = self.docs.get_ref(uri)) {
		// Invalidate cached AST and types
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
			doc.cached_ast = null;
		}
		if (doc.cached_types != null) {
			mem::free(doc.cached_types);
			doc.cached_types = null;
		}

		String old = doc.content;

		// Clamp offsets to content bounds
		uint s = start_offset > (uint)old.len ? (uint)old.len : start_offset;
		uint e = end_offset > (uint)old.len ? (uint)old.len : end_offset;
		if (e < s) e = s;

		usz prefix_len = (usz)s;
		usz suffix_len = old.len - (usz)e;
		usz new_len = prefix_len + new_text.len + suffix_len;

		char* buf = mem::alloc_array(char, new_len);
		// Copy prefix
		if (prefix_len > 0) {
			mem::copy(buf, old.ptr, prefix_len);
		}
		// Copy replacement text
		if (new_text.len > 0) {
			mem::copy(&buf[prefix_len], new_text.ptr, new_text.len);
		}
		// Copy suffix
		if (suffix_len > 0) {
			mem::copy(&buf[prefix_len + new_text.len], &old.ptr[(usz)e], suffix_len);
		}

		mem::free(old.ptr);
		doc.version = version;
		doc.content = (String)buf[:new_len];
	}
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
	// Free document strings and cached AST/types before HashMap.remove() frees the entry
	if (try doc = self.docs.get_ref(uri)) {
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
		}
		if (doc.cached_types != null) {
			mem::free(doc.cached_types);
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
		types::resolve_types(doc.cached_ast, doc.cached_types);
	}

	return doc.cached_types;
}
