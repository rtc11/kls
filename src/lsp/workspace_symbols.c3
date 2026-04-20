module kls::lsp::workspace_symbols;

import std::io;
import std::collections::object;
import kls::workspace;

const int MAX_WORKSPACE_SYMBOL_RESULTS = 200;
const int MAX_SCORED_SYMBOLS = 400;

struct ScoredSymbol {
	WorkspaceSymbol* sym;
	int score;
}

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

	// Empty query: return first N symbols
	if (query.len == 0) {
		Object* result = object::new_obj(tmem);
		int count = 0;
		for (usz i = 0; i < workspace.symbols.len(); i++) {
			if (count >= MAX_WORKSPACE_SYMBOL_RESULTS) break;
			WorkspaceSymbol* sym = &workspace.symbols[i];
			if (sym.name.len == 0) continue;
			result.push(build_symbol_information(sym));
			count++;
		}
		return result;
	}

	// Fuzzy match: collect scored results, sort by score descending
	ScoredSymbol[MAX_SCORED_SYMBOLS] scored;
	int scored_count = 0;

	for (usz i = 0; i < workspace.symbols.len(); i++) {
		WorkspaceSymbol* sym = &workspace.symbols[i];
		if (sym.name.len == 0) continue;

		int score = fuzzy_score(sym.name, query);
		if (score <= 0) continue;

		if (scored_count < scored.len) {
			scored[scored_count] = { .sym = sym, .score = score };
			scored_count++;
		}
	}

	// Simple insertion sort by score descending (small N)
	for (int i = 1; i < scored_count; i++) {
		ScoredSymbol key = scored[i];
		int j = i - 1;
		while (j >= 0 && scored[j].score < key.score) {
			scored[j + 1] = scored[j];
			j--;
		}
		scored[j + 1] = key;
	}

	Object* result = object::new_obj(tmem);
	int limit = scored_count < MAX_WORKSPACE_SYMBOL_RESULTS ? scored_count : MAX_WORKSPACE_SYMBOL_RESULTS;
	for (int i = 0; i < limit; i++) {
		result.push(build_symbol_information(scored[i].sym));
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

/**
 * Fuzzy subsequence match with scoring.
 * Returns score > 0 if query is a subsequence of name (case-insensitive).
 * Higher score = better match.
 *
 * Scoring bonuses:
 *   +10 per matched character
 *   +5  for consecutive matches
 *   +8  for camelCase boundary match (lowercase followed by uppercase)
 *   +3  for match at start of name
 *   +20 for exact prefix match
 *   -1  per gap between matches
 */
fn int fuzzy_score(String name, String query) {
	if (query.len == 0) return 1;
	if (query.len > name.len) return 0;

	usz qi = 0;  // query index
	int score = 0;
	int consecutive = 0;
	usz last_match = 0;

	// Check exact prefix match bonus
	bool is_prefix = true;
	for (usz i = 0; i < query.len && i < name.len; i++) {
		if (to_lower(name[i]) != to_lower(query[i])) {
			is_prefix = false;
			break;
		}
	}
	if (is_prefix) score += 20;

	for (usz ni = 0; ni < name.len && qi < query.len; ni++) {
		if (to_lower(name[ni]) == to_lower(query[qi])) {
			score += 10; // base match

			// Consecutive bonus
			if (qi > 0 && ni == last_match + 1) {
				consecutive++;
				score += 5;
			} else {
				consecutive = 0;
				// Gap penalty
				if (qi > 0) {
					int gap = (int)(ni - last_match) - 1;
					score -= gap;
				}
			}

			// Start-of-name bonus
			if (ni == 0) score += 3;

			// CamelCase boundary bonus (char before is lowercase, current is uppercase)
			if (ni > 0 && name[ni] >= 'A' && name[ni] <= 'Z' &&
				name[ni - 1] >= 'a' && name[ni - 1] <= 'z') {
				score += 8;
			}
			// Underscore boundary bonus
			if (ni > 0 && name[ni - 1] == '_') {
				score += 8;
			}

			last_match = ni;
			qi++;
		}
	}

	// All query chars must match
	if (qi < query.len) return 0;

	return score;
}
