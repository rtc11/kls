module kls::lsp::definition;

/*
 * textDocument/definition handler — Kotlin go-to-definition.
 *
 * Architecture (post Tier-3 refactor):
 *
 *   handle_definition (dispatcher)
 *     ├─ resolve_dot_member       — type-directed `recv.member` lookup
 *     │                             (Kotlin spec §11 member access)
 *     └─ resolve_bare_identifier  — 9-step lookup pipeline
 *                                   (Kotlin spec §16.10 lexical scopes
 *                                    + §16.30 imports)
 *
 * Spec ordering (resolve_bare_identifier):
 *   1. Receiver-lambda implicit `this` member (§16.30)
 *   2. Lexical scope walk: innermost → FILE (§16.10)
 *   3. Extension function implicit `this` member (§16.30)
 *   4. Text-based FQN dep lookup
 *   5. Inherited supertype member (§16.10) — bound tighter than
 *                                            cross-file workspace
 *   6. Workspace index — same-package + explicit imports (§16.30)
 *   7. Explicit-import dep lookup
 *   8. Star-import dep lookup
 *   9. Default-import dep lookup (§16.30 implicit imports)
 *
 * Helpers used elsewhere:
 *   find_declaration_in_file      — scope walk + global fallback;
 *                                   used by rename/references/highlight/
 *                                   inlay_hints/signature_help/
 *                                   call_hierarchy/linked_editing
 *   find_declaration_in_scope_chain — strict scope walk only,
 *                                     for spec-conformant go-to-def
 */

import std::io;
import std::collections;
import std::collections::object;
import kls::document;
import kls::lsp::hover;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::types;
import kls::kotlin::symbols;
import kls::workspace;
import kls::deps::jar_index;
import kls::deps::source_nav;
import kls::log;

/**
 * Bundle of inputs needed by every definition sub-resolver.
 *
 * Built once at the top of `handle_definition` (and during the late
 * dot-member retry); passed to all helpers so they don't have to
 * re-derive offsets, re-tokenize, or re-fetch ParseResult / TypeInfo.
 *
 * Lifetime: temp-allocator scoped — valid for one definition request
 * only. Fields point into the document store / workspace; do NOT
 * persist beyond the request.
 *
 * Mirrors Kotlin spec §16 resolution inputs:
 *   - `tok` / `target_name`  → the unresolved name reference
 *   - `pr` / `info`          → AST + types (semantic context)
 *   - `is_call`              → call vs property reference
 *   - `is_dot_member`        → member-access vs free reference
 *   - `workspace`            → cross-file + dep index access
 *   - `uri` / `doc`          → for fallback locations and source text
 */
struct ResolutionContext {
	DocumentStore* store;
	WorkspaceIndex* workspace;
	Document* doc;
	String uri;
	ParseResult* pr;
	TypeInfo* info;
	Token tok;
	String target_name;
	uint cursor_offset;
	bool is_call;
	bool is_dot_member;
}

/**
 * Build a ResolutionContext from raw LSP request inputs.
 *
 * Returns the context wrapped in Optional. Fault on any prerequisite
 * miss (no doc, no token, non-identifier token, no AST). Caller
 * should treat fault as "no definition" and return null.
 */
fn ResolutionContext? build_resolution_context(DocumentStore* store, WorkspaceIndex* workspace,
		String uri, uint line, uint character) {
	Document* doc = store.get(uri) ?? null;
	if (doc == null) return NOT_FOUND_BY_IMPORT~;

	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return NOT_FOUND_BY_IMPORT~;
	}

	if (tok.kind != IDENTIFIER) return NOT_FOUND_BY_IMPORT~;

	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) return NOT_FOUND_BY_IMPORT~;

	TypeInfo* info = store.get_types(uri) ?? null;

	bool is_call = is_call_context_ast(pr, tok.offset) || is_call_context(doc.content, tok);
	bool is_dot_member = is_token_dot_member(pr, tok);

	return (ResolutionContext){
		.store = store,
		.workspace = workspace,
		.doc = doc,
		.uri = uri,
		.pr = pr,
		.info = info,
		.tok = tok,
		.target_name = tok.text,
		.cursor_offset = tok.offset,
		.is_call = is_call,
		.is_dot_member = is_dot_member,
	};
}

/**
 * Resolve a dot-member access (`receiver.member`) to a definition.
 *
 * Spec-aligned wrapper around `find_dot_member_definition`: thin for now,
 * but central to Phase 2's split — `handle_definition` dispatches here
 * for member access and to `resolve_bare_identifier` for free names.
 *
 * Class-ref vs instance filtering happens inside via `is_member_accessible`
 * (gated by `TypeRef.is_class_ref` flag from P0.3 + `DepSymbol.is_static`
 * from P0.2).
 *
 * Returns NOT_DOT_MEMBER~ when no dot-member resolution applies; caller
 * should treat as "not handled here".
 */
fn Object*? resolve_dot_member(ResolutionContext* ctx) {
	if (ctx.info == null) return NOT_DOT_MEMBER~;
	return find_dot_member_definition(ctx.pr, ctx.info, ctx.store, ctx.workspace, ctx.tok, ctx.uri);
}

/**
 * Resolve a bare-name reference (no dot prefix) to a definition.
 *
 * Implements the Kotlin spec §16.10/§16.30 lookup order for unqualified
 * names. Each step short-circuits on success.
 *
 * Order (and Kotlin spec rule it implements):
 *   1. Receiver-lambda implicit `this` member (§16.30, lambda receiver)
 *      — gated by no-shadow (`is_declared_in_lambda_scope`)
 *   2. Scope-walk over local + enclosing AST scopes (§16.10 inner→outer)
 *   3. Extension-fn implicit `this` member (§16.30 extension receiver)
 *   4. Text-based FQN dep lookup (must precede workspace to avoid
 *      matching same-name workspace symbol in wrong package)
 *   5. Inherited supertype member (§16.10 supertype scope) — moved
 *      ABOVE workspace per spec; current-class supertype binds tighter
 *      than another file's top-level same name.
 *   6. Workspace index (cross-file user code, §16.30 same-package + imports)
 *   7. Explicit-import dep lookup
 *   8. Star-import dep lookup
 *   9. Default-import dep lookup (§16.30 implicit imports)
 *
 * Skipped entirely when `ctx.is_dot_member`; dot-member dispatch handles
 * those paths via `resolve_dot_member`.
 *
 * Returns NOT_FOUND_BY_IMPORT~ when the pipeline produces nothing; caller
 * treats fault as "no definition found" (returns null to client).
 */
fn Object*? resolve_bare_identifier(ResolutionContext* ctx) {
	ParseResult* pr = ctx.pr;
	TypeInfo* ti = ctx.info;
	Token tok = ctx.tok;
	String target_name = ctx.target_name;
	String uri = ctx.uri;
	WorkspaceIndex* workspace = ctx.workspace;
	DocumentStore* store = ctx.store;

	// 1. Receiver lambda member navigation
	// `with(receiver) { member }` / `apply { member }`: bare name may be
	// a member of the lambda's receiver type. Gate on no-shadow.
	if (!is_declared_in_lambda_scope(pr, target_name, tok.offset)) {
		if (try result = find_receiver_lambda_member_definition(pr, workspace, store, target_name, tok.offset, uri)) {
			log::debug("[def] bare: receiver-lambda member");
			return result;
		}
	}

	// 2. Scope-walk (local → outer → top-level same file).
	// Strict: no global fallback. Members of unrelated classes/objects
	// are reached via the workspace path (step 6) which is spec-conformant.
	if (try node = find_declaration_in_scope_chain(pr, target_name, tok.offset, ctx.is_call, ti)) {
		log::debug("[def] bare: AST scope search");
		return build_location_from_node(uri, node);
	}

	// 3. Extension function receiver member
	if (try result = find_extension_receiver_member_definition(pr, workspace, store, target_name, tok.offset, uri)) {
		log::debug("[def] bare: extension receiver member");
		return result;
	}

	// 4. Text-based FQN dep lookup (e.g., org.apache.kafka.X)
	if (workspace != null && workspace.dep_index.initialized) {
		if (try result = find_definition_by_text_fqn(ctx.doc.content, tok, &workspace.dep_index)) {
			log::debug("[def] bare: text-based FQN dep lookup");
			return result;
		}
	}

	// 5. Inherited supertype member — MOVED before workspace per spec.
	// Class hierarchy binds tighter than unrelated workspace symbols.
	if (workspace != null) {
		if (try result = find_inherited_member_definition(pr, workspace, store, target_name, tok.offset, uri)) {
			log::debug("[def] bare: inherited supertype member");
			return result;
		}
	}

	// 6. Cross-file workspace lookup
	if (workspace != null) {
		if (try result = find_definition_in_workspace(workspace, target_name, ctx.is_call, uri, pr)) {
			log::debug("[def] bare: workspace index");
			return result;
		}
	}

	// 7. Explicit-import dep lookup
	if (workspace != null) {
		if (try result = find_definition_by_explicit_import(pr, &workspace.dep_index, target_name, ctx.is_call, uri)) {
			log::debug("[def] bare: explicit import dep");
			return result;
		}
	}

	// 8. Star-import dep lookup
	if (workspace != null) {
		if (try result = find_definition_by_star_import(pr, &workspace.dep_index, target_name, ctx.is_call, uri)) {
			log::debug("[def] bare: star import dep");
			return result;
		}
	}

	// 9. Default-import dep lookup (Kotlin spec §16.30 implicit imports)
	if (workspace != null) {
		if (try result = find_definition_by_default_imports(&workspace.dep_index, target_name, ctx.is_call)) {
			log::debug("[def] bare: default import dep");
			return result;
		}
	}

	return NOT_FOUND_BY_IMPORT~;
}

/**
 * Handle textDocument/definition request.
 *
 * Dispatcher: routes to `resolve_dot_member` for member-access tokens
 * and to `resolve_bare_identifier` for free names. The late dot-member
 * retry handles cases where the AST didn't classify the token as a
 * dot-member but text-based detection still applies (e.g., partial AST).
 */
fn Object*? handle_definition(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	ResolutionContext ctx;
	if (try c = build_resolution_context(store, workspace, uri, line, character)) {
		ctx = c;
	} else {
		return null;
	}

	log::debug("[def] target='%s' line=%d col=%d uri=%s", ctx.target_name, line, character, ctx.uri);

	// ── Dot-member dispatch ──────────────────────────────────────
	// Member access (`receiver.member`) is type-directed. MUST run before
	// bare-name resolution; otherwise a same-named bare decl in an
	// unrelated scope can win the scoring race.
	if (ctx.is_dot_member) {
		if (try result = resolve_dot_member(&ctx)) {
			log::debug("[def] dispatch: dot-member (early)");
			return result;
		}
		// Fall through: dot-member resolution may have given up but the
		// bare-name pipeline can still find scope-local matches (rare).
	}

	// ── Bare-identifier dispatch ─────────────────────────────────
	if (try result = resolve_bare_identifier(&ctx)) {
		return result;
	}

	// ── Late dot-member retry ────────────────────────────────────
	// Catches text-based dot detection cases where AST classification
	// missed the dot relationship.
	if (!ctx.is_dot_member) {
		if (try result = resolve_dot_member(&ctx)) {
			log::debug("[def] dispatch: dot-member (late retry)");
			return result;
		}
	}

	log::debug("[def] no definition found for '%s'", ctx.target_name);
	return null;
}

/**
 * Count the number of arguments in a CALL_EXPR at the given cursor offset.
 * Returns -1 if no CALL_EXPR is found at the cursor position.
 */
fn int find_call_arg_count(ParseResult* pr, String target_name, uint cursor_offset) {
	// Find the CALL_EXPR that contains the cursor
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CALL_EXPR) continue;
		if (n.name != target_name) continue;
		if (cursor_offset < n.start_offset || cursor_offset >= n.end_offset) continue;

		// Count arguments (skip callee NAME_EXPR and trailing LAMBDA_EXPR)
		uint count = 0;
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.kind == NAME_EXPR && child.name == target_name) continue;
			if (child.kind == LAMBDA_EXPR) continue;
			count++;
		}
		return (int)count;
	}
	return -1;
}

/**
 * Collect argument type names from a CALL_EXPR at the cursor position.
 * Uses TypeInfo to resolve each argument's type. Returns count of filled entries.
 */
fn usz find_call_arg_types(ParseResult* pr, TypeInfo* ti, String target_name, uint cursor_offset, String[] out_types) {
	if (ti == null) return 0;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CALL_EXPR) continue;
		if (n.name != target_name) continue;
		if (cursor_offset < n.start_offset || cursor_offset >= n.end_offset) continue;

		usz count = 0;
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.kind == NAME_EXPR && child.name == target_name) continue;
			if (child.kind == LAMBDA_EXPR) continue;
			if (count >= out_types.len) break;

			if (ti.has_type[j]) {
				out_types[count] = ti.node_types[j].name;
			} else {
				out_types[count] = "";
			}
			count++;
		}
		return count;
	}
	return 0;
}

/**
 * Pick the best FUN_DECL among candidates by matching argument count
 * and optionally argument types.
 * If call_arg_count is -1, returns the first func_match (no scoring).
 */
fn AstNode* pick_best_overload(ParseResult* pr, AstNode*[] candidates, uint[] candidate_indices, usz count, int call_arg_count, String[] arg_types = {}, String[] named_args = {}) {
	if (count == 0) return null;
	// Defensive: caller-supplied slice may have null entries if uninitialized.
	if (candidates[0] == null) return null;
	if (count == 1 || call_arg_count < 0) return candidates[0];

	// Collect candidates with matching param count
	AstNode*[16] param_matches;
	uint[16] pm_indices;
	usz pm_count = 0;
	for (usz i = 0; i < count; i++) {
		uint param_count = ast::count_children_of_kind(pr, candidates[i], PARAM);
		if (param_count == (uint)call_arg_count && pm_count < 16) {
			param_matches[pm_count] = candidates[i];
			pm_indices[pm_count] = candidate_indices[i];
			pm_count++;
		}
	}

	if (pm_count == 0) return candidates[0];
	if (pm_count == 1) return param_matches[0];

	// Multiple param-count matches — try type-based + named arg disambiguation
	if (arg_types.len > 0 || named_args.len > 0) {
		AstNode* best = null;
		int best_score = -1;
		for (usz i = 0; i < pm_count; i++) {
			int score = 0;
			if (arg_types.len > 0) {
				score += score_param_types(pr, pm_indices[i], arg_types);
			}
			if (named_args.len > 0) {
				score += score_named_args(pr, pm_indices[i], named_args);
			}
			if (score > best_score) {
				best_score = score;
				best = param_matches[i];
			}
		}
		if (best != null) return best;
	}

	return param_matches[0];
}

