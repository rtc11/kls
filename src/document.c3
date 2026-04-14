module kls::document;

import std::collections;
import kls::kotlin::ast;
import kls::kotlin::parser;

struct Document {
	String uri;
	String language_id;
	int version;
	String content;
	ParseResult* cached_ast;  // Lazily populated, heap-allocated
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
	};
	// HashMap copies keys internally (COPY_KEYS), so pass uri directly
	self.docs.set(uri, doc);
}

fn void DocumentStore.update(DocumentStore* self, String uri, int version, String content) {
	if (try doc = self.docs.get_ref(uri)) {
		// Invalidate cached AST before replacing content
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
			doc.cached_ast = null;
		}
		// Free old content before replacing
		mem::free(doc.content.ptr);
		doc.version = version;
		doc.content = content.copy(mem);
	}
}

fn void DocumentStore.close(DocumentStore* self, String uri) {
	// Free document strings and cached AST before HashMap.remove() frees the entry
	if (try doc = self.docs.get_ref(uri)) {
		if (doc.cached_ast != null) {
			doc.cached_ast.free_errors();
			mem::free(doc.cached_ast);
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
