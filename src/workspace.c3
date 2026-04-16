module kls::workspace;

import std::io;
import std::io::file;
import std::io::path;
import std::collections;
import kls::kotlin::symbols;
import kls::kotlin::token;
import kls::kotlin::lexer;
import kls::kotlin::parser;
import kls::kotlin::ast;
import kls::deps::classpath;
import kls::deps::jar_index;

// ── Workspace symbol entry ─────────────────────────────────────────

struct WorkspaceSymbol {
	String name;           // heap-copied symbol name
	String uri;            // heap-copied file:// URI
	String package_name;   // heap-copied package (e.g. "com.example.app")
	String receiver;       // heap-copied receiver type text (extensions)
	SymbolKind kind;       // from kls::kotlin::symbols
	int lsp_kind;          // LSP SymbolKind integer
	uint line;             // 0-based line
	uint col;              // 0-based column
	uint name_len;         // length of name for range building
	String[symbols::MAX_SUPERTYPES] supertypes;  // heap-copied supertype names
	usz supertype_count;
}

// ── Cached member declaration ──────────────────────────────────────

const usz MAX_PARAMS = 16;

struct MemberDecl {
	String name;           // heap-copied member name
	String type_text;      // heap-copied type annotation (return type / property type)
	String uri;            // heap-copied file URI where the member is declared
	NodeKind node_kind;    // FUN_DECL, PROPERTY_DECL, CLASS_DECL, PARAM, etc.
	uint mod_flags;        // modifier flags (MOD_VAR, MOD_FINAL, etc.)
	uint line;             // 0-based line
	uint col;              // 0-based column
	uint name_len;         // length of name
	usz param_count;       // number of parameters (for functions)
	String[MAX_PARAMS] param_names;   // heap-copied parameter names
	String[MAX_PARAMS] param_types;   // heap-copied parameter type texts
}

// ── Workspace file entry ───────────────────────────────────────────

struct WorkspaceFile {
	String uri;            // heap-copied
	String package_name;   // heap-copied
	String module_name;    // heap-copied Gradle module name (e.g. ":core"), "" if single-project
	usz symbol_start;      // index into symbols list
	usz symbol_count;      // number of symbols from this file
}

// ── Workspace index ────────────────────────────────────────────────

struct WorkspaceIndex {
	String root_uri;                          // heap-copied workspace root URI
	String root_path;                         // heap-copied filesystem path
	List{WorkspaceSymbol} symbols;            // all symbols across workspace
	HashMap{String, WorkspaceFile} files;     // uri -> file metadata
	HashMap{String, List{usz}} name_index;    // name -> symbol indices
	HashMap{String, List{usz}} super_index;   // supertype name -> symbol indices that extend/implement it
	HashMap{String, List{MemberDecl}} member_cache;  // class name -> member declarations
	Classpath classpath;                      // resolved dependency JARs
	DependencyIndex dep_index;                // indexed symbols from JARs
}

fn void WorkspaceIndex.init(WorkspaceIndex* self) {
	self.root_uri = "";
	self.root_path = "";
	self.symbols.init(mem);
	self.files.init(mem);
	self.name_index.init(mem);
	self.super_index.init(mem);
	self.member_cache.init(mem);
	self.classpath.init();
	self.dep_index.init();
}

