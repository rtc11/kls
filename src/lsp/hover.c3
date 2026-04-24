module kls::lsp::hover;

import std::io;
import std::io::file;
import std::collections;
import std::collections::object;
import kls::json_rpc;
import kls::document;
import kls::kotlin::lexer;
import kls::kotlin::token;
import kls::kotlin::ast;
import kls::kotlin::parser;
import kls::kotlin::stdlib;
import kls::kotlin::types;
import kls::workspace;
import kls::deps::jar_index;
import kls::deps::javadoc;
import kls::deps::member_resolver;
import kls::lsp::definition;
import kls::lsp::inlay_hints;

faultdef NO_TOKEN, NO_DESCRIPTION;

/**
 * Handle textDocument/hover request.
 * Returns a Hover JSON object, or null if there is nothing to show.
 * Falls back to workspace index for cross-file identifiers.
 */
fn Object*? handle_hover(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	Object* pos = params.get("position")!;
	uint line = (uint)pos.get_int("line")!;
	uint character = (uint)pos.get_int("character")!;

	Document* doc = store.get(uri) ?? null;
	if (doc == null) {
		return null;
	}

	Token tok;
	if (try t = find_token_at_position(doc.content, line, character)) {
		tok = t;
	} else {
		return null;
	}

	String description;
	bool found_description = false;

	// For identifiers, try AST-based lookup for rich signatures
	if (tok.kind == IDENTIFIER) {
		ParseResult* pr = store.get_ast(uri) ?? null;
		TypeInfo* ti = store.get_types(uri) ?? null;
		if (pr != null) {
			if (try desc = describe_identifier_from_ast(pr, ti, doc.content, tok, workspace)) {
				description = desc;
				found_description = true;
			}
		}
		// Skip top-level stdlib/workspace lookup if the token is the member
		// name of a DOT_EXPR (e.g. `foo.println`) — those route through
		// describe_dot_member inside describe_identifier_from_ast.
		bool is_dot_member = is_dot_expr_member(pr, tok);
		// Stdlib lookup: fast in-memory match for kotlin.io.println, listOf, etc.
		if (!found_description && !is_dot_member) {
			if (try desc = describe_identifier_from_stdlib(tok)) {
				description = desc;
				found_description = true;
			}
		}
		// Cross-file workspace lookup
		if (!found_description && !is_dot_member && workspace != null) {
			if (try desc = describe_identifier_from_workspace(workspace, store, tok, uri)) {
				description = desc;
				found_description = true;
			}
		}
		// Cross-file fallback: reuse definition resolution to find the single
		// correct target, then build hover docs for that one symbol only.
		// This ensures hover and go-to-definition always agree.
		if (!found_description) {
			if (try desc = describe_from_definition(store, workspace, params)) {
				description = desc;
				found_description = true;
			}
		}
		if (!found_description) {
			// Fallback: basic identifier description
			if (try desc = describe_token(tok)) {
				description = desc;
			} else {
				return null;
			}
		}
	} else {
		if (try desc = describe_token(tok)) {
			description = desc;
		} else {
			return null;
		}
	}

	// Build hover response
	Object* contents = object::new_obj(tmem);
	contents.set("kind", "markdown");
	contents.set("value", description);

	Object* range = object::new_obj(tmem);
	Object* start = object::new_obj(tmem);
	start.set("line", (int)tok.line);
	start.set("character", (int)tok.col);
	Object* end_pos = object::new_obj(tmem);
	end_pos.set("line", (int)tok.line);
	end_pos.set("character", (int)(tok.col + tok.len));
	range.set("start", start);
	range.set("end", end_pos);

	Object* result = object::new_obj(tmem);
	result.set("contents", contents);
	result.set("range", range);

	return result;
}

/**
 * Returns true if the given token is the member name of a DOT_EXPR
 * (e.g. the `println` in `foo.println`). Used to skip top-level
 * stdlib/workspace lookups when the identifier is dotted access.
 */
fn bool is_dot_expr_member(ParseResult* pr, Token tok) {
	if (pr == null) return false;
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != DOT_EXPR) continue;
		if (n.name != tok.text) continue;
		if (n.name_line == tok.line && n.name_col == tok.col) return true;
	}
	return false;
}

/**
 * Try to find a declaration matching the identifier token in the AST
 * and return a rich signature description. Also checks for inferred
 * types from TypeInfo when explicit type annotations are missing.
 */
fn String? describe_identifier_from_ast(ParseResult* pr, TypeInfo* ti, String source, Token tok, WorkspaceIndex* workspace = null) {
	if (pr.node_count == 0) return NO_DESCRIPTION~;

	// First: check if the token sits exactly on a PARAM declaration site.
	// PARAMs are not in is_declaration() so the loop below skips them, but
	// hovering on a lambda/function param name should still show "name: Type".
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != PARAM && n.kind != TYPE_PARAM) continue;
		if (n.name != tok.text) continue;
		if (n.name_line != tok.line || n.name_col != tok.col) continue;

		// For lambda PARAMs without explicit type or TypeInfo, ask inlay-hints
		// helper to resolve the type from the enclosing call's function-type
		// param (with class-generic substitution).
		if (n.kind == PARAM && n.type_text.len == 0 &&
			(ti == null || !ti.has_type[i]) && workspace != null) {
			String inferred = inlay_hints::resolve_lambda_param_type(pr, ti, workspace, "", i);
			if (inferred.len > 0) {
				DString ds;
				ds.tinit();
				ds.appendf("```kotlin\n%s: %s\n```", n.name, inferred);
				return ds.str_view();
			}
		}

		return build_signature(n, pr, source, ti, i);
	}

	// Search all declarations for one matching this identifier name
	String target = tok.text;
	AstNode* best = null;
	uint best_idx = 0;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != target) continue;

		// Prefer the first match
		if (best == null) {
			best = n;
			best_idx = i;
		}
	}

	if (best != null) {
		return build_signature(best, pr, source, ti, best_idx);
	}

	// No declaration found - try to show inferred type for expression identifiers
	if (ti != null) {
		if (try desc = describe_expression_type(pr, ti, tok, workspace)) {
			return desc;
		}
	}

	return NO_DESCRIPTION~;
}

/**
 * Try to find an expression AST node at the token position and return
 * a description with its inferred type from TypeInfo.
 * Also handles dot-expression members (e.g. str.length -> show member info).
 */
fn String? describe_expression_type(ParseResult* pr, TypeInfo* ti, Token tok, WorkspaceIndex* workspace = null) {
	// First, check if this token is the member name of a DOT_EXPR
	if (try desc = describe_dot_member(pr, ti, tok, workspace)) {
		return desc;
	}

	// Find the NAME_EXPR or other expression node that matches this token
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind == NAME_EXPR && n.name == tok.text &&
			n.name_line == tok.line && n.name_col == tok.col) {
			if (ti.has_type[i]) {
				String type_str = types::format_type(&ti.node_types[i]);
				if (type_str.len > 0 && type_str != tok.text) {
					DString ds;
					ds.tinit();
					ds.appendf("```kotlin\n%s: %s\n```", tok.text, type_str);
					return ds.str_view();
				}
			}
			break;
		}
	}

	return NO_DESCRIPTION~;
}

// ── Receiver-filtered dependency hover ────────────────────────────

