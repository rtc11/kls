module kls::lsp::type_definition;

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
import kls::kotlin::types;
import kls::kotlin::symbols;
import kls::workspace;
import kls::deps::jar_index;
import kls::deps::source_nav;
import kls::log;

// ── Primitive / built-in types with no navigable source ────────────

fn bool is_builtin_type(String name) {
	switch (name) {
		case "Int": return true;
		case "Long": return true;
		case "Short": return true;
		case "Byte": return true;
		case "Float": return true;
		case "Double": return true;
		case "Boolean": return true;
		case "Char": return true;
		case "String": return true;
		case "Unit": return true;
		case "Nothing": return true;
		case "Any": return true;
		default: return false;
	}
}

/**
 * Handle textDocument/typeDefinition request.
 * Given a cursor position, resolves the TYPE of the symbol under the
 * cursor and navigates to that type's declaration.
 *
 * E.g. cursor on `val x: MyClass = ...` navigates to `MyClass` definition.
 */
fn Object* handle_type_definition(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

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

	// Only resolve types of identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;
	log::debug("[typedef] target='%s' line=%d col=%d", target_name, line, character);

	// Get cached AST and type info
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	TypeInfo* ti = store.get_types(uri) ?? null;

	// Resolve the type of the thing under the cursor
	String type_name = resolve_type_name(pr, ti, tok);

	if (type_name.len == 0) {
		log::debug("[typedef] could not resolve type for '%s'", target_name);
		return null;
	}

	log::debug("[typedef] resolved type='%s' for '%s'", type_name, target_name);

	// Don't navigate to built-in types (no source location for primitives)
	// but do try deps for String, etc.

	// ── Same-file AST lookup for the type ──────────────────────────
	if (try node = find_type_in_ast(pr, type_name)) {
		log::debug("[typedef] found type in same-file AST");
		return definition::build_location_from_node(uri, node);
	}

	// ── Cross-file workspace lookup ────────────────────────────────
	if (workspace != null) {
		if (try result = find_type_in_workspace(workspace, type_name, uri, pr)) {
			log::debug("[typedef] found type in workspace");
			return result;
		}
	}

	// ── Dependency JAR lookup ──────────────────────────────────────
	if (workspace != null) {
		Object* dep_result = source_nav::find_definition_in_deps(&workspace.dep_index, type_name, false);
		if (dep_result != null) {
			log::debug("[typedef] found type in deps");
			return dep_result;
		}
	}

	log::debug("[typedef] no type definition found for type '%s'", type_name);
	return null;
}

// ── Type name resolution ──────────────────────────────────────────

/**
 * Resolve the type name of the symbol under the cursor.
 * Checks: declaration type annotations, TypeInfo inferred types,
 * dot-expression member types.
 */
fn String resolve_type_name(ParseResult* pr, TypeInfo* ti, Token tok) {
	String target = tok.text;

	// 1. Check if this token IS a type name (class/interface/object usage)
	//    If the cursor is on a type reference in a declaration, navigate to it directly.
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind == TYPE_REF && n.name == target &&
			n.name_line == tok.line && n.name_col == tok.col) {
			// Cursor is on a type reference itself - navigate to the type
			return target;
		}
	}

	// 2. Check declarations and parameters with explicit type annotations
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		bool is_decl = ast::is_declaration(n.kind) || n.kind == PARAM;
		if (!is_decl) continue;
		if (n.name != target) continue;
		if (n.name_line != tok.line || n.name_col != tok.col) continue;

		// Found the declaration - extract its type
		if (n.type_text.len > 0) {
			TypeRef tr = types::parse_type_text(n.type_text);
			if (tr.name.len > 0 && tr.kind != UNKNOWN) {
				return tr.name;
			}
		}

		// For functions, the type is the return type
		if (n.kind == FUN_DECL) {
			if (n.type_text.len > 0) {
				TypeRef tr = types::parse_type_text(n.type_text);
				if (tr.name.len > 0) return tr.name;
			}
			// No explicit return type - check TypeInfo
			if (ti != null && ti.has_type[i]) {
				return ti.node_types[i].name;
			}
			return ""; // function with no return type info
		}

		// For classes/interfaces/objects, the cursor is ON the type - don't navigate
		if (n.kind == CLASS_DECL || n.kind == INTERFACE_DECL ||
			n.kind == OBJECT_DECL || n.kind == COMPANION_OBJECT_DECL) {
			return ""; // cursor is on the type itself, not a reference to a type
		}

		// Check TypeInfo for inferred type
		if (ti != null && ti.has_type[i]) {
			return ti.node_types[i].name;
		}

		return "";
	}

	// 3. Check expression nodes (NAME_EXPR) for inferred type
	if (ti != null) {
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.kind == NAME_EXPR && n.name == target &&
				n.name_line == tok.line && n.name_col == tok.col) {
				if (ti.has_type[i]) {
					TypeRef* tr = &ti.node_types[i];
					if (tr.name.len > 0 && tr.kind != UNKNOWN) {
						return tr.name;
					}
				}
				break;
			}
		}

		// 4. Check dot-expression members
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.kind == DOT_EXPR && n.name == target &&
				n.name_line == tok.line && n.name_col == tok.col) {
				if (ti.has_type[i]) {
					TypeRef* tr = &ti.node_types[i];
					if (tr.name.len > 0 && tr.kind != UNKNOWN) {
						return tr.name;
					}
				}
				break;
			}
		}
	}

	// 5. Fallback: the identifier itself might be a type name reference
	//    (e.g., in a type annotation like `val x: MyClass`, cursor on MyClass)
	//    If first char is uppercase, treat it as a potential type name.
	if (target.len > 0 && target[0] >= 'A' && target[0] <= 'Z') {
		return target;
	}

	return "";
}

