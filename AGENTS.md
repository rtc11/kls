# KLS - Kotlin Language Server

A Language Server Protocol (LSP 3.17) implementation for Kotlin, written in C3 (0.8.0 prerelease).

## Build & Run

```bash
# Build (c3c must be in PATH or use full path)
c3c build

# Build and run
c3c run

# Run tests
c3c test
```

The binary is output to `build/kls`. The server communicates over **stdin/stdout** using the LSP base protocol (Content-Length headers + JSON-RPC 2.0).

## Project Structure

```
kls/
  project.json                # C3 project configuration
  src/
    main.c3                   # kls - Entry point, creates and runs the server
    server.c3                 # kls::server - main read/dispatch loop (all LSP methods)
    json_rpc.c3               # kls::json_rpc - JSON-RPC 2.0 message framing
    document.c3               # kls::document - open document store (uri -> content) with lazy AST cache
    lsp/
      types.c3                # kls::lsp::types - Position, Range, Location, Diagnostic, etc.
      lifecycle.c3            # kls::lsp::lifecycle - initialize, shutdown handlers
      sync.c3                 # kls::lsp::sync - didOpen, didChange, didClose (triggers diagnostics)
      capabilities.c3         # kls::lsp::capabilities - server capability declarations
      diagnostics.c3          # kls::lsp::diagnostics - publishDiagnostics (lexer + parser errors)
      hover.c3                # kls::lsp::hover - textDocument/hover (keywords, AST signatures)
      completion.c3           # kls::lsp::completion - textDocument/completion (keywords, identifiers)
      definition.c3           # kls::lsp::definition - textDocument/definition (scope-aware lookup)
      references.c3           # kls::lsp::references - textDocument/references (lexer-based with AST filtering)
      document_symbols.c3     # kls::lsp::document_symbols - textDocument/documentSymbol (hierarchical)
      semantic_tokens.c3      # kls::lsp::semantic_tokens - textDocument/semanticTokens/full
      code_actions.c3         # kls::lsp::code_actions - textDocument/codeAction (quickfixes, organize imports)
    kotlin/
      token.c3                # kls::kotlin::token - Token enum, Token/TokenSpan structs
      lexer.c3                # kls::kotlin::lexer - Kotlin source tokenizer (next + next_all modes)
      ast.c3                  # kls::kotlin::ast - AST node types, ParseResult, tree queries
      parser.c3               # kls::kotlin::parser - Recursive-descent parser (flat AST with parents)
      symbols.c3              # kls::kotlin::symbols - Lightweight declaration symbol scanner
  test/
    lexer_test.c3             # Lexer tokenization tests
    lexer_next_all_test.c3    # Lexer next_all (whitespace/comments) tests
    parser_test.c3            # Parser declaration tests
    document_test.c3          # Document store tests
    diagnostics_test.c3       # Diagnostics publishing tests
    hover_test.c3             # Hover response tests
    completion_test.c3        # Completion response tests
    definition_test.c3        # Go-to-definition tests
    references_test.c3        # Find references tests
    document_symbols_test.c3  # Document symbols tests
    semantic_tokens_test.c3   # Semantic tokens tests
    code_actions_test.c3      # Code actions tests
    symbols_test.c3           # Symbol scanner tests
  lib/                        # C3 library dependencies (.c3l)
  docs/                       # Documentation
  build/                      # Build output (gitignored)
```

## C3 Coding Conventions

These conventions are **enforced by the compiler**:

| Category               | Rule                          | Example                     |
|------------------------|-------------------------------|-----------------------------|
| Types (struct/enum)    | Start uppercase, has lowercase| `Position`, `TokenKind`     |
| Variables/params/fields| Start lowercase               | `line`, `content_length`    |
| Functions/macros       | Start lowercase               | `read_message`, `dispatch`  |
| Global constants       | Start uppercase               | `MAX_HEADER_SIZE`           |
| Enum values / Faults   | Start uppercase (SCREAMING)   | `PARSE_ERROR`, `CLASS`      |
| Modules                | Lowercase + digits + `_`      | `kls::lsp::types`           |