/**
 * Look up a member name in the dependency index, filtering to only show
 * overloads whose receiver type is compatible with the given type.
 *
 * Three matching strategies, in order:
 *
 * 1. Kotlin instance/extension method: signature has form "fun ReceiverType.name(...)"
 *    (Kt-class members and Kotlin extension functions with metadata).
 *
 * 2. Kotlin extension via Kt-facade fallback: receiver becomes the first parameter
 *    on the JVM (e.g., "fun listOf(Iterable<T>, ...)").
 *
 * 3. Java method (static or instance) on the receiver class: DepSymbol.class_name
 *    matches receiver type. Verified by checking the receiver class actually exists
 *    in the dep index, with package preference from explicit imports, and a one-level
 *    supertype walk if no direct member match is found. Mirrors the logic used by
 *    find_dep_member_definition in src/lsp/definition.c3 to keep hover and
 *    go-to-definition consistent.
 *
 * Phase 2 TODO: distinguish static vs instance members of Java classes via a new
 * DepSymbol.is_static flag and a TypeRef class-reference flag, so that hover on
 * `UUID.randomUUID()` (class ref → static) doesn't surface instance methods and
 * vice versa. Tracked in AGENTS.md.
 */
fn String? describe_dep_member(DependencyIndex* dep_index, Token tok, String receiver_type, ParseResult* pr = null, bool receiver_is_class_ref = false) {
	// Resolve preferred package from explicit imports of the receiver name.
	String preferred_pkg = "";
	if (pr != null) {
		ImportMap imports = workspace::build_import_map(pr);
		for (usz i = 0; i < imports.import_count; i++) {
			if (imports.import_names[i] == receiver_type && !imports.is_star[i]) {
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

	// Shared resolver: matches via signature prefix / first param /
	// declaring class, applies static-vs-class-ref filter, walks one
	// level of supertypes, and reorders by preferred package.
	DepSymbol*[16] filtered;
	usz filtered_count = member_resolver::find_dep_class_members(
		dep_index, receiver_type, tok.text, receiver_is_class_ref,
		preferred_pkg, filtered[..]);

	if (filtered_count == 0) return NO_DESCRIPTION~;

	DString ds;
	ds.tinit();

	for (usz i = 0; i < filtered_count; i++) {
		DepSymbol* sym = filtered[i];

		if (i > 0) {
			ds.appendf("\n\n---\n\n");
		}

		ds.appendf("```kotlin\n%s\n```", sym.signature);

		if (sym.package_name.len > 0) {
			ds.appendf("\n\n*%s*", sym.package_name);
		}

		if (sym.class_name.len > 0 && sym.class_name != sym.name) {
			ds.appendf(" (from %s)", sym.class_name);
		}

		// Real-time Javadoc/KDoc extraction from source archives
		if (try doc = javadoc::extract_dep_doc(sym)) {
			if (doc.len > 0) {
				ds.appendf("\n\n---\n\n%s", doc);
			}
		}
	}

	return ds.str_view();
}

/**
 * Check if the token at the cursor is a member name in a DOT_EXPR,
 * resolve the receiver type, and show member signature information.
 */
fn String? describe_dot_member(ParseResult* pr, TypeInfo* ti, Token tok, WorkspaceIndex* workspace = null) {
	// Find a DOT_EXPR node that has this token as its member name
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.kind != DOT_EXPR) continue;
		if (n.name != tok.text) continue;
		if (n.name_line != tok.line || n.name_col != tok.col) continue;

		// Found the DOT_EXPR - resolve receiver type from first child
		TypeRef receiver_type = types::TYPE_UNKNOWN;

		// The receiver is the first child of this DOT_EXPR
		uint dot_idx = i;
		for (uint j = 0; j < pr.node_count; j++) {
			if (pr.nodes[j].parent == dot_idx) {
				// First child = receiver
				if (ti.has_type[j]) {
					receiver_type = ti.node_types[j];
				}
				break;
			}
		}

		if (receiver_type.kind == UNKNOWN) {
			// Fallback: if the receiver is a bare NAME_EXPR matching a known
			// dep class (e.g. java.lang.System without explicit import), look
			// up the member directly via that class name. Mirrors the JDK
			// fallback in find_dep_member_definition.
			if (workspace != null && workspace.dep_index.initialized) {
				String recv_name = "";
				for (uint j = 0; j < pr.node_count; j++) {
					if (pr.nodes[j].parent == dot_idx && pr.nodes[j].kind == NAME_EXPR) {
						recv_name = pr.nodes[j].name;
						break;
					}
				}
				if (recv_name.len > 0) {
					// Bare NAME_EXPR matching a known dep class name → class-ref access
					bool is_class_ref = member_resolver::is_dep_class_name(&workspace.dep_index, recv_name);
					if (try desc = describe_dep_member(&workspace.dep_index, tok, recv_name, pr, is_class_ref)) {
						return desc;
					}
				}
			}
			return NO_DESCRIPTION~;
		}

		// Look up this member in the receiver type's member table
		// (instance-only — class-ref receivers fall through to dep path).
		MemberInfo[128] members;
		usz count = types::lookup_members(&receiver_type, members[..], receiver_type.is_class_ref);

		for (usz m = 0; m < count; m++) {
			if (members[m].name == tok.text) {
				DString ds;
				ds.tinit();
				ds.appendf("```kotlin\n%s\n```", members[m].signature);
				String receiver_str = types::format_type(&receiver_type);
				if (receiver_str.len > 0) {
					ds.appendf("\n\n*Member of %s*", receiver_str);
				}
				if (members[m].doc.len > 0) {
					ds.appendf("\n\n%s", members[m].doc);
				}
				return ds.str_view();
			}
		}

		// Check stdlib receiver extensions
		StdlibSymbol*[16] stdlib_matches;
		usz stdlib_count = stdlib::lookup_by_receiver(receiver_type.name, &stdlib_matches);
		for (usz m = 0; m < stdlib_count; m++) {
			if (stdlib_matches[m].name == tok.text) {
				DString ds;
				ds.tinit();
				ds.appendf("```kotlin\n%s\n```", stdlib_matches[m].signature);
				if (stdlib_matches[m].package_name.len > 0) {
					ds.appendf("\n\n*%s*", stdlib_matches[m].package_name);
				}
				if (stdlib_matches[m].doc.len > 0) {
					ds.appendf("\n\n%s", stdlib_matches[m].doc);
				}
				return ds.str_view();
			}
		}

		// Check dependency index, filtering by receiver type.
		// Kotlin extension functions compile to static methods where the
		// receiver becomes the first parameter, so we match against that.
		// Java methods (instance + static) are filtered by declaring class.
		if (workspace != null && workspace.dep_index.initialized) {
			if (try desc = describe_dep_member(&workspace.dep_index, tok, receiver_type.name, pr, receiver_type.is_class_ref)) {
				return desc;
			}
		}

		// If we found the DOT_EXPR but couldn't resolve the member,
		// at least show the inferred type of the whole expression
		if (ti.has_type[i]) {
			String type_str = types::format_type(&ti.node_types[i]);
			if (type_str.len > 0) {
				DString ds;
				ds.tinit();
				ds.appendf("```kotlin\n%s: %s\n```", tok.text, type_str);
				return ds.str_view();
			}
		}

		break;
	}

	return NO_DESCRIPTION~;
}

/**
 * Build a markdown signature string from an AST declaration node.
 * If source is provided, also appends the KDoc/comment documentation.
 * If type_info is provided, uses inferred types when type_text is empty.
 */
fn String build_signature(AstNode* node, ParseResult* pr, String source = "", TypeInfo* type_info = null, uint node_idx = 0) {
	DString ds;
	ds.tinit();

	ds.appendf("```kotlin\n");

	// Java-interop annotations (cosmetic; documents JVM bytecode shape).
	append_jvm_annotations(&ds, node);

	// Modifiers
	append_modifiers(&ds, node.mod_flags);

	// Declaration keyword + name
	switch (node.kind) {
		case FUN_DECL:
			ds.appendf("fun ");
			append_type_params(&ds, pr, node);
			// Receiver type
			if (node.extra_text.len > 0) {
				ds.appendf("%s.", node.extra_text);
			}
			ds.appendf("%s", node.name);
			// Append parameters
			ds.appendf("(");
			bool first = true;
			for (uint i = 0; i < pr.node_count; i++) {
				AstNode* child = &pr.nodes[i];
				uint n_idx = ast::node_index(pr, node);
				if (child.parent != n_idx) continue;
				if (child.kind != PARAM) continue;

				if (!first) {
					ds.appendf(", ");
				}
				first = false;
				ds.appendf("%s", child.name);
				if (child.type_text.len > 0) {
					ds.appendf(": %s", child.type_text);
				}
				if (ast::param_has_default(child)) {
					ds.appendf(" = %s", ast::param_default_text(child));
				}
			}
			ds.appendf(")");
			if (node.type_text.len > 0) {
				ds.appendf(": %s", node.type_text);
			} else if (type_info != null && type_info.has_type[node_idx]) {
				String inferred = types::format_type(&type_info.node_types[node_idx]);
				if (inferred.len > 0) {
					ds.appendf(": %s", inferred);
				}
			}
			append_where_clause(&ds, pr, node);

		case CLASS_DECL:
			ds.appendf("class %s", node.name);
			append_type_params(&ds, pr, node);
			append_where_clause(&ds, pr, node);

		case INTERFACE_DECL:
			ds.appendf("interface %s", node.name);
			append_type_params(&ds, pr, node);
			append_where_clause(&ds, pr, node);

		case OBJECT_DECL:
			ds.appendf("object %s", node.name);

		case COMPANION_OBJECT_DECL:
			ds.appendf("companion object %s", node.name);

		case PROPERTY_DECL:
			// #13: Show val vs var based on MOD_VAR flag
			String prop_keyword = (node.mod_flags & ast::MOD_VAR) != 0 ? "var" : "val";
			ds.appendf("%s ", prop_keyword);
			append_type_params(&ds, pr, node);
			// Receiver type
			if (node.extra_text.len > 0) {
				ds.appendf("%s.", node.extra_text);
			}
			ds.appendf("%s", node.name);
			if (node.type_text.len > 0) {
				ds.appendf(": %s", node.type_text);
			} else if (type_info != null && type_info.has_type[node_idx]) {
				String inferred = types::format_type(&type_info.node_types[node_idx]);
				if (inferred.len > 0) {
					ds.appendf(": %s /* inferred */", inferred);
				}
			}

		case TYPEALIAS_DECL:
			ds.appendf("typealias %s", node.name);
			append_type_params(&ds, pr, node);
			if (node.type_text.len > 0) {
				ds.appendf(" = %s", node.type_text);
			}

		case CONSTRUCTOR_DECL:
			ds.appendf("constructor(");
			bool first = true;
			for (uint i = 0; i < pr.node_count; i++) {
				AstNode* child = &pr.nodes[i];
				uint n_idx = ast::node_index(pr, node);
				if (child.parent != n_idx) continue;
				if (child.kind != PARAM) continue;

				if (!first) {
					ds.appendf(", ");
				}
				first = false;
				ds.appendf("%s", child.name);
				if (child.type_text.len > 0) {
					ds.appendf(": %s", child.type_text);
				}
				if (ast::param_has_default(child)) {
					ds.appendf(" = %s", ast::param_default_text(child));
				}
			}
			ds.appendf(")");

		case INIT_BLOCK:
			ds.appendf("init { ... }");

		case ENUM_ENTRY:
			ds.appendf("%s", node.name);

		case PARAM:
			ds.appendf("%s", node.name);
			if (node.type_text.len > 0) {
				ds.appendf(": %s", node.type_text);
			} else if (type_info != null && type_info.has_type[node_idx]) {
				String inferred = types::format_type(&type_info.node_types[node_idx]);
				if (inferred.len > 0 && inferred != node.name) {
					ds.appendf(": %s", inferred);
				}
			}
			if (ast::param_has_default(node)) {
				ds.appendf(" = %s", ast::param_default_text(node));
			}

		default:
			ds.appendf("%s", node.name);
	}

	ds.appendf("\n```");

	// Append documentation from source comments if available
	if (source.len > 0) {
		if (try doc_text = extract_doc_comment(source, node.start_offset)) {
			if (doc_text.len > 0) {
				ds.appendf("\n\n%s", doc_text);
			}
		}
	}

	return ds.str_view();
}

/**
 * Append type parameters to a DString: <T, out R : Comparable<R>, reified V>
 * Returns true if any type parameters were appended.
 */
fn bool append_type_params(DString* ds, ParseResult* pr, AstNode* node) {
	uint node_idx = ast::node_index(pr, node);
	bool has_any = false;
	bool first = true;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != node_idx) continue;
		if (child.kind != TYPE_PARAM) continue;

		if (first) {
			ds.appendf("<");
			first = false;
		} else {
			ds.appendf(", ");
		}
		has_any = true;

		// Variance
		if (child.mod_flags & ast::MOD_IN != 0) ds.appendf("in ");
		if (child.mod_flags & ast::MOD_OUT != 0) ds.appendf("out ");
		if (child.mod_flags & ast::MOD_REIFIED != 0) ds.appendf("reified ");

		// Name
		ds.appendf("%s", child.name);

		// Upper bound
		if (child.type_text.len > 0) {
			ds.appendf(" : %s", child.type_text);
		}
	}

	if (has_any) {
		ds.appendf(">");
	}
	return has_any;
}

