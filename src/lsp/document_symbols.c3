module kls::lsp::document_symbols;

import std::collections::object;
import kls::document;
import kls::kotlin::ast;

/**
 * Handle textDocument/documentSymbol request.
 * Returns a hierarchical array of DocumentSymbol objects built from the
 * parser AST.  Returns null if the document is unknown.
 */
fn Object*? handle_document_symbol(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	// Build the result array from FILE node's direct children
	Object* result = object::new_obj(tmem);

	if (pr.node_count == 0) {
		return result;
	}

	// FILE is always node 0; walk its direct children
	AstNode* file = &pr.nodes[0];
	for (uint i = 0; i < file.child_count; i++) {
		AstNode* child = ast::get_child(pr, file, i)!!;
		// Only emit declaration nodes as symbols
		if (ast::is_declaration(child.kind)) {
			Object* sym = build_document_symbol_from_node(pr, child);
			if (sym != null) {
				result.push(sym);
			}
		}
	}

	return result;
}

/**
 * Build a DocumentSymbol JSON object from an AST node, recursively
 * including children for container declarations (classes, interfaces,
 * objects, companion objects).
 *
 * DocumentSymbol {
 *   name: string,
 *   kind: SymbolKind,
 *   range: Range,          // full span of the declaration
 *   selectionRange: Range, // span of the name token
 *   children?: DocumentSymbol[]
 * }
 */
fn Object* build_document_symbol_from_node(ParseResult* pr, AstNode* node) {
	// Skip unnamed nodes
	if (node.name.len == 0) {
		return null;
	}

	int lsp_kind = ast::to_lsp_symbol_kind(node.kind);
	if (lsp_kind == 0) {
		return null;
	}

	// range: full declaration span
	Object* range_start = object::new_obj(tmem);
	range_start.set("line", (int)node.start_line);
	range_start.set("character", (int)node.start_col);

	Object* range_end = object::new_obj(tmem);
	range_end.set("line", (int)node.end_line);
	range_end.set("character", (int)node.end_col);

	Object* range = object::new_obj(tmem);
	range.set("start", range_start);
	range.set("end", range_end);

	// selectionRange: name token span
	Object* sel_start = object::new_obj(tmem);
	sel_start.set("line", (int)node.name_line);
	sel_start.set("character", (int)node.name_col);

	Object* sel_end = object::new_obj(tmem);
	sel_end.set("line", (int)node.name_line);
	sel_end.set("character", (int)(node.name_col + node.name_len));

	Object* sel_range = object::new_obj(tmem);
	sel_range.set("start", sel_start);
	sel_range.set("end", sel_end);

	Object* ds = object::new_obj(tmem);
	ds.set("name", node.name);
	ds.set("kind", lsp_kind);
	ds.set("range", range);
	ds.set("selectionRange", sel_range);

	// Recursively add children for container declarations
	if (node.child_count > 0 && is_container(node.kind)) {
		Object* children = object::new_obj(tmem);
		for (uint i = 0; i < node.child_count; i++) {
			AstNode* child = ast::get_child(pr, node, i)!!;
			if (ast::is_declaration(child.kind)) {
				Object* child_sym = build_document_symbol_from_node(pr, child);
				if (child_sym != null) {
					children.push(child_sym);
				}
			}
		}
		if (children.get_len() > 0) {
			ds.set("children", children);
		}
	}

	return ds;
}

/**
 * Check if a node kind can contain child declarations.
 */
fn bool is_container(NodeKind kind) {
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