fn void WorkspaceIndex.free(WorkspaceIndex* self) {
	// Free heap-copied strings in symbols
	for (usz i = 0; i < self.symbols.len(); i++) {
		WorkspaceSymbol* sym = &self.symbols[i];
		if (sym.name.len > 0) mem::free(sym.name.ptr);
		if (sym.uri.len > 0) mem::free(sym.uri.ptr);
		if (sym.package_name.len > 0) mem::free(sym.package_name.ptr);
		if (sym.receiver.len > 0) mem::free(sym.receiver.ptr);
		for (usz j = 0; j < sym.supertype_count; j++) {
			if (sym.supertypes[j].len > 0) mem::free(sym.supertypes[j].ptr);
		}
	}
	self.symbols.free();

	// Free heap-copied strings in files
	@pool() {
		foreach (&entry : self.files.tvalues()) {
			if (entry.uri.len > 0) mem::free(entry.uri.ptr);
			if (entry.package_name.len > 0) mem::free(entry.package_name.ptr);
			if (entry.module_name.len > 0) mem::free(entry.module_name.ptr);
		}
	};
	self.files.free();

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

	// Free member_cache lists and their heap strings
	@pool() {
		foreach (&list : self.member_cache.tvalues()) {
			for (usz i = 0; i < list.len(); i++) {
				MemberDecl* m = &(*list)[i];
				free_member_decl(m);
			}
			list.free();
		}
	};
	self.member_cache.free();

	self.classpath.free();
	self.dep_index.free();

	if (self.root_uri.len > 0) mem::free(self.root_uri.ptr);
	if (self.root_path.len > 0) mem::free(self.root_path.ptr);
}

// ── Member cache helpers ───────────────────────────────────────────

/**
 * Free all heap-allocated strings inside a MemberDecl.
 */
fn void free_member_decl(MemberDecl* m) {
	if (m.name.len > 0) mem::free(m.name.ptr);
	if (m.type_text.len > 0) mem::free(m.type_text.ptr);
	if (m.uri.len > 0) mem::free(m.uri.ptr);
	for (usz i = 0; i < m.param_count; i++) {
		if (m.param_names[i].len > 0) mem::free(m.param_names[i].ptr);
		if (m.param_types[i].len > 0) mem::free(m.param_types[i].ptr);
	}
}

/**
 * Parse a file and cache member declarations for all class-like symbols found.
 * Called at the end of index_file() after symbols have been pushed.
 *
 * @param uri     The file URI (borrowed, will be heap-copied per member).
 * @param content The file content to parse.
 * @param syms    The scanned Symbol buffer from this file.
 * @param count   The number of symbols scanned.
 */
