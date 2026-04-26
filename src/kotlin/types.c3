module kls::kotlin::types;

import kls::kotlin::ast;
import kls::kotlin::token;
import kls::kotlin::lexer;
import kls::kotlin::cfg;
import kls::kotlin::flow;
import std::core::string;
import kls::workspace;
import kls::kotlin::symbols;
import kls::deps::jar_index;

// ── Cross-file type resolution support ─────────────────────────────

WorkspaceIndex* g_workspace;

// Cache for dep member type lookups — flat array, no heap allocation for keys
const usz DEP_CACHE_SIZE = 256;
const usz DEP_CACHE_KEY_MAX = 128;

struct DepMemberCacheEntry {
	char[DEP_CACHE_KEY_MAX] key;
	usz key_len;
	TypeRef value;
	bool occupied;
}

DepMemberCacheEntry[DEP_CACHE_SIZE] g_dep_member_cache;

/**
 * Set the workspace index for cross-file type resolution.
 * Call before resolve_types() to enable workspace-aware inference.
 */
fn void set_workspace(WorkspaceIndex* ws) {
	g_workspace = ws;
}

/**
 * Clear the workspace pointer (optional cleanup).
 */
fn void clear_workspace() {
	g_workspace = null;
}

/**
 * Clear the dep member type cache. Call when dep index is rebuilt.
 */
fn void clear_dep_member_cache() {
	for (usz i = 0; i < DEP_CACHE_SIZE; i++) {
		g_dep_member_cache[i].occupied = false;
	}
}

// ── Type representation ────────────────────────────────────────────

enum TypeKind : int {
	UNKNOWN,          // unresolved / error type
	SIMPLE,           // e.g. Int, String, MyClass
	FUNCTION,         // (A, B) -> C  or  suspend (A) -> B
	GENERIC,          // Name<T1, T2>  e.g. List<Int>
	UNIT,             // Unit (void-equivalent)
	NOTHING,          // Nothing (bottom type)
}

const usz MAX_TYPE_ARGS = 8;

/**
 * A type reference. Type arguments are stored as simple name strings
 * (not nested TypeRefs) to keep the struct non-recursive and fixed-size.
 * The full_text field preserves the original source text for display.
 */
struct TypeRef {
	TypeKind kind;
	String name;              // simple name: "Int", "List", "MyClass"
	String full_text;         // original text (for display): "List<Int>?"
	bool nullable;
	bool is_suspend;          // for function types: suspend (...) -> T
	bool is_class_ref;        // true when this TypeRef refers to a class/object/interface itself (e.g. `UUID` in `UUID.randomUUID()`), not an instance value
	bool is_dnn;              // definitely non-nullable: `T & Any` (Kotlin spec §9.4.4)

	// For GENERIC: simple type argument names
	usz type_arg_count;
	String[MAX_TYPE_ARGS] type_arg_names;   // e.g. ["Int"], ["String", "Any"]
	bool[MAX_TYPE_ARGS] type_arg_nullable;  // nullable flags per arg

	// For FUNCTION: parameter and return types as names
	usz param_type_count;
	String[MAX_TYPE_ARGS] param_type_names; // max 8 params for display
	String return_type_name;                // e.g. "String", "Unit"
	String receiver_type_name;              // for extension fn types: e.g. "Int"
}

// ── Well-known types ───────────────────────────────────────────────

const TypeRef TYPE_UNKNOWN = { .kind = UNKNOWN, .name = "" };
const TypeRef TYPE_UNIT    = { .kind = UNIT, .name = "Unit" };
const TypeRef TYPE_NOTHING = { .kind = NOTHING, .name = "Nothing" };
const TypeRef TYPE_INT     = { .kind = SIMPLE, .name = "Int" };
const TypeRef TYPE_LONG    = { .kind = SIMPLE, .name = "Long" };
const TypeRef TYPE_FLOAT   = { .kind = SIMPLE, .name = "Float" };
const TypeRef TYPE_DOUBLE  = { .kind = SIMPLE, .name = "Double" };
const TypeRef TYPE_BOOLEAN = { .kind = SIMPLE, .name = "Boolean" };
const TypeRef TYPE_CHAR    = { .kind = SIMPLE, .name = "Char" };
const TypeRef TYPE_STRING  = { .kind = SIMPLE, .name = "String" };
const TypeRef TYPE_BYTE    = { .kind = SIMPLE, .name = "Byte" };
const TypeRef TYPE_SHORT   = { .kind = SIMPLE, .name = "Short" };
const TypeRef TYPE_ANY     = { .kind = SIMPLE, .name = "Any" };

const TypeRef TYPE_NOTHING_NULLABLE = { .kind = SIMPLE, .name = "Nothing", .nullable = true };

// ── Per-file type info cache ───────────────────────────────────────

const usz MAX_FUNCTIONS_PER_FILE = 512;

struct FunctionFlow {
	uint func_ast_idx;
	cfg::Cfg* cfg;
	flow::FlowAnalysis* fa;
}

struct TypeInfo {
	TypeRef[ast::MAX_NODES] node_types;  // parallel to ParseResult.nodes
	bool[ast::MAX_NODES] has_type;       // whether node_types[i] is populated

	// Per-function flow analysis. enclosing_func[i] = AST idx of function
	// containing node i (NO_PARENT for top-level). func_flow_idx[func] =
	// index into func_flows array (or uint.max).
	uint[ast::MAX_NODES] enclosing_func;
	FunctionFlow[MAX_FUNCTIONS_PER_FILE] func_flows;
	uint func_flow_count;
	uint[ast::MAX_NODES] func_flow_lookup; // ast func idx -> func_flows index
}

// ── Type text parser ───────────────────────────────────────────────

/**
 * Parse a type annotation text (e.g. "List<Int>?", "(Int) -> String")
 * into a structured TypeRef. Uses the lexer to tokenize the type text.
 */
fn TypeRef parse_type_text(String text) {
	if (text.len == 0) return TYPE_UNKNOWN;

	TypeParser tp = { .source = text, .lexer = lexer::init(text) };
	tp.advance(); // prime first token

	TypeRef result = tp.parse_type();
	if (result.full_text.len == 0) {
		result.full_text = text;
	}
	return result;
}

// ── Type parser (internal) ─────────────────────────────────────────

struct TypeParser {
	String source;
	Lexer lexer;
	Token current;
	Token previous;
}

fn void TypeParser.advance(TypeParser* self) {
	self.previous = self.current;
	self.current = self.lexer.next();
}

fn bool TypeParser.at(TypeParser* self, TokenKind kind) {
	return self.current.kind == kind;
}

fn bool TypeParser.at_eof(TypeParser* self) {
	return self.current.kind == EOF;
}

fn bool TypeParser.eat(TypeParser* self, TokenKind kind) {
	if (self.current.kind == kind) {
		self.advance();
		return true;
	}
	return false;
}

fn bool TypeParser.at_identifier(TypeParser* self) {
	return self.current.kind.is_identifier_or_soft_keyword();
}

/**
 * Parse a full type reference: simple, generic, nullable, function, suspend.
 */
fn TypeRef TypeParser.parse_type(TypeParser* self) {
	// Handle suspend function types: suspend (A) -> B
	if (self.at(KW_SUSPEND)) {
		self.advance();
		TypeRef ft = self.parse_type();
		ft.is_suspend = true;
		ft.full_text = self.source;
		return ft;
	}

	// Handle function types starting with '(': (A, B) -> C
	if (self.at(LPAREN)) {
		return self.parse_function_or_paren_type();
	}

	// Simple or generic type: Name, Name<T>, com.example.Type
	if (self.at_identifier() || self.at(KW_DYNAMIC)) {
		return self.parse_simple_or_generic_type();
	}

	return TYPE_UNKNOWN;
}

/**
 * Parse (A, B) -> C (function type) or just (Type) (parenthesized type).
 */
fn TypeRef TypeParser.parse_function_or_paren_type(TypeParser* self) {
	self.advance(); // consume '('

	// Collect parameter type names
	TypeRef result;
	result.kind = FUNCTION;
	result.param_type_count = 0;

	while (!self.at(RPAREN) && !self.at_eof()) {
		if (result.param_type_count >= MAX_TYPE_ARGS) break;
		TypeRef param = self.parse_type();
		result.param_type_names[result.param_type_count] = format_type(&param);
		result.param_type_count++;
		if (!self.eat(COMMA)) break;
	}

	self.eat(RPAREN);

	// Check for arrow: -> ReturnType
	if (self.eat(ARROW)) {
		TypeRef ret = self.parse_type();
		result.return_type_name = format_type(&ret);
		result.name = "Function";
		result.full_text = self.source;

		// Nullable function type: ((A) -> B)?
		while (self.eat(QUEST)) {
			result.nullable = true;
		}
		return result;
	}

	// Not a function type -- parenthesized single type
	if (result.param_type_count == 1) {
		// Reconstruct a simple type from the param name
		TypeRef inner;
		inner.kind = SIMPLE;
		inner.name = result.param_type_names[0];
		// Check for nullable after parens
		while (self.eat(QUEST)) {
			inner.nullable = true;
		}
		inner.full_text = self.source;
		return inner;
	}

	// Multiple types in parens without arrow -- unusual, treat as unknown
	return TYPE_UNKNOWN;
}

/**
 * Parse a simple type (Name), dotted type (com.example.Type),
 * generic type (List<Int>), with optional nullable suffix (?).
 * Also handles receiver function types: Type.(A) -> B
 */
fn TypeRef TypeParser.parse_simple_or_generic_type(TypeParser* self) {
	TypeRef result;
	result.kind = SIMPLE;

	// Collect dotted name: com.example.Type
	// Use source slices directly — the source string (type_text from AST) is a
	// stable slice of document content, avoiding temp allocation lifetime issues
	// when TypeRefs are stored in heap-cached TypeInfo.
	String first_token = self.current.text;
	usz name_start = (usz)(first_token.ptr - self.source.ptr);
	usz name_end = name_start + first_token.len;
	self.advance();

	while (self.eat(DOT)) {
		if (self.at_identifier()) {
			String seg = self.current.text;
			name_end = (usz)(seg.ptr - self.source.ptr) + seg.len;
			self.advance();
		} else if (self.at(LPAREN)) {
			// Receiver function type: Type.(A) -> B
			String receiver_name = self.source[name_start..name_end - 1];

			TypeRef ft = self.parse_function_or_paren_type();
			ft.receiver_type_name = receiver_name;
			ft.full_text = self.source;
			return ft;
		} else {
			break;
		}
	}

	result.name = self.source[name_start..name_end - 1];

	// Generic arguments: <T, R>
	if (self.at(LANGLE)) {
		self.advance(); // consume '<'
		result.kind = GENERIC;
		result.type_arg_count = 0;

		while (!self.at(RANGLE) && !self.at_eof()) {
			if (result.type_arg_count >= MAX_TYPE_ARGS) {
				// Skip remaining
				self.skip_angle_contents();
				break;
			}

			// Handle variance annotations: in T, out T
			if (self.eat(KW_IN) || self.eat(KW_OUT)) {
				// skip variance, parse the type
			}

			// Handle star projection: *
			if (self.eat(MULT)) {
				result.type_arg_names[result.type_arg_count] = "*";
				result.type_arg_count++;
				if (!self.eat(COMMA)) break;
				continue;
			}

			TypeRef arg = self.parse_type();
			result.type_arg_names[result.type_arg_count] = format_type(&arg);
			result.type_arg_nullable[result.type_arg_count] = arg.nullable;
			result.type_arg_count++;
			if (!self.eat(COMMA)) break;
		}
		self.eat(RANGLE);
	}

	// Nullable: Type?, List<Int>?
	while (self.eat(QUEST)) {
		result.nullable = true;
	}

	// Check for receiver function type: Type<G>.(A) -> B
	if (self.eat(DOT)) {
		if (self.at(LPAREN)) {
			String receiver_name = format_type(&result);
			TypeRef ft = self.parse_function_or_paren_type();
			ft.receiver_type_name = receiver_name;
			ft.full_text = self.source;
			return ft;
		}
	}

	// Definitely non-nullable: T & Any (Kotlin spec §9.4.4).
	// `&` after a type, followed by `Any`, marks the type as guaranteed
	// non-nullable. Force `nullable = false` regardless of input.
	if (self.eat(AMP)) {
		if (self.at_identifier() && self.current.text == "Any") {
			self.advance();
			result.is_dnn = true;
			result.nullable = false;
		}
	}

	result.full_text = self.source;
	return result;
}

/**
 * Skip contents inside angle brackets (for overflow).
 */
fn void TypeParser.skip_angle_contents(TypeParser* self) {
	int depth = 1;
	while (depth > 0 && !self.at_eof()) {
		if (self.at(LANGLE)) depth++;
		if (self.at(RANGLE)) {
			depth--;
			if (depth == 0) return;
		}
		self.advance();
	}
}

// ── Type formatting ────────────────────────────────────────────────

/**
 * Format a TypeRef as a human-readable Kotlin type string.
 * For simple non-nullable types, returns the name directly (a source slice,
 * safe for long-lived storage). Complex types use temp allocator.
 */
fn String format_type(TypeRef* t) {
	if (t.kind == UNKNOWN) return "";
	if (t.kind == UNIT) return t.nullable ? "Unit?" : "Unit";
	if (t.kind == NOTHING) return t.nullable ? "Nothing?" : "Nothing";

	// Fast path: simple type without nullable/DNN — return name slice directly
	if (t.kind == SIMPLE && !t.nullable && !t.is_dnn && t.name.len > 0) return t.name;

	DString ds;
	ds.tinit();
	format_type_into(&ds, t);
	return ds.str_view();
}

fn void format_type_into(DString* ds, TypeRef* t) {
	switch (t.kind) {
		case UNKNOWN:
			return;

		case UNIT:
			ds.appendf("Unit");

		case NOTHING:
			ds.appendf("Nothing");

		case SIMPLE:
			ds.appendf("%s", t.name);

		case GENERIC:
			ds.appendf("%s<", t.name);
			for (usz i = 0; i < t.type_arg_count; i++) {
				if (i > 0) ds.appendf(", ");
				ds.appendf("%s", t.type_arg_names[i]);
				if (t.type_arg_nullable[i]) ds.appendf("?");
			}
			ds.appendf(">");

		case FUNCTION:
			if (t.is_suspend) {
				ds.appendf("suspend ");
			}
			if (t.receiver_type_name.len > 0) {
				ds.appendf("%s.", t.receiver_type_name);
			}
			ds.appendf("(");
			for (usz i = 0; i < t.param_type_count; i++) {
				if (i > 0) ds.appendf(", ");
				ds.appendf("%s", t.param_type_names[i]);
			}
			ds.appendf(") -> ");
			if (t.return_type_name.len > 0) {
				ds.appendf("%s", t.return_type_name);
			} else {
				ds.appendf("Unit");
			}
	}

	if (t.nullable) {
		ds.appendf("?");
	}
	if (t.is_dnn) {
		ds.appendf(" & Any");
	}
}

// ── Literal type inference ─────────────────────────────────────────

/**
 * Infer the type of a literal expression node from its token kind
 * and text content.
 */
fn TypeRef infer_literal_type(AstNode* node) {
	if (node.kind != LITERAL_EXPR) return TYPE_UNKNOWN;

	String text = node.extra_text;
	if (text.len == 0) return TYPE_UNKNOWN;

	// Check for boolean
	if (text == "true" || text == "false") return TYPE_BOOLEAN;

	// Check for null
	if (text == "null") return TYPE_NOTHING_NULLABLE;

	// Check for character literal: 'x'
	if (text.len >= 2 && text[0] == '\'') return TYPE_CHAR;

	// Check for numeric literal
	return infer_numeric_type(text);
}

/**
 * Infer numeric type from literal text.
 */
fn TypeRef infer_numeric_type(String text) {
	if (text.len == 0) return TYPE_UNKNOWN;

	// Check suffixes first (case-insensitive)
	char last = text[text.len - 1];
	if (text.len >= 2) {
		char second_last = text[text.len - 2];

		// uL / UL suffix -> ULong
		if ((last == 'L' || last == 'l') && (second_last == 'u' || second_last == 'U')) {
			return { .kind = SIMPLE, .name = "ULong" };
		}
	}

	// L suffix -> Long
	if (last == 'L' || last == 'l') return TYPE_LONG;

	// u/U suffix -> UInt
	if (last == 'u' || last == 'U') {
		return { .kind = SIMPLE, .name = "UInt" };
	}

	// f/F suffix -> Float
	if (last == 'f' || last == 'F') return TYPE_FLOAT;

	// Contains decimal point or exponent -> Double
	for (usz i = 0; i < text.len; i++) {
		if (text[i] == '.' || text[i] == 'e' || text[i] == 'E') {
			return TYPE_DOUBLE;
		}
	}

	// Default integer -> Int
	return TYPE_INT;
}

// ── Type resolution pass ───────────────────────────────────────────

/**
 * Resolve types for all nodes in a ParseResult.
 * Walks the AST and populates TypeInfo with resolved types.
 */
fn void resolve_types(ParseResult* pr, TypeInfo* info) {
	if (pr.node_count == 0) return;

	// Clear type info
	for (uint i = 0; i < pr.node_count; i++) {
		info.has_type[i] = false;
	}
	// Clear flow caches
	clear_flow(info);

	// Phase 1: Resolve explicit type annotations on declarations
	resolve_declaration_types(pr, info);

	// Phase 2: Infer types from literal expressions
	resolve_literal_types(pr, info);

	// Phase 3: Infer types from initializers (val x = 42 -> Int)
	resolve_initializer_types(pr, info);

	// Phase 4: Propagate types through expressions
	resolve_expression_types(pr, info);

	// Phase 5: Re-run initializer inference for declarations whose
	// initializer expressions were resolved in Phase 4
	resolve_initializer_types(pr, info);

	// Phase 6: Re-resolve expressions that depend on Phase 5 inferred types
	// (e.g., val x = listOf("a"); x.filter { it } — x's type is inferred
	// in Phase 5, but the filter chain needs another expression pass)
	resolve_expression_types(pr, info);

	// Phase 7: Final initializer+expression pass for cross-file chains
	// (e.g., val u = User(...); val n = u.name — n's DOT_EXPR resolved
	// in Phase 6, but n's PROPERTY_DECL needs one more initializer pass)
	resolve_initializer_types(pr, info);
	resolve_expression_types(pr, info);

	// Phase 8: Resolve destructuring component types
	// val (a, b) = pair -> a: Pair.component1, b: Pair.component2
	// for ((k, v) in map) -> k: Map.Entry.component1, v: Map.Entry.component2
	resolve_destructuring_types(pr, info);

	// Phase 9: Build CFG + run flow analysis per function for smart casts.
	// Done after type resolution so subsequent phases (re-runs) see flow
	// facts via resolve_name_expr_type, which queries info.func_flows.
	build_function_flows(pr, info);

	// Phase 10: Final expression pass — now with smart-cast facts available.
	// Clear cached types on NAME_EXPR / DOT_EXPR nodes so flow facts can
	// override the originally-resolved types. Then propagate to initializers.
	for (uint i = 0; i < pr.node_count; i++) {
		NodeKind k = pr.nodes[i].kind;
		if (k == NAME_EXPR || k == DOT_EXPR) {
			info.has_type[i] = false;
		}
	}
	resolve_expression_types(pr, info);
	// Re-run initializer pass: declarations whose initializer is a smart-cast
	// reference should pick up the narrowed type.
	for (uint i = 0; i < pr.node_count; i++) {
		NodeKind k = pr.nodes[i].kind;
		if (k == PROPERTY_DECL && pr.nodes[i].type_text.len == 0) {
			// Skip destructured component decls — their type comes from the
			// destructuring parent, not an initializer.
			uint parent = pr.nodes[i].parent;
			if (parent != ast::NO_PARENT && parent < pr.node_count
				&& pr.nodes[parent].kind == PROPERTY_DECL
				&& pr.nodes[parent].name == "(destructuring)") continue;
			info.has_type[i] = false;
		}
	}
	resolve_initializer_types(pr, info);
	// Re-apply destructuring component types after the initializer pass
	// (in case re-resolved initializers changed the destructured value's type).
	resolve_destructuring_types(pr, info);
}

// ── Flow analysis bookkeeping ─────────────────────────────────────

fn void clear_flow(TypeInfo* info) {
	for (uint i = 0; i < info.func_flow_count; i++) {
		FunctionFlow* ff = &info.func_flows[i];
		if (ff.cfg != null) {
			ff.cfg.free();
		}
		if (ff.fa != null) {
			ff.fa.free();
		}
		ff.cfg = null;
		ff.fa = null;
	}
	info.func_flow_count = 0;
	for (uint i = 0; i < ast::MAX_NODES; i++) {
		info.enclosing_func[i] = ast::NO_PARENT;
		info.func_flow_lookup[i] = uint.max;
	}
}

/**
 * Release heap allocations owned by TypeInfo (CFG + FlowAnalysis per function).
 * Caller still owns the TypeInfo struct itself.
 */
fn void free_type_info(TypeInfo* info) {
	if (info == null) return;
	clear_flow(info);
}

/**
 * Build a CFG + run flow analysis for every function-like declaration in
 * the file. Records enclosing-function map for each AST node so callers
 * (resolve_name_expr_type) can locate the analysis quickly.
 */
fn void build_function_flows(ParseResult* pr, TypeInfo* info) {
	// Single pass in AST order. Parents (enclosing functions) appear
	// before their nested lambdas, so when we hit a lambda we can look
	// up the already-built flow of its enclosing function and seed the
	// lambda's entry state from the enclosing flow at the lambda's
	// lexical position. This propagates smart-cast facts (e.g. early
	// return null guards) across lambda boundaries.
	for (uint i = 0; i < pr.node_count; i++) {
		NodeKind k = pr.nodes[i].kind;
		bool is_func = k == FUN_DECL
			|| k == CONSTRUCTOR_DECL
			|| k == INIT_BLOCK
			|| k == LAMBDA_EXPR
			|| k == ANONYMOUS_FUN_EXPR;
		if (!is_func) continue;
		if (info.func_flow_count >= MAX_FUNCTIONS_PER_FILE) break;
		uint slot = info.func_flow_count;
		cfg::Cfg* c = cfg::build_cfg(pr, i);

		// Find nearest enclosing function-like ancestor that already has
		// a flow analysis. If found, seed our entry from its state at
		// our lexical position.
		flow::FlowAnalysis* fa;
		uint parent = pr.nodes[i].parent;
		uint enc_func = ast::NO_PARENT;
		while (parent != ast::NO_PARENT && parent < pr.node_count) {
			if (info.func_flow_lookup[parent] != uint.max) {
				enc_func = parent;
				break;
			}
			parent = pr.nodes[parent].parent;
		}
		if (enc_func != ast::NO_PARENT) {
			uint enc_slot = info.func_flow_lookup[enc_func];
			FunctionFlow* enc_ff = &info.func_flows[enc_slot];
			flow::FlowState entry = enc_ff.fa.state_at(pr, enc_ff.cfg, i);
			fa = flow::analyze_with_entry(pr, c, &entry);
		} else {
			fa = flow::analyze(pr, c);
		}

		info.func_flows[slot] = { .func_ast_idx = i, .cfg = c, .fa = fa };
		info.func_flow_lookup[i] = slot;
		info.func_flow_count++;
	}

	// Second pass: assign enclosing function to every AST node by walking
	// up parents.
	for (uint i = 0; i < pr.node_count; i++) {
		info.enclosing_func[i] = compute_enclosing_func(pr, info, i);
	}
}

fn uint compute_enclosing_func(ParseResult* pr, TypeInfo* info, uint idx) {
	uint cur = idx;
	while (cur != ast::NO_PARENT && cur < pr.node_count) {
		if (info.func_flow_lookup[cur] != uint.max) return cur;
		cur = pr.nodes[cur].parent;
	}
	return ast::NO_PARENT;
}

/**
 * Look up a smart-cast fact for `name` at AST node `use_idx`. Returns
 * null if no flow analysis covers this node or no fact applies.
 */