// ── AST type lookup ───────────────────────────────────────────────

faultdef TYPE_NOT_FOUND;

/**
 * Find a class/interface/object/typealias declaration matching the type name.
 */
fn AstNode*? find_type_in_ast(ParseResult* pr, String type_name) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name != type_name) continue;
		switch (n.kind) {
			case CLASS_DECL:
			case INTERFACE_DECL:
			case OBJECT_DECL:
			case COMPANION_OBJECT_DECL:
			case TYPEALIAS_DECL:
				return n;
			default:
				continue;
		}
	}
	return TYPE_NOT_FOUND~;
}

// ── Workspace type lookup ─────────────────────────────────────────

/**
 * Find a type declaration in the workspace index.
 * Only considers class-like symbols (CLASS, INTERFACE, OBJECT, TYPEALIAS).
 */
fn Object*? find_type_in_workspace(WorkspaceIndex* workspace, String type_name, String current_uri, ParseResult* pr) {
	List{usz}* indices = workspace.lookup_by_name(type_name)!;

	ImportMap imports = workspace::build_import_map(pr);

	WorkspaceSymbol* best = null;
	WorkspaceSymbol* imported_match = null;

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;

		// Skip symbols from current file (already checked via AST)
		if (sym.uri == current_uri) continue;

		// Only class-like symbols
		if (sym.kind != CLASS && sym.kind != INTERFACE &&
			sym.kind != OBJECT && sym.kind != TYPEALIAS) {
			continue;
		}

		// Skip module-invisible symbols
		if (!workspace.is_module_visible(sym.uri, current_uri)) continue;

		if (best == null) {
			best = sym;
		}

		// Prefer imported match
		if (imported_match == null && is_imported(sym, &imports)) {
			imported_match = sym;
		}
	}

	WorkspaceSymbol* final_result;
	if (imported_match != null) {
		final_result = imported_match;
	} else if (best != null) {
		final_result = best;
	} else {
		return TYPE_NOT_FOUND~;
	}
	return definition::build_location_from_workspace_symbol(final_result);
}

/**
 * Check if a workspace symbol is reachable via the file's imports.
 */
fn bool is_imported(WorkspaceSymbol* sym, ImportMap* imports) {
	// Same package is always visible
	if (sym.package_name.len > 0 && sym.package_name == imports.package_name) {
		return true;
	}

	// Check explicit imports
	for (usz i = 0; i < imports.import_count; i++) {
		if (imports.is_star[i]) {
			// Star import: check if symbol's package matches
			if (sym.package_name.len > 0 && sym.package_name == imports.star_packages[i]) {
				return true;
			}
		} else {
			// Named import: check if name matches
			if (sym.name == imports.import_names[i]) {
				return true;
			}
		}
	}

	return false;
}
