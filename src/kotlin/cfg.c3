module kls::kotlin::cfg;

import kls::kotlin::ast;

// ── Control-flow graph (CFG) for a single function body ─────────────
//
// Each function (FUN_DECL, CONSTRUCTOR_DECL, INIT_BLOCK, top-level lambda
// body) is lowered into a directed graph of CfgNodes carrying flow-relevant
// information. Used as the backbone for flow-sensitive type analysis
// (smart casts, definite assignment, nullability narrowing).

const usz MAX_CFG_NODES = 8192;
const uint MAX_SUCC = 4;          // max direct successors per CFG node
const uint NO_CFG = uint.max;
const uint MAX_LOOP_DEPTH = 32;

enum CfgNodeKind : int {
	ENTRY,         // function entry
	EXIT,          // function exit (sink)
	STATEMENT,     // straight-line statement / expression (no control-flow effect)
	COND,          // condition; succ[0]=true branch, succ[1]=false branch
	MERGE,         // join point (e.g. after if/when)
	LOOP_HEAD,     // loop entry header (back-edge target)
	RETURN,        // return -> EXIT
	THROW,         // throw -> EXIT (or catch later)
	BREAK,         // break -> loop exit
	CONTINUE,      // continue -> loop head
	NULL_CHECK,    // synthetic check for `?.` / `?:` / `!!` / requireNotNull
	TYPE_CHECK,    // synthetic check for `is`/`!is`
	CALL_GUARD,    // synthetic post-call guard: requireNotNull/checkNotNull/etc.
}

struct CfgNode {
	CfgNodeKind kind;
	uint ast_idx;              // owning AST node (NO_CFG when synthetic)
	uint[MAX_SUCC] succ;       // successor CFG node indices
	uint succ_count;
}

struct Cfg {
	uint func_ast_idx;         // owning FUN_DECL / CONSTRUCTOR_DECL / INIT_BLOCK / LAMBDA_EXPR
	CfgNode[MAX_CFG_NODES] nodes;
	uint node_count;
	uint entry;                // index of ENTRY node
	uint exit;                 // index of EXIT node
	uint[ast::MAX_NODES] ast_to_cfg;  // AST node idx -> CFG node idx (NO_CFG if none)
}

struct LoopContext {
	uint head;                 // CFG node to jump to on `continue`
	uint exit;                 // CFG node to jump to on `break`
}

struct LoopStack {
	LoopContext[MAX_LOOP_DEPTH] frames;
	uint depth;
}

fn void LoopStack.push(LoopStack* self, uint head, uint exit) {
	if (self.depth >= MAX_LOOP_DEPTH) return;
	self.frames[self.depth] = { .head = head, .exit = exit };
	self.depth++;
}

fn void LoopStack.pop(LoopStack* self) {
	if (self.depth == 0) return;
	self.depth--;
}

fn LoopContext* LoopStack.top(LoopStack* self) {
	if (self.depth == 0) return null;
	return &self.frames[self.depth - 1];
}

// ── Construction primitives ─────────────────────────────────────────

fn uint Cfg.add_node(Cfg* self, CfgNodeKind kind, uint ast_idx) {
	uint idx = self.node_count;
	if (idx >= MAX_CFG_NODES - 1) {
		idx = (uint)(MAX_CFG_NODES - 1);
	} else {
		self.node_count++;
	}
	CfgNode* n = &self.nodes[idx];
	n.kind = kind;
	n.ast_idx = ast_idx;
	n.succ_count = 0;
	for (uint i = 0; i < MAX_SUCC; i++) n.succ[i] = NO_CFG;
	if (ast_idx < ast::MAX_NODES) {
		if (self.ast_to_cfg[ast_idx] == NO_CFG) {
			self.ast_to_cfg[ast_idx] = idx;
		}
	}
	return idx;
}

fn void Cfg.add_edge(Cfg* self, uint from, uint to) {
	if (from == NO_CFG || to == NO_CFG) return;
	if (from >= self.node_count || to >= self.node_count) return;
	CfgNode* n = &self.nodes[from];
	if (n.succ_count >= MAX_SUCC) return;
	n.succ[n.succ_count] = to;
	n.succ_count++;
}

