module kls::lsp::execute_command;

import std::collections::object;
import std::os::process;
import std::io;
import std::io::file;
import std::io::path;
import std::thread;
import kls::log;
import kls::json_rpc;
import kls::workspace;
import kls::document;
import kls::kotlin::symbols;
import kls::kotlin::ast;
import kls::kotlin::types;
import kls::deps::classpath;
import kls::lsp::progress;
import kls::lsp::hover;
import kls::lsp::definition;
import kls::lsp::references;
import kls::lsp::diagnostics;

fn String resolved_member_type_text(DocumentStore* store, WorkspaceIndex* workspace, MemberDecl* member) {
	if (store == null) return member.type_text;

	ParseResult* pr = workspace.get_cached_ast(member.uri) ?? null;
	if (pr == null) return member.type_text;

	String source = "";
	if (try doc = store.get(member.uri)) source = doc.content;
	if (source.len == 0) return member.type_text;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name != member.name) continue;
		if (n.name_line != member.line || n.name_col != member.col) continue;
		if (n.kind != member.node_kind) continue;
		if (n.type_text.len == 0) continue;
		AstNode* type_node = ast::find_child(pr, n, TYPE_REF) ?? null;
		if (type_node != null) {
			return ast::type_ref_name(pr, ast::node_index(pr, type_node), source, tmem);
		}
	}

	return member.type_text;
}

// ── Command IDs (must match code_lens.c3) ──────────────────────────

const String CMD_RUN_MAIN = "kotlin.runMain";
const String CMD_RUN_TEST = "kotlin.runTest";
const String CMD_QUERY_INDEX = "kotlin.queryIndex";

// ── Debug introspection commands (for kls-query MCP) ───────────────

const String CMD_LIST_DOCUMENTS    = "kotlin.listOpenDocuments";
const String CMD_DIAGNOSTICS_FOR   = "kotlin.diagnosticsForUri";
const String CMD_HOVER_AT          = "kotlin.hoverAt";
const String CMD_DEFINITION_AT     = "kotlin.definitionAt";
const String CMD_REFERENCES_AT     = "kotlin.referencesAt";
const String CMD_AST_AT            = "kotlin.astAt";
const String CMD_TYPE_AT           = "kotlin.typeAt";
const String CMD_LAST_EDITED       = "kotlin.lastEditedUri";
const String CMD_LAST_CURSOR       = "kotlin.lastCursor";

/**
 * Handle workspace/executeCommand request.
 *
 * Run/test commands:
 *   kotlin.runMain  [uri, "", "main"]                — run main() via Gradle or kotlinc
 *   kotlin.runTest  [uri, className, funcName]      — run test via Gradle
 *
 * Index introspection:
 *   kotlin.queryIndex            [name?]             — workspace symbol summary or by-name lookup
 *
 * Live debug introspection (returns JSON synchronously, used by kls-query MCP):
 *   kotlin.listOpenDocuments     []                  — list all open documents
 *   kotlin.diagnosticsForUri     [uri]               — recompute + return diagnostics
 *   kotlin.hoverAt               [uri, line, char]   — hover JSON at position
 *   kotlin.definitionAt          [uri, line, char]   — definition Location JSON
 *   kotlin.referencesAt          [uri, line, char]   — references array
 *   kotlin.astAt                 [uri, line, char]   — AST node + parent chain at position
 *   kotlin.typeAt                [uri, line, char]   — kls-internal TypeRef debug string
 *   kotlin.lastEditedUri         []                  — most-recent didOpen/didChange URI
 *
 * line/char are 0-based per LSP spec.
 *
 * Returns null on success for fire-and-forget commands. Sends window/logMessage with output.
 */
fn Object*? handle_execute_command(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	String command = params.get_string("command") ?? "";
	Object* args = params.get("arguments") ?? null;

	if (command.len == 0) {
		log::err("[kls] executeCommand: missing command");
		return null;
	}

	log::info("[kls] executeCommand: %s", command);

	switch (command) {
		case CMD_RUN_MAIN:
			execute_run_main(workspace, args);
		case CMD_RUN_TEST:
			execute_run_test(workspace, args);
		case CMD_QUERY_INDEX:
			return execute_query_index_with_store(store, workspace, args);
		case CMD_LIST_DOCUMENTS:
			return execute_list_documents(store);
		case CMD_DIAGNOSTICS_FOR:
			return execute_diagnostics_for_uri(store, workspace, args);
		case CMD_HOVER_AT:
			return execute_hover_at(store, workspace, args);
		case CMD_DEFINITION_AT:
			return execute_definition_at(store, workspace, args);
		case CMD_REFERENCES_AT:
			return execute_references_at(store, workspace, args);
		case CMD_AST_AT:
			return execute_ast_at(store, args);
		case CMD_TYPE_AT:
			return execute_type_at(store, args);
		case CMD_LAST_EDITED:
			return execute_last_edited(store);
		case CMD_LAST_CURSOR:
			return execute_last_cursor(store);
		default:
			log::err("[kls] executeCommand: unknown command '%s'", command);
			show_message(3, "Unknown command: ");
	}

	return null;
}

