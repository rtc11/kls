module kls::kotlin::flow;

import kls::kotlin::ast;
import kls::kotlin::cfg;
import kls::kotlin::contracts;
import kls::kotlin::types;

// ── Flow-sensitive smart-cast analysis ─────────────────────────────
//
// Per-function dataflow over the CFG built by `cfg::build_cfg`. Each
// CFG edge carries a FlowState describing facts that hold along that
// edge. Facts identify a variable (by AST decl index) and the narrowed
// type proven at this point.
//
// Transfer functions (Phase C):
//   * COND nodes inspecting `x is T` / `x !is T` / `x == null` / `x != null`
//     branch facts onto succ[0] (true) / succ[1] (false).
//   * STATEMENT nodes scan their AST sub-tree for:
//       - `x!!`  (POSTFIX_EXPR with operator "!!")
//       - `requireNotNull(x)` / `checkNotNull(x)`
//       - `require(x != null)` / `check(x != null)`
//       - `x ?: return ...` (ELVIS BINARY_EXPR with right = RETURN/THROW)
//     Facts asserted post-statement.
//   * ASSIGNMENT_EXPR kills facts about the assigned name.
//
// Stability gating is deferred to Phase E.

const usz MAX_FACTS_PER_STATE = 16;
const usz MAX_FLOW_NODES = cfg::MAX_CFG_NODES;

struct Fact {
	uint decl_idx;          // AST decl index this fact constrains (NO_PARENT for "this")
	String name;            // variable name (used when decl_idx is NO_PARENT)
	String member_name;     // member access path: "" for bare name, "x" for `b.x`
	TypeRef narrowed;       // narrowed type
	bool not_null;          // proven non-null
	bool occupied;
}

struct FlowState {
	Fact[MAX_FACTS_PER_STATE] facts;
	uint count;
	bool unreachable;       // BOTTOM
	bool top;               // TOP — used as initial state for non-entry nodes
}

struct FlowAnalysis {
	FlowState[MAX_FLOW_NODES] in_state;
	FlowState[MAX_FLOW_NODES] out_state;
	bool[MAX_FLOW_NODES] in_worklist;
	uint[MAX_FLOW_NODES] worklist;
	uint worklist_head;
	uint worklist_tail;
}

// ── State helpers ──────────────────────────────────────────────────

fn FlowState empty_state() {
	FlowState s;
	s.count = 0;
	s.unreachable = false;
	s.top = false;
	for (uint i = 0; i < MAX_FACTS_PER_STATE; i++) s.facts[i].occupied = false;
	return s;
}

fn FlowState top_state() {
	FlowState s = empty_state();
	s.top = true;
	return s;
}

fn FlowState bottom_state() {
	FlowState s = empty_state();
	s.unreachable = true;
	return s;
}

fn void FlowState.add_fact(FlowState* self, uint decl_idx, String name, TypeRef narrowed, bool not_null, String member_name = "") {
	// Replace existing fact for same decl_idx/name/member.
	for (uint i = 0; i < self.count; i++) {
		if (self.facts[i].occupied
			&& self.facts[i].decl_idx == decl_idx
			&& self.facts[i].name == name
			&& self.facts[i].member_name == member_name) {
			self.facts[i].narrowed = narrowed;
			self.facts[i].not_null = self.facts[i].not_null || not_null;
			return;
		}
	}
	if (self.count >= MAX_FACTS_PER_STATE) return;
	self.facts[self.count] = {
		.decl_idx = decl_idx,
		.name = name,
		.member_name = member_name,
		.narrowed = narrowed,
		.not_null = not_null,
		.occupied = true
	};
	self.count++;
}

fn void FlowState.kill_name(FlowState* self, String name, String member_name = "") {
	for (uint i = 0; i < self.count; i++) {
		if (self.facts[i].occupied
			&& self.facts[i].name == name
			&& self.facts[i].member_name == member_name) {
			self.facts[i].occupied = false;
		}
	}
}

/**
 * Kill ALL facts that mention `name` as the receiver (i.e. any `name.*`
 * member fact) plus the bare-name fact. Used when `name` itself is
 * reassigned — we lose all knowledge of its members too.
 */
fn void FlowState.kill_receiver(FlowState* self, String name) {
	for (uint i = 0; i < self.count; i++) {
		if (self.facts[i].occupied && self.facts[i].name == name) {
			self.facts[i].occupied = false;
		}
	}
}

/**
 * Look up a fact by (name, member_name). Returns null if absent.
 * member_name = "" for bare-name facts (default).
 */
fn Fact* FlowState.lookup(FlowState* self, String name, String member_name = "") {
	if (self.unreachable || self.top) return null;
	for (uint i = 0; i < self.count; i++) {
		if (self.facts[i].occupied
			&& self.facts[i].name == name
			&& self.facts[i].member_name == member_name) {
			return &self.facts[i];
		}
	}
	return null;
}

/**
 * Meet (intersect) two states: a fact survives only if both states agree.
 * TOP meets X = X. BOTTOM meets X = X.
 *
 * For agreement on the narrowed type: same TypeKind + same name. Otherwise
 * we drop the type narrowing but may keep `not_null` if both prove non-null.
 */
