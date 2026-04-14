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
	TYPE_REF,
	BLOCK,

	// Statements / expressions (inside blocks)
	IF_EXPR,
	WHEN_EXPR,
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
	String extra_text;
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

faultdef NOT_FOUND;

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