/**
 * Build the executeCommand options for server capabilities.
 * Lists all commands the server supports.
 */
fn Object* build_execute_command_options() {
	Object* opts = object::new_obj(tmem);
	Object* commands = object::new_obj(tmem);
	commands.push(object::new_string(CMD_RUN_MAIN, tmem));
	commands.push(object::new_string(CMD_RUN_TEST, tmem));
	commands.push(object::new_string(CMD_QUERY_INDEX, tmem));
	commands.push(object::new_string(CMD_LIST_DOCUMENTS, tmem));
	commands.push(object::new_string(CMD_DIAGNOSTICS_FOR, tmem));
	commands.push(object::new_string(CMD_HOVER_AT, tmem));
	commands.push(object::new_string(CMD_DEFINITION_AT, tmem));
	commands.push(object::new_string(CMD_REFERENCES_AT, tmem));
	commands.push(object::new_string(CMD_AST_AT, tmem));
	commands.push(object::new_string(CMD_TYPE_AT, tmem));
	commands.push(object::new_string(CMD_LAST_EDITED, tmem));
	commands.push(object::new_string(CMD_LAST_CURSOR, tmem));
	opts.set("commands", commands);
	return opts;
}

// ── Run main ───────────────────────────────────────────────────────

fn void execute_run_main(WorkspaceIndex* workspace, Object* args) {
	String uri = "";
	if (args != null && args.get_len() >= 1) {
		uri = args.get_at(0).s;
	}

	String root = workspace.root_path;
	if (root.len == 0) {
		show_message(1, "No workspace root configured");
		return;
	}

	switch (workspace.classpath.build_system) {
		case GRADLE:
			// Determine module for this URI
			String mod_name = find_module_for_uri(workspace, uri);
			String task;
			if (mod_name.len > 0 && mod_name != ":") {
				DString buf;
				buf.tinit();
				buf.appendf("%s:run", mod_name);
				task = buf.str_view();
			} else {
				task = "run";
			}
			run_gradle(root, task);

		case MAVEN:
			run_command(root, {"mvn", "compile", "exec:java"});

		case NONE:
			// Standalone: try kotlinc + kotlin
			run_standalone_main(root, uri);
	}
}

// ── Run test ───────────────────────────────────────────────────────

fn void execute_run_test(WorkspaceIndex* workspace, Object* args) {
	String uri = "";
	String class_name = "";
	String func_name = "";
	if (args != null) {
		if (args.get_len() >= 1) uri = args.get_at(0).s;
		if (args.get_len() >= 2) class_name = args.get_at(1).s;
		if (args.get_len() >= 3) func_name = args.get_at(2).s;
	}

	String root = workspace.root_path;
	if (root.len == 0) {
		show_message(1, "No workspace root configured");
		return;
	}

	// Build test filter
	DString filter;
	filter.tinit();

	// Find package for fully-qualified test name
	String pkg = find_package_for_uri(workspace, uri);

	if (class_name.len > 0 && func_name.len > 0) {
		// Specific test method
		if (pkg.len > 0) {
			filter.appendf("%s.%s.%s", pkg, class_name, func_name);
		} else {
			filter.appendf("%s.%s", class_name, func_name);
		}
	} else if (class_name.len > 0) {
		// All tests in class
		if (pkg.len > 0) {
			filter.appendf("%s.%s", pkg, class_name);
		} else {
			filter.appendf("%s", class_name);
		}
	} else {
		// Top-level test function (no class)
		if (func_name.len > 0) {
			if (pkg.len > 0) {
				filter.appendf("%s.%s", pkg, func_name);
			} else {
				filter.appendf("%s", func_name);
			}
		}
	}

	switch (workspace.classpath.build_system) {
		case GRADLE:
			String mod_name = find_module_for_uri(workspace, uri);
			DString task;
			task.tinit();
			if (mod_name.len > 0 && mod_name != ":") {
				task.appendf("%s:test", mod_name);
			} else {
				task.appendf("test");
			}

			if (filter.str_view().len > 0) {
				run_gradle_with_filter(root, task.str_view(), filter.str_view());
			} else {
				run_gradle(root, task.str_view());
			}

		case MAVEN:
			if (filter.str_view().len > 0) {
				DString arg;
				arg.tinit();
				arg.appendf("-Dtest=%s", filter.str_view());
				run_command(root, {"mvn", "test", arg.str_view()});
			} else {
				run_command(root, {"mvn", "test"});
			}

		case NONE:
			show_message(1, "No build system found — cannot run tests without Gradle or Maven");
	}
}

