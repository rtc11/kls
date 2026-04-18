module kls::deps::jdk_index;

import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import std::os::process;
import kls::log;
import std::compression::zip;
import kls::deps::classfile;
import kls::deps::jar_index;

// ── Key JDK modules to index ──────────────────────────────────────
// We index classes, methods, and fields from a curated set of JDK
// modules that are most relevant for Kotlin/JVM development.
// This enables go-to-definition on JDK members like System.nanoTime().

const String[*] JDK_MODULES = {
	"java.base.jmod",        // java.lang, java.util, java.io, java.nio, java.math, java.time, java.net, java.security, java.text, java.util.concurrent, etc.
	"java.sql.jmod",         // java.sql
	"java.logging.jmod",     // java.util.logging
	"java.net.http.jmod",    // java.net.http (HttpClient etc.)
	"java.xml.jmod",         // javax.xml, org.xml, org.w3c.dom
};

// ── Detect JAVA_HOME ──────────────────────────────────────────────

/**
 * Detect the JDK home directory. Tries in order:
 *   1. JAVA_HOME environment variable
 *   2. macOS: /usr/libexec/java_home output
 *   3. Common Linux/macOS paths
 * Returns a heap-copied path, or empty string if not found.
 * Caller must free the returned string.
 */
fn String detect_java_home() {
	// 1. Check JAVA_HOME environment variable
	@pool() {
		if (try java_home = env::tget_var("JAVA_HOME")) {
			if (java_home.len > 0) {
				// Verify the directory exists and has jmods/
				DString jmods_path;
				jmods_path.tinit();
				jmods_path.appendf("%s/jmods", java_home);
				if (path::is_dir(path::temp(jmods_path.str_view())!!)) {
				log::info("[kls] JDK detected from JAVA_HOME: %s", java_home);
					return java_home.copy(mem);
				}
			}
		}
	};

	// 2. macOS: try /usr/libexec/java_home
	$if env::OS_TYPE == MACOS:
		@pool() {
			char[1024] buf;
			if (try out = process::run_capture_stdout(&buf,
					{ "/usr/libexec/java_home" },
					SpawnOptions.INHERIT_ENV)) {
				// Trim trailing newline
				String java_home = out;
				while (java_home.len > 0 && (java_home[java_home.len - 1] == '\n' || java_home[java_home.len - 1] == '\r')) {
					java_home = java_home[:java_home.len - 1];
				}
				if (java_home.len > 0) {
					DString jmods_path;
					jmods_path.tinit();
					jmods_path.appendf("%s/jmods", java_home);
					if (path::is_dir(path::temp(jmods_path.str_view())!!)) {
						log::info("[kls] JDK detected from /usr/libexec/java_home: %s", java_home);
						return java_home.copy(mem);
					}
				}
			}
		};
	$endif

	// 3. Try common paths
	const String[*] COMMON_PATHS = {
		"/usr/lib/jvm/default-java",
		"/usr/lib/jvm/java-21",
		"/usr/lib/jvm/java-21-openjdk",
		"/usr/lib/jvm/java-17",
		"/usr/lib/jvm/java-17-openjdk",
		"/usr/lib/jvm/java-11",
		"/usr/lib/jvm/java-11-openjdk",
	};

	@pool() {
		foreach (p : COMMON_PATHS) {
			DString jmods_path;
			jmods_path.tinit();
			jmods_path.appendf("%s/jmods", p);
			if (try pp = path::temp(jmods_path.str_view())) {
				if (path::is_dir(pp)) {
					log::info("[kls] JDK detected at: %s", p);
					return p.copy(mem);
				}
			}
		}
	};

	log::info("[kls] No JDK detected (set JAVA_HOME to enable JDK class indexing)");
	return "";
}

// ── Index JDK jmod files ──────────────────────────────────────────

/**
 * Detect the JDK and index class-level symbols from key jmod files
 * into the dependency index. Only indexes public classes/interfaces/
 * enums/annotations (not methods or fields) to keep the symbol count
 * manageable.
 */
fn void index_jdk(DependencyIndex* dep_index) {
	String java_home = detect_java_home();
	if (java_home.len == 0) return;
	defer mem::free(java_home.ptr);

	usz total_before = dep_index.symbols.len();

	foreach (mod_name : JDK_MODULES) {
		@pool() {
			DString jmod_path;
			jmod_path.tinit();
			jmod_path.appendf("%s/jmods/%s", java_home, mod_name);

			String path_str = jmod_path.str_view();
			if (file::is_file(path_str)) {
				// Intern jmod_path: one heap copy shared by all symbols from this jmod
				String interned_path = path_str.copy(mem);
				index_jmod(dep_index, interned_path);
			} else {
				log::debug("[kls]   JDK module not found: %s", mod_name);
			}
		};
	}

	usz total_after = dep_index.symbols.len();
	log::info("[kls] JDK index: %d symbols from jmod files", (int)(total_after - total_before));
}

