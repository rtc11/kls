module kls::lsp::implementation;

import std::io;
import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::lsp::definition;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::workspace;
import kls::deps::jar_index;
import kls::deps::source_nav;

/**
 * Handle textDocument/implementation request.
 * Returns an array of Location objects pointing to classes/objects that
 * implement or extend the interface/class under the cursor, or null
 * if no implementations are found.
 *
 * Uses three tiers:
 * 1. In-file AST search: scan for class/interface/object nodes with
 *    TYPE_REF children matching the target name.
 * 2. Cross-file workspace index: use the super_index reverse mapping.
 * 3. Dependency index: use the dep super_index reverse mapping.
 */
fn Object*? handle_implementation(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	// Only look for implementations of identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;

	// Build result array
	Object* locations = object::new_obj(tmem);

	// ── Tier 1: In-file AST search ────────────────────────────────
	if (pr != null) {
		find_implementations_in_ast(pr, target_name, uri, locations);
	}

	// ── Tier 2: Cross-file workspace index ────────────────────────
	if (workspace != null) {
		find_implementations_in_workspace(workspace, target_name, uri, locations);
	}

	// ── Tier 3: Dependency index ──────────────────────────────────
	if (workspace != null) {
		find_implementations_in_deps(&workspace.dep_index, target_name, locations);
	}

	// Return null if no implementations found, otherwise the array
	if (locations.get_len() == 0) {
		return null;
	}
	return locations;
}

// ── In-file AST search ─────────────────────────────────────────────

/**
 * Scan the AST for class/interface/object declarations that have a
 * TYPE_REF child matching the target name (i.e., they extend/implement it).
 * Adds matching locations to the result array.
 */
fn void find_implementations_in_ast(ParseResult* pr, String target_name, String uri, Object* locations) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];

		// Only consider class-like declarations
		if (!is_class_like(node.kind)) continue;

		// Check if any TYPE_REF child has the target name
		if (has_supertype(pr, i, target_name)) {
			Object* loc = definition::build_location_from_node(uri, node);
			if (loc != null) {
				locations.push(loc);
			}
		}
	}
}

/**
 * Check if a class-like node at the given index has a TYPE_REF child
 * whose name matches the target.
 */
fn bool has_supertype(ParseResult* pr, usz parent_idx, String target_name) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != parent_idx) continue;
		if (child.kind != TYPE_REF) continue;
		if (child.name == target_name) return true;
	}
	return false;
}

/**
 * Check if a node kind represents a class-like declaration that can
 * implement or extend another type.
 */
fn bool is_class_like(NodeKind kind) {
	switch (kind) {
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case OBJECT_EXPR:
			return true;
		default:
			return false;
	}
}

// ── Cross-file workspace search ────────────────────────────────────

/**
 * Look up implementations in the workspace index using the super_index.
 * Skips symbols from the current document (already handled by AST search).
 */
fn void find_implementations_in_workspace(WorkspaceIndex* workspace, String target_name, String current_uri, Object* locations) {
	List{usz}* indices = workspace.lookup_by_supertype(target_name) ?? null;
	if (indices == null) return;

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;

		// Skip symbols from the current file (already checked via AST)
		if (sym.uri == current_uri) continue;

		Object* loc = definition::build_location_from_workspace_symbol(sym);
		if (loc != null) {
			locations.push(loc);
		}
	}
}

// ── Dependency search ──────────────────────────────────────────────

/**
 * Look up implementations in the dependency index using the super_index.
 * Attempts source JAR navigation to resolve to actual source locations.
 */
fn void find_implementations_in_deps(DependencyIndex* dep_index, String target_name, Object* locations) {
	if (dep_index == null || !dep_index.initialized) return;

	DepSymbol*[64] matches;
	usz count = dep_index.lookup_by_supertype(target_name, &matches);

	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = matches[i];
		// Try source JAR navigation for each implementing class
		Object* loc = source_nav::resolve_dep_definition(sym);
		if (loc != null) {
			locations.push(loc);
		}
	}
}