fn flow::Fact* lookup_smart_cast_fact(ParseResult* pr, TypeInfo* info, uint use_idx, String name, String member_name = "") {
	if (use_idx >= ast::MAX_NODES) return null;
	uint func_idx = info.enclosing_func[use_idx];
	if (func_idx == ast::NO_PARENT) return null;
	uint slot = info.func_flow_lookup[func_idx];
	if (slot == uint.max) return null;
	FunctionFlow* ff = &info.func_flows[slot];
	if (ff.fa == null) return null;
	return ff.fa.fact_at(pr, ff.cfg, use_idx, name, member_name);
}

/**
 * Stability gate for smart casts (Kotlin spec §11.3).
 *
 *   - PARAM                          → stable (effective val)
 *   - PROPERTY_DECL local val        → stable
 *   - PROPERTY_DECL local var        → stable iff use is in the SAME
 *                                       function as the declaration
 *                                       (i.e. not captured by a nested
 *                                       lambda / anonymous function).
 *   - PROPERTY_DECL member/top-level val → stable iff:
 *                                       no custom getter AND not `open`
 *                                       AND not `var`. (Conservative
 *                                       approximation of spec §11.3:
 *                                       declaration must be in the
 *                                       same module — same file is a
 *                                       reliable subset; top-level
 *                                       cross-file access is reachable
 *                                       only through workspace which
 *                                       this gate doesn't see, so
 *                                       only same-file uses currently
 *                                       narrow.)
 *   - PROPERTY_DECL member/top-level var → never stable (mutable, could
 *                                          change between check & use,
 *                                          delegated, etc.).
 */
fn bool is_stable_for_smart_cast(ParseResult* pr, TypeInfo* info, uint decl_idx, uint use_idx) {
	if (decl_idx >= pr.node_count) return false;
	AstNode* decl = &pr.nodes[decl_idx];
	if (decl.kind == PARAM) {
		// Primary-ctor `var` params are members and behave like member vars
		// (unstable). All other PARAM uses (function params, primary-ctor
		// `val`, plain ctor params) are effective val and stable.
		bool ctor_var = (decl.mod_flags & ast::MOD_VAR) != 0;
		return !ctor_var;
	}
	if (decl.kind != PROPERTY_DECL) return false;

	bool is_var = (decl.mod_flags & ast::MOD_VAR) != 0;

	// Local case: declared inside a function-like scope.
	uint decl_func = (decl_idx < ast::MAX_NODES) ? info.enclosing_func[decl_idx] : ast::NO_PARENT;
	if (decl_func != ast::NO_PARENT) {
		if (!is_var) return true;
		uint use_func = (use_idx < ast::MAX_NODES) ? info.enclosing_func[use_idx] : ast::NO_PARENT;
		return use_func == decl_func;
	}

	// Member/top-level property. var is never stable (mutable, possibly
	// delegated, observable concurrently). val is stable only when:
	//   1. no custom getter (a custom getter could return different
	//      values across two reads even for `val`), and
	//   2. not `open` (an override could supply a custom getter).
	if (is_var) return false;
	if ((decl.mod_flags & ast::MOD_OPEN) != 0) return false;
	if (property_has_custom_getter(pr, decl_idx)) return false;
	return true;
}

/**
 * True if a PROPERTY_DECL has a `get()` accessor with a body. Parser
 * shape: accessors are FUN_DECL children of the property whose `name`
 * is literally "get" or "set".
 */
fn bool property_has_custom_getter(ParseResult* pr, uint prop_idx) {
	if (prop_idx >= pr.node_count) return false;
	AstNode* p = &pr.nodes[prop_idx];
	if (p.child_count == 0) return false;
	for (uint i = p.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != prop_idx) continue;
		if (pr.nodes[i].kind != FUN_DECL) continue;
		if (pr.nodes[i].name == "get") return true;
	}
	return false;
}

/**
 * Phase 1: Resolve types from explicit annotations on declarations.
 */
fn void resolve_declaration_types(ParseResult* pr, TypeInfo* info) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];

		switch (node.kind) {
			case FUN_DECL:
				if (node.type_text.len > 0) {
					info.node_types[i] = parse_type_text(node.type_text);
					info.has_type[i] = true;
				}

			case PROPERTY_DECL:
				if (node.type_text.len > 0) {
					info.node_types[i] = parse_type_text(node.type_text);
					info.has_type[i] = true;
				}

			case PARAM:
				if (node.type_text.len > 0) {
					info.node_types[i] = parse_type_text(node.type_text);
					info.has_type[i] = true;
				}

			case TYPE_PARAM:
				if (node.type_text.len > 0) {
					info.node_types[i] = parse_type_text(node.type_text);
					info.has_type[i] = true;
				}

			case TYPEALIAS_DECL:
				if (node.type_text.len > 0) {
					info.node_types[i] = parse_type_text(node.type_text);
					info.has_type[i] = true;
				}

			case CLASS_DECL:
				if (node.name.len > 0) {
					info.node_types[i] = { .kind = SIMPLE, .name = node.name, .is_class_ref = true };
					info.has_type[i] = true;
				}

			case INTERFACE_DECL:
				if (node.name.len > 0) {
					info.node_types[i] = { .kind = SIMPLE, .name = node.name, .is_class_ref = true };
					info.has_type[i] = true;
				}

			case OBJECT_DECL:
				if (node.name.len > 0) {
					info.node_types[i] = { .kind = SIMPLE, .name = node.name, .is_class_ref = true };
					info.has_type[i] = true;
				}

			case COMPANION_OBJECT_DECL:
				if (node.name.len > 0) {
					info.node_types[i] = { .kind = SIMPLE, .name = node.name, .is_class_ref = true };
					info.has_type[i] = true;
				}

			case ENUM_ENTRY:
				if (node.parent != ast::NO_PARENT && node.parent < pr.node_count) {
					AstNode* parent = &pr.nodes[node.parent];
					if (parent.kind == CLASS_DECL && parent.name.len > 0) {
						info.node_types[i] = { .kind = SIMPLE, .name = parent.name };
						info.has_type[i] = true;
					}
				}

			case TYPE_CHECK_EXPR:
				info.node_types[i] = TYPE_BOOLEAN;
				info.has_type[i] = true;

			case TYPE_CAST_EXPR:
				if (node.type_text.len > 0) {
					TypeRef cast_type = parse_type_text(node.type_text);
					if (node.extra_text == "as?") {
						cast_type.nullable = true;
					}
					info.node_types[i] = cast_type;
					info.has_type[i] = true;
				}

			default:
				break;
		}
	}
}

/**
 * Phase 2: Resolve types for literal expressions.
 */
fn void resolve_literal_types(ParseResult* pr, TypeInfo* info) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];

		switch (node.kind) {
			case LITERAL_EXPR:
				TypeRef t = infer_literal_type(node);
				if (t.kind != UNKNOWN) {
					info.node_types[i] = t;
					info.has_type[i] = true;
				}

			case STRING_TEMPLATE_EXPR:
				info.node_types[i] = TYPE_STRING;
				info.has_type[i] = true;

			case THIS_EXPR:
				if (try encl = find_enclosing_class(pr, i)) {
					if (encl.name.len > 0) {
						info.node_types[i] = { .kind = SIMPLE, .name = encl.name };
						info.has_type[i] = true;
					}
				}

			case SUPER_EXPR:
				if (try encl = find_enclosing_class(pr, i)) {
					if (try sup = ast::find_child(pr, encl, TYPE_REF)) {
						if (sup.name.len > 0) {
							info.node_types[i] = { .kind = SIMPLE, .name = sup.name };
							info.has_type[i] = true;
						}
					}
				}

			default:
				break;
		}
	}
}

/**
 * Phase 3: Infer types from initializer expressions for properties
 * and expression-body functions without explicit type annotations.
 */
fn void resolve_initializer_types(ParseResult* pr, TypeInfo* info) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];

		if (node.kind != PROPERTY_DECL && node.kind != FUN_DECL) continue;
		if (info.has_type[i]) continue; // already has explicit type

		// Find the first expression child (the initializer)
		TypeRef inferred = TYPE_UNKNOWN;
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.kind == PARAM || child.kind == TYPE_PARAM ||
				child.kind == BLOCK || child.kind == TYPE_REF) continue;

			// Property delegation: `val x by <expr>` (expr tagged with extra_text="delegate").
			// Kotlin spec §11.16: property type = `getValue` operator return type.
			// We special-case `lazy { ... }` (returns lambda body type) which is the
			// overwhelmingly common case; other delegates fall through to the standard
			// child-type inheritance below.
			if (node.kind == PROPERTY_DECL && child.extra_text == "delegate") {
				if (child.kind == CALL_EXPR && child.name == "lazy") {
					TypeRef body = find_trailing_lambda_body_in_call(pr, info, j);
					if (body.kind != UNKNOWN) {
						inferred = body;
						break;
					}
				}
				// Future: other stdlib delegates (Delegates.notNull, observable, ...)
				// or generic getValue operator lookup.
				break;
			}

			// This is an expression child -- use its type
			if (info.has_type[j]) {
				inferred = info.node_types[j];
				break;
			}
			break; // only check first expression child
		}

		if (inferred.kind != UNKNOWN) {
			info.node_types[i] = inferred;
			info.has_type[i] = true;
		}
	}
}

/**
 * Find the trailing LAMBDA_EXPR child of a CALL_EXPR and return its body type.
 * Used by `by lazy { ... }` delegation.
 */
fn TypeRef find_trailing_lambda_body_in_call(ParseResult* pr, TypeInfo* info, uint call_idx) {
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != call_idx) continue;
		if (pr.nodes[j].kind == LAMBDA_EXPR) {
			return last_expr_type_in(pr, info, j, true);
		}
		if (pr.nodes[j].kind == VALUE_ARGUMENT && pr.nodes[j].extra_text == "trailing") {
			uint expr_idx = ast::get_arg_expr_idx(pr, j);
			if (expr_idx != uint.max && pr.nodes[expr_idx].kind == LAMBDA_EXPR) {
				return last_expr_type_in(pr, info, expr_idx, true);
			}
		}
	}
	return TYPE_UNKNOWN;
}

/**
 * Phase 7: Resolve types for destructuring declaration components.
 *
 * For val (a, b) = expr:
 *   The parent PROPERTY_DECL has name "(destructuring)" with child PROPERTY_DECL nodes.
 *   If the initializer type is Pair<A,B>, child 0 gets A, child 1 gets B.
 *   If Triple<A,B,C>, child 0 gets A, child 1 gets B, child 2 gets C.
 *
 * For for ((k, v) in map):
 *   The FOR_STMT has PARAM children from the destructuring.
 *   If iterating a Map<K,V>, children get K and V.
 *   If iterating a List<Pair<A,B>>, children get A and B.
 */
fn void resolve_destructuring_types(ParseResult* pr, TypeInfo* info) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* node = &pr.nodes[i];

		// Case 1: val (a, b) = expr
		if (node.kind == PROPERTY_DECL && node.name == "(destructuring)") {
			// Find the initializer type (first expression child of this node)
			TypeRef init_type = TYPE_UNKNOWN;
			for (uint j = 0; j < pr.node_count; j++) {
				AstNode* child = &pr.nodes[j];
				if (child.parent != i) continue;
				// Skip child PROPERTY_DECL nodes (they are the destructured vars)
				if (child.kind == PROPERTY_DECL || child.kind == PARAM ||
					child.kind == TYPE_PARAM || child.kind == BLOCK ||
					child.kind == TYPE_REF) continue;
				// This is an expression child — use its type
				if (info.has_type[j]) {
					init_type = info.node_types[j];
				}
				break;
			}

			if (init_type.kind == UNKNOWN) continue;

			// Assign component types to child PROPERTY_DECL nodes
			assign_component_types(pr, info, i, init_type);
			continue;
		}

		// Case 2: for ((k, v) in map) — FOR_STMT with multiple PARAM children
		// Case 3: for (x in items) — FOR_STMT with single PARAM child
		if (node.kind == FOR_STMT) {
			uint param_count = ast::count_children_of_kind(pr, node, PARAM);
			if (param_count == 0) continue;

			// Find the collection type: first non-PARAM, non-BLOCK child
			TypeRef collection_type = TYPE_UNKNOWN;
			for (uint j = 0; j < pr.node_count; j++) {
				AstNode* child = &pr.nodes[j];
				if (child.parent != i) continue;
				if (child.kind == PARAM || child.kind == BLOCK) continue;
				if (info.has_type[j]) {
					collection_type = info.node_types[j];
				}
				break;
			}

			if (collection_type.kind == UNKNOWN) continue;

			// Determine element type. Built-in collections handled directly;
			// user types go through operator fun iterator() / next() lookup
			// (Kotlin spec §15.5).
			TypeRef element_type = get_iteration_element_type(collection_type);
			if (element_type.kind == UNKNOWN) {
				element_type = resolve_user_iterator_element_type(pr, info, collection_type);
			}
			if (element_type.kind == UNKNOWN) continue;

			if (param_count >= 2) {
				// Destructuring loop: assign component types
				assign_component_types_for_params(pr, info, i, element_type);
			} else {
				// Single-PARAM loop: assign element type to the PARAM child,
				// unless it has an explicit annotation already.
				for (uint j = 0; j < pr.node_count; j++) {
					AstNode* child = &pr.nodes[j];
					if (child.parent != i || child.kind != PARAM) continue;
					if (!info.has_type[j] || info.node_types[j].kind == UNKNOWN) {
						info.node_types[j] = element_type;
						info.has_type[j] = true;
					}
					break;
				}
			}
		}
	}
}

/**
 * Resolve element type via user-defined `operator fun iterator()` / `next()`
 * (Kotlin spec §15.5). Looks up `iterator()` on the collection type, then
 * `next()` on the returned iterator type. Returns its return type, or UNKNOWN.
 */
fn TypeRef resolve_user_iterator_element_type(ParseResult* pr, TypeInfo* info, TypeRef collection_type) {
	TypeRef iter_type = lookup_member_anywhere(pr, info, collection_type, "iterator");
	if (iter_type.kind == UNKNOWN) return TYPE_UNKNOWN;
	TypeRef next_type = lookup_member_anywhere(pr, info, iter_type, "next");
	return next_type;
}

/**
 * Assign componentN types to child PROPERTY_DECL nodes of a destructuring parent.
 */
fn void assign_component_types(ParseResult* pr, TypeInfo* info, uint parent_idx, TypeRef init_type) {
	uint comp_index = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != parent_idx || child.kind != PROPERTY_DECL) continue;
		// Skip if child already has an explicit type annotation
		if (!info.has_type[j] || info.node_types[j].kind == UNKNOWN) {
			TypeRef comp_type = get_component_type(init_type, comp_index);
			if (comp_type.kind == UNKNOWN) {
				comp_type = lookup_componentN(pr, info, init_type, comp_index);
			}
			if (comp_type.kind != UNKNOWN) {
				info.node_types[j] = comp_type;
				info.has_type[j] = true;
			}
		}
		comp_index++;
	}
}

/**
 * Assign componentN types to PARAM children of a FOR_STMT with destructuring.
 */
fn void assign_component_types_for_params(ParseResult* pr, TypeInfo* info, uint parent_idx, TypeRef element_type) {
	uint comp_index = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != parent_idx || child.kind != PARAM) continue;
		// Skip if child already has an explicit type annotation
		if (!info.has_type[j] || info.node_types[j].kind == UNKNOWN) {
			TypeRef comp_type = get_component_type(element_type, comp_index);
			if (comp_type.kind == UNKNOWN) {
				comp_type = lookup_componentN(pr, info, element_type, comp_index);
			}
			if (comp_type.kind != UNKNOWN) {
				info.node_types[j] = comp_type;
				info.has_type[j] = true;
			}
		}
		comp_index++;
	}
}

/**
 * Look up `operator fun componentN()` on a user-defined type for destructuring
 * (Kotlin spec §11.7). N is 1-based per the operator name. Returns UNKNOWN if
 * no matching operator exists. Used as fallback when built-in component-type
 * mapping (Pair/Triple/Map.Entry) doesn't apply.
 */
fn TypeRef lookup_componentN(ParseResult* pr, TypeInfo* info, TypeRef source_type, uint comp_index) {
	if (source_type.kind == UNKNOWN || source_type.name.len == 0) return TYPE_UNKNOWN;
	String name;
	switch (comp_index) {
		case 0: name = "component1";
		case 1: name = "component2";
		case 2: name = "component3";
		case 3: name = "component4";
		case 4: name = "component5";
		default: return TYPE_UNKNOWN;
	}
	return lookup_member_anywhere(pr, info, source_type, name);
}

/**
 * Get the Nth component type from a type that supports destructuring.
 *
 * Supported types:
 * - Pair<A, B>: component1 = A, component2 = B
 * - Triple<A, B, C>: component1 = A, component2 = B, component3 = C
 * - Map.Entry<K, V>: component1 = K, component2 = V
 * - Any data class with known type args (positional)
 */
fn TypeRef get_component_type(TypeRef source_type, uint index) {
	// For generic types with type arguments, map by position
	if (source_type.kind == GENERIC && source_type.type_arg_count > index) {
		String arg_name = source_type.type_arg_names[index];
		bool arg_nullable = source_type.type_arg_nullable[index];
		if (arg_name.len > 0) {
			return { .kind = SIMPLE, .name = arg_name, .nullable = arg_nullable };
		}
	}

	// For simple types that are known Pair/Triple (without explicit type args somehow)
	// This shouldn't normally happen, but handle gracefully
	return TYPE_UNKNOWN;
}

/**
 * Get the element type for iteration over a collection.
 *
 * - Map<K, V> -> Map.Entry<K, V> (represented as Pair<K, V> for destructuring)
 * - List<T> / Set<T> / Collection<T> / Iterable<T> -> T
 * - Array<T> -> T
 */
fn TypeRef get_iteration_element_type(TypeRef collection_type) {
	if (collection_type.kind != GENERIC || collection_type.type_arg_count == 0) {
		return TYPE_UNKNOWN;
	}

	String name = collection_type.name;

	// Map<K, V> iterates as Map.Entry<K, V> — destructures to (K, V)
	if (name == "Map" || name == "MutableMap" || name == "HashMap" || name == "LinkedHashMap" || name == "SortedMap" || name == "TreeMap") {
		if (collection_type.type_arg_count >= 2) {
			// Return a Pair-like type with K, V so destructuring works
			return {
				.kind = GENERIC,
				.name = "Map.Entry",
				.type_arg_count = 2,
				.type_arg_names = {
					collection_type.type_arg_names[0],
					collection_type.type_arg_names[1],
					"", "", "", "", "", ""
				},
				.type_arg_nullable = {
					collection_type.type_arg_nullable[0],
					collection_type.type_arg_nullable[1],
					false, false, false, false, false, false
				},
			};
		}
	}

	// List<Pair<A,B>>, Set<Pair<A,B>> etc. — element type is the first type arg
	// But the element itself needs to be resolved to handle nested generics
	// For now, just return the element as a simple type from first arg
	if (name == "List" || name == "MutableList" || name == "Set" || name == "MutableSet" ||
		name == "Collection" || name == "Iterable" || name == "Sequence" || name == "Array") {
		if (collection_type.type_arg_count >= 1) {
			String elem = collection_type.type_arg_names[0];
			bool elem_nullable = collection_type.type_arg_nullable[0];
			if (elem.len > 0) {
				return { .kind = SIMPLE, .name = elem, .nullable = elem_nullable };
			}
		}
	}

	return TYPE_UNKNOWN;
}

fn void resolve_expression_types(ParseResult* pr, TypeInfo* info) {
	// Multiple passes to propagate types through chains
	for (int pass = 0; pass < 3; pass++) {
		for (uint i = 0; i < pr.node_count; i++) {
			// On later passes, retry GENERIC nodes with 0 type args, and
			// LAMBDA_EXPR nodes whose return type may have been Unit-by-default
			// because the body expression hadn't been resolved yet.
			bool is_retry = false;
			if (info.has_type[i]) {
				if (pass > 0 && info.node_types[i].kind == GENERIC &&
				    info.node_types[i].type_arg_count == 0) {
					is_retry = true;
				} else if (pass > 0 && pr.nodes[i].kind == LAMBDA_EXPR) {
					is_retry = true;
				} else {
					continue;
				}
			}

			AstNode* node = &pr.nodes[i];
			TypeRef resolved = resolve_single_expression(pr, info, i, node);

			if (resolved.kind != UNKNOWN) {
				if (is_retry && resolved.kind == GENERIC && resolved.type_arg_count == 0) {
					continue;
				}
				info.node_types[i] = resolved;
				info.has_type[i] = true;
			}
		}
	}
}

/**
 * Try to resolve the type of a single expression node.
 */
fn TypeRef resolve_single_expression(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	switch (node.kind) {
		case NAME_EXPR:
			return resolve_name_expr_type(pr, info, idx, node);

		case CALL_EXPR:
			return resolve_call_expr_type(pr, info, idx, node);

		case DOT_EXPR:
			return resolve_dot_expr_type(pr, info, idx, node);

		case BINARY_EXPR:
			return resolve_binary_expr_type(pr, info, idx, node);

		case PREFIX_EXPR:
			return resolve_prefix_expr_type(pr, info, idx, node);

		case POSTFIX_EXPR:
			return resolve_postfix_expr_type(pr, info, idx, node);

		case PAREN_EXPR:
			return resolve_paren_expr_type(pr, info, idx, node);

		case IF_EXPR:
			return resolve_if_expr_type(pr, info, idx, node);

		case WHEN_EXPR:
			return resolve_when_expr_type(pr, info, idx, node);

		case INDEX_EXPR:
			return resolve_index_expr_type(pr, info, idx, node);

		case TYPE_CHECK_EXPR:
			return TYPE_BOOLEAN;  // x is Type -> Boolean

		case TYPE_CAST_EXPR:
			// x as Type -> Type, x as? Type -> Type?
			if (node.type_text.len > 0) {
				TypeRef cast_type = parse_type_text(node.type_text);
				if (node.extra_text == "as?") {
					cast_type.nullable = true;
				}
				return cast_type;
			}
			return TYPE_UNKNOWN;

		case ASSIGNMENT_EXPR:
			return TYPE_UNIT;

		case TRY_EXPR:
			return resolve_try_expr_type(pr, info, idx, node);

		case LAMBDA_EXPR:
			return resolve_lambda_expr_type(pr, info, idx, node);

		case CALLABLE_REF_EXPR:
			return resolve_callable_ref_type(pr, info, idx, node);

		default:
			return TYPE_UNKNOWN;
	}
}

// ── Name expression resolution ─────────────────────────────────────

