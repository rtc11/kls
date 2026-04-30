module kls::kotlin::ast;

// ── AST node kinds ─────────────────────────────────────────────────

enum NodeKind : int {
	// Top-level structure
	FILE,
	PACKAGE_DECL,
	IMPORT_DECL,

	// Declarations
	CLASS_DECL,
	INTERFACE_DECL,
	OBJECT_DECL,
	COMPANION_OBJECT_DECL,
	FUN_DECL,
	PROPERTY_DECL,
	TYPEALIAS_DECL,
	CONSTRUCTOR_DECL,
	INIT_BLOCK,
	ENUM_ENTRY,

	// Structural
	PARAM,
	TYPE_PARAM,
	TYPE_ARG,            // type argument at use site: Int in List<Int>, * for star projection
	WHERE_CONSTRAINT,    // where clause constraint: T : Comparable<T>
	TYPE_REF,
	BLOCK,

	// Statements / expressions (inside blocks)
	IF_EXPR,
	WHEN_EXPR,
	WHEN_ENTRY,       // a single branch: condition(s) -> body
	FOR_STMT,
	WHILE_STMT,
	DO_WHILE_STMT,
	TRY_EXPR,
	CATCH_CLAUSE,
	RETURN_EXPR,
	THROW_EXPR,
	BREAK_EXPR,
	CONTINUE_EXPR,

	// Expression nodes (Pratt parser)
	NAME_EXPR,           // simple identifier reference
	LITERAL_EXPR,        // integer, float, string, char, boolean, null
	THIS_EXPR,           // this / this@label
	SUPER_EXPR,          // super / super@label / super<Type>
	PAREN_EXPR,          // (expr)
	CALL_EXPR,           // expr(args) -- name in name field if simple call
	DOT_EXPR,            // expr.name / expr?.name -- member name in name field
	INDEX_EXPR,          // expr[index]
	PREFIX_EXPR,         // -expr, !expr, ++expr, --expr -- operator in extra_text
	POSTFIX_EXPR,        // expr++, expr--, expr!! -- operator in extra_text
	BINARY_EXPR,         // expr op expr -- operator in extra_text
	ASSIGNMENT_EXPR,     // expr = expr, expr += expr -- operator in extra_text
	LAMBDA_EXPR,         // { params -> body } or { body }
	ANONYMOUS_FUN_EXPR,  // fun(params): T { body } / fun(params) = expr -- expression form
	CALLABLE_REF_EXPR,   // ::name or Type::name -- name in name field
	STRING_TEMPLATE_EXPR,// "...$x...${expr}..."
	OBJECT_EXPR,         // object : Type { body }
	SPREAD_EXPR,         // *array
	TYPE_CHECK_EXPR,     // expr is Type / expr !is Type
	TYPE_CAST_EXPR,      // expr as Type / expr as? Type

	// Annotations (children of declarations or FILE)
	ANNOTATION_ENTRY,    // @Foo / @Foo("x") / @get:JvmName("y") / @[A B] expanded as siblings

	// Call argument wrapper (child of CALL_EXPR for each parenthesized arg).
	// Trailing lambdas are also wrapped in VALUE_ARGUMENT with extra_text == "trailing"
	// to distinguish them from parenthesized args. Use `find_call_for_lambda` to walk
	// from a LAMBDA_EXPR up to its enclosing CALL_EXPR (handles both forms).
	// `name` field = arg name (empty if positional), `extra_text` = "*" if spread,
	// "trailing" if trailing lambda, else "".
	// Has exactly 1 child: the argument expression.
	VALUE_ARGUMENT,

	// Error recovery
	ERROR_NODE,
}

// ── Modifier flags (bitfield) ──────────────────────────────────────

