module kls::kotlin::parser;

import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;

// ── Parser struct ──────────────────────────────────────────────────

struct Parser {
	String source;
	Lexer lexer;
	Token current;
	Token previous;
	ParseResult* result;
}

// ── Public entry point ─────────────────────────────────────────────

/**
 * Parse a complete Kotlin source file into the given ParseResult.
 * The result's node_count and error_count are reset to 0 before parsing.
 */
fn void parse(String source, ParseResult* result) {
	result.node_count = 0;
	result.error_count = 0;

	Parser p = {
		.source = source,
		.lexer = lexer::init(source),
		.result = result,
	};

	// Prime the parser with the first token
	p.current = p.lexer.next();

	p.parse_file();
}

// ── Core helpers ───────────────────────────────────────────────────

fn void Parser.advance(Parser* self) {
	self.previous = self.current;
	self.current = self.lexer.next();
}

fn bool Parser.at(Parser* self, TokenKind kind) @inline {
	return self.current.kind == kind;
}

fn bool Parser.at_eof(Parser* self) @inline {
	return self.current.kind == EOF;
}

fn bool Parser.eat(Parser* self, TokenKind kind) {
	if (self.current.kind == kind) {
		self.advance();
		return true;
	}
	return false;
}

fn void Parser.expect(Parser* self, TokenKind kind) {
	if (self.current.kind == kind) {
		self.advance();
		return;
	}
	DString msg;
	msg.tinit();
	msg.appendf("Expected '%s', got '%s'", token_name(kind), self.current.text);
	self.add_error(msg.str_view());
}

/**
 * Check if the current token can be treated as an identifier.
 * In Kotlin, soft keywords are valid identifiers in non-modifier positions.
 */
fn bool Parser.at_identifier(Parser* self) {
	return self.current.kind == IDENTIFIER || is_soft_keyword(self.current.kind);
}

/**
 * Consume the current token as an identifier (including soft keywords).
 * Returns the consumed token. Adds an error if current is not identifier-like.
 */
fn Token Parser.expect_identifier(Parser* self) {
	if (self.at_identifier()) {
		Token tok = self.current;
		self.advance();
		return tok;
	}
	DString msg;
	msg.tinit();
	msg.appendf("Expected identifier, got '%s'", self.current.text);
	self.add_error(msg.str_view());
	// Return a synthetic token
	return self.current;
}

fn usz Parser.add_node(Parser* self, NodeKind kind) {
	if (self.result.node_count >= ast::MAX_NODES) {
		return ast::MAX_NODES - 1; // saturate
	}
	usz idx = self.result.node_count;
	self.result.nodes[idx].kind = kind;
	self.result.nodes[idx].name = "";
	self.result.nodes[idx].type_text = "";
	self.result.nodes[idx].extra_text = "";
	self.result.nodes[idx].mod_flags = ast::MOD_NONE;
	self.result.nodes[idx].parent = ast::NO_PARENT;
	self.result.nodes[idx].child_count = 0;
	self.result.nodes[idx].start_offset = 0;
	self.result.nodes[idx].end_offset = 0;
	self.result.nodes[idx].start_line = 0;
	self.result.nodes[idx].start_col = 0;
	self.result.nodes[idx].end_line = 0;
	self.result.nodes[idx].end_col = 0;
	self.result.nodes[idx].name_offset = 0;
	self.result.nodes[idx].name_line = 0;
	self.result.nodes[idx].name_col = 0;
	self.result.nodes[idx].name_len = 0;
	self.result.node_count++;
	return idx;
}

/**
 * Adopt all unparented nodes in [start..node_count) as children of parent_idx.
 * Only nodes with parent == NO_PARENT become children (nested nodes already
 * have their parent set by inner parse calls).
 */
fn void Parser.adopt_children(Parser* self, usz parent_idx, usz start) {
	usz count = 0;
	for (usz i = start; i < self.result.node_count; i++) {
		if (self.result.nodes[i].parent == ast::NO_PARENT) {
			self.result.nodes[i].parent = parent_idx;
			count++;
		}
	}
	self.result.nodes[parent_idx].child_count = count;
}

fn void Parser.add_error(Parser* self, String message) {
	if (self.result.error_count >= ast::MAX_ERRORS) return;
	usz idx = self.result.error_count;
	self.result.errors[idx].message = message;
	self.result.errors[idx].line = self.current.line;
	self.result.errors[idx].col = self.current.col;
	self.result.errors[idx].offset = self.current.offset;
	self.result.errors[idx].len = self.current.len;
	self.result.error_count++;
}

/**
 * Set the start span of a node from a token.
 */
fn void Parser.node_start(Parser* self, usz idx, Token tok) {
	self.result.nodes[idx].start_offset = tok.offset;
	self.result.nodes[idx].start_line = tok.line;
	self.result.nodes[idx].start_col = tok.col;
}

/**
 * Set the end span of a node from the previous token (last consumed).
 */