fn void WorkspaceIndex.cache_class_members(WorkspaceIndex* self, String uri, String content,
		Symbol* syms, usz count) {
	// Check if any class-like symbols exist in this file
	bool has_classes = false;
	for (usz i = 0; i < count; i++) {
		if (syms[i].kind == SymbolKind.CLASS || syms[i].kind == SymbolKind.INTERFACE ||
			syms[i].kind == SymbolKind.OBJECT) {
			has_classes = true;
			break;
		}
	}
	if (!has_classes) return;

	// Parse the file
	ParseResult* pr = mem::new(ParseResult);
	defer mem::free(pr);
	parser::parse(content, pr);
	if (pr.node_count == 0) return;

	// For each class-like symbol, find it in the AST and extract members
	for (usz s = 0; s < count; s++) {
		if (syms[s].kind != SymbolKind.CLASS && syms[s].kind != SymbolKind.INTERFACE &&
			syms[s].kind != SymbolKind.OBJECT) continue;

		String class_name = syms[s].name;

		// Find the class node in the AST
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if ((n.kind != CLASS_DECL && n.kind != INTERFACE_DECL && n.kind != OBJECT_DECL) ||
				n.name != class_name) continue;

			// Found the class — create member list
			List{MemberDecl} members;
			members.init(mem);

			// Iterate direct children for member declarations
			for (uint j = 0; j < pr.node_count; j++) {
				AstNode* child = &pr.nodes[j];
				if (child.parent != i) continue;
				if (child.name.len == 0) continue;

				MemberDecl m;
				bool valid = false;

				switch (child.kind) {
					case FUN_DECL:
						m = {
							.name = child.name.copy(mem),
							.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",
							.uri = uri.copy(mem),
							.node_kind = FUN_DECL,
							.mod_flags = child.mod_flags,
							.line = child.name_line,
							.col = child.name_col,
							.name_len = child.name_len,
							.param_count = 0,
						};
						// Collect parameters
						uint fun_idx = ast::node_index(pr, child);
						for (uint k = 0; k < pr.node_count && m.param_count < MAX_PARAMS; k++) {
							if (pr.nodes[k].parent != fun_idx) continue;
							if (pr.nodes[k].kind != PARAM) continue;
							usz pi = m.param_count;
							m.param_names[pi] = pr.nodes[k].name.len > 0 ? pr.nodes[k].name.copy(mem) : "";
							m.param_types[pi] = pr.nodes[k].type_text.len > 0 ? pr.nodes[k].type_text.copy(mem) : "";
							m.param_count++;
						}
						valid = true;
					case PROPERTY_DECL:
						m = {
							.name = child.name.copy(mem),
							.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",
							.uri = uri.copy(mem),
							.node_kind = PROPERTY_DECL,
							.mod_flags = child.mod_flags,
							.line = child.name_line,
							.col = child.name_col,
							.name_len = child.name_len,
							.param_count = 0,
						};
						valid = true;
					case CLASS_DECL:
					case INTERFACE_DECL:
					case OBJECT_DECL:
						m = {
							.name = child.name.copy(mem),
							.type_text = "",
							.uri = uri.copy(mem),
							.node_kind = child.kind,
							.mod_flags = child.mod_flags,
							.line = child.name_line,
							.col = child.name_col,
							.name_len = child.name_len,
							.param_count = 0,
						};
						valid = true;
					case PARAM:
						// Data class constructor params with val/var are properties
						if ((child.mod_flags & ast::MOD_VAR) != 0 || (child.mod_flags & ast::MOD_FINAL) != 0) {
							m = {
								.name = child.name.copy(mem),
								.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",
								.uri = uri.copy(mem),
								.node_kind = PARAM,
								.mod_flags = child.mod_flags,
								.line = child.name_line,
								.col = child.name_col,
								.name_len = child.name_len,
								.param_count = 0,
							};
							valid = true;
						}
					default:
				}

				if (valid) {
					members.push(m);
				}
			}

			// Check if there's already a cached entry for this class name
			// (can happen with duplicate class names across files)
			if (try existing = self.member_cache.get_ref(class_name)) {
				for (usz j = 0; j < existing.len(); j++) {
					free_member_decl(&(*existing)[j]);
				}
				existing.free();
			}
			self.member_cache.set(class_name, members);
			break; // Found the class node, done
		}
	}
}

/**
 * Look up cached members for a class by name.
 * Returns a pointer to the member list, or fault if not cached.
 */
fn List{MemberDecl}*? WorkspaceIndex.lookup_members(WorkspaceIndex* self, String class_name) {
	return self.member_cache.get_ref(class_name);
}

// ── Set workspace root ─────────────────────────────────────────────

fn void WorkspaceIndex.set_root(WorkspaceIndex* self, String uri) {
	if (self.root_uri.len > 0) mem::free(self.root_uri.ptr);
	if (self.root_path.len > 0) mem::free(self.root_path.ptr);

	self.root_uri = uri.copy(mem);
	self.root_path = uri_to_path(uri).copy(mem);
	log::info("[kls] Workspace root: %s", self.root_path);
}

// ── File indexing ──────────────────────────────────────────────────

/**
 * Index a single file: scan its content for declarations and package name,
 * add all symbols to the workspace index.
 */
