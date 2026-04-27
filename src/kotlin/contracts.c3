module kls::kotlin::contracts;

import kls::kotlin::ast;

// ── Kotlin contracts DSL effects ───────────────────────────────────
//
// Models the three effect kinds from `kotlin.contracts` (Kotlin 1.9):
//
//   1. `returns() implies (cond)`         — RETURNS_IMPLIES, rv = ANY_RETURN
//   2. `returns(true|false|null) implies (cond)` — RETURNS_IMPLIES, rv = RETURN_*
//   3. `callsInPlace(lambda, KIND)`       — CALLS_IN_PLACE
//
// Two discovery paths:
//   - `lookup_stdlib_contracts(name, receiver)` — hardcoded table for
//     well-known stdlib symbols (`requireNotNull`, `isNullOrEmpty`, …).
//     Avoids re-parsing kotlin-stdlib source.
//   - `extract_user_contracts(pr, fun_decl_idx, out)` — walks the first
//     statement of a FUN_DECL's BLOCK, recognizes a `contract { … }`
//     call, then decodes effect statements lazily from the existing AST
//     (no new node kinds required).

enum ContractEffectKind : int {
	RETURNS_IMPLIES,
	CALLS_IN_PLACE,
}

enum InvocationKind : int {
	UNKNOWN_KIND,
	AT_MOST_ONCE,
	AT_LEAST_ONCE,
	EXACTLY_ONCE,
}

enum ReturnValue : int {
	ANY_RETURN,    // returns()
	RETURN_TRUE,   // returns(true)
	RETURN_FALSE,  // returns(false)
	RETURN_NULL,   // returns(null)
}

// Predicate kinds the consumer understands. These mirror the small
// subset of expressions that `flow.c3` already extracts from `if`
// conditions, so a contract's predicate folds back into the same
// transfer functions after argument substitution.
enum PredKind : int {
	PRED_NONE,
	PRED_NOT_NULL,    // (param != null)  →  param non-null
	PRED_IS_NULL,     // (param == null)
	PRED_IS_TYPE,     // (param is T)     →  param narrowed to T
	PRED_IS_NOT_TYPE, // (param !is T)
	PRED_BOOL_PARAM,  // bare `param` boolean       → param == true
	PRED_NOT_BOOL,    // !param                     → param == false
}

// Identifies which formal the predicate references.
//   - kind = TARGET_PARAM  → param_index is the 0-based parameter index
//   - kind = TARGET_RECEIVER → `this@name` / extension receiver
enum PredTargetKind : int {
	TARGET_PARAM,
	TARGET_RECEIVER,
}

struct PredTarget {
	PredTargetKind kind;
	uint param_index;
}

struct ContractEffect {
	ContractEffectKind kind;

	// RETURNS_IMPLIES fields ─────────────────────────────────────
	ReturnValue rv;
	PredKind pred;
	PredTarget target;
	String type_text;        // for PRED_IS_TYPE / PRED_IS_NOT_TYPE

	// CALLS_IN_PLACE fields ──────────────────────────────────────
	uint cip_param_index;    // which lambda parameter
	InvocationKind ik;
}

// ── Stdlib contract table ──────────────────────────────────────────

// One stdlib row. `receiver` is "" for top-level fns. Multiple rows per
// name are allowed when overloads carry different contracts.
struct StdlibContractRow {
	String name;
	String receiver;          // "" / "T" / "CharSequence?" / "Collection<T>?" …
	ContractEffect effect;
}