fn void Parser.node_end(Parser* self, usz idx) {
	self.result.nodes[idx].end_offset = self.previous.offset + self.previous.len;
	self.result.nodes[idx].end_line = self.previous.line;
	self.result.nodes[idx].end_col = self.previous.col + self.previous.len;
}

/**
 * Set the end span of a node from the current token (not yet consumed).
 */
fn void Parser.node_end_at_current(Parser* self, usz idx) {
	self.result.nodes[idx].end_offset = self.current.offset + self.current.len;
	self.result.nodes[idx].end_line = self.current.line;
	self.result.nodes[idx].end_col = self.current.col + self.current.len;
}

/**
 * Set the name of a node from a token.
 */
fn void Parser.node_set_name(Parser* self, usz idx, Token tok) {
	self.result.nodes[idx].name = tok.text;
	self.result.nodes[idx].name_offset = tok.offset;
	self.result.nodes[idx].name_line = tok.line;
	self.result.nodes[idx].name_col = tok.col;
	self.result.nodes[idx].name_len = tok.len;
}

// ── File-level parsing ─────────────────────────────────────────────

fn void Parser.parse_file(Parser* self) {
	usz file_idx = self.add_node(FILE);
	self.node_start(file_idx, self.current);
	usz children_start = self.result.node_count;

	// Optional package declaration
	if (self.at(KW_PACKAGE)) {
		self.parse_package_decl();
	}

	// Import declarations
	while (self.at(KW_IMPORT)) {
		self.parse_import_decl();
	}

	// Top-level declarations
	while (!self.at_eof()) {
		uint mods = self.parse_modifiers();
		if (self.at_eof()) break;

		if (!self.parse_declaration(mods)) {
			// Could not parse a declaration -- skip token and try again
			if (!self.at_eof()) {
				self.add_error("Unexpected token at top level");
				self.advance();
			}
		}
	}

	self.adopt_children(file_idx, children_start);
	// End span: use previous token if we consumed anything, else current
	if (self.previous.len > 0) {
		self.node_end(file_idx);
	} else {
		self.result.nodes[file_idx].end_offset = 0;
		self.result.nodes[file_idx].end_line = 0;
		self.result.nodes[file_idx].end_col = 0;
	}
}

// ── Package declaration ────────────────────────────────────────────

fn void Parser.parse_package_decl(Parser* self) {
	usz idx = self.add_node(PACKAGE_DECL);
	self.node_start(idx, self.current);
	self.advance(); // consume 'package'

	// Parse dotted name: com.example.app
	uint path_start = self.current.offset;
	if (self.at_identifier()) {
		self.advance();
		while (self.eat(DOT)) {
			if (self.at_identifier()) {
				self.advance();
			} else {
				break;
			}
		}
	}
	uint path_end = self.previous.offset + self.previous.len;
	self.result.nodes[idx].extra_text = self.source[path_start:path_end - path_start];

	self.eat(SEMICOLON); // optional semicolon
	self.node_end(idx);
}

// ── Import declaration ─────────────────────────────────────────────

fn void Parser.parse_import_decl(Parser* self) {
	usz idx = self.add_node(IMPORT_DECL);
	self.node_start(idx, self.current);
	self.advance(); // consume 'import'

	// Parse dotted name: foo.bar.baz
	uint path_start = self.current.offset;
	if (self.at_identifier()) {
		self.advance();
		while (self.eat(DOT)) {
			if (self.eat(MULT)) {
				// Wildcard import: foo.bar.*
				break;
			}
			if (self.at_identifier()) {
				self.advance();
			} else {
				break;
			}
		}
	}
	uint path_end = self.previous.offset + self.previous.len;
	self.result.nodes[idx].extra_text = self.source[path_start:path_end - path_start];

	// Optional alias: as Name
	if (self.eat(KW_AS)) {
		Token alias_tok = self.expect_identifier();
		self.result.nodes[idx].name = alias_tok.text;
	}

	self.eat(SEMICOLON);
	self.node_end(idx);
}

// ── Modifiers ──────────────────────────────────────────────────────