/**
 * Append where clause constraints to a DString: where T : Comparable<T>, R : Serializable
 * Returns true if any constraints were appended.
 */
fn bool append_where_clause(DString* ds, ParseResult* pr, AstNode* node) {
	uint node_idx = ast::node_index(pr, node);
	bool first = true;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* child = &pr.nodes[i];
		if (child.parent != node_idx) continue;
		if (child.kind != WHERE_CONSTRAINT) continue;

		if (first) {
			ds.appendf(" where ");
			first = false;
		} else {
			ds.appendf(", ");
		}

		ds.appendf("%s", child.name);
		if (child.type_text.len > 0) {
			ds.appendf(" : %s", child.type_text);
		}
	}

	return !first;
}

/**
 * Append modifier keywords to a DString based on mod_flags.
 */
/**
 * Emit Java-interop annotations on a declaration as their `@Name` form,
 * one per line, before the modifier line. Cosmetic only; documents the
 * JVM bytecode shape (e.g. `@JvmStatic` companion methods are emitted
 * as static methods on the outer class). Resolution semantics unaffected.
 *
 * Whitelisted: JvmStatic, JvmField, JvmOverloads, JvmName.
 */
fn void append_jvm_annotations(DString* ds, AstNode* node) {
	if (node.annotation_text.len == 0) return;
	if (node.has_annotation("JvmStatic"))    ds.appendf("@JvmStatic\n");
	if (node.has_annotation("JvmField"))     ds.appendf("@JvmField\n");
	if (node.has_annotation("JvmOverloads")) ds.appendf("@JvmOverloads\n");
	if (node.has_annotation("JvmName"))      ds.appendf("@JvmName\n");
}