fn TypeRef resolve_name_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	if (node.name.len == 0) return TYPE_UNKNOWN;

	// Flow-sensitive smart cast (Phase D): check CFG-based facts. Stability
	// gate (Phase E) is applied below once we have located the declaration.
	flow::Fact* fact = lookup_smart_cast_fact(pr, info, idx, node.name);

	// Special case: implicit lambda parameter `it`
	if (node.name == "it") {
		TypeRef it_type = resolve_lambda_it_type(pr, info, idx);
		if (it_type.kind != UNKNOWN) return it_type;
	}

	uint scope_idx = find_innermost_scope(pr, idx);

	uint current = scope_idx;
	while (true) {
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* candidate = &pr.nodes[j];
			if (candidate.parent != current) continue;
			if (!is_typed_declaration(candidate.kind)) continue;
			if (candidate.name != node.name) continue;

			// Stability gate: only apply smart-cast fact when the binding
			// is stable. Local val + parameters are always stable. Local
			// var is stable only when the use site is in the same function
			// as the declaration (i.e. not captured by a nested lambda /
			// anonymous function).
			bool stable = is_stable_for_smart_cast(pr, info, j, idx);
			flow::Fact* applied = stable ? fact : null;

			if (applied != null && applied.narrowed.kind != UNKNOWN) {
				return applied.narrowed;
			}

			if (info.has_type[j]) {
				TypeRef base = info.node_types[j];
				if (applied != null && applied.not_null && base.nullable) {
					base.nullable = false;
				}
				return base;
			}
			return TYPE_UNKNOWN;
		}

		// Also look inside destructuring-wrapper PROPERTY_DECLs at this scope.
		// `val (a, b) = expr` produces a PROPERTY_DECL named "(destructuring)"
		// whose PROPERTY_DECL children are the destructured bindings. Their
		// parent is the wrapper, not the enclosing BLOCK, so the direct-child
		// scan above misses them. (Kotlin spec §11.7)
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* wrapper = &pr.nodes[j];
			if (wrapper.parent != current) continue;
			if (wrapper.kind != PROPERTY_DECL || wrapper.name != "(destructuring)") continue;
			for (uint k = 0; k < pr.node_count; k++) {
				AstNode* inner = &pr.nodes[k];
				if (inner.parent != j) continue;
				if (inner.kind != PROPERTY_DECL) continue;
				if (inner.name != node.name) continue;
				bool stable = is_stable_for_smart_cast(pr, info, k, idx);
				flow::Fact* applied = stable ? fact : null;
				if (applied != null && applied.narrowed.kind != UNKNOWN) {
					return applied.narrowed;
				}
				if (info.has_type[k]) {
					TypeRef base = info.node_types[k];
					if (applied != null && applied.not_null && base.nullable) {
						base.nullable = false;
					}
					return base;
				}
				return TYPE_UNKNOWN;
			}
		}

		AstNode* scope = &pr.nodes[current];
		if (current == 0 || scope.parent == ast::NO_PARENT) break;
		current = scope.parent;
	}

	// Scope walk did not find the declaration (e.g. when-subject `val x`
	// whose parent is WHEN_EXPR, not a recognized scope). If we have a
	// flow fact carrying an explicit narrowed type, return it. We cannot
	// apply the stability gate without a decl_idx; this matches K1
	// behaviour for these edge cases.
	if (fact != null && fact.narrowed.kind != UNKNOWN) {
		return fact.narrowed;
	}

	// Lambda receiver: resolve as member of lambda's implicit `this` receiver
	TypeRef lambda_recv_member = resolve_lambda_receiver_member(pr, info, idx, node.name);
	if (lambda_recv_member.kind != UNKNOWN) return lambda_recv_member;

	// Cross-file: query workspace for class/object types
	if (g_workspace != null) {
		if (try indices = g_workspace.lookup_by_name(node.name)) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = g_workspace.get_symbol((*indices)[i]);
				if (sym.kind == symbols::SymbolKind.CLASS || sym.kind == symbols::SymbolKind.INTERFACE ||
				    sym.kind == symbols::SymbolKind.OBJECT) {
					return { .kind = SIMPLE, .name = sym.name, .is_class_ref = true };
				}
			}
		}

		// Dep index: resolve class/interface/enum/object types by import
		if (g_workspace.dep_index.initialized) {
			TypeRef dep_result = resolve_dep_name_by_import(&g_workspace.dep_index, pr, node.name);
			if (dep_result.kind != UNKNOWN) return dep_result;
		}
	}

	// Hardcoded stdlib class-ref fallback (Kotlin spec stdlib). Recognises
	// well-known stdlib type names (Result, ...) as class-ref TypeRefs so
	// `Result.success(x)` can resolve `Result` even when the workspace
	// dep index is unavailable (tests, no kotlin-stdlib jar).
	TypeRef stdlib_class = resolve_stdlib_class_name(node.name);
	if (stdlib_class.kind != UNKNOWN) return stdlib_class;

	return TYPE_UNKNOWN;
}

// ── Lambda `it` type inference ─────────────────────────────────────

/**
 * Resolve the type of the implicit `it` parameter inside a lambda.
 *
 * Strategy: walk up from the NAME_EXPR to find the enclosing LAMBDA_EXPR.
 * If the lambda has no explicit PARAM children (implicit `it`), find the
 * enclosing CALL_EXPR, determine the call method name and receiver type,
 * then return the expected `it` type based on the method.
 *
 * For scope functions (let, also, takeIf, takeUnless): it = receiver type
 * For collection HOFs (filter, forEach, etc.): it = element type T
 * For map HOFs (forEach, etc.): it = Map.Entry<K,V> (simplified to UNKNOWN)
 */
fn TypeRef resolve_lambda_it_type(ParseResult* pr, TypeInfo* info, uint name_idx) {
	// Walk up to find the enclosing LAMBDA_EXPR
	uint lambda_idx = ast::NO_PARENT;
	uint current = name_idx;
	while (current != 0 && current != ast::NO_PARENT) {
		uint parent = pr.nodes[current].parent;
		if (parent == ast::NO_PARENT) break;
		if (pr.nodes[parent].kind == LAMBDA_EXPR) {
			lambda_idx = parent;
			break;
		}
		current = parent;
	}
	if (lambda_idx == ast::NO_PARENT) return TYPE_UNKNOWN;

	// Check that this lambda has no explicit parameters
	// (if it has PARAM children, `it` is not the implicit parameter)
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == lambda_idx && pr.nodes[j].kind == PARAM) {
			return TYPE_UNKNOWN; // Has explicit params, `it` is not implicit
		}
	}

	// Walk up from the LAMBDA_EXPR to find the enclosing CALL_EXPR
	// (handles both direct child and VALUE_ARGUMENT-wrapped forms).
	uint call_idx = ast::find_call_for_lambda(pr, lambda_idx);
	if (call_idx == ast::NO_PARENT) return TYPE_UNKNOWN;

	String method_name = pr.nodes[call_idx].name;
	if (method_name.len == 0) return TYPE_UNKNOWN;

	// Case 1: Scope functions — `it` is the receiver itself
	// receiver.let { it }, receiver.also { it }, receiver.takeIf { it }
	if (method_name == "let" || method_name == "also" ||
	    method_name == "takeIf" || method_name == "takeUnless") {
		// The CALL_EXPR might be a child of a DOT_EXPR
		// Look for the DOT_EXPR receiver to get the type
		TypeRef recv = find_call_receiver_type(pr, info, call_idx);
		// If the call uses safe-call operator (?.), the lambda only executes
		// when receiver is non-null, so `it` is the non-nullable type.
		if (recv.nullable && is_safe_call(pr, call_idx)) {
			recv.nullable = false;
		}
		return recv;
	}

	// Case 2: Collection HOFs — `it` is the element type T
	// receiver.filter { it }, receiver.forEach { it }, etc.
	if (is_collection_hof(method_name)) {
		TypeRef receiver = find_call_receiver_type(pr, info, call_idx);
		if (receiver.kind == GENERIC && receiver.type_arg_count > 0) {
			return { .kind = SIMPLE, .name = receiver.type_arg_names[0],
			         .nullable = receiver.type_arg_nullable[0] };
		}
		// For String.forEach { it } -> Char
		if (receiver.name == "String") return TYPE_CHAR;
		return TYPE_UNKNOWN;
	}

	return TYPE_UNKNOWN;
}

// ── Lambda receiver type inference ─────────────────────────────────

/**
 * Check if a method name is a scope function where the lambda receiver
 * is the call receiver (apply, run) or first argument (with, buildString, etc).
 */
fn bool is_receiver_scope_function(String name) {
	return name == "apply" || name == "run" ||
	       name == "with" || name == "buildString" || name == "buildList" ||
	       name == "buildSet" || name == "buildMap";
}

/**
 * Resolve a name as a member of the lambda receiver type.
 * For scope functions (apply/run), the receiver is the call's receiver.
 * For dep functions with receiver-typed lambda params, extract from signature.
 */
fn TypeRef resolve_lambda_receiver_member(ParseResult* pr, TypeInfo* info, uint name_idx, String member_name) {
	// Walk up to find enclosing LAMBDA_EXPR
	uint lambda_idx = ast::NO_PARENT;
	uint current = name_idx;
	while (current != 0 && current != ast::NO_PARENT) {
		uint parent = pr.nodes[current].parent;
		if (parent == ast::NO_PARENT) break;
		if (pr.nodes[parent].kind == LAMBDA_EXPR) {
			lambda_idx = parent;
			break;
		}
		current = parent;
	}
	if (lambda_idx == ast::NO_PARENT) return TYPE_UNKNOWN;

	// Find enclosing CALL_EXPR (handles VALUE_ARGUMENT wrap).
	uint call_idx = ast::find_call_for_lambda(pr, lambda_idx);
	if (call_idx == ast::NO_PARENT) return TYPE_UNKNOWN;

	String method_name = pr.nodes[call_idx].name;
	if (method_name.len == 0) return TYPE_UNKNOWN;

	TypeRef receiver_type = TYPE_UNKNOWN;

	// Scope functions: lambda receiver = call receiver
	if (is_receiver_scope_function(method_name)) {
		receiver_type = find_call_receiver_type(pr, info, call_idx);
		if (receiver_type.nullable && is_safe_call(pr, call_idx)) {
			receiver_type.nullable = false;
		}
	}

	// If we have a receiver type, resolve the member on it
	if (receiver_type.kind != UNKNOWN && g_workspace != null && g_workspace.dep_index.initialized) {
		TypeRef result = resolve_dep_member_type(&g_workspace.dep_index, receiver_type, member_name, pr);
		if (result.kind != UNKNOWN) return result;

		// Also try workspace (cross-file) member lookup
		if (try members = g_workspace.lookup_members(receiver_type.name)) {
			for (usz i = 0; i < members.len(); i++) {
				workspace::MemberDecl* m = &(*members)[i];
				if (m.name == member_name) {
					if (m.type_text.len > 0) {
						return parse_type_text(m.type_text);
					}
					return { .kind = SIMPLE, .name = m.name };
				}
			}
		}
	}

	// For dep function calls: check if lambda param has receiver type in signature
	if (receiver_type.kind == UNKNOWN && g_workspace != null && g_workspace.dep_index.initialized) {
		TypeRef lambda_recv = resolve_dep_lambda_receiver(&g_workspace.dep_index, pr, method_name);
		if (lambda_recv.kind != UNKNOWN) {
			TypeRef result = resolve_dep_member_type(&g_workspace.dep_index, lambda_recv, member_name, pr);
			if (result.kind != UNKNOWN) return result;
		}
	}

	return TYPE_UNKNOWN;
}

/**
 * Look up a dep function by name and extract the receiver type from its
 * last parameter if it's a function type with receiver (e.g., Route.() -> Unit).
 */
fn TypeRef resolve_dep_lambda_receiver(DependencyIndex* dep_index, ParseResult* pr, String method_name) {
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(method_name, &matches);
	if (count == 0) return TYPE_UNKNOWN;

	for (usz i = 0; i < count; i++) {
		if (matches[i].kind != DEP_METHOD) continue;
		TypeRef recv = extract_lambda_receiver_from_sig(matches[i].signature);
		if (recv.kind != UNKNOWN) return recv;
	}
	return TYPE_UNKNOWN;
}

/**
 * Extract the lambda receiver type from a function signature string.
 * Looks for the last function-type parameter with a receiver.
 * E.g., "fun get(path: String, body: PipelineContext.() -> Unit): Route"
 *   -> returns TypeRef{PipelineContext}
 */
fn TypeRef extract_lambda_receiver_from_sig(String sig) {
	// Find the parameter list between outermost ( and )
	usz paren_start = 0;
	usz paren_end = 0;
	int depth = 0;
	for (usz i = 0; i < sig.len; i++) {
		if (sig[i] == '(' && depth == 0) {
			paren_start = i + 1;
			depth = 1;
		} else if (sig[i] == '(') {
			depth++;
		} else if (sig[i] == ')') {
			depth--;
			if (depth == 0) {
				paren_end = i;
				break;
			}
		}
	}
	if (paren_end == 0) return TYPE_UNKNOWN;

	String params = sig[paren_start..paren_end - 1];

	// Find ".(" pattern — indicates a receiver function type
	// Walk from end to find last occurrence
	for (usz i = params.len; i > 1; i--) {
		if (params[i - 1] == '(' && i >= 2 && params[i - 2] == '.') {
			usz dot_pos = i - 2;
			// Walk back to find start of type name
			usz name_end = dot_pos;
			usz name_start = dot_pos;
			int gen_depth = 0;
			while (name_start > 0) {
				name_start--;
				char c = params[name_start];
				if (c == '>') {
					gen_depth++;
				} else if (c == '<') {
					gen_depth--;
				} else if (gen_depth == 0 && !is_type_name_char(c)) {
					name_start++;
					break;
				}
			}
			if (name_start < name_end) {
				String recv_name = params[name_start..name_end - 1];
				// Strip generic params
				for (usz j = 0; j < recv_name.len; j++) {
					if (recv_name[j] == '<') {
						recv_name = recv_name[:j];
						break;
					}
				}
				if (recv_name.len > 0) {
					return { .kind = SIMPLE, .name = recv_name };
				}
			}
		}
	}

	return TYPE_UNKNOWN;
}

fn bool is_type_name_char(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') || c == '_' || c == '.';
}

/**
 * Determine if a method name is a collection higher-order function
 * where the lambda's implicit `it` parameter is the element type.
 */
fn bool is_collection_hof(String name) {
	return name == "filter" || name == "filterNot" || name == "filterNotNull" ||
	       name == "forEach" || name == "forEachIndexed" ||
	       name == "onEach" || name == "onEachIndexed" ||
	       name == "any" || name == "all" || name == "none" || name == "count" ||
	       name == "first" || name == "firstOrNull" ||
	       name == "last" || name == "lastOrNull" ||
	       name == "single" || name == "singleOrNull" ||
	       name == "find" || name == "findLast" ||
	       name == "sortedBy" || name == "sortedByDescending" ||
	       name == "maxBy" || name == "maxByOrNull" ||
	       name == "minBy" || name == "minByOrNull" ||
	       name == "groupBy" || name == "associateBy" || name == "associateWith" ||
	       name == "distinctBy" || name == "partition" ||
	       name == "takeWhile" || name == "dropWhile" ||
	       name == "map" || name == "flatMap" || name == "mapNotNull" ||
	       name == "sumOf" || name == "sumBy";
}

/**
 * Find the receiver type of a CALL_EXPR by looking for the DOT_EXPR parent
 * or the receiver child of the DOT_EXPR.
 *
 * For `receiver.method { ... }`, the DOT_EXPR has the receiver as first child
 * and the call is either:
 * - A trailing lambda: CALL_EXPR wraps DOT_EXPR and LAMBDA_EXPR
 * - A regular call: DOT_EXPR contains CALL_EXPR
 *
 * In the KLS AST, trailing lambda calls like `items.filter { }` produce:
 *   CALL_EXPR "filter"
 *     DOT_EXPR "filter"
 *       NAME_EXPR "items"     <-- receiver (has type)
 *     LAMBDA_EXPR
 *
 * Or for chained calls like `items.filter { }.first()`:
 *   CALL_EXPR "first"
 *     DOT_EXPR "first"
 *       CALL_EXPR "filter"
 *         ...
 */
fn TypeRef find_call_receiver_type(ParseResult* pr, TypeInfo* info, uint call_idx) {
	// Look for DOT_EXPR child of CALL_EXPR
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != call_idx) continue;
		if (pr.nodes[j].kind == DOT_EXPR) {
			// The DOT_EXPR's first child is the receiver
			for (uint k = 0; k < pr.node_count; k++) {
				if (pr.nodes[k].parent == j && info.has_type[k]) {
					return info.node_types[k];
				}
			}
			break;
		}
	}

	// If the CALL_EXPR itself is a child of a DOT_EXPR, the DOT_EXPR's
	// first child (before this CALL_EXPR) is the receiver
	uint call_parent = pr.nodes[call_idx].parent;
	if (call_parent != ast::NO_PARENT && pr.nodes[call_parent].kind == DOT_EXPR) {
		for (uint k = 0; k < pr.node_count; k++) {
			if (pr.nodes[k].parent == call_parent && info.has_type[k]) {
				return info.node_types[k];
			}
		}
	}

	return TYPE_UNKNOWN;
}

/**
 * Check if a CALL_EXPR uses safe-call operator (?.) on its receiver.
 * The parser stores extra_text = "?." on DOT_EXPR nodes for safe calls.
 */
fn bool is_safe_call(ParseResult* pr, uint call_idx) {
	// Check if CALL_EXPR has a DOT_EXPR child with extra_text "?."
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != call_idx) continue;
		if (pr.nodes[j].kind == DOT_EXPR) {
			return pr.nodes[j].extra_text == "?.";
		}
	}
	// Check if CALL_EXPR's parent is a DOT_EXPR with safe call
	uint parent = pr.nodes[call_idx].parent;
	if (parent != ast::NO_PARENT && pr.nodes[parent].kind == DOT_EXPR) {
		return pr.nodes[parent].extra_text == "?.";
	}
	return false;
}


// ── Call expression resolution ─────────────────────────────────────

/**
 * Count the number of arguments in a CALL_EXPR node.
 * Skips the callee NAME_EXPR and trailing lambda VALUE_ARGUMENT.
 */
fn uint count_call_args(ParseResult* pr, uint call_idx, String callee_name) {
	uint count = 0;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != call_idx) continue;
		// Only count VALUE_ARGUMENT children (parenthesized args)
		if (child.kind != VALUE_ARGUMENT) continue;
		// Skip trailing lambda (it counts as a parameter but not a positional arg)
		if (child.extra_text == "trailing") continue;
		count++;
	}
	return count;
}

fn TypeRef resolve_call_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	if (node.name.len == 0) return TYPE_UNKNOWN;

	// Check for well-known constructor/factory calls. User-defined class with
	// same name shadows stdlib (Kotlin spec §16.10 scope resolution); skip
	// stdlib short-circuit so the constructor branch can run with proper
	// type-argument inference from primary-ctor PARAMs.
	bool user_class_shadows = false;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* candidate = &pr.nodes[j];
		if (candidate.kind != CLASS_DECL && candidate.kind != OBJECT_DECL) continue;
		if (candidate.name == node.name) { user_class_shadows = true; break; }
	}
	if (!user_class_shadows) {
		TypeRef known = resolve_known_call(node.name);
		if (known.kind != UNKNOWN) {
			// Try to infer type arguments from call arguments
			if (known.kind == GENERIC && known.type_arg_count == 0) {
				known = infer_generic_args_from_call(pr, info, idx, known);
			}
			return known;
		}
	}

	// `runCatching { ... }` → Result<T> where T = lambda body type.
	// (Kotlin spec stdlib: kotlin.runCatching). Top-level form only;
	// receiver form `x.runCatching { }` falls through to DOT_EXPR path.
	if (node.name == "runCatching") {
		TypeRef body = find_trailing_lambda_body_in_call(pr, info, idx);
		TypeRef result = { .kind = GENERIC, .name = "Result" };
		if (body.kind != UNKNOWN && body.name.len > 0) {
			result.type_arg_count = 1;
			result.type_arg_names[0] = body.name;
			result.type_arg_nullable[0] = body.nullable;
		}
		return result;
	}

	// Stdlib static factories on class refs: `Result.success(x)` / `Result.failure(e)`.
	// CALL_EXPR has DOT_EXPR child whose receiver is a class-ref NAME_EXPR.
	// Decoded here so we can pull the argument type for the type parameter.
	if (node.name == "success" || node.name == "failure") {
		TypeRef factory = resolve_static_factory_call(pr, info, idx);
		if (factory.kind != UNKNOWN) return factory;
	}

	// Count arguments of this call expression
	uint call_arg_count = count_call_args(pr, idx, node.name);

	// Method call on a receiver: try in-file member resolution FIRST so user
	// generic class members get proper type-arg substitution (Box<Int>.get():
	// Int, not raw T from a top-level FUN_DECL match by bare name).
	bool is_method_call = false;
	bool generic_receiver = false;
	bool method_receiver_known = false;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != idx) continue;
		if (child.kind == DOT_EXPR && child.name == node.name) { is_method_call = true; break; }
	}
	if (is_method_call) {
		TypeRef receiver_type = find_call_receiver_type(pr, info, idx);
		if (receiver_type.kind != UNKNOWN && receiver_type.name.len > 0) {
			method_receiver_known = true;
			if (receiver_type.kind == GENERIC && receiver_type.type_arg_count > 0) {
				generic_receiver = true;
			}
			TypeRef member_result = resolve_in_file_member(pr, receiver_type, node.name);
			if (member_result.kind != UNKNOWN) return member_result;
		}
	}

	// Search for best FUN_DECL matching this name (prefer param count match).
	// Skip when this is a method call AND we know the receiver type — the
	// receiver-based resolution above is authoritative; falling through to a
	// bare-name FUN_DECL match would lose type-arg substitution (Box<Int>.get()
	// → raw T) or pick an unrelated same-name member. When the receiver is
	// unknown (still being typed), fall through and defer — caller's retry
	// loop will re-resolve once receiver gets typed.
	uint best_idx = 0;
	bool found_any = false;
	bool found_exact = false;

	bool skip_fun_search = generic_receiver || (is_method_call && !method_receiver_known);
	if (!skip_fun_search) for (uint j = 0; j < pr.node_count; j++) {
		AstNode* candidate = &pr.nodes[j];
		if (candidate.kind != FUN_DECL) continue;
		if (candidate.name != node.name) continue;

		if (!found_any) {
			best_idx = j;
			found_any = true;
		}

		// Score by parameter count match
		if (!found_exact) {
			uint param_count = ast::count_children_of_kind(pr, candidate, PARAM);
			if (param_count == call_arg_count) {
				best_idx = j;
				found_exact = true;
			}
		}
	}

	if (found_any) {
		if (info.has_type[best_idx]) {
			TypeRef ret = info.node_types[best_idx];
			// Substitute user-defined generic type parameters using arg types.
			// Maps fun <T> id(x: T): T → id(42) returns Int (Kotlin spec §11.1.7).
			ret = substitute_user_type_params(pr, info, best_idx, idx, ret);
			return ret;
		}
		return TYPE_UNKNOWN;
	}

	// Check if it's a constructor call (name matches a class)
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* candidate = &pr.nodes[j];
		if (candidate.kind != CLASS_DECL && candidate.kind != OBJECT_DECL) continue;
		if (candidate.name != node.name) continue;

		TypeRef result = { .kind = SIMPLE, .name = candidate.name };
		// Infer class type-args from primary-ctor PARAM types vs call arg types.
		// Box<T>(val v: T); Box(42) -> Box<Int>. (Kotlin spec §11.1.7.)
		if (candidate.kind == CLASS_DECL) {
			result = infer_class_type_args(pr, info, j, idx, result);
		}
		return result;
	}

	// Cross-file: query workspace for constructor calls and function return types
	if (g_workspace != null) {
		if (try indices = g_workspace.lookup_by_name(node.name)) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = g_workspace.get_symbol((*indices)[i]);
				// Constructor call: class name matches
				if (sym.kind == symbols::SymbolKind.CLASS || sym.kind == symbols::SymbolKind.OBJECT) {
					return { .kind = SIMPLE, .name = sym.name };
				}
			}
		}

		// Constructor call from dependency: check dep index for class name
		if (g_workspace.dep_index.initialized) {
			DepSymbol*[4] dep_matches;
			usz dep_count = g_workspace.dep_index.lookup_by_name(node.name, &dep_matches);
			for (usz i = 0; i < dep_count; i++) {
				if (dep_matches[i].kind == DEP_CLASS || dep_matches[i].kind == DEP_INTERFACE ||
					dep_matches[i].kind == DEP_ENUM || dep_matches[i].kind == DEP_OBJECT) {
					return { .kind = SIMPLE, .name = node.name };
				}
			}
		}

		// PascalCase heuristic: if name starts with uppercase and wasn't found
		// in any index, it's almost certainly a constructor call
		if (node.name[0] >= 'A' && node.name[0] <= 'Z') {
			return { .kind = SIMPLE, .name = node.name };
		}

		// Method call on a receiver: g.greet() — resolve via receiver type + member cache
		TypeRef receiver_type = find_call_receiver_type(pr, info, idx);
		if (receiver_type.kind != UNKNOWN && receiver_type.name.len > 0) {
			// Try hardcoded stdlib first
			TypeRef member_result = resolve_member_type(receiver_type, node.name);
			if (member_result.kind != UNKNOWN) return member_result;
			// Try workspace member cache
			member_result = resolve_workspace_member_type(receiver_type, node.name);
			if (member_result.kind != UNKNOWN) return member_result;
			// Try dependency index
			if (g_workspace.dep_index.initialized) {
				member_result = resolve_dep_member_type(&g_workspace.dep_index, receiver_type, node.name, pr);
				if (member_result.kind != UNKNOWN) return member_result;
			}
		}
	}

	// Trailing lambda pattern: CALL_EXPR wraps DOT_EXPR + LAMBDA_EXPR
	// Use the DOT_EXPR child's resolved type (the method call result)
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx && pr.nodes[j].kind == DOT_EXPR && info.has_type[j]) {
			return info.node_types[j];
		}
	}

	// `operator fun invoke()` resolution per Kotlin spec §9.6: when the
	// callee `name` resolves to a value of some type T (not a function),
	// the call is rewritten to `name.invoke(...)`. Look up T.invoke and
	// return its result type.
	uint val_decl = find_decl_in_scope_chain(pr, idx, node.name);
	if (val_decl != ast::NO_PARENT && info.has_type[val_decl]) {
		TypeRef val_type = info.node_types[val_decl];
		// Lambda value / function-typed val: return its declared return type.
		if (val_type.kind == FUNCTION && val_type.return_type_name.len > 0) {
			return parse_type_text(val_type.return_type_name);
		}
		if (val_type.kind != UNKNOWN && val_type.kind != FUNCTION) {
			TypeRef invoke_result = lookup_member_anywhere(pr, info, val_type, "invoke");
			if (invoke_result.kind != UNKNOWN) return invoke_result;
		}
	}

	return TYPE_UNKNOWN;
}

