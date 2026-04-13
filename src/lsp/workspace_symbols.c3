module kls::lsp::workspace_symbols;

import std::io;
import std::collections::object;
import kls::workspace;

const int MAX_WORKSPACE_SYMBOL_RESULTS = 200;

/**
 * Handle workspace/symbol request.
 * Returns a JSON array of SymbolInformation objects matching the query.
 * If query is empty, returns all symbols (up to MAX_WORKSPACE_SYMBOL_RESULTS).
 */
fn Object* handle_workspace_symbol(WorkspaceIndex* workspace, Object* params) {
	String query = "";
	if (params != null) {
		if (try q = params.get_string("query")) {
			query = q;
		}
	}

	Object* result = object::new_obj(tmem);  // JSON array
	int count = 0;

	for (usz i = 0; i < workspace.symbols.len(); i++) {
		if (count >= MAX_WORKSPACE_SYMBOL_RESULTS) break;

		WorkspaceSymbol* sym = &workspace.symbols[i];
		if (sym.name.len == 0) continue; // skip removed

		// Filter by query (substring match, case-insensitive)
		if (query.len > 0 && !contains_substring_ci(sym.name, query)) {
			continue;
		}

		Object* symbol_info = build_symbol_information(sym);
		result.push(symbol_info);
		count++;
	}

	return result;
}

/**
 * Build an LSP SymbolInformation JSON object from a workspace symbol.
 */
fn Object* build_symbol_information(WorkspaceSymbol* sym) {
	// Build Location
	Object* start = object::new_obj(tmem);
	start.set("line", (int)sym.line);
	start.set("character", (int)sym.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)sym.line);
	end_pos.set("character", (int)(sym.col + sym.name_len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", sym.uri);
	location.set("range", range);

	// Build SymbolInformation
	Object* info = object::new_obj(tmem);
	info.set("name", sym.name);
	info.set("kind", sym.lsp_kind);
	info.set("location", location);

	// Add container name (package) if available
	if (sym.package_name.len > 0) {
		info.set("containerName", sym.package_name);
	}

	return info;
}

/**
 * Case-insensitive substring search.
 * Returns true if needle is found within haystack.
 */
fn bool contains_substring_ci(String haystack, String needle) {
	if (needle.len == 0) return true;
	if (needle.len > haystack.len) return false;

	for (usz i = 0; i <= haystack.len - needle.len; i++) {
		bool match = true;
		for (usz j = 0; j < needle.len; j++) {
			char h = to_lower(haystack[i + j]);
			char n = to_lower(needle[j]);
			if (h != n) {
				match = false;
				break;
			}
		}
		if (match) return true;
	}
	return false;
}

fn char to_lower(char c) @inline {
	if (c >= 'A' && c <= 'Z') return c + 32;
	return c;
}