// ── Lowering ────────────────────────────────────────────────────────

/**
 * Build a CFG for the function at func_ast_idx. Caller owns the
 * returned heap-allocated Cfg.
 */
fn Cfg* build_cfg(ParseResult* pr, uint func_ast_idx) {
	Cfg* cfg = mem::new(Cfg);
	cfg.func_ast_idx = func_ast_idx;
	cfg.node_count = 0;
	for (uint i = 0; i < ast::MAX_NODES; i++) cfg.ast_to_cfg[i] = NO_CFG;

	cfg.entry = cfg.add_node(ENTRY, func_ast_idx);
	cfg.exit = cfg.add_node(EXIT, func_ast_idx);

	uint body_idx = find_function_body(pr, func_ast_idx);
	if (body_idx == ast::NO_PARENT) {
		cfg.add_edge(cfg.entry, cfg.exit);
		return cfg;
	}

	LoopStack stack;
	stack.depth = 0;
	uint last;
	if (pr.nodes[body_idx].kind == BLOCK
		|| pr.nodes[body_idx].kind == LAMBDA_EXPR
		|| pr.nodes[body_idx].kind == INIT_BLOCK
		|| pr.nodes[body_idx].kind == ANONYMOUS_FUN_EXPR) {
		last = lower_block(cfg, pr, body_idx, cfg.entry, &stack);
	} else {
		// Expression-body function: single expression as body.
		last = lower_stmt(cfg, pr, body_idx, cfg.entry, &stack);
	}
	if (last != NO_CFG) cfg.add_edge(last, cfg.exit);
	return cfg;
}

fn uint find_function_body(ParseResult* pr, uint func_idx) {
	if (func_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* func = &pr.nodes[func_idx];
	if (func.kind == LAMBDA_EXPR || func.kind == ANONYMOUS_FUN_EXPR) {
		return func_idx;
	}
	if (func.kind == INIT_BLOCK) {
		return func_idx;
	}
	if (func.child_count == 0) return ast::NO_PARENT;
	for (uint i = func.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == func_idx && pr.nodes[i].kind == BLOCK) {
			return i;
		}
	}
	// Expression-body: last expression child.
	uint last_expr = ast::NO_PARENT;
	for (uint i = func.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == func_idx && ast::is_expression(pr.nodes[i].kind)) {
			last_expr = i;
		}
	}
	return last_expr;
}

/**
 * Lower a BLOCK (or block-equivalent container) into a CFG subgraph.
 * Returns the CFG node index of the "after" point, or NO_CFG when the
 * block diverges (every path returns/throws/breaks/continues).
 */
fn uint lower_block(Cfg* cfg, ParseResult* pr, uint block_idx, uint pred, LoopStack* loops) {
	uint cur = pred;
	if (block_idx >= pr.node_count) return cur;
	AstNode* block = &pr.nodes[block_idx];
	if (block.child_count == 0) return cur;
	for (uint i = block.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != block_idx) continue;
		if (pr.nodes[i].kind == ANNOTATION_ENTRY) continue;
		if (pr.nodes[i].kind == PARAM) continue;
		if (cur == NO_CFG) {
			// Statements after a divergent statement are unreachable.
			// Still create CFG nodes but with no incoming edge so flow
			// analysis treats them as BOTTOM.
			cur = lower_stmt(cfg, pr, i, NO_CFG, loops);
			continue;
		}
		cur = lower_stmt(cfg, pr, i, cur, loops);
	}
	return cur;
}

/**
 * Lower a single statement / expression. Returns the "after" CFG node
 * (NO_CFG when divergent).
 */