/**
 * Infer generic type arguments from the arguments of a call expression.
 * For collection factories like listOf(1, 2), infers List<Int>.
 * For mapOf("a" to 1), infers Map<String, Int>.
 */
fn TypeRef infer_generic_args_from_call(ParseResult* pr, TypeInfo* info, uint call_idx, TypeRef base) {
	// Find the first argument expression child of this CALL_EXPR
	TypeRef first_arg_type = TYPE_UNKNOWN;
	TypeRef second_arg_type = TYPE_UNKNOWN;
	uint arg_count = 0;

	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != call_idx) continue;
		if (child.kind != VALUE_ARGUMENT) continue;
		uint expr_idx = ast::get_arg_expr_idx(pr, j);
		if (expr_idx == uint.max) continue;

		if (info.has_type[expr_idx]) {
			if (arg_count == 0) {
				first_arg_type = info.node_types[expr_idx];
			} else if (arg_count == 1) {
				second_arg_type = info.node_types[expr_idx];
			}
		}
		arg_count++;
	}

	// For single-element collections, use first arg type
	if (first_arg_type.kind != UNKNOWN) {
		String container = base.name;

		// For Map, the arg is typically a Pair (from `to` infix)
		if ((container == "Map" || container == "MutableMap" || container == "HashMap" || container == "LinkedHashMap")
		    && first_arg_type.name == "Pair") {
			if (first_arg_type.type_arg_count >= 2) {
				base.type_arg_count = 2;
				base.type_arg_names[0] = first_arg_type.type_arg_names[0];
				base.type_arg_names[1] = first_arg_type.type_arg_names[1];
				base.type_arg_nullable[0] = first_arg_type.type_arg_nullable[0];
				base.type_arg_nullable[1] = first_arg_type.type_arg_nullable[1];
			}
			return base;
		}

		// For single-type-param collections: List<T>, Set<T>, Array<T>, etc.
		if (container == "List" || container == "Set" || container == "Array" ||
			container == "Sequence" || container == "MutableList" || container == "MutableSet") {
			base.type_arg_count = 1;
			base.type_arg_names[0] = first_arg_type.name;
			base.type_arg_nullable[0] = first_arg_type.nullable;
			return base;
		}
	}

	return base;
}

/**
 * Substitute user-defined generic type parameters in a function's return type
 * by inferring T = arg-type from positional FUN_DECL PARAM ↔ CALL_EXPR ARG
 * matching (Kotlin spec §11.1.7 type-argument inference).
 *
 * Strategy: for each TYPE_PARAM child of the FUN_DECL, find the first PARAM
 * whose declared type-text mentions the type-param name (top-level, not
 * inside a generic container). Take the corresponding call argument's
 * resolved type as the substitution. Then rewrite `ret` if its `name` or
 * any `type_arg_names[i]` equals a type-param name.
 *
 * Limitations:
 *   - Only top-level param-type matches (`(x: T)`, not `(x: List<T>)`).
 *   - Only return-type substitution; doesn't propagate into call-arg
 *     contexts. Sufficient for `identity(x)` / single-T transformers.
 *   - Up to 4 type parameters per function.
 */
fn TypeRef substitute_user_type_params(ParseResult* pr, TypeInfo* info,
		uint fun_decl_idx, uint call_idx, TypeRef ret) {
	const usz MAX_TP = 4;
	String[MAX_TP] tp_names;
	usz tp_count = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != fun_decl_idx) continue;
		if (child.kind != TYPE_PARAM) continue;
		if (tp_count >= MAX_TP) break;
		tp_names[tp_count++] = child.name;
	}
	if (tp_count == 0) return ret;

	bool ret_uses_tp = false;
	for (usz t = 0; t < tp_count; t++) {
		if (ret.name == tp_names[t]) { ret_uses_tp = true; break; }
		for (uint a = 0; a < ret.type_arg_count; a++) {
			if (ret.type_arg_names[a] == tp_names[t]) { ret_uses_tp = true; break; }
		}
		if (ret_uses_tp) break;
	}
	if (!ret_uses_tp) return ret;

	String[MAX_TP] subst_names;
	bool[MAX_TP] subst_nullable;
	bool[MAX_TP] subst_known;
	for (usz t = 0; t < tp_count; t++) subst_known[t] = false;

	uint param_pos = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != fun_decl_idx) continue;
		if (child.kind != PARAM) continue;
		String pt = child.type_text;
		for (usz t = 0; t < tp_count; t++) {
			if (subst_known[t]) continue;
			if (pt == tp_names[t]) {
				TypeRef arg = nth_call_arg_type(pr, info, call_idx, param_pos);
				if (arg.kind != UNKNOWN && arg.name.len > 0) {
					subst_names[t] = arg.name;
					subst_nullable[t] = arg.nullable;
					subst_known[t] = true;
				}
			}
		}
		param_pos++;
	}

	TypeRef out = ret;
	for (usz t = 0; t < tp_count; t++) {
		if (!subst_known[t]) continue;
		if (out.name == tp_names[t]) {
			out.name = subst_names[t];
			if (subst_nullable[t]) out.nullable = true;
		}
		for (uint a = 0; a < out.type_arg_count; a++) {
			if (out.type_arg_names[a] == tp_names[t]) {
				out.type_arg_names[a] = subst_names[t];
				if (subst_nullable[t]) out.type_arg_nullable[a] = true;
			}
		}
	}
	return out;
}

/**
 * Get the resolved type of the Nth positional VALUE_ARGUMENT of a CALL_EXPR.
 * Returns TYPE_UNKNOWN if absent or unresolved.
 */
fn TypeRef nth_call_arg_type(ParseResult* pr, TypeInfo* info, uint call_idx, uint n) {
	uint pos = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != call_idx) continue;
		if (child.kind != VALUE_ARGUMENT) continue;
		if (pos == n) {
			uint expr_idx = ast::get_arg_expr_idx(pr, j);
			if (expr_idx == uint.max) return TYPE_UNKNOWN;
			if (info.has_type[expr_idx]) return info.node_types[expr_idx];
			return TYPE_UNKNOWN;
		}
		pos++;
	}
	return TYPE_UNKNOWN;
}

/**
 * Infer class type-arguments at a constructor call site by matching
 * primary-ctor PARAM types against call arg types (Kotlin spec §11.1.7).
 *
 * `class Box<T>(val v: T)`; `Box(42)` → returns `Box<Int>`.
 *
 * Strategy: collect the class's TYPE_PARAM names, then walk the primary-ctor
 * PARAMs (PARAM children of the CLASS_DECL — Kotlin desugars `class Box<T>(val v: T)`
 * into the class with PARAM children for the primary ctor). For each PARAM whose
 * type-text equals a TP name (top-level only), bind that TP to the corresponding
 * positional call-arg type. Promote the result to GENERIC with bound type-args.
 */
fn TypeRef infer_class_type_args(ParseResult* pr, TypeInfo* info,
		uint class_decl_idx, uint call_idx, TypeRef base) {
	const usz MAX_TP = 4;
	String[MAX_TP] tp_names;
	usz tp_count = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != class_decl_idx) continue;
		if (child.kind != TYPE_PARAM) continue;
		if (tp_count >= MAX_TP) break;
		tp_names[tp_count++] = child.name;
	}
	if (tp_count == 0) return base;

	String[MAX_TP] subst_names;
	bool[MAX_TP] subst_nullable;
	bool[MAX_TP] subst_known;
	for (usz t = 0; t < tp_count; t++) subst_known[t] = false;

	uint param_pos = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != class_decl_idx) continue;
		if (child.kind != PARAM) continue;
		String pt = child.type_text;
		for (usz t = 0; t < tp_count; t++) {
			if (subst_known[t]) continue;
			if (pt == tp_names[t]) {
				TypeRef arg = nth_call_arg_type(pr, info, call_idx, param_pos);
				if (arg.kind != UNKNOWN && arg.name.len > 0) {
					subst_names[t] = arg.name;
					subst_nullable[t] = arg.nullable;
					subst_known[t] = true;
				}
			}
		}
		param_pos++;
	}

	// Build GENERIC TypeRef with type-args (UNKNOWN slot for unbound TPs)
	TypeRef out = base;
	out.kind = GENERIC;
	out.type_arg_count = (uint)tp_count;
	for (usz t = 0; t < tp_count; t++) {
		if (subst_known[t]) {
			out.type_arg_names[t] = subst_names[t];
			out.type_arg_nullable[t] = subst_nullable[t];
		} else {
			// Leave the TP name as a placeholder so downstream substitution
			// can still recognise it. (format_type prints it verbatim.)
			out.type_arg_names[t] = tp_names[t];
			out.type_arg_nullable[t] = false;
		}
	}
	return out;
}

/**
 * Hardcoded stdlib class-ref name table. Recognises well-known stdlib type
 * names so they can be referenced as bare class refs (`Result.success(x)`,
 * `Pair.…`, etc.) without requiring the workspace dep index to be available.
 *
 * Returns a class-ref TypeRef (`is_class_ref = true`) so DOT_EXPR member
 * resolution treats the receiver as a static-member lookup (Kotlin spec
 * companion-object access semantics).
 */
fn TypeRef resolve_stdlib_class_name(String name) {
	if (name == "Result") {
		return { .kind = SIMPLE, .name = "Result", .is_class_ref = true };
	}
	return TYPE_UNKNOWN;
}

/**
 * Resolve well-known stdlib factory/constructor calls.
 */
fn TypeRef resolve_known_call(String name) {	if (name == "listOf" || name == "emptyList") {
		return { .kind = GENERIC, .name = "List" };
	}
	if (name == "mutableListOf" || name == "arrayListOf") {
		return { .kind = GENERIC, .name = "MutableList" };
	}
	if (name == "setOf" || name == "emptySet") {
		return { .kind = GENERIC, .name = "Set" };
	}
	if (name == "mutableSetOf" || name == "hashSetOf" || name == "linkedSetOf") {
		return { .kind = GENERIC, .name = "MutableSet" };
	}
	if (name == "mapOf" || name == "emptyMap") {
		return { .kind = GENERIC, .name = "Map" };
	}
	if (name == "mutableMapOf" || name == "hashMapOf" || name == "linkedMapOf") {
		return { .kind = GENERIC, .name = "MutableMap" };
	}
	if (name == "arrayOf" || name == "emptyArray") {
		return { .kind = GENERIC, .name = "Array" };
	}
	if (name == "sequenceOf" || name == "emptySequence") {
		return { .kind = GENERIC, .name = "Sequence" };
	}
	if (name == "Pair") return { .kind = GENERIC, .name = "Pair" };
	if (name == "Triple") return { .kind = GENERIC, .name = "Triple" };
	if (name == "intArrayOf") return { .kind = SIMPLE, .name = "IntArray" };
	if (name == "longArrayOf") return { .kind = SIMPLE, .name = "LongArray" };
	if (name == "floatArrayOf") return { .kind = SIMPLE, .name = "FloatArray" };
	if (name == "doubleArrayOf") return { .kind = SIMPLE, .name = "DoubleArray" };
	if (name == "booleanArrayOf") return { .kind = SIMPLE, .name = "BooleanArray" };
	if (name == "charArrayOf") return { .kind = SIMPLE, .name = "CharArray" };
	if (name == "byteArrayOf") return { .kind = SIMPLE, .name = "ByteArray" };
	if (name == "shortArrayOf") return { .kind = SIMPLE, .name = "ShortArray" };
	if (name == "buildString" || name == "StringBuilder") return TYPE_STRING;
	if (name == "error" || name == "TODO") return TYPE_NOTHING;
	if (name == "require" || name == "check" || name == "assert") return TYPE_UNIT;
	if (name == "println" || name == "print") return TYPE_UNIT;

	return TYPE_UNKNOWN;
}

/**
 * Resolve a stdlib static factory call of the form `<ClassRef>.<method>(args)`.
 * Currently handles `Result.success(x) → Result<T>` and `Result.failure(e) → Result<T>`.
 *
 * Looks up the CALL_EXPR's DOT_EXPR child, checks the receiver is a class-ref
 * NAME_EXPR for "Result", then derives T from the first argument's type
 * (success: arg type; failure: explicit `Result.failure<T>(e)` requires
 * arg-type-independent T which we don't have without explicit type args, so
 * we return bare `Result` in that case).
 */
fn TypeRef resolve_static_factory_call(ParseResult* pr, TypeInfo* info, uint call_idx) {
	// Find DOT_EXPR child of CALL_EXPR
	uint dot_idx = ast::NO_PARENT;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != call_idx) continue;
		if (pr.nodes[j].kind == DOT_EXPR) { dot_idx = j; break; }
	}
	if (dot_idx == ast::NO_PARENT) return TYPE_UNKNOWN;

	AstNode* dot = &pr.nodes[dot_idx];
	String method = dot.name;

	// Find DOT_EXPR's receiver child
	uint recv_idx = ast::NO_PARENT;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == dot_idx) { recv_idx = j; break; }
	}
	if (recv_idx == ast::NO_PARENT) return TYPE_UNKNOWN;
	AstNode* recv = &pr.nodes[recv_idx];
	if (recv.kind != NAME_EXPR) return TYPE_UNKNOWN;

	// Result class-ref
	if (recv.name != "Result") return TYPE_UNKNOWN;

	TypeRef result = { .kind = GENERIC, .name = "Result" };
	if (method == "success") {
		// T = first arg type
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != call_idx) continue;
			if (child.kind != VALUE_ARGUMENT) continue;
			uint expr_idx = ast::get_arg_expr_idx(pr, j);
			if (expr_idx == uint.max) break;
			if (info.has_type[expr_idx]) {
				TypeRef arg = info.node_types[expr_idx];
				if (arg.kind != UNKNOWN && arg.name.len > 0) {
					result.type_arg_count = 1;
					result.type_arg_names[0] = arg.name;
					result.type_arg_nullable[0] = arg.nullable;
				}
			}
			break;
		}
		return result;
	}
	if (method == "failure") {
		// T not derivable from Throwable arg without explicit type-arg parsing;
		// return bare `Result` (callers can still use isFailure/exceptionOrNull).
		return result;
	}
	return TYPE_UNKNOWN;
}

// ── Lambda body type inference helpers ──────────────────────────────

/**
 * Find the trailing LAMBDA_EXPR sibling of a DOT_EXPR inside a CALL_EXPR.
 * Returns the type of the lambda's last expression (body return type).
 *
 * AST structure: CALL_EXPR → { DOT_EXPR, VALUE_ARGUMENT(trailing) → LAMBDA_EXPR }
 *   (older synthesized form may have a direct LAMBDA_EXPR child).
 */
fn TypeRef find_trailing_lambda_body_type(ParseResult* pr, TypeInfo* info, uint dot_idx) {
	uint parent = pr.nodes[dot_idx].parent;
	if (parent >= pr.node_count || pr.nodes[parent].kind != CALL_EXPR) return TYPE_UNKNOWN;

	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != parent) continue;
		// Direct lambda child (legacy synthesized form)
		if (pr.nodes[j].kind == LAMBDA_EXPR) {
			return last_expr_type_in(pr, info, j, true);
		}
		// Trailing lambda wrapped in VALUE_ARGUMENT(extra_text="trailing")
		if (pr.nodes[j].kind == VALUE_ARGUMENT && pr.nodes[j].extra_text == "trailing") {
			uint expr_idx = ast::get_arg_expr_idx(pr, j);
			if (expr_idx != uint.max && pr.nodes[expr_idx].kind == LAMBDA_EXPR) {
				return last_expr_type_in(pr, info, expr_idx, true);
			}
		}
	}
	return TYPE_UNKNOWN;
}

/**
 * For HOFs like map/flatMap/mapNotNull, infer the return collection type
 * from the trailing lambda's body type.
 */
fn TypeRef infer_hof_return_type(ParseResult* pr, TypeInfo* info, uint dot_idx,
		TypeRef receiver_type, String method_name) {
	TypeRef body_type = find_trailing_lambda_body_type(pr, info, dot_idx);
	if (body_type.kind == UNKNOWN) return TYPE_UNKNOWN;

	if (method_name == "map" || method_name == "mapNotNull") {
		TypeRef result = { .kind = GENERIC, .name = "List", .type_arg_count = 1 };
		result.type_arg_names[0] = body_type.name;
		result.type_arg_nullable[0] = method_name == "map" ? body_type.nullable : false;
		return result;
	}

	if (method_name == "flatMap") {
		if (body_type.kind == GENERIC && body_type.type_arg_count > 0) {
			TypeRef result = { .kind = GENERIC, .name = "List", .type_arg_count = 1 };
			result.type_arg_names[0] = body_type.type_arg_names[0];
			result.type_arg_nullable[0] = body_type.type_arg_nullable[0];
			return result;
		}
		return { .kind = GENERIC, .name = "List" };
	}

	if (method_name == "associate") {
		if (body_type.name == "Pair" && body_type.type_arg_count >= 2) {
			TypeRef result = { .kind = GENERIC, .name = "Map", .type_arg_count = 2 };
			result.type_arg_names[0] = body_type.type_arg_names[0];
			result.type_arg_names[1] = body_type.type_arg_names[1];
			result.type_arg_nullable[0] = body_type.type_arg_nullable[0];
			result.type_arg_nullable[1] = body_type.type_arg_nullable[1];
			return result;
		}
		return { .kind = GENERIC, .name = "Map" };
	}

	if (method_name == "associateWith") {
		TypeRef result = { .kind = GENERIC, .name = "Map" };
		if (receiver_type.type_arg_count > 0) {
			result.type_arg_count = 2;
			result.type_arg_names[0] = receiver_type.type_arg_names[0];
			result.type_arg_nullable[0] = receiver_type.type_arg_nullable[0];
			result.type_arg_names[1] = body_type.name;
			result.type_arg_nullable[1] = body_type.nullable;
		}
		return result;
	}

	if (method_name == "associateBy" || method_name == "groupBy") {
		TypeRef result = { .kind = GENERIC, .name = "Map" };
		if (body_type.kind != UNKNOWN) {
			result.type_arg_count = 2;
			result.type_arg_names[0] = body_type.name;
			result.type_arg_nullable[0] = body_type.nullable;
			if (method_name == "groupBy") {
				result.type_arg_names[1] = "List";
			} else if (receiver_type.type_arg_count > 0) {
				result.type_arg_names[1] = receiver_type.type_arg_names[0];
				result.type_arg_nullable[1] = receiver_type.type_arg_nullable[0];
			}
		}
		return result;
	}

	if (method_name == "mapKeys" && body_type.kind != UNKNOWN && receiver_type.type_arg_count >= 2) {
		TypeRef result = { .kind = GENERIC, .name = "Map", .type_arg_count = 2 };
		result.type_arg_names[0] = body_type.name;
		result.type_arg_nullable[0] = body_type.nullable;
		result.type_arg_names[1] = receiver_type.type_arg_names[1];
		result.type_arg_nullable[1] = receiver_type.type_arg_nullable[1];
		return result;
	}

	if (method_name == "mapValues" && body_type.kind != UNKNOWN && receiver_type.type_arg_count >= 2) {
		TypeRef result = { .kind = GENERIC, .name = "Map", .type_arg_count = 2 };
		result.type_arg_names[0] = receiver_type.type_arg_names[0];
		result.type_arg_nullable[0] = receiver_type.type_arg_nullable[0];
		result.type_arg_names[1] = body_type.name;
		result.type_arg_nullable[1] = body_type.nullable;
		return result;
	}

	return TYPE_UNKNOWN;
}

// ── Dot expression resolution ──────────────────────────────────────

fn TypeRef resolve_dot_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	if (node.name.len == 0) return TYPE_UNKNOWN;

	// Find receiver (first child)
	uint recv_idx = ast::NO_PARENT;
	TypeRef receiver_type = TYPE_UNKNOWN;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx) {
			recv_idx = j;
			if (info.has_type[j]) {
				receiver_type = info.node_types[j];
			}
			break;
		}
	}

	if (receiver_type.kind == UNKNOWN) return TYPE_UNKNOWN;

	// Compute the base member type via the existing dispatch chain.
	TypeRef base = resolve_dot_expr_member_type(pr, info, idx, node, receiver_type);
	if (base.kind == UNKNOWN) return base;

	// Flow-sensitive smart cast (member-property): if the receiver is a
	// bare NAME_EXPR (or THIS_EXPR) and a flow fact narrows `recv.member`,
	// apply it — but only when both receiver and member are stable.
	if (recv_idx != ast::NO_PARENT) {
		AstNode* rn = &pr.nodes[recv_idx];
		bool recv_simple = rn.kind == NAME_EXPR || rn.kind == THIS_EXPR;
		if (recv_simple) {
			String recv_name = rn.kind == THIS_EXPR ? "this" : rn.name;
			if (recv_name.len > 0) {
				flow::Fact* fact = lookup_smart_cast_fact(pr, info, idx, recv_name, node.name);
				if (fact != null && member_access_is_stable(pr, info, recv_idx, recv_name, receiver_type, node.name)) {
					if (fact.narrowed.kind != UNKNOWN) {
						return fact.narrowed;
					}
					if (fact.not_null && base.nullable) {
						base.nullable = false;
					}
				}
			}
		}
	}
	return base;
}

/**
 * Compute the member type of `recv.member` ignoring flow facts. Pulled
 * out of `resolve_dot_expr_type` so the entry point can wrap with the
 * smart-cast lookup + stability gate.
 */
fn TypeRef resolve_dot_expr_member_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node, TypeRef receiver_type) {
	// Try hardcoded stdlib member resolution first
	TypeRef result = resolve_member_type(receiver_type, node.name);
	if (result.kind != UNKNOWN) {
		// For HOFs that transform elements, try to infer return type from lambda body
		if (result.kind == GENERIC && result.type_arg_count == 0) {
			TypeRef lambda_result = infer_hof_return_type(pr, info, idx, receiver_type, node.name);
			if (lambda_result.kind != UNKNOWN) return lambda_result;
		}
		return result;
	}

	// Scope functions: let/run return lambda body type
	if (node.name == "let" || node.name == "run") {
		TypeRef lambda_body = find_trailing_lambda_body_type(pr, info, idx);
		if (lambda_body.kind != UNKNOWN) return lambda_body;
	}

	return lookup_member_anywhere(pr, info, receiver_type, node.name);
}