fn void WorkspaceIndex.index_file(WorkspaceIndex* self, String uri, String content) {
	// Remove old symbols for this file if re-indexing
	self.remove_file(uri);

	// Determine which Gradle module this file belongs to
	String module_name = "";
	if (self.classpath.module_count > 0) {
		String file_path = uri_to_path(uri);
		GradleModule* mod = self.classpath.find_module_for_path(file_path);
		if (mod != null) {
			module_name = mod.name;
		}
	}

	// Scan package name
	String pkg = scan_package(content);
	String pkg_copy = "";
	if (pkg.len > 0) {
		pkg_copy = pkg.copy(mem);
	}

	// Scan declarations
	Symbol[256] buf;
	usz count = symbols::scan_declarations(content, &buf);

	usz start = self.symbols.len();

	for (usz i = 0; i < count; i++) {
		WorkspaceSymbol ws = {
			.name = buf[i].name.copy(mem),
			.uri = uri.copy(mem),
			.package_name = pkg_copy.len > 0 ? pkg_copy.copy(mem) : "",
			.receiver = buf[i].receiver.len > 0 ? buf[i].receiver.copy(mem) : "",
			.kind = buf[i].kind,
			.lsp_kind = symbol_kind_to_lsp(buf[i].kind),
			.line = buf[i].line,
			.col = buf[i].col,
			.name_len = buf[i].len,
			.supertype_count = buf[i].supertype_count,
		};

		// Copy supertypes
		for (usz j = 0; j < buf[i].supertype_count; j++) {
			ws.supertypes[j] = buf[i].supertypes[j].copy(mem);
		}

		self.symbols.push(ws);

		// Update name index
		usz sym_idx = start + i;
		if (try list_ref = self.name_index.get_ref(buf[i].name)) {
			list_ref.push(sym_idx);
		} else {
			List{usz} new_list;
			new_list.init(mem);
			new_list.push(sym_idx);
			self.name_index.set(buf[i].name, new_list);
		}

		// Update super_index: map each supertype name -> this symbol
		for (usz j = 0; j < buf[i].supertype_count; j++) {
			String st_name = buf[i].supertypes[j];
			if (st_name.len == 0) continue;
			if (try list_ref = self.super_index.get_ref(st_name)) {
				list_ref.push(sym_idx);
			} else {
				List{usz} new_list;
				new_list.init(mem);
				new_list.push(sym_idx);
				self.super_index.set(st_name, new_list);
			}
		}
	}

	// Record file entry
	WorkspaceFile wf = {
		.uri = uri.copy(mem),
		.package_name = pkg_copy,
		.module_name = module_name.len > 0 ? module_name.copy(mem) : "",
		.symbol_start = start,
		.symbol_count = count,
	};
	self.files.set(uri, wf);

	// Populate member cache for class-like declarations
	self.cache_class_members(uri, content, &buf, count);
}

/**
 * Remove all symbols for a URI from the index.
 * Frees heap strings, compacts the symbols list, and rebuilds indices.
 */
fn void WorkspaceIndex.remove_file(WorkspaceIndex* self, String uri) {
	WorkspaceFile* wf = self.files.get_ref(uri) ?? null;
	if (wf == null) return;

	usz start = wf.symbol_start;
	usz count = wf.symbol_count;

	// Remove member_cache entries for class-like symbols in this file
	for (usz i = start; i < start + count && i < self.symbols.len(); i++) {
		WorkspaceSymbol* sym = &self.symbols[i];
		if (sym.kind == SymbolKind.CLASS || sym.kind == SymbolKind.INTERFACE ||
			sym.kind == SymbolKind.OBJECT) {
			if (try list_ref = self.member_cache.get_ref(sym.name)) {
				for (usz j = 0; j < list_ref.len(); j++) {
					free_member_decl(&(*list_ref)[j]);
				}
				list_ref.free();
				self.member_cache.remove(sym.name);
			}
		}
	}

	// Free strings in symbols being removed
	for (usz i = start; i < start + count && i < self.symbols.len(); i++) {
		WorkspaceSymbol* sym = &self.symbols[i];
		if (sym.name.len > 0) mem::free(sym.name.ptr);
		if (sym.uri.len > 0) mem::free(sym.uri.ptr);
		if (sym.package_name.len > 0) mem::free(sym.package_name.ptr);
		if (sym.receiver.len > 0) mem::free(sym.receiver.ptr);
		for (usz j = 0; j < sym.supertype_count; j++) {
			if (sym.supertypes[j].len > 0) mem::free(sym.supertypes[j].ptr);
		}
		sym.supertype_count = 0;
	}

	// Free file entry strings
	if (wf.uri.len > 0) mem::free(wf.uri.ptr);
	if (wf.package_name.len > 0) mem::free(wf.package_name.ptr);
	if (wf.module_name.len > 0) mem::free(wf.module_name.ptr);
	self.files.remove(uri);

	// #11: Compact the symbols list by shifting remaining symbols down
	usz remove_end = start + count;
	if (remove_end > self.symbols.len()) remove_end = self.symbols.len();
	usz shift = remove_end - start;
	if (shift > 0 && remove_end < self.symbols.len()) {
		// Shift remaining symbols down
		for (usz i = remove_end; i < self.symbols.len(); i++) {
			self.symbols[i - shift] = self.symbols[i];
		}
	}
	// Shrink the list by removing the last 'shift' entries
	for (usz i = 0; i < shift; i++) {
		self.symbols.pop()!!;
	}

	// Update symbol_start in all WorkspaceFile entries that came after the removed range
	@pool() {
		foreach (&entry : self.files.tvalues()) {
			if (entry.symbol_start > start) {
				if (entry.symbol_start >= shift) {
					entry.symbol_start -= shift;
				} else {
					entry.symbol_start = 0;
				}
			}
		}
	};

	// Rebuild name_index and super_index from the compacted symbols list
	self.rebuild_name_index();
}