fn void append_modifiers(DString* ds, uint flags) {
	if (flags & ast::MOD_PUBLIC != 0)      ds.appendf("public ");
	if (flags & ast::MOD_PRIVATE != 0)     ds.appendf("private ");
	if (flags & ast::MOD_PROTECTED != 0)   ds.appendf("protected ");
	if (flags & ast::MOD_INTERNAL != 0)    ds.appendf("internal ");
	if (flags & ast::MOD_ABSTRACT != 0)    ds.appendf("abstract ");
	if (flags & ast::MOD_OPEN != 0)        ds.appendf("open ");
	if (flags & ast::MOD_FINAL != 0)       ds.appendf("final ");
	if (flags & ast::MOD_SEALED != 0)      ds.appendf("sealed ");
	if (flags & ast::MOD_DATA != 0)        ds.appendf("data ");
	if (flags & ast::MOD_ENUM != 0)        ds.appendf("enum ");
	if (flags & ast::MOD_INNER != 0)       ds.appendf("inner ");
	if (flags & ast::MOD_ANNOTATION != 0)  ds.appendf("annotation ");
	if (flags & ast::MOD_VALUE != 0)       ds.appendf("value ");
	if (flags & ast::MOD_INLINE != 0)      ds.appendf("inline ");
	if (flags & ast::MOD_INFIX != 0)       ds.appendf("infix ");
	if (flags & ast::MOD_OPERATOR != 0)    ds.appendf("operator ");
	if (flags & ast::MOD_SUSPEND != 0)     ds.appendf("suspend ");
	if (flags & ast::MOD_TAILREC != 0)     ds.appendf("tailrec ");
	if (flags & ast::MOD_OVERRIDE != 0)    ds.appendf("override ");
	if (flags & ast::MOD_LATEINIT != 0)    ds.appendf("lateinit ");
	if (flags & ast::MOD_CONST != 0)       ds.appendf("const ");
	if (flags & ast::MOD_EXTERNAL != 0)    ds.appendf("external ");
	if (flags & ast::MOD_EXPECT != 0)      ds.appendf("expect ");
	if (flags & ast::MOD_ACTUAL != 0)      ds.appendf("actual ");
}

// ── Doc comment extraction ─────────────────────────────────────────

/**
 * Extract the documentation comment (KDoc or consecutive line comments)
 * immediately preceding a declaration at the given source offset.
 *
 * Scans backwards from `decl_start_offset`, skipping whitespace and
 * annotations. Returns the cleaned comment text (delimiters stripped),
 * or a fault if no documentation is found.
 */
fn String? extract_doc_comment(String source, uint decl_start_offset) {
	if (decl_start_offset == 0 || source.len == 0) return NO_DESCRIPTION~;

	// Scan backward from just before the declaration start
	usz pos = (usz)decl_start_offset;

	// Skip backwards over whitespace and annotations
	pos = skip_back_whitespace_and_annotations(source, pos);

	if (pos == 0) return NO_DESCRIPTION~;

	// Check what's immediately before the declaration
	// Case 1: Block comment ending with */
	if (pos >= 2 && source[pos - 1] == '/' && source[pos - 2] == '*') {
		return extract_block_comment(source, pos);
	}

	// Case 2: Line comment(s) ending with \n before whitespace
	// We need to find if the line before the declaration is a // comment
	if (try doc = extract_line_comments(source, pos)) {
		return doc;
	}

	return NO_DESCRIPTION~;
}

/**
 * Skip backward over whitespace characters (space, tab, newline, CR).
 * Returns the new position (first non-whitespace from the right).
 */
fn usz skip_back_whitespace(String source, usz pos) {
	while (pos > 0) {
		char c = source[pos - 1];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
			pos--;
		} else {
			break;
		}
	}
	return pos;
}

/**
 * Skip backward over whitespace and annotations (e.g., @KtorDsl, @Suppress("...")).
 * Annotations can appear between a KDoc comment and the declaration keyword.
 * Handles nested parentheses in annotation arguments.
 */
fn usz skip_back_whitespace_and_annotations(String source, usz pos) {
	while (pos > 0) {
		pos = skip_back_whitespace(source, pos);
		if (pos == 0) break;

		// Check if we're at the end of an annotation
		// Annotations end with either: identifier (no args) or ')' (with args)
		char c = source[pos - 1];

		if (c == ')') {
			// Skip backward over balanced parentheses
			usz paren_pos = skip_back_balanced_parens(source, pos);
			if (paren_pos == pos) break; // couldn't match parens
			pos = paren_pos;
			// Now skip the annotation name and @
			pos = skip_back_whitespace(source, pos);
			pos = skip_back_annotation_name(source, pos);
			continue;
		}

		// Check for bare annotation: @Name without parens
		// Or modifier keywords (public, abstract, data, etc.)
		if (is_identifier_char(c)) {
			usz saved = pos;
			usz name_start = skip_back_identifier(source, pos);
			if (name_start < saved) {
				String word = source[name_start..saved - 1];
				// Check for @ before the identifier → annotation
				usz at_pos = skip_back_whitespace(source, name_start);
				if (at_pos > 0 && source[at_pos - 1] == '@') {
					pos = at_pos - 1;
					continue;
				}
				// Check if it's a modifier keyword → skip it
				if (is_modifier_keyword(word)) {
					pos = name_start;
					continue;
				}
			}
			// Not an annotation or modifier, stop
			break;
		}

		break;
	}
	return pos;
}

/**
 * Skip backward over balanced parentheses. pos points just past ')'.
 * Returns position just before the matching '('.
 */
fn usz skip_back_balanced_parens(String source, usz pos) {
	if (pos == 0 || source[pos - 1] != ')') return pos;
	pos--; // skip ')'
	int depth = 1;
	while (pos > 0 && depth > 0) {
		pos--;
		if (source[pos] == ')') {
			depth++;
		} else if (source[pos] == '(') {
			depth--;
		}
	}
	return pos; // now points just past the content before '('
}

/**
 * Skip backward over an annotation name and @ prefix.
 * Handles dotted names like @file:Suppress or @io.ktor.KtorDsl.
 */
fn usz skip_back_annotation_name(String source, usz pos) {
	// Skip identifier chars and dots (for dotted annotation names)
	while (pos > 0) {
		char c = source[pos - 1];
		if (is_identifier_char(c) || c == '.' || c == ':') {
			pos--;
		} else {
			break;
		}
	}
	// Skip @
	if (pos > 0 && source[pos - 1] == '@') {
		pos--;
	}
	return pos;
}

/**
 * Skip backward over identifier characters.
 */
fn usz skip_back_identifier(String source, usz pos) {
	while (pos > 0 && is_identifier_char(source[pos - 1])) {
		pos--;
	}
	return pos;
}

fn bool is_identifier_char(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') || c == '_';
}

/**
 * Check if a word is a Kotlin modifier keyword that can appear before
 * a declaration (between KDoc and the declaration keyword).
 */
fn bool is_modifier_keyword(String word) {
	switch (word) {
		case "public":
		case "private":
		case "protected":
		case "internal":
		case "abstract":
		case "open":
		case "final":
		case "sealed":
		case "data":
		case "enum":
		case "inner":
		case "annotation":
		case "value":
		case "inline":
		case "infix":
		case "operator":
		case "suspend":
		case "tailrec":
		case "override":
		case "lateinit":
		case "const":
		case "external":
		case "expect":
		case "actual":
		case "vararg":
		case "crossinline":
		case "noinline":
		case "reified":
			return true;
		default:
			return false;
	}
}

/**
 * Extract a block comment that ends at position `pos` (where source[pos-1]
 * is a forward slash and source[pos-2] is a star). Searches backward for
 * the opening delimiter. Only returns the content if it is a KDoc block.
 */
