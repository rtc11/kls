module kls::deps::jdk_index;

import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import std::os::process;
import std::compression::zip;
import kls::deps::classfile;
import kls::deps::jar_index;

// ── Key JDK modules to index ──────────────────────────────────────
// We index class-level symbols only (not methods/fields) from a
// curated set of JDK modules that are most relevant for Kotlin/JVM
// development.

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
					io::eprintfn("[kls] JDK detected from JAVA_HOME: %s", java_home);
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
						io::eprintfn("[kls] JDK detected from /usr/libexec/java_home: %s", java_home);
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
					io::eprintfn("[kls] JDK detected at: %s", p);
					return p.copy(mem);
				}
			}
		}
	};

	io::eprintfn("[kls] No JDK detected (set JAVA_HOME to enable JDK class indexing)");
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
				index_jmod(dep_index, path_str);
			} else {
				io::eprintfn("[kls]   JDK module not found: %s", mod_name);
			}
		};
	}

	usz total_after = dep_index.symbols.len();
	io::eprintfn("[kls] JDK index: %d class symbols from jmod files", (int)(total_after - total_before));
}

/**
 * Index a single .jmod file. Opens it as a ZIP archive, iterates
 * entries under classes/, parses .class files, and adds class-level
 * symbols only (no methods/fields).
 */
fn void index_jmod(DependencyIndex* idx, String jmod_path) {
	ZipArchive archive;
	if (try a = zip::open(tmem, jmod_path, "r")) {
		archive = a;
	} else {
		io::eprintfn("[kls]   Skipping jmod (open failed): %s", jmod_path);
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

		// Add class-level symbol only (skip methods/fields for JDK)
		add_jdk_class_symbol(idx, &info, jmod_path);
		class_count++;
	}

	io::eprintfn("[kls]   Indexed jmod: %s (%d classes)", jmod_path, (int)class_count);
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
 * Add a single class-level symbol from a JDK class file.
 * Only adds public classes/interfaces/enums/annotations.
 * Does NOT add methods or fields (to keep JDK symbol count manageable).
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
		&class_supertypes, class_supertype_count);
}
