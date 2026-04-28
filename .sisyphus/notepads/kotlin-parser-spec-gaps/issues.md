# Issues — kotlin-parser-spec-gaps

(empty — append issues encountered during execution)

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