/**
 * Score how well a FUN_DECL's parameter types match the given argument types.
 * Returns number of matching type names (higher = better).
 */
fn int score_param_types(ParseResult* pr, uint fun_idx, String[] arg_types) {
	int score = 0;
	usz arg_idx = 0;

	for (uint i = 0; i < pr.node_count && arg_idx < arg_types.len; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.parent != fun_idx) continue;
		if (n.kind != PARAM) continue;

		if (arg_types[arg_idx].len > 0 && n.type_text.len > 0) {
			String param_type = strip_type_suffix(n.type_text);
			String arg_type = strip_type_suffix(arg_types[arg_idx]);
			if (param_type == arg_type) {
				score++;
			}
		}
		arg_idx++;
	}
	return score;
}

/**
 * Strip generic parameters and nullable suffix from a type name.
 * "List<String>?" -> "List", "String" -> "String"
 */
fn String strip_type_suffix(String t) {
	for (usz k = 0; k < t.len; k++) {
		if (t[k] == '<' || t[k] == '?') {
			return t[:k];
		}
	}
	return t;
}

/**
 * Extract named argument names from a CALL_EXPR.
 * In Kotlin, `foo(name = "x", count = 5)` has ASSIGNMENT_EXPR children
 * whose first child NAME_EXPR gives the argument name.
 */
fn usz find_call_named_args(ParseResult* pr, String target_name, uint cursor_offset, String[] out_names) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CALL_EXPR) continue;
		if (n.name != target_name) continue;
		if (cursor_offset < n.start_offset || cursor_offset >= n.end_offset) continue;

		usz count = 0;
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.kind != ASSIGNMENT_EXPR) continue;

			// First child of ASSIGNMENT_EXPR is the name
			for (uint k = 0; k < pr.node_count; k++) {
				if (pr.nodes[k].parent != j) continue;
				if (pr.nodes[k].kind == NAME_EXPR && pr.nodes[k].name.len > 0) {
					if (count < out_names.len) {
						out_names[count] = pr.nodes[k].name;
						count++;
					}
				}
				break; // only first child
			}
		}
		return count;
	}
	return 0;
}

/**
 * Score how well a FUN_DECL's parameter names match the given named arguments.
 * Returns number of matching parameter names (higher = better).
 */
fn int score_named_args(ParseResult* pr, uint fun_idx, String[] named_args) {
	int score = 0;
	for (usz i = 0; i < named_args.len; i++) {
		for (uint k = 0; k < pr.node_count; k++) {
			AstNode* p = &pr.nodes[k];
			if (p.parent != fun_idx) continue;
			if (p.kind != PARAM) continue;
			if (p.name == named_args[i]) {
				score++;
				break;
			}
		}
	}
	return score;
}

/**
 * Search the AST for a declaration matching the target name.
 * Starts from the innermost scope containing the cursor offset
 * and works outward. Prefers function declarations in call context.
 * When multiple overloads match, prefers the one whose parameter
 * count matches the call's argument count.
 */
/**
 * Find a declaration in `pr` matching `target_name` at `cursor_offset`.
 *
 * Two-stage lookup used by features that need to anchor an identifier
 * to its declaration node within the same file (rename, references,
 * highlight, inlay hints, signature help, call hierarchy):
 *
 *   1. Scope-walk: innermost scope outward to FILE.
 *   2. Global fallback: scored search across the whole AST (matches
 *      members of unrelated classes/objects too).
 *
 * The global fallback is intentional for these features — they need
 * to find every binding of an identifier in the file. For
 * spec-conformant go-to-definition use `find_declaration_in_scope_chain`
 * instead and resolve unfound names via the workspace/dep paths.
 */
fn AstNode*? find_declaration_in_file(ParseResult* pr, String target_name, uint cursor_offset, bool is_call, TypeInfo* ti = null) {
	// Stage 1: scope-walk
	if (try node = find_declaration_in_scope_chain(pr, target_name, cursor_offset, is_call, ti)) {
		return node;
	}
	// Stage 2: global fallback
	AstNode* node = find_definition_in_ast_global_fallback(pr, target_name, cursor_offset, is_call, ti)!;
	if (node == null) return ast::NOT_FOUND~;
	return node;
}

/**
 * Scope-walk only: search innermost scope outward to FILE.
 *
 * Returns NOT_FOUND if no enclosing scope contains a matching
 * declaration. Does NOT search unrelated classes/objects — for
 * spec-conformant go-to-definition resolution.
 */
fn AstNode*? find_declaration_in_scope_chain(ParseResult* pr, String target_name, uint cursor_offset, bool is_call, TypeInfo* ti = null) {
	if (pr.node_count == 0) return ast::NOT_FOUND~;

	// If this is a call, find the argument count and types for overload resolution
	int call_arg_count = -1;
	String[16] call_arg_types;
	usz call_arg_type_count = 0;
	String[16] call_named_args;
	usz call_named_arg_count = 0;
	if (is_call) {
		call_arg_count = find_call_arg_count(pr, target_name, cursor_offset);
		call_arg_type_count = find_call_arg_types(pr, ti, target_name, cursor_offset, call_arg_types[..]);
		call_named_arg_count = find_call_named_args(pr, target_name, cursor_offset, call_named_args[..]);
	}

	// Find the innermost scope containing the cursor.
	// Walk all nodes, tracking the deepest container that contains the cursor.
	uint scope_idx = 0; // FILE node
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!is_scope_node(n.kind)) continue;
		if (cursor_offset >= n.start_offset && cursor_offset < n.end_offset) {
			// Check if this is deeper than our current best
			// (further in the array = more deeply nested)
			scope_idx = i;
		}
	}

	// Search from innermost scope outward to FILE
	uint current = scope_idx;
	while (true) {
		AstNode* scope = &pr.nodes[current];

		// Search direct children of this scope for matching declarations
		AstNode* first_match = null;
		AstNode*[16] func_candidates;
		uint[16] func_indices;
		usz func_count = 0;

		// Class members are visible throughout class body (no order constraint).
		// Local declarations (in BLOCK, FUN_DECL, LAMBDA_EXPR, FOR_STMT, CATCH_CLAUSE)
		// are only visible after their declaration point.
		bool is_class_scope = scope.kind == CLASS_DECL || scope.kind == INTERFACE_DECL ||
			scope.kind == OBJECT_DECL || scope.kind == COMPANION_OBJECT_DECL || scope.kind == FILE;

		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.parent != current) continue;
			if (!is_definition_target(n.kind)) continue;
			if (n.name != target_name) continue;

			// Declaration-before-use: in local scopes, skip declarations after cursor
			if (!is_class_scope && (n.kind == PROPERTY_DECL || n.kind == PARAM)) {
				if (n.start_offset > cursor_offset) continue;
			}

			if (first_match == null) {
				first_match = n;
			}
			if (n.kind == FUN_DECL && func_count < 16) {
				func_candidates[func_count] = n;
				func_indices[func_count] = i;
				func_count++;
			}
		}

		if (is_call && func_count > 0) {
			AstNode* picked = pick_best_overload(pr, func_candidates[:func_count], func_indices[:func_count], func_count, call_arg_count, call_arg_types[:call_arg_type_count], call_named_args[:call_named_arg_count]);
			if (picked != null) return picked;
		}
		if (first_match != null) {
			return first_match;
		}

		// Move to parent scope
		if (current == 0 || scope.parent == ast::NO_PARENT) {
			break; // Already at FILE level
		}
		current = scope.parent;
	}

	// Scope-walk exhausted with no match. Return NOT_FOUND; callers
	// needing the global fallback (rename/references/highlight/...)
	// invoke `find_declaration_in_file` which chains the fallback.
	return ast::NOT_FOUND~;
}

/**
 * Global fallback: scored search across the whole AST. Used by
 * `find_declaration_in_file` after the scope-walk fails. Not used
 * by spec-conformant go-to-definition.
 */
fn AstNode*? find_definition_in_ast_global_fallback(ParseResult* pr, String target_name, uint cursor_offset, bool is_call, TypeInfo* ti = null) {
	if (pr.node_count == 0) return ast::NOT_FOUND~;

	int call_arg_count = -1;
	String[16] call_arg_types;
	usz call_arg_type_count = 0;
	String[16] call_named_args;
	usz call_named_arg_count = 0;
	if (is_call) {
		call_arg_count = find_call_arg_count(pr, target_name, cursor_offset);
		call_arg_type_count = find_call_arg_types(pr, ti, target_name, cursor_offset, call_arg_types[..]);
		call_named_arg_count = find_call_named_args(pr, target_name, cursor_offset, call_named_args[..]);
	}

	AstNode* best_match = null;
	int best_score = -1;
	AstNode*[16] func_candidates;
	uint[16] func_indices;
	int[16] func_scores;
	usz func_count = 0;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!is_definition_target(n.kind)) continue;
		if (n.name != target_name) continue;

		// Score: higher = better match
		// +8: top-level (parent is FILE node 0)
		// +4: in an enclosing scope (ancestor contains cursor)
		// +2: declared before cursor
		// -2: nested inside a class/object that doesn't enclose cursor
		//     (penalize but don't exclude — document_highlight needs these)
		int score = 0;
		if (n.parent == 0 || n.parent == ast::NO_PARENT) {
			score += 8;
		}
		if (n.start_offset < cursor_offset) {
			score += 2;
		}
		if (n.parent < pr.node_count && n.parent != 0) {
			AstNode* parent = &pr.nodes[n.parent];
			if (cursor_offset >= parent.start_offset && cursor_offset < parent.end_offset) {
				score += 4;
			}
		}
		if (is_nested_in_non_enclosing_class(pr, i, cursor_offset)) {
			score -= 2;
		}

		if (score > best_score) {
			best_score = score;
			best_match = n;
		}
		if (n.kind == FUN_DECL && func_count < 16) {
			func_candidates[func_count] = n;
			func_indices[func_count] = i;
			func_scores[func_count] = score;
			func_count++;
		}
	}

	if (is_call && func_count > 0) {
		int max_func_score = -1;
		for (usz fi = 0; fi < func_count; fi++) {
			if (func_scores[fi] > max_func_score) max_func_score = func_scores[fi];
		}
		AstNode*[16] best_funcs;
		uint[16] best_func_indices;
		usz best_func_count = 0;
		for (usz fi = 0; fi < func_count; fi++) {
			if (func_scores[fi] == max_func_score && best_func_count < 16) {
				best_funcs[best_func_count] = func_candidates[fi];
				best_func_indices[best_func_count] = func_indices[fi];
				best_func_count++;
			}
		}
		AstNode* picked2 = pick_best_overload(pr, best_funcs[:best_func_count], best_func_indices[:best_func_count], best_func_count, call_arg_count, call_arg_types[:call_arg_type_count], call_named_args[:call_named_arg_count]);
		if (picked2 != null) return picked2;
		if (best_match != null) return best_match;
	}
	if (best_match != null) {
		return best_match;
	}

	return ast::NOT_FOUND~;
}

/**
 * Check if a declaration node at `node_idx` is nested inside a class/object
 * that does NOT enclose the cursor. Walk parent chain; if any ancestor is
 * a class-like node whose range does not contain cursor_offset, return true.
 * Top-level declarations (parent chain reaches FILE without hitting a class) pass.
 */
fn bool is_nested_in_non_enclosing_class(ParseResult* pr, uint node_idx, uint cursor_offset) {
	uint current = pr.nodes[node_idx].parent;
	while (current != ast::NO_PARENT && current < pr.node_count) {
		AstNode* n = &pr.nodes[current];
		if (n.kind == CLASS_DECL || n.kind == INTERFACE_DECL ||
			n.kind == OBJECT_DECL || n.kind == COMPANION_OBJECT_DECL) {
			// This ancestor is a class — does it enclose cursor?
			if (cursor_offset < n.start_offset || cursor_offset >= n.end_offset) {
				return true; // cursor outside this class → skip
			}
		}
		if (current == 0) break; // reached FILE
		current = n.parent;
	}
	return false;
}

/**
 * Check if a node kind represents a scope that can contain declarations.
 */
fn bool is_scope_node(NodeKind kind) {
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

/**
 * Check if a node kind can be a definition target (declarations + parameters).
 * Unlike is_declaration(), this also includes PARAM nodes so that function
 * parameters, for-loop variables, and catch parameters are resolvable.
 */
fn bool is_definition_target(NodeKind kind) {
	if (ast::is_declaration(kind)) return true;
	return kind == PARAM || kind == TYPE_PARAM;
}

/**
 * Build an LSP Location object from an AST node's name position.
 */
fn Object* build_location_from_node(String uri, AstNode* node) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)node.name_line);
	start.set("character", (int)node.name_col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)node.name_line);
	end_pos.set("character", (int)(node.name_col + node.name_len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", uri);
	location.set("range", range);

	return location;
}

/**
 * Determine if an identifier token is in a call context by checking
 * the next non-whitespace token after it. Returns true if the next
 * token is `(`, `{` (trailing lambda), or `<` (generic invocation).
 */
fn bool is_call_context(String content, Token tok) {
	usz after_pos = (usz)tok.offset + (usz)tok.len;
	if (after_pos >= content.len) return false;

	// Lex from just after the cursor token to find the next token
	Lexer lex = lexer::init(content[after_pos..]);
	Token next = lex.next();

	return next.kind == LPAREN || next.kind == LCURL || next.kind == LANGLE;
}

/**
 * AST-based call context detection: check if the identifier at the
 * given offset is the name of a CALL_EXPR node. This is more reliable
 * than the lexer-based heuristic for multi-line calls and trailing lambdas.
 */
fn bool is_call_context_ast(ParseResult* pr, uint offset) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind == CALL_EXPR && n.name_offset == offset && n.name_len > 0) {
			return true;
		}
	}
	return false;
}

