# Learnings — semantic-subast-migration

## Inherited from kotlin-parser-spec-gaps

### C3 Conventions (from AGENTS.md)
- snake_case fns/vars; PascalCase types; SCREAMING for constants/enums/faults
- Tabs for indent
- Module header: `module kls::submodule;` first line
- Faults: `faultdef NAME1, NAME2;` flat list; return with `~` suffix
- Memory: `mem`/`tmem` builtins; `@pool() { ... };` for request scopes
- Optionals: `!` rethrow, `!!` panic, `??` default, `if (try x = ...)`, `if (catch e = ...)`
- Slice: `[start..end]` inclusive both, `[start:length]` start+count

### Build/Test
- `c3c build` — full build
- `c3c test` — full suite (~2782 tests baseline post prior plan)
- `c3c test test/<file>.c3` NOT SUPPORTED (per issues.md [W1]) — always full
- `lsp_diagnostics` for `.c3` NOT available in this env — use `c3c test`

### Producer AST shape (from prior T7/T9/T10/T11 commits)
- TYPE_REF: text in `type_text` field; sub-AST children for params/return/generics. extra_text markers: `arg`, `function`, `function nullable`, `return nullable`, `delegate`
- ANNOTATION_ENTRY: text in `annotation_text`; VALUE_ARGUMENT children w/ full expr trees
- PARAM: default text in `extra_text`; child expression node from `parse_expression(PREC_NONE)`
- Supertype delegate: TYPE_REF child = delegate expression, extra_text="delegate" on the TYPE_REF

### DUAL-STORAGE INVARIANT (carried — CRITICAL)
- `type_text` (241 readers / 20 files) — populated byte-identical
- `annotation_text` (77 readers / 10 files) — populated byte-identical
- `extra_text` (13 readers / 4 files) — only PARAM-default + supertype-delegate uses are in scope
- Other extra_text uses (operator strings on PREFIX/POSTFIX/BINARY/ASSIGNMENT_EXPR; `*` spread on VALUE_ARGUMENT; `trailing` marker; TYPE_REF kind markers `arg`/`function`/etc) — STAY ON TEXT, no sub-AST replacement

### Key file refs
- `src/kotlin/ast.c3:140-160` — node field defs
- `src/kotlin/ast.c3:324-456` — existing helpers (`has_annotation`, `is_spread`, etc.)
- `src/kotlin/ast.c3:368` — existing `type_text` accessor
- `src/kotlin/ast.c3:324-330` — existing `has_annotation` (text-based)

### Parallel-agent gotcha (from issues.md W1 of prior plan)
- DO NOT dispatch parallel agents to the SAME file within a wave — they collide
- When two tasks both touch one file → SERIALIZE within wave
## 2026-04-30 W0 — inventory + snapshot guard
- Inventory counts from W0 scan: `type_text` 283 readers across 18 files; `annotation_text` 40 readers across 5 files; `extra_text` 197 readers across 14 files. This does NOT match plan's stated 241/77/13; inventory includes many out-of-scope marker reads on `extra_text`, and fewer `annotation_text` reads than plan claimed.
- Top 5 hottest files by field:
  - `type_text`: `test/parser_test.c3` 69, `src/kotlin/types.c3` 45, `src/lsp/completion.c3` 30, `src/workspace.c3` 28, `src/lsp/diagnostics.c3` 20.
  - `annotation_text`: `test/parser_test.c3` 35, `src/kotlin/ast.c3` 2, `src/lsp/hover.c3` 1, `src/lsp/semantic_tokens.c3` 1, `test/script_parser_test.c3` 1.
  - `extra_text`: `test/parser_test.c3` 81, `src/lsp/diagnostics.c3` 40, `src/lsp/code_actions.c3` 32, `src/kotlin/types.c3` 12, `src/kotlin/flow.c3` 10.
- Surprising pattern: many `.type_text` / `.extra_text` reads in tests and producer-adjacent helper code dominate raw counts; `annotation_text` current live consumers appear concentrated almost entirely in parser tests plus `ast::has_annotation`.
- Snapshot guard added in `test/dual_storage_snapshot_test.c3`; smoke proof confirmed guard trips on intentional renderer drift (`TYPE_REF 5 mismatch: 'T' vs 'BROKEN'`).