fn FlowState meet(FlowState* a, FlowState* b) {
	if (a.unreachable) return *b;
	if (b.unreachable) return *a;
	if (a.top) return *b;
	if (b.top) return *a;

	FlowState out = empty_state();
	for (uint i = 0; i < a.count; i++) {
		if (!a.facts[i].occupied) continue;
		Fact* af = &a.facts[i];
		// Find matching fact in b
		Fact* bf = null;
		for (uint j = 0; j < b.count; j++) {
			if (!b.facts[j].occupied) continue;
			if (b.facts[j].name == af.name) {
				bf = &b.facts[j];
				break;
			}
		}
		if (bf == null) continue;
		bool same_type = af.narrowed.kind == bf.narrowed.kind
			&& af.narrowed.name == bf.narrowed.name
			&& af.narrowed.nullable == bf.narrowed.nullable;
		bool both_not_null = af.not_null && bf.not_null;
		if (same_type) {
			out.add_fact(af.decl_idx, af.name, af.narrowed, both_not_null);
		} else if (both_not_null) {
			// Different narrowings but both prove non-null — preserve not_null only.
			TypeRef nn = af.narrowed;
			nn.nullable = false;
			out.add_fact(af.decl_idx, af.name, nn, true);
		}
	}
	return out;
}

/**
 * Returns true when `b` adds anything to `a` (set inclusion check).
 */
fn bool changed(FlowState* a, FlowState* b) {
	if (a.unreachable != b.unreachable) return true;
	if (a.top != b.top) return true;
	if (a.unreachable || a.top) return false;
	if (a.count != b.count) return true;
	for (uint i = 0; i < a.count; i++) {
		if (a.facts[i].occupied != b.facts[i].occupied) return true;
		if (!a.facts[i].occupied) continue;
		if (a.facts[i].name != b.facts[i].name) return true;
		if (a.facts[i].not_null != b.facts[i].not_null) return true;
		if (a.facts[i].narrowed.kind != b.facts[i].narrowed.kind) return true;
		if (a.facts[i].narrowed.name != b.facts[i].narrowed.name) return true;
		if (a.facts[i].narrowed.nullable != b.facts[i].narrowed.nullable) return true;
	}
	return false;
}

// ── AST helpers for transfer functions ─────────────────────────────

/**
 * Walk through PAREN_EXPR / "!" PREFIX_EXPR wrappers to find the underlying
 * condition node. Returns (final_idx, negated_count). Caller XORs negation
 * into branch direction.
 */
fn uint unwrap_negation(ParseResult* pr, uint idx, bool* negated) {
	*negated = false;
	while (idx < pr.node_count) {
		AstNode* n = &pr.nodes[idx];
		if (n.kind == PAREN_EXPR) {
			uint inner = first_child(pr, idx);
			if (inner == ast::NO_PARENT) return idx;
			idx = inner;
			continue;
		}
		if (n.kind == PREFIX_EXPR && n.extra_text == "!") {
			uint inner = first_child(pr, idx);
			if (inner == ast::NO_PARENT) return idx;
			*negated = !*negated;
			idx = inner;
			continue;
		}
		return idx;
	}
	return idx;
}

fn uint first_child(ParseResult* pr, uint parent_idx) {
	if (parent_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* p = &pr.nodes[parent_idx];
	if (p.child_count == 0) return ast::NO_PARENT;
	for (uint i = p.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == parent_idx) return i;
	}
	return ast::NO_PARENT;
}

fn uint nth_child(ParseResult* pr, uint parent_idx, uint n) {
	if (parent_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* p = &pr.nodes[parent_idx];
	if (p.child_count <= n) return ast::NO_PARENT;
	uint pos = 0;
	for (uint i = p.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == parent_idx) {
			if (pos == n) return i;
			pos++;
		}
	}
	return ast::NO_PARENT;
}

/**
 * If `expr_idx` is a NAME_EXPR, return its name; else "".
 * Handles wrapping PAREN_EXPR.
 */
fn String name_of_expr(ParseResult* pr, uint expr_idx) {
	if (expr_idx >= pr.node_count) return "";
	AstNode* n = &pr.nodes[expr_idx];
	if (n.kind == PAREN_EXPR) {
		return name_of_expr(pr, first_child(pr, expr_idx));
	}
	if (n.kind == NAME_EXPR) return n.name;
	if (n.kind == THIS_EXPR) return "this";
	return "";
}

/**
 * Try to extract a single-level member access path from `expr_idx`.
 * On success returns true and sets *out_recv (e.g. "b") and *out_member
 * (e.g. "x"). Recognises `b.x` (DOT_EXPR with NAME_EXPR receiver) and
 * `this.x` (DOT_EXPR with THIS_EXPR receiver, recv = "this").
 *
 * Bare names produce *out_recv = name, *out_member = "" — distinguishing
 * via empty member_name preserves single-key behaviour for callers that
 * don't yet care about members.
 *
 * Multi-level access (`a.b.c`) is NOT decoded — returns false. Member
 * smart casts only narrow at one level for now.
 */