// ── JMOD header stripping ─────────────────────────────────────────

const char[4] JMOD_MAGIC = { 'J', 'M', 0x01, 0x00 };
const usz JMOD_HEADER_SIZE = 4;

/**
 * Strip the 4-byte JMOD magic header from a .jmod file.
 * Writes the remaining bytes (pure ZIP content) to a temp file
 * and returns the temp file path (heap-allocated).
 * Returns empty string on failure. Caller must delete the temp
 * file and free the returned string.
 */
fn String strip_jmod_header(String jmod_path) {
	// Build temp file path first — check if already cached
	DString tmp;
	tmp.tinit();
	if (try tmpdir = env::tget_var("TMPDIR")) {
		String t = tmpdir;
		if (t.len > 0 && t[t.len - 1] == '/') {
			t = t[:t.len - 1];
		}
		tmp.appendf("%s/kls-jmod-%x.zip", t, jmod_path_hash(jmod_path));
	} else {
		tmp.appendf("/tmp/kls-jmod-%x.zip", jmod_path_hash(jmod_path));
	}

	String tmp_path = tmp.str_view();

	// If temp file already exists (from previous session), reuse it
	if (file::is_file(tmp_path)) {
		log::debug("[kls]   Reusing cached jmod strip: %s", tmp_path);
		return tmp_path.copy(mem);
	}

	// Read the entire jmod file
	char[] data;
	if (try d = file::load(tmem, jmod_path)) {
		data = d;
	} else {
		return "";
	}

	// Verify JMOD magic and ensure file is large enough
	if (data.len <= JMOD_HEADER_SIZE) return "";
	if (data[0] != JMOD_MAGIC[0] || data[1] != JMOD_MAGIC[1] ||
		data[2] != JMOD_MAGIC[2] || data[3] != JMOD_MAGIC[3]) {
		return "";
	}

	// Write ZIP portion (skip first 4 bytes)
	File f;
	if (try opened = file::open(tmp_path, "wb")) {
		f = opened;
	} else {
		return "";
	}

	if (catch excuse = f.write(data[JMOD_HEADER_SIZE..])) {
		f.close()!!;
		return "";
	}
	f.close()!!;

	return tmp_path.copy(mem);
}

/**
 * Simple string hash for creating unique temp file names.
 */
fn uint jmod_path_hash(String s) {
	uint h = 5381;
	for (usz i = 0; i < s.len; i++) {
		h = ((h << 5) + h) + (uint)s[i];
	}
	return h;
}

/**
 * Index a single .jmod file. Opens it as a ZIP archive, iterates
 * entries under classes/, parses .class files, and adds class-level
 * symbols only (no methods/fields).
 */
fn void index_jmod(DependencyIndex* idx, String jmod_path) {
	// JMOD files have a 4-byte magic header (JM\x01\x00) before the ZIP
	// content. The internal ZIP offsets are relative to byte 4, so we
	// must strip the header before the ZIP library can read them correctly.
	// Strategy: read the file, skip 4 bytes, write to temp, open as ZIP.
	String zip_path = strip_jmod_header(jmod_path);
	if (zip_path.len == 0) {
		log::warn("[kls]   Skipping jmod (strip header failed): %s", jmod_path);
		return;
	}
	defer {
		// Keep temp file for cache — only free the path string
		mem::free(zip_path.ptr);
	}

	ZipArchive archive;
	if (try a = zip::open(tmem, zip_path, "r")) {
		archive = a;
	} else {
		log::warn("[kls]   Skipping jmod (zip open failed): %s", jmod_path);
		return;
	}
	defer archive.close()!!;

	usz entry_count = archive.count();
	usz class_count = 0;

	for (usz i = 0; i < entry_count; i++) {
		ZipEntry entry;
		if (try e = archive.stat_at(i)) {
			entry = e;
		} else {
			continue;
		}

		// jmod files have entries under classes/ prefix
		if (entry.is_directory) continue;
		if (!entry.name.starts_with("classes/")) continue;
		if (!entry.name.ends_with(".class")) continue;
		if (entry.name.ends_with("module-info.class")) continue;
		if (entry.name.ends_with("package-info.class")) continue;

		// Skip inner classes (contain '$' in the class name part)
		if (has_dollar_in_class_name(entry.name)) continue;

		// Read the class file bytes
		char[] class_data;
		if (try d = archive.read_file_all(tmem, entry.name)) {
			class_data = d;
		} else {
			continue;
		}

		// Parse the class file
		ClassInfo info;
		if (catch excuse = classfile::parse_class(class_data, &info)) {
			continue;
		}

		// Add class symbol plus its public methods/fields
		add_jdk_class_symbol(idx, &info, jmod_path);
		class_count++;
	}

	log::debug("[kls]   Indexed jmod: %s (%d classes)", jmod_path, (int)class_count);
}

