module kls::lsp::call_hierarchy;

import std::io;
import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::definition;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::symbols;
import kls::workspace;
import kls::log;

// ── textDocument/prepareCallHierarchy ──────────────────────────────

/**
 * Handle textDocument/prepareCallHierarchy request.
 * Returns a CallHierarchyItem[] for the function at cursor, or null.
 */
fn Object* handle_prepare(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	if (tok.kind != IDENTIFIER) return null;

	String target_name = tok.text;

	// Get AST
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) return null;

	// Find function declaration: either cursor is ON a declaration, or resolve via definition
	AstNode* fun_node = null;

	// Check if cursor is on a FUN_DECL name directly
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != FUN_DECL && n.kind != CONSTRUCTOR_DECL) continue;
		if (n.name == target_name && n.name_offset == tok.offset) {
			fun_node = n;
			break;
		}
	}

	// If not on a declaration, try to resolve to one via definition lookup
	if (fun_node == null) {
		bool is_call = definition::is_call_context(doc.content, tok) ||
			definition::is_call_context_ast(pr, tok.offset);
		if (try node = definition::find_definition_in_ast(pr, target_name, tok.offset, is_call)) {
			if (node.kind == FUN_DECL || node.kind == CONSTRUCTOR_DECL) {
				fun_node = node;
			}
		}
	}

	// Cross-file: check workspace index
	if (fun_node == null && workspace != null) {
		// Build item from workspace symbol instead
		if (try indices = workspace.lookup_by_name(target_name)) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
				if (sym.kind == SymbolKind.FUNCTION) {
					Object* item = build_item_from_workspace_symbol(sym);
					Object* result = object::new_obj(tmem);
					result.push(item);
					return result;
				}
			}
		}
		return null;
	}

	if (fun_node == null) return null;

	Object* item = build_item(uri, fun_node);
	Object* result = object::new_obj(tmem);
	result.push(item);
	return result;
}

// ── callHierarchy/incomingCalls ────────────────────────────────────

/**
 * Handle callHierarchy/incomingCalls request.
 * Finds all call sites of the target function, grouped by enclosing function.
 */
fn Object* handle_incoming_calls(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* item = params.get("item")!!;
	String target_name = item.get_string("name")!!;
	String target_uri = item.get_string("uri")!!;

	log::debug("[callHierarchy] incoming calls for '%s'", target_name);

	Object* result = object::new_obj(tmem); // JSON array

	// Scan current file
	if (try doc = store.get(target_uri)) {
		ParseResult* pr = store.get_ast(target_uri) ?? null;
		if (pr != null) {
			collect_incoming_from_ast(result, pr, target_name, target_uri);
		}
	}

	// Scan workspace files
	if (workspace != null) {
		scan_workspace_incoming(result, workspace, store, target_name, target_uri);
	}

	if (result.get_len() == 0) return null;
	return result;
}

// ── callHierarchy/outgoingCalls ────────────────────────────────────

/**
 * Handle callHierarchy/outgoingCalls request.
 * Finds all function calls made from within the target function body.
 */
fn Object* handle_outgoing_calls(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* item = params.get("item")!!;
	String target_name = item.get_string("name")!!;
	String target_uri = item.get_string("uri")!!;

	log::debug("[callHierarchy] outgoing calls from '%s'", target_name);

	// We need the AST for the file containing the function
	String content;
	ParseResult* pr = null;

	if (try doc = store.get(target_uri)) {
		content = doc.content;
		pr = store.get_ast(target_uri) ?? null;
	} else if (workspace != null) {
		// Try reading from disk
		String file_path = workspace::uri_to_path(target_uri);
		if (try c = workspace::read_file_content(file_path)) {
			content = c;
			// Parse on heap (ParseResult too large for stack)
			ParseResult* temp_pr = mem::new(ParseResult);
			defer mem::free(temp_pr);
			parser::parse(content, temp_pr);
			pr = temp_pr;
		}
	}

	if (pr == null) return null;

	// Find the FUN_DECL node matching target_name
	// Use selectionRange from item to disambiguate
	int item_line = 0;
	if (try sel_range = item.get("selectionRange")) {
		if (try start = sel_range.get("start")) {
			item_line = start.get_int("line") ?? 0;
		}
	}

	AstNode* fun_node = null;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != FUN_DECL && n.kind != CONSTRUCTOR_DECL) continue;
		if (n.name != target_name) continue;
		if ((int)n.name_line == item_line) {
			fun_node = n;
			break;
		}
	}

	// Fallback: first FUN_DECL with matching name
	if (fun_node == null) {
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if ((n.kind == FUN_DECL || n.kind == CONSTRUCTOR_DECL) && n.name == target_name) {
				fun_node = n;
				break;
			}
		}
	}

	if (fun_node == null) return null;

	Object* result = object::new_obj(tmem); // JSON array

	// Collect all CALL_EXPR nodes inside this function
	uint fun_idx = ast::node_index(pr, fun_node);
	collect_outgoing_from_function(result, pr, fun_idx, target_uri, store, workspace);

	if (result.get_len() == 0) return null;
	return result;
}