fn String? extract_block_comment(String source, usz end_pos) {
	// end_pos points just past the closing slash of the block end marker
	// Walk backward to find the matching block start marker
	if (end_pos < 4) return NO_DESCRIPTION~;

	int depth = 1;
	usz pos = end_pos - 2;  // skip past the */ we already found

	while (pos > 0 && depth > 0) {
		pos--;
		if (pos > 0 && source[pos - 1] == '/' && source[pos] == '*') {
			depth--;
			if (depth == 0) {
				// Found the opening /*
				usz start = pos - 1;
				String raw = source[start..end_pos - 1];
				// Only treat as doc if it starts with /**
				if (raw.len >= 3 && raw[2] == '*') {
					return clean_block_comment(raw);
				}
				return NO_DESCRIPTION~;
			}
			if (pos > 0) pos--;  // skip the '/' char
		} else if (pos > 0 && source[pos - 1] == '*' && source[pos] == '/') {
			depth++;
		}
	}

	return NO_DESCRIPTION~;
}

/**
 * Clean a KDoc block comment: strip the opening and closing delimiters,
 * remove leading whitespace and star on each line, trim the result.
 */
fn String clean_block_comment(String raw) {
	DString ds;
	ds.tinit();

	// Strip /** prefix and */ suffix
	usz start = 3;  // skip "/**"
	usz end = raw.len;
	if (end >= 2 && raw[end - 1] == '/' && raw[end - 2] == '*') {
		end -= 2;
	}

	// If the entire content after stripping is empty/whitespace
	if (start >= end) return ds.str_view();

	String body = raw[start..end - 1];

	// Process line by line
	bool first_line = true;
	usz line_start = 0;

	for (usz i = 0; i <= body.len; i++) {
		bool at_end = (i == body.len);
		bool at_newline = (!at_end && body[i] == '\n');

		if (at_end || at_newline) {
			String line;
			if (i > line_start) {
				line = body[line_start..i - 1];
			} else {
				line = "";
			}

			// Strip leading whitespace and optional leading *
			String trimmed = strip_comment_line(line);

			if (first_line) {
				// The first line might be on the same line as /**
				if (trimmed.len > 0) {
					ds.appendf("%s", trimmed);
					first_line = false;
				}
			} else {
				if (!first_line) {
					ds.appendf("\n");
				}
				ds.appendf("%s", trimmed);
				first_line = false;
			}

			line_start = i + 1;
		}
	}

	String result = ds.str_view();
	// Trim trailing whitespace/newlines
	while (result.len > 0 && (result[result.len - 1] == '\n' ||
	       result[result.len - 1] == '\r' ||
	       result[result.len - 1] == ' ' ||
	       result[result.len - 1] == '\t')) {
		result = result[:result.len - 1];
	}
	// Trim leading whitespace/newlines
	while (result.len > 0 && (result[0] == '\n' ||
	       result[0] == '\r' ||
	       result[0] == ' ' ||
	       result[0] == '\t')) {
		result = result[1..];
	}

	if (result.len == 0) return "";
	return result;
}

/**
 * Strip leading whitespace and an optional single leading '*' from a
 * KDoc line. Returns the trimmed content.
 */
fn String strip_comment_line(String line) {
	usz pos = 0;
	// Skip leading whitespace
	while (pos < line.len && (line[pos] == ' ' || line[pos] == '\t')) {
		pos++;
	}
	// Skip optional leading *
	if (pos < line.len && line[pos] == '*') {
		pos++;
		// Skip one space after * if present
		if (pos < line.len && line[pos] == ' ') {
			pos++;
		}
	}
	if (pos >= line.len) return "";
	return line[pos..];
}

/**
 * Extract consecutive // line comments immediately before a declaration.
 * Scans backwards line by line collecting comment lines.
 */
fn String? extract_line_comments(String source, usz pos) {
	// We're at the end of whitespace before the declaration.
	// Check if the line(s) before contain // comments.

	// Collect comment lines in reverse order
	String[32] lines;
	int line_count = 0;

	usz scan = pos;

	while (scan > 0 && line_count < 32) {
		// We should be just after the end of a line (or at start of file)
		// Find the start of this line
		usz line_end = scan;

		// Skip back over the newline if we're right after one
		if (scan > 0 && source[scan - 1] == '\n') {
			scan--;
			if (scan > 0 && source[scan - 1] == '\r') {
				scan--;
			}
			line_end = scan;
		} else if (line_count == 0) {
			// First iteration: we're at end of a non-newline char
			// This means the content before decl isn't newline-terminated line comments
			// It could still be a line comment if it ends right at this position
		} else {
			break;
		}

		// Find the start of this line
		usz line_start = scan;
		while (line_start > 0 && source[line_start - 1] != '\n') {
			line_start--;
		}

		// Get the line text
		if (line_end <= line_start) {
			break;
		}
		String line = source[line_start..line_end - 1];

		// Trim leading whitespace and check if it starts with //
		String trimmed = line;
		usz trim_pos = 0;
		while (trim_pos < trimmed.len && (trimmed[trim_pos] == ' ' || trimmed[trim_pos] == '\t')) {
			trim_pos++;
		}
		if (trim_pos >= trimmed.len) {
			// Blank line: stop collecting
			break;
		}

		if (trim_pos + 1 < trimmed.len && trimmed[trim_pos] == '/' && trimmed[trim_pos + 1] == '/') {
			// It's a line comment -- extract content after //
			usz content_start = trim_pos + 2;
			// Skip one space after // if present
			if (content_start < trimmed.len && trimmed[content_start] == ' ') {
				content_start++;
			}
			String content;
			if (content_start < trimmed.len) {
				content = trimmed[content_start..];
			} else {
				content = "";
			}
			lines[line_count] = content;
			line_count++;
			scan = line_start;
		} else {
			// Not a comment line: stop
			break;
		}
	}

	if (line_count == 0) return NO_DESCRIPTION~;

	// Build the result in forward order (lines were collected in reverse)
	DString ds;
	ds.tinit();
	for (int i = line_count - 1; i >= 0; i--) {
		if (i < line_count - 1) {
			ds.appendf("\n");
		}
		ds.appendf("%s", lines[i]);
	}

	String result = ds.str_view();
	if (result.len == 0) return NO_DESCRIPTION~;
	return result;
}

/**
 * Extract the text for a specific @param tag from a doc comment.
 * Returns the description text for the named parameter, or a fault.
 */