// ── Dot-member definition lookup ──────────────────────────────────

faultdef NOT_DOT_MEMBER;

/**
 * Check if a token is the member name of a DOT_EXPR (e.g., `foo.bar` — bar is a dot member).
 */
fn bool is_token_dot_member(ParseResult* pr, Token tok) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != DOT_EXPR) continue;
		if (n.name != tok.text) continue;
		if (n.name_line == tok.line && n.name_col == tok.col) return true;
	}
	return false;
}

/**
 * Check if the token is a member of a DOT_EXPR, resolve the receiver
 * type, and find the member declaration in the receiver class.
 */
fn Object*? find_dot_member_definition(ParseResult* pr, TypeInfo* ti, DocumentStore* store,
		WorkspaceIndex* workspace, Token tok, String current_uri) {
	// Find the DOT_EXPR that has this token as its member name
	uint dot_count = 0;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != DOT_EXPR) continue;
		dot_count++;
		if (n.name != tok.text) continue;
		if (n.name_line != tok.line || n.name_col != tok.col) continue;

		// Found the DOT_EXPR - resolve receiver type from first child
		TypeRef receiver_type = types::TYPE_UNKNOWN;

		uint dot_idx = i;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent == dot_idx) {
				// First child = receiver
				if (ti.has_type[j]) {
					receiver_type = ti.node_types[j];
				} else if (pr.nodes[j].kind == NAME_EXPR) {
					// Try to find the receiver's declaration type (scope-aware)
					String recv_name = pr.nodes[j].name;
					uint recv_offset = pr.nodes[j].start_offset;
					if (recv_name == "this") {
						// Resolve `this` to enclosing receiver type (extension fn,
						// receiver lambda, or enclosing class).
						String this_type = resolve_this_receiver_type(pr, workspace, store, recv_offset);
						if (this_type.len > 0) {
							receiver_type.kind = SIMPLE;
							receiver_type.name = this_type;
						}
					} else {
						receiver_type = find_receiver_decl_type(pr, ti, recv_name, recv_offset);
					}
				} else if (pr.nodes[j].kind == THIS_EXPR) {
					// Explicit `this` (parsed as THIS_EXPR, not NAME_EXPR).
					// Resolve to enclosing receiver type (extension fn, receiver
					// lambda, or enclosing class).
					uint recv_offset = pr.nodes[j].start_offset;
					String this_type = resolve_this_receiver_type(pr, workspace, store, recv_offset);
					// Strip generics: "ConsumedStream<K, V>" -> "ConsumedStream"
					for (usz k = 0; k < this_type.len; k++) {
						if (this_type[k] == '<') { this_type = this_type[:k]; break; }
					}
					if (this_type.len > 0) {
						receiver_type.kind = SIMPLE;
						receiver_type.name = this_type;
					}
				} else if (pr.nodes[j].kind == DOT_EXPR) {
					// Chained access: a.b.c — inner DOT_EXPR is the receiver.
					// Try type info first, then resolve via inner DOT_EXPR's member name
					// by looking up the inner receiver type and its member's return type.
					if (ti.has_type[j]) {
						receiver_type = ti.node_types[j];
					} else {
						// Try to resolve inner chain: get the inner DOT_EXPR's member name
						// and receiver, look up that member's type in workspace/deps.
						receiver_type = resolve_dot_expr_type(pr, ti, workspace, j);
					}
				} else if (pr.nodes[j].kind == CALL_EXPR) {
					// Receiver is a call: factory().member — check type info first,
					// fall back to resolving the call's receiver class.
					if (ti.has_type[j]) {
						receiver_type = ti.node_types[j];
					} else {
						String recv_class = resolve_call_receiver_class(pr, workspace, store, j);
						if (recv_class.len > 0) {
							receiver_type.kind = SIMPLE;
							receiver_type.name = recv_class;
						}
					}
				}
				break;
			}
		}

		if (receiver_type.kind == UNKNOWN) {
			// Fallback: check if receiver is a known JDK/dependency class
			// This handles cases like System.nanoTime() where System is a
			// java.lang class not declared in any Kotlin source file.
			if (workspace != null && workspace.dep_index.initialized) {
				String recv_name = "";
				for (uint j = 0; j < pr.node_count; j++) {
					if (pr.nodes[j].parent == dot_idx && pr.nodes[j].kind == NAME_EXPR) {
						recv_name = pr.nodes[j].name;
						break;
					}
				}
				if (recv_name.len > 0) {
					// If recv_name resolves to a known dep class/object/etc., the
					// receiver is a class reference (Static.member). Otherwise treat
					// as instance (permissive).
					bool recv_is_class_ref = is_dep_class_name(&workspace.dep_index, recv_name);
					Object* dep_result = find_dep_member_definition(&workspace.dep_index, recv_name, tok.text, pr, recv_is_class_ref);
					if (dep_result != null) return dep_result;
				}

				// FQN fallback: reconstruct the full dot chain (e.g., "org.apache.kafka.streams")
				// and try to split it as package.ClassName for dep member lookup.
				// This handles fully-qualified references like:
				//   org.apache.kafka.streams.StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG
				uint recv_idx = pr.node_count; // sentinel
				for (uint j = 0; j < pr.node_count; j++) {
					if (pr.nodes[j].parent == dot_idx) {
						recv_idx = j;
						break;
					}
				}
				if (recv_idx < pr.node_count) {
					String chain = reconstruct_dot_chain(pr, recv_idx);
					log::debug("[def] FQN: reconstructed chain='%s', member='%s'", chain, tok.text);
					if (chain.len > 0) {
						if (try result = find_definition_by_fqn(&workspace.dep_index, chain, tok.text)) {
							return result;
						}
					}
				}
			}

			// Fallback: search extension functions by member name across all
			// receiver types in member_cache. This handles chained calls where
			// we can't resolve the receiver type but the extension function name
			// is unique enough (filtered by import visibility).
			if (workspace != null) {
				if (try result = find_extension_by_name(workspace, tok.text, current_uri, pr)) {
					return result;
				}
			}
			// Import-aware dep extension fallback: look up member name in dep
			// index filtered by file imports (handles e.g. call.respond() from ktor)
			if (workspace != null && workspace.dep_index.initialized) {
				Object* import_result = find_dot_member_by_import(&workspace.dep_index, pr, tok.text, current_uri);
				if (import_result != null) return import_result;
			}
			// Last resort: any workspace extension by name, ignoring imports.
			// Helps when extension is reachable in workspace but not yet imported,
			// or imported via a wildcard the import map didn't expand.
			if (workspace != null) {
				if (try result = find_extension_by_name_unimported(workspace, tok.text, current_uri)) {
					return result;
				}
			}
			return NOT_DOT_MEMBER~;
		}

		String type_name = receiver_type.name;
		String member_name = tok.text;

		// Search for the member declaration in the type's class declaration
		// First, search same-file AST for class with this type name
		if (try result = find_member_in_class_ast(pr, type_name, member_name, current_uri)) {
			return result;
		}

		// Search workspace for the type's class and its members
		if (workspace != null) {
			if (try result = find_member_in_workspace_class(workspace, store, type_name, member_name)) {
				return result;
			}
		}

		// Search dependency index by receiver type name
		if (workspace != null && workspace.dep_index.initialized) {
			Object* dep_result = find_dep_member_definition(&workspace.dep_index, type_name, member_name, pr, receiver_type.is_class_ref);
			if (dep_result != null) return dep_result;
		}

		// Search workspace for extension functions matching receiver type
		if (workspace != null) {
			if (try result = find_extension_by_receiver_and_name(workspace, type_name, member_name, current_uri, pr)) {
				return result;
			}
			// Receiver-name mismatch fallback: try by-name only (still
			// import-filtered). Handles cases where the resolved receiver
			// type differs from the declared extension receiver due to
			// supertype/generic type relationships.
			if (try result = find_extension_by_name(workspace, member_name, current_uri, pr)) {
				return result;
			}
		}

		// Check if this is a known scope function (apply, let, also, run, etc.)
		// These are extension functions available on all types, defined in
		// kotlin.StandardKt. Navigate to their definition in stdlib sources
		// rather than falling through to the generic dep lookup which would
		// incorrectly match unrelated methods (e.g., BiFunction.apply).
		if (source_nav::is_scope_function(member_name)) {
			if (workspace != null) {
				Object* scope_result = source_nav::find_scope_function_definition(
					&workspace.dep_index, member_name);
				if (scope_result != null) return scope_result;
			}
			// Even if sources aren't available, return null rather than
			// falling through to the wrong definition
			return null;
		}

		// Last resort: any workspace extension by name, ignoring imports.
		// Handles workspace extensions where the resolved receiver type
		// doesn't match the declared receiver (e.g. generics, supertypes)
		// AND the extension isn't imported by simple name (e.g. wildcard
		// import that the import map didn't expand).
		if (workspace != null) {
			if (try result = find_extension_by_name_unimported(workspace, member_name, current_uri)) {
				return result;
			}
		}

		break;
	}

	return NOT_DOT_MEMBER~;
}

/**
 * Search for a member declaration inside a class in the same-file AST.
 * Checks declarations (fun, property, nested class, etc.) and data class
 * constructor parameters with var/val flags (PARAM with MOD_VAR/MOD_FINAL).
 */
fn Object*? find_member_in_class_ast(ParseResult* pr, String class_name, String member_name, String uri) {
	// Find the class declaration
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if ((n.kind == CLASS_DECL || n.kind == INTERFACE_DECL || n.kind == OBJECT_DECL) &&
			n.name == class_name) {
			// Search children for the member
			for (uint j = 0; j < pr.node_count; j++) {
				AstNode* child = &pr.nodes[j];
				if (child.parent != i) continue;

				// Descend into companion object — its members are accessible via ClassName.member
				if (child.kind == COMPANION_OBJECT_DECL) {
					for (uint k = 0; k < pr.node_count; k++) {
						AstNode* comp_child = &pr.nodes[k];
						if (comp_child.parent != j) continue;
						if (comp_child.name != member_name) continue;

						if (ast::is_declaration(comp_child.kind)) {
							return build_location_from_node(uri, comp_child);
						}
						if (comp_child.kind == PARAM) {
							if ((comp_child.mod_flags & ast::MOD_VAR) != 0 || (comp_child.mod_flags & ast::MOD_FINAL) != 0) {
								return build_location_from_node(uri, comp_child);
							}
						}
					}
					continue;
				}

				if (child.name != member_name) continue;

				// Standard declarations (fun, property, nested class, etc.)
				if (ast::is_declaration(child.kind)) {
					return build_location_from_node(uri, child);
				}

				// Data class constructor params with var/val
				if (child.kind == PARAM) {
					if ((child.mod_flags & ast::MOD_VAR) != 0 || (child.mod_flags & ast::MOD_FINAL) != 0) {
						return build_location_from_node(uri, child);
					}
				}
			}
		}
	}

	return NOT_DOT_MEMBER~;
}

/**
 * Search the workspace index for a class and find a member declaration
 * by parsing the class's source file.
 */
fn Object*? find_member_in_workspace_class(WorkspaceIndex* workspace, DocumentStore* store,
		String class_name, String member_name) {
	return find_member_in_workspace_class_depth(workspace, store, class_name, member_name, 0);
}

const int MAX_SUPERTYPE_DEPTH = 5;

