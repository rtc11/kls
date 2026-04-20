module kls::deps::jar_index;

import std::io;
import std::collections;
import std::compression::zip;
import std::thread;
import kls::deps::classfile;
import kls::deps::classpath;
import kls::deps::kotlin_metadata;
import kls::log;
import kls::lsp::progress;

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

const usz MAX_DEP_SUPERTYPES = 8;

struct DepSymbol {
	String name;           // heap-copied simple name (e.g., "listOf", "String")
	String signature;      // heap-copied Kotlin-style signature
	String package_name;   // heap-copied package (e.g., "kotlin.collections")
	String class_name;     // heap-copied declaring class simple name
	String jar_path;       // path to JAR; interned (shared) when indexed via index_jar
	DepSymbolKind kind;
	bool jar_path_shared;  // true = jar_path is interned, don't free per-symbol
	String[MAX_DEP_SUPERTYPES] supertypes;  // heap-copied simple supertype names
	usz supertype_count;
}

// ── Dependency index ───────────────────────────────────────────────

const usz MAX_DEP_SYMBOLS = 524288;

struct DependencyIndex {
	List{DepSymbol} symbols;
	HashMap{String, List{usz}} name_index;   // name -> symbol indices
	HashMap{String, List{usz}} super_index;  // supertype name -> symbol indices that extend/implement it
	Mutex index_mutex;                        // guards symbols/name_index/super_index during parallel indexing
	bool initialized;
	bool limit_warned;                        // #15: only warn once about symbol limit
}

fn void DependencyIndex.init(DependencyIndex* self) {
	self.symbols.init(mem);
	self.name_index.init(mem);
	self.super_index.init(mem);
	if (catch excuse = self.index_mutex.init()) {
		log::err("[kls] Failed to init dep index mutex: %s", excuse);
		return;
	}
	self.initialized = true;
}

fn void DependencyIndex.free(DependencyIndex* self) {
	// Track interned (shared) jar_path pointers to free once
	void*[1024] freed_jar_paths;
	usz freed_count = 0;

	for (usz i = 0; i < self.symbols.len(); i++) {
		DepSymbol* sym = &self.symbols[i];
		if (sym.name.len > 0) mem::free(sym.name.ptr);
		if (sym.signature.len > 0) mem::free(sym.signature.ptr);
		if (sym.package_name.len > 0) mem::free(sym.package_name.ptr);
		if (sym.class_name.len > 0) mem::free(sym.class_name.ptr);

		if (sym.jar_path.len > 0) {
			if (sym.jar_path_shared) {
				// Interned: free once per unique pointer
				bool already_freed = false;
				for (usz j = 0; j < freed_count; j++) {
					if (freed_jar_paths[j] == sym.jar_path.ptr) {
						already_freed = true;
						break;
					}
				}
				if (!already_freed) {
					mem::free(sym.jar_path.ptr);
					if (freed_count < 1024) {
						freed_jar_paths[freed_count] = sym.jar_path.ptr;
						freed_count++;
					}
				}
			} else {
				mem::free(sym.jar_path.ptr);
			}
		}

		for (usz j = 0; j < sym.supertype_count; j++) {
			if (sym.supertypes[j].len > 0) mem::free(sym.supertypes[j].ptr);
		}
	}
	self.symbols.free();

	// Free name_index lists
	@pool() {
		foreach (&list : self.name_index.tvalues()) {
			list.free();
		}
	};
	self.name_index.free();

	// Free super_index lists
	@pool() {
		foreach (&list : self.super_index.tvalues()) {
			list.free();
		}
	};
	self.super_index.free();

	self.index_mutex.destroy();
	self.initialized = false;
}

// ── Index all JARs from a classpath ────────────────────────────────

const usz MAX_INDEX_THREADS = 4;

struct JarWorkerArgs {
	DependencyIndex* idx;
	Classpath* cp;
	usz start;
	usz end;
}

fn void jar_worker_body(JarWorkerArgs* args) {
	for (usz i = args.start; i < args.end; i++) {
		@pool() {
			args.idx.index_jar(args.cp.jars[i].path);
		};
	}
}

fn int jar_worker_fn(void* arg) {
	@pool_init(mem, 1024 * 256) {
		jar_worker_body((JarWorkerArgs*)arg);
	};
	return 0;
}

/**
 * Index all JARs in the given classpath. Uses parallel threads to
 * speed up JAR parsing — each thread indexes a partition of JARs,
 * symbols are added to the shared index under a mutex.
 *
 * If progress_token is non-empty, reports sub-progress between
 * pct_start and pct_end (e.g., 60→80) as threads complete.
 */