// Hardcoded for well-known symbols. Kept tiny and additive — extend when
// new stdlib helpers prove worth narrowing.
const StdlibContractRow[*] STDLIB_CONTRACTS = {
	// requireNotNull(value): returns() implies (value != null)
	{ "requireNotNull", "", {
		.kind = RETURNS_IMPLIES, .rv = ANY_RETURN,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_PARAM, .param_index = 0 },
	} },
	// checkNotNull(value): returns() implies (value != null)
	{ "checkNotNull", "", {
		.kind = RETURNS_IMPLIES, .rv = ANY_RETURN,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_PARAM, .param_index = 0 },
	} },
	// require(value): returns() implies (value)  -- `value` here is Boolean
	{ "require", "", {
		.kind = RETURNS_IMPLIES, .rv = ANY_RETURN,
		.pred = PRED_BOOL_PARAM,
		.target = { .kind = TARGET_PARAM, .param_index = 0 },
	} },
	// check(value): returns() implies (value)
	{ "check", "", {
		.kind = RETURNS_IMPLIES, .rv = ANY_RETURN,
		.pred = PRED_BOOL_PARAM,
		.target = { .kind = TARGET_PARAM, .param_index = 0 },
	} },
	// CharSequence?.isNullOrEmpty(): returns(false) implies (this != null)
	{ "isNullOrEmpty", "CharSequence?", {
		.kind = RETURNS_IMPLIES, .rv = RETURN_FALSE,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_RECEIVER, .param_index = 0 },
	} },
	{ "isNullOrEmpty", "String?", {
		.kind = RETURNS_IMPLIES, .rv = RETURN_FALSE,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_RECEIVER, .param_index = 0 },
	} },
	{ "isNullOrEmpty", "Collection<T>?", {
		.kind = RETURNS_IMPLIES, .rv = RETURN_FALSE,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_RECEIVER, .param_index = 0 },
	} },
	// CharSequence?.isNullOrBlank(): returns(false) implies (this != null)
	{ "isNullOrBlank", "CharSequence?", {
		.kind = RETURNS_IMPLIES, .rv = RETURN_FALSE,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_RECEIVER, .param_index = 0 },
	} },
	{ "isNullOrBlank", "String?", {
		.kind = RETURNS_IMPLIES, .rv = RETURN_FALSE,
		.pred = PRED_NOT_NULL,
		.target = { .kind = TARGET_RECEIVER, .param_index = 0 },
	} },
	// Scope functions: callsInPlace(block, EXACTLY_ONCE).
	// `let`/`also`/`apply`/`takeIf`/`takeUnless`/`run` (extension) take the
	// lambda as positional arg 0 (extension receiver isn't a value arg).
	// `run` (top-level) takes the lambda as arg 0.
	// `with(receiver, block)` takes the lambda as arg 1.
	// cip_param_index here uses the call-site value-argument position so
	// flow.c3 can resolve the lambda from CALL_EXPR children directly.
	{ "let",        "", { .kind = CALLS_IN_PLACE, .cip_param_index = 0, .ik = EXACTLY_ONCE } },
	{ "also",       "", { .kind = CALLS_IN_PLACE, .cip_param_index = 0, .ik = EXACTLY_ONCE } },
	{ "apply",      "", { .kind = CALLS_IN_PLACE, .cip_param_index = 0, .ik = EXACTLY_ONCE } },
	{ "run",        "", { .kind = CALLS_IN_PLACE, .cip_param_index = 0, .ik = EXACTLY_ONCE } },
	{ "with",       "", { .kind = CALLS_IN_PLACE, .cip_param_index = 1, .ik = EXACTLY_ONCE } },
	{ "takeIf",     "", { .kind = CALLS_IN_PLACE, .cip_param_index = 0, .ik = EXACTLY_ONCE } },
	{ "takeUnless", "", { .kind = CALLS_IN_PLACE, .cip_param_index = 0, .ik = EXACTLY_ONCE } },
};

faultdef NOT_FOUND;

/**
 * Find the first stdlib contract matching `name`. Receiver is currently
 * not used for disambiguation — most overloads carry the same effect.
 * Caller iterates results with `next_stdlib_contract`.
 */
fn ContractEffect? lookup_stdlib_contract(String name) {
	foreach (&row : STDLIB_CONTRACTS) {
		if (row.name == name) return row.effect;
	}
	return NOT_FOUND~;
}

/**
 * Iterate all stdlib contracts for `name`. Writes up to `out.len`
 * effects into `out`, returns count written.
 */
fn usz collect_stdlib_contracts(String name, ContractEffect[] out) {
	usz n = 0;
	foreach (&row : STDLIB_CONTRACTS) {
		if (n >= out.len) break;
		if (row.name == name) { out[n] = row.effect; n++; }
	}
	return n;
}

// ── User-defined contract extraction ───────────────────────────────

/**
 * Walk a FUN_DECL, find a `contract { … }` call as the first statement
 * of its body, and decode each statement of the contract lambda into
 * one or more `ContractEffect`s. Writes up to `out.len`, returns count.
 *
 * No new AST nodes required: the parser already produces:
 *   CALL_EXPR("contract") — child[0..n-2] = VALUE_ARGUMENTs, last child
 *     either VALUE_ARGUMENT(extra="trailing") wrapping LAMBDA_EXPR or a
 *     direct LAMBDA_EXPR. Inside the lambda BLOCK each top-level stmt is
 *     either:
 *       BINARY_EXPR(op="implies", left=CALL_EXPR("returns"…), right=predicate)
 *       CALL_EXPR("callsInPlace", args=[NAME, NAME])
 */
