module kls::lsp::definition;

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

/**
 * Handle textDocument/definition request.
 * Returns a Location JSON object pointing to the declaration of the
 * identifier under the cursor, or null if no definition is found.
 *
 * Uses the parser AST for scope-aware lookup: searches from the
 * innermost scope containing the cursor outward.
 * Falls back to workspace index for cross-file definitions.
 */
fn Object* handle_definition(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	// Find the token at cursor
	Token tok;
	if (try t = hover::find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	// Only navigate to definitions of identifiers
	if (tok.kind != IDENTIFIER) {
		return null;
	}

	String target_name = tok.text;

	// Get cached AST (parses lazily if needed)
	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	// Detect call context: prefer AST-based detection, fall back to lexer
	bool is_call = is_call_context_ast(pr, tok.offset) || is_call_context(doc.content, tok);

	// ── Receiver lambda member navigation ────────────────────────
	// If the cursor is inside a receiver lambda (e.g., Module.() -> Unit),
	// and the name is NOT declared locally inside the lambda, it likely
	// refers to a member of the receiver class. Check this BEFORE the
	// global fallback to avoid matching same-named declarations in
	// unrelated scopes. Kotlin priority: local-in-lambda > receiver > outer.
	if (!is_declared_in_lambda_scope(pr, target_name, tok.offset)) {
		if (try result = find_receiver_lambda_member_definition(pr, workspace, target_name, tok.offset, uri)) {
			return result;
		}
	}

	// Find definition using scope-aware AST search
	if (try node = find_definition_in_ast(pr, target_name, tok.offset, is_call)) {
		return build_location_from_node(uri, node);
	}

	// ── Dot-member navigation ────────────────────────────────────
	// If the token is a member of a DOT_EXPR, resolve the receiver type
	// and search for the member declaration in the receiver class.
	TypeInfo* ti = store.get_types(uri) ?? null;
	if (ti != null) {
		if (try result = find_dot_member_definition(pr, ti, store, workspace, tok, uri)) {
			return result;
		}
	}

	// ── Cross-file fallback via workspace index ──────────────────
	if (workspace != null) {
		if (try result = find_definition_in_workspace(workspace, target_name, is_call, uri, pr)) {
			return result;
		}
	}

	// ── Dependency fallback via source JARs ───────────────────────
	if (workspace != null) {
		Object* dep_result = source_nav::find_definition_in_deps(&workspace.dep_index, target_name, is_call);
		if (dep_result != null) {
			return dep_result;
		}
	}

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
 * Pick the best FUN_DECL among candidates by matching argument count.
 * If call_arg_count is -1, returns the first func_match (no scoring).
 */
fn AstNode* pick_best_overload(ParseResult* pr, AstNode*[] candidates, usz count, int call_arg_count) {
	if (count == 0) return null;
	if (count == 1 || call_arg_count < 0) return candidates[0];

	// Try to find exact parameter count match
	for (usz i = 0; i < count; i++) {
		uint param_count = ast::count_children_of_kind(pr, candidates[i], PARAM);
		if (param_count == (uint)call_arg_count) {
			return candidates[i];
		}
	}

	// No exact match -- return first candidate
	return candidates[0];
}

/**
 * Search the AST for a declaration matching the target name.
 * Starts from the innermost scope containing the cursor offset
 * and works outward. Prefers function declarations in call context.
 * When multiple overloads match, prefers the one whose parameter
 * count matches the call's argument count.
 */
fn AstNode*? find_definition_in_ast(ParseResult* pr, String target_name, uint cursor_offset, bool is_call) {
	if (pr.node_count == 0) return ast::NOT_FOUND~;

	// If this is a call, find the argument count for overload resolution
	int call_arg_count = -1;
	if (is_call) {
		call_arg_count = find_call_arg_count(pr, target_name, cursor_offset);
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
		usz func_count = 0;

		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.parent != current) continue;
			if (!is_definition_target(n.kind)) continue;
			if (n.name != target_name) continue;

			if (first_match == null) {
				first_match = n;
			}
			if (n.kind == FUN_DECL && func_count < 16) {
				func_candidates[func_count] = n;
				func_count++;
			}
		}

		if (is_call && func_count > 0) {
			return pick_best_overload(pr, func_candidates[:func_count], func_count, call_arg_count);
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

	// ── Global fallback ───────────────────────────────────────────
	// The scope-walk didn't find a match. This happens when the
	// identifier refers to a member of a class/object that doesn't
	// contain the cursor (e.g. `nob.module { }` or `Nob.new(args)`).
	// Search ALL declarations in the entire AST as a fallback.
	{
		AstNode* first_match = null;
		AstNode*[16] func_candidates;
		usz func_count = 0;

		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (!is_definition_target(n.kind)) continue;
			if (n.name != target_name) continue;

			if (first_match == null) {
				first_match = n;
			}
			if (n.kind == FUN_DECL && func_count < 16) {
				func_candidates[func_count] = n;
				func_count++;
			}
		}

		if (is_call && func_count > 0) {
			return pick_best_overload(pr, func_candidates[:func_count], func_count, call_arg_count);
		}
		if (first_match != null) {
			return first_match;
		}
	}

	return ast::NOT_FOUND~;
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
					// Try to find the receiver's declaration type
					String recv_name = pr.nodes[j].name;
					for (uint k = 0; k < pr.node_count; k++) {
						if (ast::is_declaration(pr.nodes[k].kind) &&
							pr.nodes[k].name == recv_name) {
							if (ti.has_type[k]) {
								receiver_type = ti.node_types[k];
							} else if (pr.nodes[k].type_text.len > 0) {
								receiver_type = types::parse_type_text(pr.nodes[k].type_text);
							}
							break;
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
					Object* dep_result = find_dep_member_definition(&workspace.dep_index, recv_name, tok.text);
					if (dep_result != null) return dep_result;
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
		return NOT_DOT_MEMBER~;
	}

	// Fall back to parsing (cache miss)
	if (try indices = workspace.lookup_by_name(class_name)) {
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.kind != SymbolKind.CLASS && sym.kind != SymbolKind.INTERFACE &&
				sym.kind != SymbolKind.OBJECT) continue;

			// Try to parse the file and find the member
			String content;
			char[] disk_data;

			if (try doc = store.get(sym.uri)) {
				content = doc.content;
			} else {
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
fn Object* find_dep_member_definition(DependencyIndex* dep_index, String class_name, String member_name) {
	// First verify the class exists in the dep index
	DepSymbol*[4] class_matches;
	usz class_count = dep_index.lookup_by_name(class_name, &class_matches);
	bool is_known_class = false;
	for (usz i = 0; i < class_count; i++) {
		if (class_matches[i].kind == DEP_CLASS || class_matches[i].kind == DEP_INTERFACE ||
			class_matches[i].kind == DEP_ENUM || class_matches[i].kind == DEP_ANNOTATION ||
			class_matches[i].kind == DEP_OBJECT) {
			is_known_class = true;
			break;
		}
	}
	if (!is_known_class) {
		return null;
	}

	// Look up the member by name, filter by class_name
	DepSymbol*[16] member_matches;
	usz member_count = dep_index.lookup_by_name(member_name, &member_matches);

	DepSymbol* best = null;
	for (usz i = 0; i < member_count; i++) {
		if (member_matches[i].class_name != class_name) continue;
		if (member_matches[i].kind != DEP_METHOD && member_matches[i].kind != DEP_FIELD) continue;
		best = member_matches[i];
		break;
	}

	if (best == null) {
		return null;
	}

	return source_nav::resolve_dep_definition(best);
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
fn Object*? find_receiver_lambda_member_definition(ParseResult* pr, WorkspaceIndex* workspace,
		String target_name, uint cursor_offset, String current_uri) {
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
			if (receiver_type.len > 0) {
				// Found a receiver type -- look for the member in that class
				if (try result = find_member_in_class_ast(pr, receiver_type, target_name, current_uri)) {
					return result;
				}
				// Try workspace
				if (workspace != null) {
					if (try result = find_member_in_workspace_class(workspace, null, receiver_type, target_name)) {
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
fn String find_receiver_type_for_call_def(ParseResult* pr, uint call_idx) {
	AstNode* call = &pr.nodes[call_idx];
	String callee_name = call.name;

	if (callee_name.len == 0) return "";

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

// ── Cross-file definition lookup ──────────────────────────────────

faultdef NOT_FOUND_IN_WORKSPACE;

/**
 * Look up a definition in the workspace index. Searches all indexed files
 * for a symbol matching the target name. In call context, prefers FUNCTION
 * kind. Skips symbols from the current document (already searched via AST).
 * Uses import map to prefer imported symbols over non-imported ones.
 */
fn Object*? find_definition_in_workspace(WorkspaceIndex* workspace, String target_name, bool is_call, String current_uri, ParseResult* pr) {
	List{usz}* indices = workspace.lookup_by_name(target_name)!;

	// Build import map for import-aware filtering
	ImportMap imports = workspace::build_import_map(pr);

	WorkspaceSymbol* first_match = null;
	WorkspaceSymbol* func_match = null;
	WorkspaceSymbol* imported_match = null;
	WorkspaceSymbol* imported_func_match = null;
	WorkspaceSymbol* imported_file_match = null;      // imported + filename matches symbol name
	WorkspaceSymbol* imported_file_func_match = null;  // same, for functions

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;

		// Skip symbols from the current file (already checked via AST)
		if (sym.uri == current_uri) continue;

		// Skip symbols not reachable via module dependency graph
		if (!workspace.is_module_visible(sym.uri, current_uri)) continue;

		if (first_match == null) {
			first_match = sym;
		}
		if (func_match == null && sym.kind == FUNCTION) {
			func_match = sym;
		}

		// Check import visibility
		String visible_name = workspace::is_symbol_visible(sym, &imports, target_name);
		if (visible_name.len > 0) {
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
		}
	}

	// Prefer file-name-matching > imported > any visible
	WorkspaceSymbol* chosen = null;
	if (is_call) {
		if (imported_file_func_match != null) {
			chosen = imported_file_func_match;
		} else if (imported_func_match != null) {
			chosen = imported_func_match;
		} else {
			chosen = func_match;
		}
	} else {
		if (imported_file_match != null) {
			chosen = imported_file_match;
		} else if (imported_match != null) {
			chosen = imported_match;
		} else {
			chosen = first_match;
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
