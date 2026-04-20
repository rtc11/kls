module kls::lsp::semantic_tokens;

import std::collections::object;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::log;

// Maximum tokens we'll encode per document.
const usz MAX_TOKENS = 16384;
const usz MAX_NAME_ENTRIES = 4096;

// Type parameter scope entry for classifying type param uses
const usz MAX_TYPE_PARAMS = 128;

struct TypeParamScope {
	String name;
	uint scope_start;  // owner declaration start offset
	uint scope_end;    // owner declaration end offset
}

// ── Semantic token type legend (indices) ───────────────────────────
// These indices must match the tokenTypes array in build_semantic_tokens_options().
const int TT_KEYWORD       = 0;
const int TT_MODIFIER      = 1;
const int TT_VARIABLE      = 2;
const int TT_STRING        = 3;
const int TT_NUMBER        = 4;
const int TT_COMMENT       = 5;
const int TT_OPERATOR      = 6;
const int TT_PROPERTY      = 7;
const int TT_FUNCTION      = 8;
const int TT_CLASS         = 9;
const int TT_INTERFACE     = 10;
const int TT_ENUM_MEMBER   = 11;
const int TT_TYPE          = 12;
const int TT_PARAMETER     = 13;
const int TT_TYPE_PARAMETER = 14;

// Number of token types in the legend.
const usz TOKEN_TYPE_COUNT = 15;

// Token type names (must match indices above).
const String[TOKEN_TYPE_COUNT] TOKEN_TYPE_NAMES = {
	"keyword",
	"modifier",
	"variable",
	"string",
	"number",
	"comment",
	"operator",
	"property",
	"function",
	"class",
	"interface",
	"enumMember",
	"type",
	"parameter",
	"typeParameter",
};

// No modifiers for now.
const usz TOKEN_MODIFIER_COUNT = 5;

// Semantic token modifier legend (bitmask indices)
const int TM_DECLARATION = 0;  // 1 << 0
const int TM_READONLY    = 1;  // 1 << 1
const int TM_STATIC      = 2;  // 1 << 2
const int TM_DEPRECATED  = 3;  // 1 << 3
const int TM_ABSTRACT    = 4;  // 1 << 4

const String[TOKEN_MODIFIER_COUNT] TOKEN_MODIFIER_NAMES = {
	"declaration",
	"readonly",
	"static",
	"deprecated",
	"abstract",
};

/**
 * Entry mapping a source offset to a semantic token type,
 * derived from AST declaration name positions.
 */
struct NameEntry {
	uint offset;
	int token_type;
	int modifiers;  // bitmask of TM_* values
}

/**
 * Build a lookup table of (offset -> semantic token type) from the AST.
 * Includes both declaration names and expression identifiers.
 * Returns the number of entries written.
 */