fn usz extract_user_contracts(ast::ParseResult* pr, uint fun_decl_idx, ContractEffect[] out) {
	if (out.len == 0) return 0;
	if (fun_decl_idx >= pr.node_count) return 0;
	ast::AstNode* fd = &pr.nodes[fun_decl_idx];
	if (fd.kind != FUN_DECL && fd.kind != CONSTRUCTOR_DECL) return 0;

	// Find BLOCK child of the function declaration.
	uint block_idx = ast::NO_PARENT;
	for (uint i = fd.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == fun_decl_idx && pr.nodes[i].kind == BLOCK) {
			block_idx = i;
			break;
		}
	}
	if (block_idx == ast::NO_PARENT) return 0;

	// Find first non-trivial statement of the body.
	ast::AstNode* block = &pr.nodes[block_idx];
	uint first_stmt = ast::NO_PARENT;
	for (uint i = block.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == block_idx) {
			first_stmt = i;
			break;
		}
	}
	if (first_stmt == ast::NO_PARENT) return 0;

	// Must be a CALL_EXPR named "contract".
	ast::AstNode* stmt = &pr.nodes[first_stmt];
	if (stmt.kind != CALL_EXPR || stmt.name != "contract") return 0;

	// Locate the lambda argument (trailing or wrapped).
	uint lambda_idx = find_contract_lambda(pr, first_stmt);
	if (lambda_idx == ast::NO_PARENT) return 0;

	// The lambda's body statements may be either:
	//   - Direct children of LAMBDA_EXPR (common case for simple bodies),
	//   - Wrapped in a BLOCK child (some lambda forms).
	// Walk both cases by treating LAMBDA_EXPR's BLOCK child as the
	// container if present, else the LAMBDA_EXPR itself.
	uint container_idx = lambda_idx;
	ast::AstNode* lam = &pr.nodes[lambda_idx];
	for (uint i = lam.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == lambda_idx && pr.nodes[i].kind == BLOCK) {
			container_idx = i;
			break;
		}
	}

	// Walk top-level statements of the contract lambda body.
	usz count = 0;
	ast::AstNode* lb = &pr.nodes[container_idx];
	for (uint i = lb.children_start; i < pr.node_count && count < out.len; i++) {
		if (pr.nodes[i].parent != container_idx) continue;
		if (decode_effect_stmt(pr, fun_decl_idx, i, &out[count])) {
			count++;
		}
	}
	return count;
}

/**
 * Walk up from a CALL_EXPR("contract") to its trailing-lambda argument.
 * Returns the LAMBDA_EXPR index or NO_PARENT.
 */
fn uint find_contract_lambda(ast::ParseResult* pr, uint call_idx) {
	if (call_idx >= pr.node_count) return ast::NO_PARENT;
	ast::AstNode* call = &pr.nodes[call_idx];
	for (uint i = call.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != call_idx) continue;
		ast::AstNode* c = &pr.nodes[i];
		if (c.kind == LAMBDA_EXPR) return i;
		if (c.kind == VALUE_ARGUMENT) {
			// Inspect the wrapped expression.
			for (uint j = c.children_start; j < pr.node_count; j++) {
				if (pr.nodes[j].parent != i) continue;
				if (pr.nodes[j].kind == LAMBDA_EXPR) return j;
				break;
			}
		}
	}
	return ast::NO_PARENT;
}

/**
 * Decode a single statement in the contract lambda body into a
 * ContractEffect. Returns true on success.
 */
fn bool decode_effect_stmt(ast::ParseResult* pr, uint fun_decl_idx,
		uint stmt_idx, ContractEffect* out) {
	ast::AstNode* n = &pr.nodes[stmt_idx];

	// `returns(...) implies (cond)` — BINARY_EXPR(op="implies").
	if (n.kind == BINARY_EXPR && n.extra_text == "implies") {
		uint left = first_child_of(pr, stmt_idx);
		uint right = nth_child_of(pr, stmt_idx, 1);
		if (left == ast::NO_PARENT || right == ast::NO_PARENT) return false;

		ReturnValue rv;
		if (!decode_returns_call(pr, left, &rv)) return false;

		out.kind = RETURNS_IMPLIES;
		out.rv = rv;
		return decode_predicate(pr, fun_decl_idx, right, out);
	}

	// `callsInPlace(lambda, KIND)` — CALL_EXPR.
	if (n.kind == CALL_EXPR && n.name == "callsInPlace") {
		uint a0 = nth_arg_expr(pr, stmt_idx, 0);
		uint a1 = nth_arg_expr(pr, stmt_idx, 1);
		if (a0 == ast::NO_PARENT) return false;
		String pname = name_of(pr, a0);
		uint pidx;
		if (!find_param_index(pr, fun_decl_idx, pname, &pidx)) return false;

		out.kind = CALLS_IN_PLACE;
		out.cip_param_index = pidx;
		out.ik = decode_invocation_kind(pr, a1);
		return true;
	}

	return false;
}