/**
 * Check if a .class entry name has a '$' in the class name part.
 * Handles both JAR-style (com/example/Outer$Inner.class) and
 * jmod-style (classes/com/example/Outer$Inner.class) paths.
 */
fn bool has_dollar_in_class_name(String name) {
	usz start = 0;
	for (usz i = 0; i < name.len; i++) {
		if (name[i] == '/') start = i + 1;
	}
	for (usz i = start; i < name.len; i++) {
		if (name[i] == '$') return true;
	}
	return false;
}

/**
 * Add symbols from a JDK class file: the class itself plus its public
 * methods and fields. This allows go-to-definition on JDK members
 * like System.nanoTime(), Thread.sleep(), Files.readAllBytes(), etc.
 */
fn void add_jdk_class_symbol(DependencyIndex* idx, ClassInfo* info, String jmod_path) {
	if (idx.symbols.len() >= jar_index::MAX_DEP_SYMBOLS) return;

	// Only index public classes
	if ((info.access_flags & classfile::ACC_PUBLIC) == 0) return;

	String pkg = classfile::jvm_name_to_package(info.class_name);
	String simple_name = classfile::jvm_name_to_simple(info.class_name);
	if (simple_name.len == 0) return;

	// Determine kind
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

	// Collect structured supertypes
	String[jar_index::MAX_DEP_SUPERTYPES] class_supertypes;
	usz class_supertype_count = 0;

	if (info.super_name.len > 0 && info.super_name != "java/lang/Object" && info.super_name != "java/lang/Enum") {
		String super_simple = classfile::jvm_name_to_simple(info.super_name);
		if (super_simple.len > 0 && class_supertype_count < jar_index::MAX_DEP_SUPERTYPES) {
			class_supertypes[class_supertype_count] = super_simple;
			class_supertype_count++;
		}
	}

	for (usz ii = 0; ii < info.interface_count && class_supertype_count < jar_index::MAX_DEP_SUPERTYPES; ii++) {
		String iface_simple = classfile::jvm_name_to_simple(info.interfaces[ii]);
		if (iface_simple.len > 0) {
			class_supertypes[class_supertype_count] = iface_simple;
			class_supertype_count++;
		}
	}

	jar_index::add_dep_symbol(idx, simple_name, sig.str_view(), pkg, simple_name, jmod_path, class_kind,
		&class_supertypes, class_supertype_count, jar_path_interned: true);

	// Add public methods as symbols
	for (usz i = 0; i < info.method_count; i++) {
		if (idx.symbols.len() >= jar_index::MAX_DEP_SYMBOLS) return;
		ClassMember* m = &info.methods[i];

		// Only index public methods
		if ((m.access_flags & classfile::ACC_PUBLIC) == 0) continue;

		// Skip constructors and class initializers
		if (m.name == "<init>" || m.name == "<clinit>") continue;

		DString msig;
		msig.tinit();

		bool is_static = (m.access_flags & classfile::ACC_STATIC) != 0;

		msig.appendf("fun ");
		if (!is_static && simple_name.len > 0) {
			msig.appendf("%s.", simple_name);
		}
		msig.appendf("%s", m.name);
		classfile::method_descriptor_to_kotlin(m.descriptor, &msig);

		jar_index::add_dep_symbol(idx, m.name, msig.str_view(), pkg, simple_name, jmod_path, DEP_METHOD,
			null, 0, jar_path_interned: true);
	}

	// Add public fields as symbols
	for (usz i = 0; i < info.field_count; i++) {
		if (idx.symbols.len() >= jar_index::MAX_DEP_SYMBOLS) return;
		ClassMember* f = &info.fields[i];

		// Only index public fields
		if ((f.access_flags & classfile::ACC_PUBLIC) == 0) continue;

		DString fsig;
		fsig.tinit();

		bool is_final = (f.access_flags & classfile::ACC_FINAL) != 0;
		fsig.appendf("%s %s: ", is_final ? "val" : "var", f.name);
		classfile::descriptor_to_kotlin_type(f.descriptor, &fsig);

		jar_index::add_dep_symbol(idx, f.name, fsig.str_view(), pkg, simple_name, jmod_path, DEP_FIELD,
			null, 0, jar_path_interned: true);
	}
}