/**
 * Lookup a member on `receiver` across the standard cascade (excluding
 * stdlib + scope-fn shortcuts which are caller's job): in-file extension
 * → in-file class member → workspace member → dep member.
 *
 * Used by `resolve_dot_expr_member_type` and by operator-call resolvers
 * (binary/index/prefix/postfix/invoke) which need to find a user-defined
 * `operator fun plus`/`get`/`invoke`/etc. on a non-stdlib receiver.
 */
fn TypeRef lookup_member_anywhere(ParseResult* pr, TypeInfo* info, TypeRef receiver_type, String member_name) {
	// In-file extension function resolution
	TypeRef ext_result = resolve_in_file_extension(pr, info, receiver_type, member_name);
	if (ext_result.kind != UNKNOWN) return ext_result;

	// In-file class member resolution
	TypeRef in_file_result = resolve_in_file_member(pr, receiver_type, member_name);
	if (in_file_result.kind != UNKNOWN) return in_file_result;

	// Cross-file: look up member from workspace member_cache
	if (g_workspace != null) {
		TypeRef ws = resolve_workspace_member_type(receiver_type, member_name);
		if (ws.kind != UNKNOWN) return ws;

		// Dependency index: look up member by receiver type name
		if (g_workspace.dep_index.initialized) {
			TypeRef dep = resolve_dep_member_type(&g_workspace.dep_index, receiver_type, member_name, pr);
			if (dep.kind != UNKNOWN) return dep;
		}
	}

	return TYPE_UNKNOWN;
}

/**
 * Map a binary operator symbol to its Kotlin operator-fun method name
 * per the language spec (§9.6 Operator overloading). Returns "" for
 * operators that don't map to a method (||, &&, ===, etc. — handled by
 * the compiler directly) or that are already short-circuited by the
 * caller (==, <, etc. which always return Boolean).
 */
fn String binary_op_method(String op) {
	if (op == "+") return "plus";
	if (op == "-") return "minus";
	if (op == "*") return "times";
	if (op == "/") return "div";
	if (op == "%") return "rem";
	if (op == "..") return "rangeTo";
	if (op == "..<") return "rangeUntil";
	if (op == "in" || op == "!in") return "contains";  // receiver = RHS, result = Boolean
	return "";
}

/**
 * Map a unary operator symbol to its Kotlin operator-fun method name.
 * `prefix` distinguishes `+a`/`-a` (unaryPlus/unaryMinus) from
 * binary `a+b`/`a-b` (plus/minus).
 */
fn String unary_op_method(String op) {
	if (op == "+") return "unaryPlus";
	if (op == "-") return "unaryMinus";
	if (op == "!") return "not";
	if (op == "++") return "inc";
	if (op == "--") return "dec";
	return "";
}

/**
 * Stability gate for a member access `recv.member`. Both halves must be
 * stable for the smart cast to apply.
 *
 * Receiver stability: walk the receiver's NAME_EXPR scope chain to find
 * its declaration, apply the existing single-decl gate. THIS_EXPR is
 * always stable (this-reference can't be reassigned).
 *
 * Member stability: prefer the in-file class member if we can find it,
 * apply the existing gate. Cross-file members are conservatively
 * assumed unstable (no direct access to workspace decl AST here).
 */
fn bool member_access_is_stable(ParseResult* pr, TypeInfo* info, uint recv_idx, String recv_name,
		TypeRef receiver_type, String member_name) {
	if (recv_idx >= pr.node_count) return false;

	// Receiver side
	AstNode* rn = &pr.nodes[recv_idx];
	if (rn.kind != THIS_EXPR) {
		uint recv_decl = find_decl_in_scope_chain(pr, recv_idx, recv_name);
		if (recv_decl == ast::NO_PARENT) return false;
		if (!is_stable_for_smart_cast(pr, info, recv_decl, recv_idx)) return false;
	}

	// Member side: locate the in-file class declaration and apply the
	// gate to the member decl. If we can't find an in-file class for the
	// receiver type, the member must be cross-file → conservative deny.
	uint member_decl = ast::NO_PARENT;
	resolve_in_file_member(pr, receiver_type, member_name, &member_decl);
	if (member_decl == ast::NO_PARENT) return false;
	return is_stable_for_smart_cast(pr, info, member_decl, recv_idx);
}

/**
 * Find a binding for `name` reachable from `use_idx`'s scope chain.
 * Returns the AST decl idx, or ast::NO_PARENT if unresolved.
 */
fn uint find_decl_in_scope_chain(ParseResult* pr, uint use_idx, String name) {
	uint scope_idx = find_innermost_scope(pr, use_idx);
	uint current = scope_idx;
	while (true) {
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* candidate = &pr.nodes[j];
			if (candidate.parent != current) continue;
			if (!is_typed_declaration(candidate.kind)) continue;
			if (candidate.name != name) continue;
			return j;
		}
		// Also look inside destructuring-wrapper PROPERTY_DECLs at this scope:
		// `val (a, b) = expr` produces a PROPERTY_DECL named "(destructuring)"
		// whose PROPERTY_DECL children are the destructured bindings. Their
		// parent is the wrapper, not the enclosing BLOCK, so the direct-child
		// scan above misses them. (Kotlin spec §11.7)
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* wrapper = &pr.nodes[j];
			if (wrapper.parent != current) continue;
			if (wrapper.kind != PROPERTY_DECL || wrapper.name != "(destructuring)") continue;
			for (uint k = 0; k < pr.node_count; k++) {
				AstNode* inner = &pr.nodes[k];
				if (inner.parent != j) continue;
				if (inner.kind != PROPERTY_DECL) continue;
				if (inner.name == name) return k;
			}
		}
		AstNode* scope = &pr.nodes[current];
		if (current == 0 || scope.parent == ast::NO_PARENT) break;
		current = scope.parent;
	}
	return ast::NO_PARENT;
}

// ── In-file extension function resolution ──────────────────────────

/**
 * Look for extension functions/properties in the current file's AST.
 * Matches `fun ReceiverType.name(): ReturnType` declarations.
 */
fn TypeRef resolve_in_file_extension(ParseResult* pr, TypeInfo* info, TypeRef receiver, String member_name) {
	String recv_name = receiver.name;
	if (recv_name.len == 0) return TYPE_UNKNOWN;

	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* node = &pr.nodes[j];
		if (node.kind != FUN_DECL && node.kind != PROPERTY_DECL) continue;
		if (node.name != member_name) continue;
		if (node.extra_text.len == 0) continue;  // not an extension

		// Match receiver type: extract simple name from extra_text
		String ext_recv = node.extra_text;
		usz end = 0;
		while (end < ext_recv.len && ext_recv[end] != '<' && ext_recv[end] != '?' && ext_recv[end] != '.') {
			end++;
		}
		if (end == 0) continue;
		if (ext_recv[:end] != recv_name) continue;

		// Found matching extension
		if (node.type_text.len > 0) {
			return parse_type_text(node.type_text);
		}
		if (node.kind == FUN_DECL) return TYPE_UNIT;
		return TYPE_UNKNOWN;
	}
	return TYPE_UNKNOWN;
}

// ── In-file class member resolution ────────────────────────────────

/**
 * Look for a property/function/primary-ctor-val-or-var member named `member_name`
 * inside a CLASS_DECL/INTERFACE_DECL/OBJECT_DECL named `receiver.name` in the
 * current file's AST.
 *
 * Handles three declaration shapes:
 *  - PROPERTY_DECL child         (val/var x: T)
 *  - FUN_DECL child              (fun f(): T)
 *  - PARAM child with MOD_FINAL  (primary-ctor `val x: T`)
 *  - PARAM child with MOD_VAR    (primary-ctor `var x: T`)
 *
 * Returns TYPE_UNKNOWN if no match. Does not walk supertypes (workspace path
 * handles that for cross-file; in-file supertype walk falls through to the
 * workspace path which already handles the current file when indexed).
 *
 * If `out_decl_idx` is non-null, sets it to the matched declaration's AST
 * index (for downstream stability-gate checks). Set to ast::NO_PARENT on miss.
 */
fn TypeRef resolve_in_file_member(ParseResult* pr, TypeRef receiver, String member_name, uint* out_decl_idx = null) {
	if (out_decl_idx != null) *out_decl_idx = ast::NO_PARENT;
	String recv_name = receiver.name;
	if (recv_name.len == 0 || member_name.len == 0) return TYPE_UNKNOWN;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* cls = &pr.nodes[i];
		if (cls.kind != CLASS_DECL && cls.kind != INTERFACE_DECL && cls.kind != OBJECT_DECL) continue;
		if (cls.name != recv_name) continue;

		// Scan direct children for matching member
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != i) continue;
			AstNode* child = &pr.nodes[j];
			if (child.name != member_name) continue;

			switch (child.kind) {
				case PROPERTY_DECL:
				case FUN_DECL:
					if (out_decl_idx != null) *out_decl_idx = j;
					if (child.type_text.len > 0) {
						TypeRef declared = parse_type_text(child.type_text);
						return substitute_class_type_params(pr, i, receiver, declared);
					}
					if (child.kind == FUN_DECL) return TYPE_UNIT;
					return TYPE_UNKNOWN;
				case PARAM:
					// Primary-ctor val/var only — plain params aren't members
					uint mods = child.mod_flags;
					if ((mods & ast::MOD_FINAL) == 0 && (mods & ast::MOD_VAR) == 0) continue;
					if (out_decl_idx != null) *out_decl_idx = j;
					if (child.type_text.len > 0) {
						TypeRef declared = parse_type_text(child.type_text);
						return substitute_class_type_params(pr, i, receiver, declared);
					}
					return TYPE_UNKNOWN;
				default:
					continue;
			}
		}

		// Companion-object members: `Foo.member` resolves to `Foo.Companion.member`
		// (Kotlin spec §11.4.4 companion-object access). Walk OBJECT_DECL children
		// of this class with MOD_COMPANION (or named "Companion") and search them.
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != i) continue;
			AstNode* comp = &pr.nodes[j];
			if (comp.kind != OBJECT_DECL) continue;
			bool is_companion = (comp.mod_flags & ast::MOD_COMPANION) != 0
				|| comp.name == "Companion" || comp.name.len == 0;
			if (!is_companion) continue;
			for (uint k = 0; k < pr.node_count; k++) {
				if (pr.nodes[k].parent != j) continue;
				AstNode* m = &pr.nodes[k];
				if (m.name != member_name) continue;
				if (m.kind != PROPERTY_DECL && m.kind != FUN_DECL) continue;
				if (out_decl_idx != null) *out_decl_idx = k;
				if (m.type_text.len > 0) return parse_type_text(m.type_text);
				if (m.kind == FUN_DECL) {
					// Companion factory `fun new(...): Foo` may have implicit
					// return type matching the enclosing class — return class-ref
					// of the enclosing class as a heuristic when type_text empty.
					return { .kind = SIMPLE, .name = recv_name };
				}
				return TYPE_UNKNOWN;
			}
		}
	}
	return TYPE_UNKNOWN;
}

/**
 * Substitute class type-parameters in a member's declared type using the
 * receiver's bound type-arguments (Kotlin spec §11.1.7 propagation through
 * member access). For `class Box<T>(val v: T) { fun get(): T }`, given a
 * receiver `Box<Int>`, substitutes T → Int in the member's return type.
 *
 * Mirrors substitute_user_type_params but binds from the receiver's
 * type_arg_names[] rather than from call-arg positions.
 */
fn TypeRef substitute_class_type_params(ParseResult* pr, uint class_decl_idx,
		TypeRef receiver, TypeRef declared) {
	const usz MAX_TP = 4;
	String[MAX_TP] tp_names;
	usz tp_count = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		AstNode* child = &pr.nodes[j];
		if (child.parent != class_decl_idx) continue;
		if (child.kind != TYPE_PARAM) continue;
		if (tp_count >= MAX_TP) break;
		tp_names[tp_count++] = child.name;
	}
	if (tp_count == 0) return declared;

	TypeRef out = declared;
	for (usz t = 0; t < tp_count && t < receiver.type_arg_count; t++) {
		String binding = receiver.type_arg_names[t];
		bool binding_nullable = receiver.type_arg_nullable[t];
		// Skip if receiver still carries unbound TP placeholder identical to TP name
		if (binding == tp_names[t]) continue;
		if (binding.len == 0) continue;
		if (out.name == tp_names[t]) {
			out.name = binding;
			if (binding_nullable) out.nullable = true;
		}
		for (uint a = 0; a < out.type_arg_count; a++) {
			if (out.type_arg_names[a] == tp_names[t]) {
				out.type_arg_names[a] = binding;
				if (binding_nullable) out.type_arg_nullable[a] = true;
			}
		}
	}
	return out;
}

// ── Generic type argument propagation helpers ──────────────────────

/**
 * Extract the element type from a generic collection receiver.
 * For List<String>.first() -> String, List<String>.firstOrNull() -> String?
 * Falls back to UNKNOWN if receiver has no type arguments.
 */
fn TypeRef extract_element_type(TypeRef receiver, bool nullable) {
	if (receiver.type_arg_count > 0) {
		TypeRef result = { .kind = SIMPLE, .name = receiver.type_arg_names[0] };
		result.nullable = nullable || receiver.type_arg_nullable[0];
		return result;
	}
	return TYPE_UNKNOWN;
}

/**
 * Create a generic type with the receiver's type arguments preserved.
 * For List<String>.filter(...) -> List<String> (not bare List).
 */
fn TypeRef make_generic_with_receiver_args(String container_name, TypeRef receiver) {
	TypeRef result = { .kind = GENERIC, .name = container_name };
	if (receiver.type_arg_count > 0) {
		result.type_arg_count = 1;
		result.type_arg_names[0] = receiver.type_arg_names[0];
		result.type_arg_nullable[0] = receiver.type_arg_nullable[0];
	}
	return result;
}

/**
 * Extract Map's key type as Set<K>.
 * For Map<String, Int>.keys -> Set<String>.
 */
fn TypeRef extract_map_key_as_set(TypeRef receiver) {
	TypeRef result = { .kind = GENERIC, .name = "Set" };
	if (receiver.type_arg_count > 0) {
		result.type_arg_count = 1;
		result.type_arg_names[0] = receiver.type_arg_names[0];
		result.type_arg_nullable[0] = receiver.type_arg_nullable[0];
	}
	return result;
}

/**
 * Extract Map's value type as Collection<V>.
 * For Map<String, Int>.values -> Collection<Int>.
 */
fn TypeRef extract_map_value_as_collection(TypeRef receiver) {
	TypeRef result = { .kind = GENERIC, .name = "Collection" };
	if (receiver.type_arg_count > 1) {
		result.type_arg_count = 1;
		result.type_arg_names[0] = receiver.type_arg_names[1];
		result.type_arg_nullable[0] = receiver.type_arg_nullable[1];
	}
	return result;
}

/**
 * Extract Map's value type V (or V? if nullable).
 * For Map<String, Int>.get("key") -> Int?
 * For Map<String, Int>.getValue("key") -> Int
 */
fn TypeRef extract_map_value_type(TypeRef receiver, bool nullable) {
	if (receiver.type_arg_count > 1) {
		TypeRef result = { .kind = SIMPLE, .name = receiver.type_arg_names[1] };
		result.nullable = nullable || receiver.type_arg_nullable[1];
		return result;
	}
	return TYPE_UNKNOWN;
}

/**
 * Create a Map type preserving the receiver's K, V type arguments.
 * For Map<String, Int>.filter(...) -> Map<String, Int>.
 */
fn TypeRef make_map_with_receiver_args(TypeRef receiver) {
	TypeRef result = { .kind = GENERIC, .name = "Map" };
	if (receiver.type_arg_count >= 2) {
		result.type_arg_count = 2;
		result.type_arg_names[0] = receiver.type_arg_names[0];
		result.type_arg_names[1] = receiver.type_arg_names[1];
		result.type_arg_nullable[0] = receiver.type_arg_nullable[0];
		result.type_arg_nullable[1] = receiver.type_arg_nullable[1];
	}
	return result;
}

/**
 * Resolve the type of a member access on a known type.
 */
fn TypeRef resolve_member_type(TypeRef receiver, String member_name) {
	String type_name = receiver.name;

	// String members
	if (type_name == "String") {
		if (member_name == "length") return TYPE_INT;
		if (member_name == "isEmpty" || member_name == "isNotEmpty" ||
		    member_name == "isBlank" || member_name == "isNotBlank" ||
		    member_name == "startsWith" || member_name == "endsWith" ||
		    member_name == "contains" || member_name == "matches" ||
		    member_name == "any" || member_name == "all" || member_name == "none") {
			return TYPE_BOOLEAN;
		}
		if (member_name == "first" || member_name == "last" || member_name == "get") {
			return TYPE_CHAR;
		}
		if (member_name == "trim" || member_name == "trimStart" || member_name == "trimEnd" ||
		    member_name == "lowercase" || member_name == "uppercase" ||
		    member_name == "reversed" || member_name == "replace" ||
		    member_name == "removePrefix" || member_name == "removeSuffix" ||
		    member_name == "substring" || member_name == "take" || member_name == "takeLast" ||
		    member_name == "drop" || member_name == "dropLast" || member_name == "repeat" ||
		    member_name == "padStart" || member_name == "padEnd" || member_name == "plus" ||
		    member_name == "toString") {
			return TYPE_STRING;
		}
		if (member_name == "indexOf" || member_name == "lastIndexOf" ||
		    member_name == "compareTo" || member_name == "hashCode" || member_name == "count") {
			return TYPE_INT;
		}
		if (member_name == "toInt") return TYPE_INT;
		if (member_name == "toLong") return TYPE_LONG;
		if (member_name == "toFloat") return TYPE_FLOAT;
		if (member_name == "toDouble") return TYPE_DOUBLE;
		if (member_name == "toBoolean") return TYPE_BOOLEAN;
		if (member_name == "split" || member_name == "lines") {
			return { .kind = GENERIC, .name = "List", .type_arg_count = 1, .type_arg_names = { [0] = "String" } };
		}
		if (member_name == "toList") {
			return { .kind = GENERIC, .name = "List", .type_arg_count = 1, .type_arg_names = { [0] = "Char" } };
		}
		if (member_name == "toRegex") return { .kind = SIMPLE, .name = "Regex" };
		if (member_name == "toByteArray") return { .kind = SIMPLE, .name = "ByteArray" };
		if (member_name == "toCharArray") return { .kind = SIMPLE, .name = "CharArray" };
	}

	// Numeric type members
	if (type_name == "Int" || type_name == "Long" || type_name == "Float" ||
	    type_name == "Double" || type_name == "Short" || type_name == "Byte") {
		if (member_name == "toInt") return TYPE_INT;
		if (member_name == "toLong") return TYPE_LONG;
		if (member_name == "toFloat") return TYPE_FLOAT;
		if (member_name == "toDouble") return TYPE_DOUBLE;
		if (member_name == "toByte") return TYPE_BYTE;
		if (member_name == "toShort") return TYPE_SHORT;
		if (member_name == "toChar") return TYPE_CHAR;
		if (member_name == "toString") return TYPE_STRING;
		if (member_name == "compareTo" || member_name == "hashCode") return TYPE_INT;
		if (member_name == "equals") return TYPE_BOOLEAN;
		if (member_name == "plus" || member_name == "minus" || member_name == "times" ||
		    member_name == "div" || member_name == "rem" || member_name == "inc" ||
		    member_name == "dec" || member_name == "unaryMinus" || member_name == "unaryPlus" ||
		    member_name == "coerceIn" || member_name == "coerceAtLeast" || member_name == "coerceAtMost") {
			return { .kind = SIMPLE, .name = type_name };
		}
		if (member_name == "rangeTo") return { .kind = SIMPLE, .name = "IntRange" };
	}

	// Boolean members
	if (type_name == "Boolean") {
		if (member_name == "and" || member_name == "or" || member_name == "xor" || member_name == "not") {
			return TYPE_BOOLEAN;
		}
		if (member_name == "compareTo") return TYPE_INT;
		if (member_name == "toString") return TYPE_STRING;
		if (member_name == "equals") return TYPE_BOOLEAN;
	}

	// Collection members
	if (type_name == "List" || type_name == "Set" || type_name == "Collection" ||
	    type_name == "MutableList" || type_name == "MutableSet" || type_name == "MutableCollection" ||
	    type_name == "Iterable" || type_name == "Sequence") {
		if (member_name == "size" || member_name == "count" ||
		    member_name == "indexOf" || member_name == "lastIndexOf") return TYPE_INT;
		if (member_name == "isEmpty" || member_name == "isNotEmpty" ||
		    member_name == "any" || member_name == "all" || member_name == "none" ||
		    member_name == "contains" || member_name == "containsAll") {
			return TYPE_BOOLEAN;
		}
		if (member_name == "joinToString" || member_name == "toString") return TYPE_STRING;
		if (member_name == "hashCode") return TYPE_INT;
		if (member_name == "equals") return TYPE_BOOLEAN;

		// Members that return the element type T
		if (member_name == "first" || member_name == "last" ||
		    member_name == "single" || member_name == "get" ||
		    member_name == "elementAt" || member_name == "random" ||
		    member_name == "reduce" || member_name == "min" || member_name == "max" ||
		    member_name == "minOrNull" || member_name == "maxOrNull" ||
		    member_name == "sum") {
			return extract_element_type(receiver, false);
		}
		if (member_name == "firstOrNull" || member_name == "lastOrNull" ||
		    member_name == "singleOrNull" || member_name == "getOrNull" ||
		    member_name == "elementAtOrNull" || member_name == "randomOrNull" ||
		    member_name == "find" || member_name == "findLast" ||
		    member_name == "reduceOrNull" || member_name == "maxByOrNull" ||
		    member_name == "minByOrNull") {
			return extract_element_type(receiver, true);
		}

		// Members that return the same collection type with preserved type args
		if (member_name == "filter" || member_name == "filterNot" || member_name == "filterNotNull" ||
		    member_name == "sorted" || member_name == "sortedDescending" ||
		    member_name == "sortedBy" || member_name == "sortedByDescending" ||
		    member_name == "reversed" || member_name == "shuffled" ||
		    member_name == "distinct" || member_name == "take" || member_name == "drop" ||
		    member_name == "flatten" || member_name == "toList" || member_name == "toMutableList" ||
		    member_name == "zip") {
			return make_generic_with_receiver_args("List", receiver);
		}
		if (member_name == "map" || member_name == "flatMap" || member_name == "mapNotNull") {
			// map/flatMap transform the element type — we can't know the result type
			// without analyzing the lambda, so return bare List
			return { .kind = GENERIC, .name = "List" };
		}
		if (member_name == "toSet" || member_name == "toMutableSet") {
			return make_generic_with_receiver_args("Set", receiver);
		}
		if (member_name == "associate" || member_name == "associateBy" ||
		    member_name == "associateWith" || member_name == "groupBy") {
			return { .kind = GENERIC, .name = "Map" };
		}
		if (member_name == "asSequence") {
			return make_generic_with_receiver_args("Sequence", receiver);
		}
		if (member_name == "iterator") {
			return make_generic_with_receiver_args("Iterator", receiver);
		}
	}

	// Result members (Kotlin spec stdlib: kotlin.Result<T>)
	if (type_name == "Result") {
		if (member_name == "isSuccess" || member_name == "isFailure") return TYPE_BOOLEAN;
		if (member_name == "getOrNull") {
			return extract_element_type(receiver, true);  // T?
		}
		if (member_name == "getOrThrow" || member_name == "getOrDefault") {
			return extract_element_type(receiver, false); // T
		}
		if (member_name == "exceptionOrNull") {
			return { .kind = SIMPLE, .name = "Throwable", .nullable = true };
		}
		if (member_name == "getOrElse") {
			return extract_element_type(receiver, false); // T (from default fn)
		}
		if (member_name == "fold" || member_name == "recover" || member_name == "recoverCatching") {
			// fold transforms via two lambdas; return type unknown without analysis
			return TYPE_UNKNOWN;
		}
		if (member_name == "map" || member_name == "mapCatching") {
			// transforms T → R; return bare Result (R inferred elsewhere)
			return { .kind = GENERIC, .name = "Result" };
		}
		if (member_name == "onSuccess" || member_name == "onFailure") {
			return receiver;  // returns this Result<T> for chaining
		}
		if (member_name == "toString") return TYPE_STRING;
		if (member_name == "hashCode") return TYPE_INT;
		if (member_name == "equals") return TYPE_BOOLEAN;
	}

	// Map members
	if (type_name == "Map" || type_name == "MutableMap" || type_name == "HashMap" || type_name == "LinkedHashMap") {
		if (member_name == "size" || member_name == "count") return TYPE_INT;
		if (member_name == "isEmpty" || member_name == "isNotEmpty" ||
		    member_name == "containsKey" || member_name == "containsValue" ||
		    member_name == "any" || member_name == "all" || member_name == "none") {
			return TYPE_BOOLEAN;
		}
		if (member_name == "keys") {
			return extract_map_key_as_set(receiver);
		}
		if (member_name == "values") {
			return extract_map_value_as_collection(receiver);
		}
		if (member_name == "entries") return { .kind = GENERIC, .name = "Set" };
		if (member_name == "get" || member_name == "getOrDefault" || member_name == "remove") {
			return extract_map_value_type(receiver, true);
		}
		if (member_name == "getValue" || member_name == "getOrPut") {
			return extract_map_value_type(receiver, false);
		}
		if (member_name == "toList") return { .kind = GENERIC, .name = "List" };
		if (member_name == "filter" || member_name == "filterKeys" || member_name == "filterValues" ||
		    member_name == "toMutableMap") {
			return make_map_with_receiver_args(receiver);
		}
		if (member_name == "map" || member_name == "mapKeys" || member_name == "mapValues") {
			return { .kind = GENERIC, .name = "Map" };
		}
		if (member_name == "toString") return TYPE_STRING;
		if (member_name == "hashCode") return TYPE_INT;
		if (member_name == "equals") return TYPE_BOOLEAN;
	}

	// Any members (available on all types)
	if (member_name == "toString") return TYPE_STRING;
	if (member_name == "hashCode") return TYPE_INT;
	if (member_name == "equals") return TYPE_BOOLEAN;

	// Scope functions: also/apply return receiver type
	if (member_name == "also" || member_name == "apply") {
		return receiver;
	}

	return TYPE_UNKNOWN;
}