fn bool dotted_name_of_expr(ParseResult* pr, uint expr_idx, String* out_recv, String* out_member) {
	*out_recv = "";
	*out_member = "";
	if (expr_idx >= pr.node_count) return false;
	AstNode* n = &pr.nodes[expr_idx];
	if (n.kind == PAREN_EXPR) {
		return dotted_name_of_expr(pr, first_child(pr, expr_idx), out_recv, out_member);
	}
	if (n.kind == NAME_EXPR) {
		*out_recv = n.name;
		return true;
	}
	if (n.kind == THIS_EXPR) {
		*out_recv = "this";
		return true;
	}
	if (n.kind == DOT_EXPR) {
		if (n.name.len == 0) return false;
		// Receiver is the first child; must itself be a bare name.
		uint recv = first_child(pr, expr_idx);
		if (recv == ast::NO_PARENT) return false;
		String recv_name = name_of_expr(pr, recv);
		if (recv_name.len == 0) return false;
		*out_recv = recv_name;
		*out_member = n.name;
		return true;
	}
	return false;
}

/**
 * Check if `expr_idx` is a LITERAL_EXPR null.
 */
fn bool is_null_literal(ParseResult* pr, uint expr_idx) {
	if (expr_idx >= pr.node_count) return false;
	AstNode* n = &pr.nodes[expr_idx];
	if (n.kind == PAREN_EXPR) return is_null_literal(pr, first_child(pr, expr_idx));
	if (n.kind == LITERAL_EXPR && n.extra_text == "null") return true;
	return false;
}

/**
 * Try to extract an `is`/`!is` check on a name. Sets *out_name and
 * *out_type_text. Returns "is" or "!is" or "" when not a type check.
 * Handles the (negated, original) shape transparently — caller XORs.
 *
 * Also accepts member-access subjects (`b.x is T`) — `*out_member`
 * is set to the member name when present, "" for bare-name subjects.
 */
fn String parse_type_check(ParseResult* pr, uint expr_idx, String* out_name, String* out_type_text, String* out_member = null) {
	String dummy;
	if (out_member == null) out_member = &dummy;
	*out_member = "";
	if (expr_idx >= pr.node_count) return "";
	AstNode* n = &pr.nodes[expr_idx];
	if (n.kind != TYPE_CHECK_EXPR) return "";
	uint subj_idx = first_child(pr, expr_idx);
	String subj;
	String mem;
	if (!dotted_name_of_expr(pr, subj_idx, &subj, &mem)) return "";
	if (subj.len == 0) return "";
	*out_name = subj;
	*out_member = mem;
	*out_type_text = n.type_text;
	return n.extra_text;
}

/**
 * Try to extract a null comparison: returns "==null", "!=null", or "".
 * On match, sets *out_name to the variable being compared and *out_member
 * to its member-access suffix (or "" for bare names).
 */
fn String parse_null_check(ParseResult* pr, uint expr_idx, String* out_name, String* out_member = null) {
	String dummy;
	if (out_member == null) out_member = &dummy;
	*out_member = "";
	if (expr_idx >= pr.node_count) return "";
	AstNode* n = &pr.nodes[expr_idx];
	if (n.kind != BINARY_EXPR) return "";
	if (n.extra_text != "==" && n.extra_text != "!=") return "";
	uint l = first_child(pr, expr_idx);
	uint r = nth_child(pr, expr_idx, 1);
	String lname;
	String lmem;
	String rname;
	String rmem;
	bool l_ok = dotted_name_of_expr(pr, l, &lname, &lmem);
	bool r_ok = dotted_name_of_expr(pr, r, &rname, &rmem);
	if (l_ok && lname.len > 0 && is_null_literal(pr, r)) {
		*out_name = lname;
		*out_member = lmem;
		return n.extra_text == "==" ? "==null" : "!=null";
	}
	if (r_ok && rname.len > 0 && is_null_literal(pr, l)) {
		*out_name = rname;
		*out_member = rmem;
		return n.extra_text == "==" ? "==null" : "!=null";
	}
	return "";
}

// ── Transfer functions ─────────────────────────────────────────────

/**
 * Compute branch facts for a COND node: returns (true_state, false_state).
 *
 * Walks the COND's AST node looking for:
 *   - `x is T`  → true:{x narrow T}    false:{x narrow Not(T) — not modeled}
 *   - `x !is T` → true:{x narrow Not(T)}  false:{x narrow T}
 *   - `x == null` → true:{} false:{x not_null}
 *   - `x != null` → true:{x not_null} false:{}
 *   - `a && b` → true: both true facts; false: nothing (need disjoint analysis)
 *   - `a || b` → false: both false facts; true: nothing
 *   - `!a` → swap (handled via unwrap_negation)
 */
fn void compute_cond_facts(ParseResult* pr, uint cond_ast_idx, FlowState* in_s,
		FlowState* true_out, FlowState* false_out) {
	*true_out = *in_s;
	*false_out = *in_s;
	if (in_s.unreachable || in_s.top) return;
	apply_cond_facts(pr, cond_ast_idx, true_out, false_out);
}