fn usz build_name_table(ParseResult* pr, NameEntry[] table) {
	usz count = 0;

	// Pass 1: declaration names (highest priority)
	for (uint i = 0; i < pr.node_count && count < table.len; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name.len == 0 || n.name_len == 0) continue;

		int tt;
		switch (n.kind) {
			case FUN_DECL:              tt = TT_FUNCTION;
			case CLASS_DECL:            tt = TT_CLASS;
			case INTERFACE_DECL:        tt = TT_INTERFACE;
			case OBJECT_DECL:           tt = TT_CLASS;
			case COMPANION_OBJECT_DECL: tt = TT_CLASS;
			case PROPERTY_DECL:         tt = TT_PROPERTY;
			case TYPEALIAS_DECL:        tt = TT_TYPE;
			case CONSTRUCTOR_DECL:      tt = TT_FUNCTION;
			case ENUM_ENTRY:            tt = TT_ENUM_MEMBER;
			case PARAM:                 tt = TT_PARAMETER;
			case TYPE_PARAM:            tt = TT_TYPE_PARAMETER;
			default:                    continue;
		}

		table[count].offset = n.name_offset;
		table[count].token_type = tt;
		table[count].modifiers = compute_modifiers(n);
		count++;
	}

	// Pass 2: call expressions (function calls override variable/property)
	for (uint i = 0; i < pr.node_count && count < table.len; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name.len == 0 || n.name_len == 0) continue;

		int tt;
		switch (n.kind) {
			case CALL_EXPR:             tt = TT_FUNCTION;
			case CALLABLE_REF_EXPR:     tt = TT_FUNCTION;
			default:                    continue;
		}

		// Skip if this offset is already classified
		if (lookup_name(table[..], count, n.name_offset) >= 0) continue;

		table[count].offset = n.name_offset;
		table[count].token_type = tt;
		table[count].modifiers = 0; // usage sites get no declaration modifiers
		count++;
	}

	// Pass 3: dot access expressions (property access, lower priority than calls)
	for (uint i = 0; i < pr.node_count && count < table.len; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name.len == 0 || n.name_len == 0) continue;
		if (n.kind != DOT_EXPR) continue;

		// Skip if this offset is already classified (e.g. by CALL_EXPR)
		if (lookup_name(table[..], count, n.name_offset) >= 0) continue;

		table[count].offset = n.name_offset;
		table[count].token_type = TT_PROPERTY;
		count++;
	}

	// Pass 4: type parameter uses -- identifiers matching TYPE_PARAM names in scope
	// Collect all type parameter names and their parent scope ranges
	for (uint i = 0; i < pr.node_count && count < table.len; i++) {
		AstNode* tp = &pr.nodes[i];
		if (tp.kind != TYPE_PARAM || tp.name.len == 0) continue;

		// Find the parent declaration (CLASS_DECL, FUN_DECL, etc.) that owns this type param
		if (tp.parent == ast::NO_PARENT) continue;
		AstNode* owner = &pr.nodes[tp.parent];
		String tp_name = tp.name;

		// Scan all NAME_EXPR and TYPE_ARG nodes for matching identifiers within the owner scope
		for (uint j = 0; j < pr.node_count && count < table.len; j++) {
			AstNode* n = &pr.nodes[j];
			if (n.name != tp_name) continue;
			if (n.name_len == 0) continue;
			// Skip the declaration itself
			if (n.name_offset == tp.name_offset) continue;
			// Must be within owner scope
			if (n.start_offset < owner.start_offset || n.start_offset >= owner.end_offset) continue;

			// Only classify NAME_EXPR and TYPE_ARG nodes
			if (n.kind != NAME_EXPR && n.kind != TYPE_ARG) continue;

			// Skip if already classified
			if (lookup_name(table[..], count, n.name_offset) >= 0) continue;

			table[count].offset = n.name_offset;
			table[count].token_type = TT_TYPE_PARAMETER;
			count++;
		}
	}

	return count;
}

/**
 * Look up an offset in the name table. Returns the token type or -1.
 */
fn int lookup_name(NameEntry[] table, usz count, uint offset) {
	for (usz i = 0; i < count; i++) {
		if (table[i].offset == offset) {
			return table[i].token_type;
		}
	}
	return -1;
}

/**
 * Look up a name entry by offset. Returns index into table, or -1 if not found.
 */
fn int lookup_name_index(NameEntry[] table, usz count, uint offset) {
	for (usz i = 0; i < count; i++) {
		if (table[i].offset == offset) {
			return (int)i;
		}
	}
	return -1;
}

/**
 * Compute semantic token modifier bitmask from an AST node's properties.
 */
fn int compute_modifiers(AstNode* n) {
	int mods = 0;

	// All declaration names get the "declaration" modifier
	if (ast::is_declaration(n.kind)) {
		mods |= (1 << TM_DECLARATION);
	}

	// val (not var) properties and const are readonly
	if (n.kind == PROPERTY_DECL && (n.mod_flags & ast::MOD_VAR) == 0) {
		mods |= (1 << TM_READONLY);
	}
	if (n.mod_flags & ast::MOD_CONST != 0) {
		mods |= (1 << TM_READONLY);
	}

	// Companion object members are static-like
	if (n.kind == COMPANION_OBJECT_DECL || (n.mod_flags & ast::MOD_COMPANION) != 0) {
		mods |= (1 << TM_STATIC);
	}

	// @Deprecated annotation
	if (n.annotation_text.len > 0 && n.has_annotation("Deprecated")) {
		mods |= (1 << TM_DEPRECATED);
	}

	// Abstract modifier
	if (n.mod_flags & ast::MOD_ABSTRACT != 0) {
		mods |= (1 << TM_ABSTRACT);
	}

	return mods;
}