/**
 * Resolve a member type through inheritance. When the receiver type is not
 * a hardcoded type, check its supertypes (if provided) against the member
 * table. This allows types that extend stdlib types (e.g., class StringList : List<String>)
 * to resolve inherited member types.
 *
 * supertypes: array of supertype name strings
 * count: number of supertypes
 */
fn TypeRef resolve_member_type_with_supertypes(TypeRef receiver, String member_name,
		String[] supertypes, usz count) {
	// Try direct first
	TypeRef direct = resolve_member_type(receiver, member_name);
	if (direct.kind != UNKNOWN) return direct;

	// Try supertypes
	for (usz i = 0; i < count; i++) {
		String st = supertypes[i];
		if (st.len == 0) continue;

		// Build a TypeRef for the supertype
		TypeRef super_ref = { .kind = SIMPLE, .name = st };

		// If receiver has generic type args, propagate them to the supertype
		// This handles cases like: class StringList : List<String>
		// where receiver has type_arg_count > 0 from the class declaration
		if (receiver.kind == GENERIC && receiver.type_arg_count > 0) {
			super_ref.kind = GENERIC;
			super_ref.type_arg_count = receiver.type_arg_count;
			for (usz j = 0; j < receiver.type_arg_count && j < MAX_TYPE_ARGS; j++) {
				super_ref.type_arg_names[j] = receiver.type_arg_names[j];
				super_ref.type_arg_nullable[j] = receiver.type_arg_nullable[j];
			}
		}

		TypeRef result = resolve_member_type(super_ref, member_name);
		if (result.kind != UNKNOWN) return result;
	}

	return TYPE_UNKNOWN;
}

/**
 * Resolve a member type from the workspace member cache.
 * Looks up the receiver type name in the member cache and finds
 * a matching member declaration, returning its type_text as a TypeRef.
 * Also checks supertypes of the receiver class.
 */
fn TypeRef resolve_workspace_member_type(TypeRef receiver, String member_name) {
	if (g_workspace == null) return TYPE_UNKNOWN;
	String type_name = receiver.name;
	if (type_name.len == 0) return TYPE_UNKNOWN;

	// Direct lookup in member cache
	if (try members = g_workspace.member_cache.get_ref(type_name)) {
		for (usz i = 0; i < members.len(); i++) {
			MemberDecl* m = &(*members)[i];
			if (m.name == member_name) {
				if (m.type_text.len > 0) {
					return parse_type_text(m.type_text);
				}
				// Function with no explicit return type — assume Unit
				if (m.node_kind == FUN_DECL) return TYPE_UNIT;
				return TYPE_UNKNOWN;
			}
		}
	}

	// Walk supertype chain transitively (up to 32 levels to prevent cycles)
	String[32] queue;
	usz queue_len = 0;
	String[32] visited;
	usz visited_len = 0;

	// Seed queue with direct supertypes
	if (try indices = g_workspace.lookup_by_name(type_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = g_workspace.get_symbol((*indices)[i]);
			for (usz s = 0; s < sym.supertype_count && queue_len < 32; s++) {
				if (sym.supertypes[s].len > 0) {
					queue[queue_len++] = sym.supertypes[s];
				}
			}
		}
	}

	while (queue_len > 0 && visited_len < 32) {
		String st = queue[0];
		for (usz i = 1; i < queue_len; i++) queue[i-1] = queue[i];
		queue_len--;

		bool already = false;
		for (usz i = 0; i < visited_len; i++) {
			if (visited[i] == st) { already = true; break; }
		}
		if (already) continue;
		visited[visited_len++] = st;

		TypeRef super_ref = { .kind = SIMPLE, .name = st };
		TypeRef result = resolve_member_type(super_ref, member_name);
		if (result.kind != UNKNOWN) return result;

		if (try super_members = g_workspace.member_cache.get_ref(st)) {
			for (usz j = 0; j < super_members.len(); j++) {
				MemberDecl* m = &(*super_members)[j];
				if (m.name == member_name) {
					if (m.type_text.len > 0) return parse_type_text(m.type_text);
					if (m.node_kind == FUN_DECL) return TYPE_UNIT;
					return TYPE_UNKNOWN;
				}
			}
		}

		if (try indices = g_workspace.lookup_by_name(st)) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = g_workspace.get_symbol((*indices)[i]);
				for (usz s = 0; s < sym.supertype_count && queue_len < 32; s++) {
					if (sym.supertypes[s].len > 0) {
						queue[queue_len++] = sym.supertypes[s];
					}
				}
			}
		}
	}

	return TYPE_UNKNOWN;
}

/**
 * Resolve member type from the dependency index (JARs/JDK).
 * Looks up the member by class_name and extracts the return type from the signature.
 * E.g., for Record.timestamp() with signature "(): Long", returns TypeRef{Long}.
 */
fn TypeRef resolve_dep_member_type(DependencyIndex* dep_index, TypeRef receiver, String member_name, ParseResult* pr = null) {
	String type_name = receiver.name;
	if (type_name.len == 0) return TYPE_UNKNOWN;

	// Check cache for pre-substitution result
	char[DEP_CACHE_KEY_MAX] key_buf;
	usz key_len = 0;
	if (type_name.len + 1 + member_name.len < DEP_CACHE_KEY_MAX) {
		for (usz i = 0; i < type_name.len; i++) key_buf[i] = type_name[i];
		key_buf[type_name.len] = 0;
		for (usz i = 0; i < member_name.len; i++) key_buf[type_name.len + 1 + i] = member_name[i];
		key_len = type_name.len + 1 + member_name.len;
	}
	if (key_len > 0) {
		// Hash-based lookup into flat cache
		uint hash = cache_hash(key_buf[:key_len]);
		usz slot = (usz)hash % DEP_CACHE_SIZE;
		if (g_dep_member_cache[slot].occupied && g_dep_member_cache[slot].key_len == key_len) {
			bool match = true;
			for (usz i = 0; i < key_len; i++) {
				if (g_dep_member_cache[slot].key[i] != key_buf[i]) { match = false; break; }
			}
			if (match) return substitute_type_params(g_dep_member_cache[slot].value, receiver);
		}
	}

	// Use imports to prefer correct package when multiple classes share the same name
	String preferred_pkg = "";
	if (pr != null) {
		ImportMap imports = workspace::build_import_map(pr);
		for (usz i = 0; i < imports.import_count; i++) {
			if (imports.import_names[i] == type_name && !imports.is_star[i]) {
				String path = imports.import_paths[i];
				usz last_dot = 0;
				for (usz j = 0; j < path.len; j++) {
					if (path[j] == '.') last_dot = j;
				}
				if (last_dot > 0) preferred_pkg = path[:last_dot];
				break;
			}
		}
	}

	// Verify the class exists in deps, prefer imported package
	DepSymbol*[16] class_matches;
	usz class_count = dep_index.lookup_by_name(type_name, &class_matches);
	DepSymbol* best_class = null;
	for (usz i = 0; i < class_count; i++) {
		if (class_matches[i].kind != DEP_CLASS && class_matches[i].kind != DEP_INTERFACE &&
			class_matches[i].kind != DEP_ENUM && class_matches[i].kind != DEP_OBJECT) continue;
		if (preferred_pkg.len > 0 && class_matches[i].package_name == preferred_pkg) {
			best_class = class_matches[i];
			break;
		}
		if (best_class == null) best_class = class_matches[i];
	}
	if (best_class == null) return TYPE_UNKNOWN;

	String target_pkg = best_class.package_name;

	// Look up the member, filter by class name and prefer matching package
	DepSymbol*[32] member_matches;
	usz member_count = dep_index.lookup_by_name(member_name, &member_matches);

	DepSymbol* best = null;
	for (usz i = 0; i < member_count; i++) {
		if (member_matches[i].class_name != type_name) continue;
		if (member_matches[i].kind != DEP_METHOD && member_matches[i].kind != DEP_FIELD) continue;
		if (target_pkg.len > 0 && member_matches[i].package_name == target_pkg) {
			best = member_matches[i];
			break;
		}
		if (best == null) best = member_matches[i];
	}

	if (best == null) {
		// Walk supertypes to find inherited/extension members
		if (best_class != null) {
			for (usz s = 0; s < jar_index::MAX_DEP_SUPERTYPES; s++) {
				if (best_class.supertypes[s].len == 0) break;
				TypeRef super_result = resolve_dep_member_in_class(dep_index, best_class.supertypes[s], member_name);
				if (super_result.kind != UNKNOWN) {
					cache_dep_member_type(&key_buf, key_len, super_result);
					return substitute_type_params(super_result, receiver);
				}
			}
		}
		return TYPE_UNKNOWN;
	}

	TypeRef result = extract_dep_return_type(best);
	cache_dep_member_type(&key_buf, key_len, result);
	return substitute_type_params(result, receiver);
}

/**
 * Store a pre-substitution TypeRef in the dep member cache.
 */
fn void cache_dep_member_type(char[] key, usz key_len, TypeRef value) {
	if (key_len == 0 || key_len >= DEP_CACHE_KEY_MAX) return;
	uint hash = cache_hash(key[:key_len]);
	usz slot = (usz)hash % DEP_CACHE_SIZE;
	for (usz i = 0; i < key_len; i++) g_dep_member_cache[slot].key[i] = key[i];
	g_dep_member_cache[slot].key_len = key_len;
	g_dep_member_cache[slot].value = value;
	g_dep_member_cache[slot].occupied = true;
}

/**
 * Simple FNV-1a hash for cache keys.
 */
fn uint cache_hash(char[] data) {
	uint h = 0x811c9dc5;
	for (usz i = 0; i < data.len; i++) {
		h ^= (uint)data[i];
		h *= 0x01000193;
	}
	return h;
}

/**
 * Substitute type parameter placeholders (T0, T1, ...) with concrete
 * type arguments from a generic receiver type.
 * E.g., receiver = List<String>, result = T0 → String
 */
fn TypeRef substitute_type_params(TypeRef result, TypeRef receiver) {
	if (receiver.kind != GENERIC || receiver.type_arg_count == 0) return result;

	// Direct type parameter: T0, T1, etc.
	if (result.kind == SIMPLE && is_type_param_placeholder(result.name)) {
		int idx = parse_type_param_index(result.name);
		if (idx >= 0 && (usz)idx < receiver.type_arg_count) {
			String arg_name = receiver.type_arg_names[idx];
			if (arg_name.len > 0 && arg_name != "*") {
				TypeRef subst = parse_type_text(arg_name);
				if (result.nullable && !subst.nullable) subst.nullable = true;
				return subst;
			}
		}
	}

	// Generic result with type param args: e.g., Map<T0, T1> with receiver Map<String, Int>
	if (result.kind == GENERIC && result.type_arg_count > 0) {
		for (usz i = 0; i < result.type_arg_count; i++) {
			if (is_type_param_placeholder(result.type_arg_names[i])) {
				int idx = parse_type_param_index(result.type_arg_names[i]);
				if (idx >= 0 && (usz)idx < receiver.type_arg_count) {
					String arg = receiver.type_arg_names[idx];
					if (arg.len > 0 && arg != "*") {
						result.type_arg_names[i] = arg;
					}
				}
			}
		}
	}

	return result;
}

/**
 * Check if a type name is a type parameter placeholder (T0, T1, ...).
 */
fn bool is_type_param_placeholder(String name) {
	if (name.len < 2 || name[0] != 'T') return false;
	for (usz i = 1; i < name.len; i++) {
		if (name[i] < '0' || name[i] > '9') return false;
	}
	return true;
}

/**
 * Parse the index from a type parameter placeholder: "T0" -> 0, "T1" -> 1.
 */
fn int parse_type_param_index(String name) {
	if (name.len < 2 || name[0] != 'T') return -1;
	int idx = 0;
	for (usz i = 1; i < name.len; i++) {
		if (name[i] < '0' || name[i] > '9') return -1;
		idx = idx * 10 + (int)(name[i] - '0');
	}
	return idx;
}

/**
 * Look up a member by class_name in dep index and return its type.
 * Used for supertype walk.
 */
fn TypeRef resolve_dep_member_in_class(DependencyIndex* dep_index, String class_name, String member_name) {
	DepSymbol*[32] matches;
	usz count = dep_index.lookup_by_name(member_name, &matches);

	for (usz i = 0; i < count; i++) {
		if (matches[i].class_name != class_name) continue;
		if (matches[i].kind != DEP_METHOD && matches[i].kind != DEP_FIELD) continue;
		return extract_dep_return_type(matches[i]);
	}
	return TYPE_UNKNOWN;
}

/**
 * Extract return type from a DepSymbol's Kotlin-style signature.
 * Methods: "fun name(Int, String): ReturnType" -> parse ReturnType
 * Fields: "val name: Type" -> parse Type
 */
fn TypeRef extract_dep_return_type(DepSymbol* sym) {
	String sig = sym.signature;
	if (sig.len == 0) return TYPE_UNKNOWN;

	// Both methods and fields use ": Type" format:
	// Method: "fun name(Int, String): ReturnType"
	// Field:  "val name: Type" / "var name: Type"
	// Find last ": " to extract the type
	usz last_colon = 0;
	bool found = false;
	for (usz j = 0; j + 1 < sig.len; j++) {
		if (sig[j] == ':' && sig[j + 1] == ' ') {
			last_colon = j;
			found = true;
		}
	}
	if (found) {
		return parse_type_text(sig[last_colon + 2..]);
	}

	return TYPE_UNKNOWN;
}

/**
 * Resolve a name to a dep type by matching against file imports.
 * Handles class/interface/enum/object names imported explicitly or via star.
 * Also handles top-level functions (returns their return type).
 */
fn TypeRef resolve_dep_name_by_import(DependencyIndex* dep_index, ParseResult* pr, String name) {
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(name, &matches);
	if (count == 0) return TYPE_UNKNOWN;

	ImportMap imports = workspace::build_import_map(pr);

	// Check explicit imports first
	for (usz i = 0; i < count; i++) {
		for (usz j = 0; j < imports.import_count; j++) {
			if (imports.is_star[j]) continue;
			if (imports.import_names[j] != name) continue;
			String pkg = workspace::get_import_package(imports.import_paths[j]);
			if (pkg != matches[i].package_name) continue;

			if (matches[i].kind == DEP_CLASS || matches[i].kind == DEP_INTERFACE ||
				matches[i].kind == DEP_ENUM || matches[i].kind == DEP_OBJECT) {
				return { .kind = SIMPLE, .name = name, .is_class_ref = true };
			}
			if (matches[i].kind == DEP_METHOD) {
				return extract_dep_return_type(matches[i]);
			}
		}
	}

	// Check star imports
	for (usz i = 0; i < count; i++) {
		for (usz j = 0; j < imports.import_count; j++) {
			if (!imports.is_star[j]) continue;
			if (imports.star_packages[j] != matches[i].package_name) continue;

			if (matches[i].kind == DEP_CLASS || matches[i].kind == DEP_INTERFACE ||
				matches[i].kind == DEP_ENUM || matches[i].kind == DEP_OBJECT) {
				return { .kind = SIMPLE, .name = name, .is_class_ref = true };
			}
			if (matches[i].kind == DEP_METHOD) {
				return extract_dep_return_type(matches[i]);
			}
		}
	}

	// Auto-imported packages (kotlin.*, kotlin.collections.*, java.lang.*, ...)
	// resolve without explicit import — mirrors Kotlin/JVM compiler behavior.
	for (usz i = 0; i < count; i++) {
		if (!workspace::is_auto_imported_package(matches[i].package_name)) continue;
		if (matches[i].kind == DEP_CLASS || matches[i].kind == DEP_INTERFACE ||
			matches[i].kind == DEP_ENUM || matches[i].kind == DEP_OBJECT) {
			return { .kind = SIMPLE, .name = name, .is_class_ref = true };
		}
		if (matches[i].kind == DEP_METHOD) {
			return extract_dep_return_type(matches[i]);
		}
	}

	return TYPE_UNKNOWN;
}

fn TypeRef resolve_binary_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	String op = node.extra_text;

	if (op == "==" || op == "!=" || op == "===" || op == "!==" ||
	    op == "<" || op == ">" || op == "<=" || op == ">=" ||
	    op == "&&" || op == "||" || op == "in" || op == "!in") {
		return TYPE_BOOLEAN;
	}

	if (op == "?:") {
		uint child_count = 0;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent == idx) {
				child_count++;
				if (child_count == 2 && info.has_type[j]) {
					return info.node_types[j];
				}
			}
		}
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent == idx && info.has_type[j]) {
				TypeRef left_type = info.node_types[j];
				left_type.nullable = false;
				return left_type;
			}
		}
		return TYPE_UNKNOWN;
	}

	// Arithmetic — try operator method lookup first (user/data class plus/minus/etc.),
	// fall back to left-operand type for primitives where stdlib member table covers it.
	if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == ".." || op == "..<") {
		TypeRef left_t = TYPE_UNKNOWN;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent == idx && info.has_type[j]) {
				left_t = info.node_types[j];
				break;
			}
		}
		if (left_t.kind == UNKNOWN) return TYPE_UNKNOWN;
		String method = binary_op_method(op);
		if (method.len > 0) {
			// String "+" stays special: Kotlin spec says String + Any → String
			if (op == "+" && left_t.name == "String") return TYPE_STRING;
			TypeRef looked_up = resolve_member_type(left_t, method);
			if (looked_up.kind == UNKNOWN) {
				looked_up = lookup_member_anywhere(pr, info, left_t, method);
			}
			if (looked_up.kind != UNKNOWN) return looked_up;
		}
		// Fallback: assume same type as left (legacy behaviour for unknown receivers)
		return left_t;
	}

	// Infix function calls
	if (op == "to") {
		TypeRef left_t = TYPE_UNKNOWN;
		TypeRef right_t = TYPE_UNKNOWN;
		uint child_count = 0;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent == idx) {
				if (child_count == 0 && info.has_type[j]) left_t = info.node_types[j];
				if (child_count == 1 && info.has_type[j]) right_t = info.node_types[j];
				child_count++;
				if (child_count >= 2) break;
			}
		}
		TypeRef pair = { .kind = GENERIC, .name = "Pair" };
		if (left_t.kind != UNKNOWN && right_t.kind != UNKNOWN) {
			pair.type_arg_count = 2;
			pair.type_arg_names[0] = left_t.name;
			pair.type_arg_names[1] = right_t.name;
			pair.type_arg_nullable[0] = left_t.nullable;
			pair.type_arg_nullable[1] = right_t.nullable;
		}
		return pair;
	}
	if (op == "until" || op == "downTo") return { .kind = SIMPLE, .name = "IntRange" };

	return TYPE_UNKNOWN;
}

// ── Prefix expression resolution ───────────────────────────────────

fn TypeRef resolve_prefix_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	String op = node.extra_text;

	// Find operand type once
	TypeRef operand = TYPE_UNKNOWN;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx && info.has_type[j]) {
			operand = info.node_types[j];
			break;
		}
	}

	// `!` is always Boolean per spec (Boolean operand required), but try
	// user-defined `not` first for other types (e.g. custom BitSet).
	if (op == "!") {
		if (operand.kind != UNKNOWN && operand.name != "Boolean") {
			TypeRef looked_up = lookup_member_anywhere(pr, info, operand, "not");
			if (looked_up.kind != UNKNOWN) return looked_up;
		}
		return TYPE_BOOLEAN;
	}

	String method = unary_op_method(op);
	if (method.len > 0 && operand.kind != UNKNOWN) {
		TypeRef looked_up = resolve_member_type(operand, method);
		if (looked_up.kind == UNKNOWN) {
			looked_up = lookup_member_anywhere(pr, info, operand, method);
		}
		if (looked_up.kind != UNKNOWN) return looked_up;
	}

	// Fallback: legacy behaviour — operand type for unary +/- and pre-inc/dec
	if (op == "-" || op == "+" || op == "++" || op == "--") return operand;

	return TYPE_UNKNOWN;
}

// ── Postfix expression resolution ──────────────────────────────────

fn TypeRef resolve_postfix_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	String op = node.extra_text;

	// Find operand type once
	TypeRef operand = TYPE_UNKNOWN;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx && info.has_type[j]) {
			operand = info.node_types[j];
			break;
		}
	}

	if (op == "!!") {
		operand.nullable = false;
		return operand;
	}

	// Postfix `++` / `--` — try operator method, fall back to operand type
	if (op == "++" || op == "--") {
		String method = unary_op_method(op);
		if (method.len > 0 && operand.kind != UNKNOWN) {
			TypeRef looked_up = resolve_member_type(operand, method);
			if (looked_up.kind == UNKNOWN) {
				looked_up = lookup_member_anywhere(pr, info, operand, method);
			}
			if (looked_up.kind != UNKNOWN) return looked_up;
		}
		return operand;
	}

	return TYPE_UNKNOWN;
}

// ── Parenthesized / if / when / index expression resolution ────────

fn TypeRef resolve_paren_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx && info.has_type[j]) {
			return info.node_types[j];
		}
	}
	return TYPE_UNKNOWN;
}