fn void WorkspaceIndex.rebuild_name_index(WorkspaceIndex* self) {
	// Free old name_index lists and clear the map
	@pool() {
		foreach (&list : self.name_index.tvalues()) {
			list.free();
		}
	};
	self.name_index.clear();

	// Free old super_index lists and clear the map
	@pool() {
		foreach (&list : self.super_index.tvalues()) {
			list.free();
		}
	};
	self.super_index.clear();

	for (usz i = 0; i < self.symbols.len(); i++) {
		if (self.symbols[i].name.len == 0) continue; // skip removed
		String name = self.symbols[i].name;
		if (try list_ref = self.name_index.get_ref(name)) {
			list_ref.push(i);
		} else {
			List{usz} new_list;
			new_list.init(mem);
			new_list.push(i);
			self.name_index.set(name, new_list);
		}

		// Rebuild super_index
		for (usz j = 0; j < self.symbols[i].supertype_count; j++) {
			String st_name = self.symbols[i].supertypes[j];
			if (st_name.len == 0) continue;
			if (try list_ref = self.super_index.get_ref(st_name)) {
				list_ref.push(i);
			} else {
				List{usz} new_list;
				new_list.init(mem);
				new_list.push(i);
				self.super_index.set(st_name, new_list);
			}
		}
	}
}

// ── Lookup ─────────────────────────────────────────────────────────

/**
 * Look up symbols by name. Returns a pointer to the index list,
 * or null if no symbols with that name exist.
 */
fn List{usz}*? WorkspaceIndex.lookup_by_name(WorkspaceIndex* self, String name) {
	return self.name_index.get_ref(name);
}

/**
 * Look up symbols that extend/implement a given supertype name.
 * Returns a pointer to the index list of implementing symbol indices,
 * or fault if no implementations exist.
 */
fn List{usz}*? WorkspaceIndex.lookup_by_supertype(WorkspaceIndex* self, String supertype_name) {
	return self.super_index.get_ref(supertype_name);
}

/**
 * Get a workspace symbol by index.
 */
fn WorkspaceSymbol* WorkspaceIndex.get_symbol(WorkspaceIndex* self, usz idx) {
	return &self.symbols[idx];
}

/**
 * Get total number of (non-removed) symbols in the index.
 */
fn usz WorkspaceIndex.symbol_count(WorkspaceIndex* self) {
	usz count = 0;
	for (usz i = 0; i < self.symbols.len(); i++) {
		if (self.symbols[i].name.len > 0) count++;
	}
	return count;
}

// ── Workspace scanning ─────────────────────────────────────────────

faultdef SCAN_ERROR;

/**
 * Scan the workspace root directory for .kt files and index them all.
 * When Gradle modules are discovered (via classpath resolution), scans only
 * the known source roots for each module. Otherwise falls back to a recursive
 * directory walk from the workspace root.
 */
