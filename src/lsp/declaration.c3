module kls::lsp::declaration;

import std::collections::object;
import std::collections::list;
import kls::document;
import kls::lsp::definition;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::workspace;
import kls::kotlin::symbols;

/**
 * Handle textDocument/declaration request.
 * Returns the declaration site of the symbol under the cursor.
 *
 * For overridden methods (marked with `override`), navigates to the
 * original abstract/interface declaration in a supertype.
 * Falls back to definition for all other symbols.
 */
fn Object*? handle_declaration(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
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

	// Try to find original declaration in supertype for override methods
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr != null && workspace != null) {
		Object* decl = find_supertype_declaration(store, workspace, pr, tok);
		if (decl != null) return decl;
	}

	// Fall back to definition
	return definition::handle_definition(store, workspace, params);
}

/**
 * Look for the original declaration of an overridden method in supertypes.
 * Returns a Location pointing to the supertype's method, or null.
 */
fn Object* find_supertype_declaration(DocumentStore* store, WorkspaceIndex* workspace, ParseResult* pr, Token tok) {
	// Find the function declaration at cursor position
	uint fun_idx = uint.max;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if (n.name == tok.text && n.name_line == tok.line && n.name_col == tok.col) {
			fun_idx = i;
			break;
		}
	}
	if (fun_idx == uint.max) return null;

	AstNode* fun_node = &pr.nodes[fun_idx];

	// Only look for supertypes if function has override modifier
	if (fun_node.mod_flags & ast::MOD_OVERRIDE == 0) return null;

	// Find enclosing class
	uint class_idx = fun_node.parent;
	while (class_idx != 0 && class_idx != ast::NO_PARENT) {
		AstNode* n = &pr.nodes[class_idx];
		if (n.kind == CLASS_DECL || n.kind == OBJECT_DECL) break;
		class_idx = n.parent;
	}
	if (class_idx == 0 || class_idx == ast::NO_PARENT) return null;

	AstNode* cls = &pr.nodes[class_idx];
	String class_name = cls.name;
	if (class_name.len == 0) return null;

	// Find this class in workspace to get its supertypes
	if (try indices = workspace.lookup_by_name(class_name)) {
		for (usz idx = 0; idx < indices.len(); idx++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(idx));
			if (sym.name != class_name) continue;
			if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE) continue;

			// Search each supertype for the method declaration
			for (usz s = 0; s < sym.supertype_count; s++) {
				Object* loc = find_method_in_type(store, workspace, sym.supertypes[s], tok.text);
				if (loc != null) return loc;
			}
		}
	}

	return null;
}

/**
 * Find a method declaration in a type by name, searching workspace files.
 */
fn Object* find_method_in_type(DocumentStore* store, WorkspaceIndex* workspace, String type_name, String method_name) {
	if (try indices = workspace.lookup_by_name(type_name)) {
		for (usz idx = 0; idx < indices.len(); idx++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(idx));
			if (sym.name != type_name) continue;

			String super_uri = sym.uri;
			ParseResult* super_pr = store.get_ast(super_uri) ?? null;
			if (super_pr == null) continue;

			// Find matching method in supertype AST
			for (uint i = 1; i < super_pr.node_count; i++) {
				AstNode* n = &super_pr.nodes[i];
				if (n.kind != FUN_DECL) continue;
				if (n.name != method_name) continue;

				Object* start_pos = object::new_obj(tmem);
				start_pos.set("line", (int)n.name_line);
				start_pos.set("character", (int)n.name_col);

				Object* end_pos = object::new_obj(tmem);
				end_pos.set("line", (int)n.name_line);
				end_pos.set("character", (int)(n.name_col + (uint)n.name.len));

				Object* range = object::new_obj(tmem);
				range.set("start", start_pos);
				range.set("end", end_pos);

				Object* location = object::new_obj(tmem);
				location.set("uri", super_uri);
				location.set("range", range);
				return location;
			}
		}
	}
	return null;
}