fn Object*? find_member_in_workspace_class_depth(WorkspaceIndex* workspace, DocumentStore* store,
		String class_name, String member_name, int depth) {
	if (depth > MAX_SUPERTYPE_DEPTH) return NOT_DOT_MEMBER~;

	// Try the member cache first (fast path — no re-parsing)
	if (try members = workspace.lookup_members(class_name)) {
		for (usz i = 0; i < members.len(); i++) {
			MemberDecl* m = &(*members)[i];
			if (m.name != member_name) continue;

			// Standard declarations
			if (ast::is_declaration(m.node_kind)) {
				return build_location_from_member(m);
			}

			// Data class constructor params with var/val
			if (m.node_kind == PARAM) {
				if ((m.mod_flags & ast::MOD_VAR) != 0 || (m.mod_flags & ast::MOD_FINAL) != 0) {
					return build_location_from_member(m);
				}
			}
		}

		// Not found in direct class — check supertypes
		if (try indices = workspace.lookup_by_name(class_name)) {
			for (usz i = 0; i < indices.len(); i++) {
				WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
				if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
					sym.kind != SymbolKind.OBJECT) continue;
				for (usz s = 0; s < sym.supertype_count; s++) {
					if (try result = find_member_in_workspace_class_depth(workspace, store, sym.supertypes[s], member_name, depth + 1)) {
						return result;
					}
				}
			}
		}
		// member_cache had an entry but member not found — fall through to
		// parse-based lookup (handles duplicate class names across files)
	}

	// Fall back to parsing (cache miss or member not found in cached class)
	if (try indices = workspace.lookup_by_name(class_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
				sym.kind != SymbolKind.OBJECT) continue;

			// Try to parse the file and find the member
			String content;
			char[] disk_data;
			bool got_content = false;

			if (store != null) {
				if (try doc = store.get(sym.uri)) {
					content = doc.content;
					got_content = true;
				}
			}
			if (!got_content) {
				String file_path = workspace::uri_to_path(sym.uri);
				if (try d = std::io::file::load(tmem, file_path)) {
					disk_data = d;
					content = (String)disk_data;
				} else {
					continue;
				}
			}

			ParseResult* pr = mem::new(ParseResult);
			defer mem::free(pr);
			parser::parse(content, pr);

			// Find the class, then its member
			if (try result = find_member_in_class_ast(pr, class_name, member_name, sym.uri)) {
				return result;
			}

			// Not found in direct class — check supertypes
			for (usz s = 0; s < sym.supertype_count; s++) {
				if (try result = find_member_in_workspace_class_depth(workspace, store, sym.supertypes[s], member_name, depth + 1)) {
					return result;
				}
			}
		}
	}

	// Last resort: search member_cache for entries where the class_name appears
	// as a nested class/interface/object member. This handles nested types not
	// in the workspace name_index (e.g., DocumentedErrors.Async.Utbetaling).
	if (try all_members = workspace.lookup_members(class_name)) {
		// Already checked above — try finding other classes with same name
		// by scanning all member_cache entries for nested class members
	}
	// Search all cached member lists for a nested class with this name,
	// then check if THAT nested class has our target member
	foreach (&key : workspace.member_cache.tkeys()) {
		if (try parent_members = workspace.member_cache.get_ref(*key)) {
			for (usz i = 0; i < parent_members.len(); i++) {
				MemberDecl* pm = &(*parent_members)[i];
				if (pm.name != class_name) continue;
				if (pm.node_kind != CLASS_DECL && pm.node_kind != INTERFACE_DECL && pm.node_kind != OBJECT_DECL) continue;
				// Found a nested class with this name — check if its members are cached
				if (try nested_members = workspace.lookup_members(class_name)) {
					for (usz j = 0; j < nested_members.len(); j++) {
						MemberDecl* nm = &(*nested_members)[j];
						if (nm.name != member_name) continue;
						if (ast::is_declaration(nm.node_kind)) return build_location_from_member(nm);
						if (nm.node_kind == PARAM && ((nm.mod_flags & ast::MOD_VAR) != 0 || (nm.mod_flags & ast::MOD_FINAL) != 0)) {
							return build_location_from_member(nm);
						}
					}
				}
				// Members not cached — parse the file containing this nested class
				String content;
				char[] disk_data;
				bool got_content = false;
				if (store != null) {
					if (try doc = store.get(pm.uri)) {
						content = doc.content;
						got_content = true;
					}
				}
				if (!got_content) {
					String file_path = workspace::uri_to_path(pm.uri);
					if (try d = std::io::file::load(tmem, file_path)) {
						disk_data = d;
						content = (String)disk_data;
					} else {
						continue;
					}
				}
				ParseResult* pr = mem::new(ParseResult);
				defer mem::free(pr);
				parser::parse(content, pr);
				if (try result = find_member_in_class_ast(pr, class_name, member_name, pm.uri)) {
					return result;
				}
			}
		}
	}

	return NOT_DOT_MEMBER~;
}

/**
 * Build an LSP Location object from a cached MemberDecl.
 */
fn Object* build_location_from_member(MemberDecl* m) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)m.line);
	start.set("character", (int)m.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)m.line);
	end_pos.set("character", (int)(m.col + m.name_len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", m.uri);
	location.set("range", range);

	return location;
}

// ── Dependency member definition lookup ───────────────────────────

/**
 * Look up a dot-member in the dependency index. First verifies that
 * the receiver name matches a known class/interface/enum, then searches
 * for a matching method or field with that class_name.
 *
 * This handles JDK classes (System.nanoTime, Files.readAllBytes, etc.)
 * and any other dependency class whose members are indexed.
 */
/**
 * Kotlin spec §11/§16: filter dep members by receiver shape.
 *
 *   - `ClassName.member` (receiver is class reference) — only static members
 *     reachable: Java statics, Kotlin companion-object members, `const val`
 *     at top level. Instance members must be accessed through an instance.
 *
 *   - `instance.member` (receiver is a value) — instance members and
 *     extensions reachable. Companion-object members are NOT reachable
 *     via an instance in Kotlin (unlike Java statics through instances).
 *
 * For a value reference `instance.companionMember` we still want to be
 * forgiving today because:
 *   1. Many tests/users rely on the JVM-style instance-of-static lookup.
 *   2. Kotlin compiler reports an error but IDEs typically still resolve
 *      the symbol so the user can navigate.
 *
 * Phase 2 keeps the instance-side permissive (skip filter when
 * `receiver_is_class_ref == false`); the strict class-ref side is the
 * actual fix for Bug 2-style false positives like `nob.module {` matching
 * an unrelated PARAM. When `receiver_is_class_ref == true` we require the
 * dep symbol to be `is_static`. (`@JvmStatic` deferred — no current test.)
 */
fn bool is_member_accessible(DepSymbol* sym, bool receiver_is_class_ref) {
	if (sym == null) return false;
	if (receiver_is_class_ref) {
		return sym.is_static;
	}
	// Instance receiver — accept anything for now (strict mode is future work).
	return true;
}

/**
 * Heuristic: does `name` resolve to a class/interface/enum/object/annotation
 * in the dep index? Used in the UNKNOWN-receiver fallback path of
 * `find_dot_member_definition` to decide whether `Name.member` is a static
 * (class-ref) access or an instance access.
 *
 * Cheap: one lookup_by_name + scan of up to 16 matches.
 */
fn bool is_dep_class_name(DependencyIndex* dep_index, String name) {
	if (dep_index == null || !dep_index.initialized || name.len == 0) return false;
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(name, &matches);
	for (usz i = 0; i < count; i++) {
		switch (matches[i].kind) {
			case DEP_CLASS:
			case DEP_INTERFACE:
			case DEP_ENUM:
			case DEP_OBJECT:
			case DEP_ANNOTATION:
				return true;
			default:
				continue;
		}
	}
	return false;
}

fn Object* find_dep_member_definition(DependencyIndex* dep_index, String class_name, String member_name, ParseResult* pr = null, bool receiver_is_class_ref = false) {
	// First verify the class exists in the dep index
	DepSymbol*[16] class_matches;
	usz class_count = dep_index.lookup_by_name(class_name, &class_matches);
	bool is_known_class = false;

	// If we have AST, use imports to prefer the correct class when multiple exist
	String preferred_pkg = "";
	if (pr != null) {
		ImportMap imports = workspace::build_import_map(pr);
		for (usz i = 0; i < imports.import_count; i++) {
			if (imports.import_names[i] == class_name && !imports.is_star[i]) {
				// Extract package from full import path: "com.example.Record" -> "com.example"
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

	// Find the class, preferring imported package
	DepSymbol* best_class = null;
	for (usz i = 0; i < class_count; i++) {
		if (class_matches[i].kind != DEP_CLASS && class_matches[i].kind != DEP_INTERFACE &&
			class_matches[i].kind != DEP_ENUM && class_matches[i].kind != DEP_ANNOTATION &&
			class_matches[i].kind != DEP_OBJECT) continue;
		is_known_class = true;
		if (preferred_pkg.len > 0 && class_matches[i].package_name == preferred_pkg) {
			best_class = class_matches[i];
			break;
		}
		if (best_class == null) best_class = class_matches[i];
	}
	if (!is_known_class) {
		return null;
	}

	// Use the best class's package to filter members
	String target_class = class_name;
	String target_pkg = best_class != null ? best_class.package_name : "";

	// Look up the member by name, filter by class_name and prefer matching package
	DepSymbol*[32] member_matches;
	usz member_count = dep_index.lookup_by_name(member_name, &member_matches);

	DepSymbol* best = null;
	for (usz i = 0; i < member_count; i++) {
		if (member_matches[i].class_name != target_class) continue;
		if (member_matches[i].kind != DEP_METHOD && member_matches[i].kind != DEP_FIELD) continue;
		if (!is_member_accessible(member_matches[i], receiver_is_class_ref)) continue;
		if (target_pkg.len > 0 && member_matches[i].package_name == target_pkg) {
			best = member_matches[i];
			break;
		}
		if (best == null) best = member_matches[i];
	}

	if (best == null) {
		// Walk supertypes to find extension functions indexed under parent types.
		// E.g. List.toSet() -> toSet is indexed under Iterable (the receiver type).
		if (best_class != null) {
			for (usz s = 0; s < jar_index::MAX_DEP_SUPERTYPES; s++) {
				if (best_class.supertypes[s].len == 0) break;
				Object* super_result = find_dep_member_in_class(dep_index, best_class.supertypes[s], member_name);
				if (super_result != null) return super_result;
			}
		}
		return null;
	}

	return source_nav::resolve_dep_definition(best);
}

/**
 * Look up a member by class_name in the dep index without verifying class existence.
 * Used for supertype walk where we already know the hierarchy is valid.
 */
fn Object* find_dep_member_in_class(DependencyIndex* dep_index, String class_name, String member_name) {
	DepSymbol*[32] member_matches;
	usz member_count = dep_index.lookup_by_name(member_name, &member_matches);

	for (usz i = 0; i < member_count; i++) {
		if (member_matches[i].class_name != class_name) continue;
		if (member_matches[i].kind != DEP_METHOD && member_matches[i].kind != DEP_FIELD) continue;
		return source_nav::resolve_dep_definition(member_matches[i]);
	}
	return null;
}

/**
 * Reconstruct the full dotted text from a DOT_EXPR chain or NAME_EXPR.
 * For a chain like a.b.c.D (nested DOT_EXPRs), returns "a.b.c.D".
 * For a NAME_EXPR, returns the name.
 * Returns empty string if the node structure is unexpected.
 */
fn String reconstruct_dot_chain(ParseResult* pr, uint node_idx) {
	if (node_idx >= pr.node_count) return "";

	AstNode* n = &pr.nodes[node_idx];

	if (n.kind == NAME_EXPR) {
		return n.name;
	}

	if (n.kind != DOT_EXPR) return "";

	// Find the receiver child (first child of this DOT_EXPR)
	uint child_idx = pr.node_count; // sentinel
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent == node_idx) {
			child_idx = j;
			break;
		}
	}

	String receiver_text = reconstruct_dot_chain(pr, child_idx);
	if (receiver_text.len == 0) return n.name;

	return string::tformat("%s.%s", receiver_text, n.name);
}

/**
 * Try to resolve a fully-qualified name as package.ClassName and look up a member.
 * Splits the FQN at each dot, trying the last segment as class_name and the rest
 * as package_name. Also handles the case where member_name refers to the class itself
 * (i.e., cursor is on the class name part of the FQN, and member_name is the class).
 *
 * When the dep symbol is found but source JAR is unavailable, returns a synthesized
 * null-location rather than falling through — the FQN is unambiguous.
 */
fn Object*? find_definition_by_fqn(DependencyIndex* dep_index, String receiver_chain, String member_name) {
	if (dep_index == null || !dep_index.initialized) return FQN_NOT_FOUND~;

	// Try interpreting receiver_chain as "package.ClassName"
	// Split at last dot: package = everything before, class = last segment
	usz last_dot = 0;
	bool has_dot = false;
	for (usz i = 0; i < receiver_chain.len; i++) {
		if (receiver_chain[i] == '.') {
			last_dot = i;
			has_dot = true;
		}
	}

	if (has_dot) {
		String pkg = receiver_chain[:last_dot];
		String cls = receiver_chain[last_dot + 1..];

		// First: check if cursor is on a member of the class (e.g., NUM_STANDBY_REPLICAS_CONFIG)
		DepSymbol*[32] member_matches;
		usz member_count = dep_index.lookup_by_name(member_name, &member_matches);
		for (usz i = 0; i < member_count; i++) {
			if (member_matches[i].class_name != cls) continue;
			if (member_matches[i].package_name != pkg) continue;
			if (member_matches[i].kind != DEP_METHOD && member_matches[i].kind != DEP_FIELD) continue;
			Object* result = source_nav::resolve_dep_definition(member_matches[i]);
			if (result != null) return result;
			// Found the right symbol but no source — return empty location
			// to prevent falling through to wrong results.
			log::debug("[def] FQN member matched %s.%s.%s but no source available", pkg, cls, member_name);
			return null;
		}

		// Second: check if the receiver_chain itself is a class reference
		// and cursor is on a companion member or class-level constant.
		DepSymbol*[16] class_matches;
		usz class_count = dep_index.lookup_by_name(cls, &class_matches);
		for (usz i = 0; i < class_count; i++) {
			if (class_matches[i].package_name != pkg) continue;
			if (class_matches[i].kind == DEP_CLASS || class_matches[i].kind == DEP_INTERFACE ||
				class_matches[i].kind == DEP_ENUM || class_matches[i].kind == DEP_OBJECT) {
				// Found the class — now look up member under this exact package+class
				for (usz m = 0; m < member_count; m++) {
					if (member_matches[m].class_name == cls && member_matches[m].package_name == pkg) {
						Object* result = source_nav::resolve_dep_definition(member_matches[m]);
						if (result != null) return result;
						log::debug("[def] FQN class+member matched %s.%s.%s but no source available", pkg, cls, member_name);
						return null;
					}
				}
			}
		}
	}

	// Also try: the entire receiver_chain + member_name forms "package.ClassName"
	// E.g., receiver_chain = "org.apache.kafka.streams", member_name = "StreamsConfig"
	// → package = "org.apache.kafka.streams", class = "StreamsConfig"
	DepSymbol*[16] class_matches;
	usz class_count = dep_index.lookup_by_name(member_name, &class_matches);
	for (usz i = 0; i < class_count; i++) {
		if (class_matches[i].package_name != receiver_chain) continue;
		if (class_matches[i].kind == DEP_CLASS || class_matches[i].kind == DEP_INTERFACE ||
			class_matches[i].kind == DEP_ENUM || class_matches[i].kind == DEP_OBJECT) {
			Object* result = source_nav::resolve_dep_definition(class_matches[i]);
			if (result != null) return result;
			// FQN class matched but no source — return null to stop further lookups
			log::debug("[def] FQN class matched %s.%s but no source available", receiver_chain, member_name);
			return null;
		}
	}

	return FQN_NOT_FOUND~;
}

faultdef FQN_NOT_FOUND;
faultdef NOT_TEXT_FQN;

/**
 * Text-based FQN detection and dep lookup.
 * Scans the source text around the token to detect if it's part of a
 * dot-separated chain (e.g., org.apache.kafka.streams.StreamsConfig).
 * If so, reconstructs the prefix and tries dep lookup.
 * This is independent of AST DOT_EXPR matching — handles cases where
 * the AST position doesn't match the lexer token position.
 */
fn Object*? find_definition_by_text_fqn(String source, Token tok, DependencyIndex* dep_index) {
	if (dep_index == null || !dep_index.initialized) return NOT_TEXT_FQN~;

	// Check if there's a dot immediately before the token
	usz tok_off = (usz)tok.offset;
	if (tok_off == 0 || source[tok_off - 1] != '.') return NOT_TEXT_FQN~;

	// Walk backward from the dot to reconstruct the prefix chain
	// e.g., for "org.apache.kafka.streams.StreamsConfig", starting before "StreamsConfig"
	// we walk back through "org.apache.kafka.streams"
	usz prefix_end = tok_off - 1; // points at the dot
	usz prefix_start = prefix_end;

	// Walk backward: accept identifiers and dots
	while (prefix_start > 0) {
		char c = source[prefix_start - 1];
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '_' || c == '.') {
			prefix_start--;
		} else {
			break;
		}
	}

	if (prefix_start >= prefix_end) return NOT_TEXT_FQN~;

	String prefix = source[prefix_start..prefix_end - 1]; // exclude trailing dot
	if (prefix.len == 0) return NOT_TEXT_FQN~;

	// Also check if there's a dot AFTER the token — to determine if cursor
	// is on a middle segment (class name) vs the last segment (member name)
	usz tok_end = tok_off + (usz)tok.text.len;
	bool has_dot_after = tok_end < source.len && source[tok_end] == '.';

	String member_name = tok.text;

	if (has_dot_after) {
		// Token is a middle segment — e.g., "StreamsConfig" in "...StreamsConfig.NUM_..."
		// The prefix is the package, the token is the class name
		// Try: prefix = package, member_name = class name → look up class in dep index
		DepSymbol*[16] class_matches;
		usz class_count = dep_index.lookup_by_name(member_name, &class_matches);
		for (usz i = 0; i < class_count; i++) {
			if (class_matches[i].package_name != prefix) continue;
			if (class_matches[i].kind == DEP_CLASS || class_matches[i].kind == DEP_INTERFACE ||
				class_matches[i].kind == DEP_ENUM || class_matches[i].kind == DEP_OBJECT) {
				Object* result = source_nav::resolve_dep_definition(class_matches[i]);
				if (result != null) return result;
				// Found but no source — return null to stop further lookups
				log::debug("[def] text-FQN class matched %s.%s but no source", prefix, member_name);
				return null;
			}
		}
	}

	// Token is the last segment — try as member of a FQN class
	// prefix might be "org.apache.kafka.streams.StreamsConfig" or "org.apache.kafka.streams"
	if (try result = find_definition_by_fqn(dep_index, prefix, member_name)) {
		return result;
	}

	return NOT_TEXT_FQN~;
}

// ── Receiver lambda member definition lookup ──────────────────────

faultdef NOT_RECEIVER_MEMBER;

/**
 * Check if a name is declared locally within the innermost LAMBDA_EXPR
 * scope containing the cursor. This is used to determine if a name
 * should resolve to a lambda-local declaration rather than a receiver
 * member. In Kotlin, locals inside a lambda shadow receiver members.
 */
fn bool is_declared_in_lambda_scope(ParseResult* pr, String name, uint cursor_offset) {
	// Find the innermost lambda containing the cursor
	uint lambda_idx = ast::NO_PARENT;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != LAMBDA_EXPR) continue;
		if (cursor_offset >= n.start_offset && cursor_offset < n.end_offset) {
			lambda_idx = i;
		}
	}
	if (lambda_idx == ast::NO_PARENT) return false;

	// Check direct children of this lambda for matching declarations
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.parent != lambda_idx) continue;
		if (n.name != name) continue;
		if (is_definition_target(n.kind)) return true;
	}

	// Also check nested blocks inside the lambda (but NOT nested lambdas)
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != BLOCK) continue;
		if (n.parent != lambda_idx) continue;

		// Check children of this block
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* child = &pr.nodes[j];
			if (child.parent != i) continue;
			if (child.name != name) continue;
			if (is_definition_target(child.kind)) return true;
		}
	}

	return false;
}