fn TypeRef resolve_if_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	// Collect typed children of IF_EXPR.
	// The condition may or may not be present as a child (depends on parser).
	// The then/else branches are the last 2 children (or last 1 if no else).
	// Strategy: if there are 3 typed children, skip the first (condition).
	// If there are 2 typed children, compute common_type of both.
	// If only 1, return it directly.

	// First, count total children and collect typed ones
	uint child_count = 0;
	uint[8] typed_children;
	uint typed_count = 0;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx) {
			child_count++;
			if (info.has_type[j] && typed_count < 8) {
				typed_children[typed_count] = j;
				typed_count++;
			}
		}
	}

	if (typed_count == 0) return TYPE_UNKNOWN;

	// If we have 3+ children, the first is the condition -- skip it.
	// If we have exactly 2 children with types and 3+ total children,
	// the condition was typed too; skip it.
	uint start = 0;
	if (child_count >= 3 && typed_count >= 2) {
		// Skip the condition (first typed child)
		start = 1;
	}

	TypeRef result = TYPE_UNKNOWN;
	for (uint k = start; k < typed_count; k++) {
		TypeRef t = info.node_types[typed_children[k]];
		if (result.kind == UNKNOWN) {
			result = t;
		} else {
			result = common_type(result, t);
		}
	}
	return result;
}

fn TypeRef resolve_when_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	TypeRef result = TYPE_UNKNOWN;
	bool found_entry = false;
	// With WHEN_ENTRY nodes, the type of each branch is determined by
	// the body expression/block inside each WHEN_ENTRY child.
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != idx) continue;

		if (pr.nodes[j].kind == WHEN_ENTRY) {
			found_entry = true;
			// Find the body type of this WHEN_ENTRY.
			// Children are ordered: condition(s), then body (last child).
			// We want the body type, so find the last child and use its type.
			TypeRef entry_type = TYPE_UNKNOWN;
			uint last_child = pr.node_count; // sentinel
			for (uint k = 0; k < pr.node_count; k++) {
				if (pr.nodes[k].parent != j) continue;
				last_child = k;
			}
			if (last_child < pr.node_count && info.has_type[last_child]) {
				entry_type = info.node_types[last_child];
			}
			if (entry_type.kind != UNKNOWN) {
				if (result.kind == UNKNOWN) {
					result = entry_type;
				} else {
					result = common_type(result, entry_type);
				}
			}
		}
	}

	// Only fall back to direct children if no WHEN_ENTRY nodes exist
	// (old-style AST without explicit entries). Skip the subject expression
	// which is the first non-WHEN_ENTRY child.
	if (!found_entry) {
		bool skipped_subject = false;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != idx) continue;
			if (!info.has_type[j]) continue;
			// Skip the first typed child (subject expression)
			if (!skipped_subject) {
				skipped_subject = true;
				continue;
			}
			if (result.kind == UNKNOWN) {
				result = info.node_types[j];
			} else {
				result = common_type(result, info.node_types[j]);
			}
		}
	}

	return result;
}

// ── Try/catch expression resolution ────────────────────────────────

/**
 * try { expr } catch(e: T) { expr } finally { ... }
 * Type = common_type(try body, catch bodies). Finally ignored for type.
 */
fn TypeRef resolve_try_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	TypeRef result = TYPE_UNKNOWN;
	bool found_try_body = false;
	bool found_catch = false;

	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != idx) continue;

		if (pr.nodes[j].kind == CATCH_CLAUSE) {
			found_catch = true;
			// Find body expression type (skip PARAM nodes, descend into BLOCK)
			TypeRef catch_type = last_expr_type_in(pr, info, j, true);
			if (catch_type.kind != UNKNOWN) {
				if (result.kind == UNKNOWN) {
					result = catch_type;
				} else {
					result = common_type(result, catch_type);
				}
			}
		} else if (!found_try_body && !found_catch) {
			// First non-catch child = try body (may be BLOCK)
			found_try_body = true;
			TypeRef body_type = TYPE_UNKNOWN;
			if (pr.nodes[j].kind == BLOCK) {
				body_type = last_expr_type_in(pr, info, j, false);
			} else if (info.has_type[j]) {
				body_type = info.node_types[j];
			}
			if (body_type.kind != UNKNOWN) {
				if (result.kind == UNKNOWN) {
					result = body_type;
				} else {
					result = common_type(result, body_type);
				}
			}
		}
		// Any non-catch child after catch = finally block, skip for type
	}
	return result;
}

/**
 * Resolve type of a LAMBDA_EXPR node into a FUNCTION TypeRef.
 *
 * Builds the function type from:
 *  - PARAM children (parameter types from explicit annotations; "?" if missing)
 *  - body's last-expression type as the return type
 *
 * Used so `val f = { ... }` infers `f` as a function type, and so a later
 * `f(args)` call can return the lambda body's type.
 */
fn TypeRef resolve_lambda_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	TypeRef result = { .kind = FUNCTION, .name = "Function" };

	// Collect parameter type texts from PARAM children (in source order).
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != idx) continue;
		if (pr.nodes[j].kind != PARAM) continue;
		if (result.param_type_count >= MAX_TYPE_ARGS) break;

		String pt = pr.nodes[j].type_text;
		result.param_type_names[result.param_type_count] = pt.len > 0 ? pt : "?";
		result.param_type_count++;
	}

	// Return type: last expression of body. Skip PARAM children.
	TypeRef body_type = last_expr_type_in(pr, info, idx, true);
	if (body_type.kind != UNKNOWN && body_type.name.len > 0) {
		result.return_type_name = body_type.name;
	} else {
		result.return_type_name = "Unit";
	}

	return result;
}


/**
 * Build a FUNCTION TypeRef from a FUN_DECL's PARAMs + return type.
 * Used by callable-reference resolution (`::name`, `Type::name`).
 */
fn TypeRef function_type_from_fun_decl(ParseResult* pr, uint fun_decl_idx) {
	TypeRef result = { .kind = FUNCTION, .name = "Function" };
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != fun_decl_idx) continue;
		if (pr.nodes[j].kind != PARAM) continue;
		if (result.param_type_count >= MAX_TYPE_ARGS) break;
		String pt = pr.nodes[j].type_text;
		result.param_type_names[result.param_type_count] = pt.len > 0 ? pt : "?";
		result.param_type_count++;
	}
	String rt = pr.nodes[fun_decl_idx].type_text;
	result.return_type_name = rt.len > 0 ? rt : "Unit";
	return result;
}

/**
 * Resolve a CALLABLE_REF_EXPR node (`::name` or `Type::name`) into a FUNCTION TypeRef
 * (Kotlin spec §16.30.5). Bare `::name` looks up FUN_DECL via scope chain then
 * top-level. `Type::name` resolves the receiver child's type and looks up the
 * method via lookup_member_anywhere; v1 returns a minimal FUNCTION TypeRef with
 * just the return type populated.
 */
fn TypeRef resolve_callable_ref_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	if (node.name.len == 0) return TYPE_UNKNOWN;

	// Check for receiver child (Type::name form).
	uint recv_child = ast::NO_PARENT;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx) { recv_child = j; break; }
	}

	if (recv_child != ast::NO_PARENT) {
		// Type::name form: look up method on receiver type.
		if (!info.has_type[recv_child]) return TYPE_UNKNOWN;
		TypeRef recv = info.node_types[recv_child];
		TypeRef ret = lookup_member_anywhere(pr, info, recv, node.name);
		if (ret.kind == UNKNOWN) return TYPE_UNKNOWN;
		TypeRef result = { .kind = FUNCTION, .name = "Function" };
		result.return_type_name = ret.name.len > 0 ? ret.name : "Unit";
		return result;
	}

	// Bare ::name form: scope-chain lookup, then top-level FUN_DECL fallback.
	uint decl = find_decl_in_scope_chain(pr, idx, node.name);
	if (decl != ast::NO_PARENT && pr.nodes[decl].kind == FUN_DECL) {
		return function_type_from_fun_decl(pr, decl);
	}
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].kind != FUN_DECL) continue;
		if (pr.nodes[j].name != node.name) continue;
		return function_type_from_fun_decl(pr, j);
	}
	return TYPE_UNKNOWN;
}

/**
 * Find last expression type inside a parent node.
 * Descends into BLOCK children. Skips PARAM nodes when skip_params is true.
 */
fn TypeRef last_expr_type_in(ParseResult* pr, TypeInfo* info, uint parent_idx, bool skip_params) {
	TypeRef last_type = TYPE_UNKNOWN;
	for (uint k = 0; k < pr.node_count; k++) {
		if (pr.nodes[k].parent != parent_idx) continue;
		if (skip_params && pr.nodes[k].kind == PARAM) continue;
		if (pr.nodes[k].kind == BLOCK) {
			TypeRef block_type = last_expr_type_in(pr, info, k, false);
			if (block_type.kind != UNKNOWN) last_type = block_type;
		} else if (info.has_type[k]) {
			last_type = info.node_types[k];
		}
	}
	return last_type;
}

fn TypeRef resolve_index_expr_type(ParseResult* pr, TypeInfo* info, uint idx, AstNode* node) {
	// First child = receiver, second = index expression
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == idx) {
			// This is the receiver (first child)
			if (!info.has_type[j]) return TYPE_UNKNOWN;
			TypeRef receiver = info.node_types[j];
			if (receiver.name == "String") return TYPE_CHAR;
			if (receiver.kind == GENERIC && receiver.type_arg_count > 0) {
				// Map<K,V>[key] → V? (nullable because key may be absent)
				if ((receiver.name == "Map" || receiver.name == "MutableMap" ||
				     receiver.name == "HashMap" || receiver.name == "LinkedHashMap")
				    && receiver.type_arg_count >= 2) {
					return { .kind = SIMPLE, .name = receiver.type_arg_names[1], .nullable = true };
				}
				// List<T>[i] → T, etc.
				return { .kind = SIMPLE, .name = receiver.type_arg_names[0] };
			}
			// User-defined `operator fun get(...)` lookup per Kotlin spec §9.6.
			TypeRef getter = lookup_member_anywhere(pr, info, receiver, "get");
			if (getter.kind != UNKNOWN) return getter;
			break;
		}
	}
	return TYPE_UNKNOWN;
}

// ── Helper: common supertype ───────────────────────────────────────

fn TypeRef common_type(TypeRef a, TypeRef b) {
	if (a.kind == UNKNOWN) return b;
	if (b.kind == UNKNOWN) return a;
	if (a.kind == NOTHING) return b;
	if (b.kind == NOTHING) return a;

	if (a.name == b.name) {
		TypeRef result = a;
		result.nullable = a.nullable || b.nullable;
		return result;
	}

	if (is_numeric_type(a) && is_numeric_type(b)) {
		return promote_numeric(a, b);
	}

	TypeRef any_type = TYPE_ANY;
	any_type.nullable = a.nullable || b.nullable;
	return any_type;
}

fn bool is_numeric_type(TypeRef t) {
	return t.name == "Int" || t.name == "Long" || t.name == "Float" ||
	       t.name == "Double" || t.name == "Short" || t.name == "Byte";
}

fn TypeRef promote_numeric(TypeRef a, TypeRef b) {
	int rank_a = numeric_rank(a);
	int rank_b = numeric_rank(b);
	return rank_a >= rank_b ? a : b;
}

fn int numeric_rank(TypeRef t) {
	if (t.name == "Double") return 6;
	if (t.name == "Float") return 5;
	if (t.name == "Long") return 4;
	if (t.name == "Int") return 3;
	if (t.name == "Short") return 2;
	if (t.name == "Byte") return 1;
	return 0;
}

// ── Type assignability ────────────────────────────────────────────

/**
 * Hardcoded stdlib supertype table.
 * Each entry: { type_name, { supertype1, supertype2, ... } }
 * BFS walk to check transitive supertypes.
 */
const usz MAX_STDLIB_SUPERS = 4;

struct StdlibSupertypeEntry {
	String name;
	String[MAX_STDLIB_SUPERS] supertypes;
	usz super_count;
}

const StdlibSupertypeEntry[*] STDLIB_SUPERTYPES = {
	// Primitives → Number → Comparable → Any
	{ "Int",                { "Number", "Comparable", "Any", "" },                    3 },
	{ "Long",               { "Number", "Comparable", "Any", "" },                    3 },
	{ "Short",              { "Number", "Comparable", "Any", "" },                    3 },
	{ "Byte",               { "Number", "Comparable", "Any", "" },                    3 },
	{ "Float",              { "Number", "Comparable", "Any", "" },                    3 },
	{ "Double",             { "Number", "Comparable", "Any", "" },                    3 },
	{ "Number",             { "Comparable", "Any", "", "" },                          2 },
	{ "Boolean",            { "Comparable", "Any", "", "" },                          2 },
	{ "Char",               { "Comparable", "Any", "", "" },                          2 },
	{ "String",             { "CharSequence", "Comparable", "Any", "" },              3 },
	{ "CharSequence",       { "Any", "", "", "" },                                    1 },
	{ "Comparable",         { "Any", "", "", "" },                                    1 },
	// Unsigned
	{ "UInt",               { "Comparable", "Any", "", "" },                          2 },
	{ "ULong",              { "Comparable", "Any", "", "" },                          2 },
	{ "UShort",             { "Comparable", "Any", "", "" },                          2 },
	{ "UByte",              { "Comparable", "Any", "", "" },                          2 },
	// Collections
	{ "Iterable",           { "Any", "", "", "" },                                    1 },
	{ "Collection",         { "Iterable", "Any", "", "" },                            2 },
	{ "List",               { "Collection", "Iterable", "Any", "" },                  3 },
	{ "Set",                { "Collection", "Iterable", "Any", "" },                  3 },
	{ "MutableIterable",    { "Iterable", "Any", "", "" },                            2 },
	{ "MutableCollection",  { "Collection", "MutableIterable", "Iterable", "Any" },   4 },
	{ "MutableList",        { "List", "MutableCollection", "", "" },                  2 },
	{ "MutableSet",         { "Set", "MutableCollection", "", "" },                   2 },
	{ "ArrayList",          { "MutableList", "List", "Any", "" },                     3 },
	{ "LinkedList",         { "MutableList", "List", "Any", "" },                     3 },
	{ "HashSet",            { "MutableSet", "Set", "Any", "" },                       3 },
	{ "LinkedHashSet",      { "MutableSet", "Set", "Any", "" },                       3 },
	{ "Sequence",           { "Any", "", "", "" },                                    1 },
	// Maps
	{ "Map",                { "Any", "", "", "" },                                    1 },
	{ "MutableMap",         { "Map", "Any", "", "" },                                 2 },
	{ "HashMap",            { "MutableMap", "Map", "Any", "" },                       3 },
	{ "LinkedHashMap",      { "MutableMap", "Map", "Any", "" },                       3 },
	// Pair / Triple
	{ "Pair",               { "Any", "", "", "" },                                    1 },
	{ "Triple",             { "Any", "", "", "" },                                    1 },
	// Exceptions
	{ "Throwable",          { "Any", "", "", "" },                                    1 },
	{ "Exception",          { "Throwable", "Any", "", "" },                           2 },
	{ "RuntimeException",   { "Exception", "Throwable", "Any", "" },                  3 },
	{ "IllegalArgumentException",  { "RuntimeException", "Exception", "Throwable", "" },  3 },
	{ "IllegalStateException",     { "RuntimeException", "Exception", "Throwable", "" },  3 },
	{ "NullPointerException",      { "RuntimeException", "Exception", "Throwable", "" },  3 },
	{ "IndexOutOfBoundsException", { "RuntimeException", "Exception", "Throwable", "" },  3 },
	{ "UnsupportedOperationException", { "RuntimeException", "Exception", "Throwable", "" }, 3 },
	{ "NoSuchElementException",    { "RuntimeException", "Exception", "Throwable", "" },  3 },
	{ "ConcurrentModificationException", { "RuntimeException", "Exception", "Throwable", "" }, 3 },
	{ "Error",              { "Throwable", "Any", "", "" },                           2 },
	// Other
	{ "Unit",               { "Any", "", "", "" },                                    1 },
	{ "Array",              { "Any", "", "", "" },                                    1 },
	{ "IntArray",           { "Any", "", "", "" },                                    1 },
	{ "LongArray",          { "Any", "", "", "" },                                    1 },
	{ "DoubleArray",        { "Any", "", "", "" },                                    1 },
	{ "FloatArray",         { "Any", "", "", "" },                                    1 },
	{ "ByteArray",          { "Any", "", "", "" },                                    1 },
	{ "ShortArray",         { "Any", "", "", "" },                                    1 },
	{ "BooleanArray",       { "Any", "", "", "" },                                    1 },
	{ "CharArray",          { "Any", "", "", "" },                                    1 },
	{ "Enum",               { "Comparable", "Any", "", "" },                          2 },
	{ "Regex",              { "Any", "", "", "" },                                    1 },
};

/**
 * Hardcoded generic variance table.
 * 0 = invariant, 1 = covariant (out), -1 = contravariant (in)
 */
const usz MAX_VARIANCE_PARAMS = 2;

struct VarianceEntry {
	String name;
	int[MAX_VARIANCE_PARAMS] variance;  // per type param
	usz param_count;
}

const VarianceEntry[*] GENERIC_VARIANCE = {
	{ "List",               { 1, 0 },   1 },  // List<out E>
	{ "Set",                { 1, 0 },   1 },  // Set<out E>
	{ "Collection",         { 1, 0 },   1 },  // Collection<out E>
	{ "Iterable",           { 1, 0 },   1 },  // Iterable<out T>
	{ "Sequence",           { 1, 0 },   1 },  // Sequence<out T>
	{ "Map",                { 0, 1 },   2 },  // Map<K, out V>
	{ "Map.Entry",          { 0, 1 },   2 },  // Map.Entry<K, out V>
	{ "Comparable",         { -1, 0 },  1 },  // Comparable<in T>
	// Mutable collections: invariant
	{ "MutableList",        { 0, 0 },   1 },
	{ "MutableSet",         { 0, 0 },   1 },
	{ "MutableCollection",  { 0, 0 },   1 },
	{ "MutableIterable",    { 0, 0 },   1 },
	{ "MutableMap",         { 0, 0 },   2 },
	{ "ArrayList",          { 0, 0 },   1 },
	{ "HashSet",            { 0, 0 },   1 },
	{ "HashMap",            { 0, 0 },   2 },
	{ "LinkedHashMap",      { 0, 0 },   2 },
	{ "Array",              { 0, 0 },   1 },  // Array is invariant in Kotlin
	{ "Pair",               { 0, 0 },   2 },  // Pair<A, B> invariant
	{ "Triple",             { 0, 0 },   2 },  // Triple<A, B> -- only 2 tracked
};

/**
 * Check if source type is assignable to target type.
 * Follows Kotlin's type system rules:
 * - No implicit numeric widening (Int NOT assignable to Long)
 * - T assignable to T?, but not vice versa
 * - Nothing is subtype of everything
 * - Any is supertype of everything
 * - Stdlib hierarchy + workspace supertypes (BFS)
 * - Generic variance (covariant, contravariant, invariant)
 * - Function type variance (contravariant params, covariant return)
 */
fn bool is_assignable_to(TypeRef source, TypeRef target) {
	// UNKNOWN: permissive to avoid false positives
	if (source.kind == UNKNOWN || target.kind == UNKNOWN) return true;

	// Nothing is subtype of everything
	if (source.kind == NOTHING || source.name == "Nothing") {
		// Nothing (non-nullable) assignable to any type
		if (!source.nullable) return true;
		// Nothing? (null literal) only assignable to nullable types
		return target.nullable;
	}

	// Unit: anything assignable to Unit (Kotlin allows ignoring return values)
	if (target.kind == UNIT || target.name == "Unit") return true;

	// Any target: supertype of everything
	if (target.name == "Any") {
		if (target.nullable) return true;           // Any? accepts everything
		return !source.nullable;                    // Any accepts non-nullable only
	}

	// Type parameters (T, V, K, etc.) accept any type — we can't verify
	// without generic substitution, so be permissive to avoid false positives
	if (is_type_parameter(target.name)) return true;
	if (is_type_parameter(source.name)) return true;

	// Numeric literal widening: Kotlin allows integer literals to widen
	// Int -> Long, Float -> Double, Byte -> Short/Int/Long, Short -> Int/Long
	if (is_numeric_widening(source.name, target.name)) return true;

	// Same name
	if (source.name == target.name) {
		// Nullable check: T? NOT assignable to T, but T assignable to T?
		if (source.nullable && !target.nullable) return false;

		// Check generic type arguments if both have them
		if (source.type_arg_count > 0 && target.type_arg_count > 0) {
			return check_generic_args_assignable(source, target);
		}
		return true;
	}

	// Nullable source to non-nullable target: never OK (different names)
	if (source.nullable && !target.nullable) {
		// Exception: Nothing? handled above
		return false;
	}

	// Check stdlib supertype hierarchy (BFS)
	if (is_stdlib_subtype(source.name, target.name)) {
		// For generic targets, check type args through the hierarchy
		if (target.type_arg_count > 0) {
			return check_supertype_generic_args(source, target);
		}
		return true;
	}

	// Function type assignability: contravariant params, covariant return
	if (source.kind == FUNCTION && target.kind == FUNCTION) {
		return check_function_type_assignable(source, target);
	}

	// Permissive for unknown types: if either type is not in our known
	// stdlib/primitive hierarchy, we can't verify the relationship.
	// Return true to avoid false positive diagnostics for user/dependency types.
	if (!is_known_stdlib_type(source.name) || !is_known_stdlib_type(target.name)) {
		return true;
	}

	return false;
}

/**
 * Check if source numeric type can be widened to target numeric type.
 * Kotlin allows this for literal values in argument positions.
 */
fn bool is_numeric_widening(String source, String target) {
	if (target == "Long") return source == "Int" || source == "Short" || source == "Byte";
	if (target == "Int") return source == "Short" || source == "Byte";
	if (target == "Short") return source == "Byte";
	if (target == "Double") return source == "Float" || source == "Int" || source == "Long";
	if (target == "Float") return source == "Int";
	return false;
}

/**
 * Check if a type name is in our known stdlib/primitive type table.
 * Types not in this table are user/dependency types where we can't
 * verify subtype relationships.
 */
fn bool is_known_stdlib_type(String name) {
	for (usz i = 0; i < STDLIB_SUPERTYPES.len; i++) {
		if (STDLIB_SUPERTYPES[i].name == name) return true;
	}
	// Also check 'Any' and 'Nothing' which aren't in the table as entries
	if (name == "Any" || name == "Nothing") return true;
	return false;
}

/**
 * BFS check: is source_name a subtype of target_name in stdlib hierarchy?
 */
fn bool is_stdlib_subtype(String source_name, String target_name) {
	// BFS with visited set (max 32 types to check)
	String[32] queue;
	bool[32] visited_flags;
	String[32] visited_names;
	usz visited_count = 0;
	usz q_start = 0;
	usz q_end = 0;

	queue[q_end++] = source_name;

	while (q_start < q_end && q_start < 32) {
		String current = queue[q_start++];

		// Check visited
		bool was_visited = false;
		for (usz v = 0; v < visited_count; v++) {
			if (visited_names[v] == current) { was_visited = true; break; }
		}
		if (was_visited) continue;
		if (visited_count < 32) visited_names[visited_count++] = current;

		// Look up in stdlib table
		for (usz i = 0; i < STDLIB_SUPERTYPES.len; i++) {
			if (STDLIB_SUPERTYPES[i].name != current) continue;

			for (usz s = 0; s < STDLIB_SUPERTYPES[i].super_count; s++) {
				String sup = STDLIB_SUPERTYPES[i].supertypes[s];
				if (sup == target_name) return true;
				if (q_end < 32) queue[q_end++] = sup;
			}
			break;
		}
	}

	return false;
}

/**
 * Check generic type argument assignability respecting variance.
 * Both source and target have the same container name.
 */
/**
 * Check if a type name looks like an unresolved type parameter.
 * Type parameters are typically single uppercase letters (T, K, V, R, E)
 * or short names not in known stdlib types.
 */
fn bool is_type_parameter(String name) {
	if (name.len == 0) return false;
	// Single uppercase letter: definitely a type parameter
	if (name.len == 1 && name[0] >= 'A' && name[0] <= 'Z') return true;
	// Two-letter names starting with uppercase that aren't known types
	if (name.len == 2 && name[0] >= 'A' && name[0] <= 'Z' && name[1] >= 'A' && name[1] <= 'Z') {
		return !is_known_stdlib_type(name);
	}
	return false;
}