fn uint lower_stmt(Cfg* cfg, ParseResult* pr, uint stmt_idx, uint pred, LoopStack* loops) {
	if (stmt_idx >= pr.node_count) return pred;
	AstNode* node = &pr.nodes[stmt_idx];
	switch (node.kind) {
		case IF_EXPR:        return lower_if(cfg, pr, stmt_idx, pred, loops);
		case WHEN_EXPR:      return lower_when(cfg, pr, stmt_idx, pred, loops);
		case WHILE_STMT:     return lower_while(cfg, pr, stmt_idx, pred, loops);
		case DO_WHILE_STMT:  return lower_do_while(cfg, pr, stmt_idx, pred, loops);
		case FOR_STMT:       return lower_for(cfg, pr, stmt_idx, pred, loops);
		case TRY_EXPR:       return lower_try(cfg, pr, stmt_idx, pred, loops);
		case RETURN_EXPR:    return lower_return(cfg, pr, stmt_idx, pred);
		case THROW_EXPR:     return lower_throw(cfg, pr, stmt_idx, pred);
		case BREAK_EXPR:     return lower_break(cfg, pr, stmt_idx, pred, loops);
		case CONTINUE_EXPR:  return lower_continue(cfg, pr, stmt_idx, pred, loops);
		case BLOCK:          return lower_block(cfg, pr, stmt_idx, pred, loops);
		default:
			// PROPERTY_DECL / RETURN_EXPR / etc. with a control-flow
			// expression as their value (e.g. `val a = when (s) {...}`,
			// `return if (x is T) ... else ...`) need their value lowered
			// so the inner WHEN/IF/TRY produces COND nodes — otherwise
			// smart-cast facts in branch bodies are never narrowed.
			uint cf_child = find_control_flow_value(pr, stmt_idx);
			if (cf_child != ast::NO_PARENT) {
				uint after = lower_stmt(cfg, pr, cf_child, pred, loops);
				uint n = cfg.add_node(STATEMENT, stmt_idx);
				if (after != NO_CFG) cfg.add_edge(after, n);
				return n;
			}
			// Plain statement / expression. Even non-control-flow nodes
			// may contain `!!`, `?:`, `?.` or guard calls that affect
			// flow facts — record them as STATEMENT nodes; the flow
			// analyzer inspects sub-AST for guard effects.
			return lower_plain(cfg, pr, stmt_idx, pred);
	}
}

/**
 * If `stmt_idx` is a PROPERTY_DECL or RETURN_EXPR whose value child is a
 * control-flow expression (WHEN_EXPR / IF_EXPR / TRY_EXPR), return the
 * AST index of that value child. Returns NO_PARENT otherwise.
 *
 * Smart-cast narrowing inside `is`/null branches relies on COND nodes
 * being created by lower_if/lower_when/lower_try; if these expressions
 * appear as initializers / return values they're never reached through
 * the block-level statement loop and their bodies see the un-narrowed
 * subject type.
 */
fn uint find_control_flow_value(ParseResult* pr, uint stmt_idx) {
	if (stmt_idx >= pr.node_count) return ast::NO_PARENT;
	AstNode* node = &pr.nodes[stmt_idx];
	if (node.kind != PROPERTY_DECL && node.kind != RETURN_EXPR) return ast::NO_PARENT;
	for (uint i = node.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != stmt_idx) continue;
		if (pr.nodes[i].kind == ANNOTATION_ENTRY) continue;
		if (pr.nodes[i].kind == TYPE_REF) continue;
		switch (pr.nodes[i].kind) {
			case WHEN_EXPR:
			case IF_EXPR:
			case TRY_EXPR:
				return i;
			default:
				// First non-annotation/type child that's not control-flow:
				// nothing to descend into.
				return ast::NO_PARENT;
		}
	}
	return ast::NO_PARENT;
}

fn uint lower_plain(Cfg* cfg, ParseResult* pr, uint stmt_idx, uint pred) {
	uint n = cfg.add_node(STATEMENT, stmt_idx);
	if (pred != NO_CFG) cfg.add_edge(pred, n);
	return n;
}

// ── Branch lowering ────────────────────────────────────────────────