/**
 * If the cursor is inside a receiver lambda, resolve the receiver type
 * and find the member declaration in the receiver class.
 *
 * For example, in `nob.module { src = "example" }` where `module` takes
 * `Module.() -> Unit`, navigating from `src` should go to Module's `src`
 * property, not to some other `src` in the file.
 */
/**
 * Resolve the type of `this` at the given cursor offset.
 *
 * Walks ancestors from the cursor outward. Returns the receiver type name
 * for the innermost enclosing scope that defines `this`:
 *   1. LAMBDA_EXPR: derive lambda receiver type from the enclosing CALL_EXPR.
 *      Strategy: resolve the call's receiver expression type, then look up the
 *      callee method on that class and read the lambda param's receiver type.
 *      Falls back to scanning workspace.member_cache when the call's receiver
 *      type can't be resolved (and the lambda receiver type can be inferred
 *      from the workspace symbol alone, e.g. top-level extension fns).
 *   2. FUN_DECL or PROPERTY_DECL extension receiver (extra_text).
 *   3. Enclosing CLASS_DECL/OBJECT_DECL/INTERFACE_DECL.
 *
 * Returns empty string when no enclosing receiver is found.
 */
fn String resolve_this_receiver_type(ParseResult* pr, WorkspaceIndex* workspace,
		DocumentStore* store, uint cursor_offset) {
	// Find innermost ancestor (smallest enclosing node) by offset range.
	uint innermost = ast::NO_PARENT;
	uint best_size = (uint)-1;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (cursor_offset < n.start_offset || cursor_offset >= n.end_offset) continue;
		uint size = n.end_offset - n.start_offset;
		if (size < best_size) {
			best_size = size;
			innermost = i;
		}
	}
	if (innermost == ast::NO_PARENT) return "";

	uint current = innermost;
	while (current != ast::NO_PARENT) {
		AstNode* n = &pr.nodes[current];

		// Lambda with implicit receiver: derive from enclosing call's lambda param type
		if (n.kind == LAMBDA_EXPR) {
			uint call_idx = find_call_parent_of_lambda_def(pr, current);
			if (call_idx != ast::NO_PARENT) {
				String callee_name = pr.nodes[call_idx].name;

				// Step 1: resolve the call's receiver class (the type of the
				// expression on which the method is called). For `obj.branch(...)`,
				// that's the type of `obj`.
				String recv_class = resolve_call_receiver_class(pr, workspace, store, call_idx);

				// Step 2: when we know the receiver class, look up the called
				// method on that class and read the lambda param's receiver type.
				if (recv_class.len > 0 && callee_name.len > 0 && workspace != null) {
					String lambda_recv = find_lambda_receiver_for_class_method(
						workspace, recv_class, callee_name);
					if (lambda_recv.len > 0) return lambda_recv;
				}

				// Step 3: same-file FUN_DECL fallback (top-level extension fns).
				String receiver_type = find_receiver_type_for_call_def(pr, call_idx);
				if (receiver_type.len == 0 && workspace != null && callee_name.len > 0) {
					receiver_type = find_lambda_receiver_in_workspace(
						workspace, store, callee_name);
				}
				if (receiver_type.len > 0) {
					// Strip generics: "MappedStream<K, V>" -> "MappedStream"
					for (usz k = 0; k < receiver_type.len; k++) {
						if (receiver_type[k] == '<') {
							receiver_type = receiver_type[:k];
							break;
						}
					}
					return receiver_type;
				}
			}
		}

		// Extension fun/property: receiver type stored in extra_text
		if ((n.kind == FUN_DECL || n.kind == PROPERTY_DECL) && n.extra_text.len > 0) {
			String receiver = n.extra_text;
			if (receiver.len > 0 && receiver[receiver.len - 1] == '?') {
				receiver = receiver[:receiver.len - 1];
			}
			for (usz k = 0; k < receiver.len; k++) {
				if (receiver[k] == '<') {
					receiver = receiver[:k];
					break;
				}
			}
			if (receiver.len > 0) return receiver;
		}

		// Enclosing class/object/interface
		if ((n.kind == CLASS_DECL || n.kind == OBJECT_DECL || n.kind == INTERFACE_DECL) && n.name.len > 0) {
			return n.name;
		}

		current = n.parent;
	}
	return "";
}

/**
 * Resolve the receiver class name for a CALL_EXPR. Returns the class on which
 * the method is being called (e.g. "ConsumedStream" for `consumed.branch(...)`).
 * Returns empty string when the call has no receiver or the type can't be resolved.
 */
fn String resolve_call_receiver_class(ParseResult* pr, WorkspaceIndex* workspace,
		DocumentStore* store, uint call_idx) {
	// Find DOT_EXPR child (the callee). For `a.b.method(...)`, callee is the
	// outer DOT_EXPR whose member name = method name.
	// Trailing-lambda calls (`obj.method(args) { lambda }`) wrap an inner
	// CALL_EXPR — descend through nested CALL_EXPR children to find DOT_EXPR.
	uint dot_idx = ast::NO_PARENT;
	uint inner_call_idx = call_idx; // innermost call we descended to
	uint scan_idx = call_idx;
	for (uint depth = 0; depth < 4; depth++) {
		// Callee is the FIRST child adopted (lowest node index among children).
		uint first_child = ast::NO_PARENT;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent != scan_idx) continue;
			if (first_child == ast::NO_PARENT || j < first_child) first_child = j;
		}
		if (first_child == ast::NO_PARENT) break;
		AstNode* callee_node = &pr.nodes[first_child];
		if (callee_node.kind == DOT_EXPR) { dot_idx = first_child; break; }
		if (callee_node.kind == CALL_EXPR) {
			scan_idx = first_child;
			inner_call_idx = first_child;
			continue;
		}
		// Callee is NAME_EXPR or other — bare call.
		break;
	}

	// Bare call: no DOT_EXPR callee. e.g. `consume(...)` inside an extension fn.
	// Implicit `this` receiver = enclosing class/extension. Look up callee
	// (CALL_EXPR.name) as a method on that class, return its return type.
	if (dot_idx == ast::NO_PARENT) {
		if (workspace == null) return "";
		AstNode* call_node = &pr.nodes[inner_call_idx];
		String callee = call_node.name;
		if (callee.len == 0) return "";
		String enclosing = resolve_this_receiver_type(pr, workspace, store, call_node.start_offset);
		if (enclosing.len > 0) {
			String ret_class = find_method_return_class(workspace, enclosing, callee);
			if (ret_class.len > 0) return ret_class;
		}
		return "";
	}

	// Find the receiver child of the DOT_EXPR (its first child).
	for (uint k = 0; k < pr.node_count; k++) {
		if (pr.nodes[k].parent != dot_idx) continue;
		AstNode* recv = &pr.nodes[k];

		// NAME_EXPR: variable reference
		if (recv.kind == NAME_EXPR) {
			TypeRef t = find_receiver_decl_type(pr, null, recv.name, recv.start_offset);
			if (t.kind != UNKNOWN && t.name.len > 0) return t.name;
			// Could be a class reference itself
			if (recv.name.len > 0 && recv.name[0] >= 'A' && recv.name[0] <= 'Z') {
				return recv.name;
			}
			return "";
		}

		// CALL_EXPR: factory call. Resolve callee return type via workspace.
		if (recv.kind == CALL_EXPR) {
			String callee = recv.name;
			if (callee.len == 0) return "";
			if (workspace == null) return "";

			// First: if the call has its own DOT_EXPR receiver (chained), recurse.
			// e.g. for `obj.foo().branch`, callee=foo, receiver of foo is obj.
			String inner_recv = resolve_call_receiver_class(pr, workspace, store, k);
			if (inner_recv.len > 0) {
				// Look up callee on inner_recv's class, get return type.
				String ret_class = find_method_return_class(workspace, inner_recv, callee);
				if (ret_class.len > 0) return ret_class;
			}

			// Otherwise: bare call. Implicit receiver = enclosing class/extension.
			// Walk up from the call site to find the enclosing receiver type,
			// then look up callee as a method of that class.
			String enclosing = resolve_this_receiver_type(pr, workspace, store, recv.start_offset);
			if (enclosing.len > 0) {
				String ret_class = find_method_return_class(workspace, enclosing, callee);
				if (ret_class.len > 0) return ret_class;
			}

			// Last resort: top-level FUN by name. Multiple overloads may exist;
			// this picks one and may be wrong, so it's last.
			if (try indices = workspace.lookup_by_name(callee)) {
				for (usz i = 0; i < indices.len(); i++) {
					WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
					if (sym.kind != SymbolKind.FUNCTION) continue;
					String content;
					char[] disk_data;
					if (store != null) {
						if (try doc = store.get(sym.uri)) content = doc.content;
					}
					if (content.len == 0) {
						String path = workspace::uri_to_path(sym.uri);
						if (path.len > 0) {
							if (try data = std::io::file::load(tmem, path)) {
								disk_data = data;
								content = (String)disk_data;
							}
						}
					}
					if (content.len == 0) continue;

					String found_ret = "";
					@pool() {
						ParseResult* cross_pr = mem::new(ParseResult);
						defer mem::free(cross_pr);
						parser::parse(content, cross_pr);
						for (uint p = 0; p < cross_pr.node_count; p++) {
							AstNode* fn_node = &cross_pr.nodes[p];
							if (fn_node.kind != FUN_DECL) continue;
							if (fn_node.name != callee) continue;
							if (fn_node.type_text.len == 0) continue;
							String rt = fn_node.type_text;
							for (usz q = 0; q < rt.len; q++) {
								if (rt[q] == '<' || rt[q] == '?') {
									rt = rt[:q];
									break;
								}
							}
							static char[256] ret_buf;
							usz copy_len = rt.len < 256 ? rt.len : 255;
							ret_buf[:copy_len] = rt[:copy_len];
							found_ret = (String)ret_buf[:copy_len];
						}
					};
					if (found_ret.len > 0) return found_ret;
				}
			}
			return "";
		}

		// DOT_EXPR: chained access — recurse
		if (recv.kind == DOT_EXPR) {
			// Treat the inner DOT_EXPR as the receiver of a virtual call.
			// Find a CALL_EXPR ancestor wrapping it, or fall back to its member
			// type lookup. Simpler: bail out — full recursion is expensive.
			return "";
		}

		// THIS_EXPR: receiver is the enclosing receiver
		if (recv.kind == THIS_EXPR) {
			return resolve_this_receiver_type(pr, workspace, store, recv.start_offset);
		}

		return "";
	}
	return "";
}

