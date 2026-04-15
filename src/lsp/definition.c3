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
		if (try result = find_definition_in_workspace(workspace, target_name, is_call, uri)) {
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
 * Search the AST for a declaration matching the target name.
 * Starts from the innermost scope containing the cursor offset
 * and works outward. Prefers function declarations in call context.
 */
fn AstNode*? find_definition_in_ast(ParseResult* pr, String target_name, uint cursor_offset, bool is_call) {
	if (pr.node_count == 0) return ast::NOT_FOUND~;

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
		AstNode* func_match = null;

		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.parent != current) continue;
			if (!is_definition_target(n.kind)) continue;
			if (n.name != target_name) continue;

			if (first_match == null) {
				first_match = n;
			}
			if (func_match == null && n.kind == FUN_DECL) {
				func_match = n;
			}
		}

		if (is_call && func_match != null) {
			return func_match;
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
		AstNode* func_match = null;

		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (!is_definition_target(n.kind)) continue;
			if (n.name != target_name) continue;

			if (first_match == null) {
				first_match = n;
			}
			if (func_match == null && n.kind == FUN_DECL) {
				func_match = n;
			}
		}

		if (is_call && func_match != null) {
			return func_match;
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
	return kind == PARAM;
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
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != DOT_EXPR) continue;
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

		if (receiver_type.kind == UNKNOWN) return NOT_DOT_MEMBER~;

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

		break;
	}

	return NOT_DOT_MEMBER~;
}

/**
 * Search for a member declaration inside a class in the same-file AST.
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
				if (!ast::is_declaration(child.kind)) continue;
				if (child.name != member_name) continue;
				return build_location_from_node(uri, child);
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
	// Look up the class in the workspace index
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
		}
	}

	return NOT_DOT_MEMBER~;
}

// ── Cross-file definition lookup ──────────────────────────────────

faultdef NOT_FOUND_IN_WORKSPACE;

/**
 * Look up a definition in the workspace index. Searches all indexed files
 * for a symbol matching the target name. In call context, prefers FUNCTION
 * kind. Skips symbols from the current document (already searched via AST).
 */
fn Object*? find_definition_in_workspace(WorkspaceIndex* workspace, String target_name, bool is_call, String current_uri) {
	List{usz}* indices = workspace.lookup_by_name(target_name)!;

	WorkspaceSymbol* first_match = null;
	WorkspaceSymbol* func_match = null;

	for (usz i = 0; i < indices.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
		if (sym.name.len == 0) continue;

		// Skip symbols from the current file (already checked via AST)
		if (sym.uri == current_uri) continue;

		if (first_match == null) {
			first_match = sym;
		}
		if (func_match == null && sym.kind == FUNCTION) {
			func_match = sym;
		}
	}

	WorkspaceSymbol* chosen = null;
	if (is_call && func_match != null) {
		chosen = func_match;
	} else if (first_match != null) {
		chosen = first_match;
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
