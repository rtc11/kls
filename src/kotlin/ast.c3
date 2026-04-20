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
	CALLABLE_REF_EXPR,   // ::name or Type::name -- name in name field
	STRING_TEMPLATE_EXPR,// "...$x...${expr}..."
	OBJECT_EXPR,         // object : Type { body }
	SPREAD_EXPR,         // *array
	TYPE_CHECK_EXPR,     // expr is Type / expr !is Type
	TYPE_CAST_EXPR,      // expr as Type / expr as? Type

	// Error recovery
	ERROR_NODE,
}

// ── Modifier flags (bitfield) ──────────────────────────────────────

const uint MOD_NONE        = 0;
const uint MOD_ABSTRACT    = 1 << 0;
const uint MOD_OPEN        = 1 << 1;
const uint MOD_FINAL       = 1 << 2;
const uint MOD_SEALED      = 1 << 3;
const uint MOD_DATA        = 1 << 4;
const uint MOD_ENUM        = 1 << 5;
const uint MOD_INNER       = 1 << 6;
const uint MOD_ANNOTATION  = 1 << 7;
const uint MOD_VALUE       = 1 << 8;
const uint MOD_INLINE      = 1 << 9;
const uint MOD_INFIX       = 1 << 10;
const uint MOD_OPERATOR    = 1 << 11;
const uint MOD_SUSPEND     = 1 << 12;
const uint MOD_TAILREC     = 1 << 13;
const uint MOD_OVERRIDE    = 1 << 14;
const uint MOD_LATEINIT    = 1 << 15;
const uint MOD_CONST       = 1 << 16;
const uint MOD_EXTERNAL    = 1 << 17;
const uint MOD_PRIVATE     = 1 << 18;
const uint MOD_PROTECTED   = 1 << 19;
const uint MOD_INTERNAL    = 1 << 20;
const uint MOD_PUBLIC      = 1 << 21;
const uint MOD_EXPECT      = 1 << 22;
const uint MOD_ACTUAL      = 1 << 23;
const uint MOD_VARARG      = 1 << 24;
const uint MOD_COMPANION   = 1 << 25;
const uint MOD_NOINLINE    = 1 << 26;
const uint MOD_CROSSINLINE = 1 << 27;
const uint MOD_REIFIED     = 1 << 28;
const uint MOD_VAR         = 1 << 29;  // property declared with 'var' (mutable)
const uint MOD_IN          = 1 << 30;  // type parameter variance: in
const uint MOD_OUT         = 1u << 31; // type parameter variance: out

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
	uint mod_flags;

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