### Style (matching stdlib):
- **snake_case** for functions, variables, parameters, struct fields
- **PascalCase** for types (structs, enums, typedefs, interfaces)
- **SCREAMING_SNAKE_CASE** for constants, enum values, faults
- Indentation: **tabs** for indent, spaces for alignment
- Brace style: Allman or K&R (be consistent within a file)

## C3 Patterns Used in This Project

### Error Handling (Optionals)

A function that can fail returns `Type?` (an Optional). The caller must decide
how to handle the potential fault. There are five ways to unwrap an Optional:

#### `!` -- rethrow (propagate fault to caller)
Only valid inside a function that itself returns `?`. Unwraps on success,
re-returns the fault on failure.
```c3
fn String? read_message() {
	String line = io::treadline(stdin)!;          // if treadline fails, read_message fails
	content_length = num_str.to_int()!;           // same -- propagates the fault upward
	return (String)buf[:(usz)content_length];
}
```

#### `!!` -- force unwrap (panic on fault)
Works anywhere, including `void` functions. Unwraps on success, **panics** on
failure. Use when failure is a programming error or truly unrecoverable.
```c3
fn void handle_did_open(DocumentStore* store, Object* params) {
	Object* td = params.get("textDocument")!!;    // panic if missing -- protocol violation
	String uri = td.get_string("uri")!!;
	io::fprintf(stdout, "Content-Length: %d\r\n\r\n", body_str.len)!!;  // panic on I/O failure
}
```

#### `??` -- default value on fault
Provides a fallback when the Optional fails. The right side can be a value or
a block that evaluates to a value.
```c3
Document* doc = store.get(uri) ?? null;                       // null if not found
JsonRpcMessage msg = parse_message(data) ?? { .id = 0 };     // struct default on error
```

#### `if (try x = expr)` -- conditional unwrap (success branch)
Binds the unwrapped value only when the Optional succeeds. The variable is
scoped to the `if` body. Use when the value is optional and absence is normal.
```c3
if (try id_val = msg.get_int("id")) {     // request has an id
	request_id = id_val;
	is_request = true;
}

if (try t = find_token_at_position(doc.content, line, character)) {
	tok = t;
} else {
	return null;    // no token at cursor -- not an error, just nothing to show
}
```

#### `if (catch excuse = expr)` -- conditional unwrap (failure branch)
Enters the branch when the Optional fails, binding the fault value.
```c3
if (catch excuse = parse_message(data)) {
	log_error(excuse);
	return;
}
// parse succeeded -- msg is usable here
```

#### Key rules
- **`!` vs `!!`**: Single `!` rethrows and only compiles inside `fn Type? ...` functions. Double `!!` panics and works everywhere. Using `!` in a non-Optional function is a **compile error**.
- **Returning faults**: Use the `~` suffix: `return UNEXPECTED_EOF~;` (see Faults below).
- **`if (try ...)`** is the idiomatic pattern when absence is a normal case (checking optional JSON fields, looking up documents, finding tokens at a position).
- **`!!`** is the idiomatic pattern for protocol-required fields and I/O operations that should never fail during normal operation.

### Faults
```c3
// faultdef is a flat list, NOT a grouped fault block
faultdef PARSE_ERROR, INVALID_HEADER, UNEXPECTED_EOF;
faultdef METHOD_NOT_FOUND, INVALID_PARAMS;

// Return faults with ~ suffix
return UNEXPECTED_EOF~;
```

### Memory Management
- **`mem`** is a `@builtin` heap allocator alias (always available, no import needed)
- **`tmem`** is a `@builtin` temp allocator alias (always available, no import needed)
- Use **temp allocator** (`@pool`, `tmem`, `tinit`, `tcopy`) for request-scoped work
- Use **heap** (`mem`, `mem::new`) for long-lived state (document store)
- Wrap each request handler in `@pool() { ... };`
- `HashMap.init(mem)` for heap-allocated maps, `HashMap.tinit()` for temp maps
- `String.copy(mem)` for heap string copy, `String.tcopy()` for temp copy

### Module Organization
- Every `.c3` file starts with `module kls::submodule;`
- Import with `import std::io;`, `import kls::lsp::types;`
- Sibling modules (same parent) are implicitly imported
- `std::core` is always implicitly imported