fn uint lower_if(Cfg* cfg, ParseResult* pr, uint if_idx, uint pred, LoopStack* loops) {
	// IF_EXPR children: [0]=condition, [1]=then-branch, optional [2]=else-branch.
	uint cond = ast::NO_PARENT;
	uint then_b = ast::NO_PARENT;
	uint else_b = ast::NO_PARENT;
	uint pos = 0;
	for (uint i = pr.nodes[if_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != if_idx) continue;
		if (pos == 0) {
			cond = i;
		} else if (pos == 1) {
			then_b = i;
		} else if (pos == 2) {
			else_b = i;
		}
		pos++;
	}
	uint cond_node = cfg.add_node(COND, cond != ast::NO_PARENT ? cond : if_idx);
	if (pred != NO_CFG) cfg.add_edge(pred, cond_node);

	uint merge = cfg.add_node(MERGE, if_idx);

	// True branch
	uint true_after = then_b != ast::NO_PARENT
		? lower_stmt(cfg, pr, then_b, cond_node, loops)
		: cond_node;
	if (true_after != NO_CFG) cfg.add_edge(true_after, merge);

	// False branch
	if (else_b != ast::NO_PARENT) {
		uint false_after = lower_stmt(cfg, pr, else_b, cond_node, loops);
		if (false_after != NO_CFG) cfg.add_edge(false_after, merge);
	} else {
		cfg.add_edge(cond_node, merge);
	}

	// If both branches diverge AND there's no else fall-through, merge
	// is unreachable. Detect: succ_count of merge predecessors = 0.
	uint[8] preds;
	uint pcount = cfg.predecessors(merge, &preds);
	if (pcount == 0) return NO_CFG;
	return merge;
}

fn uint lower_when(Cfg* cfg, ParseResult* pr, uint when_idx, uint pred, LoopStack* loops) {
	// WHEN_EXPR children: optional subject (PROPERTY_DECL/PAREN_EXPR/NAME_EXPR/etc.)
	// followed by N WHEN_ENTRY nodes. Each WHEN_ENTRY has condition children
	// + a body child (or `else -> body`).
	uint merge = cfg.add_node(MERGE, when_idx);
	uint cur = pred;
	bool any_reached_merge = false;
	bool saw_else = false;

	for (uint i = pr.nodes[when_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != when_idx) continue;
		if (pr.nodes[i].kind != WHEN_ENTRY) continue;

		// Identify body (last child of entry); preceding children are conditions.
		// "else" branch entries have no condition, just the body.
		uint body = ast::NO_PARENT;
		uint last_child = ast::NO_PARENT;
		uint child_count = 0;
		for (uint j = pr.nodes[i].children_start; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != i) continue;
			last_child = j;
			child_count++;
		}
		body = last_child;
		bool is_else = child_count <= 1 && pr.nodes[i].extra_text == "else";
		if (is_else) saw_else = true;

		uint cond_node = cfg.add_node(COND, i);
		if (cur != NO_CFG) cfg.add_edge(cur, cond_node);

		uint body_after = body != ast::NO_PARENT
			? lower_stmt(cfg, pr, body, cond_node, loops)
			: cond_node;
		if (body_after != NO_CFG) {
			cfg.add_edge(body_after, merge);
			any_reached_merge = true;
		}

		// Fall-through to next entry on false
		cur = cond_node;
	}

	// If no `else` entry, the false-out of the last condition reaches merge.
	if (!saw_else && cur != NO_CFG) {
		cfg.add_edge(cur, merge);
		any_reached_merge = true;
	}

	if (!any_reached_merge) return NO_CFG;
	return merge;
}

// ── Loop lowering ──────────────────────────────────────────────────

fn uint lower_while(Cfg* cfg, ParseResult* pr, uint while_idx, uint pred, LoopStack* loops) {
	// WHILE_STMT children: [0]=condition, [1]=body
	uint cond = ast::NO_PARENT;
	uint body = ast::NO_PARENT;
	uint pos = 0;
	for (uint i = pr.nodes[while_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != while_idx) continue;
		if (pos == 0) {
			cond = i;
		} else if (pos == 1) {
			body = i;
		}
		pos++;
	}

	uint head = cfg.add_node(LOOP_HEAD, while_idx);
	uint cond_node = cfg.add_node(COND, cond != ast::NO_PARENT ? cond : while_idx);
	uint loop_exit = cfg.add_node(MERGE, while_idx);

	if (pred != NO_CFG) cfg.add_edge(pred, head);
	cfg.add_edge(head, cond_node);
	// Cond false: exit loop
	cfg.add_edge(cond_node, loop_exit);

	loops.push(head, loop_exit);
	uint body_after = body != ast::NO_PARENT
		? lower_stmt(cfg, pr, body, cond_node, loops)
		: cond_node;
	loops.pop();
	if (body_after != NO_CFG) cfg.add_edge(body_after, head); // back-edge

	return loop_exit;
}