fn String? extract_param_doc(String doc_text, String param_name) {
	if (doc_text.len == 0 || param_name.len == 0) return NO_DESCRIPTION~;

	// Search for @param <name> pattern
	usz pos = 0;
	while (pos + 7 + param_name.len < doc_text.len) {
		// Look for @param
		if (doc_text[pos] == '@' && pos + 6 <= doc_text.len &&
			doc_text[pos + 1] == 'p' && doc_text[pos + 2] == 'a' &&
			doc_text[pos + 3] == 'r' && doc_text[pos + 4] == 'a' &&
			doc_text[pos + 5] == 'm') {
			usz tag_end = pos + 6;
			// Skip whitespace after @param
			while (tag_end < doc_text.len && (doc_text[tag_end] == ' ' || doc_text[tag_end] == '\t')) {
				tag_end++;
			}
			// Check if the parameter name matches
			if (tag_end + param_name.len <= doc_text.len) {
				bool name_match = true;
				for (usz j = 0; j < param_name.len; j++) {
					if (doc_text[tag_end + j] != param_name[j]) {
						name_match = false;
						break;
					}
				}
				if (name_match) {
					// Check that the name is followed by whitespace or end
					usz after_name = tag_end + param_name.len;
					if (after_name >= doc_text.len ||
						doc_text[after_name] == ' ' || doc_text[after_name] == '\t' ||
						doc_text[after_name] == '\n') {
						// Extract the description: from after the name to end of line
						usz desc_start = after_name;
						// Skip whitespace before description
						while (desc_start < doc_text.len &&
							(doc_text[desc_start] == ' ' || doc_text[desc_start] == '\t')) {
							desc_start++;
						}
						// Find end of description (next @tag or end)
						usz desc_end = desc_start;
						while (desc_end < doc_text.len) {
							if (doc_text[desc_end] == '\n') {
								// Check if next non-whitespace line starts with @
								usz next = desc_end + 1;
								while (next < doc_text.len &&
									(doc_text[next] == ' ' || doc_text[next] == '\t')) {
									next++;
								}
								if (next < doc_text.len && doc_text[next] == '@') {
									break;
								}
								// Continuation line: include it
							}
							desc_end++;
						}
						if (desc_end > desc_start) {
							String desc = doc_text[desc_start..desc_end - 1];
							// Trim trailing whitespace
							while (desc.len > 0 && (desc[desc.len - 1] == ' ' ||
								desc[desc.len - 1] == '\n' ||
								desc[desc.len - 1] == '\r' ||
								desc[desc.len - 1] == '\t')) {
								desc = desc[:desc.len - 1];
							}
							if (desc.len > 0) return desc;
						}
					}
				}
			}
		}
		pos++;
	}

	return NO_DESCRIPTION~;
}

/**
 * Convert an LSP position (line, character) to a byte offset in the source.
 * Per LSP spec, line/char past end clamp to end of line/content.
 * Delegates to the canonical implementation in document.c3.
 */
fn long position_to_offset(String content, uint line, uint character) {
	return document::position_to_byte_offset(content, line, character);
}

/**
 * Find the token at the given LSP position by converting to a byte offset
 * and scanning all tokens. Returns the matching token or a fault.
 */
fn Token? find_token_at_position(String content, uint line, uint character) {
	long byte_offset = position_to_offset(content, line, character);
	if (byte_offset < 0) {
		return NO_TOKEN~;
	}
	usz target = (usz)byte_offset;

	Lexer lex = lexer::init(content);
	while (true) {
		Token tok = lex.next();
		if (tok.kind == EOF) break;

		usz tok_start = (usz)tok.offset;
		usz tok_end = tok_start + (usz)tok.len;
		if (target >= tok_start && target < tok_end) {
			return tok;
		}
	}

	return NO_TOKEN~;
}

/**
 * Return a markdown description for a token, or a fault for tokens
 * that should not show hover (basic punctuation).
 */