/**
 * Build a table of type parameter names with their owner scope ranges.
 * Used to classify IDENTIFIER tokens as type parameters even when they
 * appear in positions not captured by the AST (e.g., type annotations).
 */
fn usz build_type_param_scopes(ParseResult* pr, TypeParamScope[] table) {
	usz count = 0;
	for (uint i = 0; i < pr.node_count && count < table.len; i++) {
		AstNode* tp = &pr.nodes[i];
		if (tp.kind != TYPE_PARAM || tp.name.len == 0) continue;
		if (tp.parent == ast::NO_PARENT) continue;

		AstNode* owner = &pr.nodes[tp.parent];
		table[count].name = tp.name;
		table[count].scope_start = owner.start_offset;
		table[count].scope_end = owner.end_offset;
		count++;
	}
	return count;
}

/**
 * Check if an identifier at the given offset matches a type parameter in scope.
 */
fn bool is_type_param_use(TypeParamScope[] table, usz count, String name, uint offset) {
	for (usz i = 0; i < count; i++) {
		if (table[i].name == name && offset >= table[i].scope_start && offset < table[i].scope_end) {
			return true;
		}
	}
	return false;
}

/**
 * Handle textDocument/semanticTokens/full request.
 * Returns a SemanticTokens object { data: [...] } or null if unknown doc.
 */
fn Object*? handle_semantic_tokens_full(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	Object* result = encode_semantic_tokens(doc.content, pr, 0, uint.max);

	// Cache the result data for delta support
	cache_result_data(doc, result);

	return result;
}

// ── textDocument/semanticTokens/range ─────────────────────────────

/**
 * Handle textDocument/semanticTokens/range request.
 * Returns tokens only within the requested line range.
 */
fn Object*? handle_semantic_tokens_range(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) return null;

	// Extract range
	Object* range = params.get("range")!;
	Object* range_start = range.get("start")!;
	Object* range_end = range.get("end")!;
	uint start_line = (uint)range_start.get_int("line")!;
	uint end_line = (uint)range_end.get_int("line")!;

	return encode_semantic_tokens(doc.content, pr, start_line, end_line);
}

// ── textDocument/semanticTokens/full/delta ────────────────────────

/**
 * Handle textDocument/semanticTokens/full/delta request.
 * If previousResultId matches cached data, returns a SemanticTokensDelta
 * with minimal edits. Otherwise falls back to full response.
 */