fn uint lower_do_while(Cfg* cfg, ParseResult* pr, uint do_idx, uint pred, LoopStack* loops) {
	// DO_WHILE_STMT children: [0]=body, [1]=condition
	uint body = ast::NO_PARENT;
	uint cond = ast::NO_PARENT;
	uint pos = 0;
	for (uint i = pr.nodes[do_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != do_idx) continue;
		if (pos == 0) {
			body = i;
		} else if (pos == 1) {
			cond = i;
		}
		pos++;
	}

	uint head = cfg.add_node(LOOP_HEAD, do_idx);
	uint cond_node = cfg.add_node(COND, cond != ast::NO_PARENT ? cond : do_idx);
	uint loop_exit = cfg.add_node(MERGE, do_idx);

	if (pred != NO_CFG) cfg.add_edge(pred, head);

	loops.push(head, loop_exit);
	uint body_after = body != ast::NO_PARENT
		? lower_stmt(cfg, pr, body, head, loops)
		: head;
	loops.pop();
	if (body_after != NO_CFG) cfg.add_edge(body_after, cond_node);

	cfg.add_edge(cond_node, head);          // cond true: back-edge
	cfg.add_edge(cond_node, loop_exit);     // cond false: exit
	return loop_exit;
}

fn uint lower_for(Cfg* cfg, ParseResult* pr, uint for_idx, uint pred, LoopStack* loops) {
	// FOR_STMT children: PARAM(s), iterable expression, body.
	// We treat the iterable as a STATEMENT before head, and the body executes 0..N times.
	// Locate iterable (first non-PARAM expression child) and body (BLOCK or last expr).
	uint iterable = ast::NO_PARENT;
	uint body = ast::NO_PARENT;
	uint last_child = ast::NO_PARENT;
	for (uint i = pr.nodes[for_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != for_idx) continue;
		if (pr.nodes[i].kind == PARAM) continue;
		if (iterable == ast::NO_PARENT) {
			iterable = i;
		}
		last_child = i;
	}
	if (last_child != iterable) body = last_child;

	uint iter_node = NO_CFG;
	if (iterable != ast::NO_PARENT) {
		iter_node = cfg.add_node(STATEMENT, iterable);
		if (pred != NO_CFG) cfg.add_edge(pred, iter_node);
	}
	uint pred_for_head = iter_node != NO_CFG ? iter_node : pred;

	uint head = cfg.add_node(LOOP_HEAD, for_idx);
	uint cond_node = cfg.add_node(COND, for_idx);
	uint loop_exit = cfg.add_node(MERGE, for_idx);

	if (pred_for_head != NO_CFG) cfg.add_edge(pred_for_head, head);
	cfg.add_edge(head, cond_node);
	cfg.add_edge(cond_node, loop_exit);  // empty iterable: skip body

	loops.push(head, loop_exit);
	uint body_after = body != ast::NO_PARENT
		? lower_stmt(cfg, pr, body, cond_node, loops)
		: cond_node;
	loops.pop();
	if (body_after != NO_CFG) cfg.add_edge(body_after, head);

	return loop_exit;
}