fn void apply_cond_facts(ParseResult* pr, uint cond_idx, FlowState* true_out, FlowState* false_out) {
	if (cond_idx >= pr.node_count) return;

	// WHEN_ENTRY: COND nodes for `when` arms point at the WHEN_ENTRY directly.
	// Derive the subject name (from enclosing WHEN_EXPR) and look for `is T`
	// conditions inside the entry's children.
	if (pr.nodes[cond_idx].kind == WHEN_ENTRY) {
		apply_when_entry_facts(pr, cond_idx, true_out, false_out);
		return;
	}

	bool negated = false;
	uint idx = unwrap_negation(pr, cond_idx, &negated);
	AstNode* n = &pr.nodes[idx];

	String name;
	String member;
	String type_text;
	String op = parse_type_check(pr, idx, &name, &type_text, &member);
	if (op.len > 0) {
		bool is_pos = op == "is";
		if (negated) is_pos = !is_pos;
		TypeRef t = types::parse_type_text(type_text);
		if (is_pos) {
			true_out.add_fact(ast::NO_PARENT, name, t, !t.nullable, member);
			// false branch: we don't model "not T" narrowing
		} else {
			false_out.add_fact(ast::NO_PARENT, name, t, !t.nullable, member);
		}
		return;
	}

	String null_op = parse_null_check(pr, idx, &name, &member);
	if (null_op.len > 0) {
		bool is_eq = null_op == "==null";
		if (negated) is_eq = !is_eq;
		// narrowed type stays UNKNOWN — only the not_null bit matters; the
		// declared type is looked up by the caller and has nullable cleared.
		TypeRef nn = types::TYPE_UNKNOWN;
		if (is_eq) {
			// `x == null`: false-branch proves x not-null
			false_out.add_fact(ast::NO_PARENT, name, nn, true, member);
		} else {
			// `x != null`: true-branch proves x not-null
			true_out.add_fact(ast::NO_PARENT, name, nn, true, member);
		}
		return;
	}

	// Conjunction / disjunction
	if (n.kind == BINARY_EXPR) {
		String op2 = n.extra_text;
		if (op2 == "&&" || op2 == "||") {
			uint l = first_child(pr, idx);
			uint r = nth_child(pr, idx, 1);
			FlowState lt = empty_state();
			FlowState lf = empty_state();
			FlowState rt = empty_state();
			FlowState rf = empty_state();
			apply_cond_facts(pr, l, &lt, &lf);
			apply_cond_facts(pr, r, &rt, &rf);
			if (op2 == "&&") {
				// true-branch: both must be true (union narrow)
				merge_facts_into(true_out, &lt);
				merge_facts_into(true_out, &rt);
				// false-branch: indeterminate (could be l-false or r-false)
				// Skip narrowing on false branch for &&.
				if (negated) {
					// !(a && b) — flip
					FlowState tmp = *true_out;
					*true_out = *false_out;
					*false_out = tmp;
				}
			} else {
				// ||  true-branch: indeterminate.
				// false-branch: both must be false (union narrow).
				merge_facts_into(false_out, &lf);
				merge_facts_into(false_out, &rf);
				if (negated) {
					FlowState tmp = *true_out;
					*true_out = *false_out;
					*false_out = tmp;
				}
			}
			return;
		}
	}

	// Contract-driven narrowing: `if (call(...))` with a contract of
	// the form `returns(true|false) implies (predicate)` narrows
	// caller-side facts in the matching branch. Common idioms:
	//   if (s.isNullOrEmpty()) {} else { s.length }    // s known non-null in else
	//   if (!s.isNullOrEmpty()) { s.length }           // s known non-null in then
	if (n.kind == CALL_EXPR) {
		apply_call_cond_contracts(pr, idx, negated, true_out, false_out);
		return;
	}
}

/**
 * Consume `returns(true|false) implies (cond)` contracts at a call
 * appearing in conditional position. RETURN_TRUE arms feed `true_out`,
 * RETURN_FALSE arms feed `false_out`. ANY_RETURN arms apply
 * unconditionally on both branches (the call returned normally to
 * evaluate the condition, so any `returns()` postcondition holds).
 *
 * `negated` flips which branch each arm contributes to (handles `!call`).
 */
fn void apply_call_cond_contracts(ParseResult* pr, uint call_idx, bool negated,
		FlowState* true_out, FlowState* false_out) {
	AstNode* call = &pr.nodes[call_idx];
	String callee = call.name;
	if (callee.len == 0) return;

	contracts::ContractEffect[16] buf;
	usz n = collect_contracts_for_callee(pr, callee, buf[..]);
	for (usz i = 0; i < n; i++) {
		if (buf[i].kind != contracts::ContractEffectKind.RETURNS_IMPLIES) continue;

		FlowState* dest;
		switch (buf[i].rv) {
			case contracts::ReturnValue.RETURN_TRUE:
				dest = negated ? false_out : true_out;
			case contracts::ReturnValue.RETURN_FALSE:
				dest = negated ? true_out : false_out;
			case contracts::ReturnValue.ANY_RETURN:
				// Postcondition of normal completion — both branches see it.
				apply_predicate_to(pr, call_idx, &buf[i], true_out);
				apply_predicate_to(pr, call_idx, &buf[i], false_out);
				continue;
			case contracts::ReturnValue.RETURN_NULL:
				// Boolean-valued conditions can't carry a null return.
				continue;
		}
		apply_predicate_to(pr, call_idx, &buf[i], dest);
	}
}