fn Object*? handle_semantic_tokens_delta(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) return null;

	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) return null;

	// Compute new tokens
	Object* new_result = encode_semantic_tokens(doc.content, pr, 0, uint.max);
	Object* new_data = new_result.get("data")!;

	// Check for previous result
	String prev_id_str = "";
	if (try pid = params.get_string("previousResultId")) {
		prev_id_str = pid;
	}

	SemanticTokensCache* cached = doc.cached_semantic;
	if (cached != null && prev_id_str.len > 0) {
		// Parse previous result ID
		int prev_id = 0;
		bool parsed_ok = false;
		if (try v = prev_id_str.to_int()) {
			prev_id = v;
			parsed_ok = true;
		}

		if (parsed_ok && prev_id == cached.result_id) {
			// Compute delta between cached and new
			// Extract new data as int array (heap-allocated, too large for stack)
			usz new_len = new_data.get_len();
			int* new_ints = mem::alloc_array(int, document::MAX_SEMANTIC_DATA);
			defer mem::free(new_ints);
			usz new_int_count = 0;
			for (usz i = 0; i < new_len && i < document::MAX_SEMANTIC_DATA; i++) {
				new_ints[i] = new_data.get_int_at((sz)i) ?? 0;
				new_int_count++;
			}

			// Find first difference
			usz min_len = cached.data_len < new_int_count ? cached.data_len : new_int_count;
			usz first_diff = min_len;
			for (usz i = 0; i < min_len; i++) {
				if (cached.data[i] != new_ints[i]) {
					first_diff = i;
					break;
				}
			}

			// Find last matching suffix
			usz old_tail = cached.data_len;
			usz new_tail = new_int_count;
			while (old_tail > first_diff && new_tail > first_diff) {
				if (cached.data[old_tail - 1] != new_ints[new_tail - 1]) break;
				old_tail--;
				new_tail--;
			}

			// Cache new result
			cache_result_data(doc, new_result);

			// If no differences, return empty edits
			if (first_diff == old_tail && first_diff == new_tail) {
				Object* delta = object::new_obj(tmem);
				DString rid;
				rid.tinit();
				rid.appendf("%d", doc.cached_semantic.result_id);
				delta.set("resultId", rid.str_view());
				Object* edits = object::new_obj(tmem);
				delta.set("edits", edits);
				return delta;
			}

			// Build single edit
			Object* edit = object::new_obj(tmem);
			edit.set("start", (int)first_diff);
			edit.set("deleteCount", (int)(old_tail - first_diff));

			Object* edit_data = object::new_obj(tmem);
			for (usz i = first_diff; i < new_tail; i++) {
				edit_data.push(object::new_int(new_ints[i], tmem));
			}
			edit.set("data", edit_data);

			Object* edits = object::new_obj(tmem);
			edits.push(edit);

			Object* delta = object::new_obj(tmem);
			DString rid;
			rid.tinit();
			rid.appendf("%d", doc.cached_semantic.result_id);
			delta.set("resultId", rid.str_view());
			delta.set("edits", edits);

			log::debug("[semanticTokens] delta: start=%d deleteCount=%d insertCount=%d",
				(int)first_diff, (int)(old_tail - first_diff), (int)(new_tail - first_diff));

			return delta;
		}
	}

	// Fallback: return full result
	cache_result_data(doc, new_result);
	return new_result;
}

// ── Cache helpers ─────────────────────────────────────────────────

/**
 * Global result ID counter for semantic tokens delta support.
 */
int g_next_result_id = 1;

/**
 * Cache the semantic token data array from a result object into the document.
 * Assigns a new resultId and sets it on the result object.
 */
fn void cache_result_data(Document* doc, Object* result) {
	if (doc.cached_semantic == null) {
		doc.cached_semantic = mem::new(SemanticTokensCache);
	}

	SemanticTokensCache* cache = doc.cached_semantic;
	cache.result_id = g_next_result_id++;
	cache.data_len = 0;

	Object* data = result.get("data") ?? null;
	if (data != null) {
		usz len = data.get_len();
		for (usz i = 0; i < len && i < document::MAX_SEMANTIC_DATA; i++) {
			cache.data[i] = data.get_int_at((sz)i) ?? 0;
			cache.data_len++;
		}
	}

	// Set resultId on the response
	DString rid;
	rid.tinit();
	rid.appendf("%d", cache.result_id);
	result.set("resultId", rid.str_view());
}

/**
 * Lex the content and encode all semantic tokens as a delta-encoded
 * integer array per the LSP spec.  Uses the parser AST to classify
 * identifiers at declaration name positions (function, class, etc.).
 *
 * Each token is 5 integers: deltaLine, deltaStart, length, tokenType, tokenModifiers.
 *
 * Returns a SemanticTokens object: { "data": [ ... ] }
 */