const ulong MOD_NONE         = 0;
const ulong MOD_ABSTRACT     = 1ul << 0;
const ulong MOD_OPEN         = 1ul << 1;
const ulong MOD_FINAL        = 1ul << 2;
const ulong MOD_SEALED       = 1ul << 3;
const ulong MOD_DATA         = 1ul << 4;
const ulong MOD_ENUM         = 1ul << 5;
const ulong MOD_INNER        = 1ul << 6;
const ulong MOD_ANNOTATION   = 1ul << 7;
const ulong MOD_VALUE        = 1ul << 8;
const ulong MOD_INLINE       = 1ul << 9;
const ulong MOD_INFIX        = 1ul << 10;
const ulong MOD_OPERATOR     = 1ul << 11;
const ulong MOD_SUSPEND      = 1ul << 12;
const ulong MOD_TAILREC      = 1ul << 13;
const ulong MOD_OVERRIDE     = 1ul << 14;
const ulong MOD_LATEINIT     = 1ul << 15;
const ulong MOD_CONST        = 1ul << 16;
const ulong MOD_EXTERNAL     = 1ul << 17;
const ulong MOD_PRIVATE      = 1ul << 18;
const ulong MOD_PROTECTED    = 1ul << 19;
const ulong MOD_INTERNAL     = 1ul << 20;
const ulong MOD_PUBLIC       = 1ul << 21;
const ulong MOD_EXPECT       = 1ul << 22;
const ulong MOD_ACTUAL       = 1ul << 23;
const ulong MOD_VARARG       = 1ul << 24;
const ulong MOD_COMPANION    = 1ul << 25;
const ulong MOD_NOINLINE     = 1ul << 26;
const ulong MOD_CROSSINLINE  = 1ul << 27;
const ulong MOD_REIFIED      = 1ul << 28;
const ulong MOD_VAR          = 1ul << 29;  // property declared with 'var' (mutable)
const ulong MOD_IN           = 1ul << 30;  // type parameter variance: in
const ulong MOD_OUT          = 1ul << 31; // type parameter variance: out
const ulong MOD_FUN_INTERFACE = 1ul << 32; // interface declared with preceding 'fun'

// ── AST node ───────────────────────────────────────────────────────

struct AstNode {
	NodeKind kind;

	// Span: full range of this node (start of modifiers/keyword to end of body)
	uint start_offset;
	uint end_offset;
	uint start_line;
	uint start_col;
	uint end_line;
	uint end_col;

	// Name (for declarations): slice into source
	String name;
	uint name_offset;
	uint name_line;
	uint name_col;
	uint name_len;

	// Children: linked via parent index
	uint parent;          // index of parent node (NO_PARENT for root FILE node)
	uint child_count;     // number of direct children
	uint children_start;  // first index where children may appear (set by adopt_children)

	// Modifier flags (bitfield)
	ulong mod_flags;

	// Type text: for properties, function return types, typealias targets
	// Slice into source covering the type annotation text
	String type_text;

	// For IMPORT_DECL: the full import path text
	// For PACKAGE_DECL: the full package path text
	// For FUN_DECL / PROPERTY_DECL: receiver type text (extension declarations)
	String extra_text;

	// Annotation names: space-separated simple names from @-annotations
	// e.g. "@Test @Ignore" → "Test Ignore", "@org.junit.Test" → "Test"
	String annotation_text;
}

// ── Parse error ────────────────────────────────────────────────────

struct ParseError {
	String message;
	uint line;
	uint col;
	uint offset;
	uint len;
}

// ── Parse result ───────────────────────────────────────────────────

const uint NO_PARENT = uint.max;
const usz MAX_NODES = 16384;
const usz MAX_ERRORS = 256;
// Last slot is reserved as overflow sink -- writes go there when the array is full,
// preventing out-of-bounds access. Real nodes use indices 0..MAX_NODES-2.
const uint OVERFLOW_NODE = (uint)(MAX_NODES - 1);

struct ParseResult {
	AstNode[MAX_NODES] nodes;
	uint node_count;
	ParseError[MAX_ERRORS] errors;
	usz error_count;
	bool is_script;  // true for .kts files (top-level statements allowed)
}

// ── AST query helpers ──────────────────────────────────────────────

/**
 * Get the index of a parent node within the nodes array.
 */
fn uint node_index(ParseResult* result, AstNode* node) {
	return (uint)(node - &result.nodes[0]);
}