fn void WorkspaceIndex.scan_workspace(WorkspaceIndex* self) {
	if (self.root_path.len == 0) {
		log::warn("[kls] No workspace root set, skipping scan");
		return;
	}

	log::info("[kls] Scanning workspace: %s", self.root_path);
	usz file_count = 0;

	if (self.classpath.module_count > 0) {
		// Module-aware scan: iterate each module's source roots
		for (usz i = 0; i < self.classpath.module_count; i++) {
			GradleModule* m = &self.classpath.modules[i];
			for (usz j = 0; j < m.src_root_count; j++) {
				if (m.src_roots[j].len == 0) continue;
				Path src = path::temp(m.src_roots[j])!!;
				if (path::is_dir(src)) {
					scan_directory_recursive(self, src, &file_count);
				}
			}
		}
	} else {
		// Fallback: recursive walk from workspace root
		Path root = path::temp(self.root_path)!!;
		scan_directory_recursive(self, root, &file_count);
	}

	log::info("[kls] Indexed %d files, %d symbols", file_count, self.symbols.len());
}

fn void scan_directory_recursive(WorkspaceIndex* idx, Path dir, usz* file_count) {
	PathList entry_list;
	if (try list = path::ls(tmem, dir)) {
		entry_list = list;
	} else {
		return;
	}

	foreach (entry : entry_list) {
		String entry_name = entry.basename();

		// Skip hidden entries and common non-source dirs
		if (entry_name.len > 0 && entry_name[0] == '.') continue;
		if (entry_name == "build" || entry_name == "out" || entry_name == "node_modules") continue;

		Path full;
		if (try f = dir.tappend(entry_name)) {
			full = f;
		} else {
			continue;
		}

		if (path::is_dir(full)) {
			// Recurse into subdirectory
			scan_directory_recursive(idx, full, file_count);
		} else if (entry_name.len > 3 && entry_name[entry_name.len - 3..] == ".kt") {
			// Index .kt file
			String full_str = full.str_view();
			index_file_from_disk(idx, full_str, file_count);
		}
	}
}

fn void index_file_from_disk(WorkspaceIndex* idx, String file_path, usz* file_count) {
	// Read file content using the stdlib file loader
	char[] data;
	if (try d = file::load(mem, file_path)) {
		data = d;
	} else {
		log::debug("[kls] Failed to read: %s", file_path);
		return;
	}
	defer mem::free(data.ptr);

	String content = (String)data;
	String uri = path_to_uri(file_path);
	String uri_copy = uri.tcopy();

	idx.index_file(uri_copy, content);
	(*file_count)++;
}

// ── File I/O helpers ───────────────────────────────────────────────

/**
 * Read a file's content into heap-allocated memory.
 * Caller must free the returned string's .ptr when done.
 */
fn String? read_file_content(String file_path) {
	char[] data = file::load(mem, file_path)!;
	return (String)data;
}

// ── URI <-> Path conversion ────────────────────────────────────────

/**
 * Convert a file:// URI to a filesystem path.
 * "file:///Users/foo/bar.kt" -> "/Users/foo/bar.kt"
 */
fn String uri_to_path(String uri) {
	if (uri.starts_with("file://")) {
		return uri["file://".len..];
	}
	return uri;
}

/**
 * Convert a filesystem path to a file:// URI.
 * "/Users/foo/bar.kt" -> "file:///Users/foo/bar.kt"
 */
fn String path_to_uri(String path) {
	DString ds;
	ds.tinit();
	ds.appendf("file://%s", path);
	return ds.str_view();
}

// ── Package scanning ───────────────────────────────────────────────

/**
 * Extract the package name from Kotlin source content.
 * Looks for "package <identifier>" at the beginning of the file.
 * Returns empty string if no package declaration found.
 */