fn Object* encode_semantic_tokens(String content, ParseResult* pr, uint start_line, uint end_line) {
	Object* data = object::new_obj(tmem); // JSON array

	if (content.len == 0) {
		Object* result = object::new_obj(tmem);
		result.set("data", data);
		return result;
	}

	// Build AST name table for identifier classification
	NameEntry[MAX_NAME_ENTRIES] name_table;
	usz name_count = build_name_table(pr, &name_table);

	// Build type parameter scope table for classifying uses in type positions
	TypeParamScope[MAX_TYPE_PARAMS] tp_scopes;
	usz tp_count = build_type_param_scopes(pr, &tp_scopes);

	Lexer lex = lexer::init(content);
	uint prev_line = 0;
	uint prev_col = 0;

	usz token_count = 0;
	while (token_count < MAX_TOKENS) {
		Token tok = lex.next_all();
		if (tok.kind == EOF) break;

		// Range filtering: skip tokens before start_line, stop after end_line
		if (tok.line > end_line) break;
		if (tok.line < start_line) {
			// Still need to track prev_line/prev_col for tokens we might emit later
			// that are on the boundary. But since we skip, we only need to update
			// if we have NOT emitted anything yet.
			continue;
		}

		int token_type = map_token_type(tok.kind);

		// For identifiers, check if this is a declaration name or type param use
		int token_modifiers = 0;
		if (tok.kind == IDENTIFIER && name_count > 0) {
			int name_idx = lookup_name_index(name_table[..], name_count, tok.offset);
			if (name_idx >= 0) {
				token_type = name_table[name_idx].token_type;
				token_modifiers = name_table[name_idx].modifiers;
			} else if (tp_count > 0 && is_type_param_use(tp_scopes[..], tp_count, tok.text, tok.offset)) {
				token_type = TT_TYPE_PARAMETER;
			}
		}

		if (token_type < 0) {
			// Skip tokens with no semantic mapping (whitespace, newline, error)
			continue;
		}

		// Compute deltas
		uint delta_line = tok.line - prev_line;
		uint delta_start;
		if (delta_line == 0) {
			// Same line: delta relative to previous token start
			delta_start = tok.col - prev_col;
		} else {
			// Different line: absolute column
			delta_start = tok.col;
		}

		data.push(object::new_int((int)delta_line, tmem));
		data.push(object::new_int((int)delta_start, tmem));
		data.push(object::new_int((int)tok.len, tmem));
		data.push(object::new_int(token_type, tmem));
		data.push(object::new_int(token_modifiers, tmem));

		prev_line = tok.line;
		prev_col = tok.col;
		token_count++;
	}

	Object* result = object::new_obj(tmem);
	result.set("data", data);
	return result;
}

/**
 * Map a TokenKind to a semantic token type index.
 * Returns -1 if the token should be skipped (whitespace, newline, error, EOF).
 */