fn uint lower_try(Cfg* cfg, ParseResult* pr, uint try_idx, uint pred, LoopStack* loops) {
	// TRY_EXPR children: try-body, CATCH_CLAUSE*, optional finally-body.
	// Conservative model: any statement in the try block may throw and reach
	// any catch clause. We approximate by edging from try-block's STATEMENT
	// into each catch's body. (Phase B keeps it coarse; flow analysis still
	// benefits from the try/catch shape.)
	uint try_body = ast::NO_PARENT;
	uint finally_body = ast::NO_PARENT;
	uint[16] catches;
	uint catch_count = 0;
	uint pos = 0;
	for (uint i = pr.nodes[try_idx].children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent != try_idx) continue;
		NodeKind k = pr.nodes[i].kind;
		if (k == CATCH_CLAUSE) {
			if (catch_count < 16) catches[catch_count++] = i;
		} else if (pos == 0) {
			try_body = i;
		} else {
			finally_body = i;
		}
		pos++;
	}

	uint merge = cfg.add_node(MERGE, try_idx);

	uint try_after = try_body != ast::NO_PARENT
		? lower_stmt(cfg, pr, try_body, pred, loops)
		: pred;
	if (try_after != NO_CFG) cfg.add_edge(try_after, merge);

	// Each catch: edge from pred (entry to try block) to catch body.
	for (uint i = 0; i < catch_count; i++) {
		uint catch_idx = catches[i];
		// Catch body = last child of CATCH_CLAUSE (after PARAM).
		uint catch_body = ast::NO_PARENT;
		for (uint j = pr.nodes[catch_idx].children_start; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != catch_idx) continue;
			if (pr.nodes[j].kind == PARAM) continue;
			catch_body = j;
		}
		uint catch_after = catch_body != ast::NO_PARENT
			? lower_stmt(cfg, pr, catch_body, pred, loops)
			: pred;
		if (catch_after != NO_CFG) cfg.add_edge(catch_after, merge);
	}

	if (finally_body != ast::NO_PARENT) {
		uint after_finally = lower_stmt(cfg, pr, finally_body, merge, loops);
		return after_finally;
	}
	return merge;
}

// ── Terminator lowering ────────────────────────────────────────────

fn uint lower_return(Cfg* cfg, ParseResult* pr, uint ret_idx, uint pred) {
	// Lower a control-flow value child (when/if/try) first so its COND
	// nodes exist for smart-cast narrowing inside the arms.
	uint cf_child = find_control_flow_value(pr, ret_idx);
	uint after = pred;
	if (cf_child != ast::NO_PARENT) {
		LoopStack empty_loops;
		empty_loops.depth = 0;
		uint cf_after = lower_stmt(cfg, pr, cf_child, pred, &empty_loops);
		if (cf_after != NO_CFG) after = cf_after;
	}
	uint n = cfg.add_node(RETURN, ret_idx);
	if (after != NO_CFG) cfg.add_edge(after, n);
	cfg.add_edge(n, cfg.exit);
	return NO_CFG;
}

fn uint lower_throw(Cfg* cfg, ParseResult* pr, uint th_idx, uint pred) {
	uint n = cfg.add_node(THROW, th_idx);
	if (pred != NO_CFG) cfg.add_edge(pred, n);
	cfg.add_edge(n, cfg.exit);
	return NO_CFG;
}

fn uint lower_break(Cfg* cfg, ParseResult* pr, uint br_idx, uint pred, LoopStack* loops) {
	uint n = cfg.add_node(BREAK, br_idx);
	if (pred != NO_CFG) cfg.add_edge(pred, n);
	LoopContext* top = loops.top();
	if (top != null) {
		cfg.add_edge(n, top.exit);
	} else {
		cfg.add_edge(n, cfg.exit);
	}
	return NO_CFG;
}

fn uint lower_continue(Cfg* cfg, ParseResult* pr, uint co_idx, uint pred, LoopStack* loops) {
	uint n = cfg.add_node(CONTINUE, co_idx);
	if (pred != NO_CFG) cfg.add_edge(pred, n);
	LoopContext* top = loops.top();
	if (top != null) {
		cfg.add_edge(n, top.head);
	} else {
		cfg.add_edge(n, cfg.exit);
	}
	return NO_CFG;
}

// ── Query helpers ──────────────────────────────────────────────────

fn uint Cfg.cfg_node_for(Cfg* self, uint ast_idx) {
	if (ast_idx >= ast::MAX_NODES) return NO_CFG;
	return self.ast_to_cfg[ast_idx];
}

fn uint Cfg.predecessors(Cfg* self, uint node_idx, uint[] buf) {
	uint count = 0;
	for (uint i = 0; i < self.node_count; i++) {
		CfgNode* n = &self.nodes[i];
		for (uint k = 0; k < n.succ_count; k++) {
			if (n.succ[k] == node_idx) {
				if (count < buf.len) buf[count] = i;
				count++;
				break;
			}
		}
	}
	return count;
}

fn void Cfg.free(Cfg* self) {
	mem::free(self);
}