/**
 * Decode the left side of `… implies …` — must be a CALL_EXPR named
 * "returns" with 0 or 1 argument (true / false / null literal).
 */
fn bool decode_returns_call(ast::ParseResult* pr, uint expr_idx, ReturnValue* out) {
	if (expr_idx >= pr.node_count) return false;
	ast::AstNode* n = &pr.nodes[expr_idx];
	if (n.kind != CALL_EXPR) return false;
	if (n.name != "returns" && n.name != "returnsNotNull") return false;

	if (n.name == "returnsNotNull") {
		// Treat returnsNotNull() implies cond identically to returns()
		// for narrowing purposes (caller sees a non-null result; the
		// predicate still applies on normal return).
		*out = ANY_RETURN;
		return true;
	}

	uint arg = nth_arg_expr(pr, expr_idx, 0);
	if (arg == ast::NO_PARENT) {
		*out = ANY_RETURN;
		return true;
	}
	ast::AstNode* a = &pr.nodes[arg];
	if (a.kind != LITERAL_EXPR) return false;
	switch (a.extra_text) {
		case "true":  *out = RETURN_TRUE;  return true;
		case "false": *out = RETURN_FALSE; return true;
		case "null":  *out = RETURN_NULL;  return true;
		default: return false;
	}
}

/**
 * Decode the predicate side of `… implies (pred)`. Recognized forms:
 *   PAREN_EXPR wrapping any of: `x is T`, `x !is T`, `x == null`,
 *   `x != null`, bare `x` (boolean param), `!x`. `this@name` resolves
 *   to TARGET_RECEIVER.
 */
fn bool decode_predicate(ast::ParseResult* pr, uint fun_decl_idx,
		uint pred_idx, ContractEffect* out) {
	uint idx = unwrap_paren(pr, pred_idx);
	if (idx >= pr.node_count) return false;
	ast::AstNode* n = &pr.nodes[idx];

	// !expr  →  flip BOOL_PARAM polarity.
	bool negated = false;
	if (n.kind == PREFIX_EXPR && n.extra_text == "!") {
		negated = true;
		idx = first_child_of(pr, idx);
		if (idx >= pr.node_count) return false;
		idx = unwrap_paren(pr, idx);
		n = &pr.nodes[idx];
	}

	// x is T / x !is T  → TYPE_CHECK_EXPR with extra_text "is" or "!is".
	if (n.kind == TYPE_CHECK_EXPR) {
		uint lhs = first_child_of(pr, idx);
		String pname = name_of(pr, lhs);
		if (!resolve_target(pr, fun_decl_idx, lhs, pname, &out.target)) return false;
		out.type_text = n.type_text;
		bool pos = n.extra_text == "is";
		if (negated) pos = !pos;
		out.pred = pos ? PRED_IS_TYPE : PRED_IS_NOT_TYPE;
		return true;
	}

	// x == null / x != null  → BINARY_EXPR with extra_text "==" or "!=".
	if (n.kind == BINARY_EXPR && (n.extra_text == "==" || n.extra_text == "!=")) {
		uint lhs = first_child_of(pr, idx);
		uint rhs = nth_child_of(pr, idx, 1);
		uint name_idx = ast::NO_PARENT;
		if (is_null_literal(pr, rhs)) {
			name_idx = lhs;
		} else if (is_null_literal(pr, lhs)) {
			name_idx = rhs;
		} else {
			return false;
		}
		String pname = name_of(pr, name_idx);
		if (!resolve_target(pr, fun_decl_idx, name_idx, pname, &out.target)) return false;
		bool eq = n.extra_text == "==";
		if (negated) eq = !eq;
		out.pred = eq ? PRED_IS_NULL : PRED_NOT_NULL;
		return true;
	}

	// Bare boolean param reference: `value` or `this@name`.
	if (n.kind == NAME_EXPR || n.kind == THIS_EXPR) {
		String pname = name_of(pr, idx);
		if (!resolve_target(pr, fun_decl_idx, idx, pname, &out.target)) return false;
		out.pred = negated ? PRED_NOT_BOOL : PRED_BOOL_PARAM;
		return true;
	}

	return false;
}

/**
 * Map a name to a target. Bare identifiers resolve to a parameter
 * index; `this` / `this@xxx` resolves to the receiver target.
 */
