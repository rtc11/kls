module kls::document;

import std::collections;

struct Document {
	String uri;
	String language_id;
	int version;
	String content;
}

struct DocumentStore {
	HashMap{String, Document} docs;
}

fn void DocumentStore.init(DocumentStore* self) {
	self.docs.init(mem);
}

fn void DocumentStore.free(DocumentStore* self) {
	// Free heap-allocated document strings before HashMap.free() clears entries.
	// HashMap.free() handles freeing its own key copies.
	@pool() {
		foreach (&doc : self.docs.tvalues()) {
			mem::free(doc.uri.ptr);
			mem::free(doc.language_id.ptr);
			mem::free(doc.content.ptr);
		}
	};
	self.docs.free();
}

fn void DocumentStore.open(DocumentStore* self, String uri, String language_id, int version, String content) {
	// Free old document strings if re-opening the same URI
	if (try old = self.docs.get_ref(uri)) {
		mem::free(old.uri.ptr);
		mem::free(old.language_id.ptr);
		mem::free(old.content.ptr);
	}
	Document doc = {
		.uri = uri.copy(mem),
		.language_id = language_id.copy(mem),
		.version = version,
		.content = content.copy(mem),
	};
	// HashMap copies keys internally (COPY_KEYS), so pass uri directly
	self.docs.set(uri, doc);
}

fn void DocumentStore.update(DocumentStore* self, String uri, int version, String content) {
	if (try doc = self.docs.get_ref(uri)) {
		// Free old content before replacing
		mem::free(doc.content.ptr);
		doc.version = version;
		doc.content = content.copy(mem);
	}
}

fn void DocumentStore.close(DocumentStore* self, String uri) {
	// Free document strings before HashMap.remove() frees the entry
	if (try doc = self.docs.get_ref(uri)) {
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