fn String? describe_token(Token tok) {
	switch (tok.kind) {
		// ── Hard Keywords ──────────────────────────────────────────
		case KW_PACKAGE:     return "**package** (keyword)\n\nDeclares the package for the current file.";
		case KW_IMPORT:      return "**import** (keyword)\n\nImports a class, function, or property.";
		case KW_CLASS:       return "**class** (keyword)\n\nDeclares a class.";
		case KW_INTERFACE:   return "**interface** (keyword)\n\nDeclares an interface.";
		case KW_FUN:         return "**fun** (keyword)\n\nDeclares a function.";
		case KW_OBJECT:      return "**object** (keyword)\n\nDeclares a singleton object or object expression.";
		case KW_VAL:         return "**val** (keyword)\n\nDeclares a read-only property or local variable.";
		case KW_VAR:         return "**var** (keyword)\n\nDeclares a mutable property or local variable.";
		case KW_TYPEALIAS:   return "**typealias** (keyword)\n\nDeclares a type alias.";
		case KW_CONSTRUCTOR: return "**constructor** (keyword)\n\nDeclares a secondary constructor.";
		case KW_BY:          return "**by** (keyword)\n\nUsed for delegation or delegated properties.";
		case KW_COMPANION:   return "**companion** (keyword)\n\nDeclares a companion object inside a class.";
		case KW_INIT:        return "**init** (keyword)\n\nDeclares an initializer block.";
		case KW_THIS:        return "**this** (keyword)\n\nRefers to the current instance.";
		case KW_SUPER:       return "**super** (keyword)\n\nRefers to the superclass implementation.";
		case KW_TYPEOF:      return "**typeof** (keyword)\n\nReserved for future use.";
		case KW_WHERE:       return "**where** (keyword)\n\nSpecifies constraints for generic type parameters.";
		case KW_IF:          return "**if** (keyword)\n\nConditional expression or statement.";
		case KW_ELSE:        return "**else** (keyword)\n\nAlternative branch of an `if` expression.";
		case KW_WHEN:        return "**when** (keyword)\n\nPattern matching expression (similar to `switch`).";
		case KW_TRY:         return "**try** (keyword)\n\nBegins a try-catch-finally block for exception handling.";
		case KW_CATCH:       return "**catch** (keyword)\n\nHandles exceptions thrown in a `try` block.";
		case KW_FINALLY:     return "**finally** (keyword)\n\nBlock that always executes after `try`/`catch`.";
		case KW_FOR:         return "**for** (keyword)\n\nIterates over an iterable or range.";
		case KW_DO:          return "**do** (keyword)\n\nBegins a `do-while` loop.";
		case KW_WHILE:       return "**while** (keyword)\n\nLoop that repeats while a condition is true.";
		case KW_THROW:       return "**throw** (keyword)\n\nThrows an exception.";
		case KW_RETURN:      return "**return** (keyword)\n\nReturns a value from a function.";
		case KW_CONTINUE:    return "**continue** (keyword)\n\nSkips to the next iteration of a loop.";
		case KW_BREAK:       return "**break** (keyword)\n\nExits the enclosing loop.";
		case KW_AS:          return "**as** (keyword)\n\nType cast operator. Use `as?` for safe casts.";
		case AS_SAFE:        return "**as?** (keyword)\n\nSafe type cast operator. Returns null if the cast fails.";
		case KW_IS:          return "**is** (keyword)\n\nType check operator. Returns true if the expression is of the given type.";
		case KW_IN:          return "**in** (keyword)\n\nChecks containment or iterates in a `for` loop.";
		case KW_OUT:         return "**out** (keyword)\n\nMarks a type parameter as covariant (producer).";
		case KW_DYNAMIC:     return "**dynamic** (keyword)\n\nDynamic type for Kotlin/JS interop.";

		// ── Soft Keywords (modifiers) ──────────────────────────────
		case KW_ABSTRACT:    return "**abstract** (modifier)\n\nMarks a class or member as abstract (must be overridden).";
		case KW_ANNOTATION:  return "**annotation** (modifier)\n\nDeclares an annotation class.";
		case KW_DATA:        return "**data** (modifier)\n\nMarks a class as a data class (auto-generates equals, hashCode, toString, copy).";
		case KW_ENUM:        return "**enum** (modifier)\n\nDeclares an enum class.";
		case KW_EXTERNAL:    return "**external** (modifier)\n\nMarks a declaration as implemented outside Kotlin (e.g., in JavaScript).";
		case KW_FINAL:       return "**final** (modifier)\n\nPrevents overriding of a member (default for classes and members).";
		case KW_INFIX:       return "**infix** (modifier)\n\nAllows calling a function with infix notation (`a foo b`).";
		case KW_INLINE:      return "**inline** (modifier)\n\nInlines the function body and its lambda parameters at call sites.";
		case KW_INNER:       return "**inner** (modifier)\n\nAllows a nested class to access members of its outer class.";
		case KW_INTERNAL:    return "**internal** (visibility)\n\nVisible within the same module.";
		case KW_LATEINIT:    return "**lateinit** (modifier)\n\nAllows initializing a non-null property after construction.";
		case KW_NOINLINE:    return "**noinline** (modifier)\n\nPrevents inlining of a lambda parameter in an inline function.";
		case KW_OPEN:        return "**open** (modifier)\n\nAllows a class to be subclassed or a member to be overridden.";
		case KW_OPERATOR:    return "**operator** (modifier)\n\nMarks a function as an operator overload.";
		case KW_OVERRIDE:    return "**override** (modifier)\n\nOverrides a superclass member or interface method.";
		case KW_PRIVATE:     return "**private** (visibility)\n\nVisible only within the declaring scope.";
		case KW_PROTECTED:   return "**protected** (visibility)\n\nVisible within the class and its subclasses.";
		case KW_PUBLIC:      return "**public** (visibility)\n\nVisible everywhere (default visibility).";
		case KW_REIFIED:     return "**reified** (modifier)\n\nMakes a type parameter accessible at runtime in an inline function.";
		case KW_SEALED:      return "**sealed** (modifier)\n\nRestricts a class hierarchy to a fixed set of subclasses.";
		case KW_SUSPEND:     return "**suspend** (modifier)\n\nMarks a function or lambda as suspendable (coroutines).";
		case KW_TAILREC:     return "**tailrec** (modifier)\n\nOptimizes a tail-recursive function into a loop.";
		case KW_VARARG:      return "**vararg** (modifier)\n\nAllows passing a variable number of arguments.";
		case KW_CROSSINLINE: return "**crossinline** (modifier)\n\nPrevents non-local returns in an inlined lambda.";
		case KW_CONST:       return "**const** (modifier)\n\nMarks a property as a compile-time constant.";
		case KW_EXPECT:      return "**expect** (modifier)\n\nDeclares a platform-specific API expectation (multiplatform).";
		case KW_ACTUAL:      return "**actual** (modifier)\n\nProvides a platform-specific implementation (multiplatform).";
		case KW_VALUE:       return "**value** (modifier)\n\nDeclares an inline (value) class.";

		// ── Soft Keywords (property/accessor) ──────────────────────
		case KW_GET:         return "**get** (accessor)\n\nDefines a custom getter for a property.";
		case KW_SET:         return "**set** (accessor)\n\nDefines a custom setter for a property.";
		case KW_FIELD:       return "**field** (accessor)\n\nRefers to the backing field in a property accessor.";
		case KW_PROPERTY:    return "**property** (use-site target)\n\nAnnotation target for the property itself.";
		case KW_RECEIVER:    return "**receiver** (use-site target)\n\nAnnotation target for the extension receiver parameter.";
		case KW_PARAM:       return "**param** (use-site target)\n\nAnnotation target for the constructor parameter.";
		case KW_SETPARAM:    return "**setparam** (use-site target)\n\nAnnotation target for the setter parameter.";
		case KW_DELEGATE:    return "**delegate** (use-site target)\n\nAnnotation target for the delegate field.";
		case KW_FILE:        return "**file** (use-site target)\n\nAnnotation target for the file.";

		// ── Literals ───────────────────────────────────────────────
		case INTEGER_LITERAL:
			DString ds;
			ds.tinit();
			ds.appendf("**Integer literal**: `%s`\n\nType: ", tok.text);
			if (tok.text.len > 0 && (tok.text[tok.text.len - 1] == 'L')) {
				ds.appendf("Long");
			} else if (tok.text.len > 1 && (tok.text[tok.text.len - 1] == 'u' || tok.text[tok.text.len - 1] == 'U')) {
				ds.appendf("UInt");
			} else {
				ds.appendf("Int");
			}
			return ds.str_view();

		case FLOAT_LITERAL:
			DString ds;
			ds.tinit();
			ds.appendf("**Float literal**: `%s`\n\nType: ", tok.text);
			if (tok.text.len > 0 && (tok.text[tok.text.len - 1] == 'f' || tok.text[tok.text.len - 1] == 'F')) {
				ds.appendf("Float");
			} else {
				ds.appendf("Double");
			}
			return ds.str_view();

		case BOOLEAN_LITERAL:
			DString ds;
			ds.tinit();
			ds.appendf("**Boolean literal**: `%s`\n\nType: Boolean", tok.text);
			return ds.str_view();

		case NULL_LITERAL:
			return "**null**\n\nThe null reference. Type: Nothing?";

		case STRING_CONTENT:
			return "**String literal**\n\nType: String";

		case CHARACTER_LITERAL:
			DString ds;
			ds.tinit();
			ds.appendf("**Character literal**: `%s`\n\nType: Char", tok.text);
			return ds.str_view();

		// ── Operators (interesting ones) ───────────────────────────
		case SAFE_CALL:    return "**?.** (safe call)\n\nCalls a method or accesses a property only if the receiver is non-null.";
		case ELVIS:        return "**?:** (elvis operator)\n\nReturns the left operand if non-null, otherwise the right operand.";
		case NOT_NULL:     return "**!!** (not-null assertion)\n\nAsserts that a value is non-null, throwing NullPointerException if it is null.";
		case RANGE:        return "**..** (range operator)\n\nCreates a range from the left to the right operand (inclusive).";
		case RANGE_UNTIL:  return "**..<** (range-until operator)\n\nCreates a range from the left operand (inclusive) to the right operand (exclusive).";
		case COLONCOLON:   return "**::** (member reference)\n\nCreates a reference to a function, property, or constructor.";
		case ARROW:        return "**->** (arrow)\n\nSeparates parameters from the body in a lambda, or conditions from results in a `when` branch.";
		case DOUBLE_ARROW: return "**=>** (double arrow)\n\nUsed in certain annotation and builder contexts.";
		case EQEQ:         return "**==** (structural equality)\n\nChecks structural equality (calls `equals()`).";
		case EXCL_EQ:      return "**!=** (structural inequality)\n\nChecks structural inequality.";
		case EQEQEQ:       return "**===** (referential equality)\n\nChecks that two references point to the same object.";
		case EXCL_EQEQ:    return "**!==** (referential inequality)\n\nChecks that two references point to different objects.";
		case LE:           return "**<=** (less than or equal)\n\nComparison operator.";
		case GE:           return "**>=** (greater than or equal)\n\nComparison operator.";
		case CONJ:         return "**&&** (logical AND)\n\nShort-circuit logical conjunction.";
		case DISJ:         return "**||** (logical OR)\n\nShort-circuit logical disjunction.";
		case QUEST:        return "**?** (nullable type marker)\n\nMarks a type as nullable.";

		// ── Identifiers ────────────────────────────────────────────
		case IDENTIFIER:
			DString ds;
			ds.tinit();
			ds.appendf("Identifier: `%s`", tok.text);
			return ds.str_view();

		// ── Everything else (basic punctuation) ────────────────────
		default:
			return NO_DESCRIPTION~;
	}
}

// ── Definition-based hover resolution ─────────────────────────────

/**
 * Resolve the definition target using the same logic as go-to-definition,
 * then build hover documentation for that single resolved symbol.
 *
 * This ensures hover shows exactly one result — the same symbol that
 * go-to-definition would navigate to — instead of listing all name matches.
 */