fn String scan_package(String content) {
	if (content.len == 0) return "";

	Lexer lex = lexer::init(content);

	Token tok = lex.next();
	if (tok.kind != KW_PACKAGE) return "";

	// Collect package path: identifiers separated by dots
	usz start = 0;
	usz end = 0;
	bool first = true;

	while (true) {
		Token name_tok = lex.next();
		// #8: Accept soft keywords as package name segments (e.g., "data.model")
		if (!name_tok.kind.is_identifier_or_soft_keyword()) break;

		if (first) {
			start = (usz)name_tok.offset;
			first = false;
		}
		end = (usz)name_tok.offset + (usz)name_tok.len;

		// Check for dot continuation
		Token dot = lex.next();
		if (dot.kind != DOT) break;
	}

	if (first) return ""; // No identifier after package
	return content[start..end - 1];
}

// ── SymbolKind -> LSP SymbolKind ───────────────────────────────────

fn int symbol_kind_to_lsp(SymbolKind kind) {
	switch (kind) {
		case FUNCTION:  return 12; // Function
		case CLASS:     return 5;  // Class
		case INTERFACE: return 11; // Interface
		case OBJECT:    return 2;  // Module
		case PROPERTY:  return 7;  // Property
		case TYPEALIAS: return 5;  // Class (no TypeAlias in LSP)
	}
}

// ── Import-aware visibility ───────────────────────────────────────

// Maximum number of imports per file we track
const usz MAX_IMPORTS = 256;

struct ImportMap {
	String package_name;             // this file's package
	usz import_count;
	String[MAX_IMPORTS] import_paths; // full import paths (e.g. "com.example.Foo")
	String[MAX_IMPORTS] import_names; // simple name or alias (e.g. "Foo" or alias "Bar")
	bool[MAX_IMPORTS] is_star;        // true if wildcard import (com.example.*)
	String[MAX_IMPORTS] star_packages;// for star imports, the package prefix (com.example)
}

/**
 * Build an import map from a parsed file's AST.
 * Extracts the package declaration and all import declarations.
 */
fn ImportMap build_import_map(ParseResult* pr) {
	ImportMap map;
	map.package_name = "";
	map.import_count = 0;

	if (pr == null || pr.node_count == 0) return map;

	// FILE is node 0
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (node.parent != 0) continue; // only direct children of FILE

		if (node.kind == PACKAGE_DECL) {
			map.package_name = node.extra_text;
			continue;
		}

		if (node.kind == IMPORT_DECL) {
			if (map.import_count >= MAX_IMPORTS) break;
			String path = node.extra_text;
			if (path.len == 0) continue;

			usz idx = map.import_count;

			// Check for star import: path ends with ".*"
			if (path.len >= 2 && path[path.len - 2] == '.' && path[path.len - 1] == '*') {
				map.is_star[idx] = true;
				map.star_packages[idx] = path[:path.len - 2]; // trim ".*"
				map.import_paths[idx] = path;
				map.import_names[idx] = "*";
			} else {
				map.is_star[idx] = false;
				map.star_packages[idx] = "";
				map.import_paths[idx] = path;

				// Determine simple name: alias if present, otherwise last path segment
				if (node.name.len > 0) {
					// Has alias: import com.example.Foo as Bar
					map.import_names[idx] = node.name;
				} else {
					// Extract last segment from path
					usz last_dot = path.len;
					for (usz j = path.len; j > 0; j--) {
						if (path[j - 1] == '.') {
							last_dot = j - 1;
							break;
						}
					}
					if (last_dot < path.len) {
						map.import_names[idx] = path[last_dot + 1..];
					} else {
						map.import_names[idx] = path;
					}
				}
			}
			map.import_count++;
			continue;
		}
	}
	return map;
}

/**
 * Check if a workspace symbol is visible from a file with the given import map.
 *
 * A symbol is visible if:
 * 1. It's in the same package as the importing file
 * 2. It's in a package covered by a star import (import com.example.*)
 * 3. It's explicitly imported by name (import com.example.Foo)
 * 4. It's in a Kotlin auto-imported package (kotlin.*, kotlin.collections.*, etc.)
 *
 * For aliased imports, the alias name must be used instead of the real name.
 * Returns the name to use (alias or real name), or empty string if not visible.
 */
