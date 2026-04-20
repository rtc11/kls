module kls::lsp::type_hierarchy;

import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::definition;
import kls::lsp::implementation;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::workspace;
import kls::kotlin::stdlib;
import kls::kotlin::jdk_symbols;
import kls::kotlin::symbols;
import kls::deps::jar_index;
import kls::deps::source_nav;
import kls::log;

/**
 * Handle textDocument/prepareTypeHierarchy request.
 * Resolves the symbol at the cursor to a TypeHierarchyItem if it is
 * a class-like declaration (class, interface, object, enum).
 *
 * Returns a JSON array of TypeHierarchyItem, or null if the cursor
 * is not on a type name.
 */
fn Object*? handle_prepare(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	// Find token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	if (tok.kind != IDENTIFIER) return null;

	String target_name = tok.text;

	// Try AST first: find a class-like declaration with this name
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr != null) {
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* node = &pr.nodes[i];
			if (!is_type_decl(node.kind)) continue;
			if (node.name != target_name) continue;

			Object* item = build_item_from_node(node, uri);
			Object* items = object::new_obj(tmem);
			items.push(item);
			return items;
		}
	}

	// Try workspace index
	if (workspace != null) {
		if (try indices = workspace.lookup_by_name(target_name)) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
				if (sym.name.len == 0) continue;
				if (!is_type_symbol_kind(sym.kind)) continue;

				Object* item = build_item_from_workspace_symbol(sym);
				Object* items = object::new_obj(tmem);
				items.push(item);
				return items;
			}
		}
	}

	// Try dependency index
	if (workspace != null) {
		DepSymbol*[16] matches;
		usz count = workspace.dep_index.lookup_by_name(target_name, &matches);
		for (usz i = 0; i < count; i++) {
			DepSymbol* dep = matches[i];
			if (!is_type_dep_kind(dep.kind)) continue;

			Object* item = build_item_from_dep_symbol(dep);
			if (item != null) {
				Object* items = object::new_obj(tmem);
				items.push(item);
				return items;
			}
		}
	}

	return null;
}

/**
 * Handle typeHierarchy/supertypes request.
 * Given a TypeHierarchyItem, returns its direct supertypes.
 */
fn Object*? handle_supertypes(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* item = params.get("item")!;
	String name = item.get_string("name")!;
	String uri = item.get_string("uri")!;

	Object* supertypes = object::new_obj(tmem);

	// Strategy 1: AST-based -- find TYPE_REF children of the class decl
	Document* doc = store.get(uri) ?? null;
	if (doc != null) {
		ParseResult* pr = store.get_ast(uri) ?? null;
		if (pr != null) {
			collect_supertypes_from_ast(pr, name, uri, store, workspace, supertypes);
		}
	}

	// Strategy 2: Workspace index -- use stored supertypes
	if (supertypes.get_len() == 0 && workspace != null) {
		collect_supertypes_from_workspace(workspace, name, supertypes);
	}

	// Strategy 3: Dep index -- use stored supertypes
	if (supertypes.get_len() == 0 && workspace != null) {
		collect_supertypes_from_deps(&workspace.dep_index, name, supertypes);
	}

	if (supertypes.get_len() == 0) return null;
	return supertypes;
}

/**
 * Handle typeHierarchy/subtypes request.
 * Given a TypeHierarchyItem, returns its direct subtypes/implementors.
 */
fn Object*? handle_subtypes(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* item = params.get("item")!;
	String name = item.get_string("name")!;
	String uri = item.get_string("uri")!;

	Object* subtypes = object::new_obj(tmem);

	// In-file AST search (same logic as implementation)
	Document* doc = store.get(uri) ?? null;
	if (doc != null) {
		ParseResult* pr = store.get_ast(uri) ?? null;
		if (pr != null) {
			find_subtypes_in_ast(pr, name, uri, subtypes);
		}
	}

	// Cross-file workspace index
	if (workspace != null) {
		find_subtypes_in_workspace(workspace, name, uri, subtypes);
	}

	// Dependency index
	if (workspace != null) {
		find_subtypes_in_deps(&workspace.dep_index, name, subtypes);
	}

	if (subtypes.get_len() == 0) return null;
	return subtypes;
}

