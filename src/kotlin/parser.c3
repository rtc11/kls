module kls::kotlin::parser;

import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import std::collections::list;

// ── Parser struct ──────────────────────────────────────────────────

struct Parser {
	String source;
	Lexer lexer;
	Token current;
	Token previous;
	ParseResult* result;
	String last_annotations;  // set by parse_modifiers, read by declaration parsers
	bool allow_angle_comparison;  // when true, treat < > as comparison in expressions
	bool is_script;  // when true, allow top-level statements/expressions (.kts files)

	// User-defined infix function names. Populated by `parse()` from a quick
	// pre-scan over `source` (same-file infix funs) AND from caller-provided
	// workspace-wide infix names. Used by `is_user_defined_infix` to recognize
	// `a foo b` style calls in the Pratt loop. Both slices are tcopy/tinit.
	String[] same_file_infix;
	String[] workspace_infix;

	// Pending annotation source ranges captured by parse_modifiers, flushed
	// into ANNOTATION_ENTRY child nodes by the declaration parser via
	// begin_decl_children_with_annotations(decl_idx).
	AnnotationRange[MAX_PENDING_ANNS] pending_anns;
	uint pending_ann_count;
}

const uint MAX_PENDING_ANNS = 32;

struct AnnotationRange {
	uint start_offset;  // offset of '@'
	uint end_offset;    // exclusive end (after closing ')' or end of name)
	uint start_line;
	uint start_col;
	uint args_start;    // offset of '(' (0 if no args)
	uint args_end;      // offset after ')' (0 if no args)
}

// ── Public entry point ─────────────────────────────────────────────

/**
 * Parse a complete Kotlin source file into the given ParseResult.
 * The result's node_count and error_count are reset to 0 before parsing.
 *
 * `workspace_infix`: optional slice of infix function names from other
 * workspace files. Combined with same-file infix names (auto-detected
 * by a pre-scan) so the Pratt loop recognizes user-defined infix calls
 * like `a customOp b`. Default empty (parser uses only the hard-coded
 * stdlib infix whitelist).
 */
fn void parse(String source, ParseResult* result, bool is_script = false,
		String[] workspace_infix = {}) {
	result.node_count = 0;
	result.error_count = 0;
	result.is_script = is_script;

	Parser p = {
		.source = source,
		.lexer = lexer::init(source),
		.result = result,
		.is_script = is_script,
		.same_file_infix = scan_same_file_infix_names(source),
		.workspace_infix = workspace_infix,
	};

	// Prime the parser with the first token
	p.current = p.lexer.next();

	p.parse_file();
}

/**
 * One-pass scan over `source` collecting names of `infix fun` declarations.
 * Used to populate Parser.same_file_infix so the Pratt loop can recognize
 * forward-referenced infix calls inside the same file. Result allocated
 * with tmem (request-scoped); caller must be inside a temp-allocator pool.
 */
fn String[] scan_same_file_infix_names(String source) {
	List{String} names;
	names.tinit();
	Lexer lex = lexer::init(source);
	bool saw_infix = false;
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;
		switch (tok.kind) {
			case KW_INFIX:
				saw_infix = true;
			case KW_FUN:
				if (saw_infix) {
					// Skip optional `<T>` type params, optional `Receiver.`, then name.
					Token t = lex.next();
					if (t.kind == LANGLE) {
						int depth = 1;
						while (depth > 0) {
							t = lex.next();
							if (t.kind == EOF) return names.array_view();
							if (t.kind == LANGLE) {
								depth++;
							} else if (t.kind == RANGLE) {
								depth--;
							}
						}
						t = lex.next();
					}
					// Skip receiver `Foo.` if present
					if (t.kind == IDENTIFIER) {
						Lexer save = lex;
						Token after = lex.next();
						if (after.kind == DOT) {
							t = lex.next();
						} else {
							lex = save;
						}
					}
					if (t.kind == IDENTIFIER) {
						names.push(t.text);
					}
				}
				saw_infix = false;
			case KW_VAL:
				nextcase;
			case KW_VAR:
				nextcase;
			case KW_CLASS:
				nextcase;
			case KW_INTERFACE:
				nextcase;
			case KW_OBJECT:
				saw_infix = false;
			default:
				break;
		}
	}
	return names.array_view();
}

/**
 * Parse a chunk of source for incremental re-parsing.
 * Parses declarations in source[byte_start..byte_end) into the result.
 * The lexer starts at byte_start with the given line number.
 * Nodes are written starting at result.node_count = 0.
 *
 * This is used by incremental parsing to re-parse a single top-level
 * declaration or class member without re-parsing the entire file.
 */
