module kls::deps::jar_index;

import std::io;
import std::collections;
import std::compression::zip;
import kls::deps::classfile;
import kls::deps::classpath;

// ── Dependency symbol kinds ────────────────────────────────────────

enum DepSymbolKind : int {
	DEP_CLASS,
	DEP_INTERFACE,
	DEP_ENUM,
	DEP_ANNOTATION,
	DEP_OBJECT,       // Kotlin singleton (Kt suffix heuristic)
	DEP_METHOD,
	DEP_FIELD,
}

// ── Dependency symbol ──────────────────────────────────────────────

struct DepSymbol {
	String name;           // heap-copied simple name (e.g., "listOf", "String")
	String signature;      // heap-copied Kotlin-style signature
	String package_name;   // heap-copied package (e.g., "kotlin.collections")
	String class_name;     // heap-copied declaring class simple name
	String jar_path;       // heap-copied path to the JAR containing this symbol
	DepSymbolKind kind;
}

// ── Dependency index ───────────────────────────────────────────────

const usz MAX_DEP_SYMBOLS = 16384;

struct DependencyIndex {
	List{DepSymbol} symbols;
	HashMap{String, List{usz}} name_index;  // name -> symbol indices
	bool initialized;
}

fn void DependencyIndex.init(DependencyIndex* self) {
	self.symbols.init(mem);
	self.name_index.init(mem);
	self.initialized = true;
}

fn void DependencyIndex.free(DependencyIndex* self) {
	for (usz i = 0; i < self.symbols.len(); i++) {
		DepSymbol* sym = &self.symbols[i];
		if (sym.name.len > 0) mem::free(sym.name.ptr);
		if (sym.signature.len > 0) mem::free(sym.signature.ptr);
		if (sym.package_name.len > 0) mem::free(sym.package_name.ptr);
		if (sym.class_name.len > 0) mem::free(sym.class_name.ptr);
		if (sym.jar_path.len > 0) mem::free(sym.jar_path.ptr);
	}
	self.symbols.free();

	// Free name_index lists
	@pool() {
		foreach (&list : self.name_index.tvalues()) {
			list.free();
		}
	};
	self.name_index.free();
	self.initialized = false;
}

// ── Index all JARs from a classpath ────────────────────────────────

/**
 * Index all JARs in the given classpath. Opens each JAR as a ZIP,
 * iterates .class entries, parses each, and adds public API symbols.
 */
fn void DependencyIndex.index_classpath(DependencyIndex* self, Classpath* cp) {
	io::eprintfn("[kls] Indexing %d JARs for dependency symbols...", (int)cp.jar_count);

	for (usz i = 0; i < cp.jar_count; i++) {
		@pool() {
			self.index_jar(cp.jars[i].path);
		};
	}

	io::eprintfn("[kls] Dependency index: %d symbols from %d JARs", (int)self.symbols.len(), (int)cp.jar_count);
}

/**
 * Index a single JAR file. Opens it as a ZIP archive, finds .class entries,
 * parses each with the classfile parser, and adds symbols.
 */
fn void DependencyIndex.index_jar(DependencyIndex* self, String jar_path) {
	ZipArchive archive;
	if (try a = zip::open(tmem, jar_path, "r")) {
		archive = a;
	} else {
		io::eprintfn("[kls]   Skipping JAR (open failed): %s", jar_path);
		return;
	}
	defer archive.close()!!;

	usz entry_count = archive.count();
	for (usz i = 0; i < entry_count; i++) {
		ZipEntry entry;
		if (try e = archive.stat_at(i)) {
			entry = e;
		} else {
			continue;
		}

		// Skip non-class files, directories, module-info, package-info
		if (entry.is_directory) continue;
		if (!entry.name.ends_with(".class")) continue;
		if (entry.name.ends_with("module-info.class")) continue;
		if (entry.name.ends_with("package-info.class")) continue;
		// Skip inner classes (contain '$') - we get their public API through the outer class
		if (has_dollar_in_class_name(entry.name)) continue;

		// Read the class file bytes
		char[] class_data;
		if (try d = archive.read_file_all(tmem, entry.name)) {
			class_data = d;
		} else {
			continue; // skip unreadable entries
		}

		// Parse the class file
		ClassInfo info;
		if (catch excuse = classfile::parse_class(class_data, &info)) {
			continue; // skip unparseable entries
		}

		// Add symbols from this class
		add_symbols_from_class(self, &info, jar_path);
	}
}