// ── Supertype collection ───────────────────────────────────────────

/**
 * Find supertypes from AST TYPE_REF children of a class decl,
 * then resolve each supertype name to a TypeHierarchyItem.
 */
fn void collect_supertypes_from_ast(ParseResult* pr, String class_name, String uri,
		DocumentStore* store, WorkspaceIndex* workspace, Object* result) {
	// Find the class-like node
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (!is_type_decl(node.kind)) continue;
		if (node.name != class_name) continue;

		// Collect TYPE_REF children (supertypes)
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.kind != TYPE_REF) continue;
			if (child.name.len == 0) continue;

			Object* item = resolve_type_name(child.name, uri, store, workspace);
			if (item != null) {
				result.push(item);
			}
		}
		return;
	}
}

/**
 * Find supertypes from workspace symbol supertypes field.
 */
fn void collect_supertypes_from_workspace(WorkspaceIndex* workspace, String name, Object* result) {
	if (try indices = workspace.lookup_by_name(name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.name.len == 0) continue;
			if (!is_type_symbol_kind(sym.kind)) continue;

			for (usz j = 0; j < sym.supertype_count; j++) {
				String super_name = sym.supertypes[j];
				if (super_name.len == 0) continue;

				// Resolve the supertype name to a TypeHierarchyItem
				Object* item = resolve_type_in_workspace(workspace, super_name);
				if (item != null) {
					result.push(item);
				}
			}
			return; // found our symbol
		}
	}
}

/**
 * Find supertypes from dependency index.
 */
fn void collect_supertypes_from_deps(DependencyIndex* dep_index, String name, Object* result) {
	if (dep_index == null || !dep_index.initialized) return;

	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(name, &matches);
	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = matches[i];
		if (!is_type_dep_kind(sym.kind)) continue;

		for (usz j = 0; j < sym.supertype_count; j++) {
			String super_name = sym.supertypes[j];
			if (super_name.len == 0) continue;

			Object* item = resolve_dep_type(dep_index, super_name);
			if (item != null) {
				result.push(item);
			}
		}
		return;
	}
}

// ── Subtype collection ─────────────────────────────────────────────

/**
 * Find subtypes in AST (class-like nodes with TYPE_REF matching target).
 */
fn void find_subtypes_in_ast(ParseResult* pr, String target_name, String uri, Object* result) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];
		if (!is_type_decl(node.kind)) continue;

		if (implementation::has_supertype(pr, i, target_name)) {
			Object* item = build_item_from_node(node, uri);
			result.push(item);
		}
	}
}

/**
 * Find subtypes in workspace index via super_index.
 */
fn void find_subtypes_in_workspace(WorkspaceIndex* workspace, String target_name, String current_uri, Object* result) {
	List{usz}* indices = workspace.lookup_by_supertype(target_name) ?? null;
	if (indices == null) return;

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;
		// Skip same-file symbols (already handled by AST)
		if (sym.uri == current_uri) continue;

		Object* item = build_item_from_workspace_symbol(sym);
		result.push(item);
	}
}

/**
 * Find subtypes in dependency index via super_index.
 */
fn void find_subtypes_in_deps(DependencyIndex* dep_index, String target_name, Object* result) {
	if (dep_index == null || !dep_index.initialized) return;

	DepSymbol*[64] matches;
	usz count = dep_index.lookup_by_supertype(target_name, &matches);

	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = matches[i];
		Object* item = build_item_from_dep_symbol(sym);
		if (item != null) {
			result.push(item);
		}
	}
}

// ── Name resolution helpers ────────────────────────────────────────

/**
 * Resolve a type name to a TypeHierarchyItem by searching:
 * 1. Open documents (AST)
 * 2. Workspace index
 * 3. Dependency index
 */
