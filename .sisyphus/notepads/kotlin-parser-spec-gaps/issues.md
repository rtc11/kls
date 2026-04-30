# Issues — kotlin-parser-spec-gaps

## [W1] Parallel subagents → race condition on shared files
- T1, T2, T3, T4 all ran parallel and modified `src/kotlin/lexer.c3` and `src/kotlin/token.c3`
- Each subagent rebased the file with their own changes, OVERWRITING others
- Final state: lexer.c3 has all 4 changes (committed via T1/T2 commits), but token.c3 needed manual followup commit
- T2 + T4 falsely reported "pre-existing failures" — was actually their parallel sibling's edits not yet visible
- LSP `c3c test test/<file>.c3` syntax not supported in this build target — only full `c3c test` works
- LSP diagnostics for .c3 not configured (no LSP server in environment) — fall back to `c3c test`

**Lesson for W2-W4**: Files touched by multiple parallel tasks → either serialize OR ensure each subagent touches DISJOINT files only. T9-T11 ALL touch `src/kotlin/parser.c3` → MUST serialize across waves and possibly within waves.

## Build/test commands that work
- `c3c test` — full suite, exit code 0 = pass
- `c3c build` — full build
- File-level test filtering NOT supported via `c3c test test/<file>.c3`


- `c3c test test/lexer_test.c3` not supported here; runner said no build target named `test/lexer_test.c3`.
- `lsp_diagnostics` unavailable for `.c3` in current tool setup; no C3 LSP server configured.
## T3 DOC_COMMENT lexer note
- KDoc detection uses lexical shape only: `/**` with next char neither `*` nor `/`.
- Empty `/**/` stays `BLOCK_COMMENT`.
- Trivia mode now emits `DOC_COMMENT`; normal mode still skips it.

## T2 shebang lexer note
- Shebang skip now lives at lexer BOF guard and runs before both `next()` and `next_all()` paths.
- Skip consumes `#!...` through newline or EOF; mid-file `#!` still lexes as `HASH` + following tokens.
- `c3c test` still reports unrelated pre-existing failures in comment/semantic-token/folding tests, but shebang tests pass.
## 2026-04-28
- T4 lexer work verified `...` tokenization in targeted lexer tests. Full `c3c test` still failed on pre-existing unrelated suite failures in `lexer_next_all_test.c3`, `folding_range_test.c3`, and `semantic_tokens_test.c3` from dirty worktree changes outside T4 scope.

## 2026-04-28 — T6
- `lsp_diagnostics` unavailable for `.c3` in this environment; used `c3c test` instead.


## 2026-04-28 — T11 partial defer (T11b follow-up)
- Landed partial TYPE_REF dual-storage in `src/kotlin/parser.c3` with green full suite.
- Working coverage now: simple param type refs, generic return type refs, intersection type refs, variance/use-site type arg refs.
- Deferred cases for follow-up task T11b:
  - nullable function-type TYPE_REF child shape (`((Int) -> String)?`)
  - suspend function-type TYPE_REF child shape + suspend marker assertions (`suspend (A, B) -> C?`)
  - deeply nested generic TYPE_REF traversal (`Map<String, List<Pair<Int, Boolean>>>`)
- Chosen because partial parser infra is stable and `c3c test` returns 0 after deferring those assertions; forcing remaining shapes now risked shipping broken parser/tests.

## 2026-04-30 — T11b CLOSED
- All 3 deferred cases verified via probe + landed assertions in `test/parser_test.c3`.
- Parser already produced correct AST shapes; only tests were missing. No parser changes needed.
- Findings:
  - `((Int) -> String)?`: TYPE_REF with `extra='function nullable'`, 2 children (param `Int`, return `String`).
  - `suspend (A, B) -> C?`: TYPE_REF with `extra='function'` + `mod_flags & MOD_SUSPEND`, 3 children (params A/B, return `C` w/ `extra='return nullable'`).
  - `Map<String, List<Pair<Int, Boolean>>>`: nested TYPE_REFs all carry per-level `type_text` and `extra='arg'`.
- Tests: `type_ref_nullable_function_type_dual_storage`, `type_ref_suspend_function_type_dual_storage`, `type_ref_deeply_nested_generic_dual_storage`.
- Full `c3c test`: 2782 PASS, 0 FAIL.

## F2 Code Quality Review (HEAD 20c44a5)
- parser.c3:4570 `skip_param_default` — DEAD (T9 replaced w/ parse_expression + adopt_children)
- parser.c3:4772 `skip_delegation_expression` — DEAD (T10 replaced w/ parse_expression + adopt_children)
- parser.c3:4444-4448 `skip_type_ref` — stray `}` at 4446 closes if-block early; intersection block now sits at fn-body level (compiles, behavior preserved due to early-returns above, but bad indentation/style after T11 conflict markers cleanup)
- ast.c3:122 `MOD_FUN_INTERFACE = MOD_REIFIED` — bit-aliasing tech debt. Currently safe (REIFIED only consumed on TYPE_PARAM, MOD_FUN_INTERFACE only set on INTERFACE_DECL). Future risk if either bit-check broadens.
- lexer.c3:710-718 `lex_operator` switch — extra leading tab on `switch` + `case '.':` block from T1 RESERVED `...` insertion. Cosmetic.
- parser.c3:4690 `uint accessor_mods = ast::MOD_NONE;` — extra leading tab from T6 in_accessor_body diff context.

## 2026-04-30 — F2 CLOSED
- Item 3 (MOD_FUN_INTERFACE alias): widened `mod_flags` from `uint` to `ulong`. MOD_FUN_INTERFACE now `1ul << 32`, no longer aliased to MOD_REIFIED. Cascaded to parse_modifiers, append_modifiers, lookup_class_mod_flags, WorkspaceMember, class_mod_flags HashMap. Commit `37dfa91` (bundled w/ unrelated parallel-agent LSP/deps work in worktree).
- Item 1 (dead helpers): deleted `skip_param_default` and `skip_delegation_expression` from parser.c3.
- Item 2 (stray `}`): fixed in `skip_type_ref` function-type-with-receiver branch.
- Item 4 (cosmetic indent):
  - `accessor_mods` stray leading tab → fixed.
  - `lex_operator` switch indentation → DEFERRED. Entangled with pre-existing inconsistent `case` indentation throughout the function (some cases at switch-level, some at switch+1). Cosmetic-only, no functional benefit, high risk of formatter cascade. Documented decision in commit message.
- Items 1+2+4-accessor in commit `456952b`.
- Full `c3c test`: 2782 PASS, 0 FAIL after both commits.
