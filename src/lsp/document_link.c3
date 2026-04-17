module kls::lsp::document_link;

import std::collections::object;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::workspace;
import kls::log;

/**
 * Handle textDocument/documentLink request.
 * Returns DocumentLink[] with clickable URLs in comments and strings,
 * and import paths that resolve to workspace files.
 */
fn Object* handle_document_link(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument") ?? null;
	if (td == null) return object::new_obj(tmem);

	String uri = td.get_string("uri") ?? "";
	if (uri.len == 0) return object::new_obj(tmem);

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return object::new_obj(tmem);

	Object* links = object::new_obj(tmem);

	// Extract URL links from content (comments and strings)
	add_url_links(links, doc.content);

	// Extract import links (resolve to workspace files)
	if (workspace != null) {
		ParseResult* pr = store.get_ast(uri) ?? null;
		if (pr != null) {
			add_import_links(links, pr, workspace);
		}
	}

	return links;
}

// ── URL extraction ───────────────────────────────────────────────

/**
 * Scan content for http:// and https:// URLs in comments and strings.
 * Each URL becomes a DocumentLink with the URL as target.
 */
fn void add_url_links(Object* links, String content) {
	if (content.len < 8) return; // minimum "http://x"

	usz i = 0;
	uint line = 0;
	uint col = 0;

	while (i < content.len) {
		// Track line/col
		if (content[i] == '\n') {
			line++;
			col = 0;
			i++;
			continue;
		}

		// Look for http:// or https://
		if (i + 7 < content.len && content[i] == 'h' && content[i + 1] == 't' &&
			content[i + 2] == 't' && content[i + 3] == 'p') {
			usz url_start = i;
			uint start_col = col;
			bool is_url = false;

			if (i + 7 < content.len && content[i + 4] == ':' && content[i + 5] == '/' && content[i + 6] == '/') {
				is_url = true;
			} else if (i + 8 < content.len && content[i + 4] == 's' && content[i + 5] == ':' && content[i + 6] == '/' && content[i + 7] == '/') {
				is_url = true;
			}

			if (is_url) {
				// Find end of URL (stop at whitespace, ), ], }, >, ", ', or end of content)
				usz url_end = url_start;
				while (url_end < content.len) {
					char c = content[url_end];
					if (c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
						c == ')' || c == ']' || c == '}' || c == '>' ||
						c == '"' || c == '\'' || c == '`') break;
					url_end++;
				}

				// Strip trailing punctuation that's unlikely part of URL
				while (url_end > url_start) {
					char last = content[url_end - 1];
					if (last == '.' || last == ',' || last == ';' || last == ':') {
						url_end--;
					} else {
						break;
					}
				}

				usz url_len = url_end - url_start;
				if (url_len > 10) { // minimum valid URL length
					String url = content[url_start:url_len];
					uint end_col = start_col + (uint)url_len;

					Object* link = object::new_obj(tmem);
					Object* range = object::new_obj(tmem);
					Object* start_pos = object::new_obj(tmem);
					start_pos.set("line", (int)line);
					start_pos.set("character", (int)start_col);
					Object* end_pos = object::new_obj(tmem);
					end_pos.set("line", (int)line);
					end_pos.set("character", (int)end_col);
					range.set("start", start_pos);
					range.set("end", end_pos);
					link.set("range", range);
					link.set("target", url);
					links.push(link);

					col += (uint)url_len;
					i = url_end;
					continue;
				}
			}
		}

		col++;
		i++;
	}
}

// ── Import path links ────────────────────────────────────────────

/**
 * Scan AST for IMPORT_DECL nodes and try to resolve them to workspace files.
 * Creates DocumentLinks from the import path to the target file URI.
 */
fn void add_import_links(Object* links, ParseResult* ast, WorkspaceIndex* workspace) {
	for (uint i = 0; i < ast.node_count; i++) {
		AstNode* n = &ast.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.parent != 0) continue; // only top-level imports

		String path = n.extra_text;
		if (path.len == 0) continue;

		// Skip wildcard imports
		if (path[path.len - 1] == '*') continue;

		// Extract the simple name (last segment after '.')
		String simple_name = path;
		for (usz j = path.len; j > 0; j--) {
			if (path[j - 1] == '.') {
				simple_name = path[j..];
				break;
			}
		}

		// Try to find a workspace file that declares this symbol
		if (try indices = workspace.lookup_by_name(simple_name)) {
			for (usz j = 0; j < indices.len(); j++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(j));
				// Match package: import path without last segment = package
				String import_pkg = "";
				for (usz k = path.len; k > 0; k--) {
					if (path[k - 1] == '.') {
						import_pkg = path[:k - 1];
						break;
					}
				}

				if (sym.package_name == import_pkg || import_pkg.len == 0) {
					// Create link from import range to the file
					Object* link = object::new_obj(tmem);
					Object* range = object::new_obj(tmem);
					Object* start_pos = object::new_obj(tmem);
					start_pos.set("line", (int)n.start_line);
					start_pos.set("character", (int)n.start_col);
					Object* end_pos = object::new_obj(tmem);
					end_pos.set("line", (int)n.end_line);
					end_pos.set("character", (int)n.end_col);
					range.set("start", start_pos);
					range.set("end", end_pos);
					link.set("range", range);
					link.set("target", sym.uri);
					links.push(link);
					break; // one link per import
				}
			}
		}
	}
}
