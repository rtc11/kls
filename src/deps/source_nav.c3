module kls::deps::source_nav;

import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import std::collections;
import std::collections::object;
import std::compression::zip;
import kls::deps::jar_index;
import kls::deps::classpath;
import kls::kotlin::lexer;
import kls::kotlin::token;

// ── Source JAR navigation ──────────────────────────────────────────
//
// Given a DepSymbol from the dependency index, this module:
// 1. Derives the source JAR path (replace .jar with -sources.jar)
// 2. Opens the source JAR (ZIP archive)
// 3. Finds the source file for the symbol's declaring class
// 4. Extracts it to a temp cache directory
// 5. Scans the extracted source for the symbol's declaration position
// 6. Returns an LSP Location pointing to the extracted source file

faultdef SOURCE_NOT_FOUND, EXTRACT_FAILED;

// ── Temp cache directory ───────────────────────────────────────────

const String CACHE_DIR_NAME = "kls-sources";

/**
 * Get the temp cache directory for extracted source files.
 * Creates it if it doesn't exist. Returns a heap-copied path.
 * Pattern: $TMPDIR/kls-sources/ or /tmp/kls-sources/
 */
fn String get_cache_dir() {
	DString ds;
	ds.tinit();

	if (try tmpdir = env::tget_var("TMPDIR")) {
		// Remove trailing slash if present
		String t = tmpdir;
		if (t.len > 0 && t[t.len - 1] == '/') {
			t = t[..t.len - 2];
		}
		ds.appendf("%s/%s", t, CACHE_DIR_NAME);
	} else {
		ds.appendf("/tmp/%s", CACHE_DIR_NAME);
	}

	return ds.str_view();
}

// ── Source JAR path derivation ─────────────────────────────────────

/**
 * Derive the source JAR path from a binary JAR path.
 * Replaces ".jar" with "-sources.jar".
 * Returns empty string if the source JAR doesn't exist on disk.
 */
fn String derive_source_jar_path(String jar_path) {
	if (!jar_path.ends_with(".jar")) return "";

	DString ds;
	ds.tinit();
	String base = jar_path[..jar_path.len - 5]; // strip ".jar"
	ds.appendf("%s-sources.jar", base);

	String source_path = ds.str_view();
	if (!file::is_file(source_path)) return "";
	return source_path;
}

// ── Source file path inside JAR ────────────────────────────────────

/**
 * Build the expected source file path inside a source JAR.
 * Given package "kotlin.collections" and class "CollectionsKt",
 * tries "kotlin/collections/CollectionsKt.kt" and ".java" variants.
 *
 * Writes candidates into out_buf and returns count.
 */
fn usz build_source_candidates(String package_name, String class_name, String[] out_buf, usz max) {
	if (class_name.len == 0 || max == 0) return 0;

	// Convert package dots to slashes
	DString pkg_path;
	pkg_path.tinit();
	for (usz i = 0; i < package_name.len; i++) {
		if (package_name[i] == '.') {
			pkg_path.appendf("/");
		} else {
			pkg_path.appendf("%c", package_name[i]);
		}
	}

	// Strip "Kt" suffix for Kotlin file-facade classes
	// e.g. "CollectionsKt" -> also try "Collections.kt" and "_Collections.kt"
	String base_name = class_name;
	bool is_kt_facade = class_name.len > 2
		&& class_name[class_name.len - 2] == 'K'
		&& class_name[class_name.len - 1] == 't';

	usz count = 0;

	// Candidate 1: package/ClassName.kt
	if (count < max) {
		DString ds;
		ds.tinit();
		if (pkg_path.len() > 0) {
			ds.appendf("%s/%s.kt", pkg_path.str_view(), class_name);
		} else {
			ds.appendf("%s.kt", class_name);
		}
		out_buf[count] = ds.str_view();
		count++;
	}

	// Candidate 2: package/ClassName.java
	if (count < max) {
		DString ds;
		ds.tinit();
		if (pkg_path.len() > 0) {
			ds.appendf("%s/%s.java", pkg_path.str_view(), class_name);
		} else {
			ds.appendf("%s.java", class_name);
		}
		out_buf[count] = ds.str_view();
		count++;
	}

	// For Kt facade classes, also try without "Kt" suffix
	if (is_kt_facade) {
		String stripped = class_name[..class_name.len - 3]; // remove "Kt"

		// Candidate 3: package/StrippedName.kt
		if (count < max && stripped.len > 0) {
			DString ds;
			ds.tinit();
			if (pkg_path.len() > 0) {
				ds.appendf("%s/%s.kt", pkg_path.str_view(), stripped);
			} else {
				ds.appendf("%s.kt", stripped);
			}
			out_buf[count] = ds.str_view();
			count++;
		}

		// Candidate 4: package/_StrippedName.kt (common Kotlin stdlib pattern)
		if (count < max && stripped.len > 0) {
			DString ds;
			ds.tinit();
			if (pkg_path.len() > 0) {
				ds.appendf("%s/_%s.kt", pkg_path.str_view(), stripped);
			} else {
				ds.appendf("_%s.kt", stripped);
			}
			out_buf[count] = ds.str_view();
			count++;
		}
	}

	return count;
}