fn void parse_chunk(String source, ParseResult* result,
		uint byte_start, uint byte_end, uint line_start) {
	result.node_count = 0;
	result.error_count = 0;

	// Compute column: scan backwards from byte_start to find start of line
	uint col = 0;
	if (byte_start > 0) {
		uint scan = byte_start;
		while (scan > 0 && source[scan - 1] != '\n') {
			scan--;
			col++;
		}
	}

	Parser p = {
		.source = source,
		.lexer = lexer::init_at(source, (usz)byte_start, line_start, col),
		.result = result,
	};

	// Prime the parser with the first token
	p.current = p.lexer.next();

	// Parse declarations until we pass byte_end or hit EOF
	while (!p.at_eof() && p.current.offset < byte_end) {
		uint mods = p.parse_modifiers();
		if (p.at_eof() || p.current.offset >= byte_end) break;

		if (!p.parse_declaration(mods)) {
			// Could not parse a declaration -- skip token and try again
			if (!p.at_eof() && p.current.offset < byte_end) {
				p.add_error("Unexpected token in chunk");
				p.advance();
			}
		}
	}
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

fn bool Parser.peek_is(Parser* self, TokenKind kind) {
	Lexer save = self.lexer;
	Token next = self.lexer.next();
	self.lexer = save;
	return next.kind == kind;
}

fn bool Parser.peek_is_constructor(Parser* self) {
	Lexer save = self.lexer;
	Token next = self.lexer.next();
	self.lexer = save;
	return next.kind == KW_CONSTRUCTOR;
}

/**
 * Check if current IDENT is followed by `AT LCURL` on the same line.
 * Used to detect labeled lambda expressions: `label@ { ... }`.
 * Per Kotlin spec, no whitespace allowed between IDENT and `@`, but we
 * relax to same-line check since the lexer emits a single AT token.
 */
fn bool Parser.peek_is_label_at_for_lambda(Parser* self) {
	if (self.current.kind != IDENTIFIER) return false;
	Lexer save = self.lexer;
	Token at_tok = self.lexer.next();
	bool result = false;
	if (at_tok.kind == AT && at_tok.line == self.current.line) {
		Token after = self.lexer.next();
		if (after.kind == LCURL && after.line == at_tok.line) {
			result = true;
		}
	}
	self.lexer = save;
	return result;
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

fn uint Parser.add_node(Parser* self, NodeKind kind) {
	if (self.result.node_count >= ast::OVERFLOW_NODE) {
		// Emit a diagnostic once when we first overflow
		if (self.result.node_count == ast::OVERFLOW_NODE) {
			self.add_error("AST node limit reached; remaining declarations may be incomplete");
		}
		// Return the reserved overflow sink slot -- writes are safe but discarded
		uint idx = ast::OVERFLOW_NODE;
		self.result.nodes[idx].kind = kind;
		self.result.nodes[idx].name = "";
		self.result.nodes[idx].type_text = "";
		self.result.nodes[idx].extra_text = "";
		self.result.nodes[idx].annotation_text = "";
		self.result.nodes[idx].mod_flags = ast::MOD_NONE;
		self.result.nodes[idx].parent = ast::NO_PARENT;
		self.result.nodes[idx].child_count = 0;
		self.result.nodes[idx].children_start = 0;
		return idx;
	}
	uint idx = self.result.node_count;
	self.result.nodes[idx].kind = kind;
	self.result.nodes[idx].name = "";
	self.result.nodes[idx].type_text = "";
	self.result.nodes[idx].extra_text = "";
	self.result.nodes[idx].annotation_text = "";
	self.result.nodes[idx].mod_flags = ast::MOD_NONE;
	self.result.nodes[idx].parent = ast::NO_PARENT;
	self.result.nodes[idx].child_count = 0;
	self.result.nodes[idx].children_start = 0;
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
 * have their parent set by inner parse calls). Nodes already parented to
 * parent_idx (e.g. ANNOTATION_ENTRY children pre-attached by
 * begin_decl_children_with_annotations) are also counted.
 */
fn void Parser.adopt_children(Parser* self, uint parent_idx, uint start) {
	if (parent_idx == ast::OVERFLOW_NODE) return;
	uint count = 0;
	for (usz i = start; i < self.result.node_count; i++) {
		if (self.result.nodes[i].parent == ast::NO_PARENT) {
			self.result.nodes[i].parent = parent_idx;
			count++;
		} else if (self.result.nodes[i].parent == parent_idx) {
			count++;
		}
	}
	self.result.nodes[parent_idx].child_count = count;
	self.result.nodes[parent_idx].children_start = start;
}

fn void Parser.add_error(Parser* self, String message) {
	if (self.result.error_count >= ast::MAX_ERRORS) return;
	usz idx = self.result.error_count;
	// Heap-copy the message so it outlives the temp allocator pool.
	// ParseResult is cached on the heap, so error messages must also be heap-owned.
	self.result.errors[idx].message = message.copy(mem);
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
 * Compute the end line and column for a token, accounting for multi-line
 * tokens (block comments, multiline strings). Returns {end_line, end_col}.
 */
fn uint[2] Parser.token_end_pos(Parser* self, Token tok) {
	uint end_offset = tok.offset + tok.len;
	// Scan the token text for newlines to find the true end line/col
	uint line = tok.line;
	uint col = tok.col;
	usz start = tok.offset;
	usz end = start + tok.len;
	if (end > self.source.len) end = self.source.len;
	for (usz i = start; i < end; i++) {
		if (self.source[i] == '\n') {
			line++;
			col = 0;
		} else {
			col++;
		}
	}
	return { line, col };
}

/**
 * Set the end span of a node from the previous token (last consumed).
 */
fn void Parser.node_end(Parser* self, usz idx) {
	self.result.nodes[idx].end_offset = self.previous.offset + self.previous.len;
	uint[2] end_pos = self.token_end_pos(self.previous);
	self.result.nodes[idx].end_line = end_pos[0];
	self.result.nodes[idx].end_col = end_pos[1];
}

/**
 * Set the end span of a node from the current token (not yet consumed).
 */
fn void Parser.node_end_at_current(Parser* self, usz idx) {
	self.result.nodes[idx].end_offset = self.current.offset + self.current.len;
	uint[2] end_pos = self.token_end_pos(self.current);
	self.result.nodes[idx].end_line = end_pos[0];
	self.result.nodes[idx].end_col = end_pos[1];
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
	uint file_idx = self.add_node(FILE);
	self.node_start(file_idx, self.current);

	// Scan file-level annotations first (e.g., @file:Suppress("UNCHECKED_CAST"))
	// so their source ranges land in the pending buffer; we then flush them as
	// ANNOTATION_ENTRY children of FILE before capturing children_start.
	while (self.at(AT) && self.is_file_annotation()) {
		self.scan_annotation();
	}
	uint children_start = self.result.node_count;
	self.flush_pending_annotations(file_idx);

	// Optional package declaration
	if (self.at(KW_PACKAGE)) {
		self.parse_package_decl();
	}

	// Import declarations
	while (self.at(KW_IMPORT)) {
		self.parse_import_decl();
	}

	// Top-level declarations (and statements/expressions in script mode)
	while (!self.at_eof()) {
		// Script mode: if current token doesn't look like a declaration or modifier,
		// go straight to statement parsing (avoids consuming soft-keyword identifiers as modifiers)
		if (self.is_script && !is_modifier_keyword(self.current.kind) && !self.at(AT) && !is_declaration_start(self.current.kind)) {
			if (!self.parse_statement()) {
				if (!self.at_eof()) {
					self.add_error("Unexpected token in script");
					self.advance();
				}
			}
			continue;
		}

		uint mods = self.parse_modifiers();
		if (self.at_eof()) break;

		if (!self.parse_declaration(mods)) {
			if (self.is_script) {
				// Modifiers consumed but no declaration — try as statement/expression
				if (!self.at_eof() && !self.parse_expression_statement()) {
					self.add_error("Unexpected token in script");
					self.advance();
				}
			} else {
				// Could not parse a declaration -- skip token and try again
				if (!self.at_eof()) {
					self.add_error("Unexpected token at top level");
					self.advance();
				}
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
	uint idx = self.add_node(PACKAGE_DECL);
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
	uint idx = self.add_node(IMPORT_DECL);
	self.node_start(idx, self.current);
	self.advance(); // consume 'import'

	// Parse dotted name: foo.bar.baz
	uint path_start = self.current.offset;
	Token last_ident = self.current; // track last identifier for name/position
	bool is_star = false;
	if (self.at_identifier()) {
		last_ident = self.current;
		self.advance();
		while (self.eat(DOT)) {
			if (self.eat(MULT)) {
				// Wildcard import: foo.bar.*
				is_star = true;
				break;
			}
			if (self.at_identifier()) {
				last_ident = self.current;
				self.advance();
			} else {
				break;
			}
		}
	}
	uint path_end = self.previous.offset + self.previous.len;
	self.result.nodes[idx].extra_text = self.source[path_start:path_end - path_start];

	// Set name to last segment of import path (e.g., "MQQueue" for com.ibm.mq.jms.MQQueue)
	// so that build_location_from_node returns the correct position.
	// For star imports, use the last identifier before ".*".
	if (!is_star) {
		self.result.nodes[idx].name = last_ident.text;
		self.result.nodes[idx].name_line = last_ident.line;
		self.result.nodes[idx].name_col = last_ident.col;
		self.result.nodes[idx].name_offset = last_ident.offset;
		self.result.nodes[idx].name_len = last_ident.len;
	}

	// Optional alias: as Name — overrides the default name
	if (self.eat(KW_AS)) {
		Token alias_tok = self.expect_identifier();
		self.result.nodes[idx].name = alias_tok.text;
		self.result.nodes[idx].name_line = alias_tok.line;
		self.result.nodes[idx].name_col = alias_tok.col;
		self.result.nodes[idx].name_offset = alias_tok.offset;
		self.result.nodes[idx].name_len = alias_tok.len;
	}

	self.eat(SEMICOLON);
	self.node_end(idx);
}

// ── Modifiers ──────────────────────────────────────────────────────

fn uint Parser.parse_modifiers(Parser* self) {
	uint flags = ast::MOD_NONE;
	// Single annotation: direct source slice (zero-copy, stable pointer).
	// Multiple: heap-copied concatenation (tiny per-decl leak, acceptable for LSP).
	String first_ann = "";
	int ann_count = 0;
	DString multi_buf;

	// Clear stale pending annotation ranges from a previous (failed/empty) modifier scan.
	self.pending_ann_count = 0;

	while (!self.at_eof()) {
		// Annotations
		if (self.at(AT)) {
			String ann_name = self.scan_annotation();
			if (ann_name.len > 0) {
				ann_count++;
				if (ann_count == 1) {
					first_ann = ann_name;
				} else if (ann_count == 2) {
					multi_buf.tinit();
					multi_buf.append(first_ann);
					multi_buf.append(" ");
					multi_buf.append(ann_name);
				} else {
					multi_buf.append(" ");
					multi_buf.append(ann_name);
				}
			}
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
			case KW_PUBLIC:      flags |= ast::MOD_PUBLIC;       self.advance();
			case KW_EXPECT:      flags |= ast::MOD_EXPECT;      self.advance();
			case KW_ACTUAL:      flags |= ast::MOD_ACTUAL;      self.advance();
			case KW_VARARG:      flags |= ast::MOD_VARARG;      self.advance();
			case KW_NOINLINE:    flags |= ast::MOD_NOINLINE;    self.advance();
			case KW_CROSSINLINE: flags |= ast::MOD_CROSSINLINE; self.advance();
			case KW_REIFIED:     flags |= ast::MOD_REIFIED;     self.advance();
			default:
				if (ann_count <= 1) {
					self.last_annotations = first_ann;
				} else {
					self.last_annotations = multi_buf.str_view().copy(mem);
				}
				return flags;
		}
	}

	if (ann_count <= 1) {
		self.last_annotations = first_ann;
	} else {
		self.last_annotations = multi_buf.str_view().copy(mem);
	}
	return flags;
}

/**
 * Check if the current token starts a @file: annotation.
 * Peeks ahead without consuming tokens.
 */
fn bool Parser.is_file_annotation(Parser* self) {
	if (!self.at(AT)) return false;
	Lexer save_lexer = self.lexer;
	Token save_current = self.current;
	Token save_previous = self.previous;

	self.advance(); // consume '@'
	bool result = self.at_identifier() && self.current.text == "file";
	if (result) {
		self.advance(); // consume 'file'
		result = self.at(COLON);
	}

	self.lexer = save_lexer;
	self.current = save_current;
	self.previous = save_previous;
	return result;
}

/**
 * Scan an annotation: @Name or @Name(...).
 * Also handles use-site targets: @file:Name, @get:Name, etc.
 * Returns the simple (last segment) annotation name, e.g. "Test" for @org.junit.Test.
 *
 * Records the full source range (from '@' through closing ')' if present)
 * into the pending_anns buffer so a subsequent declaration parser can build
 * ANNOTATION_ENTRY child nodes via begin_decl_children_with_annotations().
 */
fn String Parser.scan_annotation(Parser* self) {
	uint range_start = self.current.offset;
	uint range_start_line = self.current.line;
	uint range_start_col = self.current.col;
	self.advance(); // consume '@'

	// Consume the first identifier (annotation name or use-site target)
	String name = "";
	if (self.at_identifier()) {
		name = self.current.text;
		self.advance();
	} else {
		return ""; // bare @ with no name
	}

	// If colon follows, the identifier was a use-site target (e.g. file:, get:)
	// and the real annotation name comes after
	if (self.eat(COLON)) {
		// Bracketed form: @target:[A B C]
		if (self.at(LSQUARE)) {
			self.advance(); // consume '['
			while (!self.at(RSQUARE) && !self.at_eof()) {
				if (self.at_identifier()) {
					name = self.current.text;
					self.advance();
					while (self.eat(DOT)) {
						if (self.at_identifier()) {
							name = self.current.text;
							self.advance();
						}
					}
					if (self.at(LPAREN)) {
						self.skip_balanced_parens();
					}
				} else {
					self.advance();
				}
			}
			self.eat(RSQUARE);
			uint range_end_b = self.previous.offset + self.previous.len;
			self.record_pending_annotation(range_start, range_end_b, range_start_line, range_start_col, 0, 0);
			return name;
		}
		if (self.at_identifier()) {
			name = self.current.text;
			self.advance();
		}
	}

	// Dotted annotation name: @com.example.MyAnnotation
	// Keep the last segment as the simple name
	while (self.eat(DOT)) {
		if (self.at_identifier()) {
			name = self.current.text;
			self.advance();
		}
	}

	// Skip annotation arguments
	uint args_start = 0;
	uint args_end = 0;
	if (self.at(LPAREN)) {
		args_start = self.current.offset;
		self.skip_balanced_parens();
		args_end = self.previous.offset + self.previous.len;
	}

	uint range_end = self.previous.offset + self.previous.len;
	self.record_pending_annotation(range_start, range_end, range_start_line, range_start_col, args_start, args_end);
	return name;
}

/**
 * Push an annotation source range onto the pending buffer. Silently drops
 * if buffer full (>32 anns on one declaration is unrealistic).
 */
fn void Parser.record_pending_annotation(Parser* self, uint start, uint end, uint line, uint col, uint args_start, uint args_end) {
	if (self.pending_ann_count >= MAX_PENDING_ANNS) return;
	self.pending_anns[self.pending_ann_count] = {
		.start_offset = start,
		.end_offset = end,
		.start_line = line,
		.start_col = col,
		.args_start = args_start,
		.args_end = args_end,
	};
	self.pending_ann_count++;
}

/**
 * Capture children_start for a declaration AND emit any pending ANNOTATION_ENTRY
 * child nodes (parent set to decl_idx) before child parsing begins. The pending
 * buffer is cleared. Must be called exactly once per declaration immediately
 * before any real children are parsed.
 *
 * Returns children_start (the index of the first ANNOTATION_ENTRY, or
 * node_count if there are none).
 */
fn uint Parser.begin_decl_children_with_annotations(Parser* self, uint decl_idx) {
	uint children_start = self.result.node_count;
	self.flush_pending_annotations(decl_idx);
	return children_start;
}

/**
 * Flush all pending annotation source ranges into ANNOTATION_ENTRY child
 * nodes parented to parent_idx. Clears the pending buffer.
 */
fn void Parser.flush_pending_annotations(Parser* self, uint parent_idx) {
	uint count = self.pending_ann_count;
	for (uint i = 0; i < count; i++) {
		AnnotationRange r = self.pending_anns[i];
		self.build_annotation_entry(parent_idx, r);
	}
	self.pending_ann_count = 0;
}

/**
 * Build a single ANNOTATION_ENTRY node by re-lexing the captured source range.
 * Parent is set to decl_idx. Use-site target (if any) goes into type_text;
 * simple name into name; full dotted path into extra_text; arguments are
 * parsed as expression children.
 */
fn void Parser.build_annotation_entry(Parser* self, uint decl_idx, AnnotationRange r) {
	uint idx = self.add_node(ANNOTATION_ENTRY);
	self.result.nodes[idx].parent = decl_idx;
	self.result.nodes[idx].start_offset = r.start_offset;
	self.result.nodes[idx].start_line = r.start_line;
	self.result.nodes[idx].start_col = r.start_col;
	self.result.nodes[idx].end_offset = r.end_offset;
	// We don't track exact end line/col since the range is bounded; estimate.
	self.result.nodes[idx].end_line = r.start_line;
	self.result.nodes[idx].end_col = r.start_col + (r.end_offset - r.start_offset);

	// Slice and re-lex
	if (r.end_offset > r.start_offset && r.end_offset <= self.source.len) {
		// Save outer parser state
		Lexer save_lexer = self.lexer;
		Token save_current = self.current;
		Token save_previous = self.previous;

		// Init a sub-lexer over a slice of the source (zero-copy via subview)
		String slice = self.source[r.start_offset:r.end_offset - r.start_offset];
		self.lexer = lexer::init(slice);
		self.current = self.lexer.next();
		self.previous = self.current;

		// Parse: @ [target:] [path.]Name [( args )]
		if (self.at(AT)) self.advance();

		String target = "";
		String simple = "";
		uint path_start = self.current.offset;
		Token last_ident = self.current;

		if (self.at_identifier()) {
			Token first = self.current;
			self.advance();
			if (self.at(COLON)) {
				// Use-site target
				target = first.text;
				self.advance(); // consume ':'
				if (self.at(LSQUARE)) {
					// Bracketed form @target:[A B] -- store target only;
					// the entries inside collapse into a single ANNOTATION_ENTRY
					// here (richer modeling deferred).
					self.advance();
					if (self.at_identifier()) {
						last_ident = self.current;
						simple = self.current.text;
						self.advance();
						while (self.eat(DOT)) {
							if (self.at_identifier()) {
								last_ident = self.current;
								simple = self.current.text;
								self.advance();
							}
						}
					}
				} else if (self.at_identifier()) {
					last_ident = self.current;
					simple = self.current.text;
					path_start = self.current.offset;
					self.advance();
				}
			} else {
				// No target -- first identifier is start of dotted path
				last_ident = first;
				simple = first.text;
				path_start = first.offset;
			}

			while (self.eat(DOT)) {
				if (self.at_identifier()) {
					last_ident = self.current;
					simple = self.current.text;
					self.advance();
				} else {
					break;
				}
			}
		}

		// Capture full dotted path text from outer source (offsets relative to slice
		// — slice starts at r.start_offset, so add it back)
		uint path_end = self.previous.offset + self.previous.len;
		if (path_end > path_start) {
			uint abs_start = r.start_offset + path_start;
			uint abs_end = r.start_offset + path_end;
			if (abs_end <= self.source.len) {
				self.result.nodes[idx].extra_text = self.source[abs_start:abs_end - abs_start];
			}
		}

		self.result.nodes[idx].name = simple;
		self.result.nodes[idx].name_offset = r.start_offset + last_ident.offset;
		self.result.nodes[idx].name_line = last_ident.line;
		self.result.nodes[idx].name_col = last_ident.col;
		self.result.nodes[idx].name_len = last_ident.len;
		self.result.nodes[idx].type_text = target;

		// Argument list (if any) -- store raw source slice (including parens)
		// in annotation_text. Full sub-AST parsing deferred to a later phase.
		if (r.args_end > r.args_start && r.args_end <= self.source.len) {
			self.result.nodes[idx].annotation_text = self.source[r.args_start:r.args_end - r.args_start];
		}

		// Restore outer parser state
		self.lexer = save_lexer;
		self.current = save_current;
		self.previous = save_previous;
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
	uint idx = self.add_node(kind);
	self.result.nodes[idx].mod_flags = mods;
	self.result.nodes[idx].annotation_text = self.last_annotations;

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

	uint children_start = self.begin_decl_children_with_annotations(idx);

	// Type parameters: <T, R>
	if (self.at(LANGLE)) {
		self.parse_type_params();
	}

	// Primary constructor for classes: (val x: Int, var y: String)
	// May have optional visibility modifier and 'constructor' keyword:
	//   class Foo(val x: Int)
	//   class Foo internal constructor(val x: Int)
	//   class Foo private constructor(val x: Int)
	if (kind == CLASS_DECL) {
		// Skip optional visibility modifier before 'constructor'
		if ((self.at(KW_INTERNAL) || self.at(KW_PRIVATE) || self.at(KW_PROTECTED) || self.at(KW_PUBLIC))
		    && self.peek_is_constructor()) {
			self.advance(); // consume visibility modifier
		}
		// Skip optional 'constructor' keyword
		if (self.at(KW_CONSTRUCTOR) && self.peek_is(LPAREN)) {
			self.advance(); // consume 'constructor'
		}
		if (self.at(LPAREN)) {
			self.parse_primary_constructor();
		}
	}

	// Super types: : SuperClass(), Interface
	if (self.at(COLON)) {
		self.parse_super_types();
	}

	// Where clause: where T : Comparable<T>
	if (self.at(KW_WHERE)) {
		self.parse_where_clause();
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
	uint idx = self.add_node(FUN_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.result.nodes[idx].annotation_text = self.last_annotations;
	self.node_start(idx, self.current);
	self.advance(); // consume 'fun'

	uint children_start = self.begin_decl_children_with_annotations(idx);

	// Type parameters: <T>
	if (self.at(LANGLE)) {
		self.parse_type_params();
	}

	// Name or Receiver.name
	if (self.at_identifier()) {
		Token first_name = self.expect_identifier();

		// Check for receiver: if DOT follows, first_name was the receiver type
		if (self.at(LANGLE)) {
			// Could be Receiver<T>.name -- capture full receiver text
			uint recv_start = first_name.offset;
			self.parse_type_args();
			// Handle nullable generic receiver: Receiver<T>?.name
			bool is_nullable_recv = false;
			if (self.at(QUEST)) {
				self.advance(); // consume '?'
				is_nullable_recv = true;
			}
			if (self.eat(DOT) || (!is_nullable_recv && self.at(SAFE_CALL))) {
				bool used_safe_call = false;
				if (self.at(SAFE_CALL)) {
					used_safe_call = true;
					self.advance(); // consume '?.'
				}
				// Receiver<T>.name  or  Receiver<T>?.name
				uint recv_end = self.previous.offset; // offset of '.' or '?.'
				if (used_safe_call) {
					// For '?.' token, extra_text should include the '?'
					self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start + 1];
				} else {
					self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start];
				}
				if (self.at_identifier()) {
					Token real_name = self.expect_identifier();
					self.node_set_name(idx, real_name);
				}
			} else {
				// Not a receiver -- first_name was the function name
				self.node_set_name(idx, first_name);
			}
		} else if (self.at(DOT) || self.at(SAFE_CALL)) {
			// Handle receiver: Receiver.name  or  Receiver?.name
			// Also handles dotted receivers: com.example.Type.name
			uint recv_start = first_name.offset;
			if (self.at(SAFE_CALL)) {
				// ?. is a single token -- receiver includes the ?
				uint recv_end = self.current.offset; // offset of '?.'
				self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start + 1];
				self.advance(); // consume '?.'
			} else {
				self.advance(); // consume '.'
				self.result.nodes[idx].extra_text = first_name.text;
			}
			if (self.at_identifier()) {
				Token real_name = self.expect_identifier();
				// Check for additional dots: Outer.Inner.funName
				while (self.at(DOT) || self.at(SAFE_CALL)) {
					// Previous real_name was part of receiver, not the function name
					if (self.at(SAFE_CALL)) {
						uint recv_end = self.current.offset;
						self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start + 1];
						self.advance(); // consume '?.'
					} else {
						uint recv_end = self.current.offset;
						self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start];
						self.advance(); // consume '.'
					}
					if (self.at_identifier()) {
						real_name = self.expect_identifier();
					} else {
						break;
					}
				}
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
		self.parse_where_clause();
	}

	// Body: { ... } or = expression
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (self.eat(ASSIGNMENT)) {
		// Expression body: fun foo() = expr
		self.parse_expression_body();
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
	uint idx = self.add_node(PROPERTY_DECL);
	// #13: Track val vs var distinction
	if (self.at(KW_VAR)) {
		mods |= ast::MOD_VAR;
	}
	self.result.nodes[idx].mod_flags = mods;
	self.result.nodes[idx].annotation_text = self.last_annotations;
	self.node_start(idx, self.current);
	self.advance(); // consume 'val' or 'var'

	uint children_start = self.begin_decl_children_with_annotations(idx);

	// Type parameters: val <T> List<T>.first: T
	if (self.at(LANGLE)) {
		self.parse_type_params();
	}

	// Destructuring: val (a, b) = pair
	if (self.at(LPAREN)) {
		self.result.nodes[idx].name = "(destructuring)";
		self.advance(); // consume '('
		while (!self.at(RPAREN) && !self.at_eof()) {
			if (self.at(COMMA)) {
				self.advance(); // consume ','
				continue;
			}
			if (self.at_identifier()) {
				uint child_idx = self.add_node(PROPERTY_DECL);
				// Inherit val/var from parent
				self.result.nodes[child_idx].mod_flags = mods;
				self.node_start(child_idx, self.current);
				Token comp_name = self.expect_identifier();
				self.node_set_name(child_idx, comp_name);
				// Optional type annotation: (a: Int, b: String)
				if (self.eat(COLON)) {
					uint type_start = self.current.offset;
					self.skip_type_ref();
					uint type_end = self.previous.offset + self.previous.len;
					if (type_end > type_start) {
						self.result.nodes[child_idx].type_text = self.source[type_start:type_end - type_start];
					}
				}
				self.node_end(child_idx);
			} else {
				// Skip unexpected token
				self.advance();
			}
		}
		self.expect(RPAREN);
	} else if (self.at_identifier()) {
		Token first_name = self.expect_identifier();

		// Check for receiver: Name.property or Name<T>.property or Name?.property
		if (self.at(LANGLE)) {
			uint recv_start = first_name.offset;
			self.parse_type_args();
			// Handle nullable generic receiver: Name<T>?.property
			bool is_nullable_recv = false;
			if (self.at(QUEST)) {
				self.advance(); // consume '?'
				is_nullable_recv = true;
			}
			if (self.eat(DOT) || (!is_nullable_recv && self.at(SAFE_CALL))) {
				bool used_safe_call = false;
				if (self.at(SAFE_CALL)) {
					used_safe_call = true;
					self.advance(); // consume '?.'
				}
				uint recv_end = self.previous.offset;
				if (used_safe_call) {
					self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start + 1];
				} else {
					self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start];
				}
				if (self.at_identifier()) {
					Token real_name = self.expect_identifier();
					self.node_set_name(idx, real_name);
				}
			} else {
				self.node_set_name(idx, first_name);
			}
		} else if (self.at(DOT) || self.at(SAFE_CALL)) {
			// Handle receiver: Name.property  or  Name?.property
			uint recv_start = first_name.offset;
			if (self.at(SAFE_CALL)) {
				uint recv_end = self.current.offset;
				self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start + 1];
				self.advance(); // consume '?.'
			} else {
				self.advance(); // consume '.'
				self.result.nodes[idx].extra_text = first_name.text;
			}
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
		self.parse_expression_body();
	}

	// Property accessors: get() = ..., set(value) { ... }
	// These are soft keywords, so they appear as KW_GET / KW_SET
	while (self.at(KW_GET) || self.at(KW_SET)) {
		self.parse_property_accessor();
	}

	// Delegation: by expression
	if (self.eat(KW_BY)) {
		self.parse_expression_body();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Typealias declaration ──────────────────────────────────────────

fn void Parser.parse_typealias_decl(Parser* self, uint mods) {
	uint idx = self.add_node(TYPEALIAS_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.result.nodes[idx].annotation_text = self.last_annotations;
	self.node_start(idx, self.current);
	self.advance(); // consume 'typealias'

	if (self.at_identifier()) {
		Token name = self.expect_identifier();
		self.node_set_name(idx, name);
	}

	uint children_start = self.begin_decl_children_with_annotations(idx);

	// Type parameters
	if (self.at(LANGLE)) {
		self.parse_type_params();
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

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Constructor declaration ────────────────────────────────────────

fn void Parser.parse_constructor_decl(Parser* self, uint mods) {
	uint idx = self.add_node(CONSTRUCTOR_DECL);
	self.result.nodes[idx].mod_flags = mods;
	self.result.nodes[idx].annotation_text = self.last_annotations;
	self.node_start(idx, self.current);
	self.result.nodes[idx].name = "constructor";
	self.node_set_name(idx, self.current);
	self.advance(); // consume 'constructor'

	uint children_start = self.begin_decl_children_with_annotations(idx);

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
	uint idx = self.add_node(INIT_BLOCK);
	self.node_start(idx, self.current);
	self.result.nodes[idx].name = "init";
	self.node_set_name(idx, self.current);
	self.advance(); // consume 'init'

	if (self.at(LCURL)) {
		uint children_start = self.begin_decl_children_with_annotations(idx);
		self.parse_block();
		self.adopt_children(idx, children_start);
	}

	self.node_end(idx);
}

// ── Companion object ───────────────────────────────────────────────

fn void Parser.parse_companion_object(Parser* self, uint mods) {
	uint idx = self.add_node(COMPANION_OBJECT_DECL);
	self.result.nodes[idx].mod_flags = mods | ast::MOD_COMPANION;
	self.result.nodes[idx].annotation_text = self.last_annotations;
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

	uint children_start = self.begin_decl_children_with_annotations(idx);

	// Super types
	if (self.at(COLON)) {
		self.parse_super_types();
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
		if (is_var) {
			param_mods |= ast::MOD_VAR; // var parameters are mutable
		}

		self.parse_param_with_mods(param_mods);

		if (!self.eat(COMMA)) break;
	}

	self.expect(RPAREN);
}

// ── Parameter ──────────────────────────────────────────────────────

fn void Parser.parse_param(Parser* self) {
	// Consume parameter-level modifiers: vararg, crossinline, noinline
	uint mods = ast::MOD_NONE;
	while (self.at(KW_VARARG) || self.at(KW_CROSSINLINE) || self.at(KW_NOINLINE)) {
		if (self.at(KW_VARARG)) {
			mods |= ast::MOD_VARARG;
			self.advance();
		} else if (self.at(KW_CROSSINLINE)) {
			mods |= ast::MOD_CROSSINLINE;
			self.advance();
		} else if (self.at(KW_NOINLINE)) {
			mods |= ast::MOD_NOINLINE;
			self.advance();
		}
	}
	self.parse_param_with_mods(mods);
}

fn void Parser.parse_param_with_mods(Parser* self, uint mods) {
	uint idx = self.add_node(PARAM);
	self.result.nodes[idx].mod_flags = mods;
	self.result.nodes[idx].annotation_text = self.last_annotations;
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
	// Capture the source slice in `extra_text` for hover/completion display.
	// Sub-AST is not yet built (deferred); slice supports text-only display.
	if (self.eat(ASSIGNMENT)) {
		uint default_start = self.current.offset;
		self.skip_param_default();
		uint default_end = self.previous.offset + self.previous.len;
		// Defensive: ensure end didn't roll back into nothing.
		if (default_end > default_start && default_end <= self.source.len) {
			self.result.nodes[idx].extra_text =
				self.source[default_start:default_end - default_start];
		}
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
		uint idx = self.add_node(TYPE_PARAM);
		self.node_start(idx, self.current);

		// Variance: in/out
		uint mods = ast::MOD_NONE;
		if (self.eat(KW_IN)) {
			mods |= ast::MOD_IN;
		} else if (self.eat(KW_OUT)) {
			mods |= ast::MOD_OUT;
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

// ── Type arguments (use-site) ──────────────────────────────────────

/**
 * Parse type arguments at a use site: <Int, String>, <out T>, <*>
 * Each becomes a TYPE_ARG child node with:
 *   - name: the type text (e.g. "Int", "String", "*")
 *   - type_text: full text of complex types (e.g. "List<Int>", "suspend () -> Unit")
 *   - mod_flags: MOD_IN/MOD_OUT for use-site variance
 */
fn void Parser.parse_type_args(Parser* self) {
	self.advance(); // consume '<'

	while (!self.at(RANGLE) && !self.at_eof()) {
		uint idx = self.add_node(TYPE_ARG);
		self.node_start(idx, self.current);

		// Use-site variance: in/out
		uint mods = ast::MOD_NONE;
		if (self.eat(KW_IN)) {
			mods |= ast::MOD_IN;
		} else if (self.eat(KW_OUT)) {
			mods |= ast::MOD_OUT;
		}
		self.result.nodes[idx].mod_flags = mods;

		// Star projection: *
		if (self.at(MULT)) {
			self.result.nodes[idx].name = "*";
			uint type_start = self.current.offset;
			self.advance(); // consume '*'
			uint type_end = self.previous.offset + self.previous.len;
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		} else {
			// Type reference
			uint type_start = self.current.offset;
			self.skip_type_ref();
			uint type_end = self.previous.offset + self.previous.len;
			if (type_end > type_start) {
				String type_text = self.source[type_start:type_end - type_start];
				self.result.nodes[idx].type_text = type_text;
				// Set name to simple identifier if it's just a name
				self.result.nodes[idx].name = type_text;
			}
		}

		self.node_end(idx);
		if (!self.eat(COMMA)) break;
	}

	if (self.at(RANGLE)) {
		self.advance();
	}
}

// ── Super types ────────────────────────────────────────────────────

/**
 * Skip super type list: : SuperClass(), Interface, Mixin by delegate
 */
/**
 * Parse super type list after ':'. Creates TYPE_REF child nodes for each
 * supertype so the AST captures inheritance information.
 *
 * Handles: class Foo : Bar, Baz<T>, Qux()
 *          class Foo : Base() by delegate
 *          class Foo : InterfaceA, InterfaceB
 */
fn void Parser.parse_super_types(Parser* self) {
	self.advance(); // consume ':'

	// Parse super types until we hit { or something that ends them
	while (!self.at_eof()) {
		// Type name
		if (self.at_identifier()) {
			// Create a TYPE_REF node for this supertype
			uint ref_idx = self.add_node(TYPE_REF);
			self.node_start(ref_idx, self.current);

			Token name_tok = self.current;
			self.node_set_name(ref_idx, name_tok);
			self.advance();

			// Dot-qualified name: models.Simulering
			while (self.eat(DOT)) {
				if (self.at_identifier()) {
					name_tok = self.current;
					self.node_set_name(ref_idx, name_tok);
					self.advance();
				} else {
					break;
				}
			}

			// Generic arguments: <T, R>
			if (self.at(LANGLE)) {
				self.parse_type_args();
			}
			// Constructor call: ()
			if (self.at(LPAREN)) {
				self.skip_balanced_parens();
			}
			// Delegation: by expression
			if (self.eat(KW_BY)) {
				self.skip_delegation_expression();
			}

			self.node_end(ref_idx);
		}

		if (self.eat(COMMA)) continue;
		break;
	}
}

// ── Where clause ───────────────────────────────────────────────────

fn void Parser.parse_where_clause(Parser* self) {
	self.advance(); // consume 'where'

	while (!self.at_eof()) {
		if (self.at_identifier()) {
			uint idx = self.add_node(WHERE_CONSTRAINT);
			self.node_start(idx, self.current);

			Token name_tok = self.current;
			self.node_set_name(idx, name_tok);
			self.advance();

			if (self.eat(COLON)) {
				uint type_start = self.current.offset;
				self.skip_type_ref();
				uint type_end = self.previous.offset + self.previous.len;
				if (type_end > type_start) {
					self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
				}
			}

			self.node_end(idx);
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

		uint idx = self.add_node(ENUM_ENTRY);
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

// ── Block with statement parsing ───────────────────────────────────

/**
 * Parse a block: { statements... }
 * Now parses interior statements to produce child nodes for
 * local declarations, control flow, etc.
 */
fn void Parser.parse_block(Parser* self) {
	uint idx = self.add_node(BLOCK);
	self.node_start(idx, self.current);
	self.advance(); // consume '{'
	uint children_start = self.result.node_count;

	while (!self.at(RCURL) && !self.at_eof()) {
		self.eat(SEMICOLON); // skip optional semicolons between statements
		if (self.at(RCURL) || self.at_eof()) break;

		// Save position to detect stuck parser
		uint saved_pos = self.current.offset;

		if (!self.parse_statement()) {
			// Could not parse a statement -- skip token and try again
			if (!self.at(RCURL) && !self.at_eof()) {
				self.advance();
			}
		} else if (self.current.offset == saved_pos) {
			// Statement claimed to parse but didn't advance -- force advance
			if (!self.at(RCURL) && !self.at_eof()) {
				self.advance();
			}
		}
	}

	self.expect(RCURL);
	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Statement dispatcher ──────────────────────────────────────────

/**
 * Try to parse a statement inside a block.
 * Returns true if something was parsed, false otherwise.
 */
fn bool Parser.parse_statement(Parser* self) {
	switch (self.current.kind) {
		case KW_VAL:
			nextcase;
		case KW_VAR:
			self.parse_property_decl(ast::MOD_NONE);
			return true;

		case KW_IF:
			self.parse_if_expr();
			return true;

		case KW_WHEN:
			self.parse_when_expr();
			return true;

		case KW_FOR:
			self.parse_for_stmt();
			return true;

		case KW_WHILE:
			self.parse_while_stmt();
			return true;

		case KW_DO:
			self.parse_do_while_stmt();
			return true;

		case KW_TRY:
			self.parse_try_expr();
			return true;

		case KW_RETURN:
			self.parse_return_expr();
			return true;

		case KW_THROW:
			self.parse_throw_expr();
			return true;

		case KW_BREAK:
			self.parse_break_continue(BREAK_EXPR);
			return true;

		case KW_CONTINUE:
			self.parse_break_continue(CONTINUE_EXPR);
			return true;

		default:
			break;
	}

	// Check for modifiers + declaration (local fun, local class)
	if (is_modifier_keyword(self.current.kind) || self.at(AT)) {
		uint mods = self.parse_modifiers();
		if (is_declaration_start(self.current.kind)) {
			return self.parse_declaration(mods);
		}
		// Modifiers without a declaration keyword -- probably an expression
		// starting with a soft keyword used as an identifier. Fall through
		// to expression statement. But we already consumed the modifiers
		// as tokens, so we can just try to parse an expression.
		if (!self.at(RCURL) && !self.at_eof()) {
			self.parse_expression_statement();
		}
		return true;
	}

	// Declaration without modifiers (local fun, local class, etc.)
	if (is_declaration_start(self.current.kind)) {
		return self.parse_declaration(ast::MOD_NONE);
	}

	// Expression statement
	return self.parse_expression_statement();
}

// ── If expression ─────────────────────────────────────────────────

/**
 * Parse if expression:
 *   if (condition) block/statement
 *   if (condition) block/statement else block/statement
 *   if (condition) block/statement else if (condition) ...
 */
fn void Parser.parse_if_expr(Parser* self) {
	uint idx = self.add_node(IF_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'if'
	uint children_start = self.result.node_count;

	// Condition: (expr) -- try to parse the expression inside parens as
	// an AST child for smart casts and type inference. Fall back to
	// skip_balanced_parens if expression parsing can't consume the
	// full condition (e.g. due to < and > ambiguity with generics).
	if (self.at(LPAREN)) {
		// Save parser state for rollback
		Lexer save_lexer = self.lexer;
		Token save_current = self.current;
		Token save_previous = self.previous;
		uint save_node_count = self.result.node_count;
		usz save_error_count = self.result.error_count;

		self.advance(); // consume '('
		if (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_expression(0);
		}

		if (self.at(RPAREN)) {
			// Expression parsing consumed the condition correctly
			self.advance(); // consume ')'
		} else {
			// Rollback and retry with < > as comparison operators
			self.lexer = save_lexer;
			self.current = save_current;
			self.previous = save_previous;
			self.result.node_count = save_node_count;
			self.result.error_count = save_error_count;

			self.allow_angle_comparison = true;
			self.advance(); // consume '('
			if (!self.at(RPAREN) && !self.at_eof()) {
				self.parse_expression(0);
			}
			self.allow_angle_comparison = false;

			if (self.at(RPAREN)) {
				self.advance(); // consume ')'
			} else {
				// Still can't parse -- final fallback to skipping
				self.lexer = save_lexer;
				self.current = save_current;
				self.previous = save_previous;
				self.result.node_count = save_node_count;
				self.result.error_count = save_error_count;
				self.skip_balanced_parens();
			}
		}
	}

	// Then branch: block or single statement
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (!self.at(RCURL) && !self.at_eof()) {
		// Single-statement then branch -- parse one statement
		self.parse_statement();
	}

	// Else branch
	if (self.eat(KW_ELSE)) {
		if (self.at(KW_IF)) {
			// else if -- recursive
			self.parse_if_expr();
		} else if (self.at(LCURL)) {
			self.parse_block();
		} else if (!self.at(RCURL) && !self.at_eof()) {
			self.parse_statement();
		}
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── When expression ───────────────────────────────────────────────

/**
 * Parse when expression:
 *   when { conditions -> body, ... }
 *   when (subject) { conditions -> body, ... }
 *
 * Subject: parsed as an expression child (with rollback fallback).
 * Each branch: a WHEN_ENTRY child containing condition expression(s) + body.
 */
fn void Parser.parse_when_expr(Parser* self) {
	uint idx = self.add_node(WHEN_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'when'
	uint children_start = self.result.node_count;

	// Optional subject: (expr) -- parse as AST child with rollback
	if (self.at(LPAREN)) {
		Lexer save_lexer = self.lexer;
		Token save_current = self.current;
		Token save_previous = self.previous;
		uint save_node_count = self.result.node_count;
		usz save_error_count = self.result.error_count;

		self.advance(); // consume '('
		if (self.at(KW_VAL) || self.at(KW_VAR)) {
			// when (val x = expr) -- subject binding (Kotlin spec §16.30)
			self.parse_property_decl(ast::MOD_NONE);
		} else if (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_expression(0);
		}

		if (self.at(RPAREN)) {
			self.advance(); // consume ')'
		} else {
			// Rollback and fall back to skipping
			self.lexer = save_lexer;
			self.current = save_current;
			self.previous = save_previous;
			self.result.node_count = save_node_count;
			self.result.error_count = save_error_count;
			self.skip_balanced_parens();
		}
	}

	// Body: { branches }
	if (self.at(LCURL)) {
		self.advance(); // consume '{'

		while (!self.at(RCURL) && !self.at_eof()) {
			self.eat(SEMICOLON);
			if (self.at(RCURL)) break;

			uint saved_pos = self.current.offset;

			// Create a WHEN_ENTRY node for this branch
			uint entry_idx = self.add_node(WHEN_ENTRY);
			self.node_start(entry_idx, self.current);
			uint entry_children_start = self.result.node_count;

			// Parse condition(s) with rollback: try expression parsing,
			// fall back to skip if it fails to reach ->
			self.parse_when_entry_conditions(entry_idx);

			// Arrow: ->
			if (self.eat(ARROW)) {
				// Branch body: block or statement(s)
				if (self.at(LCURL)) {
					self.parse_block();
				} else if (!self.at(RCURL) && !self.at_eof()) {
					// Single expression/statement branch
					self.parse_statement();
				}
			}

			self.adopt_children(entry_idx, entry_children_start);
			self.node_end(entry_idx);

			// Stuck detection
			if (self.current.offset == saved_pos) {
				if (!self.at(RCURL) && !self.at_eof()) {
					self.advance();
				}
			}
		}

		self.expect(RCURL);
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

/**
 * Parse the condition part of a when entry. Tries to parse conditions
 * as expressions (comma-separated). Falls back to token skipping if
 * expression parsing doesn't reach the -> arrow.
 *
 * Handles: literal conditions, is/in checks, else, comma-separated conditions.
 */
fn void Parser.parse_when_entry_conditions(Parser* self, uint entry_idx) {
	// Handle 'else' keyword specially
	if (self.at(KW_ELSE)) {
		self.result.nodes[entry_idx].extra_text = "else";
		self.advance();
		return;
	}

	// Try to parse condition expressions with rollback
	Lexer save_lexer = self.lexer;
	Token save_current = self.current;
	Token save_previous = self.previous;
	uint save_node_count = self.result.node_count;
	usz save_error_count = self.result.error_count;

	// Parse comma-separated condition expressions
	bool success = true;
	while (!self.at(ARROW) && !self.at(RCURL) && !self.at_eof()) {
		// Handle bare `is Type` / `!is Type` (subject implied from when)
		if (self.at(KW_IS) || self.at(NOT_IS)) {
			uint idx = self.add_node(TYPE_CHECK_EXPR);
			self.node_start(idx, self.current);
			self.result.nodes[idx].extra_text = self.current.text;
			self.advance(); // consume 'is' or '!is'

			// Parse the type
			uint type_start = self.current.offset;
			self.skip_type_ref();
			uint type_end = self.previous.offset + self.previous.len;
			if (type_end > type_start) {
				self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
			}
			self.node_end(idx);
		} else if (self.at(KW_IN) || self.at(NOT_IN)) {
			// Handle bare `in range` (subject implied)
			self.advance(); // consume 'in' or '!in'
			self.parse_expression(PREC_NONE);
		} else {
			self.parse_expression(PREC_NONE);
		}

		if (self.at(ARROW)) break;
		if (self.at(COMMA)) {
			self.advance(); // consume comma between conditions
			continue;
		}
		// Unexpected token -- expression parsing didn't handle condition
		success = false;
		break;
	}

	if (success && self.at(ARROW)) {
		// Expression parsing succeeded -- conditions are now AST children
		return;
	}

	// Rollback and fall back to token skipping
	self.lexer = save_lexer;
	self.current = save_current;
	self.previous = save_previous;
	self.result.node_count = save_node_count;
	self.result.error_count = save_error_count;
	self.skip_when_condition();
}

/**
 * Skip the condition part of a when branch until we find ->.
 * Handles: literals, is/in checks, commas between conditions,
 * and nested expressions in parens/brackets.
 */
fn void Parser.skip_when_condition(Parser* self) {
	int depth = 0;
	while (!self.at_eof()) {
		// Skip string literals atomically (they may contain RCURL from templates)
		if (self.at(STRING_OPEN) || self.at(MULTILINE_STRING_OPEN)) {
			self.skip_string_tokens();
			continue;
		}
		if (self.at(LCURL)) {
			if (depth == 0) return; // start of a block, not part of condition
			depth++;
			self.advance();
			continue;
		}
		if (self.at(RCURL)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}
		if (self.at(LPAREN)) { depth++; self.advance(); continue; }
		if (self.at(RPAREN)) {
			if (depth == 0) return;
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

		// Arrow at depth 0 ends the condition
		if (depth == 0 && self.at(ARROW)) return;

		self.advance();
	}
}

// ── For statement ─────────────────────────────────────────────────

/**
 * Parse for statement:
 *   for (variable in collection) block
 *   for ((a, b) in collection) block
 */
fn void Parser.parse_for_stmt(Parser* self) {
	uint idx = self.add_node(FOR_STMT);
	self.node_start(idx, self.current);
	self.advance(); // consume 'for'
	uint children_start = self.result.node_count;

	if (self.eat(LPAREN)) {
		// Loop variable -- may be destructuring: (a, b)
		if (self.at(LPAREN)) {
			// Destructuring declaration -- parse individual names as PARAM nodes
			self.advance(); // consume '('
			while (!self.at(RPAREN) && !self.at_eof()) {
				if (self.at(COMMA)) {
					self.advance(); // consume ','
					continue;
				}
				if (self.at_identifier()) {
					uint param_idx = self.add_node(PARAM);
					self.node_start(param_idx, self.current);
					Token name = self.expect_identifier();
					self.node_set_name(param_idx, name);
					// Optional type annotation: (a: Int, b: String)
					if (self.eat(COLON)) {
						uint type_start = self.current.offset;
						self.skip_type_ref();
						uint type_end = self.previous.offset + self.previous.len;
						if (type_end > type_start) {
							self.result.nodes[param_idx].type_text = self.source[type_start:type_end - type_start];
						}
					}
					self.node_end(param_idx);
				} else {
					// Skip unexpected token
					self.advance();
				}
			}
			self.expect(RPAREN);
		} else if (self.at_identifier()) {
			// Simple loop variable -- create a PARAM node for it
			uint param_idx = self.add_node(PARAM);
			self.node_start(param_idx, self.current);
			Token name = self.expect_identifier();
			self.node_set_name(param_idx, name);

			// Optional type annotation: variable: Type
			if (self.eat(COLON)) {
				uint type_start = self.current.offset;
				self.skip_type_ref();
				uint type_end = self.previous.offset + self.previous.len;
				if (type_end > type_start) {
					self.result.nodes[param_idx].type_text = self.source[type_start:type_end - type_start];
				}
			}
			self.node_end(param_idx);
		}

		// 'in' keyword
		if (self.at(KW_IN)) {
			self.advance();
		}

		// Parse collection expression (creates an AST node for type resolution)
		if (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_expression(PREC_NONE);
		}

		self.expect(RPAREN);
	}

	// Body
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (!self.at(RCURL) && !self.at_eof()) {
		self.parse_statement();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

/**
 * Skip tokens until a matching closing ')' at depth 0.
 * Does NOT consume the ')'.
 */
fn void Parser.skip_until_closing_paren(Parser* self) {
	int depth = 0;
	while (!self.at_eof()) {
		// Skip string literals atomically (they may contain RCURL from templates)
		if (self.at(STRING_OPEN) || self.at(MULTILINE_STRING_OPEN)) {
			self.skip_string_tokens();
			continue;
		}
		if (self.at(LPAREN)) { depth++; self.advance(); continue; }
		if (self.at(RPAREN)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}
		if (self.at(LCURL)) { depth++; self.advance(); continue; }
		if (self.at(RCURL)) {
			if (depth == 0) return;
			depth--;
			self.advance();
			continue;
		}
		self.advance();
	}
}

// ── While statement ───────────────────────────────────────────────

/**
 * Parse while statement: while (condition) block
 */
fn void Parser.parse_while_stmt(Parser* self) {
	uint idx = self.add_node(WHILE_STMT);
	self.node_start(idx, self.current);
	self.advance(); // consume 'while'
	uint children_start = self.result.node_count;

	// Condition: (expr) -- try to parse the expression inside parens as
	// an AST child for hover, completion, go-to-definition, etc. Fall back
	// to skip_balanced_parens if expression parsing can't consume the
	// full condition (e.g. due to < and > ambiguity with generics).
	if (self.at(LPAREN)) {
		// Save parser state for rollback
		Lexer save_lexer = self.lexer;
		Token save_current = self.current;
		Token save_previous = self.previous;
		uint save_node_count = self.result.node_count;
		usz save_error_count = self.result.error_count;

		self.advance(); // consume '('
		if (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_expression(0);
		}

		if (self.at(RPAREN)) {
			// Expression parsing consumed the condition correctly
			self.advance(); // consume ')'
		} else {
			// Rollback and fall back to skipping
			self.lexer = save_lexer;
			self.current = save_current;
			self.previous = save_previous;
			self.result.node_count = save_node_count;
			self.result.error_count = save_error_count;
			self.skip_balanced_parens();
		}
	}

	// Body
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (!self.at(RCURL) && !self.at_eof()) {
		self.parse_statement();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Do-while statement ────────────────────────────────────────────

/**
 * Parse do-while statement: do block while (condition)
 */
fn void Parser.parse_do_while_stmt(Parser* self) {
	uint idx = self.add_node(DO_WHILE_STMT);
	self.node_start(idx, self.current);
	self.advance(); // consume 'do'
	uint children_start = self.result.node_count;

	// Body
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (!self.at(RCURL) && !self.at_eof()) {
		self.parse_statement();
	}

	// while (condition) -- try to parse the expression inside parens as
	// an AST child for hover, completion, go-to-definition, etc. Fall back
	// to skip_balanced_parens if expression parsing can't consume the
	// full condition (e.g. due to < and > ambiguity with generics).
	if (self.eat(KW_WHILE)) {
		if (self.at(LPAREN)) {
			// Save parser state for rollback
			Lexer save_lexer = self.lexer;
			Token save_current = self.current;
			Token save_previous = self.previous;
			uint save_node_count = self.result.node_count;
			usz save_error_count = self.result.error_count;

		self.advance(); // consume '('
			if (!self.at(RPAREN) && !self.at_eof()) {
				self.parse_expression(0);
			}

			if (self.at(RPAREN)) {
				// Expression parsing consumed the condition correctly
				self.advance(); // consume ')'
			} else {
				// Rollback and retry with < > as comparison operators
				self.lexer = save_lexer;
				self.current = save_current;
				self.previous = save_previous;
				self.result.node_count = save_node_count;
				self.result.error_count = save_error_count;

				self.allow_angle_comparison = true;
				self.advance(); // consume '('
				if (!self.at(RPAREN) && !self.at_eof()) {
					self.parse_expression(0);
				}
				self.allow_angle_comparison = false;

				if (self.at(RPAREN)) {
					self.advance(); // consume ')'
				} else {
					// Still can't parse -- final fallback to skipping
					self.lexer = save_lexer;
					self.current = save_current;
					self.previous = save_previous;
					self.result.node_count = save_node_count;
					self.result.error_count = save_error_count;
					self.skip_balanced_parens();
				}
			}
		}
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Try expression ────────────────────────────────────────────────

/**
 * Parse try expression:
 *   try { ... } catch (e: Type) { ... } finally { ... }
 */
fn void Parser.parse_try_expr(Parser* self) {
	uint idx = self.add_node(TRY_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'try'
	uint children_start = self.result.node_count;

	// Try block
	if (self.at(LCURL)) {
		self.parse_block();
	}

	// Catch clauses
	while (self.at(KW_CATCH)) {
		self.parse_catch_clause();
	}

	// Finally block
	if (self.eat(KW_FINALLY)) {
		if (self.at(LCURL)) {
			self.parse_block();
		}
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

/**
 * Parse a catch clause: catch (e: ExceptionType) { ... }
 * The CATCH_CLAUSE node acts as a scope for the exception parameter.
 */
fn void Parser.parse_catch_clause(Parser* self) {
	uint idx = self.add_node(CATCH_CLAUSE);
	self.node_start(idx, self.current);
	self.advance(); // consume 'catch'
	uint children_start = self.result.node_count;

	// Parameter: (e: Type)
	if (self.eat(LPAREN)) {
		if (self.at_identifier()) {
			uint param_idx = self.add_node(PARAM);
			self.node_start(param_idx, self.current);
			Token name = self.expect_identifier();
			self.node_set_name(param_idx, name);

			if (self.eat(COLON)) {
				uint type_start = self.current.offset;
				self.skip_type_ref();
				uint type_end = self.previous.offset + self.previous.len;
				if (type_end > type_start) {
					self.result.nodes[param_idx].type_text = self.source[type_start:type_end - type_start];
				}
			}
			self.node_end(param_idx);
		}
		self.expect(RPAREN);
	}

	// Catch body
	if (self.at(LCURL)) {
		self.parse_block();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

// ── Return / throw ────────────────────────────────────────────────

/**
 * Parse return expression: return expr?
 * May have a label: return@label expr
 */
fn uint Parser.parse_return_expr(Parser* self) {
	uint idx = self.add_node(RETURN_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'return'
	uint children_start = self.result.node_count;

	// Optional label: @label  -- store name in extra_text for go-to-def
	if (self.eat(AT)) {
		if (self.at_identifier()) {
			self.result.nodes[idx].extra_text = self.current.text;
			self.advance();
		}
	}

	// Optional return value
	if (!self.at(RCURL) && !self.at(SEMICOLON) && !self.at_eof()) {
		// Parse expression unless it looks like a new statement.
		// Exception: if/when/try are both statement starters AND expressions,
		// so after 'return' they should be parsed as the return value.
		if (!is_statement_start(self.current.kind) ||
		    self.current.kind == KW_WHEN || self.current.kind == KW_IF ||
		    self.current.kind == KW_TRY || self.current.kind == KW_OBJECT) {
			self.parse_expression(PREC_NONE);
		}
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse throw expression: throw expr
 */
fn uint Parser.parse_throw_expr(Parser* self) {
	uint idx = self.add_node(THROW_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'throw'
	uint children_start = self.result.node_count;

	// Skip the thrown expression
	if (!self.at(RCURL) && !self.at(SEMICOLON) && !self.at_eof()) {
		self.parse_expression(PREC_NONE);
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

// ── Break / continue ──────────────────────────────────────────────

/**
 * Parse break or continue: break@label? / continue@label?
 */
fn void Parser.parse_break_continue(Parser* self, NodeKind kind) {
	uint idx = self.add_node(kind);
	self.node_start(idx, self.current);
	self.advance(); // consume 'break' or 'continue'

	// Optional label: @label  -- store name in extra_text
	// TODO(labeled-loops): go-to-definition for `break@label` / `continue@label`
	// currently resolves only to enclosing FUN_DECL/LAMBDA_EXPR with matching
	// name (see definition::find_label_target). Labeled loops `outer@ for ...`
	// are not yet parsed -- the `outer@` prefix is dropped. Once labeled loops
	// produce a FOR_STMT/WHILE_STMT/DO_STMT with `extra_text == "outer"`,
	// extend find_label_target to match those node kinds too.
	// See AGENTS.md "NOT DONE (deferred)" section for full context.
	if (self.eat(AT)) {
		if (self.at_identifier()) {
			self.result.nodes[idx].extra_text = self.current.text;
			self.advance();
		}
	}

	self.node_end(idx);
}

// ── Expression parsing (Pratt precedence climbing) ────────────────

/**
 * Precedence levels for Kotlin operators (low to high).
 * Higher values bind more tightly.
 */
const int PREC_NONE        = 0;
const int PREC_ASSIGNMENT   = 1;  // =, +=, -=, *=, /=, %=
const int PREC_DISJUNCTION  = 2;  // ||
const int PREC_CONJUNCTION  = 3;  // &&
const int PREC_EQUALITY     = 4;  // ==, !=, ===, !==
const int PREC_COMPARISON   = 5;  // <, >, <=, >=
const int PREC_NAMED_CHECK  = 6;  // in, !in, is, !is
const int PREC_ELVIS        = 7;  // ?:
const int PREC_INFIX_CALL   = 8;  // infix function calls: a to b, a and b, etc.
const int PREC_RANGE        = 9;  // ..
const int PREC_ADDITIVE     = 10; // +, -
const int PREC_MULTIPLICATIVE = 11; // *, /, %
const int PREC_TYPE_CAST    = 12; // as, as?
const int PREC_PREFIX       = 13; // -, !, ++, --
const int PREC_POSTFIX      = 14; // ++, --, !!, ., ?., (), [], ::

/**
 * Get the infix/binary precedence level for a token kind.
 * Returns PREC_NONE if the token is not a binary operator.
 */
fn int infix_precedence(TokenKind kind) {
	switch (kind) {
		case ASSIGNMENT:   return PREC_ASSIGNMENT;
		case ADD_ASSIGN:   return PREC_ASSIGNMENT;
		case SUB_ASSIGN:   return PREC_ASSIGNMENT;
		case MULT_ASSIGN:  return PREC_ASSIGNMENT;
		case DIV_ASSIGN:   return PREC_ASSIGNMENT;
		case MOD_ASSIGN:   return PREC_ASSIGNMENT;
		case DISJ:         return PREC_DISJUNCTION;
		case CONJ:         return PREC_CONJUNCTION;
		case EQEQ:         return PREC_EQUALITY;
		case EXCL_EQ:      return PREC_EQUALITY;
		case EQEQEQ:       return PREC_EQUALITY;
		case EXCL_EQEQ:    return PREC_EQUALITY;
		// NOTE: LANGLE and RANGLE are intentionally omitted.
		// They are ambiguous with generic type arguments (e.g. List<Int>),
		// and correct disambiguation requires type information.
		// LE (<=) and GE (>=) are unambiguous and included.
		case LE:           return PREC_COMPARISON;
		case GE:           return PREC_COMPARISON;
		case KW_IN:        return PREC_NAMED_CHECK;
		case NOT_IN:       return PREC_NAMED_CHECK;
		case KW_IS:        return PREC_NAMED_CHECK;
		case NOT_IS:       return PREC_NAMED_CHECK;
		case ELVIS:        return PREC_ELVIS;
		case RANGE:        return PREC_RANGE;
		case RANGE_UNTIL:  return PREC_RANGE;
		case ADD:          return PREC_ADDITIVE;
		case SUB:          return PREC_ADDITIVE;
		case MULT:         return PREC_MULTIPLICATIVE;
		case DIV:          return PREC_MULTIPLICATIVE;
		case MOD:          return PREC_MULTIPLICATIVE;
		case KW_AS:        return PREC_TYPE_CAST;
		case AS_SAFE:      return PREC_TYPE_CAST;
		default:           return PREC_NONE;
	}
}

/**
 * Check if a binary operator is right-associative.
 */
fn bool is_right_assoc(TokenKind kind) {
	switch (kind) {
		case ASSIGNMENT:  return true;
		case ADD_ASSIGN:  return true;
		case SUB_ASSIGN:  return true;
		case MULT_ASSIGN: return true;
		case DIV_ASSIGN:  return true;
		case MOD_ASSIGN:  return true;
		case ELVIS:       return true;
		default:          return false;
	}
}

/**
 * Check if a token kind is an assignment operator.
 */
fn bool is_assignment_op(TokenKind kind) {
	switch (kind) {
		case ASSIGNMENT:  return true;
		case ADD_ASSIGN:  return true;
		case SUB_ASSIGN:  return true;
		case MULT_ASSIGN: return true;
		case DIV_ASSIGN:  return true;
		case MOD_ASSIGN:  return true;
		default:          return false;
	}
}

/**
 * Parse an expression statement: parse a full expression, then
 * consume an optional semicolon. Returns true if tokens were consumed.
 */
fn bool Parser.parse_expression_statement(Parser* self) {
	if (self.at(RCURL) || self.at_eof()) return false;

	uint before = self.result.node_count;
	self.parse_expression(PREC_NONE);

	if (self.result.node_count == before) {
		// No expression was parsed -- skip one token for error recovery
		if (!self.at(RCURL) && !self.at_eof()) {
			self.advance();
		}
		return true;
	}

	self.eat(SEMICOLON);
	return true;
}

/**
 * Parse an expression with Pratt precedence climbing.
 * min_prec is the minimum precedence that this call will consume.
 * Returns the index of the expression node, or the current node_count if nothing parsed.
 */
fn uint Parser.parse_expression(Parser* self, int min_prec) {
	// Parse prefix / primary
	uint left = self.parse_prefix_or_primary();
	if (left >= self.result.node_count) return left; // nothing parsed

	// Parse postfix suffixes: .name, ?.name, (), [], !!, ++, --
	left = self.parse_postfix_chain(left);

	// Parse infix / binary operators via precedence climbing
	while (!self.at_eof()) {
		int prec = infix_precedence(self.current.kind);

		// When allow_angle_comparison is set (if/while conditions),
		// treat < and > as comparison operators instead of generic delimiters.
		if (prec == PREC_NONE && self.allow_angle_comparison
			&& (self.current.kind == LANGLE || self.current.kind == RANGLE)) {
			prec = PREC_COMPARISON;
		}

		// Infix function calls: `a to b`, `a until b`, `a downTo b`, etc.
		// Only recognize a few well-known infix functions to avoid
		// mistakenly treating statement-initial identifiers as infix calls.
		if (prec == PREC_NONE && PREC_INFIX_CALL >= min_prec
			&& self.is_user_or_known_infix(self.current.text)) {
			prec = PREC_INFIX_CALL;
		}

		if (prec == PREC_NONE || prec < min_prec) break;

		// Handle is/!is and as/as? specially (right side is a type, not expression)
		if (self.current.kind == KW_IS || self.current.kind == NOT_IS) {
			left = self.parse_type_check(left);
			left = self.parse_postfix_chain(left);
			continue;
		}
		if (self.current.kind == KW_AS || self.current.kind == AS_SAFE) {
			left = self.parse_type_cast(left);
			left = self.parse_postfix_chain(left);
			continue;
		}

		TokenKind op_kind = self.current.kind;
		Token op_tok = self.current;
		int next_prec = is_right_assoc(op_kind) ? prec : prec + 1;

		// Create the binary/assignment node
		NodeKind node_kind = is_assignment_op(op_kind) ? ASSIGNMENT_EXPR : BINARY_EXPR;
		uint bin_idx = self.add_node(node_kind);
		self.result.nodes[bin_idx].start_offset = self.result.nodes[left].start_offset;
		self.result.nodes[bin_idx].start_line = self.result.nodes[left].start_line;
		self.result.nodes[bin_idx].start_col = self.result.nodes[left].start_col;
		self.result.nodes[bin_idx].extra_text = op_tok.text;

		self.advance(); // consume operator

		// Adopt left operand
		self.result.nodes[left].parent = bin_idx;

		// Parse right operand
		uint right = self.parse_expression(next_prec);

		// Adopt right operand (if parsed)
		if (right < self.result.node_count) {
			self.result.nodes[right].parent = bin_idx;
		}

		self.result.nodes[bin_idx].child_count =
			(right < self.result.node_count) ? 2 : 1;
		self.node_end(bin_idx);
		left = bin_idx;
	}

	return left;
}

/**
 * Parse a prefix unary expression or a primary expression.
 */
fn uint Parser.parse_prefix_or_primary(Parser* self) {
	switch (self.current.kind) {
		case SUB:
			nextcase;
		case EXCL:
			nextcase;
		case INCR:
			nextcase;
		case DECR:
			return self.parse_prefix_expr();
		case MULT:
			// Spread operator: *array
			return self.parse_spread_expr();
		default:
			return self.parse_primary();
	}
}

/**
 * Parse a prefix unary expression: -expr, !expr, ++expr, --expr
 */
fn uint Parser.parse_prefix_expr(Parser* self) {
	uint idx = self.add_node(PREFIX_EXPR);
	self.node_start(idx, self.current);
	self.result.nodes[idx].extra_text = self.current.text;
	self.advance(); // consume operator

	uint children_start = self.result.node_count;
	uint operand = self.parse_prefix_or_primary();
	if (operand < self.result.node_count) {
		operand = self.parse_postfix_chain(operand);
	}
	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse spread expression: *array
 */
fn uint Parser.parse_spread_expr(Parser* self) {
	uint idx = self.add_node(SPREAD_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume '*'

	uint children_start = self.result.node_count;
	uint operand = self.parse_prefix_or_primary();
	if (operand < self.result.node_count) {
		operand = self.parse_postfix_chain(operand);
	}
	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse a primary expression.
 */
fn uint Parser.parse_primary(Parser* self) {
	switch (self.current.kind) {
		case IDENTIFIER:
			// Detect labeled lambda: `label@ { ... }` -- IDENT AT LCURL on same line.
			if (self.peek_is_label_at_for_lambda()) {
				return self.parse_labeled_lambda_expr();
			}
			return self.parse_name_expr();

		case INTEGER_LITERAL:
			nextcase;
		case FLOAT_LITERAL:
			nextcase;
		case CHARACTER_LITERAL:
			nextcase;
		case BOOLEAN_LITERAL:
			nextcase;
		case NULL_LITERAL:
			nextcase;
		case STRING_CONTENT:
			return self.parse_literal_expr();

		case STRING_OPEN:
			nextcase;
		case MULTILINE_STRING_OPEN:
			return self.parse_string_template_expr();

		case KW_THIS:
			return self.parse_this_expr();

		case KW_SUPER:
			return self.parse_super_expr();

		case LPAREN:
			return self.parse_paren_expr();

		case LCURL:
			return self.parse_lambda_expr();

		case COLONCOLON:
			return self.parse_callable_ref_expr();

		case KW_OBJECT:
			return self.parse_object_expr();

		case KW_FUN:
			return self.parse_anonymous_fun_expr();

		case KW_IF:
			return self.parse_if_as_expr();

		case KW_WHEN:
			return self.parse_when_as_expr();

		case KW_TRY:
			return self.parse_try_as_expr();

		case KW_THROW:
			return self.parse_throw_expr();

		case KW_RETURN:
			return self.parse_return_expr();

		default:
			break;
	}

	// Soft keywords can be identifiers in expression position
	if (is_soft_keyword(self.current.kind)) {
		return self.parse_name_expr();
	}

	// Some hard keywords can also appear as identifiers in expression position
	// (e.g. 'out' as named argument: foo(out = bar))
	if (self.current.kind == KW_OUT || self.current.kind == KW_IN) {
		return self.parse_name_expr();
	}

	return self.result.node_count; // nothing parsed
}

/**
 * Parse a simple identifier reference: NAME_EXPR.
 */
fn uint Parser.parse_name_expr(Parser* self) {
	uint idx = self.add_node(NAME_EXPR);
	self.node_start(idx, self.current);
	self.node_set_name(idx, self.current);
	self.advance(); // consume identifier/soft keyword
	self.node_end(idx);
	return idx;
}

/**
 * Parse a literal expression: integer, float, char, boolean, null.
 */
fn uint Parser.parse_literal_expr(Parser* self) {
	uint idx = self.add_node(LITERAL_EXPR);
	self.node_start(idx, self.current);
	self.result.nodes[idx].extra_text = self.current.text;
	self.advance();
	self.node_end(idx);
	return idx;
}

/**
 * Parse a string template expression: "...", """..."""
 * Skips string content tokens until close.
 */
fn uint Parser.parse_string_template_expr(Parser* self) {
	uint idx = self.add_node(STRING_TEMPLATE_EXPR);
	self.node_start(idx, self.current);
	uint children_start = self.result.node_count;

	TokenKind close_kind = (self.current.kind == STRING_OPEN) ? STRING_CLOSE : MULTILINE_STRING_CLOSE;
	self.advance(); // consume open

	while (!self.at_eof()) {
		if (self.current.kind == close_kind) {
			self.advance(); // consume close
			break;
		}
		if (self.current.kind == STRING_TEMPLATE_REF) {
			// $identifier -- create a NAME_EXPR child
			uint ref_idx = self.add_node(NAME_EXPR);
			self.node_start(ref_idx, self.current);
			// The text includes $ prefix, so strip it for the name
			String ref_text = self.current.text;
			if (ref_text.len > 1 && ref_text[0] == '$') {
				ref_text = ref_text[1..];
			}
			self.result.nodes[ref_idx].name = ref_text;
			self.result.nodes[ref_idx].name_offset = self.current.offset + 1;
			self.result.nodes[ref_idx].name_line = self.current.line;
			self.result.nodes[ref_idx].name_col = self.current.col + 1;
			self.result.nodes[ref_idx].name_len = self.current.len > 1 ? self.current.len - 1 : 0;
			self.node_end(ref_idx);
			self.advance();
			continue;
		}
		if (self.current.kind == STRING_TEMPLATE_START) {
			// ${ ... } -- parse enclosed expression
			self.advance(); // consume ${
			if (!self.at(RCURL) && !self.at_eof()) {
				self.parse_expression(PREC_NONE);
			}
			self.eat(RCURL);
			continue;
		}
		// STRING_CONTENT or other string tokens -- skip
		self.advance();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse 'this' expression, optionally with label: this@label
 */
fn uint Parser.parse_this_expr(Parser* self) {
	uint idx = self.add_node(THIS_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'this'

	// Optional label: @label
	if (self.eat(AT)) {
		if (self.at_identifier()) {
			self.result.nodes[idx].name = self.current.text;
			self.advance();
		}
	}

	self.node_end(idx);
	return idx;
}

/**
 * Parse 'super' expression: super, super@label, super<Type>
 */
fn uint Parser.parse_super_expr(Parser* self) {
	uint idx = self.add_node(SUPER_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'super'

	// Generic qualifier: super<Type>
	if (self.at(LANGLE)) {
		self.parse_type_args();
	}

	// Optional label: @label
	if (self.eat(AT)) {
		if (self.at_identifier()) {
			self.result.nodes[idx].name = self.current.text;
			self.advance();
		}
	}

	self.node_end(idx);
	return idx;
}

/**
 * Parse parenthesized expression: (expr)
 */
fn uint Parser.parse_paren_expr(Parser* self) {
	uint idx = self.add_node(PAREN_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume '('
	uint children_start = self.result.node_count;

	if (!self.at(RPAREN) && !self.at_eof()) {
		self.parse_expression(PREC_NONE);
	}

	self.expect(RPAREN);
	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse a labeled lambda expression: `label@ { ... }`.
 * Caller has already verified via `peek_is_label_at_for_lambda` that the
 * current IDENT is followed by `AT LCURL` on the same line.
 * Stores the label name in `LAMBDA_EXPR.extra_text` for `return@label` resolution.
 */
fn uint Parser.parse_labeled_lambda_expr(Parser* self) {
	Token label_tok = self.current;
	self.advance(); // consume label IDENT
	self.advance(); // consume AT
	uint idx = self.parse_lambda_expr();
	self.result.nodes[idx].extra_text = label_tok.text;
	// Extend start to cover the label so highlights/folds include it.
	self.result.nodes[idx].start_offset = label_tok.offset;
	return idx;
}

/**
 * Parse lambda expression: { body } or { params -> body }
 * Lambda parameters create PARAM child nodes.
 */
fn uint Parser.parse_lambda_expr(Parser* self) {
	uint idx = self.add_node(LAMBDA_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume '{'
	uint children_start = self.result.node_count;

	// Try to detect lambda parameters by looking for '->'
	// Heuristic: if we see `identifier ->` or `identifier, identifier ->` or
	// `identifier: Type ->` early on, these are lambda parameters.
	if (self.looks_like_lambda_params()) {
		self.parse_lambda_params();
		self.eat(ARROW); // consume '->'
	}

	// Parse body statements
	while (!self.at(RCURL) && !self.at_eof()) {
		self.eat(SEMICOLON);
		if (self.at(RCURL) || self.at_eof()) break;

		uint saved_pos = self.current.offset;

		if (!self.parse_statement()) {
			if (!self.at(RCURL) && !self.at_eof()) {
				self.advance();
			}
		} else if (self.current.offset == saved_pos) {
			if (!self.at(RCURL) && !self.at_eof()) {
				self.advance();
			}
		}
	}

	self.expect(RCURL);
	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse anonymous function expression (Kotlin spec §17.7).
 *
 * Forms:
 *   fun(params): ReturnType { body }
 *   fun(params) = expr
 *   fun name(params): T { body }       -- name is rare, allowed
 *   fun Receiver.(params): T { body }  -- extension form (best-effort)
 *
 * Caller has already determined `fun` here begins an expression
 * (not a top-level/local declaration).
 */
fn uint Parser.parse_anonymous_fun_expr(Parser* self) {
	uint idx = self.add_node(ANONYMOUS_FUN_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'fun'
	uint children_start = self.result.node_count;

	// Optional name (rare): fun foo() {...}
	if (self.at_identifier() && !self.at(LPAREN)) {
		// Could be either name or extension receiver. If next-after-ident is
		// '.' or '?.' or '<', treat first ident as receiver (best-effort).
		Token first = self.expect_identifier();
		if (self.at(LANGLE)) {
			uint recv_start = first.offset;
			self.parse_type_args();
			if (self.at(QUEST)) self.advance();
			if (self.eat(DOT) || self.eat(SAFE_CALL)) {
				uint recv_end = self.previous.offset;
				self.result.nodes[idx].extra_text = self.source[recv_start:recv_end - recv_start];
			}
		} else if (self.eat(DOT) || self.eat(SAFE_CALL)) {
			self.result.nodes[idx].extra_text = first.text;
		} else {
			// Plain name on anonymous fun
			self.node_set_name(idx, first);
		}
	}

	// Parameters: ( ... )
	if (self.at(LPAREN)) {
		self.advance(); // consume '('
		while (!self.at(RPAREN) && !self.at_eof()) {
			self.parse_param();
			if (!self.eat(COMMA)) break;
		}
		self.expect(RPAREN);
	}

	// Optional return type: : Type
	if (self.eat(COLON)) {
		uint type_start = self.current.offset;
		self.skip_type_ref();
		uint type_end = self.previous.offset + self.previous.len;
		if (type_end > type_start) {
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		}
	}

	// Body: { block } or = expr  (both optional -- tolerate missing body)
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (self.eat(ASSIGNMENT)) {
		self.parse_expression_body();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Heuristic: look ahead to see if the beginning of a brace block
 * looks like lambda parameters (identifier(s) followed by ->).
 * This is an approximation -- we don't consume any tokens.
 */
fn bool Parser.looks_like_lambda_params(Parser* self) {
	// Save state for lookahead
	Lexer saved_lexer = self.lexer;
	Token saved_current = self.current;
	Token saved_previous = self.previous;

	bool result = false;
	int depth = 0;
	int token_count = 0;
	const int MAX_LOOKAHEAD = 50; // don't look too far

	while (!self.at_eof() && token_count < MAX_LOOKAHEAD) {
		if (self.at(ARROW) && depth == 0) {
			result = true;
			break;
		}
		if (self.at(RCURL) && depth == 0) break; // end of block, no arrow found
		if (self.at(SEMICOLON) && depth == 0) break; // statement separator

		// Track nesting
		if (self.at(LPAREN) || self.at(LSQUARE) || self.at(LANGLE) || self.at(LCURL)) { depth++; }
		if (self.at(RPAREN) || self.at(RSQUARE) || self.at(RANGLE) || self.at(RCURL)) { depth--; }

		// If we see a statement keyword at depth 0, this is not params
		if (depth == 0 && is_statement_start(self.current.kind)) break;

		self.advance();
		token_count++;
	}

	// Restore state
	self.lexer = saved_lexer;
	self.current = saved_current;
	self.previous = saved_previous;
	return result;
}

/**
 * Parse lambda parameters before the -> arrow.
 * Creates PARAM nodes for each parameter.
 */
fn void Parser.parse_lambda_params(Parser* self) {
	while (!self.at(ARROW) && !self.at(RCURL) && !self.at_eof()) {
		if (self.at_identifier()) {
			uint param_idx = self.add_node(PARAM);
			self.node_start(param_idx, self.current);
			Token name = self.expect_identifier();
			self.node_set_name(param_idx, name);

			// Optional type: : Type
			if (self.eat(COLON)) {
				uint type_start = self.current.offset;
				self.skip_type_ref();
				uint type_end = self.previous.offset + self.previous.len;
				if (type_end > type_start) {
					self.result.nodes[param_idx].type_text = self.source[type_start:type_end - type_start];
				}
			}

			self.node_end(param_idx);
		} else if (self.at(LPAREN)) {
			// Destructuring parameter: (a, b) or (_, dp)
			self.advance(); // consume '('
			while (!self.at(RPAREN) && !self.at_eof()) {
				if (self.at(COMMA)) {
					self.advance();
					continue;
				}
				if (self.at_identifier()) {
					// Skip underscore placeholders -- no PARAM node needed
					if (self.current.text == "_") {
						self.advance();
					} else {
						uint param_idx = self.add_node(PARAM);
						self.node_start(param_idx, self.current);
						Token name = self.expect_identifier();
						self.node_set_name(param_idx, name);
						// Optional type annotation: (a: Int, b: String)
						if (self.eat(COLON)) {
							uint type_start = self.current.offset;
							self.skip_type_ref();
							uint type_end = self.previous.offset + self.previous.len;
							if (type_end > type_start) {
								self.result.nodes[param_idx].type_text = self.source[type_start:type_end - type_start];
							}
						}
						self.node_end(param_idx);
					}
				} else {
					self.advance(); // skip unexpected token
				}
			}
			if (self.at(RPAREN)) self.advance(); // consume ')'
		}

		if (!self.eat(COMMA)) break;
	}
}

/**
 * Parse callable reference: ::name
 * (Type::name is handled as postfix on a name expression)
 */
fn uint Parser.parse_callable_ref_expr(Parser* self) {
	uint idx = self.add_node(CALLABLE_REF_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume '::'

	if (self.at_identifier() || self.at(KW_CLASS)) {
		self.node_set_name(idx, self.current);
		self.advance();
	}

	self.node_end(idx);
	return idx;
}

/**
 * Parse object expression: object : SuperType { body }
 */
fn uint Parser.parse_object_expr(Parser* self) {
	uint idx = self.add_node(OBJECT_EXPR);
	self.node_start(idx, self.current);
	self.advance(); // consume 'object'
	uint children_start = self.result.node_count;

	// Super types: : Type
	if (self.at(COLON)) {
		self.parse_super_types();
	}

	// Body
	if (self.at(LCURL)) {
		self.parse_class_body(false);
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
	return idx;
}

/**
 * Parse if as an expression (reuses parse_if_expr).
 * Returns the index of the IF_EXPR node.
 */
fn uint Parser.parse_if_as_expr(Parser* self) {
	uint idx = self.result.node_count;
	self.parse_if_expr();
	return idx;
}

/**
 * Parse when as an expression (reuses parse_when_expr).
 * Returns the index of the WHEN_EXPR node.
 */
fn uint Parser.parse_when_as_expr(Parser* self) {
	uint idx = self.result.node_count;
	self.parse_when_expr();
	return idx;
}

/**
 * Parse try as an expression (reuses parse_try_expr).
 * Returns the index of the TRY_EXPR node.
 */
fn uint Parser.parse_try_as_expr(Parser* self) {
	uint idx = self.result.node_count;
	self.parse_try_expr();
	return idx;
}

/**
 * Parse a chain of postfix operators on an expression.
 * Handles: .name, ?.name, (args), [index], !!, ++, --, ::name
 */
fn uint Parser.parse_postfix_chain(Parser* self, uint left) {
	while (!self.at_eof()) {
		switch (self.current.kind) {
			case DOT:
				left = self.parse_dot_access(left, false);
			case SAFE_CALL:
				left = self.parse_dot_access(left, true);
			case LPAREN:
				left = self.parse_call_expr(left);
			case LSQUARE:
				left = self.parse_index_expr(left);
			case NOT_NULL:
				left = self.parse_not_null_postfix(left);
			case INCR:
				// Postfix ++ only if no line break before
				// For simplicity, always treat as postfix here
				left = self.parse_postfix_incr_decr(left);
			case DECR:
				left = self.parse_postfix_incr_decr(left);
			case COLONCOLON:
				left = self.parse_member_ref(left);
		case LANGLE:
			// Generic type arguments: name<Type>() or name<A, B>
			// Only after name-like expressions. Parse the type arguments.
			if (self.is_generic_context(left)) {
				self.parse_type_args();
			} else {
				return left;
			}
			case LCURL:
				// Trailing lambda: only after call-like expressions or identifiers
				// Heuristic: if the previous expression is a name or call, this is a trailing lambda
				if (self.is_trailing_lambda_context(left)) {
					left = self.parse_trailing_lambda(left);
				} else {
					return left;
				}
			default:
				return left;
		}
	}
	return left;
}

/**
 * Check if a trailing lambda makes sense after the given expression.
 */
fn bool Parser.is_trailing_lambda_context(Parser* self, uint left) {
	if (left >= self.result.node_count) return false;
	NodeKind kind = self.result.nodes[left].kind;
	switch (kind) {
		case NAME_EXPR:
		case CALL_EXPR:
		case DOT_EXPR:
			return true;
		default:
			return false;
	}
}

/**
 * Check if generic type arguments (<...>) make sense after the given expression.
 * Only valid after name-like expressions.
 */
fn bool Parser.is_generic_context(Parser* self, uint left) {
	if (left >= self.result.node_count) return false;
	NodeKind kind = self.result.nodes[left].kind;
	switch (kind) {
		case NAME_EXPR:
		case DOT_EXPR:
			return true;
		default:
			return false;
	}
}

/**
 * Parse dot access: expr.name or expr?.name
 */
fn uint Parser.parse_dot_access(Parser* self, uint left, bool safe) {
	uint idx = self.add_node(DOT_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;
	if (safe) {
		self.result.nodes[idx].extra_text = "?.";
	}

	self.advance(); // consume '.' or '?.'

	// Member name: identifiers, soft keywords, and some hard keywords
	// In Kotlin, keywords like 'class', 'in', 'out' can appear as member names
	if (self.at_identifier() || self.at(KW_CLASS) || self.at(KW_OUT) || self.at(KW_IN)) {
		self.node_set_name(idx, self.current);
		self.advance();
	}

	// Adopt left operand as child
	self.result.nodes[left].parent = idx;
	self.result.nodes[idx].child_count = 1;
	self.node_end(idx);
	return idx;
}

/**
 * Parse call expression: expr(args)
 * Also supports trailing lambda: expr(args) { lambda }
 */
fn uint Parser.parse_call_expr(Parser* self, uint left) {
	uint idx = self.add_node(CALL_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;

	// Copy name from left if it's a simple name
	if (self.result.nodes[left].kind == NAME_EXPR) {
		self.result.nodes[idx].name = self.result.nodes[left].name;
		self.result.nodes[idx].name_offset = self.result.nodes[left].name_offset;
		self.result.nodes[idx].name_line = self.result.nodes[left].name_line;
		self.result.nodes[idx].name_col = self.result.nodes[left].name_col;
		self.result.nodes[idx].name_len = self.result.nodes[left].name_len;
	} else if (self.result.nodes[left].kind == DOT_EXPR) {
		// For member calls like obj.method(), copy the member name
		self.result.nodes[idx].name = self.result.nodes[left].name;
		self.result.nodes[idx].name_offset = self.result.nodes[left].name_offset;
		self.result.nodes[idx].name_line = self.result.nodes[left].name_line;
		self.result.nodes[idx].name_col = self.result.nodes[left].name_col;
		self.result.nodes[idx].name_len = self.result.nodes[left].name_len;
	}

	// Adopt left (callee) as child
	self.result.nodes[left].parent = idx;

	self.advance(); // consume '('
	uint children_start = self.result.node_count;

	// Parse arguments — each wrapped in a VALUE_ARGUMENT node.
	while (!self.at(RPAREN) && !self.at_eof()) {
		self.parse_value_argument();
		if (!self.eat(COMMA)) break;
	}

	self.expect(RPAREN);
	self.adopt_children(idx, children_start);
	self.result.nodes[idx].child_count += 1; // +1 for the callee already adopted
	self.node_end(idx);
	return idx;
}

/**
 * Parse a single call argument and wrap it in a VALUE_ARGUMENT node.
 * Forms:
 *   expr            — positional
 *   name = expr     — named (only if `name` is identifier-like and `=` follows)
 *   *expr           — spread (vararg expansion)
 * The VALUE_ARGUMENT has exactly one child: the argument expression.
 */
fn uint Parser.parse_value_argument(Parser* self) {
	uint va_idx = self.add_node(VALUE_ARGUMENT);
	self.node_start(va_idx, self.current);

	// Detect named argument: IDENT '=' (but not '==')
	if (self.at_identifier() && self.peek_is(ASSIGNMENT)) {
		Token name_tok = self.current;
		self.node_set_name(va_idx, name_tok);
		self.advance(); // consume name
		self.advance(); // consume '='
	}

	// Detect spread: '*expr'
	if (self.at(MULT)) {
		self.result.nodes[va_idx].extra_text = "*";
		self.advance(); // consume '*'
	}

	uint expr_start = self.result.node_count;
	self.parse_expression(PREC_NONE);
	self.adopt_children(va_idx, expr_start);
	self.node_end(va_idx);
	return va_idx;
}

/**
 * Parse index expression: expr[index]
 */
fn uint Parser.parse_index_expr(Parser* self, uint left) {
	uint idx = self.add_node(INDEX_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;

	self.result.nodes[left].parent = idx;

	self.advance(); // consume '['
	uint children_start = self.result.node_count;

	while (!self.at(RSQUARE) && !self.at_eof()) {
		self.parse_expression(PREC_NONE);
		if (!self.eat(COMMA)) break;
	}

	self.expect(RSQUARE);
	self.adopt_children(idx, children_start);
	self.result.nodes[idx].child_count += 1; // +1 for the receiver
	self.node_end(idx);
	return idx;
}

/**
 * Parse not-null assertion: expr!!
 */
fn uint Parser.parse_not_null_postfix(Parser* self, uint left) {
	uint idx = self.add_node(POSTFIX_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;
	self.result.nodes[idx].extra_text = "!!";

	self.result.nodes[left].parent = idx;
	self.result.nodes[idx].child_count = 1;

	self.advance(); // consume '!!'
	self.node_end(idx);
	return idx;
}

/**
 * Parse postfix ++/-- on an expression.
 */
fn uint Parser.parse_postfix_incr_decr(Parser* self, uint left) {
	uint idx = self.add_node(POSTFIX_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;
	self.result.nodes[idx].extra_text = self.current.text;

	self.result.nodes[left].parent = idx;
	self.result.nodes[idx].child_count = 1;

	self.advance(); // consume '++' or '--'
	self.node_end(idx);
	return idx;
}

/**
 * Parse member reference: expr::name
 */
fn uint Parser.parse_member_ref(Parser* self, uint left) {
	uint idx = self.add_node(CALLABLE_REF_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;

	self.result.nodes[left].parent = idx;
	self.result.nodes[idx].child_count = 1;

	self.advance(); // consume '::'

	if (self.at_identifier() || self.at(KW_CLASS)) {
		self.node_set_name(idx, self.current);
		self.advance();
	}

	self.node_end(idx);
	return idx;
}

/**
 * Parse a trailing lambda: expr { ... }
 *
 * Two cases (Kotlin spec §11.1.5):
 *   1. `left` is already a CALL_EXPR `foo(args)` — append the lambda
 *      as a final VALUE_ARGUMENT to that same call. No wrapper node.
 *   2. `left` is a NAME_EXPR / DOT_EXPR — synthesize a new CALL_EXPR
 *      whose only argument is the trailing lambda (no parens form,
 *      e.g. `runBlocking { ... }`).
 *
 * The lambda is wrapped in a VALUE_ARGUMENT (consistent with parenthesized
 * args). VALUE_ARGUMENT.extra_text = "trailing" marks it as the trailing
 * form so consumers can distinguish if needed.
 */
fn uint Parser.parse_trailing_lambda(Parser* self, uint left) {
	// Case 1: left is an existing CALL_EXPR — append lambda to it.
	if (left < self.result.node_count
		&& self.result.nodes[left].kind == CALL_EXPR
		&& !self.call_has_trailing_lambda(left)) {
		uint va_idx = self.add_node(VALUE_ARGUMENT);
		self.node_start(va_idx, self.current);
		self.result.nodes[va_idx].extra_text = "trailing";
		self.result.nodes[va_idx].parent = left;

		uint expr_start = self.result.node_count;
		self.parse_lambda_expr();
		// Adopt only the freshly-added lambda node(s) into VALUE_ARGUMENT
		uint expr_count = 0;
		for (uint i = expr_start; i < self.result.node_count; i++) {
			if (self.result.nodes[i].parent == ast::NO_PARENT) {
				self.result.nodes[i].parent = va_idx;
				expr_count++;
			}
		}
		self.result.nodes[va_idx].child_count = expr_count;
		self.result.nodes[va_idx].children_start = expr_start;
		self.node_end(va_idx);

		// Bump the existing CALL_EXPR child count and extend its end span.
		self.result.nodes[left].child_count += 1;
		self.result.nodes[left].end_offset = self.result.nodes[va_idx].end_offset;
		self.result.nodes[left].end_line = self.result.nodes[va_idx].end_line;
		self.result.nodes[left].end_col = self.result.nodes[va_idx].end_col;
		return left;
	}

	// Case 2: synthesize a new CALL_EXPR wrapping left + lambda-as-VALUE_ARGUMENT.
	uint idx = self.add_node(CALL_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;

	// Copy name from left
	if (left < self.result.node_count) {
		self.result.nodes[idx].name = self.result.nodes[left].name;
		self.result.nodes[idx].name_offset = self.result.nodes[left].name_offset;
		self.result.nodes[idx].name_line = self.result.nodes[left].name_line;
		self.result.nodes[idx].name_col = self.result.nodes[left].name_col;
		self.result.nodes[idx].name_len = self.result.nodes[left].name_len;
	}

	self.result.nodes[left].parent = idx;

	// Wrap the trailing lambda in a VALUE_ARGUMENT.
	uint children_start = self.result.node_count;
	uint va_idx = self.add_node(VALUE_ARGUMENT);
	self.node_start(va_idx, self.current);
	self.result.nodes[va_idx].extra_text = "trailing";

	uint expr_start = self.result.node_count;
	self.parse_lambda_expr();
	uint expr_count = 0;
	for (uint i = expr_start; i < self.result.node_count; i++) {
		if (self.result.nodes[i].parent == ast::NO_PARENT) {
			self.result.nodes[i].parent = va_idx;
			expr_count++;
		}
	}
	self.result.nodes[va_idx].child_count = expr_count;
	self.result.nodes[va_idx].children_start = expr_start;
	self.node_end(va_idx);

	self.adopt_children(idx, children_start);
	self.result.nodes[idx].child_count += 1; // +1 for left already adopted
	self.node_end(idx);
	return idx;
}

/**
 * Check whether a CALL_EXPR already has a trailing lambda (a VALUE_ARGUMENT
 * child whose extra_text == "trailing", or a direct LAMBDA_EXPR child for
 * back-compat with synthesized forms).
 */
fn bool Parser.call_has_trailing_lambda(Parser* self, uint call_idx) {
	if (call_idx >= self.result.node_count) return false;
	AstNode* call = &self.result.nodes[call_idx];
	if (call.child_count == 0) return false;
	for (uint i = call.children_start; i < self.result.node_count; i++) {
		if (self.result.nodes[i].parent != call_idx) continue;
		if (self.result.nodes[i].kind == LAMBDA_EXPR) return true;
		if (self.result.nodes[i].kind == VALUE_ARGUMENT
			&& self.result.nodes[i].extra_text == "trailing") return true;
	}
	return false;
}

/**
 * Parse a type check: expr is Type / expr !is Type
 */
fn uint Parser.parse_type_check(Parser* self, uint left) {
	uint idx = self.add_node(TYPE_CHECK_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;
	self.result.nodes[idx].extra_text = self.current.text;

	self.result.nodes[left].parent = idx;
	self.result.nodes[idx].child_count = 1;

	self.advance(); // consume 'is' or '!is'

	// Parse the type
	uint type_start = self.current.offset;
	self.skip_type_ref();
	uint type_end = self.previous.offset + self.previous.len;
	if (type_end > type_start) {
		self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
	}

	self.node_end(idx);
	return idx;
}

/**
 * Parse a type cast: expr as Type / expr as? Type
 */
fn uint Parser.parse_type_cast(Parser* self, uint left) {
	uint idx = self.add_node(TYPE_CAST_EXPR);
	self.result.nodes[idx].start_offset = self.result.nodes[left].start_offset;
	self.result.nodes[idx].start_line = self.result.nodes[left].start_line;
	self.result.nodes[idx].start_col = self.result.nodes[left].start_col;
	self.result.nodes[idx].extra_text = self.current.text;

	self.result.nodes[left].parent = idx;
	self.result.nodes[idx].child_count = 1;

	self.advance(); // consume 'as' or 'as?'

	// Parse the type
	uint type_start = self.current.offset;
	self.skip_type_ref();
	uint type_end = self.previous.offset + self.previous.len;
	if (type_end > type_start) {
		self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
	}

	self.node_end(idx);
	return idx;
}

/**
 * Check if a token kind can start a statement inside a block.
 * Used for heuristic statement boundary detection.
 */
fn bool is_statement_start(TokenKind kind) {
	switch (kind) {
		// Declarations
		case KW_CLASS: case KW_INTERFACE: case KW_OBJECT: case KW_FUN:
		case KW_VAL: case KW_VAR: case KW_TYPEALIAS: case KW_CONSTRUCTOR:
		case KW_INIT: case KW_COMPANION:
			return true;
		// Control flow
		case KW_IF: case KW_WHEN: case KW_FOR: case KW_WHILE: case KW_DO:
		case KW_TRY: case KW_RETURN: case KW_THROW: case KW_BREAK:
		case KW_CONTINUE:
			return true;
		default:
			return false;
	}
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

	// Handle suspend function types: suspend (A) -> B, suspend Type.() -> B
	if (self.at(KW_SUSPEND)) {
		self.advance();
		// After suspend, the rest is a regular function type or receiver function type
		// Recurse to handle: (A) -> B  or  Type.() -> B  or  Type<G>.() -> B
		self.skip_type_ref();
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

		// Intersection type (definitely non-nullable): T & Any
		if (self.eat(AMP)) {
			self.skip_type_ref();
		}

		return;
	}

	// Nothing consumed -- error or end of type
}

/**
 * Parse an expression body (after = in fun or val).
 * Uses the expression parser to produce AST nodes.
 * The expression ends at the same boundaries as the old skip heuristic:
 * declaration starters, modifiers, get/set at depth 0, semicolons, or '}'.
 */
fn void Parser.parse_expression_body(Parser* self) {
	// We rely on the expression parser to naturally stop when it
	// encounters something it can't parse. However, Kotlin's soft
	// keywords (get, set, modifier keywords) look like identifiers
	// and would be incorrectly consumed. We handle this by checking
	// if the current token is a property accessor or top-level boundary
	// BEFORE the expression parser gets to it.
	//
	// Strategy: parse a single expression. The Pratt parser will
	// stop at tokens with no prefix/infix binding power.
	self.parse_expression(PREC_NONE);
	self.eat(SEMICOLON);
}

/**
 * Skip over a string literal's token sequence (STRING_OPEN ... STRING_CLOSE
 * or MULTILINE_STRING_OPEN ... MULTILINE_STRING_CLOSE), including any nested
 * template expressions that contain LCURL/RCURL tokens.
 * Caller must be positioned ON the STRING_OPEN/MULTILINE_STRING_OPEN token.
 */
fn void Parser.skip_string_tokens(Parser* self) {
	TokenKind open_kind = self.current.kind;
	TokenKind close_kind = (open_kind == MULTILINE_STRING_OPEN)
		? MULTILINE_STRING_CLOSE
		: STRING_CLOSE;
	self.advance(); // consume opening token
	int nesting = 1;
	while (nesting > 0 && !self.at_eof()) {
		if (self.current.kind == open_kind) {
			nesting++;
		} else if (self.current.kind == close_kind) {
			nesting--;
			if (nesting == 0) {
				self.advance(); // consume closing token
				return;
			}
		}
		self.advance();
	}
}

/**
 * Skip a parameter default value expression.
 * Similar to parse_expression_body but also stops at comma and closing paren.
 */
fn void Parser.skip_param_default(Parser* self) {
	int depth = 0;
	while (!self.at_eof()) {
		// Skip string literals atomically (they may contain RCURL from templates)
		if (self.at(STRING_OPEN) || self.at(MULTILINE_STRING_OPEN)) {
			self.skip_string_tokens();
			continue;
		}
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
/**
 * Parse a property accessor (get/set) into a FUN_DECL child node.
 *
 * Kotlin property accessors:
 *   val x: Int
 *       get() = field + 1
 *
 *   var y: Int
 *       get() { return field }
 *       set(value) { field = value }
 *
 * We represent them as FUN_DECL children of the PROPERTY_DECL, with name "get" or "set".
 */
fn void Parser.parse_property_accessor(Parser* self) {
	uint idx = self.add_node(FUN_DECL);
	self.node_start(idx, self.current);
	uint children_start = self.result.node_count;

	// Set name to "get" or "set"
	self.node_set_name(idx, self.current);
	self.advance(); // consume 'get' or 'set'

	// Parameters for set: set(value) or set(value: Type)
	if (self.at(LPAREN)) {
		self.advance(); // consume '('
		while (!self.at(RPAREN) && !self.at_eof()) {
			if (self.at(COMMA)) {
				self.advance();
				continue;
			}
			if (self.at_identifier()) {
				uint param_idx = self.add_node(PARAM);
				self.node_start(param_idx, self.current);
				Token name = self.expect_identifier();
				self.node_set_name(param_idx, name);
				if (self.eat(COLON)) {
					uint type_start = self.current.offset;
					self.skip_type_ref();
					uint type_end = self.previous.offset + self.previous.len;
					if (type_end > type_start) {
						self.result.nodes[param_idx].type_text = self.source[type_start:type_end - type_start];
					}
				}
				self.node_end(param_idx);
			} else {
				self.advance();
			}
		}
		self.expect(RPAREN);
	}

	// Return type annotation
	if (self.eat(COLON)) {
		uint type_start = self.current.offset;
		self.skip_type_ref();
		uint type_end = self.previous.offset + self.previous.len;
		if (type_end > type_start) {
			self.result.nodes[idx].type_text = self.source[type_start:type_end - type_start];
		}
	}

	// Body: block or expression-body
	if (self.at(LCURL)) {
		self.parse_block();
	} else if (self.eat(ASSIGNMENT)) {
		self.parse_expression_body();
	}

	self.adopt_children(idx, children_start);
	self.node_end(idx);
}

/**
 * Skip a delegation expression after 'by'.
 * Handles nested parens, angle brackets, and curly braces for
 * complex delegation expressions (e.g., lambdas, generic calls).
 */
fn void Parser.skip_delegation_expression(Parser* self) {
	int paren_depth = 0;
	int angle_depth = 0;
	int curl_depth = 0;
	while (!self.at_eof()) {
		if (self.at(LPAREN)) { paren_depth++; self.advance(); continue; }
		if (self.at(RPAREN)) {
			if (paren_depth == 0) return;
			paren_depth--;
			self.advance();
			continue;
		}
		if (self.at(LANGLE)) { angle_depth++; self.advance(); continue; }
		if (self.at(RANGLE)) {
			if (angle_depth > 0) angle_depth--;
			self.advance();
			continue;
		}
		if (self.at(LCURL)) {
			if (paren_depth == 0 && angle_depth == 0 && curl_depth == 0) return;
			curl_depth++;
			self.advance();
			continue;
		}
		if (self.at(RCURL)) {
			if (curl_depth == 0) return;
			curl_depth--;
			self.advance();
			continue;
		}
		// At top level (no nesting), comma/where terminates delegation
		if (paren_depth == 0 && angle_depth == 0 && curl_depth == 0) {
			if (self.at(COMMA) || self.at(KW_WHERE)) return;
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
		case KW_FILE: case KW_INIT: case KW_CONSTRUCTOR: case KW_BY:
		case KW_COMPANION: case KW_CATCH: case KW_FINALLY: case KW_WHERE:
		case KW_DYNAMIC:
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
 * Check if an identifier is a well-known infix function in Kotlin stdlib.
 * This avoids misinterpreting statement-initial identifiers as infix calls
 * without full newline-sensitive parsing.
 */
fn bool is_known_infix_function(String text) {
	switch (text) {
		case "to":       return true;
		case "and":      return true;
		case "or":       return true;
		case "xor":      return true;
		case "shl":      return true;
		case "shr":      return true;
		case "ushr":     return true;
		case "until":    return true;
		case "downTo":   return true;
		case "step":     return true;
		default:         return false;
	}
}

/**
 * Recognize a name as an infix call: hard-coded stdlib whitelist OR
 * user-defined `infix fun` from same file or workspace.
 */
fn bool Parser.is_user_or_known_infix(Parser* self, String text) {
	if (is_known_infix_function(text)) return true;
	for (usz i = 0; i < self.same_file_infix.len; i++) {
		if (self.same_file_infix[i] == text) return true;
	}
	for (usz i = 0; i < self.workspace_infix.len; i++) {
		if (self.workspace_infix[i] == text) return true;
	}
	return false;
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