fn void merge_facts_into(FlowState* dest, FlowState* src) {
	if (src.unreachable || src.top) return;
	for (uint i = 0; i < src.count; i++) {
		if (!src.facts[i].occupied) continue;
		Fact* f = &src.facts[i];
		dest.add_fact(f.decl_idx, f.name, f.narrowed, f.not_null);
	}
}

/**
 * WHEN_ENTRY → branch facts. The COND for a `when` arm points at the
 * WHEN_ENTRY node. Subject name comes from the enclosing WHEN_EXPR; the
 * entry's first non-body child is the condition.
 *
 * Supported patterns:
 *   when (x) { is String -> ... }   → narrow x to String on true
 *   when (x) { null -> ... }        → x not-null on false
 *   when (x) { val y = expr; ... }  → subject binding (skipped)
 *
 * `else` arms have no condition; we treat them as unconditional pass-through
 * (true_out unchanged, false_out unreachable handled by solver).
 */
fn void apply_when_entry_facts(ParseResult* pr, uint entry_idx, FlowState* true_out, FlowState* false_out) {
	AstNode* entry = &pr.nodes[entry_idx];
	if (entry.extra_text == "else") return;

	// Find enclosing WHEN_EXPR
	uint when_idx = entry.parent;
	if (when_idx >= pr.node_count || pr.nodes[when_idx].kind != WHEN_EXPR) return;

	// Subject name: first child of WHEN_EXPR
	String subject_name = "";
	for (uint i = pr.nodes[when_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != when_idx) continue;
		if (pr.nodes[i].kind == WHEN_ENTRY) break;
		AstNode* sub = &pr.nodes[i];
		if (sub.kind == NAME_EXPR) {
			subject_name = sub.name;
			break;
		}
		if (sub.kind == PROPERTY_DECL) {
			subject_name = sub.name;
			break;
		}
		if (sub.kind == PAREN_EXPR) {
			uint inner = first_child(pr, i);
			if (inner != ast::NO_PARENT && pr.nodes[inner].kind == NAME_EXPR) {
				subject_name = pr.nodes[inner].name;
			}
			break;
		}
		break;
	}
	if (subject_name.len == 0) return;

	// Walk entry children: first child is the condition; following children
	// are body. (For multi-condition arms `is A, is B -> ...` we only narrow
	// when all conditions agree on the same type — TODO.)
	uint cond_child = ast::NO_PARENT;
	for (uint i = pr.nodes[entry_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != entry_idx) continue;
		cond_child = i;
		break;
	}
	if (cond_child == ast::NO_PARENT) return;

	AstNode* cn = &pr.nodes[cond_child];

	// `is T` / `!is T` arm
	if (cn.kind == TYPE_CHECK_EXPR) {
		bool is_pos = cn.extra_text == "is";
		TypeRef t = types::parse_type_text(cn.type_text);
		if (is_pos) {
			true_out.add_fact(ast::NO_PARENT, subject_name, t, !t.nullable);
		} else {
			false_out.add_fact(ast::NO_PARENT, subject_name, t, !t.nullable);
		}
		return;
	}

	// `null` literal arm: when (x) { null -> ... }
	if (cn.kind == LITERAL_EXPR && cn.extra_text == "null") {
		// true: x is null (no useful fact). false: x is non-null.
		false_out.add_fact(ast::NO_PARENT, subject_name, types::TYPE_UNKNOWN, true);
		return;
	}
}

/**
 * Walk a STATEMENT's sub-AST looking for guard effects:
 *   - `x!!` → assert x non-null
 *   - `requireNotNull(x)` / `checkNotNull(x)` → assert x non-null
 *   - `require(x != null)` / `check(x != null)` → assert x non-null
 *   - `x ?: return` / `x ?: throw` → assert x non-null (ELVIS with right diverges)
 *   - assignment `x = ...` → kill facts about x
 */
fn void apply_stmt_effects(ParseResult* pr, uint stmt_idx, FlowState* state) {
	if (stmt_idx >= pr.node_count) return;
	if (state.unreachable || state.top) return;
	scan_node(pr, stmt_idx, state);
}