// ── Query index ────────────────────────────────────────────────────

/**
 * Query the workspace index for debugging.
 * No args: returns summary (counts + file list).
 * args[0] = name: returns full symbol details for matching symbols.
 */
fn String member_type_text(DocumentStore* store, WorkspaceIndex* workspace, MemberDecl* member) {
	ParseResult* pr = workspace.get_cached_ast(member.uri) ?? null;
	if (pr == null) return member.type_text;

	String source = "";
	if (try doc = store.get(member.uri)) source = doc.content;
	if (source.len == 0) return member.type_text;

	for (uint i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (n.name != member.name) continue;
		if (n.name_line != member.line || n.name_col != member.col) continue;
		if (n.kind != member.node_kind) continue;
		AstNode* type_node = ast::find_child(pr, n, TYPE_REF) ?? null;
		if (type_node != null) {
			return ast::type_ref_name(pr, ast::node_index(pr, type_node), source, tmem);
		}
	}

	return member.type_text;
}

fn Object* execute_query_index_with_store(DocumentStore* store, WorkspaceIndex* workspace, Object* args) {
	String query = "";
	if (args != null && args.get_len() >= 1) {
		query = args.get_at(0).s;
	}

	Object* result = object::new_obj(tmem);
	result.set("root_uri", workspace.root_uri);
	result.set("root_path", workspace.root_path);
	result.set("symbol_count", (int)workspace.symbols.len());

	int file_count = 0;
	foreach (key : workspace.files.tkeys()) {
		file_count++;
	}
	result.set("file_count", file_count);

	if (query.len == 0) {
		Object* files_arr = object::new_obj(tmem);
		foreach (key : workspace.files.tkeys()) {
			WorkspaceFile* wf = workspace.files.get_ref(key) ?? null;
			if (wf == null) continue;
			Object* f = object::new_obj(tmem);
			f.set("uri", wf.uri);
			f.set("package", wf.package_name);
			if (wf.module_name.len > 0) {
				f.set("module", wf.module_name);
			}
			f.set("symbol_count", (int)wf.symbol_count);
			files_arr.push(f);
		}
		result.set("files", files_arr);
	} else {
		// Query mode: find symbols matching name
		Object* matches = object::new_obj(tmem);

		if (try list_ref = workspace.lookup_by_name(query)) {
			for (usz i = 0; i < list_ref.len(); i++) {
				WorkspaceSymbol* sym = workspace.get_symbol((*list_ref)[i]);
				matches.push(build_symbol_json(sym));
			}
		}

		// Also search member_cache for class members
		if (try members = workspace.lookup_members(query)) {
			Object* member_arr = object::new_obj(tmem);
			for (usz i = 0; i < members.len(); i++) {
				MemberDecl* m = &(*members)[i];
				Object* mj = object::new_obj(tmem);
				mj.set("name", m.name);
				mj.set("type", resolved_member_type_text(store, workspace, m));
				mj.set("uri", m.uri);
				mj.set("line", (int)m.line);
				mj.set("col", (int)m.col);
				mj.set("param_count", (int)m.param_count);
				member_arr.push(mj);
			}
			result.set("members", member_arr);
		}

		result.set("symbols", matches);
	}

	return result;
}

fn Object* execute_query_index(WorkspaceIndex* workspace, Object* args) {
	return execute_query_index_with_store(null, workspace, args);
}