fn Object* resolve_type_name(String name, String current_uri,
		DocumentStore* store, WorkspaceIndex* workspace) {
	// Check open documents
	if (store != null) {
		foreach (&doc : store.docs.tvalues()) {
			ParseResult* pr = store.get_ast(doc.uri) ?? null;
			if (pr == null) continue;

			for (uint i = 0; i < pr.node_count; i++) {
				AstNode* node = &pr.nodes[i];
				if (!is_type_decl(node.kind)) continue;
				if (node.name == name) {
					return build_item_from_node(node, doc.uri);
				}
			}
		}
	}

	// Workspace index
	if (workspace != null) {
		Object* item = resolve_type_in_workspace(workspace, name);
		if (item != null) return item;

		// Dep index
		Object* dep_item = resolve_dep_type(&workspace.dep_index, name);
		if (dep_item != null) return dep_item;
	}

	// Unresolved -- build a placeholder item with just the name
	return build_unresolved_item(name);
}

/**
 * Resolve a type name in workspace index.
 */
fn Object* resolve_type_in_workspace(WorkspaceIndex* workspace, String name) {
	if (try indices = workspace.lookup_by_name(name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.name.len == 0) continue;
			if (!is_type_symbol_kind(sym.kind)) continue;
			return build_item_from_workspace_symbol(sym);
		}
	}
	return null;
}

/**
 * Resolve a type name in dependency index.
 */
fn Object* resolve_dep_type(DependencyIndex* dep_index, String name) {
	if (dep_index == null || !dep_index.initialized) return null;

	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(name, &matches);
	for (usz i = 0; i < count; i++) {
		if (!is_type_dep_kind(matches[i].kind)) continue;
		return build_item_from_dep_symbol(matches[i]);
	}
	return null;
}

// ── TypeHierarchyItem builders ─────────────────────────────────────

/**
 * Build a TypeHierarchyItem from an AST node.
 */
fn Object* build_item_from_node(AstNode* node, String uri) {
	Object* item = object::new_obj(tmem);
	item.set("name", node.name);
	item.set("kind", node_kind_to_lsp_symbol_kind(node.kind));
	item.set("uri", uri);

	// range: full node span
	Object* range = object::new_obj(tmem);
	Object* r_start = object::new_obj(tmem);
	r_start.set("line", (int)node.start_line);
	r_start.set("character", (int)node.start_col);
	Object* r_end = object::new_obj(tmem);
	r_end.set("line", (int)node.end_line);
	r_end.set("character", (int)node.end_col);
	range.set("start", r_start);
	range.set("end", r_end);
	item.set("range", range);

	// selectionRange: name span
	Object* sel_range = object::new_obj(tmem);
	Object* s_start = object::new_obj(tmem);
	s_start.set("line", (int)node.name_line);
	s_start.set("character", (int)node.name_col);
	Object* s_end = object::new_obj(tmem);
	s_end.set("line", (int)node.name_line);
	s_end.set("character", (int)(node.name_col + node.name_len));
	sel_range.set("start", s_start);
	sel_range.set("end", s_end);
	item.set("selectionRange", sel_range);

	return item;
}

/**
 * Build a TypeHierarchyItem from a workspace symbol.
 */
fn Object* build_item_from_workspace_symbol(WorkspaceSymbol* sym) {
	Object* item = object::new_obj(tmem);
	item.set("name", sym.name);
	item.set("kind", sym.lsp_kind);
	item.set("uri", sym.uri);

	// For workspace symbols, range = selectionRange (name position only)
	Object* range = object::new_obj(tmem);
	Object* r_start = object::new_obj(tmem);
	r_start.set("line", (int)sym.line);
	r_start.set("character", (int)sym.col);
	Object* r_end = object::new_obj(tmem);
	r_end.set("line", (int)sym.line);
	r_end.set("character", (int)(sym.col + sym.name_len));
	range.set("start", r_start);
	range.set("end", r_end);
	item.set("range", range);
	item.set("selectionRange", range);

	if (sym.package_name.len > 0) {
		item.set("detail", sym.package_name);
	}

	return item;
}

