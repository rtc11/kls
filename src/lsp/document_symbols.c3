module kls::lsp::document_symbols;

import std::collections::object;
import kls::document;
import kls::kotlin::symbols;

const usz MAX_SYMBOLS = 512;

/**
 * Handle textDocument/documentSymbol request.
 * Returns an array of DocumentSymbol objects representing declarations
 * found in the document, or null if the document is unknown.
 *
 * Uses the lexer-based symbol scanner -- returns a flat list (no children).
 */
fn Object* handle_document_symbol(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	Symbol[MAX_SYMBOLS] sym_buf;
	usz sym_count = symbols::scan_declarations(doc.content, &sym_buf);

	Object* result = object::new_obj(tmem);  // JSON array
	for (usz i = 0; i < sym_count; i++) {
		result.push(build_document_symbol(sym_buf[i]));
	}

	return result;
}

/**
 * Build a single DocumentSymbol JSON object from a Symbol.
 *
 * DocumentSymbol {
 *   name: string,
 *   kind: SymbolKind (number),
 *   range: Range,
 *   selectionRange: Range
 * }
 *
 * Both range and selectionRange cover the symbol name span, since the
 * scanner only captures name token positions (not full declaration spans).
 */
fn Object* build_document_symbol(Symbol sym) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)sym.line);
	start.set("character", (int)sym.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)sym.line);
	end_pos.set("character", (int)(sym.col + sym.len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	// selectionRange is the same as range (name span only)
	Object* sel_start = object::new_obj(tmem);
	sel_start.set("line", (int)sym.line);
	sel_start.set("character", (int)sym.col);

	Object* sel_end = object::new_obj(tmem);
	sel_end.set("line", (int)sym.line);
	sel_end.set("character", (int)(sym.col + sym.len));

	Object* sel_range = object::new_obj(tmem);
	sel_range.set("start", sel_start);
	sel_range.set("end", sel_end);

	Object* ds = object::new_obj(tmem);
	ds.set("name", sym.name);
	ds.set("kind", to_lsp_symbol_kind(sym.kind));
	ds.set("range", range);
	ds.set("selectionRange", sel_range);

	return ds;
}

/**
 * Map internal SymbolKind to LSP SymbolKind number.
 *
 * LSP SymbolKind values used:
 *   Module    = 2
 *   Class     = 5
 *   Property  = 7
 *   Interface = 11
 *   Function  = 12
 */
fn int to_lsp_symbol_kind(SymbolKind kind) {
	switch (kind) {
		case FUNCTION:  return 12;
		case CLASS:     return 5;
		case INTERFACE: return 11;
		case OBJECT:    return 2;   // Module
		case PROPERTY:  return 7;
		case TYPEALIAS: return 5;   // Class (no TypeAlias in LSP)
	}
}