fn Object* build_symbol_json(WorkspaceSymbol* sym) {
	Object* obj = object::new_obj(tmem);
	obj.set("name", sym.name);
	obj.set("uri", sym.uri);
	obj.set("package", sym.package_name);
	obj.set("kind", symbol_kind_label(sym.kind));
	obj.set("line", (int)sym.line);
	obj.set("col", (int)sym.col);
	obj.set("is_private", sym.is_private);
	if (sym.receiver.len > 0) {
		obj.set("receiver", sym.receiver);
	}
	if (sym.supertype_count > 0) {
		Object* supers = object::new_obj(tmem);
		for (usz i = 0; i < sym.supertype_count; i++) {
			supers.push(object::new_string(sym.supertypes[i], tmem));
		}
		obj.set("supertypes", supers);
	}
	return obj;
}

fn String symbol_kind_label(SymbolKind kind) {
	switch (kind) {
		case FUNCTION:  return "function";
		case CLASS:     return "class";
		case INTERFACE: return "interface";
		case OBJECT:    return "object";
		case PROPERTY:  return "property";
		case TYPEALIAS: return "typealias";
	}
}

// ── Debug introspection ────────────────────────────────────────────

/**
 * Build LSP-style params {textDocument:{uri}, position:{line,character}} from
 * an args array [uri, line, character]. Returns null on malformed input.
 */
fn Object*? build_position_params(Object* args) {
	if (args == null || args.get_len() < 3) return null;
	String uri = args.get_at(0).s;
	int line = args.get_int_at(1) ?? -1;
	int character = args.get_int_at(2) ?? -1;
	if (uri.len == 0 || line < 0 || character < 0) return null;

	Object* p = object::new_obj(tmem);
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	p.set("textDocument", td);
	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);
	p.set("position", pos);
	return p;
}

/**
 * Wrap any handler result inside {ok: bool, result: ...} so a null result
 * (handler returned nothing) is distinguishable from a transport error.
 */
fn Object* wrap_ok(Object* result) {
	Object* obj = object::new_obj(tmem);
	obj.set("ok", true);
	if (result == null) {
		obj.set("result", object::new_null());
	} else {
		obj.set("result", result);
	}
	return obj;
}

fn Object* wrap_err(String message) {
	Object* obj = object::new_obj(tmem);
	obj.set("ok", false);
	obj.set("error", message);
	return obj;
}

fn Object* execute_list_documents(DocumentStore* store) {
	Object* result = object::new_obj(tmem);
	Object* docs_arr = object::new_obj(tmem);
	int count = 0;
	if (store != null) {
		foreach (&doc : store.docs.tvalues()) {
			Object* d = object::new_obj(tmem);
			d.set("uri", doc.uri);
			d.set("language_id", doc.language_id);
			d.set("version", doc.version);
			d.set("byte_count", (int)doc.content.len);

			// Count newlines for line count
			int line_count = 1;
			for (usz i = 0; i < doc.content.len; i++) {
				if (doc.content[i] == '\n') line_count++;
			}
			d.set("line_count", line_count);
			d.set("has_ast", doc.cached_ast != null);
			d.set("has_types", doc.cached_types != null);
			d.set("has_tokens", doc.cached_tokens != null);
			docs_arr.push(d);
			count++;
		}
	}
	result.set("count", count);
	result.set("documents", docs_arr);
	if (store != null && store.last_edited_uri.len > 0) {
		result.set("last_edited_uri", store.last_edited_uri);
	}
	return result;
}

fn Object* execute_last_edited(DocumentStore* store) {
	Object* result = object::new_obj(tmem);
	if (store != null && store.last_edited_uri.len > 0) {
		result.set("uri", store.last_edited_uri);
	} else {
		result.set("uri", object::new_null());
	}
	return result;
}

fn Object* execute_last_cursor(DocumentStore* store) {
	Object* result = object::new_obj(tmem);
	if (store == null || store.last_cursor_uri.len == 0 ||
		store.last_cursor_line < 0 || store.last_cursor_character < 0) {
		result.set("uri", object::new_null());
		result.set("line", object::new_null());
		result.set("character", object::new_null());
		return result;
	}
	result.set("uri", store.last_cursor_uri);
	result.set("line", store.last_cursor_line);
	result.set("character", store.last_cursor_character);
	return result;
}

