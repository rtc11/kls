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
import kls::log;

/**
 * Handle textDocument/definition request.
 * Returns a Location JSON object pointing to the declaration of the
 * identifier under the cursor, or null if no definition is found.
 *
 * Uses the parser AST for scope-aware lookup: searches from the
 * innermost scope containing the cursor outward.
 * Falls back to workspace index for cross-file definitions.
 */
fn Object*? handle_definition(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

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
	log::debug("[def] target='%s' line=%d col=%d uri=%s", target_name, line, character, uri);

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
		log::debug("[def] found via AST scope search");
		return build_location_from_node(uri, node);
	}

	// ── Extension function receiver member navigation ────────────
	// If the cursor is inside an extension function (fun Receiver.name()),
	// bare identifiers may refer to implicit `this` members of the receiver.
	if (try result = find_extension_receiver_member_definition(pr, workspace, target_name, tok.offset, uri)) {
		log::debug("[def] found via extension receiver member");
		return result;
	}

	// ── Dot-member navigation ────────────────────────────────────
	// If the token is a member of a DOT_EXPR, resolve the receiver type
	// and search for the member declaration in the receiver class.
	TypeInfo* ti = store.get_types(uri) ?? null;
	bool is_dot_member = is_token_dot_member(pr, tok);
	if (ti != null) {
		if (try result = find_dot_member_definition(pr, ti, store, workspace, tok, uri)) {
			log::debug("[def] found via dot-member navigation");
			return result;
		}
	}

	// ── Cross-file lookup via workspace index ────────────────────
	// Workspace symbols take priority over dependency symbols, because
	// the user's own code is the most relevant navigation target.
	// Skip this for dot members (e.g., record.timestamp()) — the dot-member
	// handler already searched the workspace by receiver type. Falling through
	// here would match unrelated symbols with the same name.
	if (workspace != null && !is_dot_member) {
		if (try result = find_definition_in_workspace(workspace, target_name, is_call, uri, pr)) {
			log::debug("[def] found via workspace index");
			return result;
		}
	}

	// ── Inheritance-aware member lookup ──────────────────────────
	// If the cursor is inside a class body and the bare call/reference
	// matches a member of a supertype, resolve it via the class hierarchy.
	// This handles `createOppdrag110()` called from a class that extends
	// the class defining that method — without requiring explicit `this.`.
	if (workspace != null && !is_dot_member) {
		if (try result = find_inherited_member_definition(pr, workspace, store, target_name, tok.offset, uri)) {
			log::debug("[def] found via inherited member lookup");
			return result;
		}
	}

	// ── Import-aware dependency lookup ───────────────────────────
	// If the file has an explicit import for this name (e.g., import com.example.Foo),
	// try the dependency index, filtered by the import's package.
	// Skip for dot members — the dot-member handler already tried deps by receiver type.
	if (workspace != null && !is_dot_member) {
		if (try result = find_definition_by_explicit_import(pr, &workspace.dep_index, target_name, is_call, uri)) {
			log::debug("[def] found via explicit import dep lookup");
			return result;
		}
	}

	// ── Dependency fallback via source JARs ───────────────────────
	// Skip for dot members — falling through here matches unrelated members
	// (e.g., TestRecord.timestamp instead of Record.timestamp).
	if (workspace != null && !is_dot_member) {
		Object* dep_result = source_nav::find_definition_in_deps(&workspace.dep_index, target_name, is_call);
		if (dep_result != null) {
			log::debug("[def] found via dep JAR fallback");
			return dep_result;
		}
	}

	log::debug("[def] no definition found for '%s'", target_name);
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
					// Try to find the receiver's declaration type
					String recv_name = pr.nodes[j].name;
					for (uint k = 0; k < pr.node_count; k++) {
						if ((ast::is_declaration(pr.nodes[k].kind) || pr.nodes[k].kind == PARAM) &&
							pr.nodes[k].name == recv_name) {
							if (ti.has_type[k]) {
								receiver_type = ti.node_types[k];
							} else if (pr.nodes[k].type_text.len > 0) {
								receiver_type = types::parse_type_text(pr.nodes[k].type_text);
							}
							break;
						}
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
					// Receiver is a call: factory().member — check type info
					if (ti.has_type[j]) {
						receiver_type = ti.node_types[j];
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
					Object* dep_result = find_dep_member_definition(&workspace.dep_index, recv_name, tok.text, pr);
					if (dep_result != null) return dep_result;
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
			Object* dep_result = find_dep_member_definition(&workspace.dep_index, type_name, member_name, pr);
			if (dep_result != null) return dep_result;
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
				if (try doc = store.get(pm.uri)) {
					content = doc.content;
				} else {
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
fn Object* find_dep_member_definition(DependencyIndex* dep_index, String class_name, String member_name, ParseResult* pr = null) {
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
 * Navigate to a member of the extension function's receiver type.
 *
 * Inside `fun Receiver.name() { ... }`, bare identifiers like `member`
 * refer to `this.member` — a member of the Receiver class. Walk up
 * the parent chain from the NAME_EXPR to find an enclosing FUN_DECL
 * or PROPERTY_DECL with a receiver type (extra_text), then look up
 * the member in that class.
 */
fn Object*? find_extension_receiver_member_definition(ParseResult* pr, WorkspaceIndex* workspace,
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
				if (try result = find_member_in_workspace_class(workspace, null, receiver, target_name)) {
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

/**
 * Find the type of a variable by looking at its declaration's type_text in the AST.
 * Searches from the reference point upward through scopes.
 */
fn String find_variable_type_in_ast(ParseResult* pr, uint ref_offset, String var_name) {
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != PROPERTY_DECL && n.kind != PARAM) continue;
		if (n.name != var_name) continue;
		if (n.type_text.len > 0) {
			// Strip generics and nullable for simple type name
			String t = n.type_text;
			for (usz k = 0; k < t.len; k++) {
				if (t[k] == '<' || t[k] == '?') {
					return t[:k];
				}
			}
			return t;
		}
	}
	return "";
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
			chosen = func_match != null ? func_match : first_match;
		}
	} else {
		if (imported_file_match != null) {
			chosen = imported_file_match;
		} else if (imported_match != null) {
			chosen = imported_match;
		} else if (!has_explicit) {
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
			// Look up the variable declaration type
			String var_name = pr.nodes[j].name;
			for (uint k = 0; k < pr.node_count; k++) {
				if ((ast::is_declaration(pr.nodes[k].kind) || pr.nodes[k].kind == PARAM) && pr.nodes[k].name == var_name) {
					if (ti.has_type[k]) {
						recv_type = ti.node_types[k];
					} else if (pr.nodes[k].type_text.len > 0) {
						recv_type = types::parse_type_text(pr.nodes[k].type_text);
					}
					break;
				}
			}
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
	}

	return types::TYPE_UNKNOWN;
}

// ── Extension function fallback ───────────────────────────────────

faultdef NO_EXTENSION_FOUND;

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
