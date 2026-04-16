module kls::deps::kotlin_fallback;

import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import std::os::process;
import kls::deps::jar_index;
import kls::log;

faultdef KOTLIN_NOT_FOUND;

// ── System Kotlin stdlib fallback ─────────────────────────────────
// When no build system resolves any JARs (jar_count == 0), we try
// to detect a system Kotlin installation and index kotlin-stdlib.jar
// so that completions, diagnostics, and import suggestions still
// work for stdlib types (List, Map, String extensions, etc.).

/**
 * Detect the Kotlin home directory. Tries in order:
 *   1. KOTLIN_HOME environment variable
 *   2. Homebrew paths (macOS ARM + Intel)
 *   3. SDKMAN path (~/.sdkman/candidates/kotlin/current)
 *   4. Common Linux paths
 *   5. `which kotlinc` -> resolve symlinks -> derive home
 * Returns a heap-copied path, or empty string if not found.
 * Caller must free the returned string.
 */
fn String detect_kotlin_home() {
	// 1. Check KOTLIN_HOME environment variable
	@pool() {
		if (try kotlin_home = env::tget_var("KOTLIN_HOME")) {
			if (kotlin_home.len > 0 && has_stdlib_jar(kotlin_home)) {
				log::info("[kls] Kotlin detected from KOTLIN_HOME: %s", kotlin_home);
				return kotlin_home.copy(mem);
			}
		}
	};

	// 2. Homebrew paths (macOS)
	$if env::OS_TYPE == MACOS:
		@pool() {
			// ARM Homebrew
			if (try home = find_homebrew_kotlin("/opt/homebrew/Cellar/kotlin")) {
				log::info("[kls] Kotlin detected from Homebrew (ARM): %s", home);
				return home;
			}
			// Intel Homebrew
			if (try home = find_homebrew_kotlin("/usr/local/Cellar/kotlin")) {
				log::info("[kls] Kotlin detected from Homebrew (Intel): %s", home);
				return home;
			}
		};
	$endif

	// 3. SDKMAN
	@pool() {
		if (try home_dir = env::tget_var("HOME")) {
			DString sdkman_path;
			sdkman_path.tinit();
			sdkman_path.appendf("%s/.sdkman/candidates/kotlin/current", home_dir);
			String sdkman = sdkman_path.str_view();
			if (has_stdlib_jar(sdkman)) {
				log::info("[kls] Kotlin detected from SDKMAN: %s", sdkman);
				return sdkman.copy(mem);
			}
		}
	};

	// 4. Common Linux paths
	const String[*] LINUX_PATHS = {
		"/usr/share/kotlin",
		"/usr/local/share/kotlin",
		"/usr/lib/kotlin",
	};

	@pool() {
		foreach (p : LINUX_PATHS) {
			if (has_stdlib_jar(p)) {
				log::info("[kls] Kotlin detected at: %s", p);
				return p.copy(mem);
			}
		}
	};

	// 5. Try `which kotlinc` and resolve to find the home
	@pool() {
		char[1024] buf;
		if (try out = process::run_capture_stdout(&buf,
				{ "which", "kotlinc" },
				SpawnOptions.INHERIT_ENV)) {
			// Trim trailing newline
			String kotlinc_path = out;
			while (kotlinc_path.len > 0 && (kotlinc_path[kotlinc_path.len - 1] == '\n' || kotlinc_path[kotlinc_path.len - 1] == '\r')) {
				kotlinc_path = kotlinc_path[:kotlinc_path.len - 1];
			}
			if (kotlinc_path.len > 0) {
				// kotlinc is typically at <kotlin_home>/bin/kotlinc
				// Try stripping /bin/kotlinc from the end
				if (try home = strip_bin_suffix(kotlinc_path)) {
					if (has_stdlib_jar(home)) {
						log::info("[kls] Kotlin detected from `which kotlinc`: %s", home);
						return home.copy(mem);
					}
				}

				// Also try resolving symlinks: readlink -f kotlinc_path
				char[1024] link_buf;
				if (try resolved = process::run_capture_stdout(&link_buf,
						{ "readlink", "-f", kotlinc_path },
						SpawnOptions.INHERIT_ENV)) {
					String resolved_path = resolved;
					while (resolved_path.len > 0 && (resolved_path[resolved_path.len - 1] == '\n' || resolved_path[resolved_path.len - 1] == '\r')) {
						resolved_path = resolved_path[:resolved_path.len - 1];
					}
					if (try home = strip_bin_suffix(resolved_path)) {
						if (has_stdlib_jar(home)) {
							log::info("[kls] Kotlin detected from resolved kotlinc: %s", home);
							return home.copy(mem);
						}
					}
				}
			}
		}
	};

	log::info("[kls] No system Kotlin detected (set KOTLIN_HOME to enable stdlib fallback)");
	return "";
}

