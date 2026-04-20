module kls::lsp::code_lens;

import std::collections::object;
import kls::document;
import kls::kotlin::ast;

/**
 * Handle textDocument/codeLens request.
 * Returns an array of CodeLens objects:
 *   - "▶ Run" on top-level `fun main()` declarations
 *   - "▶ Run Test" on @Test-annotated functions
 *   - "▶ Run Tests" on classes containing @Test methods
 * Returns null if the document is unknown.
 */
fn Object*? handle_code_lens(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!;
	String uri = td.get_string("uri")!;

	ParseResult* pr = store.get_ast(uri) ?? null;
	if (pr == null) {
		return null;
	}

	Object* result = object::new_obj(tmem);

	if (pr.node_count == 0) {
		return result;
	}

	// Walk FILE node's direct children
	AstNode* file = &pr.nodes[0];
	for (uint i = 0; i < file.child_count; i++) {
		if (try node = ast::get_child(pr, file, i)) {
			emit_lenses(pr, node, uri, result);
		}
	}

	return result;
}

/**
 * Recursively emit CodeLens items for a node and its children.
 */
fn void emit_lenses(ParseResult* pr, AstNode* node, String uri, Object* result) {
	switch (node.kind) {
		case FUN_DECL:
			// Top-level fun main() -> "▶ Run"
			if (node.name == "main" && node.parent < pr.node_count &&
				pr.nodes[node.parent].kind == FILE) {
				result.push(build_lens(node, uri, "▶ Run", "kotlin.runMain",
					uri, "", "main"));
			}
			// @Test fun -> "▶ Run Test"
			if (node.has_annotation("Test")) {
				// Find parent class name if inside a class
				String class_name = "";
				if (node.parent < pr.node_count) {
					AstNode* parent = &pr.nodes[node.parent];
					if (parent.kind == CLASS_DECL || parent.kind == OBJECT_DECL) {
						class_name = parent.name;
					}
				}
				result.push(build_lens(node, uri, "▶ Run Test", "kotlin.runTest",
					uri, class_name, node.name));
			}

		case CLASS_DECL:
		case OBJECT_DECL:
			// Check if class contains any @Test methods -> "▶ Run Tests"
			if (class_has_test_methods(pr, node)) {
				result.push(build_lens(node, uri, "▶ Run Tests", "kotlin.runTest",
					uri, node.name, ""));
			}
			// Recurse into class children
			for (uint i = 0; i < node.child_count; i++) {
				if (try child = ast::get_child(pr, node, i)) {
					emit_lenses(pr, child, uri, result);
				}
			}

		default:
			break;
	}
}

/**
 * Check if a class/object node has any direct @Test-annotated FUN_DECL children.
 */
fn bool class_has_test_methods(ParseResult* pr, AstNode* node) {
	uint parent_idx = ast::node_index(pr, node);
	for (uint i = node.children_start; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == parent_idx &&
			pr.nodes[i].kind == FUN_DECL &&
			pr.nodes[i].has_annotation("Test")) {
			return true;
		}
	}
	return false;
}

/**
 * Build a single CodeLens JSON object.
 *
 * {
 *   "range": { "start": { "line": N, "character": 0 }, "end": { "line": N, "character": 0 } },
 *   "command": {
 *     "title": title,
 *     "command": command_id,
 *     "arguments": [uri, class_name, function_name]
 *   }
 * }
 */
fn Object* build_lens(AstNode* node, String uri, String title, String command_id,
	String arg_uri, String arg_class, String arg_func) {

	Object* start = object::new_obj(tmem);
	start.set("line", (int)node.start_line);
	start.set("character", (int)node.start_col);

	Object* end = object::new_obj(tmem);
	end.set("line", (int)node.start_line);
	end.set("character", (int)node.start_col);

	Object* range = object::new_obj(tmem);
	range.set("start", start);
	range.set("end", end);

	Object* args = object::new_obj(tmem);
	args.push(object::new_string(arg_uri, tmem));
	args.push(object::new_string(arg_class, tmem));
	args.push(object::new_string(arg_func, tmem));

	Object* command = object::new_obj(tmem);
	command.set("title", title);
	command.set("command", command_id);
	command.set("arguments", args);

	Object* lens = object::new_obj(tmem);
	lens.set("range", range);
	lens.set("command", command);
	return lens;
}

/**
 * Handle codeLens/resolve request.
 * Since we always include commands in the initial response, this simply
 * returns the code lens as-is.
 */
fn Object*? handle_code_lens_resolve(Object* code_lens) {
	return code_lens;
}