/**
 * Look up `method_name` on `class_name` in workspace.member_cache. If it's a
 * function with a final lambda-typed param having a receiver, return that
 * receiver type name. Returns empty string when not found.
 */
fn String find_lambda_receiver_for_class_method(WorkspaceIndex* workspace,
		String class_name, String method_name) {
	static char[256] recv_buf;
	if (try members = workspace.lookup_members(class_name)) {
		for (usz i = 0; i < members.len(); i++) {
			MemberDecl* m = members.get_ref(i);
			if (m.node_kind != FUN_DECL) continue;
			if (m.name != method_name) continue;
			for (usz p = 0; p < m.param_count; p++) {
				String pt = m.param_types[p];
				if (pt.len == 0) continue;
				TypeRef tref = types::parse_type_text(pt);
				if (tref.kind == FUNCTION && tref.receiver_type_name.len > 0) {
					usz copy_len = tref.receiver_type_name.len < 256 ? tref.receiver_type_name.len : 255;
					recv_buf[:copy_len] = tref.receiver_type_name[:copy_len];
					return (String)recv_buf[:copy_len];
				}
			}
		}
	}
	return "";
}

/**
 * Find the return class of a method on a class.
 *
 * Iterates members of class_name, finds first FUN_DECL matching method_name,
 * parses its type_text (return type), strips generics, returns class name.
 * Returns "" if not found or return type unresolvable.
 */
fn String find_method_return_class(WorkspaceIndex* workspace,
		String class_name, String method_name) {
	static char[256] ret_buf;
	if (try members = workspace.lookup_members(class_name)) {
		for (usz i = 0; i < members.len(); i++) {
			MemberDecl* m = members.get_ref(i);
			if (m.node_kind != FUN_DECL) continue;
			if (m.name != method_name) continue;
			String rt = m.type_text;
			if (rt.len == 0) continue;
			// Strip generics: "ConsumedStream<K, V>" -> "ConsumedStream"
			usz end = rt.len;
			for (usz k = 0; k < rt.len; k++) {
				if (rt[k] == '<') { end = k; break; }
			}
			// Strip nullable suffix
			if (end > 0 && rt[end - 1] == '?') end--;
			if (end == 0) continue;
			usz copy_len = end < 256 ? end : 255;
			ret_buf[:copy_len] = rt[:copy_len];
			return (String)ret_buf[:copy_len];
		}
	}
	return "";
}

/**
 * Navigate to a member of the extension function's receiver type.
 *
 * Inside `fun Receiver.name() { ... }`, bare identifiers like `member`
 * refer to `this.member` — a member of the Receiver class. Walk up
 * the parent chain from the NAME_EXPR to find an enclosing FUN_DECL
 * or PROPERTY_DECL with a receiver type (extra_text), then look up
 * the member in that class.
 */
fn Object*? find_extension_receiver_member_definition(ParseResult* pr, WorkspaceIndex* workspace,
		DocumentStore* store, String target_name, uint cursor_offset, String current_uri) {
	// Find the NAME_EXPR at the cursor position
	uint name_node_idx = ast::NO_PARENT;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != NAME_EXPR) continue;
		if (n.name != target_name) continue;
		if (cursor_offset >= n.name_offset && cursor_offset < n.name_offset + n.name_len) {
			name_node_idx = i;
			break;
		}
	}
	if (name_node_idx == ast::NO_PARENT) return NOT_RECEIVER_MEMBER~;

	// Walk up parent chain to find an extension function/property
	uint current = pr.nodes[name_node_idx].parent;
	while (current != ast::NO_PARENT) {
		AstNode* n = &pr.nodes[current];
		if ((n.kind == FUN_DECL || n.kind == PROPERTY_DECL) && n.extra_text.len > 0) {
			String receiver = n.extra_text;
			// Strip nullable suffix
			if (receiver.len > 0 && receiver[receiver.len - 1] == '?') {
				receiver = receiver[:receiver.len - 1];
			}
			// Strip type parameters (e.g., "List<String>" -> "List")
			for (usz k = 0; k < receiver.len; k++) {
				if (receiver[k] == '<') {
					receiver = receiver[:k];
					break;
				}
			}
			// Try same-file AST
			if (try result = find_member_in_class_ast(pr, receiver, target_name, current_uri)) {
				return result;
			}
			// Try workspace
			if (workspace != null) {
				if (try result = find_member_in_workspace_class(workspace, store, receiver, target_name)) {
					return result;
				}
			}
			return NOT_RECEIVER_MEMBER~;
		}
		current = n.parent;
	}
	return NOT_RECEIVER_MEMBER~;
}

fn Object*? find_receiver_lambda_member_definition(ParseResult* pr, WorkspaceIndex* workspace,
		DocumentStore* store, String target_name, uint cursor_offset, String current_uri) {
	// Find the NAME_EXPR at the cursor position
	uint name_node_idx = ast::NO_PARENT;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != NAME_EXPR) continue;
		if (n.name != target_name) continue;
		if (cursor_offset >= n.name_offset && cursor_offset < n.name_offset + n.name_len) {
			name_node_idx = i;
			break;
		}
	}
	if (name_node_idx == ast::NO_PARENT) return NOT_RECEIVER_MEMBER~;

	// Walk up through lambdas to find a receiver type
	uint current = name_node_idx;
	while (true) {
		uint lambda_idx = find_lambda_ancestor_def(pr, current);
		if (lambda_idx == ast::NO_PARENT) return NOT_RECEIVER_MEMBER~;

		uint call_idx = find_call_parent_of_lambda_def(pr, lambda_idx);
		if (call_idx != ast::NO_PARENT) {
			String receiver_type = find_receiver_type_for_call_def(pr, call_idx);

			// Cross-file fallback: look up callee in workspace, parse its file,
			// scan for lambda receiver param type
			if (receiver_type.len == 0 && workspace != null) {
				String callee_name = pr.nodes[call_idx].name;
				if (callee_name.len > 0) {
					receiver_type = find_lambda_receiver_in_workspace(workspace, store, callee_name);
				}
			}

			if (receiver_type.len > 0) {
				// Found a receiver type -- look for the member in that class
				if (try result = find_member_in_class_ast(pr, receiver_type, target_name, current_uri)) {
					return result;
				}
				// Try workspace
				if (workspace != null) {
					if (try result = find_member_in_workspace_class(workspace, store, receiver_type, target_name)) {
						return result;
					}
				}
			}
		}

		// Try the next outer lambda
		current = lambda_idx;
	}
}

/**
 * Find the nearest LAMBDA_EXPR ancestor of a node.
 */
fn uint find_lambda_ancestor_def(ParseResult* pr, uint node_idx) {
	uint current = node_idx;
	while (current != ast::NO_PARENT) {
		AstNode* n = &pr.nodes[current];
		if (n.kind == LAMBDA_EXPR && current != node_idx) {
			return current;
		}
		current = n.parent;
	}
	return ast::NO_PARENT;
}

/**
 * Find the CALL_EXPR parent of a LAMBDA_EXPR (trailing lambdas are direct children).
 */
fn uint find_call_parent_of_lambda_def(ParseResult* pr, uint lambda_idx) {
	AstNode* lambda = &pr.nodes[lambda_idx];
	if (lambda.parent == ast::NO_PARENT) return ast::NO_PARENT;
	AstNode* parent = &pr.nodes[lambda.parent];
	if (parent.kind == CALL_EXPR) return lambda.parent;
	return ast::NO_PARENT;
}

/**
 * Given a CALL_EXPR, find the receiver type from the called function's
 * parameter with a receiver function type (e.g., Module.() -> Unit).
 * Searches the same-file AST for the function declaration.
 */

/**
 * Find the type of a variable by looking at its declaration's type_text in the AST.
 * Searches from the reference point upward through scopes.
 */
fn String find_variable_type_in_ast(ParseResult* pr, uint ref_offset, String var_name) {
	// Scope-aware: find innermost scope containing ref_offset, walk outward.
	// This ensures we resolve the correct variable when names shadow.
	uint scope_idx = 0; // FILE node
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!is_scope_node(n.kind)) continue;
		if (ref_offset >= n.start_offset && ref_offset < n.end_offset) {
			scope_idx = i;
		}
	}

	uint current = scope_idx;
	while (true) {
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.parent != current) continue;
			if (n.kind != PROPERTY_DECL && n.kind != PARAM) continue;
			if (n.name != var_name) continue;
			if (n.type_text.len > 0) {
				String t = n.type_text;
				for (usz k = 0; k < t.len; k++) {
					if (t[k] == '<' || t[k] == '?') {
						return t[:k];
					}
				}
				return t;
			}
		}
		AstNode* scope = &pr.nodes[current];
		if (current == 0 || scope.parent == ast::NO_PARENT) break;
		current = scope.parent;
	}
	return "";
}

/**
 * Scope-aware lookup of a receiver variable's declaration type.
 * Walks from innermost scope outward, returning the nearest declaration's type.
 * Used by dot-member resolution to find the correct receiver type when
 * multiple variables share the same name in different scopes.
 */
fn TypeRef find_receiver_decl_type(ParseResult* pr, TypeInfo* ti, String var_name, uint ref_offset) {
	// Find innermost scope
	uint scope_idx = 0;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!is_scope_node(n.kind)) continue;
		if (ref_offset >= n.start_offset && ref_offset < n.end_offset) {
			scope_idx = i;
		}
	}

	uint current = scope_idx;
	while (true) {
		for (uint k = 0; k < pr.node_count; k++) {
			AstNode* n = &pr.nodes[k];
			if (n.parent != current) continue;
			if (!ast::is_declaration(n.kind) && n.kind != PARAM) continue;
			if (n.name != var_name) continue;

			if (ti != null && ti.has_type[k]) {
				return ti.node_types[k];
			}
			if (n.type_text.len > 0) {
				return types::parse_type_text(n.type_text);
			}
			// Found declaration but no type info — still the right decl
			return types::TYPE_UNKNOWN;
		}
		AstNode* scope = &pr.nodes[current];
		if (current == 0 || scope.parent == ast::NO_PARENT) break;
		current = scope.parent;
	}
	return types::TYPE_UNKNOWN;
}

fn String find_receiver_type_for_call_def(ParseResult* pr, uint call_idx) {
	AstNode* call = &pr.nodes[call_idx];
	String callee_name = call.name;

	if (callee_name.len == 0) return "";

	// ── Handle scope functions (apply/run) ────────────────────────
	// For `receiver.apply { ... }`, the lambda's `this` is the receiver type.
	// We need to resolve the receiver expression's type from the DOT_EXPR.
	if (callee_name == "apply" || callee_name == "run") {
		// The CALL_EXPR for apply is typically a child or sibling of a DOT_EXPR.
		// Check if there's a DOT_EXPR child whose member is "apply"/"run".
		for (uint i = 0; i < pr.node_count; i++) {
			if (pr.nodes[i].parent != call_idx) continue;
			if (pr.nodes[i].kind != DOT_EXPR) continue;

			// Found DOT_EXPR child — look for receiver (NAME_EXPR or CALL_EXPR)
			uint dot_idx = i;
			for (uint j = 0; j < pr.node_count; j++) {
				if (pr.nodes[j].parent != dot_idx) continue;

				if (pr.nodes[j].kind == NAME_EXPR) {
					String recv_name = pr.nodes[j].name;
					// Try to find this variable's type from declarations
					String var_type = find_variable_type_in_ast(pr, call_idx, recv_name);
					if (var_type.len > 0) return var_type;
					// Could be a class name itself
					if (recv_name.len > 0 && recv_name[0] >= 'A' && recv_name[0] <= 'Z') {
						return recv_name;
					}
					break;
				}

				if (pr.nodes[j].kind == CALL_EXPR) {
					String ctor_name = pr.nodes[j].name;
					if (ctor_name.len > 0 && ctor_name[0] >= 'A' && ctor_name[0] <= 'Z') {
						return ctor_name;
					}
					// Factory method — return type needs deeper resolution
					// (handled by caller via workspace lookup if we return "")
					break;
				}
				break; // only check first child
			}
			break;
		}
		return "";
	}

	// Search all FUN_DECL nodes with matching name
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != FUN_DECL) continue;
		if (n.name != callee_name) continue;

		// Scan PARAM children for a function type with receiver
		for (uint j = 0; j < pr.node_count; j++) {
			AstNode* p = &pr.nodes[j];
			if (p.parent != i) continue;
			if (p.kind != PARAM) continue;
			if (p.type_text.len == 0) continue;

			TypeRef tref = types::parse_type_text(p.type_text);
			if (tref.kind == FUNCTION && tref.receiver_type_name.len > 0) {
				return tref.receiver_type_name;
			}
		}
	}

	return "";
}

/**
 * Look up a function by name in the workspace, parse its file, and extract
 * the receiver type from its last function-type parameter with a receiver.
 * E.g., `fun buildModule(block: Module.() -> Unit)` -> "Module"
 */