fn void DependencyIndex.index_classpath(DependencyIndex* self, Classpath* cp,
		String progress_token = "", int pct_start = 0, int pct_end = 100) {
	log::info("[kls] Indexing %d JARs for dependency symbols...", (int)cp.jar_count);

	if (cp.jar_count == 0) return;

	// For small JAR counts, index sequentially (thread overhead not worth it)
	if (cp.jar_count <= 4) {
		for (usz i = 0; i < cp.jar_count; i++) {
			@pool() {
				self.index_jar(cp.jars[i].path);
			};
			if (progress_token.len > 0 && cp.jar_count > 0) {
				int pct = pct_start + (int)((i + 1) * (usz)(pct_end - pct_start) / cp.jar_count);
				progress::report(progress_token, "Indexing dependencies...", pct);
			}
		}
		log::info("[kls] Dependency index: %d symbols from %d JARs", (int)self.symbols.len(), (int)cp.jar_count);
		return;
	}

	// Determine thread count (up to MAX_INDEX_THREADS, at least 1 JAR per thread)
	usz thread_count = MAX_INDEX_THREADS;
	if (thread_count > cp.jar_count) thread_count = cp.jar_count;

	// Partition JARs across threads
	JarWorkerArgs[MAX_INDEX_THREADS] args;
	Thread[MAX_INDEX_THREADS] threads;
	usz per_thread = cp.jar_count / thread_count;
	usz remainder = cp.jar_count % thread_count;
	usz offset = 0;

	for (usz t = 0; t < thread_count; t++) {
		usz count = per_thread + (usz)(t < remainder ? 1 : 0);
		args[t] = {
			.idx = self,
			.cp = cp,
			.start = offset,
			.end = offset + count,
		};
		offset += count;
	}

	// Launch worker threads (thread 0 runs on main thread)
	usz launched = 0;
	for (usz t = 1; t < thread_count; t++) {
		if (catch excuse = threads[t].create(&jar_worker_fn, &args[t])) {
			log::err("[kls] Failed to create worker thread %d: %s, running on main thread", (int)t, excuse);
			jar_worker_body(&args[t]);
		} else {
			launched++;
		}
	}

	// Main thread handles partition 0 (already has temp allocator)
	jar_worker_body(&args[0]);

	// Report progress as main thread partition completes
	if (progress_token.len > 0) {
		int pct = pct_start + (int)((usz)(pct_end - pct_start) / thread_count);
		progress::report(progress_token, "Indexing dependencies...", pct);
	}

	// Join worker threads
	for (usz t = 1; t < thread_count; t++) {
		(void)threads[t].join();
		if (progress_token.len > 0) {
			int pct = pct_start + (int)((t + 1) * (usz)(pct_end - pct_start) / thread_count);
			progress::report(progress_token, "Indexing dependencies...", pct);
		}
	}

	log::info("[kls] Dependency index: %d symbols from %d JARs (%d threads)",
		(int)self.symbols.len(), (int)cp.jar_count, (int)thread_count);
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
		log::warn("[kls]   Skipping JAR (open failed): %s", jar_path);
		return;
	}
	defer (void)archive.close();

	// Intern jar_path: one heap copy shared by all symbols from this JAR
	String interned_jar_path = jar_path.copy(mem);

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

		// Add symbols from this class (jar_path is interned, not re-copied)
		add_symbols_from_class(self, &info, interned_jar_path);
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

	// Try to parse Kotlin metadata for accurate type info
	KmClass* km = null;
	bool has_km = false;
	if (info.has_kotlin_metadata) {
		km = mem::new(KmClass);
		has_km = kotlin_metadata::parse_metadata(info, km);
		if (!has_km) {
			mem::free(km);
			km = null;
		}
	}
	defer { if (km != null) mem::free(km); }

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

		// Collect structured supertypes for the class symbol
		String[MAX_DEP_SUPERTYPES] class_supertypes;
		usz class_supertype_count = 0;

		// Add superclass (if not Object/Enum)
		if (info.super_name.len > 0 && info.super_name != "java/lang/Object" && info.super_name != "java/lang/Enum") {
			String super_simple = classfile::jvm_name_to_simple(info.super_name);
			if (super_simple.len > 0 && class_supertype_count < MAX_DEP_SUPERTYPES) {
				class_supertypes[class_supertype_count] = super_simple;
				class_supertype_count++;
			}
		}

		// Add interfaces
		for (usz ii = 0; ii < info.interface_count && class_supertype_count < MAX_DEP_SUPERTYPES; ii++) {
			String iface_simple = classfile::jvm_name_to_simple(info.interfaces[ii]);
			if (iface_simple.len > 0) {
				class_supertypes[class_supertype_count] = iface_simple;
				class_supertype_count++;
			}
		}

		add_dep_symbol(idx, simple_name, sig.str_view(), pkg, simple_name, jar_path, class_kind,
			&class_supertypes, class_supertype_count, jar_path_interned: true);
	}

	// Build metadata function lookup: name_id -> KmFunction index
	// Used to match JVM methods to their Kotlin metadata counterparts
	// (We iterate JVM methods as primary, metadata as enrichment)

	// Add public methods as symbols
	for (usz i = 0; i < info.method_count; i++) {
		ClassMember* m = &info.methods[i];

		// Skip constructors and class initializers
		if (m.name == "<init>" || m.name == "<clinit>") continue;

		// Try to find matching metadata function for this method
		KmFunction* km_fn = null;
		if (has_km) {
			km_fn = find_km_function(km, m.name, info.metadata_d2[..], info.metadata_d2_len);
		}

		// Build method signature
		DString sig;
		sig.tinit();

		bool is_static = (m.access_flags & classfile::ACC_STATIC) != 0;

		sig.appendf("fun ");

		// If metadata has receiver type, this is an extension function
		if (km_fn != null && km_fn.has_receiver_type) {
			String recv_name = kotlin_metadata::resolve_km_type_to_string(
				&km_fn.receiver_type, km, info.metadata_d2[..], info.metadata_d2_len);
			if (recv_name.len > 0) {
				sig.appendf("%s.", recv_name);
			}
		} else if (!is_static && simple_name.len > 0) {
			// For non-static methods on Kt classes, it's a member function
			sig.appendf("%s.", simple_name);
		}

		sig.appendf("%s", m.name);

		// Use metadata for return type if available
		if (km_fn != null && km_fn.has_return_type) {
			// Build param list from metadata
			sig.appendf("(");
			for (usz p = 0; p < km_fn.param_count; p++) {
				if (p > 0) sig.appendf(", ");
				String pname = kotlin_metadata::resolve_string(
					km_fn.params[p].name_id, info.metadata_d2[..], info.metadata_d2_len);
				String ptype = kotlin_metadata::resolve_km_type_to_string(
					&km_fn.params[p].type, km, info.metadata_d2[..], info.metadata_d2_len);
				if (pname.len > 0 && ptype.len > 0) {
					sig.appendf("%s: %s", pname, ptype);
				} else if (ptype.len > 0) {
					sig.appendf("%s", ptype);
				}
			}
			sig.appendf("): ");
			String ret_name = kotlin_metadata::resolve_km_type_to_string(
				&km_fn.return_type, km, info.metadata_d2[..], info.metadata_d2_len);
			sig.appendf("%s", ret_name.len > 0 ? ret_name : "Unit");
		} else {
			classfile::method_descriptor_to_kotlin(m.descriptor, &sig);
		}

		add_dep_symbol(idx, m.name, sig.str_view(), pkg, simple_name, jar_path, DEP_METHOD,
			null, 0, jar_path_interned: true);

		// For extension functions, also index under receiver type name
		if (km_fn != null && km_fn.has_receiver_type) {
			String recv_type_name = kotlin_metadata::resolve_type_name(
				km, km_fn.receiver_type.class_name_id, info.metadata_d2[..], info.metadata_d2_len);
			if (recv_type_name.len > 0 && recv_type_name != simple_name) {
				add_dep_symbol(idx, m.name, sig.str_view(), pkg, recv_type_name, jar_path, DEP_METHOD,
					null, 0, jar_path_interned: true);
			}
		} else if (is_static && simple_name.len > 2 && simple_name[simple_name.len - 2..] == "Kt") {
			// Fallback: JVM descriptor heuristic for Kt facade classes without metadata
			String receiver_name = classfile::descriptor_first_param_class(m.descriptor);
			if (receiver_name.len > 0 && receiver_name != simple_name) {
				add_dep_symbol(idx, m.name, sig.str_view(), pkg, receiver_name, jar_path, DEP_METHOD,
					null, 0, jar_path_interned: true);
			}
		}

		// Register Kotlin property name for getter/setter methods.
		if (m.name.len > 3 && m.name[..2] == "get" && m.name[3] >= 'A' && m.name[3] <= 'Z') {
			String prop_name = m.name[3..];
			DString prop_sig;
			prop_sig.tinit();
			prop_sig.appendf("val %s", prop_name);
			classfile::method_descriptor_to_kotlin(m.descriptor, &prop_sig);
			add_dep_symbol(idx, prop_name, prop_sig.str_view(), pkg, simple_name, jar_path, DEP_FIELD,
				null, 0, jar_path_interned: true);
		}
	}

	// Add public fields as symbols
	for (usz i = 0; i < info.field_count; i++) {
		ClassMember* f = &info.fields[i];

		DString sig;
		sig.tinit();

		// Try to find matching metadata property
		KmProperty* km_prop = null;
		if (has_km) {
			km_prop = find_km_property(km, f.name, info.metadata_d2[..], info.metadata_d2_len);
		}

		bool is_final = (f.access_flags & classfile::ACC_FINAL) != 0;

		if (km_prop != null && km_prop.has_return_type) {
			sig.appendf("%s %s: ", is_final ? "val" : "var", f.name);
			String type_name = kotlin_metadata::resolve_km_type_to_string(
				&km_prop.return_type, km, info.metadata_d2[..], info.metadata_d2_len);
			sig.appendf("%s", type_name.len > 0 ? type_name : "Any");
		} else {
			sig.appendf("%s %s: ", is_final ? "val" : "var", f.name);
			classfile::descriptor_to_kotlin_type(f.descriptor, &sig);
		}

		add_dep_symbol(idx, f.name, sig.str_view(), pkg, simple_name, jar_path, DEP_FIELD,
			null, 0, jar_path_interned: true);
	}
}