/**
 * Check if a .class file name has a '$' in the class name part.
 * This indicates an inner class. We skip these to avoid duplicating
 * symbols (outer class already has the public API).
 * Does NOT skip Kotlin file-facade classes like CollectionsKt.
 */
fn bool has_dollar_in_class_name(String name) {
	// The name looks like "com/example/Outer$Inner.class"
	// We want to check for '$' in the part after the last '/'
	usz start = 0;
	for (usz i = 0; i < name.len; i++) {
		if (name[i] == '/') start = i + 1;
	}
	// Check the filename part for '$'
	for (usz i = start; i < name.len; i++) {
		if (name[i] == '$') return true;
	}
	return false;
}

// ── Symbol extraction from a parsed class ──────────────────────────

fn void add_symbols_from_class(DependencyIndex* idx, ClassInfo* info, String jar_path) {
	if (idx.symbols.len() >= MAX_DEP_SYMBOLS) return;

	String pkg = classfile::jvm_name_to_package(info.class_name);
	String simple_name = classfile::jvm_name_to_simple(info.class_name);

	// Skip classes with empty or weird names
	if (simple_name.len == 0) return;

	// Add the class/interface itself as a symbol (if public)
	if ((info.access_flags & classfile::ACC_PUBLIC) != 0) {
		DepSymbolKind class_kind = DEP_CLASS;
		if ((info.access_flags & classfile::ACC_INTERFACE) != 0) {
			if ((info.access_flags & classfile::ACC_ANNOTATION) != 0) {
				class_kind = DEP_ANNOTATION;
			} else {
				class_kind = DEP_INTERFACE;
			}
		} else if ((info.access_flags & classfile::ACC_ENUM) != 0) {
			class_kind = DEP_ENUM;
		}

		// Build signature
		DString sig;
		sig.tinit();
		switch (class_kind) {
			case DEP_CLASS:      sig.appendf("class %s", simple_name);
			case DEP_INTERFACE:  sig.appendf("interface %s", simple_name);
			case DEP_ENUM:       sig.appendf("enum class %s", simple_name);
			case DEP_ANNOTATION: sig.appendf("annotation class %s", simple_name);
			default:             sig.appendf("class %s", simple_name);
		}

		// Add supertype if interesting
		if (info.super_name.len > 0 && info.super_name != "java/lang/Object" && info.super_name != "java/lang/Enum") {
			DString super_str;
			super_str.tinit();
			classfile::append_short_class_name(info.super_name, &super_str);
			sig.appendf(" : %s", super_str.str_view());
		}

		add_dep_symbol(idx, simple_name, sig.str_view(), pkg, simple_name, jar_path, class_kind);
	}

	// Add public methods as symbols
	for (usz i = 0; i < info.method_count; i++) {
		ClassMember* m = &info.methods[i];

		// Skip constructors and class initializers
		if (m.name == "<init>" || m.name == "<clinit>") continue;

		// Build method signature
		DString sig;
		sig.tinit();

		bool is_static = (m.access_flags & classfile::ACC_STATIC) != 0;

		sig.appendf("fun ");
		// For static methods on Kt classes, it's a top-level function
		if (!is_static && simple_name.len > 0) {
			sig.appendf("%s.", simple_name);
		}
		sig.appendf("%s", m.name);
		classfile::method_descriptor_to_kotlin(m.descriptor, &sig);

		add_dep_symbol(idx, m.name, sig.str_view(), pkg, simple_name, jar_path, DEP_METHOD);
	}

	// Add public fields as symbols
	for (usz i = 0; i < info.field_count; i++) {
		ClassMember* f = &info.fields[i];

		DString sig;
		sig.tinit();

		bool is_final = (f.access_flags & classfile::ACC_FINAL) != 0;
		sig.appendf("%s %s: ", is_final ? "val" : "var", f.name);
		classfile::descriptor_to_kotlin_type(f.descriptor, &sig);

		add_dep_symbol(idx, f.name, sig.str_view(), pkg, simple_name, jar_path, DEP_FIELD);
	}
}