// ── Find source entry in JAR ───────────────────────────────────────

/**
 * Search a source JAR for a matching source file entry.
 * Tries exact candidates first, then falls back to suffix matching.
 * Returns the entry name on success, or a fault.
 */
fn String? find_source_entry_in_jar(String source_jar_path, String package_name, String class_name) {
	ZipArchive archive = zip::open(tmem, source_jar_path, "r")!;
	defer archive.close()!!;

	// Build candidate paths
	String[8] candidates;
	usz candidate_count = build_source_candidates(package_name, class_name, &candidates, 8);

	usz entry_count = archive.count();

	// Try exact match first
	for (usz c = 0; c < candidate_count; c++) {
		for (usz i = 0; i < entry_count; i++) {
			if (try entry = archive.stat_at(i)) {
				if (!entry.is_directory && entry.name == candidates[c]) {
					return entry.name.tcopy();
				}
			}
		}
	}

	// Fallback: suffix match (e.g., entry might have a different source root prefix)
	for (usz c = 0; c < candidate_count; c++) {
		for (usz i = 0; i < entry_count; i++) {
			if (try entry = archive.stat_at(i)) {
				if (!entry.is_directory && entry.name.ends_with(candidates[c])) {
					return entry.name.tcopy();
				}
			}
		}
	}

	return SOURCE_NOT_FOUND~;
}

// ── Extract source file to cache ───────────────────────────────────

/**
 * Extract a source file from a JAR to the cache directory.
 * Returns the filesystem path to the extracted file (heap-copied).
 *
 * Cache layout: $TMPDIR/kls-sources/<jar-hash>/<entry-path>
 * where jar-hash is a simple hash of the jar_path for uniqueness.
 */
fn String? extract_source_to_cache(String source_jar_path, String entry_name) {
	String cache_dir = get_cache_dir();

	// Create a unique subdirectory based on the JAR path hash
	uint jar_hash = simple_hash(source_jar_path);

	DString dest_dir;
	dest_dir.tinit();
	dest_dir.appendf("%s/%x", cache_dir, jar_hash);

	DString dest_path;
	dest_path.tinit();
	dest_path.appendf("%s/%s", dest_dir.str_view(), entry_name);

	String dest = dest_path.str_view();

	// Check if already extracted (cache hit)
	if (file::is_file(dest)) {
		return dest.copy(mem);
	}

	// Read the source file from the JAR
	ZipArchive archive = zip::open(tmem, source_jar_path, "r")!;
	defer archive.close()!!;

	char[] data = archive.read_file_all(tmem, entry_name)!;

	// Create all parent directories
	ensure_parent_dirs(dest);

	// Write the extracted file
	File f = file::open(dest, "wb")!;
	f.write(data)!;
	f.close()!;

	return dest.copy(mem);
}

/**
 * Simple string hash for creating unique directory names.
 */
fn uint simple_hash(String s) {
	uint h = 5381;
	for (usz i = 0; i < s.len; i++) {
		h = ((h << 5) + h) + (uint)s[i];
	}
	return h;
}

/**
 * Ensure all parent directories exist for a given file path.
 * Creates directories as needed.
 */
fn void ensure_parent_dirs(String file_path) {
	// Find the last '/' to get the parent directory
	usz last_slash = 0;
	bool found = false;
	for (usz i = 0; i < file_path.len; i++) {
		if (file_path[i] == '/') {
			last_slash = i;
			found = true;
		}
	}
	if (!found) return;
	// #10: Guard against usz underflow when last_slash == 0
	if (last_slash == 0) return;

	String dir_path = file_path[..last_slash - 1];
	if (dir_path.len == 0) return;

	// Create directories iteratively from root
	for (usz i = 1; i < dir_path.len; i++) {
		if (dir_path[i] == '/') {
			String partial = dir_path[..i - 1];
			if (try pp = path::temp(partial)) {
				if (!path::is_dir(pp)) {
					path::mkdir(pp, false)!!;
				}
			}
		}
	}
	// Create the final directory
	if (try dp = path::temp(dir_path)) {
		if (!path::is_dir(dp)) {
			path::mkdir(dp, false)!!;
		}
	}
}

// ── Scan source for symbol declaration ─────────────────────────────

/**
 * Scan a Kotlin/Java source file for a symbol declaration.
 * Returns the 0-based line and column of the symbol name.
 *
 * For functions: looks for "fun <name>"
 * For classes/interfaces: looks for "class <name>" / "interface <name>"
 * For fields/properties: looks for "val <name>" / "var <name>"
 *
 * Falls back to finding the first occurrence of the identifier.
 */