fn Object* execute_diagnostics_for_uri(DocumentStore* store, WorkspaceIndex* workspace, Object* args) {
	if (args == null || args.get_len() < 1) {
		return wrap_err("missing uri");
	}
	String uri = args.get_at(0).s;
	if (uri.len == 0) {
		return wrap_err("empty uri");
	}
	if (store == null) {
		return wrap_err("no document store");
	}
	if (catch excuse = store.get(uri)) {
		return wrap_err("document not open");
	}

	// Fetch parsed AST + types (lazily computed by store).
	ParseResult* ast_result = null;
	if (try a = store.get_ast(uri)) ast_result = a;
	if (ast_result == null) {
		return wrap_err("failed to parse document");
	}
	TypeInfo* type_info = null;
	if (try ti = store.get_types(uri)) type_info = ti;

	String content = "";
	if (try doc = store.get(uri)) content = doc.content;

	Object* arr = diagnostics::build_diagnostics_array(content, ast_result, workspace, type_info);
	Object* result = object::new_obj(tmem);
	result.set("uri", uri);
	result.set("diagnostics", arr);
	return result;
}

fn Object* execute_hover_at(DocumentStore* store, WorkspaceIndex* workspace, Object* args) {
	Object* p = build_position_params(args) ?? null;
	if (p == null) return wrap_err("expected [uri, line, character]");
	Object* result = null;
	if (try r = hover::handle_hover(store, workspace, p)) result = r;
	return wrap_ok(result);
}

fn Object* execute_definition_at(DocumentStore* store, WorkspaceIndex* workspace, Object* args) {
	Object* p = build_position_params(args) ?? null;
	if (p == null) return wrap_err("expected [uri, line, character]");
	Object* result = null;
	if (try r = definition::handle_definition(store, workspace, p)) result = r;
	return wrap_ok(result);
}

fn Object* execute_references_at(DocumentStore* store, WorkspaceIndex* workspace, Object* args) {
	Object* p = build_position_params(args) ?? null;
	if (p == null) return wrap_err("expected [uri, line, character]");
	// references handler reads context.includeDeclaration; default true for
	// debug ergonomics.
	Object* ctx = object::new_obj(tmem);
	ctx.set("includeDeclaration", true);
	p.set("context", ctx);
	Object* result = null;
	if (try r = references::handle_references(store, workspace, p)) result = r;
	return wrap_ok(result);
}

fn Object* execute_ast_at(DocumentStore* store, Object* args) {
	if (args == null || args.get_len() < 3) {
		return wrap_err("expected [uri, line, character]");
	}
	String uri = args.get_at(0).s;
	int line = args.get_int_at(1) ?? -1;
	int character = args.get_int_at(2) ?? -1;
	if (uri.len == 0 || line < 0 || character < 0) {
		return wrap_err("bad arguments");
	}
	if (store == null) return wrap_err("no document store");

	ParseResult* pr = null;
	if (try a = store.get_ast(uri)) pr = a;
	if (pr == null) return wrap_err("failed to parse document");

	String source = "";
	if (try doc = store.get(uri)) source = doc.content;
	long offset = hover::position_to_offset(source, (uint)line, (uint)character);
	if (offset < 0) return wrap_err("position out of range");

	// Find innermost AST node whose [start, end) span contains offset.
	// Smaller spans are preferred.
	uint best_idx = 0;
	usz best_span = (usz)-1;
	bool found = false;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if ((usz)n.start_offset <= (usz)offset && (usz)n.end_offset > (usz)offset) {
			usz span = (usz)(n.end_offset - n.start_offset);
			if (span < best_span) {
				best_span = span;
				best_idx = i;
				found = true;
			}
		}
	}

	Object* result = object::new_obj(tmem);
	result.set("uri", uri);
	result.set("line", line);
	result.set("character", character);
	result.set("offset", (int)offset);
	if (!found) {
		result.set("found", false);
		return result;
	}
	result.set("found", true);

	// Build parent chain (innermost → outermost), capped at 16.
	Object* chain = object::new_obj(tmem);
	uint cur = best_idx;
	int depth = 0;
	while (cur != 0 && depth < 16) {
		AstNode* n = &pr.nodes[cur];
		Object* node = object::new_obj(tmem);
		node.set("idx", (int)cur);
		node.set("kind", n.kind.nameof);
		node.set("name", n.name);
		node.set("start", (int)n.start_offset);
		node.set("end", (int)n.end_offset);
		node.set("name_line", (int)n.name_line);
		node.set("name_col", (int)n.name_col);
		String text = ast::type_ref_name(pr, cur, source, tmem);
		if (text.len > 0) node.set("type_text", text);
		node.set("mod_flags", (long)n.mod_flags);
		chain.push(node);
		if (n.parent == cur) break; // root
		cur = n.parent;
		depth++;
	}
	result.set("chain", chain);
	return result;
}