/**
 * Find a KmFunction in the metadata that matches a JVM method name.
 * Returns null if no match found.
 */
fn KmFunction* find_km_function(KmClass* km, String method_name, String[] d2, usz d2_len) {
	for (usz i = 0; i < km.function_count; i++) {
		String fn_name = kotlin_metadata::resolve_string(km.functions[i].name_id, d2, d2_len);
		if (fn_name == method_name) {
			return &km.functions[i];
		}
	}
	return null;
}

/**
 * Find a KmProperty in the metadata that matches a JVM field name.
 * Returns null if no match found.
 */
fn KmProperty* find_km_property(KmClass* km, String field_name, String[] d2, usz d2_len) {
	for (usz i = 0; i < km.property_count; i++) {
		String prop_name = kotlin_metadata::resolve_string(km.properties[i].name_id, d2, d2_len);
		if (prop_name == field_name) {
			return &km.properties[i];
		}
	}
	return null;
}

fn void add_dep_symbol(DependencyIndex* idx, String name, String signature,
		String package_name, String class_name, String jar_path, DepSymbolKind kind,
		String[MAX_DEP_SUPERTYPES]* supertypes, usz supertype_count,
		bool jar_path_interned = false) {

	// Pre-allocate symbol data outside the lock (heap alloc is thread-safe)
	DepSymbol sym = {
		.name = name.copy(mem),
		.signature = signature.copy(mem),
		.package_name = package_name.len > 0 ? package_name.copy(mem) : "",
		.class_name = class_name.copy(mem),
		.jar_path = jar_path_interned ? jar_path : jar_path.copy(mem),
		.kind = kind,
		.jar_path_shared = jar_path_interned,
		.supertype_count = supertype_count,
	};

	// Copy supertypes
	for (usz i = 0; i < supertype_count; i++) {
		if (supertypes != null) {
			sym.supertypes[i] = (*supertypes)[i].copy(mem);
		}
	}

	// Lock for data structure mutation
	idx.index_mutex.lock();
	defer idx.index_mutex.unlock();

	if (idx.symbols.len() >= MAX_DEP_SYMBOLS) {
		// #15: Warn once when the dependency symbol limit is reached
		if (!idx.limit_warned) {
			log::warn("[kls] Warning: dependency symbol limit reached (%d), some symbols may be missing", MAX_DEP_SYMBOLS);
			idx.limit_warned = true;
		}
		// Free pre-allocated strings
		if (sym.name.len > 0) mem::free(sym.name.ptr);
		if (sym.signature.len > 0) mem::free(sym.signature.ptr);
		if (sym.package_name.len > 0) mem::free(sym.package_name.ptr);
		if (sym.class_name.len > 0) mem::free(sym.class_name.ptr);
		if (!jar_path_interned && sym.jar_path.len > 0) mem::free(sym.jar_path.ptr);
		for (usz i = 0; i < supertype_count; i++) {
			if (sym.supertypes[i].len > 0) mem::free(sym.supertypes[i].ptr);
		}
		return;
	}

	usz sym_idx = idx.symbols.len();
	idx.symbols.push(sym);

	// Update name index
	if (try list_ref = idx.name_index.get_ref(name)) {
		list_ref.push(sym_idx);
	} else {
		List{usz} new_list;
		new_list.init(mem);
		new_list.push(sym_idx);
		idx.name_index.set(sym.name, new_list);
	}

	// Update super_index: map each supertype name -> this symbol
	for (usz i = 0; i < supertype_count; i++) {
		String st_name;
		if (supertypes != null) {
			st_name = (*supertypes)[i];
		} else {
			continue;
		}
		if (st_name.len == 0) continue;
		if (try list_ref = idx.super_index.get_ref(st_name)) {
			list_ref.push(sym_idx);
		} else {
			List{usz} new_list;
			new_list.init(mem);
			new_list.push(sym_idx);
			idx.super_index.set(sym.supertypes[i], new_list);
		}
	}
}