fn bool check_generic_args_assignable(TypeRef source, TypeRef target) {
	// Find variance for this container
	for (usz i = 0; i < GENERIC_VARIANCE.len; i++) {
		if (GENERIC_VARIANCE[i].name != source.name) continue;

		usz check_count = GENERIC_VARIANCE[i].param_count;
		if (check_count > source.type_arg_count) check_count = source.type_arg_count;
		if (check_count > target.type_arg_count) check_count = target.type_arg_count;

		for (usz p = 0; p < check_count; p++) {
			String src_arg = source.type_arg_names[p];
			String tgt_arg = target.type_arg_names[p];
			bool src_null = source.type_arg_nullable[p];
			bool tgt_null = target.type_arg_nullable[p];

			if (src_arg == tgt_arg) {
				// Same name: check nullable direction
				if (src_null && !tgt_null) return false;
				continue;
			}

			// Star projection: always OK
			if (tgt_arg == "*" || src_arg == "*") continue;

			int variance = GENERIC_VARIANCE[i].variance[p];
			TypeRef src_type = parse_type_text(src_arg);
			src_type.nullable = src_null;
			TypeRef tgt_type = parse_type_text(tgt_arg);
			tgt_type.nullable = tgt_null;

			if (variance == 1) {
				// Covariant (out): source arg must be assignable to target arg
				if (!is_assignable_to(src_type, tgt_type)) return false;
			} else if (variance == -1) {
				// Contravariant (in): target arg must be assignable to source arg
				if (!is_assignable_to(tgt_type, src_type)) return false;
			} else {
				// Invariant: must be same type (bidirectional)
				if (!is_assignable_to(src_type, tgt_type)) return false;
				if (!is_assignable_to(tgt_type, src_type)) return false;
			}
		}
		return true;
	}

	// No variance entry found: treat all args as invariant
	// Be permissive with unresolved type parameters (e.g., V vs L)
	// to avoid false positives in generic code.
	usz check_count = source.type_arg_count;
	if (check_count > target.type_arg_count) check_count = target.type_arg_count;
	for (usz p = 0; p < check_count; p++) {
		String src_arg = source.type_arg_names[p];
		String tgt_arg = target.type_arg_names[p];
		if (src_arg == tgt_arg) {
			if (source.type_arg_nullable[p] && !target.type_arg_nullable[p]) return false;
			continue;
		}
		// If either arg looks like an unresolved type parameter, be permissive
		if (is_type_parameter(src_arg) || is_type_parameter(tgt_arg)) continue;
		// Both are concrete types — check assignability
		TypeRef src_type = parse_type_text(src_arg);
		src_type.nullable = source.type_arg_nullable[p];
		TypeRef tgt_type = parse_type_text(tgt_arg);
		tgt_type.nullable = target.type_arg_nullable[p];
		if (!is_assignable_to(src_type, tgt_type)) return false;
		if (!is_assignable_to(tgt_type, src_type)) return false;
	}
	return true;
}

/**
 * Check generic args when assigning to a supertype with generic params.
 * E.g. ArrayList<String> assignable to Collection<String> (covariant).
 */
fn bool check_supertype_generic_args(TypeRef source, TypeRef target) {
	// If source has type args, check against target's type args
	if (source.type_arg_count > 0 && target.type_arg_count > 0) {
		// Find variance for the TARGET container
		for (usz i = 0; i < GENERIC_VARIANCE.len; i++) {
			if (GENERIC_VARIANCE[i].name != target.name) continue;

			usz check_count = GENERIC_VARIANCE[i].param_count;
			if (check_count > source.type_arg_count) check_count = source.type_arg_count;
			if (check_count > target.type_arg_count) check_count = target.type_arg_count;

			for (usz p = 0; p < check_count; p++) {
				String src_arg = source.type_arg_names[p];
				String tgt_arg = target.type_arg_names[p];
				bool src_null = source.type_arg_nullable[p];
				bool tgt_null = target.type_arg_nullable[p];

				if (src_arg == tgt_arg && src_null == tgt_null) continue;
				if (tgt_arg == "*" || src_arg == "*") continue;

				int variance = GENERIC_VARIANCE[i].variance[p];
				TypeRef src_type = parse_type_text(src_arg);
				src_type.nullable = src_null;
				TypeRef tgt_type = parse_type_text(tgt_arg);
				tgt_type.nullable = tgt_null;

				if (variance == 1) {
					if (!is_assignable_to(src_type, tgt_type)) return false;
				} else if (variance == -1) {
					if (!is_assignable_to(tgt_type, src_type)) return false;
				} else {
					if (!is_assignable_to(src_type, tgt_type)) return false;
					if (!is_assignable_to(tgt_type, src_type)) return false;
				}
			}
			return true;
		}
	}
	// No type args to check or no variance info: allow
	return true;
}

/**
 * Function type assignability:
 * - Params are contravariant: target param types must be assignable to source param types
 * - Return type is covariant: source return must be assignable to target return
 */
fn bool check_function_type_assignable(TypeRef source, TypeRef target) {
	// Param count must match
	if (source.param_type_count != target.param_type_count) return false;

	// Check params (contravariant)
	usz param_count = source.param_type_count;
	for (usz i = 0; i < param_count; i++) {
		TypeRef src_param = parse_type_text(source.param_type_names[i]);
		TypeRef tgt_param = parse_type_text(target.param_type_names[i]);
		// Contravariant: target param must be assignable to source param
		if (!is_assignable_to(tgt_param, src_param)) return false;
	}

	// Check return type (covariant)
	TypeRef src_return = parse_type_text(source.return_type_name);
	TypeRef tgt_return = parse_type_text(target.return_type_name);
	if (!is_assignable_to(src_return, tgt_return)) return false;

	return true;
}

/**
 * Format a type for diagnostic messages: "Type" or "Type?"
 */
fn String format_type_for_diagnostic(TypeRef* t) {
	if (t.kind == UNKNOWN) return "Unknown";
	if (t.kind == NOTHING) return t.nullable ? "Nothing?" : "Nothing";
	if (t.kind == UNIT) return "Unit";

	if (t.type_arg_count > 0) {
		// Use full_text if available, else build name<args>
		if (t.full_text.len > 0) {
			return t.nullable ? string::tformat("%s?", t.full_text) : t.full_text;
		}
		DString buf;
		buf.tinit();
		buf.appendf("%s<", t.name);
		for (usz i = 0; i < t.type_arg_count; i++) {
			if (i > 0) buf.appendf(", ");
			buf.appendf("%s", t.type_arg_names[i]);
			if (t.type_arg_nullable[i]) buf.appendf("?");
		}
		buf.appendf(">");
		if (t.nullable) buf.appendf("?");
		return buf.str_view();
	}

	return t.nullable ? string::tformat("%s?", t.name) : t.name;
}

// ── Scope helpers ──────────────────────────────────────────────────

fn uint find_innermost_scope(ParseResult* pr, uint node_idx) {
	AstNode* node = &pr.nodes[node_idx];
	uint offset = node.start_offset;

	uint scope_idx = 0;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!is_scope_kind(n.kind)) continue;
		if (offset >= n.start_offset && offset < n.end_offset) {
			scope_idx = i;
		}
	}
	return scope_idx;
}

fn bool is_scope_kind(NodeKind kind) {
	switch (kind) {
		case FILE:
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case FUN_DECL:
		case BLOCK:
		case FOR_STMT:
		case CATCH_CLAUSE:
		case LAMBDA_EXPR:
			return true;
		default:
			return false;
	}
}

fn bool is_typed_declaration(NodeKind kind) {
	switch (kind) {
		case PROPERTY_DECL:
		case FUN_DECL:
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case PARAM:
		case TYPEALIAS_DECL:
		case ENUM_ENTRY:
			return true;
		default:
			return false;
	}
}

fn AstNode*? find_enclosing_class(ParseResult* pr, uint node_idx) {
	uint current = node_idx;
	while (current != ast::NO_PARENT && current < pr.node_count) {
		AstNode* n = &pr.nodes[current];
		if (n.kind == CLASS_DECL || n.kind == INTERFACE_DECL ||
		    n.kind == OBJECT_DECL || n.kind == COMPANION_OBJECT_DECL) {
			return n;
		}
		current = n.parent;
	}
	return ast::NOT_FOUND~;
}

// ── Member info for completion ─────────────────────────────────────

const usz MAX_MEMBERS = 128;

struct MemberInfo {
	String name;
	String signature;
	String detail;
	int kind;      // LSP CompletionItemKind
	String doc;    // optional documentation text
}

/**
 * Look up members available on a type.
 * Fills out_buf with member info and returns count.
 *
 * When `receiver_is_class_ref` is true (e.g. `UUID.` referencing the
 * class itself, not an instance), returns 0 — the hardcoded type tables
 * model instance members only. Real static members come from the dep
 * index path and stdlib companion lookups.
 */
fn usz lookup_members(TypeRef* type_ref, MemberInfo[] out_buf, bool receiver_is_class_ref = false) {
	if (type_ref.kind == UNKNOWN || out_buf.len == 0) return 0;
	if (receiver_is_class_ref) return 0;

	String type_name = type_ref.name;
	usz count = 0;

	if (type_name == "String") {
		count = add_string_members(out_buf, count);
	} else if (type_name == "Int" || type_name == "Long" || type_name == "Float" ||
	         type_name == "Double" || type_name == "Short" || type_name == "Byte") {
		count = add_number_members(out_buf, count, type_name);
	} else if (type_name == "Boolean") {
		count = add_boolean_members(out_buf, count);
	} else if (type_name == "List" || type_name == "MutableList" ||
	         type_name == "Set" || type_name == "MutableSet" ||
	         type_name == "Collection" || type_name == "MutableCollection" ||
	         type_name == "Iterable" || type_name == "Sequence") {
		count = add_collection_members(out_buf, count, type_name);
	} else if (type_name == "Map" || type_name == "MutableMap" ||
	         type_name == "HashMap" || type_name == "LinkedHashMap") {
		count = add_map_members(out_buf, count, type_name);
	}

	count = add_any_members(out_buf, count);
	count = add_scope_function_members(out_buf, count);

	return count;
}

fn usz add_member(MemberInfo[] buf, usz count, String name, String sig, String detail, int kind) {
	if (count >= buf.len) return count;
	buf[count] = { .name = name, .signature = sig, .detail = detail, .kind = kind };
	return count + 1;
}

fn usz add_member_with_doc(MemberInfo[] buf, usz count, String name, String sig, String detail, int kind, String doc) {
	if (count >= buf.len) return count;
	buf[count] = { .name = name, .signature = sig, .detail = detail, .kind = kind, .doc = doc };
	return count + 1;
}

fn usz add_any_members(MemberInfo[] buf, usz count) {
	count = add_member(buf, count, "toString", "fun toString(): String", "String", 2);
	count = add_member(buf, count, "hashCode", "fun hashCode(): Int", "Int", 2);
	count = add_member(buf, count, "equals", "fun equals(other: Any?): Boolean", "Boolean", 2);
	return count;
}

fn usz add_scope_function_members(MemberInfo[] buf, usz count) {
	count = add_member_with_doc(buf, count, "let", "fun <T, R> T.let(block: (T) -> R): R", "R", 2,
		"Calls block with this value as argument and returns the result.");
	count = add_member_with_doc(buf, count, "run", "fun <T, R> T.run(block: T.() -> R): R", "R", 2,
		"Calls block with this value as receiver and returns the result.");
	count = add_member_with_doc(buf, count, "also", "fun <T> T.also(block: (T) -> Unit): T", "T", 2,
		"Calls block with this value as argument and returns this value.");
	count = add_member_with_doc(buf, count, "apply", "fun <T> T.apply(block: T.() -> Unit): T", "T", 2,
		"Calls block with this value as receiver and returns this value.");
	count = add_member_with_doc(buf, count, "takeIf", "fun <T> T.takeIf(predicate: (T) -> Boolean): T?", "T?", 2,
		"Returns this value if it satisfies the predicate, or null otherwise.");
	count = add_member_with_doc(buf, count, "takeUnless", "fun <T> T.takeUnless(predicate: (T) -> Boolean): T?", "T?", 2,
		"Returns this value if it does not satisfy the predicate, or null otherwise.");
	return count;
}

fn usz add_string_members(MemberInfo[] buf, usz count) {
	count = add_member(buf, count, "length", "val length: Int", "Int", 10);
	count = add_member(buf, count, "isEmpty", "fun isEmpty(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "isNotEmpty", "fun isNotEmpty(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "isBlank", "fun isBlank(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "isNotBlank", "fun isNotBlank(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "substring", "fun substring(startIndex: Int): String", "String", 2);
	count = add_member(buf, count, "contains", "fun contains(other: CharSequence): Boolean", "Boolean", 2);
	count = add_member(buf, count, "startsWith", "fun startsWith(prefix: String): Boolean", "Boolean", 2);
	count = add_member(buf, count, "endsWith", "fun endsWith(suffix: String): Boolean", "Boolean", 2);
	count = add_member(buf, count, "indexOf", "fun indexOf(string: String): Int", "Int", 2);
	count = add_member(buf, count, "lastIndexOf", "fun lastIndexOf(string: String): Int", "Int", 2);
	count = add_member(buf, count, "replace", "fun replace(oldValue: String, newValue: String): String", "String", 2);
	count = add_member(buf, count, "trim", "fun trim(): String", "String", 2);
	count = add_member(buf, count, "lowercase", "fun lowercase(): String", "String", 2);
	count = add_member(buf, count, "uppercase", "fun uppercase(): String", "String", 2);
	count = add_member(buf, count, "split", "fun split(delimiter: String): List<String>", "List<String>", 2);
	count = add_member(buf, count, "lines", "fun lines(): List<String>", "List<String>", 2);
	count = add_member(buf, count, "toInt", "fun toInt(): Int", "Int", 2);
	count = add_member(buf, count, "toLong", "fun toLong(): Long", "Long", 2);
	count = add_member(buf, count, "toDouble", "fun toDouble(): Double", "Double", 2);
	count = add_member(buf, count, "toBoolean", "fun toBoolean(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "reversed", "fun reversed(): String", "String", 2);
	count = add_member(buf, count, "take", "fun take(n: Int): String", "String", 2);
	count = add_member(buf, count, "drop", "fun drop(n: Int): String", "String", 2);
	count = add_member(buf, count, "first", "fun first(): Char", "Char", 2);
	count = add_member(buf, count, "last", "fun last(): Char", "Char", 2);
	count = add_member(buf, count, "count", "fun count(): Int", "Int", 2);
	count = add_member(buf, count, "repeat", "fun repeat(n: Int): String", "String", 2);
	count = add_member(buf, count, "toRegex", "fun toRegex(): Regex", "Regex", 2);
	count = add_member(buf, count, "toByteArray", "fun toByteArray(): ByteArray", "ByteArray", 2);
	count = add_member(buf, count, "toCharArray", "fun toCharArray(): CharArray", "CharArray", 2);
	return count;
}

fn usz add_number_members(MemberInfo[] buf, usz count, String type_name) {
	count = add_member(buf, count, "toInt", "fun toInt(): Int", "Int", 2);
	count = add_member(buf, count, "toLong", "fun toLong(): Long", "Long", 2);
	count = add_member(buf, count, "toFloat", "fun toFloat(): Float", "Float", 2);
	count = add_member(buf, count, "toDouble", "fun toDouble(): Double", "Double", 2);
	count = add_member(buf, count, "toByte", "fun toByte(): Byte", "Byte", 2);
	count = add_member(buf, count, "toShort", "fun toShort(): Short", "Short", 2);
	count = add_member(buf, count, "toChar", "fun toChar(): Char", "Char", 2);
	count = add_member(buf, count, "compareTo", string::tformat("fun compareTo(other: %s): Int", type_name), "Int", 2);
	count = add_member(buf, count, "plus", string::tformat("operator fun plus(other: %s): %s", type_name, type_name), type_name, 2);
	count = add_member(buf, count, "minus", string::tformat("operator fun minus(other: %s): %s", type_name, type_name), type_name, 2);
	count = add_member(buf, count, "times", string::tformat("operator fun times(other: %s): %s", type_name, type_name), type_name, 2);
	count = add_member(buf, count, "div", string::tformat("operator fun div(other: %s): %s", type_name, type_name), type_name, 2);
	count = add_member(buf, count, "rem", string::tformat("operator fun rem(other: %s): %s", type_name, type_name), type_name, 2);
	count = add_member(buf, count, "inc", string::tformat("operator fun inc(): %s", type_name), type_name, 2);
	count = add_member(buf, count, "dec", string::tformat("operator fun dec(): %s", type_name), type_name, 2);
	count = add_member(buf, count, "rangeTo", string::tformat("operator fun rangeTo(other: %s): IntRange", type_name), "IntRange", 2);
	count = add_member(buf, count, "coerceIn", string::tformat("fun coerceIn(min: %s, max: %s): %s", type_name, type_name, type_name), type_name, 2);
	count = add_member(buf, count, "coerceAtLeast", string::tformat("fun coerceAtLeast(min: %s): %s", type_name, type_name), type_name, 2);
	count = add_member(buf, count, "coerceAtMost", string::tformat("fun coerceAtMost(max: %s): %s", type_name, type_name), type_name, 2);
	return count;
}

fn usz add_boolean_members(MemberInfo[] buf, usz count) {
	count = add_member(buf, count, "and", "infix fun and(other: Boolean): Boolean", "Boolean", 2);
	count = add_member(buf, count, "or", "infix fun or(other: Boolean): Boolean", "Boolean", 2);
	count = add_member(buf, count, "xor", "infix fun xor(other: Boolean): Boolean", "Boolean", 2);
	count = add_member(buf, count, "not", "fun not(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "compareTo", "fun compareTo(other: Boolean): Int", "Int", 2);
	return count;
}

fn usz add_collection_members(MemberInfo[] buf, usz count, String type_name) {
	count = add_member(buf, count, "size", "val size: Int", "Int", 10);
	count = add_member(buf, count, "isEmpty", "fun isEmpty(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "isNotEmpty", "fun isNotEmpty(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "contains", "fun contains(element: T): Boolean", "Boolean", 2);
	count = add_member(buf, count, "first", "fun first(): T", "T", 2);
	count = add_member(buf, count, "last", "fun last(): T", "T", 2);
	count = add_member(buf, count, "firstOrNull", "fun firstOrNull(): T?", "T?", 2);
	count = add_member(buf, count, "lastOrNull", "fun lastOrNull(): T?", "T?", 2);
	count = add_member(buf, count, "find", "fun find(predicate: (T) -> Boolean): T?", "T?", 2);
	count = add_member(buf, count, "indexOf", "fun indexOf(element: T): Int", "Int", 2);
	count = add_member(buf, count, "count", "fun count(): Int", "Int", 2);
	count = add_member(buf, count, "any", "fun any(predicate: (T) -> Boolean): Boolean", "Boolean", 2);
	count = add_member(buf, count, "all", "fun all(predicate: (T) -> Boolean): Boolean", "Boolean", 2);
	count = add_member(buf, count, "none", "fun none(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "filter", "fun filter(predicate: (T) -> Boolean): List<T>", "List<T>", 2);
	count = add_member(buf, count, "map", "fun <R> map(transform: (T) -> R): List<R>", "List<R>", 2);
	count = add_member(buf, count, "flatMap", "fun <R> flatMap(transform: (T) -> Iterable<R>): List<R>", "List<R>", 2);
	count = add_member(buf, count, "forEach", "fun forEach(action: (T) -> Unit)", "Unit", 2);
	count = add_member(buf, count, "sorted", "fun sorted(): List<T>", "List<T>", 2);
	count = add_member(buf, count, "sortedBy", "fun <R> sortedBy(selector: (T) -> R?): List<T>", "List<T>", 2);
	count = add_member(buf, count, "reversed", "fun reversed(): List<T>", "List<T>", 2);
	count = add_member(buf, count, "distinct", "fun distinct(): List<T>", "List<T>", 2);
	count = add_member(buf, count, "take", "fun take(n: Int): List<T>", "List<T>", 2);
	count = add_member(buf, count, "drop", "fun drop(n: Int): List<T>", "List<T>", 2);
	count = add_member(buf, count, "joinToString", "fun joinToString(separator: CharSequence): String", "String", 2);
	count = add_member(buf, count, "toList", "fun toList(): List<T>", "List<T>", 2);
	count = add_member(buf, count, "toMutableList", "fun toMutableList(): MutableList<T>", "MutableList<T>", 2);
	count = add_member(buf, count, "toSet", "fun toSet(): Set<T>", "Set<T>", 2);
	count = add_member(buf, count, "asSequence", "fun asSequence(): Sequence<T>", "Sequence<T>", 2);
	count = add_member(buf, count, "sumOf", "fun sumOf(selector: (T) -> Int): Int", "Int", 2);

	if (type_name == "MutableList" || type_name == "MutableSet" || type_name == "MutableCollection") {
		count = add_member(buf, count, "add", "fun add(element: T): Boolean", "Boolean", 2);
		count = add_member(buf, count, "remove", "fun remove(element: T): Boolean", "Boolean", 2);
		count = add_member(buf, count, "clear", "fun clear()", "Unit", 2);
	}
	if (type_name == "List" || type_name == "MutableList") {
		count = add_member(buf, count, "get", "operator fun get(index: Int): T", "T", 2);
		count = add_member(buf, count, "subList", "fun subList(fromIndex: Int, toIndex: Int): List<T>", "List<T>", 2);
	}
	return count;
}

fn usz add_map_members(MemberInfo[] buf, usz count, String type_name) {
	count = add_member(buf, count, "size", "val size: Int", "Int", 10);
	count = add_member(buf, count, "isEmpty", "fun isEmpty(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "isNotEmpty", "fun isNotEmpty(): Boolean", "Boolean", 2);
	count = add_member(buf, count, "containsKey", "fun containsKey(key: K): Boolean", "Boolean", 2);
	count = add_member(buf, count, "containsValue", "fun containsValue(value: V): Boolean", "Boolean", 2);
	count = add_member(buf, count, "get", "operator fun get(key: K): V?", "V?", 2);
	count = add_member(buf, count, "getOrDefault", "fun getOrDefault(key: K, defaultValue: V): V", "V", 2);
	count = add_member(buf, count, "keys", "val keys: Set<K>", "Set<K>", 10);
	count = add_member(buf, count, "values", "val values: Collection<V>", "Collection<V>", 10);
	count = add_member(buf, count, "entries", "val entries: Set<Map.Entry<K, V>>", "Set<Map.Entry<K, V>>", 10);
	count = add_member(buf, count, "filter", "fun filter(predicate: (Map.Entry<K, V>) -> Boolean): Map<K, V>", "Map<K, V>", 2);
	count = add_member(buf, count, "map", "fun <R> map(transform: (Map.Entry<K, V>) -> R): List<R>", "List<R>", 2);
	count = add_member(buf, count, "forEach", "fun forEach(action: (K, V) -> Unit)", "Unit", 2);
	count = add_member(buf, count, "toList", "fun toList(): List<Pair<K, V>>", "List<Pair<K, V>>", 2);
	count = add_member(buf, count, "toMutableMap", "fun toMutableMap(): MutableMap<K, V>", "MutableMap<K, V>", 2);
	count = add_member(buf, count, "count", "fun count(): Int", "Int", 2);

	if (type_name == "MutableMap" || type_name == "HashMap" || type_name == "LinkedHashMap") {
		count = add_member(buf, count, "put", "fun put(key: K, value: V): V?", "V?", 2);
		count = add_member(buf, count, "remove", "fun remove(key: K): V?", "V?", 2);
		count = add_member(buf, count, "clear", "fun clear()", "Unit", 2);
		count = add_member(buf, count, "getOrPut", "fun getOrPut(key: K, defaultValue: () -> V): V", "V", 2);
	}
	return count;
}