/**
 * Get the Nth direct child of a node (0-indexed).
 * Returns null if n >= child_count.
 */
fn AstNode*? get_child(ParseResult* result, AstNode* parent, uint n) {
	if (n >= parent.child_count) return NOT_FOUND~;
	uint parent_idx = node_index(result, parent);
	uint count = 0;
	for (uint i = parent.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == parent_idx) {
			if (count == n) {
				return &result.nodes[i];
			}
			count++;
		}
	}
	return NOT_FOUND~;
}

/**
 * Find the first child of a given kind, or fault.
 */
fn AstNode*? find_child(ParseResult* result, AstNode* parent, NodeKind kind) {
	if (parent.child_count == 0) return NOT_FOUND~;
	uint parent_idx = node_index(result, parent);
	for (uint i = parent.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == parent_idx && result.nodes[i].kind == kind) {
			return &result.nodes[i];
		}
	}
	return NOT_FOUND~;
}

/**
 * Iterate over direct children of a node, calling a callback.
 * count_of_kind returns the number of direct children matching a given kind.
 */
fn uint count_children_of_kind(ParseResult* result, AstNode* parent, NodeKind kind) {
	uint parent_idx = node_index(result, parent);
	uint count = 0;
	for (uint i = parent.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == parent_idx && result.nodes[i].kind == kind) {
			count++;
		}
	}
	return count;
}

/**
 * Check if a node is a declaration kind.
 */
fn bool is_declaration(NodeKind kind) {
	switch (kind) {
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
		case FUN_DECL:
		case PROPERTY_DECL:
		case TYPEALIAS_DECL:
		case CONSTRUCTOR_DECL:
		case INIT_BLOCK:
		case ENUM_ENTRY:
			return true;
		default:
			return false;
	}
}

/**
 * Map AST NodeKind to LSP SymbolKind number.
 */
fn int to_lsp_symbol_kind(NodeKind kind) {
	switch (kind) {
		case FUN_DECL:              return 12; // Function
		case CLASS_DECL:            return 5;  // Class
		case INTERFACE_DECL:        return 11; // Interface
		case OBJECT_DECL:           return 2;  // Module
		case COMPANION_OBJECT_DECL: return 2;  // Module
		case PROPERTY_DECL:         return 7;  // Property
		case TYPEALIAS_DECL:        return 5;  // Class (no TypeAlias in LSP)
		case CONSTRUCTOR_DECL:      return 9;  // Constructor
		case INIT_BLOCK:            return 12; // Function
		case ENUM_ENTRY:            return 22; // EnumMember
		default:                    return 0;
	}
}

/**
 * Check if a node kind is an expression.
 */
fn bool is_expression(NodeKind kind) {
	switch (kind) {
		case NAME_EXPR:
		case LITERAL_EXPR:
		case THIS_EXPR:
		case SUPER_EXPR:
		case PAREN_EXPR:
		case CALL_EXPR:
		case DOT_EXPR:
		case INDEX_EXPR:
		case PREFIX_EXPR:
		case POSTFIX_EXPR:
		case BINARY_EXPR:
		case ASSIGNMENT_EXPR:
		case LAMBDA_EXPR:
		case ANONYMOUS_FUN_EXPR:
		case CALLABLE_REF_EXPR:
		case STRING_TEMPLATE_EXPR:
		case OBJECT_EXPR:
		case SPREAD_EXPR:
		case TYPE_CHECK_EXPR:
		case TYPE_CAST_EXPR:
		case IF_EXPR:
		case WHEN_EXPR:
		case TRY_EXPR:
			return true;
		default:
			return false;
	}
}

faultdef NOT_FOUND;

/**
 * Check if a node has a specific annotation (by simple name).
 * Searches the space-separated annotation_text for an exact word match.
 */