fn uint Parser.parse_modifiers(Parser* self) {
	uint flags = ast::MOD_NONE;

	while (!self.at_eof()) {
		// Annotations
		if (self.at(AT)) {
			self.skip_annotation();
			continue;
		}

		switch (self.current.kind) {
			case KW_ABSTRACT:    flags |= ast::MOD_ABSTRACT;    self.advance();
			case KW_OPEN:        flags |= ast::MOD_OPEN;        self.advance();
			case KW_FINAL:       flags |= ast::MOD_FINAL;       self.advance();
			case KW_SEALED:      flags |= ast::MOD_SEALED;      self.advance();
			case KW_DATA:        flags |= ast::MOD_DATA;        self.advance();
			case KW_ENUM:        flags |= ast::MOD_ENUM;        self.advance();
			case KW_INNER:       flags |= ast::MOD_INNER;       self.advance();
			case KW_ANNOTATION:  flags |= ast::MOD_ANNOTATION;  self.advance();
			case KW_VALUE:       flags |= ast::MOD_VALUE;       self.advance();
			case KW_INLINE:      flags |= ast::MOD_INLINE;      self.advance();
			case KW_INFIX:       flags |= ast::MOD_INFIX;       self.advance();
			case KW_OPERATOR:    flags |= ast::MOD_OPERATOR;    self.advance();
			case KW_SUSPEND:     flags |= ast::MOD_SUSPEND;     self.advance();
			case KW_TAILREC:     flags |= ast::MOD_TAILREC;     self.advance();
			case KW_OVERRIDE:    flags |= ast::MOD_OVERRIDE;    self.advance();
			case KW_LATEINIT:    flags |= ast::MOD_LATEINIT;    self.advance();
			case KW_CONST:       flags |= ast::MOD_CONST;       self.advance();
			case KW_EXTERNAL:    flags |= ast::MOD_EXTERNAL;    self.advance();
			case KW_PRIVATE:     flags |= ast::MOD_PRIVATE;     self.advance();
			case KW_PROTECTED:   flags |= ast::MOD_PROTECTED;   self.advance();
			case KW_INTERNAL:    flags |= ast::MOD_INTERNAL;    self.advance();
			case KW_PUBLIC:      flags |= ast::MOD_PUBLIC;      self.advance();
			case KW_EXPECT:      flags |= ast::MOD_EXPECT;      self.advance();
			case KW_ACTUAL:      flags |= ast::MOD_ACTUAL;      self.advance();
			case KW_VARARG:      flags |= ast::MOD_VARARG;      self.advance();
			case KW_NOINLINE:    flags |= ast::MOD_NOINLINE;    self.advance();
			case KW_CROSSINLINE: flags |= ast::MOD_CROSSINLINE; self.advance();
			case KW_REIFIED:     flags |= ast::MOD_REIFIED;     self.advance();
			default:
				return flags;
		}
	}

	return flags;
}

/**
 * Skip an annotation: @Name or @Name(...).
 * Also handles use-site targets: @file:Name, @get:Name, etc.
 */
fn void Parser.skip_annotation(Parser* self) {
	self.advance(); // consume '@'

	// Consume the first identifier (annotation name or use-site target)
	if (self.at_identifier()) {
		self.advance();
	} else {
		return; // bare @ with no name
	}

	// If colon follows, the identifier was a use-site target (e.g. file:, get:)
	// and the real annotation name comes after
	if (self.eat(COLON)) {
		if (self.at_identifier()) {
			self.advance();
		}
	}

	// Dotted annotation name: @com.example.MyAnnotation
	while (self.eat(DOT)) {
		if (self.at_identifier()) {
			self.advance();
		}
	}

	// Skip annotation arguments
	if (self.at(LPAREN)) {
		self.skip_balanced_parens();
	}
}

// ── Declaration dispatch ───────────────────────────────────────────

/**
 * Try to parse a declaration with the given modifiers.
 * Returns true if a declaration was parsed, false otherwise.
 */
fn bool Parser.parse_declaration(Parser* self, uint mods) {
	switch (self.current.kind) {
		case KW_CLASS:
			self.parse_class_like(mods, CLASS_DECL);
			return true;

		case KW_INTERFACE:
			self.parse_class_like(mods, INTERFACE_DECL);
			return true;

		case KW_OBJECT:
			self.parse_class_like(mods, OBJECT_DECL);
			return true;

		case KW_FUN:
			self.parse_fun_decl(mods);
			return true;

		case KW_VAL:
			nextcase;
		case KW_VAR:
			self.parse_property_decl(mods);
			return true;

		case KW_TYPEALIAS:
			self.parse_typealias_decl(mods);
			return true;

		case KW_CONSTRUCTOR:
			self.parse_constructor_decl(mods);
			return true;

		case KW_INIT:
			self.parse_init_block();
			return true;

		case KW_COMPANION:
			self.parse_companion_object(mods);
			return true;

		default:
			return false;
	}
}

// ── Class-like declarations ────────────────────────────────────────

/**
 * Parse class / interface / object declaration.
 *
 * class Name<T>(val x: Int) : Super(), Iface { body }
 * interface Name<T> : Iface { body }
 * object Name : Iface { body }
 */