// ── Internal helpers ───────────────────────────────────────────────

/**
 * Build a CallHierarchyItem JSON object from an AST FUN_DECL node.
 */
fn Object* build_item(String uri, AstNode* node) {
	Object* item = object::new_obj(tmem);
	item.set("name", node.name);

	// Kind: 12=Function, 9=Constructor
	int kind = node.kind == CONSTRUCTOR_DECL ? 9 : 12;
	item.set("kind", kind);
	item.set("uri", uri);

	// Detail: return type or receiver
	if (node.extra_text.len > 0) {
		DString detail;
		detail.tinit();
		detail.appendf("%s.%s", node.extra_text, node.name);
		item.set("detail", detail.str_view());
	} else if (node.type_text.len > 0) {
		item.set("detail", node.type_text);
	}

	// range: full node span
	Object* range = build_range(node.start_line, node.start_col, node.end_line, node.end_col);
	item.set("range", range);

	// selectionRange: name span
	Object* sel_range = build_range(node.name_line, node.name_col,
		node.name_line, node.name_col + node.name_len);
	item.set("selectionRange", sel_range);

	return item;
}

/**
 * Build a CallHierarchyItem from a WorkspaceSymbol.
 */
fn Object* build_item_from_workspace_symbol(WorkspaceSymbol* sym) {
	Object* item = object::new_obj(tmem);
	item.set("name", sym.name);
	item.set("kind", 12); // Function
	item.set("uri", sym.uri);

	Object* range = build_range(sym.line, sym.col, sym.line, sym.col + sym.name_len);
	item.set("range", range);

	Object* sel_range = build_range(sym.line, sym.col, sym.line, sym.col + sym.name_len);
	item.set("selectionRange", sel_range);

	return item;
}

fn Object* build_range(uint start_line, uint start_col, uint end_line, uint end_col) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)start_line);
	start.set("character", (int)start_col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)end_line);
	end_pos.set("character", (int)end_col);

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);
	return range;
}

/**
 * Check if node at child_idx is a descendant of node at ancestor_idx.
 */
fn bool is_descendant_of(ParseResult* pr, uint child_idx, uint ancestor_idx) {
	uint current = child_idx;
	while (current != ast::NO_PARENT) {
		if (current == ancestor_idx) return true;
		current = pr.nodes[current].parent;
	}
	return false;
}

/**
 * Find the enclosing FUN_DECL for a node. Walks parent chain upward.
 */
fn AstNode*? find_enclosing_function(ParseResult* pr, uint node_idx) {
	uint current = pr.nodes[node_idx].parent;
	while (current != ast::NO_PARENT) {
		AstNode* n = &pr.nodes[current];
		if (n.kind == FUN_DECL || n.kind == CONSTRUCTOR_DECL || n.kind == INIT_BLOCK) {
			return n;
		}
		current = n.parent;
	}
	return ast::NOT_FOUND~;
}

/**
 * Collect incoming calls from a single file's AST.
 * For each CALL_EXPR matching target_name, find enclosing function and group.
 */
fn void collect_incoming_from_ast(Object* result, ParseResult* pr, String target_name, String uri) {
	// Temp storage: group calls by enclosing function index
	// Max 64 distinct callers per file
	uint[64] caller_indices;
	Object*[64] caller_items;
	Object*[64] caller_ranges; // JSON arrays of fromRanges
	usz caller_count = 0;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CALL_EXPR) continue;
		if (n.name != target_name) continue;

		// Find enclosing function
		AstNode* enclosing;
		if (try enc = find_enclosing_function(pr, i)) {
			enclosing = enc;
		} else {
			continue; // top-level call outside function — skip
		}

		// Don't report self-recursion as incoming (same name + same node)
		// Actually, self-recursion IS valid incoming call. Keep it.

		uint enc_idx = ast::node_index(pr, enclosing);

		// Build call-site range
		Object* call_range = build_range(n.name_line, n.name_col,
			n.name_line, n.name_col + n.name_len);

		// Find or create caller group
		bool found = false;
		for (usz j = 0; j < caller_count; j++) {
			if (caller_indices[j] == enc_idx) {
				caller_ranges[j].push(call_range);
				found = true;
				break;
			}
		}
		if (!found && caller_count < 64) {
			caller_indices[caller_count] = enc_idx;
			caller_items[caller_count] = build_item(uri, enclosing);
			Object* ranges_arr = object::new_obj(tmem);
			ranges_arr.push(call_range);
			caller_ranges[caller_count] = ranges_arr;
			caller_count++;
		}
	}

	// Emit CallHierarchyIncomingCall objects
	for (usz j = 0; j < caller_count; j++) {
		Object* incoming = object::new_obj(tmem);
		incoming.set("from", caller_items[j]);
		incoming.set("fromRanges", caller_ranges[j]);
		result.push(incoming);
	}
}

/**
 * Scan workspace files for incoming calls to target_name.
 */