fn bool AstNode.has_annotation(AstNode* self, String name) {
	if (self.annotation_text.len == 0 || name.len == 0) return false;
	String text = self.annotation_text;
	usz i = 0;
	while (i < text.len) {
		// Skip leading spaces
		while (i < text.len && text[i] == ' ') i++;
		if (i >= text.len) break;
		// Find end of word
		usz start = i;
		while (i < text.len && text[i] != ' ') i++;
		String word = text[start:i - start];
		if (word == name) return true;
	}
	return false;
}

/**
 * Check whether parent has direct ANNOTATION_ENTRY child with matching
 * simple name. Uses annotation sub-AST; use-site targets live in type_text
 * and do not affect simple-name matching.
 */
fn bool has_annotation_ast(ParseResult* result, uint parent_idx, String simple_name) {
	if (parent_idx >= result.node_count || simple_name.len == 0) return false;
	AstNode* parent = &result.nodes[parent_idx];
	if (parent.child_count == 0) return false;
	for (uint i = parent.children_start; i < result.node_count; i++) {
		AstNode* child = &result.nodes[i];
		if (child.parent != parent_idx) continue;
		if (child.kind != ANNOTATION_ENTRY) continue;
		if (child.name == simple_name) return true;
	}
	return false;
}

/**
 * Find the first ANNOTATION_ENTRY child whose simple name matches.
 * Returns null fault if not found. Searches across all entries (handles
 * cases where multiple annotations are attached to the same declaration).
 */
fn AstNode*? find_annotation(ParseResult* result, AstNode* parent, String simple_name) {
	if (parent.child_count == 0) return NOT_FOUND~;
	uint parent_idx = node_index(result, parent);
	for (uint i = parent.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == parent_idx
			&& result.nodes[i].kind == ANNOTATION_ENTRY
			&& result.nodes[i].name == simple_name) {
			return &result.nodes[i];
		}
	}
	return NOT_FOUND~;
}

/**
 * Get the use-site target of an ANNOTATION_ENTRY (e.g. "get", "set", "field",
 * "param", "property", "receiver", "setparam", "delegate", "file").
 * Returns empty string if no target was specified.
 */
fn String AstNode.annotation_target(AstNode* self) {
	if (self.kind != ANNOTATION_ENTRY) return "";
	return self.type_text;
}

// ── Call argument helpers ──────────────────────────────────────────

/**
 * Count VALUE_ARGUMENT children of a CALL_EXPR. Excludes trailing lambdas
 * (which are direct LAMBDA_EXPR children, not wrapped in VALUE_ARGUMENT).
 */
fn uint count_call_args(ParseResult* result, uint call_idx) {
	if (call_idx >= result.node_count) return 0;
	AstNode* call = &result.nodes[call_idx];
	if (call.child_count == 0) return 0;
	uint count = 0;
	for (uint i = call.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == call_idx
			&& result.nodes[i].kind == VALUE_ARGUMENT) {
			count++;
		}
	}
	return count;
}

/**
 * Get the expression child of a VALUE_ARGUMENT node, or NOT_FOUND.
 * VALUE_ARGUMENT always has exactly 1 child: the argument expression.
 */
fn AstNode*? get_arg_expr(ParseResult* result, uint value_arg_idx) {
	if (value_arg_idx >= result.node_count) return NOT_FOUND~;
	AstNode* va = &result.nodes[value_arg_idx];
	if (va.kind != VALUE_ARGUMENT || va.child_count == 0) return NOT_FOUND~;
	for (uint i = va.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == value_arg_idx) {
			return &result.nodes[i];
		}
	}
	return NOT_FOUND~;
}

/**
 * Get the expression child index of a VALUE_ARGUMENT node, or uint.max.
 */
fn uint get_arg_expr_idx(ParseResult* result, uint value_arg_idx) {
	if (value_arg_idx >= result.node_count) return uint.max;
	AstNode* va = &result.nodes[value_arg_idx];
	if (va.kind != VALUE_ARGUMENT || va.child_count == 0) return uint.max;
	for (uint i = va.children_start; i < result.node_count; i++) {
		if (result.nodes[i].parent == value_arg_idx) {
			return i;
		}
	}
	return uint.max;
}

/**
 * Whether a VALUE_ARGUMENT is named (has `name = expr` form). Returns
 * the name slice, empty string if positional.
 */