fn String find_lambda_receiver_in_workspace(WorkspaceIndex* workspace, DocumentStore* store, String callee_name) {
	static char[256] recv_buf;
	if (try indices = workspace.lookup_by_name(callee_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.kind != SymbolKind.FUNCTION) continue;

			// Get content: from open doc or disk
			String content;
			char[] disk_data;

			if (store != null) {
				if (try doc = store.get(sym.uri)) {
					content = doc.content;
				}
			}

			if (content.len == 0) {
				String path = workspace::uri_to_path(sym.uri);
				if (path.len > 0) {
					if (try data = std::io::file::load(tmem, path)) {
						disk_data = data;
						content = (String)disk_data;
					}
				}
			}

			if (content.len == 0) continue;

			// Parse the file and scan the function's PARAM children
			String found_receiver;
			@pool() {
				ParseResult* cross_pr = mem::new(ParseResult);
				defer mem::free(cross_pr);
				parser::parse(content, cross_pr);
				for (uint j = 0; j < cross_pr.node_count; j++) {
					AstNode* n = &cross_pr.nodes[j];
					if (n.kind != FUN_DECL) continue;
					if (n.name != callee_name) continue;

					// Scan PARAM children for function type with receiver
					for (uint k = 0; k < cross_pr.node_count; k++) {
						AstNode* p = &cross_pr.nodes[k];
						if (p.parent != j) continue;
						if (p.kind != PARAM) continue;
						if (p.type_text.len == 0) continue;

						TypeRef tref = types::parse_type_text(p.type_text);
						if (tref.kind == FUNCTION && tref.receiver_type_name.len > 0) {
							usz copy_len = tref.receiver_type_name.len < 256 ? tref.receiver_type_name.len : 255;
							recv_buf[:copy_len] = tref.receiver_type_name[:copy_len];
							found_receiver = (String)recv_buf[:copy_len];
						}
					}
				}
			};
			if (found_receiver.len > 0) return found_receiver;
		}
	}
	return "";
}

// ── Cross-file definition lookup ──────────────────────────────────

faultdef NOT_FOUND_IN_WORKSPACE;

faultdef NOT_FOUND_BY_IMPORT;

/**
 * If the file has an explicit import for target_name, try the dependency
 * index filtered by the import's package. This ensures that
 * `import no.trygdeetaten.skjema.oppdrag.Oppdrag` navigates to the
 * correct Oppdrag in that package, even if there's a same-named class
 * elsewhere in the workspace.
 */
fn Object*? find_definition_by_explicit_import(ParseResult* pr, DependencyIndex* dep_index, String target_name, bool is_call, String current_uri) {
	if (dep_index == null || !dep_index.initialized) return NOT_FOUND_BY_IMPORT~;

	ImportMap imports = workspace::build_import_map(pr);

	// Find the explicit import for this name
	String import_package = "";
	for (usz i = 0; i < imports.import_count; i++) {
		if (imports.is_star[i]) continue;
		if (imports.import_names[i] == target_name) {
			import_package = workspace::get_import_package(imports.import_paths[i]);
			break;
		}
	}
	if (import_package.len == 0) return NOT_FOUND_BY_IMPORT~;

	// Look up in dep index, filtering by the import's package
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(target_name, &matches);
	if (count == 0) return NOT_FOUND_BY_IMPORT~;

	DepSymbol* best = null;
	for (usz i = 0; i < count; i++) {
		if (matches[i].package_name == import_package) {
			best = matches[i];
			break;
		}
	}
	if (best == null) return NOT_FOUND_BY_IMPORT~;

	Object* result = source_nav::resolve_dep_definition(best);
	if (result != null) return result;

	// Source JAR not available — fall back to the import statement itself.
	// This gives the user a useful navigation target (the FQN is visible
	// in the import line) rather than "no locations found".
	String full_import = imports.import_paths[0]; // need to find the right one
	for (usz i = 0; i < imports.import_count; i++) {
		if (imports.is_star[i]) continue;
		if (imports.import_names[i] == target_name) {
			full_import = imports.import_paths[i];
			break;
		}
	}
	if (try loc = find_import_statement_location(pr, full_import, current_uri)) {
		return loc;
	}

	return NOT_FOUND_BY_IMPORT~;
}

/**
 * Find definition via star (wildcard) imports in the dependency index.
 * For `import java.util.*`, looks up target_name in dep index and filters
 * to symbols whose package matches a star-imported package.
 * Returns null if no match or ambiguous (multiple star packages match).
 */
fn Object*? find_definition_by_star_import(ParseResult* pr, DependencyIndex* dep_index, String target_name, bool is_call, String current_uri) {
	if (dep_index == null || !dep_index.initialized) return NOT_FOUND_BY_IMPORT~;

	ImportMap imports = workspace::build_import_map(pr);

	// Collect star packages
	bool has_star = false;
	for (usz i = 0; i < imports.import_count; i++) {
		if (imports.is_star[i]) { has_star = true; break; }
	}
	if (!has_star) return NOT_FOUND_BY_IMPORT~;

	// Look up all dep symbols with this name
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(target_name, &matches);
	if (count == 0) return NOT_FOUND_BY_IMPORT~;

	// Filter to symbols whose package matches a star-imported package
	DepSymbol* best = null;
	String best_star_path = "";
	for (usz i = 0; i < count; i++) {
		for (usz j = 0; j < imports.import_count; j++) {
			if (!imports.is_star[j]) continue;
			if (matches[i].package_name == imports.star_packages[j]) {
				if (best != null && best.package_name != matches[i].package_name) {
					// Ambiguous: multiple star packages match different symbols
					log::debug("[def] star import ambiguous for '%s': %s vs %s",
						target_name, best.package_name, matches[i].package_name);
					return NOT_FOUND_BY_IMPORT~;
				}
				best = matches[i];
				best_star_path = imports.import_paths[j];
				break; // found matching star package for this symbol
			}
		}
	}
	if (best == null) return NOT_FOUND_BY_IMPORT~;

	Object* result = source_nav::resolve_dep_definition(best);
	if (result != null) return result;

	// Source JAR not available — fall back to the star import statement itself.
	if (try loc = find_import_statement_location(pr, best_star_path, current_uri)) {
		return loc;
	}

	return NOT_FOUND_BY_IMPORT~;
}

/**
 * Find definition via Kotlin default imports (spec §16.30).
 * Resolves bare names like `println`, `listOf`, `String`, `UUID` that come
 * from auto-imported packages without any explicit import statement.
 *
 * Auto-imported packages: kotlin, kotlin.annotation, kotlin.collections,
 * kotlin.comparisons, kotlin.io, kotlin.ranges, kotlin.sequences,
 * kotlin.text, and (Kotlin/JVM) java.lang.
 *
 * Returns NOT_FOUND_BY_IMPORT~ when no match or ambiguous (multiple
 * default packages match the same name).
 */
fn Object*? find_definition_by_default_imports(DependencyIndex* dep_index, String target_name, bool is_call) {
	if (dep_index == null || !dep_index.initialized) return NOT_FOUND_BY_IMPORT~;

	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(target_name, &matches);
	if (count == 0) return NOT_FOUND_BY_IMPORT~;

	DepSymbol* best = null;
	for (usz i = 0; i < count; i++) {
		if (!workspace::is_auto_imported_package(matches[i].package_name)) continue;
		if (best == null) {
			best = matches[i];
			continue;
		}
		// Prefer same package; if different default packages match, ambiguous
		if (best.package_name != matches[i].package_name) {
			log::debug("[def] default-import ambiguous for '%s': %s vs %s",
				target_name, best.package_name, matches[i].package_name);
			return NOT_FOUND_BY_IMPORT~;
		}
	}
	if (best == null) return NOT_FOUND_BY_IMPORT~;

	Object* result = source_nav::resolve_dep_definition(best);
	if (result != null) return result;

	return NOT_FOUND_BY_IMPORT~;
}

/**
 * Check if the import map has an explicit (non-star) import for a given name.
 */
fn bool has_explicit_import_for(ImportMap* imports, String name) {
	for (usz i = 0; i < imports.import_count; i++) {
		if (imports.is_star[i]) continue;
		if (imports.import_names[i] == name) return true;
	}
	return false;
}

/**
 * Find the IMPORT_DECL node in the AST matching a full import path
 * and return an LSP Location pointing to it. Used as a fallback when
 * source JAR navigation fails — the user can at least see the FQN.
 */
fn Object*? find_import_statement_location(ParseResult* pr, String full_import_path, String uri) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != IMPORT_DECL) continue;
		if (n.extra_text != full_import_path) continue;

		return build_location_from_node(uri, n);
	}
	return NOT_FOUND_BY_IMPORT~;
}

/**
 * Look up a definition in the workspace index. Searches all indexed files
 * for a symbol matching the target name. In call context, prefers FUNCTION
 * kind. Skips symbols from the current document (already searched via AST).
 * Uses import map to prefer imported symbols over non-imported ones.
 */
fn Object*? find_definition_in_workspace(WorkspaceIndex* workspace, String target_name, bool is_call, String current_uri, ParseResult* pr) {
	List{usz}* indices = workspace.lookup_by_name(target_name)!;

	log::debug("[def:ws] lookup '%s': %d candidates", target_name, (int)indices.len());

	// Build import map for import-aware filtering
	ImportMap imports = workspace::build_import_map(pr);

	log::debug("[def:ws] file package='%s', %d imports", imports.package_name, (int)imports.import_count);
	for (usz di = 0; di < imports.import_count; di++) {
		if (imports.is_star[di]) {
			log::debug("[def:ws]   import %s (star, pkg='%s')", imports.import_paths[di], imports.star_packages[di]);
		} else {
			log::debug("[def:ws]   import %s (name='%s')", imports.import_paths[di], imports.import_names[di]);
		}
	}

	WorkspaceSymbol* first_match = null;
	WorkspaceSymbol* func_match = null;
	WorkspaceSymbol* same_pkg_match = null;       // same package as current file
	WorkspaceSymbol* same_pkg_func_match = null;   // same package, function kind
	WorkspaceSymbol* imported_match = null;
	WorkspaceSymbol* imported_func_match = null;
	WorkspaceSymbol* imported_file_match = null;      // imported + filename matches symbol name
	WorkspaceSymbol* imported_file_func_match = null;  // same, for functions

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;

		// Skip symbols from the current file (already checked via AST)
		if (sym.uri == current_uri) continue;

		// Skip private symbols from other files
		if (sym.is_private) continue;

		// Skip symbols not reachable via module dependency graph
		String from_mod = workspace.get_file_module(current_uri);
		String sym_mod = workspace.get_file_module(sym.uri);
		if (!workspace.is_module_visible(sym.uri, current_uri)) {
			log::debug("[def:ws]   SKIP module-invisible: %s (pkg=%s, uri=%s) from_mod='%s' sym_mod='%s' mod_count=%d",
				sym.name, sym.package_name, sym.uri, from_mod, sym_mod, (int)workspace.classpath.module_count);
			continue;
		}

		log::debug("[def:ws]   candidate: %s (pkg=%s, uri=%s)",
			sym.name, sym.package_name, sym.uri);

		if (first_match == null) {
			first_match = sym;
		}
		if (func_match == null && sym.kind == FUNCTION) {
			func_match = sym;
		}

		// Track same-package symbols (visible without import in Kotlin)
		if (imports.package_name.len > 0 && sym.package_name == imports.package_name) {
			if (same_pkg_match == null) same_pkg_match = sym;
			if (same_pkg_func_match == null && sym.kind == FUNCTION) same_pkg_func_match = sym;
		}

		// Check import visibility
		String visible_name = workspace::is_symbol_visible(sym, &imports, target_name);
		if (visible_name.len > 0) {
			log::debug("[def:ws]   import-visible as '%s'", visible_name);
			if (imported_match == null) {
				imported_match = sym;
			}
			if (imported_func_match == null && sym.kind == FUNCTION) {
				imported_func_match = sym;
			}
			// Prefer symbol whose file name matches the target name (Kotlin convention)
			if (imported_file_match == null && uri_filename_matches(sym.uri, target_name)) {
				imported_file_match = sym;
			}
			if (imported_file_func_match == null && sym.kind == FUNCTION && uri_filename_matches(sym.uri, target_name)) {
				imported_file_func_match = sym;
			}
		} else {
			log::debug("[def:ws]   NOT import-visible");
		}
	}

	// Prefer file-name-matching > imported > any visible
	// When the file has an explicit import for this name but no workspace symbol
	// matched that import's package, don't fall back to first_match -- the symbol
	// is likely from an external dependency (JAR) and the first_match would be wrong.
	bool has_explicit = has_explicit_import_for(&imports, target_name);

	log::debug("[def:ws] has_explicit=%d first=%s imported=%s",
		(int)has_explicit ? 1 : 0,
		first_match != null ? first_match.uri : "(null)",
		imported_match != null ? imported_match.uri : "(null)");

	WorkspaceSymbol* chosen = null;
	if (is_call) {
		if (imported_file_func_match != null) {
			chosen = imported_file_func_match;
		} else if (imported_func_match != null) {
			chosen = imported_func_match;
		} else if (imported_file_match != null) {
			// Constructor call: Foo() where Foo is a CLASS, not FUNCTION
			chosen = imported_file_match;
		} else if (imported_match != null) {
			chosen = imported_match;
		} else if (!has_explicit) {
			// Prefer same-package > any visible
			if (same_pkg_func_match != null) {
				chosen = same_pkg_func_match;
			} else if (same_pkg_match != null) {
				chosen = same_pkg_match;
			} else {
				chosen = func_match != null ? func_match : first_match;
			}
		}
	} else {
		if (imported_file_match != null) {
			chosen = imported_file_match;
		} else if (imported_match != null) {
			chosen = imported_match;
		} else if (!has_explicit) {
			chosen = same_pkg_match != null ? same_pkg_match : first_match;
		}
	}

	if (chosen == null) return NOT_FOUND_IN_WORKSPACE~;

	return build_location_from_workspace_symbol(chosen);
}

/**
 * Build an LSP Location object from a workspace symbol.
 */