fn Object* execute_type_at(DocumentStore* store, Object* args) {
	if (args == null || args.get_len() < 3) {
		return wrap_err("expected [uri, line, character]");
	}
	String uri = args.get_at(0).s;
	int line = args.get_int_at(1) ?? -1;
	int character = args.get_int_at(2) ?? -1;
	if (uri.len == 0 || line < 0 || character < 0) {
		return wrap_err("bad arguments");
	}
	if (store == null) return wrap_err("no document store");

	ParseResult* pr = null;
	if (try a = store.get_ast(uri)) pr = a;
	if (pr == null) return wrap_err("failed to parse document");

	TypeInfo* ti = null;
	if (try t = store.get_types(uri)) ti = t;
	if (ti == null) return wrap_err("type info unavailable");

	String content = "";
	if (try doc = store.get(uri)) content = doc.content;
	long offset = hover::position_to_offset(content, (uint)line, (uint)character);
	if (offset < 0) return wrap_err("position out of range");

	// Find innermost typed node containing offset.
	uint best_idx = 0;
	usz best_span = (usz)-1;
	bool found = false;
	for (uint i = 1; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ti.has_type[i]) continue;
		if ((usz)n.start_offset <= (usz)offset && (usz)n.end_offset > (usz)offset) {
			usz span = (usz)(n.end_offset - n.start_offset);
			if (span < best_span) {
				best_span = span;
				best_idx = i;
				found = true;
			}
		}
	}

	Object* result = object::new_obj(tmem);
	result.set("uri", uri);
	result.set("line", line);
	result.set("character", character);
	result.set("offset", (int)offset);
	if (!found) {
		result.set("found", false);
		return result;
	}
	AstNode* n = &pr.nodes[best_idx];
	String formatted = types::format_type(&ti.node_types[best_idx]);
	result.set("found", true);
	result.set("idx", (int)best_idx);
	result.set("kind", n.kind.nameof);
	result.set("name", n.name);
	result.set("start", (int)n.start_offset);
	result.set("end", (int)n.end_offset);
	result.set("type", formatted);
	result.set("is_class_ref", ti.node_types[best_idx].is_class_ref);
	result.set("type_kind", ti.node_types[best_idx].kind.nameof);
	return result;
}

// ── Helpers ────────────────────────────────────────────────────────

fn void run_gradle(String root, String task) {
	// Detect wrapper
	String gradle_cmd = detect_gradle_wrapper(root);

	DString msg;
	msg.tinit();
	msg.appendf("Running: %s %s", gradle_cmd, task);
	show_message(3, msg.str_view());

	run_command(root, {gradle_cmd, task, "--console=plain", "-q"});
}

fn void run_gradle_with_filter(String root, String task, String filter) {
	String gradle_cmd = detect_gradle_wrapper(root);

	DString test_arg;
	test_arg.tinit();
	test_arg.appendf("--tests=%s", filter);

	DString msg;
	msg.tinit();
	msg.appendf("Running: %s %s %s", gradle_cmd, task, test_arg.str_view());
	show_message(3, msg.str_view());

	run_command(root, {gradle_cmd, task, test_arg.str_view(), "--console=plain"});
}

fn String detect_gradle_wrapper(String root) {
	// Check for gradlew in workspace root
	DString wrapper_path;
	wrapper_path.tinit();
	wrapper_path.appendf("%s/gradlew", root);

	if (file::is_file(wrapper_path.str_view())) {
		return "./gradlew";
	}
	return "gradle";
}

fn void run_standalone_main(String root, String uri) {
	// Convert URI to relative path for kotlinc
	String file_path = workspace::uri_to_path(uri);
	if (file_path.len == 0) {
		show_message(1, "Cannot determine file path");
		return;
	}

	show_message(3, "Compiling and running with kotlinc...");

	// kotlinc file.kt -include-runtime -d /tmp/kls_run.jar && kotlin -jar /tmp/kls_run.jar
	DString jar_path;
	jar_path.tinit();
	// Use hash of file path for unique JAR name (avoid collisions from same-length paths)
	uint path_hash = 5381;
	foreach (c : file_path) {
		path_hash = path_hash * 33 + (uint)c;
	}
	jar_path.appendf("/tmp/kls_run_%x.jar", path_hash);

	run_command(root, {"kotlinc", file_path, "-include-runtime", "-d", jar_path.str_view()});

	// If compile succeeded, run it
	run_command(root, {"kotlin", "-jar", jar_path.str_view()});
}