fn void Parser.parse_class_like(Parser* self, uint mods, NodeKind kind) {
	usz idx = self.add_node(kind);
	self.result.nodes[idx].mod_flags = mods;

	// Start span from the keyword (or earlier if modifiers present, but
	// we use keyword start -- the caller could adjust)
	self.node_start(idx, self.current);
	self.advance(); // consume class/interface/object

	// Name (objects may be anonymous in some expression contexts, but
	// at declaration level they should have a name)
	if (self.at_identifier()) {
		Token name = self.expect_identifier();
		self.node_set_name(idx, name);
	}

	usz children_start = self.result.node_count;

	// Type parameters: <T, R>
	if (self.at(LANGLE)) {
		self.parse_type_params();
	}

	// Primary constructor for classes: (val x: Int, var y: String)
	if (kind == CLASS_DECL && self.at(LPAREN)) {
		self.parse_primary_constructor();
	}

	// Super types: : SuperClass(), Interface
	if (self.at(COLON)) {
		self.skip_super_types();
	}

	// Where clause: where T : Comparable<T>
	if (self.at(KW_WHERE)) {
		self.skip_where_clause();
	}

	// Class body
	if (self.at(LCURL)) {
		self.parse_class_body(mods & ast::MOD_ENUM != 0);
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Function declaration ───────────────────────────────────────────

/**
 * Parse function declaration.
 *
 * fun name(params): ReturnType { body }
 * fun <T> name(params): ReturnType { body }
 * fun Receiver.name(params): ReturnType { body }
 * fun <T> Receiver<T>.name(params): ReturnType { body }
 */
fn void Parser.parse_fun_decl(Parser* self, uint mods) {
	usz idx = self.add_node(FUN_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.node_start(idx, self.current);
	self.advance(); // consume 'fun'

	usz children_start = self.result.node_count;

	// Type parameters: <T>
	if (self.at(LANGLE)) {
		self.parse_type_params();
	}

	// Name or Receiver.name
	if (self.at_identifier()) {
		Token first_name = self.expect_identifier();

		// Check for receiver: if DOT follows, first_name was the receiver type
		if (self.at(LANGLE)) {
			// Could be Receiver<T>.name
			self.skip_angle_brackets();
			if (self.eat(DOT)) {
				// Receiver<T>.name
				if (self.at_identifier()) {
					Token real_name = self.expect_identifier();
					self.node_set_name(idx, real_name);
				}
			} else {
				// Not a receiver -- first_name was the function name
				self.node_set_name(idx, first_name);
			}
		} else if (self.eat(DOT)) {
			// Receiver.name
			if (self.at_identifier()) {
				Token real_name = self.expect_identifier();
				self.node_set_name(idx, real_name);
			}
		} else {
			// Simple: fun name
			self.node_set_name(idx, first_name);
		}
	}

	// Parameters: (param1: Type, param2: Type)
	if (self.at(LPAREN)) {
		self.advance(); // consume '('
		while (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_param();
			if (!self.eat(COMMA)) break;
		}
		self.expect(RPAREN);
	}

	// Return type: : ReturnType
	if (self.eat(COLON)) {
		uint type_start = self.current.offset;
		self.skip_type_ref();
		uint type_end = self.previous.offset + self.previous.len;
		if (type_end > type_start) {
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		}
	}

	// Where clause
	if (self.at(KW_WHERE)) {
		self.skip_where_clause();
	}

	// Body: { ... } or = expression
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (self.eat(ASSIGNMENT)) {
		// Expression body: fun foo() = expr
		// Skip until we hit something that ends the expression
		self.skip_expression_body();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Property declaration ───────────────────────────────────────────

/**
 * Parse val/var property declaration.
 *
 * val name: Type = expr
 * var name: Type = expr
 * val Receiver.name: Type get() = ...
 * val (a, b) = pair  -- destructuring (skip internals)
 */
fn void Parser.parse_property_decl(Parser* self, uint mods) {
	usz idx = self.add_node(PROPERTY_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.node_start(idx, self.current);
	self.advance(); // consume 'val' or 'var'

	usz children_start = self.result.node_count;

	// Type parameters: val <T> List<T>.first: T
	if (self.at(LANGLE)) {
		self.parse_type_params();
	}

	// Destructuring: val (a, b) = pair
	if (self.at(LPAREN)) {
		self.result.nodes[idx].name = "(destructuring)";
		self.skip_balanced_parens();
	} else if (self.at_identifier()) {
		Token first_name = self.expect_identifier();

		// Check for receiver: Name.property or Name<T>.property
		if (self.at(LANGLE)) {
			self.skip_angle_brackets();
			if (self.eat(DOT)) {
				if (self.at_identifier()) {
					Token real_name = self.expect_identifier();
					self.node_set_name(idx, real_name);
				}
			} else {
				self.node_set_name(idx, first_name);
			}
		} else if (self.eat(DOT)) {
			if (self.at_identifier()) {
				Token real_name = self.expect_identifier();
				self.node_set_name(idx, real_name);
			}
		} else {
			self.node_set_name(idx, first_name);
		}
	}

	// Type annotation: : Type
	if (self.eat(COLON)) {
		uint type_start = self.current.offset;
		self.skip_type_ref();
		uint type_end = self.previous.offset + self.previous.len;
		if (type_end > type_start) {
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		}
	}

	// Initializer: = expression
	if (self.eat(ASSIGNMENT)) {
		self.skip_expression_body();
	}

	// Property accessors: get() = ..., set(value) { ... }
	// These are soft keywords, so they appear as KW_GET / KW_SET
	while (self.at(KW_GET) || self.at(KW_SET)) {
		self.skip_property_accessor();
	}

	// Delegation: by expression
	if (self.eat(KW_BY)) {
		self.skip_expression_body();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Typealias declaration ──────────────────────────────────────────

fn void Parser.parse_typealias_decl(Parser* self, uint mods) {
	usz idx = self.add_node(TYPEALIAS_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.node_start(idx, self.current);
	self.advance(); // consume 'typealias'

	if (self.at_identifier()) {
		Token name = self.expect_identifier();
		self.node_set_name(idx, name);
	}

	// Type parameters
	if (self.at(LANGLE)) {
		self.skip_angle_brackets();
	}

	// = Type
	if (self.eat(ASSIGNMENT)) {
		uint type_start = self.current.offset;
		self.skip_type_ref();
		uint type_end = self.previous.offset + self.previous.len;
		if (type_end > type_start) {
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		}
	}

	self.node_end(idx);
}

// ── Constructor declaration ────────────────────────────────────────

fn void Parser.parse_constructor_decl(Parser* self, uint mods) {
	usz idx = self.add_node(CONSTRUCTOR_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.node_start(idx, self.current);
	self.result.nodes[idx].name = "constructor";
	self.node_set_name(idx, self.current);
	self.advance(); // consume 'constructor'

	usz children_start = self.result.node_count;

	// Parameters
	if (self.at(LPAREN)) {
		self.advance();
		while (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_param();
			if (!self.eat(COMMA)) break;
		}
		self.expect(RPAREN);
	}

	// Delegation call: : this(...) or : super(...)
	if (self.eat(COLON)) {
		if (self.at(KW_THIS) || self.at(KW_SUPER)) {
			self.advance();
			if (self.at(LPAREN)) {
				self.skip_balanced_parens();
			}
		}
	}

	// Body
	if (self.at(LCURL)) {
		self.parse_block();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Init block ─────────────────────────────────────────────────────

fn void Parser.parse_init_block(Parser* self) {
	usz idx = self.add_node(INIT_BLOCK);
	self.node_start(idx, self.current);
	self.result.nodes[idx].name = "init";
	self.node_set_name(idx, self.current);
	self.advance(); // consume 'init'

	if (self.at(LCURL)) {
		self.parse_block();
	}

	self.node_end(idx);
}

// ── Companion object ───────────────────────────────────────────────

fn void Parser.parse_companion_object(Parser* self, uint mods) {
	usz idx = self.add_node(COMPANION_OBJECT_DECL);
	self.result.nodes[idx].mod_flags = mods | ast::MOD_COMPANION;
	self.node_start(idx, self.current);
	self.advance(); // consume 'companion'

	if (!self.eat(KW_OBJECT)) {
		self.add_error("Expected 'object' after 'companion'");
		self.node_end(idx);
		return;
	}

	// Optional name
	if (self.at_identifier()) {
		Token name = self.expect_identifier();
		self.node_set_name(idx, name);
	} else {
		self.result.nodes[idx].name = "Companion";
	}

	usz children_start = self.result.node_count;

	// Super types
	if (self.at(COLON)) {
		self.skip_super_types();
	}

	// Body
	if (self.at(LCURL)) {
		self.parse_class_body(false);
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Primary constructor ────────────────────────────────────────────

/**
 * Parse primary constructor parameters: (val x: Int, var y: String)
 * Each val/var parameter becomes a PARAM child node.
 */
fn void Parser.parse_primary_constructor(Parser* self) {
	self.advance(); // consume '('

	while (!self.at(RPAREN) && !self.at_eof()) {
		// Annotations and modifiers on parameters
		uint param_mods = self.parse_modifiers();

		// val/var prefix makes it a property parameter
		bool is_val = self.eat(KW_VAL);
		bool is_var = !is_val && self.eat(KW_VAR);
		if (is_val) {
			param_mods |= ast::MOD_FINAL; // val parameters are final
		}

		self.parse_param_with_mods(param_mods);

		if (!self.eat(COMMA)) break;
	}

	self.expect(RPAREN);
}

// ── Parameter ──────────────────────────────────────────────────────

fn void Parser.parse_param(Parser* self) {
	self.parse_param_with_mods(ast::MOD_NONE);
}

fn void Parser.parse_param_with_mods(Parser* self, uint mods) {
	usz idx = self.add_node(PARAM);
	self.result.nodes[idx].mod_flags = mods;
	self.node_start(idx, self.current);

	// Parameter name
	if (self.at_identifier()) {
		Token name = self.expect_identifier();
		self.node_set_name(idx, name);
	}

	// Type annotation: : Type
	if (self.eat(COLON)) {
		uint type_start = self.current.offset;
		self.skip_type_ref();
		uint type_end = self.previous.offset + self.previous.len;
		if (type_end > type_start) {
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		}
	}

	// Default value: = expression
	if (self.eat(ASSIGNMENT)) {
		self.skip_param_default();
	}

	self.node_end(idx);
}

// ── Type parameters ────────────────────────────────────────────────

/**
 * Parse type parameters: <T, R : Comparable<R>, out V>
 * Each becomes a TYPE_PARAM child node.
 */
fn void Parser.parse_type_params(Parser* self) {
	self.advance(); // consume '<'

	while (!self.at(RANGLE) && !self.at_eof()) {
		usz idx = self.add_node(TYPE_PARAM);
		self.node_start(idx, self.current);

		// Variance: in/out
		uint mods = ast::MOD_NONE;
		if (self.eat(KW_IN) || self.eat(KW_OUT)) {
			// Record variance in modifiers if needed later
		}
		if (self.eat(KW_REIFIED)) {
			mods |= ast::MOD_REIFIED;
		}
		self.result.nodes[idx].mod_flags = mods;

		// Name
		if (self.at_identifier()) {
			Token name = self.expect_identifier();
			self.node_set_name(idx, name);
		}

		// Upper bound: : Type
		if (self.eat(COLON)) {
			uint type_start = self.current.offset;
			self.skip_type_ref();
			uint type_end = self.previous.offset + self.previous.len;
			if (type_end > type_start) {
				self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
			}
		}

		self.node_end(idx);
		if (!self.eat(COMMA)) break;
	}

	self.expect(RANGLE);
}

// ── Super types ────────────────────────────────────────────────────

/**
 * Skip super type list: : SuperClass(), Interface, Mixin by delegate
 */
fn void Parser.skip_super_types(Parser* self) {
	self.advance(); // consume ':'

	// Parse super types until we hit { or something that ends them
	while (!self.at_eof()) {
		// Type name
		if (self.at_identifier()) {
			self.advance();
			// Generic arguments
			if (self.at(LANGLE)) {
				self.skip_angle_brackets();
			}
			// Constructor call
			if (self.at(LPAREN)) {
				self.skip_balanced_parens();
			}
			// Delegation: by expression
			if (self.eat(KW_BY)) {
				self.skip_delegation_expression();
			}
		}

		if (self.eat(COMMA)) continue;
		break;
	}
}

// ── Where clause ───────────────────────────────────────────────────

fn void Parser.skip_where_clause(Parser* self) {
	self.advance(); // consume 'where'

	while (!self.at_eof()) {
		if (self.at_identifier()) {
			self.advance();
		}
		if (self.eat(COLON)) {
			self.skip_type_ref();
		}
		if (self.eat(COMMA)) continue;
		break;
	}
}

// ── Class body ─────────────────────────────────────────────────────

/**
 * Parse class body: { enum_entries?; members }
 */
fn void Parser.parse_class_body(Parser* self, bool is_enum) {
	self.advance(); // consume '{'

	// Enum entries come first in enum classes
	if (is_enum) {
		self.parse_enum_entries();
	}

	// Members
	while (!self.at(RCURL) && !self.at_eof()) {
		uint mods = self.parse_modifiers();
		if (self.at(RCURL) || self.at_eof()) break;

		if (!self.parse_declaration(mods)) {
			// Skip unrecognized token inside class body
			if (!self.at(RCURL) && !self.at_eof()) {
				self.advance();
			}
		}
	}

	self.expect(RCURL);
}

// ── Enum entries ───────────────────────────────────────────────────

/**
 * Parse enum entries: ENTRY_A, ENTRY_B(args), ENTRY_C { body };
 * Entries end with ';' or '}' (end of class body).
 */
fn void Parser.parse_enum_entries(Parser* self) {
	while (!self.at(RCURL) && !self.at(SEMICOLON) && !self.at_eof()) {
		// Check if this looks like an enum entry (identifier at start)
		// vs a regular member (keyword like fun, val, etc.)
		if (!self.at_identifier()) {
			// Check for modifiers that might precede a member declaration
			if (is_declaration_start(self.current.kind) || is_modifier_keyword(self.current.kind)) {
				break; // This is a member, not an enum entry
			}
			if (self.at(AT)) break; // annotation before member
			break;
		}

		usz idx = self.add_node(ENUM_ENTRY);
		self.node_start(idx, self.current);
		Token name = self.expect_identifier();
		self.node_set_name(idx, name);

		// Constructor arguments
		if (self.at(LPAREN)) {
			self.skip_balanced_parens();
		}

		// Entry body
		if (self.at(LCURL)) {
			self.parse_block();
		}

		self.node_end(idx);

		if (!self.eat(COMMA)) break;
	}

	// Optional semicolon separating entries from members
	self.eat(SEMICOLON);
}

// ── Opaque block ───────────────────────────────────────────────────

/**
 * Parse an opaque block: { ... }
 * Tracks brace nesting to find the matching closing brace.
 * Does not parse the interior -- this is phase 1.
 */
fn void Parser.parse_block(Parser* self) {
	usz idx = self.add_node(BLOCK);
	self.node_start(idx, self.current);
	self.advance(); // consume '{'

	int depth = 1;
	while (depth > 0 && !self.at_eof()) {
		if (self.at(LCURL)) {
			depth++;
		} else if (self.at(RCURL)) {
			depth--;
			if (depth == 0) break;
		}
		self.advance();
	}

	self.expect(RCURL); // consume closing '}'
	self.node_end(idx);
}

// ── Skip helpers ───────────────────────────────────────────────────

/**
 * Skip balanced parentheses: (...)
 */
fn void Parser.skip_balanced_parens(Parser* self) {
	self.advance(); // consume '('
	int depth = 1;
	while (depth > 0 && !self.at_eof()) {
		if (self.at(LPAREN)) {
			depth++;
		} else if (self.at(RPAREN)) {
			depth--;
			if (depth == 0) break;
		}
		self.advance();
	}
	self.expect(RPAREN);
}

/**
 * Skip balanced angle brackets: <...>
 */
fn void Parser.skip_angle_brackets(Parser* self) {
	self.advance(); // consume '<'
	int depth = 1;
	while (depth > 0 && !self.at_eof()) {
		if (self.at(LANGLE)) {
			depth++;
		} else if (self.at(RANGLE)) {
			depth--;
			if (depth == 0) break;
		}
		self.advance();
	}
	if (self.at(RANGLE)) {
		self.advance();
	}
}

/**
 * Skip a type reference. Consumes tokens that form a type:
 *   Name, Name<T>, Name?, (A, B) -> C, etc.
 */
fn void Parser.skip_type_ref(Parser* self) {
	// Handle function types: (A, B) -> C
	if (self.at(LPAREN)) {
		self.skip_balanced_parens();
		if (self.eat(ARROW)) {
			self.skip_type_ref(); // return type
		}
		// Nullable: ((A) -> B)?
		while (self.eat(QUEST)) {}
		return;
	}

	// Handle suspend function types: suspend (A) -> B
	if (self.at(KW_SUSPEND)) {
		self.advance();
		if (self.at(LPAREN)) {
			self.skip_type_ref(); // recurse to handle the function type
		}
		return;
	}

	// Simple type: Name
	if (self.at_identifier() || self.at(KW_DYNAMIC)) {
		self.advance();

		// Dotted type: com.example.Type
		while (self.eat(DOT)) {
			if (self.at_identifier()) {
				self.advance();
			} else if (self.at(LPAREN)) {
				// Function type with receiver: Type.(A, B) -> C
				// The DOT was already consumed by eat(DOT) above.
				self.skip_balanced_parens();
				if (self.eat(ARROW)) {
					self.skip_type_ref(); // return type
				}
				while (self.eat(QUEST)) {} // nullable
				return;
			} else {
				break;
			}
		}

		// Generic arguments: <T, R>
		if (self.at(LANGLE)) {
			self.skip_angle_brackets();
		}

		// Nullable: Type?
		while (self.eat(QUEST)) {}

		// Function type with receiver: Type.(A) -> B  or  Type<G>.(A) -> B
		if (self.eat(DOT)) {
			if (self.at(LPAREN)) {
				self.skip_balanced_parens();
				if (self.eat(ARROW)) {
					self.skip_type_ref(); // return type
				}
				while (self.eat(QUEST)) {} // nullable
			}
		}

		return;
	}

	// Nothing consumed -- error or end of type
}

/**
 * Skip an expression body (after = in fun or val).
 * Heuristic: skip until we see something at brace depth 0 that
 * starts a new declaration or ends the enclosing scope.
 */
fn void Parser.skip_expression_body(Parser* self) {
	int depth = 0;
	while (!self.at_eof()) {
		if (self.at(LCURL)) {
			depth++;
			self.advance();
			continue;
		}
		if (self.at(RCURL)) {
			if (depth == 0) return; // end of enclosing scope
			depth--;
			self.advance();
			continue;
		}
		if (self.at(LPAREN)) {
			depth++;
			self.advance();
			continue;
		}
		if (self.at(RPAREN)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}

		// At depth 0, check for declaration starters
		if (depth == 0) {
			if (is_declaration_start(self.current.kind)) return;
			if (is_modifier_keyword(self.current.kind)) return;
			if (self.at(SEMICOLON)) {
				self.advance();
				return;
			}
			// Property accessors at depth 0 end the expression
			if (self.at(KW_GET) || self.at(KW_SET)) return;
		}

		self.advance();
	}
}

/**
 * Skip a parameter default value expression.
 * Similar to skip_expression_body but also stops at comma and closing paren.
 */
fn void Parser.skip_param_default(Parser* self) {
	int depth = 0;
	while (!self.at_eof()) {
		if (self.at(LCURL)) { depth++; self.advance(); continue; }
		if (self.at(RCURL)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}
		if (self.at(LPAREN)) { depth++; self.advance(); continue; }
		if (self.at(RPAREN)) {
			if (depth == 0) return; // enclosing parameter list
			depth--;
			self.advance();
			continue;
		}
		if (self.at(LSQUARE)) { depth++; self.advance(); continue; }
		if (self.at(RSQUARE)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}

		// At depth 0, comma ends the default value
		if (depth == 0 && self.at(COMMA)) return;

		self.advance();
	}
}

/**
 * Skip a property accessor: get() = ... or set(value) { ... }
 */
fn void Parser.skip_property_accessor(Parser* self) {
	self.advance(); // consume 'get' or 'set'

	// Annotations and modifiers before the accessor
	// (already consumed by parse_modifiers in some paths)

	// Parameters for set
	if (self.at(LPAREN)) {
		self.skip_balanced_parens();
	}

	// Return type
	if (self.eat(COLON)) {
		self.skip_type_ref();
	}

	// Body
	if (self.at(LCURL)) {
		// Block body
		int depth = 1;
		self.advance(); // consume '{'
		while (depth > 0 && !self.at_eof()) {
			if (self.at(LCURL)) {
				depth++;
			} else if (self.at(RCURL)) {
				depth--;
			}
			if (depth > 0) {
				self.advance();
			}
		}
		if (self.at(RCURL)) {
			self.advance();
		}
	} else if (self.eat(ASSIGNMENT)) {
		// Expression body
		self.skip_expression_body();
	}
}

/**
 * Skip a delegation expression after 'by'.
 */
fn void Parser.skip_delegation_expression(Parser* self) {
	// Simple heuristic: skip until comma, '{', or end of type list
	int depth = 0;
	while (!self.at_eof()) {
		if (self.at(LPAREN)) { depth++; self.advance(); continue; }
		if (self.at(RPAREN)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}
		if (depth == 0) {
			if (self.at(COMMA) || self.at(LCURL) || self.at(KW_WHERE)) return;
		}
		self.advance();
	}
}

// ── Token classification helpers ───────────────────────────────────

/**
 * Check if a token kind is a soft keyword (context-dependent keyword
 * that can also be used as an identifier).
 */
fn bool is_soft_keyword(TokenKind kind) {
	switch (kind) {
		case KW_ABSTRACT: case KW_ANNOTATION: case KW_DATA: case KW_ENUM:
		case KW_EXTERNAL: case KW_FINAL: case KW_INFIX: case KW_INLINE:
		case KW_INNER: case KW_INTERNAL: case KW_LATEINIT: case KW_NOINLINE:
		case KW_OPEN: case KW_OPERATOR: case KW_OVERRIDE: case KW_PRIVATE:
		case KW_PROTECTED: case KW_PUBLIC: case KW_REIFIED: case KW_SEALED:
		case KW_SUSPEND: case KW_TAILREC: case KW_VARARG: case KW_CROSSINLINE:
		case KW_CONST: case KW_EXPECT: case KW_ACTUAL: case KW_VALUE:
		case KW_GET: case KW_SET: case KW_FIELD: case KW_PROPERTY:
		case KW_RECEIVER: case KW_PARAM: case KW_SETPARAM: case KW_DELEGATE:
		case KW_FILE:
			return true;
		default:
			return false;
	}
}

/**
 * Check if a token kind is a modifier keyword (subset of soft keywords
 * that can appear before declarations).
 */
fn bool is_modifier_keyword(TokenKind kind) {
	switch (kind) {
		case KW_ABSTRACT: case KW_ANNOTATION: case KW_DATA: case KW_ENUM:
		case KW_EXTERNAL: case KW_FINAL: case KW_INFIX: case KW_INLINE:
		case KW_INNER: case KW_INTERNAL: case KW_LATEINIT: case KW_NOINLINE:
		case KW_OPEN: case KW_OPERATOR: case KW_OVERRIDE: case KW_PRIVATE:
		case KW_PROTECTED: case KW_PUBLIC: case KW_REIFIED: case KW_SEALED:
		case KW_SUSPEND: case KW_TAILREC: case KW_VARARG: case KW_CROSSINLINE:
		case KW_CONST: case KW_EXPECT: case KW_ACTUAL: case KW_VALUE:
			return true;
		default:
			return false;
	}
}

/**
 * Check if a token kind starts a declaration.
 */
fn bool is_declaration_start(TokenKind kind) {
	switch (kind) {
		case KW_CLASS: case KW_INTERFACE: case KW_OBJECT: case KW_FUN:
		case KW_VAL: case KW_VAR: case KW_TYPEALIAS: case KW_CONSTRUCTOR:
		case KW_INIT: case KW_COMPANION:
			return true;
		default:
			return false;
	}
}

/**
 * Get a human-readable name for a token kind (for error messages).
 */
fn String token_name(TokenKind kind) {
	switch (kind) {
		case EOF:         return "end of file";
		case IDENTIFIER:  return "identifier";
		case LPAREN:      return "(";
		case RPAREN:      return ")";
		case LSQUARE:     return "[";
		case RSQUARE:     return "]";
		case LCURL:       return "{";
		case RCURL:       return "}";
		case LANGLE:      return "<";
		case RANGLE:      return ">";
		case COLON:       return ":";
		case SEMICOLON:   return ";";
		case COMMA:       return ",";
		case DOT:         return ".";
		case ASSIGNMENT:  return "=";
		case ARROW:       return "->";
		case KW_CLASS:    return "class";
		case KW_FUN:      return "fun";
		case KW_VAL:      return "val";
		case KW_VAR:      return "var";
		case KW_OBJECT:   return "object";
		case KW_PACKAGE:  return "package";
		case KW_IMPORT:   return "import";
		default:          return "token";
	}
}