fn Object* build_location_from_workspace_symbol(WorkspaceSymbol* sym) {
	Object* start = object::new_obj(tmem);
	start.set("line", (int)sym.line);
	start.set("character", (int)sym.col);

	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)sym.line);
	end_pos.set("character", (int)(sym.col + sym.name_len));

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end_pos);

	Object* location = object::new_obj(tmem);
	location.set("uri", sym.uri);
	location.set("range", range);

	return location;
}

/**
 * Check if a file URI's basename (without .kt extension) matches a symbol name.
 * E.g., "file:///path/to/Simulering.kt" matches "Simulering".
 */
fn bool uri_filename_matches(String uri, String name) {
	// Find the last '/' to get the filename
	usz last_slash = 0;
	for (usz i = uri.len; i > 0; i--) {
		if (uri[i - 1] == '/') {
			last_slash = i;
			break;
		}
	}
	String filename = uri[last_slash..];
	// Strip ".kt" suffix
	if (filename.len > 3 && filename[filename.len - 3] == '.'
		&& filename[filename.len - 2] == 'k' && filename[filename.len - 1] == 't') {
		String stem = filename[:filename.len - 3];
		return stem == name;
	}
	return false;
}

// ── Inheritance-aware member definition lookup ────────────────────

faultdef NOT_INHERITED_MEMBER;

/**
 * Find a bare call/reference that resolves to a member of a supertype.
 *
 * When inside a class body, bare identifiers can refer to inherited members
 * (via implicit `this`). This function:
 * 1. Finds the enclosing class/object at the cursor position
 * 2. Looks up its supertypes (from workspace index)
 * 3. Searches member_cache for each supertype in the hierarchy
 *
 * This avoids false positives because it ONLY matches members of classes
 * that the enclosing class actually inherits from.
 */
fn Object*? find_inherited_member_definition(ParseResult* pr, WorkspaceIndex* workspace,
		DocumentStore* store, String target_name, uint cursor_offset, String current_uri) {
	// Find the enclosing class/interface/object containing the cursor
	String enclosing_class = find_enclosing_class_name(pr, cursor_offset);
	if (enclosing_class.len == 0) return NOT_INHERITED_MEMBER~;

	log::debug("[def:inherit] enclosing class='%s', looking for '%s'", enclosing_class, target_name);

	// First check: is it a member of the enclosing class itself (cross-file)?
	// This handles the case where the class is defined in another file.
	if (try result = find_member_in_workspace_class(workspace, store, enclosing_class, target_name)) {
		return result;
	}

	// Get the enclosing class's supertypes from the workspace index
	if (try indices = workspace.lookup_by_name(enclosing_class)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
				sym.kind != SymbolKind.OBJECT) continue;

			// Search each supertype's members (with depth limit)
			for (usz s = 0; s < sym.supertype_count; s++) {
				if (try result = find_member_in_workspace_class_depth(
						workspace, store, sym.supertypes[s], target_name, 0)) {
					return result;
				}
			}
		}
	}

	// Also check supertypes declared in the same-file AST
	// (the class might have supertypes only visible in the local AST)
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CLASS_DECL && n.kind != INTERFACE_DECL && n.kind != OBJECT_DECL) continue;
		if (n.name != enclosing_class) continue;
		if (!(cursor_offset >= n.start_offset && cursor_offset < n.end_offset)) continue;

		// Check supertypes from the AST node's extra_text
		// The parser stores supertypes as comma-separated in extra_text for class nodes
		// But we also have them from workspace index — so just check member_cache
		// by walking child SUPERTYPE_ENTRY nodes if they exist
		break;
	}

	return NOT_INHERITED_MEMBER~;
}

/**
 * Find the name of the class/interface/object whose body contains the cursor.
 * Walks the AST to find the innermost class-like scope enclosing the offset.
 */
fn String find_enclosing_class_name(ParseResult* pr, uint cursor_offset) {
	String result = "";
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != CLASS_DECL && n.kind != INTERFACE_DECL && n.kind != OBJECT_DECL) continue;
		if (n.name.len == 0) continue;
		if (cursor_offset >= n.start_offset && cursor_offset < n.end_offset) {
			result = n.name;
		}
	}
	return result;
}

// ── Dot-member type resolution helpers ────────────────────────────

/**
 * Resolve the type of a DOT_EXPR node by examining its structure.
 * For `a.b`, finds type of `a` then looks up member `b`'s return type.
 * Used when type inference didn't resolve the DOT_EXPR.
 */
fn TypeRef resolve_dot_expr_type(ParseResult* pr, TypeInfo* ti, WorkspaceIndex* workspace, uint dot_idx) {
	AstNode* dot = &pr.nodes[dot_idx];
	String member_name = dot.name;
	if (member_name.len == 0) return types::TYPE_UNKNOWN;

	// Find the receiver (first child of the DOT_EXPR)
	TypeRef recv_type = types::TYPE_UNKNOWN;
	for (uint j = 0; j < pr.node_count; j++) {
		if (pr.nodes[j].parent != dot_idx) continue;
		if (ti.has_type[j]) {
			recv_type = ti.node_types[j];
		} else if (pr.nodes[j].kind == NAME_EXPR) {
			// Look up the variable declaration type (scope-aware)
			String var_name = pr.nodes[j].name;
			uint var_offset = pr.nodes[j].start_offset;
			recv_type = find_receiver_decl_type(pr, ti, var_name, var_offset);
			// If not a variable, it might be a class/object reference
			if (recv_type.kind == UNKNOWN) {
				recv_type = { .kind = SIMPLE, .name = var_name };
			}
		} else if (pr.nodes[j].kind == DOT_EXPR) {
			// Recursive chain: a.b.c — resolve inner DOT_EXPR type
			recv_type = resolve_dot_expr_type(pr, ti, workspace, j);
		} else if (pr.nodes[j].kind == CALL_EXPR) {
			if (ti.has_type[j]) {
				recv_type = ti.node_types[j];
			}
		}
		break;
	}

	if (recv_type.kind == UNKNOWN || recv_type.name.len == 0) return types::TYPE_UNKNOWN;

	// Now look up member_name's type in recv_type's class
	if (workspace != null) {
		if (try members = workspace.lookup_members(recv_type.name)) {
			for (usz i = 0; i < members.len(); i++) {
				MemberDecl* m = &(*members)[i];
				if (m.name != member_name) continue;
				if (m.type_text.len > 0) {
					return types::parse_type_text(m.type_text);
				}
				// For constructor-like members (class name = type)
				if (m.node_kind == CLASS_DECL || m.node_kind == INTERFACE_DECL || m.node_kind == OBJECT_DECL) {
					return { .kind = SIMPLE, .name = m.name };
				}
				break;
			}
		}

		// Try dep index for method/field return types (JDK, library classes)
		if (workspace.dep_index.initialized) {
			TypeRef dep_type = resolve_dep_member_type(&workspace.dep_index, recv_type.name, member_name);
			if (dep_type.kind != UNKNOWN) return dep_type;
		}
	}

	return types::TYPE_UNKNOWN;
}

/**
 * Resolve the return type of a dep method/field by parsing the signature.
 * Signature format: "fun name(params): ReturnType" or "val name: Type"
 */
fn TypeRef resolve_dep_member_type(DependencyIndex* dep_index, String class_name, String member_name) {
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(member_name, &matches);

	for (usz i = 0; i < count; i++) {
		if (matches[i].class_name != class_name) continue;
		if (matches[i].kind != DEP_METHOD && matches[i].kind != DEP_FIELD) continue;

		String sig = matches[i].signature;
		if (sig.len == 0) continue;

		// Extract return type: find last "): " or ": " pattern
		String ret = extract_return_type_from_signature(sig);
		if (ret.len > 0) {
			return types::parse_type_text(ret);
		}
	}
	return types::TYPE_UNKNOWN;
}

/**
 * Extract the return type from a Kotlin-style signature.
 * "fun stream(): Stream<E>" -> "Stream<E>"
 * "val size: Int" -> "Int"
 * "fun add(element: E): Boolean" -> "Boolean"
 */
fn String extract_return_type_from_signature(String sig) {
	// For val/var: "val name: Type" — find ": " after the name
	if (sig.len > 4 && (sig[..2] == "val" || sig[..2] == "var")) {
		for (usz i = 4; i + 1 < sig.len; i++) {
			if (sig[i] == ':' && i + 1 < sig.len && sig[i + 1] == ' ') {
				return sig[i + 2..];
			}
		}
		return "";
	}

	// For fun: find "): " after closing paren
	// Need to handle nested parens in param types
	int paren_depth = 0;
	for (usz i = 0; i + 2 < sig.len; i++) {
		if (sig[i] == '(') paren_depth++;
		if (sig[i] == ')') {
			paren_depth--;
			if (paren_depth == 0 && i + 2 < sig.len && sig[i + 1] == ':' && sig[i + 2] == ' ') {
				return sig[i + 3..];
			}
		}
	}
	return "";
}

// ── Extension function fallback ───────────────────────────────────

faultdef NO_EXTENSION_FOUND;

/**
 * Search workspace for an extension function matching BOTH receiver type
 * and member name. More precise than find_extension_by_name.
 */
fn Object*? find_extension_by_receiver_and_name(WorkspaceIndex* workspace, String receiver_type,
		String member_name, String current_uri, ParseResult* pr) {
	ImportMap imports = workspace::build_import_map(pr);

	if (try indices = workspace.lookup_by_name(member_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.uri == current_uri) continue;
			if (sym.kind != symbols::SymbolKind.FUNCTION && sym.kind != symbols::SymbolKind.PROPERTY) continue;
			if (sym.receiver.len == 0) continue;

			// Match receiver type: strip generics/nullable from stored receiver
			String recv = sym.receiver;
			usz recv_end = 0;
			while (recv_end < recv.len && recv[recv_end] != '<' && recv[recv_end] != '?' && recv[recv_end] != '.') {
				recv_end++;
			}
			if (recv_end == 0) continue;
			if (recv[:recv_end] != receiver_type) continue;

			// Check import + module visibility
			String visible = workspace::is_symbol_visible(sym, &imports, member_name);
			if (visible.len == 0) continue;
			if (!workspace.is_module_visible(sym.uri, current_uri)) continue;

			return build_location_from_workspace_symbol(sym);
		}
	}

	return NO_EXTENSION_FOUND~;
}

/**
 * Search all member_cache entries for an extension function matching
 * the given name. Used as fallback when receiver type is unresolvable.
 * Filters by import visibility to avoid false positives.
 */
fn Object*? find_extension_by_name(WorkspaceIndex* workspace, String member_name, String current_uri, ParseResult* pr) {
	ImportMap imports = workspace::build_import_map(pr);

	// Search workspace name_index for top-level extension functions with this name
	if (try indices = workspace.lookup_by_name(member_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.uri == current_uri) continue;
			if (sym.kind != symbols::SymbolKind.FUNCTION && sym.kind != symbols::SymbolKind.PROPERTY) continue;
			if (sym.receiver.len == 0) continue; // only extension functions

			// Check import visibility
			String visible = workspace::is_symbol_visible(sym, &imports, member_name);
			if (visible.len == 0) continue;

			// Check module visibility
			if (!workspace.is_module_visible(sym.uri, current_uri)) continue;

			return build_location_from_workspace_symbol(sym);
		}
	}

	return NO_EXTENSION_FOUND~;
}

/**
 * Permissive last-resort: locate any workspace extension function matching
 * the member name, ignoring import visibility. Only used when no other
 * lookup matched. Lets users navigate to extensions even when the import
 * hasn't been added yet (a common editing situation), and avoids dead-end
 * "no definition" responses for legitimate workspace symbols. Still respects
 * module visibility so multi-module projects don't surface unreachable code.
 */
fn Object*? find_extension_by_name_unimported(WorkspaceIndex* workspace, String member_name, String current_uri) {
	if (try indices = workspace.lookup_by_name(member_name)) {
		// Prefer non-private symbols
		WorkspaceSymbol* fallback = null;
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.uri == current_uri) continue;
			if (sym.kind != symbols::SymbolKind.FUNCTION && sym.kind != symbols::SymbolKind.PROPERTY) continue;
			if (sym.receiver.len == 0) continue;
			if (!workspace.is_module_visible(sym.uri, current_uri)) continue;
			if (sym.is_private) {
				if (fallback == null) fallback = sym;
				continue;
			}
			return build_location_from_workspace_symbol(sym);
		}
		if (fallback != null) return build_location_from_workspace_symbol(fallback);
	}
	return NO_EXTENSION_FOUND~;
}

/**
 * Import-aware fallback for dot-member navigation.
 * When receiver type is unknown or member not found by receiver class,
 * look up the member name in the dep index and filter by file imports.
 * Handles extension functions from deps (e.g., call.respond() from ktor).
 */
fn Object* find_dot_member_by_import(DependencyIndex* dep_index, ParseResult* pr, String member_name, String current_uri) {
	if (dep_index == null || !dep_index.initialized) return null;

	ImportMap imports = workspace::build_import_map(pr);

	DepSymbol*[32] matches;
	usz count = dep_index.lookup_by_name(member_name, &matches);
	if (count == 0) return null;

	// First pass: prefer explicit import match
	for (usz i = 0; i < count; i++) {
		if (matches[i].kind != DEP_METHOD && matches[i].kind != DEP_FIELD) continue;
		for (usz j = 0; j < imports.import_count; j++) {
			if (imports.is_star[j]) continue;
			if (imports.import_names[j] != member_name) continue;
			String pkg = workspace::get_import_package(imports.import_paths[j]);
			if (pkg == matches[i].package_name) {
				Object* result = source_nav::resolve_dep_definition(matches[i]);
				if (result != null) return result;
			}
		}
	}

	// Second pass: star import match
	for (usz i = 0; i < count; i++) {
		if (matches[i].kind != DEP_METHOD && matches[i].kind != DEP_FIELD) continue;
		for (usz j = 0; j < imports.import_count; j++) {
			if (!imports.is_star[j]) continue;
			if (imports.star_packages[j] == matches[i].package_name) {
				Object* result = source_nav::resolve_dep_definition(matches[i]);
				if (result != null) return result;
			}
		}
	}

	return null;
}