fn bool resolve_target(ast::ParseResult* pr, uint fun_decl_idx,
		uint expr_idx, String pname, PredTarget* out) {
	if (expr_idx < pr.node_count && pr.nodes[expr_idx].kind == THIS_EXPR) {
		out.kind = TARGET_RECEIVER;
		out.param_index = 0;
		return true;
	}
	if (pname.len == 0) return false;
	uint pidx;
	if (find_param_index(pr, fun_decl_idx, pname, &pidx)) {
		out.kind = TARGET_PARAM;
		out.param_index = pidx;
		return true;
	}
	return false;
}

/**
 * Find the 0-based parameter index of `name` inside a FUN_DECL.
 */
fn bool find_param_index(ast::ParseResult* pr, uint fun_decl_idx, String name, uint* out) {
	if (fun_decl_idx >= pr.node_count || name.len == 0) return false;
	ast::AstNode* fd = &pr.nodes[fun_decl_idx];
	uint idx = 0;
	for (uint i = fd.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != fun_decl_idx) continue;
		if (pr.nodes[i].kind != PARAM) continue;
		if (pr.nodes[i].name == name) { *out = idx; return true; }
		idx++;
	}
	return false;
}

/**
 * Decode an InvocationKind from a `kotlin.contracts.InvocationKind` enum
 * reference. Accepts `EXACTLY_ONCE`, `InvocationKind.EXACTLY_ONCE`, etc.
 */
fn InvocationKind decode_invocation_kind(ast::ParseResult* pr, uint expr_idx) {
	if (expr_idx >= pr.node_count) return UNKNOWN_KIND;
	ast::AstNode* n = &pr.nodes[expr_idx];
	String tag = "";
	if (n.kind == NAME_EXPR) {
		tag = n.name;
	} else if (n.kind == DOT_EXPR) {
		tag = n.name;
	}
	switch (tag) {
		case "EXACTLY_ONCE":  return EXACTLY_ONCE;
		case "AT_LEAST_ONCE": return AT_LEAST_ONCE;
		case "AT_MOST_ONCE":  return AT_MOST_ONCE;
		case "UNKNOWN":       return UNKNOWN_KIND;
		default:              return UNKNOWN_KIND;
	}
}

// ── AST shorthand helpers (private) ────────────────────────────────

fn uint first_child_of(ast::ParseResult* pr, uint parent_idx) {
	if (parent_idx >= pr.node_count) return ast::NO_PARENT;
	ast::AstNode* p = &pr.nodes[parent_idx];
	for (uint i = p.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == parent_idx) return i;
	}
	return ast::NO_PARENT;
}

fn uint nth_child_of(ast::ParseResult* pr, uint parent_idx, uint n) {
	if (parent_idx >= pr.node_count) return ast::NO_PARENT;
	ast::AstNode* p = &pr.nodes[parent_idx];
	uint count = 0;
	for (uint i = p.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != parent_idx) continue;
		if (count == n) return i;
		count++;
	}
	return ast::NO_PARENT;
}

fn uint nth_arg_expr(ast::ParseResult* pr, uint call_idx, uint n) {
	if (call_idx >= pr.node_count) return ast::NO_PARENT;
	ast::AstNode* call = &pr.nodes[call_idx];
	uint count = 0;
	for (uint i = call.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != call_idx) continue;
		if (pr.nodes[i].kind != VALUE_ARGUMENT) continue;
		if (count == n) return ast::get_arg_expr_idx(pr, i);
		count++;
	}
	return ast::NO_PARENT;
}

fn uint unwrap_paren(ast::ParseResult* pr, uint idx) {
	while (idx < pr.node_count && pr.nodes[idx].kind == PAREN_EXPR) {
		uint inner = first_child_of(pr, idx);
		if (inner >= pr.node_count) break;
		idx = inner;
	}
	return idx;
}

fn String name_of(ast::ParseResult* pr, uint expr_idx) {
	if (expr_idx >= pr.node_count) return "";
	ast::AstNode* n = &pr.nodes[expr_idx];
	if (n.kind == NAME_EXPR) return n.name;
	if (n.kind == THIS_EXPR) return "this";
	if (n.kind == PAREN_EXPR) return name_of(pr, first_child_of(pr, expr_idx));
	return "";
}

fn bool is_null_literal(ast::ParseResult* pr, uint idx) {
	if (idx >= pr.node_count) return false;
	ast::AstNode* n = &pr.nodes[idx];
	return n.kind == LITERAL_EXPR && n.extra_text == "null";
}