fn void scan_node(ParseResult* pr, uint idx, FlowState* state) {
	if (idx >= pr.node_count) return;
	AstNode* n = &pr.nodes[idx];

	switch (n.kind) {
		case ASSIGNMENT_EXPR:
			// LHS is first child. If bare NAME_EXPR, kill all facts about
			// it (including any member facts — `b = ...` invalidates `b.x`).
			// If `b.x = ...`, kill only the `b.x` fact.
			uint lhs = first_child(pr, idx);
			String lname;
			String lmem;
			if (dotted_name_of_expr(pr, lhs, &lname, &lmem) && lname.len > 0) {
				if (lmem.len == 0) {
					state.kill_receiver(lname);
				} else {
					state.kill_name(lname, lmem);
				}
			}
			// Continue scanning RHS.
			break;

		case POSTFIX_EXPR:
			if (n.extra_text == "!!") {
				uint inner = first_child(pr, idx);
				String name;
				String mem;
				if (dotted_name_of_expr(pr, inner, &name, &mem) && name.len > 0) {
					TypeRef nn = types::TYPE_UNKNOWN;
					state.add_fact(ast::NO_PARENT, name, nn, true, mem);
				}
			}
			break;

		case BINARY_EXPR:
			if (n.extra_text == "?:") {
				// Elvis: if right side is RETURN/THROW, left becomes non-null after.
				uint l = first_child(pr, idx);
				uint r = nth_child(pr, idx, 1);
				if (r != ast::NO_PARENT) {
					AstNode* rn = &pr.nodes[r];
					bool diverges = rn.kind == RETURN_EXPR
						|| rn.kind == THROW_EXPR
						|| (rn.kind == BLOCK && block_diverges(pr, r));
					if (diverges) {
						String lname;
						String lmem;
						if (dotted_name_of_expr(pr, l, &lname, &lmem) && lname.len > 0) {
							TypeRef nn = types::TYPE_UNKNOWN;
							state.add_fact(ast::NO_PARENT, lname, nn, true, lmem);
						}
					}
				}
			}
			break;

		case CALL_EXPR:
			// Apply post-call facts from any matching stdlib contract.
			// Covers requireNotNull/checkNotNull/require/check (formerly
			// hardcoded) plus isNullOrEmpty/isNullOrBlank patterns when
			// they appear in statement position (rare; usually they
			// surface via cond branches — see apply_cond_facts).
			apply_call_contracts(pr, idx, state);
			break;

		default:
			break;
	}

	// Recurse into children — facts accumulate left-to-right.
	if (n.child_count == 0) return;
	for (uint i = n.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == idx) {
			scan_node(pr, i, state);
		}
	}
}

/**
 * Apply contract effects matching this call site. Statement-position
 * application: only RETURNS_IMPLIES with rv == ANY_RETURN contributes
 * facts (the call must have returned normally to reach the next
 * statement). Conditional-position narrowing (returns(true|false))
 * happens through `apply_cond_facts`.
 */
fn void apply_call_contracts(ParseResult* pr, uint call_idx, FlowState* state) {
	AstNode* call = &pr.nodes[call_idx];
	String callee = call.name;
	if (callee.len == 0) return;

	contracts::ContractEffect[16] buf;
	usz n = collect_contracts_for_callee(pr, callee, buf[..]);
	for (usz i = 0; i < n; i++) {
		if (buf[i].kind != contracts::ContractEffectKind.RETURNS_IMPLIES) continue;
		if (buf[i].rv != contracts::ReturnValue.ANY_RETURN) continue;
		apply_returns_implies(pr, call_idx, &buf[i], state);
	}
}

/**
 * Collect contracts for a callee from BOTH the hardcoded stdlib table
 * AND the in-file user-defined contracts (any FUN_DECL with matching
 * name in the same ParseResult). Cross-file user contracts are NOT
 * resolved here — that requires a workspace lookup which would invert
 * the kotlin → workspace layering. Tracked in the contracts plan.
 */
fn usz collect_contracts_for_callee(ParseResult* pr, String callee_name,
		contracts::ContractEffect[] out) {
	usz n = contracts::collect_stdlib_contracts(callee_name, out);
	if (n >= out.len) return n;

	// In-file scan: find any FUN_DECL with this name, extract its
	// contracts. Multiple matches (overloads) all contribute — flow
	// is conservative so applying superset of facts only narrows more.
	for (uint i = 0; i < pr.node_count; i++) {
		if (n >= out.len) break;
		if (pr.nodes[i].kind != FUN_DECL) continue;
		if (pr.nodes[i].name != callee_name) continue;
		usz wrote = contracts::extract_user_contracts(pr, i, out[n..]);
		n += wrote;
	}
	return n;
}

/**
 * Translate a RETURNS_IMPLIES effect into a FlowState fact at the call
 * site. Substitutes the predicate target (param index or receiver)
 * against the actual call arguments / receiver expression.
 */
fn void apply_returns_implies(ParseResult* pr, uint call_idx,
		contracts::ContractEffect* effect, FlowState* state) {
	apply_predicate_to(pr, call_idx, effect, state);
}

/**
 * Apply the contract's predicate as a fact to `dest`. Shared between
 * statement-position consumption (ANY_RETURN) and conditional-position
 * consumption (RETURN_TRUE / RETURN_FALSE arms in `if` / `when`).
 */