fn void scan_workspace_incoming(Object* result, WorkspaceIndex* workspace, DocumentStore* store, String target_name, String current_uri) {
	// Use name_index to find files that might contain the name
	List{usz}* indices;
	if (try idx = workspace.lookup_by_name(target_name)) {
		indices = idx;
	} else {
		return;
	}

	// Collect unique URIs
	String[128] uris_to_scan;
	usz uri_count = 0;

	for (usz i = 0; i < indices.len() && uri_count < 128; i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;
		if (sym.uri == current_uri) continue;

		bool already_have = false;
		for (usz j = 0; j < uri_count; j++) {
			if (uris_to_scan[j] == sym.uri) {
				already_have = true;
				break;
			}
		}
		if (!already_have) {
			uris_to_scan[uri_count] = sym.uri;
			uri_count++;
		}
	}

	// Also scan all workspace files that are open in editor
	// (they may reference the function without declaring a symbol with that name)

	for (usz f = 0; f < uri_count; f++) {
		String file_uri = uris_to_scan[f];
		String content;
		bool need_free = false;

		if (try doc = store.get(file_uri)) {
			content = doc.content;
		} else {
			String file_path = workspace::uri_to_path(file_uri);
			if (try c = workspace::read_file_content(file_path)) {
				content = c;
				need_free = true;
			} else {
				continue;
			}
		}

		// Parse and scan AST
		ParseResult* temp_pr = mem::new(ParseResult);
		parser::parse(content, temp_pr);
		collect_incoming_from_ast(result, temp_pr, target_name, file_uri);
		mem::free(temp_pr);

		if (need_free) {
			mem::free(content.ptr);
		}
	}
}

/**
 * Collect outgoing calls from a function body.
 * Walks all CALL_EXPR descendants of fun_idx.
 */
fn void collect_outgoing_from_function(Object* result, ParseResult* pr, uint fun_idx, String uri,
		DocumentStore* store, WorkspaceIndex* workspace) {
	// Temp: deduplicate by callee name + target location
	String[128] seen_names;
	uint[128] seen_lines;
	Object*[128] seen_ranges; // JSON arrays of fromRanges
	Object*[128] seen_items;
	usz seen_count = 0;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CALL_EXPR) continue;
		if (n.name.len == 0) continue;

		// Must be descendant of our function
		if (!is_descendant_of(pr, i, fun_idx)) continue;

		String callee_name = n.name;

		// Build call-site range (from the call in our function)
		Object* call_range = build_range(n.name_line, n.name_col,
			n.name_line, n.name_col + n.name_len);

		// Try to resolve callee to a declaration
		// First: in-file AST
		AstNode* target_node = null;
		String target_uri = uri;

		if (try node = definition::find_definition_in_ast(pr, callee_name, n.name_offset, true)) {
			if (node.kind == FUN_DECL || node.kind == CONSTRUCTOR_DECL) {
				target_node = node;
			}
		}

		if (target_node != null) {
			uint target_line = target_node.name_line;
			// Deduplicate: same name + same line = same target
			bool found = false;
			for (usz j = 0; j < seen_count; j++) {
				if (seen_names[j] == callee_name && seen_lines[j] == target_line) {
					seen_ranges[j].push(call_range);
					found = true;
					break;
				}
			}
			if (!found && seen_count < 128) {
				seen_names[seen_count] = callee_name;
				seen_lines[seen_count] = target_line;
				seen_items[seen_count] = build_item(uri, target_node);
				Object* ranges_arr = object::new_obj(tmem);
				ranges_arr.push(call_range);
				seen_ranges[seen_count] = ranges_arr;
				seen_count++;
			}
		} else if (workspace != null) {
			// Cross-file: check workspace
			if (try indices = workspace.lookup_by_name(callee_name)) {
				for (usz k = 0; k < indices.len(); k++) {
					WorkspaceSymbol* sym = workspace.get_symbol(indices.get(k));
					if (sym.kind != SymbolKind.FUNCTION) continue;

					// Deduplicate
					bool found = false;
					for (usz j = 0; j < seen_count; j++) {
						if (seen_names[j] == callee_name && seen_lines[j] == sym.line) {
							seen_ranges[j].push(call_range);
							found = true;
							break;
						}
					}
					if (!found && seen_count < 128) {
						seen_names[seen_count] = callee_name;
						seen_lines[seen_count] = sym.line;
						seen_items[seen_count] = build_item_from_workspace_symbol(sym);
						Object* ranges_arr = object::new_obj(tmem);
						ranges_arr.push(call_range);
						seen_ranges[seen_count] = ranges_arr;
						seen_count++;
					}
					break; // take first match
				}
			}
		}
	}

	// Emit CallHierarchyOutgoingCall objects
	for (usz j = 0; j < seen_count; j++) {
		Object* outgoing = object::new_obj(tmem);
		outgoing.set("to", seen_items[j]);
		outgoing.set("fromRanges", seen_ranges[j]);
		result.push(outgoing);
	}
}