fn String arg_name(AstNode* value_arg) {
	if (value_arg.kind != VALUE_ARGUMENT) return "";
	return value_arg.name;
}

/**
 * Whether a VALUE_ARGUMENT is a spread (`*expr`).
 */
fn bool arg_is_spread(AstNode* value_arg) {
	if (value_arg.kind != VALUE_ARGUMENT) return false;
	return value_arg.extra_text == "*";
}

// ── PARAM helpers ──────────────────────────────────────────────────

/**
 * Get the source slice of a parameter's default value expression
 * (the text after `=`), or empty if no default. Stored in PARAM.extra_text
 * during parsing.
 */
fn String param_default_text(AstNode* param) {
	if (param.kind != PARAM) return "";
	return param.extra_text;
}

/**
 * Whether a PARAM has a default value.
 */
fn bool param_has_default(AstNode* param) {
	if (param.kind != PARAM) return false;
	return param.extra_text.len > 0;
}

/**
 * Get child node index of PARAM default expression, or NO_PARENT.
 * PARAM children are ordered as optional TYPE_REF first, then adopted
 * default-expression sub-AST roots.
 */
fn uint param_default_expr(ParseResult* result, uint param_idx) {
	if (param_idx >= result.node_count) return NO_PARENT;
	AstNode* param = &result.nodes[param_idx];
	if (param.kind != PARAM || param.child_count == 0) return NO_PARENT;
	for (uint i = param.children_start; i < result.node_count; i++) {
		AstNode* child = &result.nodes[i];
		if (child.parent != param_idx) continue;
		if (child.kind == TYPE_REF) continue;
		return i;
	}
	return NO_PARENT;
}

/**
 * Get child node index of supertype delegate expression, or NO_PARENT.
 * Supertype TYPE_REF may have delegate expression child tagged with
 * extra_text == "delegate".
 */
fn uint supertype_delegate_expr(ParseResult* result, uint type_ref_idx) {
	if (type_ref_idx >= result.node_count) return NO_PARENT;
	AstNode* type_ref = &result.nodes[type_ref_idx];
	if (type_ref.kind != TYPE_REF || type_ref.child_count == 0) return NO_PARENT;
	for (uint i = type_ref.children_start; i < result.node_count; i++) {
		AstNode* child = &result.nodes[i];
		if (child.parent != type_ref_idx) continue;
		if (child.extra_text == "delegate") return i;
	}
	return NO_PARENT;
}

/**
 * True if parent has direct child tagged with extra_text == "delegate".
 */
fn bool has_delegate_child(ParseResult* result, uint parent_idx) {
	if (parent_idx >= result.node_count) return false;
	AstNode* parent = &result.nodes[parent_idx];
	if (parent.child_count == 0) return false;
	for (uint i = parent.children_start; i < result.node_count; i++) {
		AstNode* child = &result.nodes[i];
		if (child.parent != parent_idx) continue;
		if (child.extra_text == "delegate") return true;
	}
	return false;
}

/**
 * Walk up from a LAMBDA_EXPR (by index) to its enclosing CALL_EXPR.
 * Handles both forms:
 *   - Direct child of CALL_EXPR (legacy synthesized form)
 *   - Wrapped in VALUE_ARGUMENT (parenthesized arg or trailing lambda)
 * Returns the CALL_EXPR index, or NO_PARENT if no enclosing call.
 */
fn uint find_call_for_lambda(ParseResult* result, uint lambda_idx) {
	if (lambda_idx >= result.node_count) return NO_PARENT;
	uint parent = result.nodes[lambda_idx].parent;
	if (parent == NO_PARENT) return NO_PARENT;
	if (result.nodes[parent].kind == CALL_EXPR) return parent;
	if (result.nodes[parent].kind == VALUE_ARGUMENT) {
		uint gp = result.nodes[parent].parent;
		if (gp != NO_PARENT && result.nodes[gp].kind == CALL_EXPR) return gp;
	}
	return NO_PARENT;
}

// ── Incremental parsing: node array manipulation ───────────────────