### Struct Methods
```c3
fn void Server.run(Server* self) { ... }
// Called as: server.run();
```

### JSON Handling
- Parse: `std::encoding::json::tparse_string(str)` returns `Object*?`
- Navigate: `obj.get("field")`, `obj.get_string("field")`, `obj.get_int("field")`
- Build: `Object` tree with `object::new_obj()`, `object::new_string()`, etc.
- Serialize: `DString.appendf("%s", obj)` to serialize an Object to JSON, NOT `json::marshal_to` (which requires structs)

### IO Streams
- `std::io::stdin()` / `std::io::stdout()` for LSP stdio transport
- Socket implements `InStream` + `OutStream` if TCP transport is added later
- `io::treadline()` for reading header lines
- `io::fprintf()` for writing formatted output

### Slice/Range Syntax
- `[start..end]` -- **INCLUSIVE** on both sides: `arr[0..2]` = 3 elements
- `[start:length]` -- start + count: `arr[0:3]` = 3 elements
- `[..end]` = from 0 to end inclusive; `[start..]` = from start to last
- `[:length]` = first N elements
- PITFALL: `buf[..buf.len]` is OUT OF BOUNDS (inclusive end). Use `buf[:buf.len]` or `(String)buf`

## LSP Protocol Notes

### Base Protocol (Content-Length framing)
```
Content-Length: <byte-count>\r\n
\r\n
<JSON-RPC body>
```

### Lifecycle
1. Client sends `initialize` request -> server responds with capabilities
2. Client sends `initialized` notification
3. Normal operation (requests/notifications)
4. Client sends `shutdown` request -> server responds
5. Client sends `exit` notification -> server exits

### Implemented Features
1. **Lifecycle**: initialize / shutdown / exit
2. **Document sync**: didOpen / didChange / didClose (full sync)
3. **Diagnostics**: publishDiagnostics (lexer + parser errors)
4. **Hover**: textDocument/hover (keywords, AST-based signatures)
5. **Completion**: textDocument/completion (keywords, identifiers)
6. **Go to definition**: textDocument/definition (scope-aware with global fallback)
7. **Find references**: textDocument/references (lexer-based with AST declaration filtering)
8. **Document symbols**: textDocument/documentSymbol (hierarchical)
9. **Semantic tokens**: textDocument/semanticTokens/full (AST-enhanced)
10. **Code actions**: textDocument/codeAction (quickfixes, organize imports)

## Kotlin Grammar Reference

The Kotlin spec version targeted is **1.9**. Key constructs the parser must handle:
- Package declarations and imports
- Class/interface/object/enum/annotation/data class/sealed class/value class declarations
- Function declarations (fun), property declarations (val/var)
- Primary/secondary constructors, init blocks
- Generics with variance (in/out), reified type parameters
- Nullable types (?), safe calls (?.), elvis (?:), not-null assertion (!!)
- when expressions, if/else, for/while/do-while
- Lambda literals, anonymous functions, trailing lambdas
- String templates ($var, ${expr})
- Coroutines (suspend), extension functions/properties
- Operator overloading, infix functions, destructuring
- Annotations (@), type aliases (typealias)
- Hard keywords: package, import, class, interface, fun, object, val, var, typealias, constructor, by, companion, init, this, super, typeof, where, if, else, when, try, catch, finally, for, do, while, throw, return, continue, break, as, is, in, out, dynamic
- Soft keywords: abstract, annotation, by, catch, companion, constructor, crossinline, data, dynamic, enum, external, final, finally, get, import, infix, init, inline, inner, internal, lateinit, noinline, open, operator, out, override, private, protected, public, reified, sealed, suspend, tailrec, vararg, where, set, field, property, receiver, param, setparam, delegate, file, expect, actual, const

## Key References

- C3 Language: https://c3-lang.org/
- C3 Compiler (0.8.0 pre): https://github.com/c3lang/c3c
- LSP 3.17 Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- Kotlin Spec 1.9: https://kotlinlang.org/spec/
- Kotlin Grammar: https://kotlinlang.org/spec/syntax-and-grammar.html