// ── Index system Kotlin stdlib ────────────────────────────────────

/**
 * Detect a system Kotlin installation and index kotlin-stdlib.jar
 * into the dependency index. This is the main entry point called
 * from server.c3 when no build system resolved any JARs.
 */
fn void index_system_kotlin(DependencyIndex* dep_index) {
	String kotlin_home = detect_kotlin_home();
	if (kotlin_home.len == 0) return;
	defer mem::free(kotlin_home.ptr);

	usz total_before = dep_index.symbols.len();

	// Index kotlin-stdlib.jar using the existing JAR indexer
	@pool() {
		DString stdlib_path;
		stdlib_path.tinit();
		stdlib_path.appendf("%s/lib/kotlin-stdlib.jar", kotlin_home);

		String path_str = stdlib_path.str_view();
		if (file::is_file(path_str)) {
			dep_index.index_jar(path_str);
		} else {
			log::warn("[kls]   kotlin-stdlib.jar not found at: %s", path_str);
		}
	};

	usz total_after = dep_index.symbols.len();
	log::info("[kls] System Kotlin fallback: %d symbols from kotlin-stdlib.jar", (int)(total_after - total_before));
}

// ── Helpers ───────────────────────────────────────────────────────

/**
 * Check whether <kotlin_home>/lib/kotlin-stdlib.jar exists.
 */
fn bool has_stdlib_jar(String kotlin_home) {
	DString ds;
	ds.tinit();
	ds.appendf("%s/lib/kotlin-stdlib.jar", kotlin_home);
	return file::is_file(ds.str_view());
}

/**
 * Strip /bin/kotlinc (or /bin/kotlinc.bat) from the end of a path
 * to derive the Kotlin home directory.
 * Returns the home path (a slice of the input), or fault if not matching.
 */
fn String? strip_bin_suffix(String path) {
	if (path.ends_with("/bin/kotlinc")) {
		return path[:path.len - "/bin/kotlinc".len];
	}
	if (path.ends_with("/bin/kotlinc.bat")) {
		return path[:path.len - "/bin/kotlinc.bat".len];
	}
	return KOTLIN_NOT_FOUND~;
}

/**
 * Find a Kotlin installation under a Homebrew Cellar prefix.
 * Homebrew installs to <cellar>/kotlin/<version>/libexec/.
 * We look for any version directory that has lib/kotlin-stdlib.jar.
 * Returns a heap-copied path or fault if not found.
 */
fn String? find_homebrew_kotlin(String cellar_prefix) {
	if (!path::is_dir(path::temp(cellar_prefix)!!)) return KOTLIN_NOT_FOUND~;

	PathList versions;
	if (try list = path::ls(tmem, path::temp(cellar_prefix)!!)) {
		versions = list;
	} else {
		return KOTLIN_NOT_FOUND~;
	}

	// Iterate version dirs, pick the first with a valid stdlib
	foreach (entry : versions) {
		String ver_name = entry.basename();
		if (ver_name.len == 0 || ver_name[0] == '.') continue;

		DString libexec;
		libexec.tinit();
		libexec.appendf("%s/%s/libexec", cellar_prefix, ver_name);

		if (has_stdlib_jar(libexec.str_view())) {
			return libexec.str_view().copy(mem);
		}
	}

	return KOTLIN_NOT_FOUND~;
}