fn void apply_predicate_to(ParseResult* pr, uint call_idx,
		contracts::ContractEffect* effect, FlowState* dest) {
	String target_name = resolve_target_name(pr, call_idx, &effect.target);

	switch (effect.pred) {
		case contracts::PredKind.PRED_NOT_NULL:
			if (target_name.len > 0) {
				dest.add_fact(ast::NO_PARENT, target_name, types::TYPE_UNKNOWN, true);
			}
		case contracts::PredKind.PRED_BOOL_PARAM:
			// `target_name` here would be the formal param's name in
			// callee scope, which doesn't refer to anything caller-side
			// unless the caller passes a bare local/param of the same
			// name. The interesting narrowing is when the actual arg
			// is itself `x != null` / `x is T` — propagate that.
			propagate_boolean_arg_narrowing(pr, call_idx, effect.target.param_index, dest);
		case contracts::PredKind.PRED_IS_TYPE:
			if (target_name.len > 0) {
				TypeRef t = types::parse_type_text(effect.type_text);
				dest.add_fact(ast::NO_PARENT, target_name, t, !t.nullable);
			}
		case contracts::PredKind.PRED_IS_NULL:
		case contracts::PredKind.PRED_IS_NOT_TYPE:
		case contracts::PredKind.PRED_NOT_BOOL:
		case contracts::PredKind.PRED_NONE:
			// No useful narrowing from these in statement position.
			break;
	}
}

/**
 * For PRED_BOOL_PARAM: if the call's Nth argument is `x != null` or
 * `x is T`, treat it like that condition was asserted true.
 */
fn void propagate_boolean_arg_narrowing(ParseResult* pr, uint call_idx,
		uint param_index, FlowState* state) {
	uint arg = nth_positional_arg(pr, call_idx, param_index);
	if (arg >= pr.node_count) return;
	String name;
	String op = parse_null_check(pr, arg, &name);
	if (op == "!=null" && name.len > 0) {
		state.add_fact(ast::NO_PARENT, name, types::TYPE_UNKNOWN, true);
		return;
	}
	String type_text;
	String tcop = parse_type_check(pr, arg, &name, &type_text);
	if (tcop == "is" && name.len > 0) {
		TypeRef t = types::parse_type_text(type_text);
		state.add_fact(ast::NO_PARENT, name, t, !t.nullable);
	}
}

/**
 * Resolve the variable name a contract target points at within the
 * caller. Param targets index the call's positional argument list;
 * receiver targets walk up to the enclosing DOT_EXPR's left side.
 */
fn String resolve_target_name(ParseResult* pr, uint call_idx,
		contracts::PredTarget* target) {
	if (target.kind == contracts::PredTargetKind.TARGET_PARAM) {
		uint arg = nth_positional_arg(pr, call_idx, target.param_index);
		return name_of_expr(pr, arg);
	}
	// TARGET_RECEIVER — the receiver of a member call appears as the
	// callee child of CALL_EXPR (parser shape: CALL_EXPR has DOT_EXPR
	// as a child, where the DOT_EXPR's first child is the receiver).
	// Note: the callee child is added BEFORE `children_start` for the
	// args, so we must scan all nodes for `parent == call_idx`.
	if (call_idx >= pr.node_count) return "";
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != call_idx) continue;
		if (pr.nodes[i].kind == DOT_EXPR) {
			uint lhs = first_child(pr, i);
			return name_of_expr(pr, lhs);
		}
	}
	return "";
}

/**
 * Get the argument expression at the Nth positional position of a call.
 */
fn uint nth_positional_arg(ParseResult* pr, uint call_idx, uint n) {
	if (call_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* call = &pr.nodes[call_idx];
	if (call.child_count == 0) return ast::NO_PARENT;
	uint count = 0;
	for (uint i = call.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != call_idx) continue;
		if (pr.nodes[i].kind != VALUE_ARGUMENT) continue;
		// Skip named arguments — contracts target positional formals.
		if (pr.nodes[i].name.len > 0) continue;
		if (count == n) return ast::get_arg_expr_idx(pr, i);
		count++;
	}
	return ast::NO_PARENT;
}

fn bool block_diverges(ParseResult* pr, uint block_idx) {
	if (block_idx >= pr.node_count) return false;
	AstNode* b = &pr.nodes[block_idx];
	if (b.child_count == 0) return false;
	for (uint i = b.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == block_idx) {
			NodeKind k = pr.nodes[i].kind;
			if (k == RETURN_EXPR || k == THROW_EXPR) return true;
		}
	}
	return false;
}

// ── Worklist solver ────────────────────────────────────────────────

fn void enqueue(FlowAnalysis* fa, uint idx) {
	if (fa.in_worklist[idx]) return;
	if (fa.worklist_tail >= MAX_FLOW_NODES) return;
	fa.worklist[fa.worklist_tail] = idx;
	fa.worklist_tail++;
	fa.in_worklist[idx] = true;
}