/**
 * Check if a NodeKind is a class-like declaration that can contain members.
 */
fn bool is_class_like(NodeKind kind) {
	switch (kind) {
		case CLASS_DECL:
		case INTERFACE_DECL:
		case OBJECT_DECL:
		case COMPANION_OBJECT_DECL:
			return true;
		default:
			return false;
	}
}

/**
 * Shift all parent indices and children_start fields in [from_idx..node_count)
 * by `delta` (which may be negative, cast to int). Used when nodes are
 * inserted or removed from the middle of the flat array.
 *
 * Also updates parent references that point at or beyond from_idx.
 */
fn void ParseResult.shift_indices(ParseResult* self, uint from_idx, int delta) {
	for (uint i = 0; i < self.node_count; i++) {
		// Shift parent references that point at or beyond from_idx
		if (self.nodes[i].parent != NO_PARENT && self.nodes[i].parent >= from_idx) {
			int new_parent = (int)self.nodes[i].parent + delta;
			self.nodes[i].parent = new_parent >= 0 ? (uint)new_parent : NO_PARENT;
		}
		// Shift children_start that points at or beyond from_idx
		if (self.nodes[i].children_start >= from_idx && self.nodes[i].child_count > 0) {
			int new_start = (int)self.nodes[i].children_start + delta;
			self.nodes[i].children_start = new_start >= 0 ? (uint)new_start : 0;
		}
	}
}

/**
 * Shift byte offsets, line numbers, and column numbers for all nodes
 * in [from_idx..to_idx) by the given deltas. Used after an incremental
 * edit to adjust nodes that come after the edited region.
 *
 * For nodes whose start_line == edit_line (same line as edit end),
 * the column is also adjusted by col_delta.
 */
fn void ParseResult.shift_offsets(ParseResult* self, uint from_idx, uint to_idx,
		int byte_delta, int line_delta, int col_delta, uint edit_end_line) {
	if (to_idx > self.node_count) to_idx = self.node_count;
	for (uint i = from_idx; i < to_idx; i++) {
		AstNode* n = &self.nodes[i];
		// Shift start position
		n.start_offset = (uint)((int)n.start_offset + byte_delta);
		n.start_line = (uint)((int)n.start_line + line_delta);
		if (line_delta == 0 && n.start_line == edit_end_line) {
			n.start_col = (uint)((int)n.start_col + col_delta);
		}
		// Shift end position
		n.end_offset = (uint)((int)n.end_offset + byte_delta);
		n.end_line = (uint)((int)n.end_line + line_delta);
		if (line_delta == 0 && n.end_line == edit_end_line) {
			n.end_col = (uint)((int)n.end_col + col_delta);
		}
		// Shift name position
		if (n.name.len > 0) {
			n.name_offset = (uint)((int)n.name_offset + byte_delta);
			n.name_line = (uint)((int)n.name_line + line_delta);
			if (line_delta == 0 && n.name_line == edit_end_line) {
				n.name_col = (uint)((int)n.name_col + col_delta);
			}
		}
	}
}

/**
 * Move a block of nodes within the flat array. Copies nodes[src..src+count)
 * to nodes[dst..dst+count). Handles overlapping regions correctly.
 */
fn void ParseResult.move_nodes(ParseResult* self, uint dst, uint src, uint count) {
	if (count == 0 || dst == src) return;
	if (dst < src) {
		for (uint i = 0; i < count; i++) {
			self.nodes[dst + i] = self.nodes[src + i];
		}
	} else {
		for (uint i = count; i > 0; i--) {
			self.nodes[dst + i - 1] = self.nodes[src + i - 1];
		}
	}
}

/**
 * Free heap-allocated error messages inside a ParseResult.
 * Must be called before freeing the ParseResult itself.
 */
fn void ParseResult.free_errors(ParseResult* self) {
	for (usz i = 0; i < self.error_count; i++) {
		if (self.errors[i].message.len > 0) {
			mem::free(self.errors[i].message.ptr);
		}
	}
	self.error_count = 0;
}