fn String is_symbol_visible(WorkspaceSymbol* sym, ImportMap* imports, String lookup_name) {
	// Same package — always visible
	if (sym.package_name.len > 0 && sym.package_name == imports.package_name) {
		return sym.name;
	}

	// Kotlin auto-imported packages — always visible
	if (is_auto_imported_package(sym.package_name)) {
		return sym.name;
	}

	// Check explicit and star imports
	for (usz i = 0; i < imports.import_count; i++) {
		if (imports.is_star[i]) {
			// Star import: import com.example.*
			// Matches any symbol whose package equals the star prefix
			if (sym.package_name == imports.star_packages[i]) {
				return sym.name;
			}
		} else {
			// Explicit import: check if import path matches package.name
			// The import path should be "package.SymbolName"
			// If it has an alias, the lookup_name should match the alias
			String import_name = imports.import_names[i];
			String import_path = imports.import_paths[i];

			// Check if this import refers to this symbol
			if (sym.name == get_import_real_name(import_path) &&
				sym.package_name == get_import_package(import_path)) {
				// If the import has an alias, only match the alias
				if (import_name != sym.name) {
					// Aliased import: only match when lookup uses the alias
					if (lookup_name == import_name) {
						return import_name;
					}
				} else {
					return sym.name;
				}
			}
		}
	}

	// No package info on symbol — treat as same-package (backward compat)
	if (sym.package_name.len == 0) {
		return sym.name;
	}

	return "";
}

/**
 * Check if a package is auto-imported in Kotlin (always available without explicit import).
 */
fn bool is_auto_imported_package(String package_name) {
	if (package_name.len == 0) return false;
	return package_name == "kotlin" ||
		package_name == "kotlin.annotation" ||
		package_name == "kotlin.collections" ||
		package_name == "kotlin.comparisons" ||
		package_name == "kotlin.io" ||
		package_name == "kotlin.ranges" ||
		package_name == "kotlin.sequences" ||
		package_name == "kotlin.text";
}

/**
 * Extract the simple name (last segment) from a fully qualified import path.
 * e.g., "com.example.Foo" -> "Foo"
 */
fn String get_import_real_name(String path) {
	for (usz i = path.len; i > 0; i--) {
		if (path[i - 1] == '.') {
			return path[i..];
		}
	}
	return path;
}

/**
 * Extract the package part from a fully qualified import path.
 * e.g., "com.example.Foo" -> "com.example"
 */
fn String get_import_package(String path) {
	for (usz i = path.len; i > 0; i--) {
		if (path[i - 1] == '.') {
			return path[:i - 1];
		}
	}
	return "";
}

// ── Module-aware visibility ───────────────────────────────────────

/**
 * Get the module name for a file by URI.
 * Returns empty string if no modules are known or the file is not in any module.
 */
fn String WorkspaceIndex.get_file_module(WorkspaceIndex* self, String uri) {
	if (self.classpath.module_count == 0) return "";
	WorkspaceFile* wf = self.files.get_ref(uri) ?? null;
	if (wf == null) return "";
	return wf.module_name;
}

/**
 * Check if a symbol is visible from a given file, considering module boundaries.
 * In a multi-module project, a symbol from module X is only visible to a file
 * in module Y if Y depends on X (directly or transitively).
 *
 * Returns true if:
 * - No modules are known (single-project mode — everything visible)
 * - Either the symbol or requesting file has no module assignment (permissive)
 * - The symbol and file are in the same module
 * - The requesting file's module depends on the symbol's module
 */
fn bool WorkspaceIndex.is_module_visible(WorkspaceIndex* self, String sym_uri, String from_uri) {
	if (self.classpath.module_count == 0) return true;

	String from_module = self.get_file_module(from_uri);
	String sym_module = self.get_file_module(sym_uri);

	// If either has no module, be permissive (backward compat / files outside modules)
	if (from_module.len == 0 || sym_module.len == 0) return true;

	return self.classpath.module_depends_on(from_module, sym_module);
}