// ── Lookup functions ───────────────────────────────────────────────

/**
 * Copy all symbols from a source index that belong to the given JAR path.
 * Used for incremental re-indexing: unchanged JARs get their symbols copied
 * instead of re-parsed from disk.
 */
fn void DependencyIndex.copy_symbols_from_jar(DependencyIndex* self, DependencyIndex* source, String jar_path) {
	// Intern jar_path once for all copied symbols
	String interned = jar_path.copy(mem);

	for (usz i = 0; i < source.symbols.len(); i++) {
		DepSymbol* src = &source.symbols[i];
		if (src.jar_path != jar_path) continue;

		if (self.symbols.len() >= MAX_DEP_SYMBOLS) {
			if (!self.limit_warned) {
				log::warn("[kls] Warning: dependency symbol limit reached (%d), some symbols may be missing", MAX_DEP_SYMBOLS);
				self.limit_warned = true;
			}
			return;
		}

		DepSymbol sym = {
			.name = src.name.copy(mem),
			.signature = src.signature.copy(mem),
			.package_name = src.package_name.len > 0 ? src.package_name.copy(mem) : "",
			.class_name = src.class_name.copy(mem),
			.jar_path = interned,
			.kind = src.kind,
			.jar_path_shared = true,
			.supertype_count = src.supertype_count,
		};
		for (usz s = 0; s < src.supertype_count; s++) {
			sym.supertypes[s] = src.supertypes[s].copy(mem);
		}

		usz sym_idx = self.symbols.len();
		self.symbols.push(sym);

		// Update name index
		if (try list_ref = self.name_index.get_ref(src.name)) {
			list_ref.push(sym_idx);
		} else {
			List{usz} new_list;
			new_list.init(mem);
			new_list.push(sym_idx);
			self.name_index.set(sym.name, new_list);
		}

		// Update super_index
		for (usz s = 0; s < sym.supertype_count; s++) {
			if (sym.supertypes[s].len == 0) continue;
			if (try list_ref = self.super_index.get_ref(src.supertypes[s])) {
				list_ref.push(sym_idx);
			} else {
				List{usz} new_list;
				new_list.init(mem);
				new_list.push(sym_idx);
				self.super_index.set(sym.supertypes[s], new_list);
			}
		}
	}
}

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
 * Uses name_index keys for efficient iteration and natural dedup.
 * Writes matching pointers into out_buf and returns the count.
 */
fn usz DependencyIndex.lookup_by_prefix(DependencyIndex* self, String prefix, DepSymbol*[] out_buf) {
	if (prefix.len == 0 || out_buf.len == 0) return 0;

	usz count = 0;

	// Iterate name_index keys — each key is a unique name, so dedup is free
	@pool() {
		foreach (name : self.name_index.tkeys()) {
			if (count >= out_buf.len) break;
			if (!name.starts_with(prefix)) continue;

			// Get first symbol with this name
			if (try indices = self.name_index.get_ref(name)) {
				if (indices.len() > 0) {
					usz idx = indices.get(0);
					if (idx < self.symbols.len()) {
						out_buf[count] = &self.symbols[idx];
						count++;
					}
				}
			}
		}
	};

	return count;
}

/**
 * Look up dependency symbols that extend/implement a given supertype.
 * Writes matching pointers into out_buf and returns the count.
 * Only returns class/interface/enum/object symbols (not methods/fields).
 */
fn usz DependencyIndex.lookup_by_supertype(DependencyIndex* self, String supertype_name, DepSymbol*[] out_buf) {
	if (out_buf.len == 0 || supertype_name.len == 0) return 0;

	if (try indices = self.super_index.get_ref(supertype_name)) {
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
