module kls::lsp::semantic_tokens;

import std::collections::object;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

// Maximum tokens we'll encode per document.
const usz MAX_TOKENS = 16384;

// Maximum AST name positions we'll track for identifier classification.
const usz MAX_NAME_ENTRIES = 4096;

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
const usz TOKEN_MODIFIER_COUNT = 0;

/**
 * Entry mapping a source offset to a semantic token type,
 * derived from AST declaration name positions.
 */
struct NameEntry {
	uint offset;
	int token_type;
}

/**
 * Build a lookup table of (offset -> semantic token type) from the AST.
 * Returns the number of entries written.
 */
fn usz build_name_table(ParseResult* pr, NameEntry[] table) {
	usz count = 0;
	for (usz i = 0; i < pr.node_count && count < table.len; i++) {
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
		count++;
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
 * Handle textDocument/semanticTokens/full request.
 * Returns a SemanticTokens object { data: [...] } or null if unknown doc.
 */
fn Object* handle_semantic_tokens_full(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	return encode_semantic_tokens(doc.content, pr);
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
fn Object* encode_semantic_tokens(String content, ParseResult* pr) {
	Object* data = object::new_obj(tmem); // JSON array

	if (content.len == 0) {
		Object* result = object::new_obj(tmem);
		result.set("data", data);
		return result;
	}

	// Build AST name table for identifier classification
	NameEntry[MAX_NAME_ENTRIES] name_table;
	usz name_count = build_name_table(pr, &name_table);

	Lexer lex = lexer::init(content);
	uint prev_line = 0;
	uint prev_col = 0;

	usz token_count = 0;
	while (token_count < MAX_TOKENS) {
		Token tok = lex.next_all();
		if (tok.kind == EOF) break;

		int token_type = map_token_type(tok.kind);

		// For identifiers, check if this is a declaration name
		if (tok.kind == IDENTIFIER && name_count > 0) {
			int ast_type = lookup_name(name_table[..], name_count, tok.offset);
			if (ast_type >= 0) {
				token_type = ast_type;
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
		data.push(object::new_int(0, tmem)); // tokenModifiers: none

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
		case BOOLEAN_LITERAL: return TT_NUMBER;
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

	// tokenModifiers array (empty for now)
	Object* modifiers = object::new_obj(tmem);
	legend.set("tokenModifiers", modifiers);

	Object* opts = object::new_obj(tmem);
	opts.set("legend", legend);
	opts.set("full", true);

	return opts;
}