fn String? describe_from_definition(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	// Call the definition handler to resolve the target location
	Object* location = definition::handle_definition(store, workspace, params)!;
	if (location == null) return NO_DESCRIPTION~;

	// Extract uri, line, col from the Location result
	String target_uri = location.get_string("uri")!;

	Object* range = location.get("range")!;
	Object* start = range.get("start")!;
	uint target_line = (uint)start.get_int("line")!;
	uint target_col = (uint)start.get_int("character")!;

	// Get the content of the target file
	String content;
	char[] disk_data;
	bool have_content = false;

	if (try doc = store.get(target_uri)) {
		content = doc.content;
		have_content = true;
	} else {
		String file_path = workspace::uri_to_path(target_uri);
		if (try d = std::io::file::load(tmem, file_path)) {
			disk_data = d;
			content = (String)disk_data;
			have_content = true;
		}
	}

	if (!have_content) {
		// File not accessible — fall back to workspace symbol info
		if (workspace != null) {
			if (try desc = describe_workspace_symbol_at(workspace, target_uri, target_line, target_col)) {
				return desc;
			}
		}
		return NO_DESCRIPTION~;
	}

	// Parse the target file and find the declaration at the resolved position
	ParseResult* pr = mem::new(ParseResult);
	defer mem::free(pr);
	parser::parse(content, pr);
	if (pr.node_count == 0) return NO_DESCRIPTION~;

	// Find the declaration node at the exact resolved position
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind) && n.kind != PARAM && n.kind != TYPE_PARAM) continue;
		if (n.name_line == target_line && n.name_col == target_col) {
			return build_signature(n, pr, content);
		}
	}

	// Exact match not found — try name match at the target line
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind) && n.kind != PARAM && n.kind != TYPE_PARAM) continue;
		if (n.name_line == target_line) {
			return build_signature(n, pr, content);
		}
	}

	return NO_DESCRIPTION~;
}

/**
 * Find a workspace symbol at a specific uri/line/col and return a basic
 * hover description (no AST parsing). Used when the target file is not
 * accessible (not open and not on disk).
 */
fn String? describe_workspace_symbol_at(WorkspaceIndex* workspace, String uri, uint line, uint col) {
	// Scan all symbols to find one matching the location
	for (usz i = 0; i < workspace.symbols.len(); i++) {
		WorkspaceSymbol* sym = workspace.get_symbol(i);
		if (sym.name.len == 0) continue;
		if (sym.uri != uri) continue;
		if (sym.line == line && sym.col == col) {
			return describe_workspace_symbol(sym);
		}
	}
	return NO_DESCRIPTION~;
}

// ── Cross-file hover ──────────────────────────────────────────────

/**
 * Look up an identifier in the bundled kotlin-stdlib index and produce
 * a hover description with signature, package, and documentation.
 * Returns all matching overloads separated by horizontal rules.
 */
fn String? describe_identifier_from_stdlib(Token tok) {
	String target = tok.text;

	StdlibSymbol*[16] matches;
	usz count = stdlib::lookup_all_by_name(target, &matches);
	if (count == 0) return NO_DESCRIPTION~;

	DString ds;
	ds.tinit();

	for (usz i = 0; i < count; i++) {
		StdlibSymbol* sym = matches[i];

		if (i > 0) {
			ds.appendf("\n\n---\n\n");
		}

		ds.appendf("```kotlin\n%s\n```", sym.signature);

		if (sym.package_name.len > 0) {
			ds.appendf("\n\n*%s*", sym.package_name);
		}

		if (sym.doc.len > 0) {
			ds.appendf("\n\n%s", sym.doc);
		}
	}

	return ds.str_view();
}

// ── Cross-file hover (workspace) ──────────────────────────────────

/**
 * Look up an identifier in the workspace index and try to produce a
 * rich signature. First tries parsing the target file for an AST-based
 * signature; falls back to a basic description from the workspace symbol.
 */
fn String? describe_identifier_from_workspace(WorkspaceIndex* workspace, DocumentStore* store, Token tok, String current_uri) {
	String target = tok.text;

	if (try indices = workspace.lookup_by_name(target)) {
		// Find best match (skip same-file symbols, check module visibility)
		WorkspaceSymbol* best = null;
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.name.len == 0) continue;
			if (sym.uri == current_uri) continue;
			if (!workspace.is_module_visible(sym.uri, current_uri)) continue;
			best = sym;
			break;
		}

		if (best == null) return NO_DESCRIPTION~;

		// Try to get rich signature by parsing the target file
		if (try desc = describe_from_file(best, store)) {
			return desc;
		}

		// Fall back to basic workspace symbol info
		return describe_workspace_symbol(best);
	}

	return NO_DESCRIPTION~;
}

/**
 * Try to parse the target file and extract a rich signature for the symbol.
 * Checks open documents first, falls back to reading from disk.
 */
fn String? describe_from_file(WorkspaceSymbol* sym, DocumentStore* store) {
	String content;
	bool from_disk = false;
	char[] disk_data;

	// Check if file is open in document store
	if (try doc = store.get(sym.uri)) {
		content = doc.content;
	} else {
		// Read from disk
		String file_path = workspace::uri_to_path(sym.uri);
		if (try d = file::load(tmem, file_path)) {
			disk_data = d;
			content = (String)disk_data;
		} else {
			return NO_DESCRIPTION~;
		}
	}

	// Parse the content and find the declaration
	ParseResult* pr = mem::new(ParseResult);
	defer mem::free(pr);
	parser::parse(content, pr);
	if (pr.node_count == 0) return NO_DESCRIPTION~;

	// Find the declaration node matching the symbol
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != sym.name) continue;
		if (n.name_line == sym.line && n.name_col == sym.col) {
			return build_signature(n, pr, content);
		}
	}

	// If exact position match failed, try first name match
	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != sym.name) continue;
		return build_signature(n, pr, content);
	}

	return NO_DESCRIPTION~;
}

/**
 * Build a basic hover description from a workspace symbol (no AST).
 */
fn String describe_workspace_symbol(WorkspaceSymbol* sym) {
	DString ds;
	ds.tinit();

	ds.appendf("```kotlin\n");
	switch (sym.kind) {
		case FUNCTION:  ds.appendf("fun %s(...)", sym.name);
		case CLASS:     ds.appendf("class %s", sym.name);
		case INTERFACE: ds.appendf("interface %s", sym.name);
		case OBJECT:    ds.appendf("object %s", sym.name);
		case PROPERTY:  ds.appendf("val %s", sym.name);
		case TYPEALIAS: ds.appendf("typealias %s", sym.name);
	}
	ds.appendf("\n```");

	if (sym.package_name.len > 0) {
		ds.appendf("\n\n*%s*", sym.package_name);
	}

	return ds.str_view();
}

// ── Dependency hover ──────────────────────────────────────────────

/**
 * Look up an identifier in the dependency index (indexed JARs) and produce
 * a hover description with signature, package, and declaring class.
 * Returns all matching overloads separated by horizontal rules.
 */
fn String? describe_identifier_from_deps(DependencyIndex* dep_index, Token tok) {
	String target = tok.text;

	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(target, &matches);
	if (count == 0) return NO_DESCRIPTION~;

	DString ds;
	ds.tinit();

	for (usz i = 0; i < count; i++) {
		DepSymbol* sym = matches[i];

		if (i > 0) {
			ds.appendf("\n\n---\n\n");
		}

		ds.appendf("```kotlin\n%s\n```", sym.signature);

		if (sym.package_name.len > 0) {
			ds.appendf("\n\n*%s*", sym.package_name);
		}

		if (sym.class_name.len > 0 && sym.class_name != sym.name) {
			ds.appendf(" (from %s)", sym.class_name);
		}

		// Real-time Javadoc/KDoc extraction from source archives
		if (try doc = javadoc::extract_dep_doc(sym)) {
			if (doc.len > 0) {
				ds.appendf("\n\n---\n\n%s", doc);
			}
		}
	}

	return ds.str_view();
}
