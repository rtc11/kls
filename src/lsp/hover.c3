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
import kls::workspace;
import kls::deps::jar_index;

faultdef NO_TOKEN, NO_DESCRIPTION;

/**
 * Handle textDocument/hover request.
 * Returns a Hover JSON object, or null if there is nothing to show.
 * Falls back to workspace index for cross-file identifiers.
 */
fn Object* handle_hover(DocumentStore* store, WorkspaceIndex* workspace, Object* params) {
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri")!!;

	Object* pos = params.get("position")!!;
	uint line = (uint)pos.get_int("line")!!;
	uint character = (uint)pos.get_int("character")!!;

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
		if (pr != null) {
			if (try desc = describe_identifier_from_ast(pr, tok)) {
				description = desc;
				found_description = true;
			}
		}
		// Cross-file fallback: look up in workspace index
		if (!found_description && workspace != null) {
			if (try desc = describe_identifier_from_workspace(workspace, store, tok, uri)) {
				description = desc;
				found_description = true;
			}
		}
		// Dependency fallback: look up in indexed JARs
		if (!found_description && workspace != null && workspace.dep_index.initialized) {
			if (try desc = describe_identifier_from_deps(&workspace.dep_index, tok)) {
				description = desc;
				found_description = true;
			}
		}
		// Stdlib fallback: look up in bundled kotlin-stdlib index
		if (!found_description) {
			if (try desc = describe_identifier_from_stdlib(tok)) {
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
 * Try to find a declaration matching the identifier token in the AST
 * and return a rich signature description.
 */
fn String? describe_identifier_from_ast(ParseResult* pr, Token tok) {
	if (pr.node_count == 0) return NO_DESCRIPTION~;

	// Search all declarations for one matching this identifier name
	String target = tok.text;
	AstNode* best = null;

	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != target) continue;

		// Prefer the first match
		if (best == null) {
			best = n;
		}
	}

	if (best == null) return NO_DESCRIPTION~;

	return build_signature(best, pr);
}

/**
 * Build a markdown signature string from an AST declaration node.
 */
fn String build_signature(AstNode* node, ParseResult* pr) {
	DString ds;
	ds.tinit();

	ds.appendf("```kotlin\n");

	// Modifiers
	append_modifiers(&ds, node.mod_flags);

	// Declaration keyword + name
	switch (node.kind) {
		case FUN_DECL:
			ds.appendf("fun %s", node.name);
			// Append parameters
			ds.appendf("(");
			bool first = true;
			for (usz i = 0; i < pr.node_count; i++) {
				AstNode* child = &pr.nodes[i];
				usz node_idx = ast::node_index(pr, node);
				if (child.parent != node_idx) continue;
				if (child.kind != PARAM) continue;

				if (!first) {
					ds.appendf(", ");
				}
				first = false;
				ds.appendf("%s", child.name);
				if (child.type_text.len > 0) {
					ds.appendf(": %s", child.type_text);
				}
			}
			ds.appendf(")");
			if (node.type_text.len > 0) {
				ds.appendf(": %s", node.type_text);
			}

		case CLASS_DECL:
			ds.appendf("class %s", node.name);

		case INTERFACE_DECL:
			ds.appendf("interface %s", node.name);

		case OBJECT_DECL:
			ds.appendf("object %s", node.name);

		case COMPANION_OBJECT_DECL:
			ds.appendf("companion object %s", node.name);

		case PROPERTY_DECL:
			// #13: Show val vs var based on MOD_VAR flag
			String prop_keyword = (node.mod_flags & ast::MOD_VAR) != 0 ? "var" : "val";
			ds.appendf("%s %s", prop_keyword, node.name);
			if (node.type_text.len > 0) {
				ds.appendf(": %s", node.type_text);
			}

		case TYPEALIAS_DECL:
			ds.appendf("typealias %s", node.name);
			if (node.type_text.len > 0) {
				ds.appendf(" = %s", node.type_text);
			}

		case CONSTRUCTOR_DECL:
			ds.appendf("constructor(");
			bool first = true;
			for (usz i = 0; i < pr.node_count; i++) {
				AstNode* child = &pr.nodes[i];
				usz node_idx = ast::node_index(pr, node);
				if (child.parent != node_idx) continue;
				if (child.kind != PARAM) continue;

				if (!first) {
					ds.appendf(", ");
				}
				first = false;
				ds.appendf("%s", child.name);
				if (child.type_text.len > 0) {
					ds.appendf(": %s", child.type_text);
				}
			}
			ds.appendf(")");

		case INIT_BLOCK:
			ds.appendf("init { ... }");

		case ENUM_ENTRY:
			ds.appendf("%s", node.name);

		default:
			ds.appendf("%s", node.name);
	}

	ds.appendf("\n```");

	return ds.str_view();
}

/**
 * Append modifier keywords to a DString based on mod_flags.
 */
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

/**
 * Convert an LSP position (line, character) to a byte offset in the source.
 * Returns the byte offset, or -1 if the position is past the end.
 */
fn long position_to_offset(String content, uint line, uint character) {
	uint current_line = 0;
	usz i = 0;

	// Skip to the target line
	while (i < content.len && current_line < line) {
		if (content[i] == '\n') {
			current_line++;
		}
		i++;
	}

	if (current_line < line) {
		return -1; // Line is past end of content
	}

	// Add character offset
	usz offset = i + (usz)character;
	if (offset > content.len) {
		return -1;
	}

	return (long)offset;
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
		// Find best match (skip same-file symbols)
		WorkspaceSymbol* best = null;
		for (usz i = 0; i < indices.len(); i++) {
			WorkspaceSymbol* sym = workspace.get_symbol(indices.get(i));
			if (sym.name.len == 0) continue;
			if (sym.uri == current_uri) continue;
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
	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != sym.name) continue;
		if (n.name_line == sym.line && n.name_col == sym.col) {
			return build_signature(n, pr);
		}
	}

	// If exact position match failed, try first name match
	for (usz i = 0; i < pr.node_count; i++) {
		AstNode* n = &pr.nodes[i];
		if (!ast::is_declaration(n.kind)) continue;
		if (n.name != sym.name) continue;
		return build_signature(n, pr);
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
	}

	return ds.str_view();
}