/**
 * Build a TypeHierarchyItem from a dependency symbol.
 * Returns null if source navigation fails.
 */
fn Object* build_item_from_dep_symbol(DepSymbol* sym) {
	// Try to resolve source location
	Object* loc = source_nav::resolve_dep_definition(sym);
	if (loc == null) {
		// Build with synthetic URI (no source available)
		return build_unresolved_item(sym.name);
	}

	String uri = loc.get_string("uri")!!;
	Object* range = loc.get("range")!!;

	Object* item = object::new_obj(tmem);
	item.set("name", sym.name);
	item.set("kind", dep_kind_to_lsp_symbol_kind(sym.kind));
	item.set("uri", uri);
	item.set("range", range);
	item.set("selectionRange", range);

	if (sym.package_name.len > 0) {
		item.set("detail", sym.package_name);
	}

	return item;
}

/**
 * Build a TypeHierarchyItem for types not found in workspace/deps.
 * Tries stdlib and JDK symbol tables for richer metadata before
 * falling back to a minimal placeholder.
 */
fn Object* build_unresolved_item(String name) {
	Object* item = object::new_obj(tmem);
	item.set("name", name);

	int kind = 5; // default: Class
	String detail = "";

	// Try stdlib
	if (try sym = stdlib::lookup_by_name(name)) {
		switch (sym.kind) {
			case INTERFACE: kind = 11;
			case OBJECT: kind = 5;
			default: kind = 5;
		}
		detail = sym.package_name;
	} else {
		// Try JDK
		StdlibSymbol*[4] jdk_matches;
		usz jdk_count = jdk_symbols::lookup_all_by_name(name, &jdk_matches);
		if (jdk_count > 0) {
			StdlibSymbol* jdk = jdk_matches[0];
			switch (jdk.kind) {
				case INTERFACE: kind = 11;
				default: kind = 5;
			}
			detail = jdk.package_name;
		}
	}

	item.set("kind", kind);
	if (detail.len > 0) {
		item.set("detail", detail);
	}

	// Still no source location — use empty URI + zero range
	item.set("uri", "");

	Object* zero_pos = object::new_obj(tmem);
	zero_pos.set("line", 0);
	zero_pos.set("character", 0);

	Object* range = object::new_obj(tmem);
	range.set("start", zero_pos);
	range.set("end", zero_pos);
	item.set("range", range);
	item.set("selectionRange", range);

	return item;
}

// ── Kind checks ────────────────────────────────────────────────────

fn bool is_type_decl(NodeKind kind) {
	switch (kind) {
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case ENUM_ENTRY:
			return true;
		default:
			return false;
	}
}

fn bool is_type_symbol_kind(SymbolKind kind) {
	switch (kind) {
		case CLASS:
		case INTERFACE:
		case OBJECT:
			return true;
		default:
			return false;
	}
}

fn bool is_type_dep_kind(DepSymbolKind kind) {
	switch (kind) {
		case DEP_CLASS:
		case DEP_INTERFACE:
		case DEP_ENUM:
		case DEP_ANNOTATION:
			return true;
		default:
			return false;
	}
}

fn int node_kind_to_lsp_symbol_kind(NodeKind kind) {
	switch (kind) {
		case CLASS_DECL:       return 5;  // Class
		case INTERFACE_DECL:   return 11; // Interface
		case OBJECT_DECL:      return 5;  // Class (object is singleton class)
		case COMPANION_OBJECT_DECL: return 5;
		case ENUM_ENTRY:       return 22; // EnumMember
		default:               return 5;  // Class fallback
	}
}

fn int dep_kind_to_lsp_symbol_kind(DepSymbolKind kind) {
	switch (kind) {
		case DEP_CLASS:      return 5;  // Class
		case DEP_INTERFACE:  return 11; // Interface
		case DEP_ENUM:       return 10; // Enum
		case DEP_ANNOTATION: return 5;  // Class
		default:             return 5;
	}
}