fn int map_token_type(TokenKind kind) {
	switch (kind) {
		// Skip non-semantic tokens
		case EOF:        return -1;
		case ERROR:      return -1;
		case WHITESPACE: return -1;
		case NEWLINE:    return -1;

		// Comments
		case LINE_COMMENT:  return TT_COMMENT;
		case BLOCK_COMMENT: return TT_COMMENT;

		// String-related
		case STRING_OPEN:           return TT_STRING;
		case STRING_CLOSE:          return TT_STRING;
		case STRING_CONTENT:        return TT_STRING;
		case STRING_TEMPLATE_REF:   return TT_STRING;
		case STRING_TEMPLATE_START: return TT_STRING;
		case MULTILINE_STRING_OPEN:  return TT_STRING;
		case MULTILINE_STRING_CLOSE: return TT_STRING;
		case CHARACTER_LITERAL:     return TT_STRING;

		// Number literals
		case INTEGER_LITERAL: return TT_NUMBER;
		case FLOAT_LITERAL:   return TT_NUMBER;
		case BOOLEAN_LITERAL: return TT_KEYWORD;  // true/false are keyword-like
		case NULL_LITERAL:    return TT_KEYWORD;

		// Identifiers
		case IDENTIFIER: return TT_VARIABLE;

		// Hard keywords
		case KW_PACKAGE:     return TT_KEYWORD;
		case KW_IMPORT:      return TT_KEYWORD;
		case KW_CLASS:       return TT_KEYWORD;
		case KW_INTERFACE:   return TT_KEYWORD;
		case KW_FUN:         return TT_KEYWORD;
		case KW_OBJECT:      return TT_KEYWORD;
		case KW_VAL:         return TT_KEYWORD;
		case KW_VAR:         return TT_KEYWORD;
		case KW_TYPEALIAS:   return TT_KEYWORD;
		case KW_CONSTRUCTOR: return TT_KEYWORD;
		case KW_BY:          return TT_KEYWORD;
		case KW_COMPANION:   return TT_KEYWORD;
		case KW_INIT:        return TT_KEYWORD;
		case KW_THIS:        return TT_KEYWORD;
		case KW_SUPER:       return TT_KEYWORD;
		case KW_TYPEOF:      return TT_KEYWORD;
		case KW_WHERE:       return TT_KEYWORD;
		case KW_IF:          return TT_KEYWORD;
		case KW_ELSE:        return TT_KEYWORD;
		case KW_WHEN:        return TT_KEYWORD;
		case KW_TRY:         return TT_KEYWORD;
		case KW_CATCH:       return TT_KEYWORD;
		case KW_FINALLY:     return TT_KEYWORD;
		case KW_FOR:         return TT_KEYWORD;
		case KW_DO:          return TT_KEYWORD;
		case KW_WHILE:       return TT_KEYWORD;
		case KW_THROW:       return TT_KEYWORD;
		case KW_RETURN:      return TT_KEYWORD;
		case KW_CONTINUE:    return TT_KEYWORD;
		case KW_BREAK:       return TT_KEYWORD;
		case KW_AS:          return TT_KEYWORD;
		case KW_IS:          return TT_KEYWORD;
		case KW_IN:          return TT_KEYWORD;
		case KW_OUT:         return TT_KEYWORD;
		case KW_DYNAMIC:     return TT_KEYWORD;

		// Soft keywords (modifiers)
		case KW_ABSTRACT:    return TT_MODIFIER;
		case KW_ANNOTATION:  return TT_MODIFIER;
		case KW_DATA:        return TT_MODIFIER;
		case KW_ENUM:        return TT_MODIFIER;
		case KW_EXTERNAL:    return TT_MODIFIER;
		case KW_FINAL:       return TT_MODIFIER;
		case KW_INFIX:       return TT_MODIFIER;
		case KW_INLINE:      return TT_MODIFIER;
		case KW_INNER:       return TT_MODIFIER;
		case KW_INTERNAL:    return TT_MODIFIER;
		case KW_LATEINIT:    return TT_MODIFIER;
		case KW_NOINLINE:    return TT_MODIFIER;
		case KW_OPEN:        return TT_MODIFIER;
		case KW_OPERATOR:    return TT_MODIFIER;
		case KW_OVERRIDE:    return TT_MODIFIER;
		case KW_PRIVATE:     return TT_MODIFIER;
		case KW_PROTECTED:   return TT_MODIFIER;
		case KW_PUBLIC:      return TT_MODIFIER;
		case KW_REIFIED:     return TT_MODIFIER;
		case KW_SEALED:      return TT_MODIFIER;
		case KW_SUSPEND:     return TT_MODIFIER;
		case KW_TAILREC:     return TT_MODIFIER;
		case KW_VARARG:      return TT_MODIFIER;
		case KW_CROSSINLINE: return TT_MODIFIER;
		case KW_CONST:       return TT_MODIFIER;
		case KW_EXPECT:      return TT_MODIFIER;
		case KW_ACTUAL:      return TT_MODIFIER;
		case KW_VALUE:       return TT_MODIFIER;

		// Soft keywords (property/accessor)
		case KW_GET:      return TT_PROPERTY;
		case KW_SET:      return TT_PROPERTY;
		case KW_FIELD:    return TT_PROPERTY;
		case KW_PROPERTY: return TT_PROPERTY;
		case KW_RECEIVER: return TT_PROPERTY;
		case KW_PARAM:    return TT_PROPERTY;
		case KW_SETPARAM: return TT_PROPERTY;
		case KW_DELEGATE: return TT_PROPERTY;
		case KW_FILE:     return TT_PROPERTY;

		// Operators and punctuation
		case DOT:          return TT_OPERATOR;
		case COMMA:        return TT_OPERATOR;
		case LPAREN:       return TT_OPERATOR;
		case RPAREN:       return TT_OPERATOR;
		case LSQUARE:      return TT_OPERATOR;
		case RSQUARE:      return TT_OPERATOR;
		case LCURL:        return TT_OPERATOR;
		case RCURL:        return TT_OPERATOR;
		case MULT:         return TT_OPERATOR;
		case MOD:          return TT_OPERATOR;
		case DIV:          return TT_OPERATOR;
		case ADD:          return TT_OPERATOR;
		case SUB:          return TT_OPERATOR;
		case INCR:         return TT_OPERATOR;
		case DECR:         return TT_OPERATOR;
		case CONJ:         return TT_OPERATOR;
		case DISJ:         return TT_OPERATOR;
		case EXCL:         return TT_OPERATOR;
		case COLON:        return TT_OPERATOR;
		case SEMICOLON:    return TT_OPERATOR;
		case ASSIGNMENT:   return TT_OPERATOR;
		case ADD_ASSIGN:   return TT_OPERATOR;
		case SUB_ASSIGN:   return TT_OPERATOR;
		case MULT_ASSIGN:  return TT_OPERATOR;
		case DIV_ASSIGN:   return TT_OPERATOR;
		case MOD_ASSIGN:   return TT_OPERATOR;
		case ARROW:        return TT_OPERATOR;
		case DOUBLE_ARROW: return TT_OPERATOR;
		case RANGE:        return TT_OPERATOR;
		case RANGE_UNTIL:  return TT_OPERATOR;
		case COLONCOLON:   return TT_OPERATOR;
		case HASH:         return TT_OPERATOR;
		case AT:           return TT_OPERATOR;
		case QUEST:        return TT_OPERATOR;
		case SAFE_CALL:    return TT_OPERATOR;
		case ELVIS:        return TT_OPERATOR;
		case NOT_NULL:     return TT_OPERATOR;
		case LANGLE:       return TT_OPERATOR;
		case RANGLE:       return TT_OPERATOR;
		case LE:           return TT_OPERATOR;
		case GE:           return TT_OPERATOR;
		case EXCL_EQ:      return TT_OPERATOR;
		case EXCL_EQEQ:    return TT_OPERATOR;
		case EQEQ:         return TT_OPERATOR;
		case EQEQEQ:       return TT_OPERATOR;
		case AS_SAFE:      return TT_OPERATOR;
		case NOT_IS:       return TT_OPERATOR;
		case NOT_IN:       return TT_OPERATOR;

		default: return -1;
	}
}

/**
 * Build the semanticTokensProvider capability options for initialize.
 * Returns a JSON object suitable for the "semanticTokensProvider" key.
 */
fn Object* build_semantic_tokens_options() {
	Object* legend = object::new_obj(tmem);

	// tokenTypes array
	Object* types = object::new_obj(tmem);
	for (usz i = 0; i < TOKEN_TYPE_COUNT; i++) {
		types.push(object::new_string(TOKEN_TYPE_NAMES[i], tmem));
	}
	legend.set("tokenTypes", types);

	// tokenModifiers array
	Object* modifiers = object::new_obj(tmem);
	for (usz i = 0; i < TOKEN_MODIFIER_COUNT; i++) {
		modifiers.push(object::new_string(TOKEN_MODIFIER_NAMES[i], tmem));
	}
	legend.set("tokenModifiers", modifiers);

	Object* opts = object::new_obj(tmem);
	opts.set("legend", legend);

	// Full with delta support
	Object* full_opts = object::new_obj(tmem);
	full_opts.set("delta", true);
	opts.set("full", full_opts);

	// Range support
	opts.set("range", true);

	return opts;
}