fn uint dequeue(FlowAnalysis* fa) {
	if (fa.worklist_head >= fa.worklist_tail) return cfg::NO_CFG;
	uint idx = fa.worklist[fa.worklist_head];
	fa.worklist_head++;
	fa.in_worklist[idx] = false;
	return idx;
}

/**
 * Run forward dataflow over the CFG. Returns a heap-allocated FlowAnalysis
 * the caller must free with `free(fa)`.
 *
 * Initial: in[entry]=empty, all others=top (so first meet adopts incoming).
 * Standard meet-over-paths fixpoint.
 */
fn FlowAnalysis* analyze(ParseResult* pr, Cfg* cfg) {
	FlowState empty = empty_state();
	return analyze_with_entry(pr, cfg, &empty);
}

/**
 * Like `analyze` but seeds the entry state from `initial`. Used for
 * lambda CFGs nested inside an enclosing function: the lambda inherits
 * the enclosing function's flow facts at the lambda's lexical position.
 */
fn FlowAnalysis* analyze_with_entry(ParseResult* pr, Cfg* cfg, FlowState* initial) {
	FlowAnalysis* fa = mem::new(FlowAnalysis);
	for (uint i = 0; i < cfg.node_count; i++) {
		fa.in_state[i] = top_state();
		fa.out_state[i] = top_state();
		fa.in_worklist[i] = false;
	}
	fa.worklist_head = 0;
	fa.worklist_tail = 0;

	fa.in_state[cfg.entry] = *initial;
	enqueue(fa, cfg.entry);

	uint iterations = 0;
	const uint MAX_ITER = 100000;
	while (fa.worklist_head < fa.worklist_tail && iterations < MAX_ITER) {
		iterations++;
		uint idx = dequeue(fa);
		if (idx == cfg::NO_CFG) break;

		FlowState new_out = transfer(pr, cfg, idx, &fa.in_state[idx]);
		FlowState new_out_false = bottom_state();
		if (cfg.nodes[idx].kind == COND) {
			new_out_false = empty_state();
			new_out = empty_state();
			compute_cond_facts(pr, cfg.nodes[idx].ast_idx, &fa.in_state[idx], &new_out, &new_out_false);
		}

		fa.out_state[idx] = new_out;

		CfgNode* node = &cfg.nodes[idx];
		for (uint k = 0; k < node.succ_count; k++) {
			uint succ = node.succ[k];
			FlowState* edge = &new_out;
			if (node.kind == COND && k == 1) edge = &new_out_false;
			FlowState merged = meet(&fa.in_state[succ], edge);
			if (changed(&fa.in_state[succ], &merged)) {
				fa.in_state[succ] = merged;
				enqueue(fa, succ);
			}
		}
	}
	return fa;
}

/**
 * Transfer function for a single CFG node. For STATEMENT nodes: scans
 * the AST for guard effects. For terminator / structural nodes: pass
 * through. COND is handled separately by the solver via compute_cond_facts.
 */
fn FlowState transfer(ParseResult* pr, Cfg* cfg, uint cfg_idx, FlowState* in_s) {
	CfgNode* node = &cfg.nodes[cfg_idx];
	FlowState s = *in_s;
	if (s.unreachable || s.top) return s;
	switch (node.kind) {
		case STATEMENT:
			apply_stmt_effects(pr, node.ast_idx, &s);
			return s;
		case RETURN:
		case THROW:
		case BREAK:
		case CONTINUE:
			// Side-effects of the operand expression first
			apply_stmt_effects(pr, node.ast_idx, &s);
			return s;
		default:
			return s;
	}
}

/**
 * Look up the smart-cast fact for a NAME_EXPR usage at AST node idx.
 * Walks up the AST to find the enclosing CFG-mapped node and reads
 * its IN-state. Returns null if no fact applies.
 */
fn Fact* FlowAnalysis.fact_at(FlowAnalysis* self, ParseResult* pr, Cfg* cfg, uint ast_idx, String name, String member_name = "") {
	uint cur = ast_idx;
	while (cur != ast::NO_PARENT && cur < pr.node_count) {
		uint cfg_idx = cfg.cfg_node_for(cur);
		if (cfg_idx != cfg::NO_CFG) {
			return self.in_state[cfg_idx].lookup(name, member_name);
		}
		cur = pr.nodes[cur].parent;
	}
	return null;
}

/**
 * Snapshot of the in-state at the CFG node enclosing `ast_idx`. Used to
 * seed a nested lambda's CFG with facts that hold at its lexical position
 * in the enclosing function. Returns empty_state() if no enclosing CFG
 * node is found.
 */
fn FlowState FlowAnalysis.state_at(FlowAnalysis* self, ParseResult* pr, Cfg* cfg, uint ast_idx) {
	uint cur = ast_idx;
	while (cur != ast::NO_PARENT && cur < pr.node_count) {
		uint cfg_idx = cfg.cfg_node_for(cur);
		if (cfg_idx != cfg::NO_CFG) {
			return self.in_state[cfg_idx];
		}
		cur = pr.nodes[cur].parent;
	}
	return empty_state();
}

fn void FlowAnalysis.free(FlowAnalysis* self) {
	mem::free(self);
}
