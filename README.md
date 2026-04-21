# kls

A Language Server Protocol (LSP 3.17) implementation for Kotlin, written in [C3](https://c3-lang.org/).

## Build & Run

```bash
c3c build       # build -> build/kls
c3c run         # build and run
c3c test        # run tests
```

The server communicates over stdin/stdout using the LSP base protocol.

## LSP Features

- **Diagnostics** — lexer + parser errors, unused imports/locals, deprecated usage
- **Hover** — keywords, AST signatures, dependency Javadoc/KDoc
- **Completion** — keywords, identifiers, cross-file, stdlib, dependencies
- **Go to Definition** — scope-aware, cross-file, dependency source navigation
- **Find References** — lexer-based with AST filtering, cross-file
- **Document Symbols** — hierarchical outline
- **Semantic Tokens** — full, delta, range (AST-enhanced)
- **Code Actions** — quickfixes, organize imports, refactoring
- **Rename** — cross-file via workspace index
- **Formatting** — document, range, on-type (whitespace, indent, blank lines)
- **Signature Help** — active parameter index
- **Inlay Hints** — parameter names at call sites, type hints for val/var
- **Selection Range** — AST-based expand/shrink
- **Folding Range** — AST nodes, import groups, block comments
- **Code Lens** — Run main, Run Test on @Test
- **Type Definition** — jump to type of symbol
- **Declaration** — supertype method navigation for overrides
- **Implementation** — find implementors (in-file, workspace, dependencies)
- **Type Hierarchy** — supertypes and subtypes
- **Call Hierarchy** — incoming and outgoing calls
- **Document Highlight** — read/write classification
- **Document Link** — URLs in comments, import paths to workspace files
- **Linked Editing Range** — rename-as-you-type for identifiers
- **Workspace Symbols** — fuzzy query across workspace
- **Execute Command** — run main, run test via Gradle/Maven/kotlinc
- **Progress** — work done progress reporting

## Debug Adapter Protocol (DAP)

kls also functions as a DAP debug adapter for Kotlin. Run with the `--dap` flag:

```bash
c3c run -- --dap
```

- Launch and attach to JVM processes (JDWP)
- Breakpoints (line, exception)
- Step execution (continue, next, stepIn, stepOut, pause)
- Stack traces with source path resolution
- Variable inspection (scopes, locals)
- Expression evaluation
- Thread listing

## License

MIT