fn bool find_symbol_position(String content, String symbol_name, DepSymbolKind kind, uint* out_line, uint* out_col) {
	if (content.len == 0 || symbol_name.len == 0) return false;

	// Use the lexer to scan tokens
	Lexer lex = lexer::init(content);

	// Track the previous token to detect "fun X", "class X", etc.
	Token prev = { .kind = EOF };

	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		// #18: Also match soft keywords used as symbol names (e.g., class named "data")
		if ((tok.kind == IDENTIFIER || tok.kind.is_identifier_or_soft_keyword()) && tok.text == symbol_name) {
			// Check if preceded by the expected keyword
			bool is_match = false;

			switch (kind) {
				case DEP_METHOD:
					is_match = (prev.kind == KW_FUN);
				case DEP_CLASS:
				case DEP_ENUM:
					is_match = (prev.kind == KW_CLASS);
				case DEP_INTERFACE:
					is_match = (prev.kind == KW_INTERFACE);
				case DEP_ANNOTATION:
					is_match = (prev.kind == KW_CLASS); // annotation class
				case DEP_FIELD:
					is_match = (prev.kind == KW_VAL || prev.kind == KW_VAR);
				case DEP_OBJECT:
					is_match = (prev.kind == KW_OBJECT);
			}

			if (is_match) {
				*out_line = tok.line;
				*out_col = tok.col;
				return true;
			}
		}

		prev = tok;
	}

	// Fallback: find the first occurrence of the identifier anywhere
	Lexer lex2 = lexer::init(content);
	while (true) {
		Token tok = lex2.next();
		if (tok.kind == EOF) break;
		if ((tok.kind == IDENTIFIER || tok.kind.is_identifier_or_soft_keyword()) && tok.text == symbol_name) {
			*out_line = tok.line;
			*out_col = tok.col;
			return true;
		}
	}

	return false;
}

// ── Main entry point: resolve definition from dep symbol ───────────

/**
 * Try to navigate to the source definition of a dependency symbol.
 * Returns an LSP Location object pointing to the extracted source file,
 * or null if source navigation is not possible.
 */
fn Object* resolve_dep_definition(DepSymbol* sym) {
	if (sym == null) return null;

	// Derive source JAR path
	String source_jar = derive_source_jar_path(sym.jar_path);
	if (source_jar.len == 0) {
		return null; // No source JAR available
	}

	// Find the source entry in the JAR
	String entry_name;
	if (try e = find_source_entry_in_jar(source_jar, sym.package_name, sym.class_name)) {
		entry_name = e;
	} else {
		return null;
	}

	// Extract to cache
	String extracted_path;
	if (try p = extract_source_to_cache(source_jar, entry_name)) {
		extracted_path = p;
	} else {
		return null;
	}
	defer mem::free(extracted_path.ptr);

	// Read the extracted source
	char[] source_data;
	if (try d = file::load(tmem, extracted_path)) {
		source_data = d;
	} else {
		return null;
	}
	String source_content = (String)source_data;

	// Find the symbol position in the source
	uint sym_line = 0;
	uint sym_col = 0;
	if (!find_symbol_position(source_content, sym.name, sym.kind, &sym_line, &sym_col)) {
		// Even if we can't find the exact position, navigate to top of file
		sym_line = 0;
		sym_col = 0;
	}

	// Build the LSP Location
	DString uri_ds;
	uri_ds.tinit();
	uri_ds.appendf("file://%s", extracted_path);

	Object* start = object::new_obj(tmem);
	start.set("line", (int)sym_line);
	start.set("character", (int)sym_col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)sym_line);
	end_pos.set("character", (int)(sym_col + sym.name.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", uri_ds.str_view());
	location.set("range", range);

	return location;
}

// ── Lookup + resolve combo ─────────────────────────────────────────

/**
 * Try to find a definition for an identifier in the dependency index.
 * Looks up the symbol by name, prefers function matches in call context,
 * then tries source JAR navigation for the best match.
 *
 * Returns an LSP Location or null.
 */
fn Object* find_definition_in_deps(DependencyIndex* dep_index, String target_name, bool is_call) {
	if (dep_index == null || !dep_index.initialized) return null;

	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(target_name, &matches);
	if (count == 0) return null;

	// Pick best match: prefer function in call context
	DepSymbol* best = null;
	DepSymbol* func_match = null;
	DepSymbol* class_match = null;

	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = matches[i];
		if (func_match == null && sym.kind == DEP_METHOD) {
			func_match = sym;
		}
		if (class_match == null && (sym.kind == DEP_CLASS || sym.kind == DEP_INTERFACE || sym.kind == DEP_ENUM || sym.kind == DEP_ANNOTATION)) {
			class_match = sym;
		}
	}

	if (is_call && func_match != null) {
		best = func_match;
	} else if (!is_call && class_match != null) {
		best = class_match;
	} else {
		best = matches[0]; // fallback to first match
	}

	// Try source JAR navigation
	Object* result = resolve_dep_definition(best);
	if (result != null) return result;

	// If source navigation failed but we have multiple candidates, try others
	for (usz i = 0; i < count; i++) {
		if (matches[i] == best) continue;
		result = resolve_dep_definition(matches[i]);
		if (result != null) return result;
	}

	return null;
}