fn void run_command(String workdir, String[] argv) {
	if (argv.len == 0) return;

	progress::create("kls-exec");
	progress::begin("kls-exec", "Running...", 0);

	// chdir to workspace root (C3 process spawn has no workdir option)
	Path old_cwd;
	if (try cwd = path::tcwd()) {
		old_cwd = cwd;
	} else {
		show_message(1, "Failed to get current directory");
		progress::end("kls-exec", "Failed");
		return;
	}

	if (catch excuse = path::chdir(workdir)) {
		DString msg;
		msg.tinit();
		msg.appendf("Failed to chdir to %s: %s", workdir, excuse);
		show_message(1, msg.str_view());
		progress::end("kls-exec", "Failed");
		return;
	}

	Process proc;
	if (try p = process::spawn(argv, SpawnOptions.ASYNC_OUTPUT | SpawnOptions.INHERIT_ENV)) {
		proc = p;
	} else {
		(void)path::chdir(old_cwd);
		show_message(1, "Failed to start process");
		progress::end("kls-exec", "Failed");
		return;
	}

	// Restore working directory immediately after spawn
	path::chdir(old_cwd)!!;

	// Drain stdout and stderr while process runs
	DString output;
	output.tinit();
	DString err_output;
	err_output.tinit();
	char[4096] out_buf;
	char[4096] err_buf;

	while (true) {
		bool running = proc.is_running() ?? false;

		bool got_data = true;
		while (got_data) {
			got_data = false;

			sz n_out = proc.read_stdout(&out_buf, out_buf.len) ?? 0;
			if (n_out > 0) {
				got_data = true;
				output.appendf("%s", (String)out_buf[:(usz)n_out]);
			}

			sz n_err = proc.read_stderr(&err_buf, err_buf.len) ?? 0;
			if (n_err > 0) {
				got_data = true;
				err_output.appendf("%s", (String)err_buf[:(usz)n_err]);
			}
		}

		if (!running) break;
		thread::sleep_ms(50);
	}

	// Final drain
	bool got_final = true;
	while (got_final) {
		got_final = false;
		sz n_out = proc.read_stdout(&out_buf, out_buf.len) ?? 0;
		if (n_out > 0) {
			got_final = true;
			output.appendf("%s", (String)out_buf[:(usz)n_out]);
		}
		sz n_err = proc.read_stderr(&err_buf, err_buf.len) ?? 0;
		if (n_err > 0) {
			got_final = true;
			err_output.appendf("%s", (String)err_buf[:(usz)n_err]);
		}
	}

	(void)proc.destroy();

	// Report results — check stderr for errors
	bool has_errors = err_output.str_view().len > 0;
	if (!has_errors) {
		if (output.str_view().len > 0) {
			show_message(3, output.str_view());
		} else {
			show_message(3, "Command completed successfully");
		}
		progress::end("kls-exec", "Done");
		log::info("[kls] Command succeeded (exit 0)");
	} else {
		DString msg;
		msg.tinit();
		msg.appendf("Command produced errors");
		msg.appendf("\n%s", err_output.str_view());
		if (output.str_view().len > 0) {
			msg.appendf("\n%s", output.str_view());
		}
		show_message(1, msg.str_view());
		progress::end("kls-exec", "Failed");
		log::err("[kls] Command failed");
	}
}

/**
 * Send window/showMessage notification.
 * type: 1=Error, 2=Warning, 3=Info, 4=Log
 */
fn void show_message(int type, String message) {
	Object* params = object::new_obj(tmem);
	params.set("type", type);
	params.set("message", message);
	json_rpc::send_notification("window/showMessage", params);
}

/**
 * Find the Gradle module name for a given file URI.
 */
fn String find_module_for_uri(WorkspaceIndex* workspace, String uri) {
	if (try file_entry = workspace.files.get(uri)) {
		return file_entry.module_name;
	}
	return "";
}

/**
 * Find the package name for a given file URI.
 */
fn String find_package_for_uri(WorkspaceIndex* workspace, String uri) {
	if (try file_entry = workspace.files.get(uri)) {
		return file_entry.package_name;
	}
	return "";
}