fn void add_dep_symbol(DependencyIndex* idx, String name, String signature,
		String package_name, String class_name, String jar_path, DepSymbolKind kind) {
	if (idx.symbols.len() >= MAX_DEP_SYMBOLS) return;

	DepSymbol sym = {
		.name = name.copy(mem),
		.signature = signature.copy(mem),
		.package_name = package_name.len > 0 ? package_name.copy(mem) : "",
		.class_name = class_name.copy(mem),
		.jar_path = jar_path.copy(mem),
		.kind = kind,
	};

	usz sym_idx = idx.symbols.len();
	idx.symbols.push(sym);

	// Update name index
	if (try list_ref = idx.name_index.get_ref(name)) {
		list_ref.push(sym_idx);
	} else {
		List{usz} new_list;
		new_list.init(mem);
		new_list.push(sym_idx);
		idx.name_index.set(name, new_list);
	}
}

// ── Lookup functions ───────────────────────────────────────────────

/**
 * Look up all dependency symbols with the exact given name.
 * Writes matching pointers into out_buf and returns the count.
 */
fn usz DependencyIndex.lookup_by_name(DependencyIndex* self, String name, DepSymbol*[] out_buf) {
	if (out_buf.len == 0) return 0;

	if (try indices = self.name_index.get_ref(name)) {
		usz count = 0;
		for (usz i = 0; i < indices.len() && count < out_buf.len; i++) {
			usz idx = indices.get(i);
			if (idx < self.symbols.len()) {
				out_buf[count] = &self.symbols[idx];
				count++;
			}
		}
		return count;
	}
	return 0;
}

/**
 * Look up dependency symbols whose name starts with the given prefix.
 * Writes matching pointers into out_buf and returns the count.
 */
fn usz DependencyIndex.lookup_by_prefix(DependencyIndex* self, String prefix, DepSymbol*[] out_buf) {
	if (prefix.len == 0 || out_buf.len == 0) return 0;

	// Track seen names to deduplicate
	String[256] seen;
	usz seen_count = 0;
	usz count = 0;

	for (usz i = 0; i < self.symbols.len() && count < out_buf.len; i++) {
		DepSymbol* sym = &self.symbols[i];
		if (sym.name.len == 0) continue;
		if (!sym.name.starts_with(prefix)) continue;

		// Dedup by name
		bool already_seen = false;
		for (usz j = 0; j < seen_count; j++) {
			if (seen[j] == sym.name) {
				already_seen = true;
				break;
			}
		}
		if (already_seen) continue;

		if (seen_count < 256) {
			seen[seen_count] = sym.name;
			seen_count++;
		}

		out_buf[count] = sym;
		count++;
	}

	return count;
}

// ── Kind mapping helpers ───────────────────────────────────────────

/**
 * Map a DepSymbolKind to an LSP CompletionItemKind integer.
 */
fn int dep_kind_to_completion_kind(DepSymbolKind kind) {
	switch (kind) {
		case DEP_CLASS:      return 7;  // Class
		case DEP_INTERFACE:  return 8;  // Interface
		case DEP_ENUM:       return 13; // Enum
		case DEP_ANNOTATION: return 7;  // Class (no annotation kind in LSP)
		case DEP_OBJECT:     return 9;  // Module
		case DEP_METHOD:     return 2;  // Method
		case DEP_FIELD:      return 5;  // Field
	}
}
