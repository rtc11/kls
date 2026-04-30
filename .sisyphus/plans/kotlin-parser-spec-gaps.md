# Kotlin 1.9 Parser/Lexer Spec Gap Closure

## TL;DR

> **Quick Summary**: Close the gap between KLS Kotlin parser/lexer (`src/kotlin/{lexer,parser,ast,token}.c3`) and the Kotlin 1.9 syntax-and-grammar spec. Adds missing lexer features, missing parser productions, and structured sub-AST for previously text-only fields (annotation arguments, parameter defaults, supertype delegation, type references) — all using **dual-storage** (new sub-AST + existing text fields) to avoid cascading into 241 type_text readers across types.c3, flow.c3, contracts.c3, workspace.c3, and src/lsp/*.c3.
>
> **Deliverables**:
> - Lexer: `d`/`D` double suffix, shebang `#!`, `DOC_COMMENT` token, `...` RESERVED token (4 tasks)
> - Parser missing productions: `fun interface`, `field` keyword in accessors, supertype `by expr` sub-AST, intersection bound `<T : A & B>` (4 tasks)
> - Parser sub-AST (dual-storage): annotation arguments, parameter defaults, type references (3 tasks)
> - Final regression sweep + plan-compliance audit (4 review tasks)
>
> **Estimated Effort**: Large (11 implementation tasks + 4 review tasks)
> **Parallel Execution**: YES — 4 waves
> **Critical Path**: T1-T4 (lexer Wave 1, parallel) → T5-T8 (parser productions Wave 2, parallel) → T9-T10 (low-risk dual-storage Wave 3, parallel) → T11 (TYPE_REF dual-storage Wave 4, sequential, isolated) → F1-F4 (final review)

---

## Context

### Original Request
"Find the gap on what we need to implement from the kotlin spec that we are missing." Scope locked to **parser/grammar gaps only** (no semantic/type-system, no LSP-feature gaps).

### Interview Summary
**Key Discussions**:
- Scope: lexer + parser + AST grammar only — explicitly excludes types.c3, flow.c3, contracts.c3, LSP handlers, workspace, deps, DAP
- Output: implementation plan (not gap report)
- Research mode: spec-driven (Kotlin 1.9 spec sections vs current code)

**Research Findings** (3 parallel agents — librarian + 2 explore):
- Lexer: 157 token kinds, 35 hard + 35 soft keywords, 68 operators, all literal types incl underscores/L/u/U/uL/f/F suffixes, char escapes incl `\uXXXX`, regular + triple-quoted strings, `$x` and `${expr}` templates, backtick + Unicode identifiers — strong baseline
- Parser: ~85-90% Kotlin 1.9 spec coverage. All major declarations, statements, expressions present. Gaps concentrated in (a) a few missing productions, (b) text-only sub-AST that blocks downstream semantic work

### Metis Review (CRITICAL CORRECTIONS)
**Inventory errors corrected** (verified by Metis against source):
- `data object` — **ALREADY DONE** (parser.c3:642, ast.c3:90). Removed from gap list.
- Suspend function types — **ALREADY DONE** (parser.c3:4006-4012). Removed.
- Multi-bound where clauses (`where T : A, T : B`) — **ALREADY DONE** (parser.c3:1751-1769). Only intersection-bound `<T : A & B>` form remains a gap.
- `Type::class` callable refs — **ALREADY DONE**. Removed.
- Labeled lambdas — **ALREADY DONE**. Removed.
- `field` keyword — **PARTIAL** (token exists at token.c3:99, but treated as NAME_EXPR in accessor bodies). Smaller gap than originally classified.
- Property delegation `by expr` — **ALREADY PARSED into expression AST** (parser.c3:1348-1357, tagged `extra_text="delegate"`). Only **supertype delegation** (parser.c3:1736-1739 `skip_delegation_expression`) is the actual gap.

**Blast radius (HIGH severity)**:
- `type_text` has **241 readers across 20 files** including 50+ in types.c3, 30+ in diagnostics.c3, 20+ in workspace.c3, 40+ test assertions
- `annotation_text` has **77 readers across 10 files** including `ast::has_annotation()` walker
- `extra_text` (param default, delegation marker) has ~13 readers across 4 files

**Mandatory strategy**: **DUAL-STORAGE** for all sub-AST additions. New TYPE_REF / annotation arg / param default sub-nodes are added ALONGSIDE existing `type_text` / `annotation_text` / `extra_text` fields. Both stay populated. Removing the text fields is **out-of-scope** (would cascade into types.c3, flow.c3, contracts.c3, workspace.c3, src/lsp/*.c3).

---

## Work Objectives

### Core Objective
Close every confirmed Kotlin 1.9 grammar/lexer gap in `src/kotlin/` that affects parser correctness or blocks downstream sub-AST consumers, while preserving 100% backwards compatibility with existing 241 `type_text` / 77 `annotation_text` / 13 `extra_text` consumers.

### Concrete Deliverables
- `src/kotlin/lexer.c3` — `d`/`D` suffix recognition, shebang `#!` skip-at-file-start, `DOC_COMMENT` token emission, `...` RESERVED token recognition
- `src/kotlin/token.c3` — `DOC_COMMENT`, `RESERVED` token enum variants
- `src/kotlin/parser.c3` — `fun interface` modifier, `field` reference in accessor bodies, supertype `by expr` sub-AST, `<T : A & B>` intersection bound, annotation arg expression sub-AST (dual-storage), param default expression sub-AST (dual-storage), TYPE_REF sub-AST for all type positions (dual-storage)
- `src/kotlin/ast.c3` — new modifier flag (MOD_FUN_INTERFACE), reuse existing TYPE_REF kind, new FIELD_REF or BACKING_FIELD_EXPR kind if needed
- `test/lexer_test.c3`, `test/parser_test.c3` — RED-GREEN tests for every grammar addition + regression snapshot tests for dual-storage consistency

### Definition of Done
- [ ] `c3c build` exit code 0
- [ ] `c3c test` exit code 0 with zero regressions vs pre-plan baseline
- [ ] Every new grammar feature has a dedicated test asserting both AST shape AND text-field equivalence
- [ ] Snapshot diff `test/baseline.txt` vs post-plan output: empty (only new tests added)

### Must Have
- Backwards compatibility: every existing `type_text` / `annotation_text` / `extra_text` value MUST equal pre-plan value (snapshot test enforces)
- Dual-storage for all sub-AST additions
- Each task = one wave-eligible unit, 1-3 files, with TDD RED-GREEN-REFACTOR
- Full test suite passes after each task (`c3c test`, not just lexer/parser tests)
- New test per grammar feature using concrete Kotlin source samples

### Must NOT Have (Guardrails)
- **MUST NOT** modify `src/kotlin/types.c3`, `src/kotlin/flow.c3`, `src/kotlin/contracts.c3`, `src/kotlin/symbols.c3` to consume new sub-AST nodes (deferred follow-up scope)
- **MUST NOT** modify `src/lsp/*.c3` files (deferred follow-up scope)
- **MUST NOT** modify `src/workspace.c3` (deferred — depends on types.c3 changes)
- **MUST NOT** modify `src/deps/*.c3` or `src/dap/*.c3` (out of scope)
- **MUST NOT** remove or stop populating `type_text`, `annotation_text`, or `extra_text` fields (breaks 241+77+13 readers)
- **MUST NOT** refactor whitespace-sensitive `@`/`?`/`!` token variants (AT_NO_WS, AT_PRE_WS, AT_POST_WS, AT_BOTH_WS, QUEST_NO_WS, QUEST_WS, EXCL_NO_WS, EXCL_WS) — high cost, low LSP value, defer
- **MUST NOT** enforce modifier ordering rules (Kotlin spec rule, but lenient is OK for an LSP)
- **MUST NOT** raise/remove AST node hard limit (parser.c3:314) — separate concern
- **MUST NOT** raise MAX_STRING_DEPTH=8 limit — edge case, separate concern
- **MUST NOT** add new top-level (FILE-direct-child) AST node kinds without verifying `src/kotlin/incremental.c3:61-100` chunking still works
- **MUST NOT** wire `field` keyword into types.c3 backing-field semantics (out-of-scope; just parse the reference)
- **MUST NOT** implement when-guards (NOT a Kotlin 1.9 feature; deferred to 2.x)
- **MUST NOT** introduce SAM-conversion semantics for `fun interface` (just the modifier flag; type system change is out-of-scope)
- **MUST NOT** scope-creep into rewriting test fixtures — add new tests, don't rewrite existing 40+ `type_text` assertions

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — all verification agent-executed via `c3c test` / `c3c build` / AST inspection.

### Test Decision
- **Infrastructure exists**: YES (`c3c test`, `test/lexer_test.c3`, `test/parser_test.c3`, ~50 existing tests)
- **Automated tests**: YES (TDD) — every task is RED (failing test) → GREEN (minimal impl) → REFACTOR
- **Framework**: c3c built-in test runner
- **If TDD**: Each task starts with a failing test asserting the new grammar feature, then minimal implementation, then refactor for clarity

### QA Policy
Every task includes agent-executed QA scenarios. Tools: `Bash` (running `c3c build` and `c3c test`) plus AST-inspection scenarios via small C3 test programs that parse a Kotlin source string and assert node kinds/fields. Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}` (text logs of test runner output + assertion details).

### Regression Safety (MANDATORY)
- **Baseline capture**: Before T9 (first sub-AST task): `c3c test 2>&1 > .sisyphus/evidence/baseline-test-output.txt`
- **Post-task verification**: After every task in Wave 3 and Wave 4: `c3c test 2>&1 > .sisyphus/evidence/post-task-{N}-test-output.txt && diff .sisyphus/evidence/baseline-test-output.txt .sisyphus/evidence/post-task-{N}-test-output.txt` MUST show only added tests (no removed/changed PASS lines)
- **Snapshot test for dual-storage** (T9, T10, T11): iterate AST nodes in fixture file, assert `node.text_field == ast::node_text_from_subast(node.subast_child)`. Proves both storages stay in sync.
- **Cross-consumer test** (T9 — annotation args): run `c3c test test/code_actions_test.c3 test/diagnostics_test.c3 test/semantic_tokens_test.c3` (consumers of `has_annotation()`)
- **Cross-consumer test** (T11 — TYPE_REF): run `c3c test test/types_test.c3 test/flow_test.c3 test/contracts_test.c3 test/cross_file_*_test.c3` — zero regressions required

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — lexer additions, fully independent):
├── T1: `d`/`D` double literal suffix [quick]
├── T2: Shebang `#!` skip at file start [quick]
├── T3: DOC_COMMENT token kind + lexer recognition [quick]
└── T4: `...` RESERVED token [quick]

Wave 2 (After Wave 1 — parser missing productions, mostly independent):
├── T5: `fun interface` modifier+flag (MOD_FUN_INTERFACE) [quick]
├── T6: `field` reference in accessor bodies (FIELD_REF or NAME_EXPR with flag) [quick]
├── T7: Supertype `by expr` sub-AST (replace skip_delegation_expression) [unspecified-low]
└── T8: Intersection bound `<T : A & B>` in TYPE_PARAM [quick]

Wave 3 (After Wave 2 — low-risk dual-storage sub-ASTs, parallel):
├── T9: Annotation arg expression sub-AST (dual-storage) [unspecified-high]
└── T10: Parameter default expression sub-AST (dual-storage) [unspecified-low]

Wave 4 (After Wave 3 — HIGH-RISK isolated dual-storage):
└── T11: TYPE_REF sub-AST for all type positions (dual-storage) [deep]

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── F1: Plan compliance audit (oracle)
├── F2: Code quality review (unspecified-high)
├── F3: Real manual QA — full test suite + spec-conformance corpus (unspecified-high)
└── F4: Scope fidelity check + dual-storage invariant audit (deep)
-> Present results -> Get explicit user okay

Critical Path: T1 → T5 → T9 → T11 → F1-F4 → user okay
Parallel Speedup: ~60% faster than sequential
Max Concurrent: 4 (Waves 1 & 2)
```

### Dependency Matrix

- **T1-T4** (lexer): no deps — start immediately. Block Wave 2 entry.
- **T5** (`fun interface`): depends T1-T4 (clean lexer). Blocks F-wave only.
- **T6** (`field`): depends T1-T4. Blocks F-wave only.
- **T7** (supertype `by`): depends T1-T4. Blocks F-wave only.
- **T8** (intersection bound): depends T1-T4. Blocks F-wave only.
- **T9** (annotation arg sub-AST): depends T1-T4. Could parallelize with T5-T8 but holds for Wave 3 to keep risk bands separate. Blocks F-wave.
- **T10** (param default sub-AST): depends T1-T4. Same as T9. Blocks F-wave.
- **T11** (TYPE_REF sub-AST): depends T1-T10 (all prior waves) — sequential after Wave 3 because TYPE_REF refactor touches every type position incl those modified by T7/T8. Blocks F-wave.
- **F1-F4**: depend on T1-T11 complete. All 4 run in parallel.

### Agent Dispatch Summary

- **Wave 1**: 4 tasks — T1-T4 → `quick` (single-file lexer additions, 1-2h each)
- **Wave 2**: 4 tasks — T5, T6, T8 → `quick`; T7 → `unspecified-low` (slightly more involved)
- **Wave 3**: 2 tasks — T9 → `unspecified-high` (77 readers blast radius, dual-storage care needed); T10 → `unspecified-low`
- **Wave 4**: 1 task — T11 → `deep` (241 readers, must split into careful sub-steps within the task, may need oracle consult)
- **FINAL**: 4 tasks — F1 → `oracle`; F2 → `unspecified-high`; F3 → `unspecified-high`; F4 → `deep`

---

## TODOs

> Implementation + Test = ONE Task. EVERY task has: Recommended Agent Profile + Parallelization info + QA Scenarios.

- [x] 1. **Lexer: `d`/`D` double literal suffix**

  **What to do**:
  - In `src/kotlin/lexer.c3` `lex_number()` (~line 452-456), extend the suffix check to accept `d` and `D` in addition to `f`/`F`. When detected, mark the literal as FLOAT_LITERAL (same kind, since lexer doesn't distinguish float vs double — that's parser/type-system concern), consume the suffix character, and include it in the token span.
  - Add a test in `test/lexer_test.c3` parsing `1.5d`, `2.0D`, `42d`, `1e10D` → expect single FLOAT_LITERAL token with text `"1.5d"` etc.
  - Add a negative test: `1.0e` (no exponent digits) MUST still error or stop float; `1.0dd` MUST lex as FLOAT(`1.0d`) + IDENT(`d`).
  - RED-GREEN-REFACTOR cycle.

  **Must NOT do**:
  - Do NOT add a separate DOUBLE_LITERAL token kind (kept as FLOAT_LITERAL — parser layer concern)
  - Do NOT touch `src/kotlin/parser.c3` numeric handling (parser already accepts FLOAT_LITERAL)
  - Do NOT modify type system to distinguish `d`-suffixed numbers (out-of-scope)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single-file, ~5-line lexer change with focused tests. Trivial diff.
  - **Skills**: [`kls`]
    - `kls`: Required — references C3 language and the KLS lexer codebase conventions
  - **Skills Evaluated but Omitted**:
    - `playwright`: No browser involved
    - `git-master`: Standard single commit, no advanced git work needed

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with T2, T3, T4)
  - **Blocks**: T5-T11 (any parser task touching numeric literals or expecting clean lexer)
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - `src/kotlin/lexer.c3:452-456` — Existing `f`/`F` float suffix handling. Mirror this exact pattern for `d`/`D`.
  - `src/kotlin/lexer.c3:427-447` — Underscore separator + exponent handling for context

  **Test References**:
  - `test/lexer_test.c3` — Existing FLOAT_LITERAL tests. Find a `1.5f`-style assertion and copy the structure for new tests.

  **External References**:
  - Kotlin spec §1.4 (real literals): https://kotlinlang.org/spec/syntax-and-grammar.html — confirms `d`/`D` suffix is part of grammar

  **WHY Each Reference Matters**:
  - lexer.c3:452-456 is the exact insertion point and shows the byte-by-byte token-extension idiom used in this codebase (don't invent a new pattern)
  - Spec link confirms the suffix is allowed but optional and behaves identically to no-suffix double in terms of value (lexer doesn't care about value semantics)

  **Acceptance Criteria**:
  - [ ] Test file modified: `test/lexer_test.c3`
  - [ ] `c3c test test/lexer_test.c3` → PASS (all existing + new tests)
  - [ ] `c3c build` → exit 0

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — d-suffix on decimal point literal
    Tool: Bash (c3c test)
    Preconditions: Working tree clean. Lexer code modified per task.
    Steps:
      1. Run `c3c test test/lexer_test.c3 2>&1 > .sisyphus/evidence/task-1-happy.txt`
      2. Grep output for the new test name (e.g., `test_lexer_double_suffix_d`)
      3. Assert PASS line present
    Expected Result: New test PASSES; existing tests unchanged
    Failure Indicators: New test FAIL line; any existing test changes from PASS to FAIL
    Evidence: .sisyphus/evidence/task-1-happy.txt

  Scenario: Negative — non-suffix character after literal
    Tool: Bash (small C3 test program)
    Preconditions: Lexer modified.
    Steps:
      1. Write a test that lexes `1.0dd` and asserts: token[0] is FLOAT_LITERAL with text `"1.0d"`, token[1] is IDENTIFIER with text `"d"`
      2. Run via `c3c test`
    Expected Result: Two tokens emitted, no error
    Failure Indicators: Single token consuming both `d`s; ERROR token; lexer crash
    Evidence: .sisyphus/evidence/task-1-error.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-1-happy.txt` (test runner output for new positive test)
  - [ ] `.sisyphus/evidence/task-1-error.txt` (test runner output for negative test)

  **Commit**: YES — `feat(lexer): support d/D double literal suffix`. Files: `src/kotlin/lexer.c3`, `test/lexer_test.c3`. Pre-commit: `c3c test`.

- [x] 2. **Lexer: Shebang `#!` skip at file start**

  **What to do**:
  - In `src/kotlin/lexer.c3`, add detection at the very start of lexing (when `pos == 0` and the source begins with `#!`) to consume the entire first line up to but not including `\n` (or EOF), treating it as trivia.
  - In `next()` mode: skip silently.
  - In `next_all()` mode: emit a `LINE_COMMENT` token (keeps simplicity — no new SHEBANG token needed since shebang is line-comment-shaped).
  - Add tests in `test/lexer_test.c3`: source `#!/usr/bin/env kotlin\nfun main() {}` → first non-trivia token in `next()` mode is KW_FUN; in `next_all()` mode is LINE_COMMENT.
  - Negative test: `# !` (with space) MUST NOT be treated as shebang (lexed as HASH + EXCL).
  - Negative test: `#!` not at line 0/col 0 MUST NOT be treated as shebang.

  **Must NOT do**:
  - Do NOT add a separate SHEBANG token kind (LINE_COMMENT in trivia mode is sufficient)
  - Do NOT add `*.kts` script-mode handling beyond shebang lexing (out-of-scope)
  - Do NOT modify parser.c3 (lexer-only change)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single-file lexer addition with clear positional precondition (pos == 0)
  - **Skills**: [`kls`]
    - `kls`: KLS lexer pattern conventions
  - **Skills Evaluated but Omitted**:
    - `playwright`, `git-master`: not applicable

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with T1, T3, T4)
  - **Blocks**: T5-T11 indirectly (clean lexer required)
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `src/kotlin/lexer.c3:284-288` — Existing line comment skip pattern (`//` consume-to-newline). Mirror for shebang.
  - `src/kotlin/lexer.c3:104-141` — `lex_normal_token` entrypoint where shebang detection should be inserted (only when `pos == 0`)

  **Test References**:
  - `test/lexer_test.c3` — Existing line comment tests for assertion structure
  - `test/lexer_next_all_test.c3` — Trivia mode test patterns

  **External References**:
  - Kotlin spec §2.1 (file structure): shebang allowed at file start

  **WHY Each Reference Matters**:
  - lexer.c3:284-288 is the consume-to-newline idiom — reuse, don't reinvent
  - lexer.c3:104-141 shows the entrypoint structure; insert shebang check first, before all other token dispatching, gated on `pos == 0`

  **Acceptance Criteria**:
  - [ ] `c3c test test/lexer_test.c3 test/lexer_next_all_test.c3` → PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — shebang at file start, next() mode skips
    Tool: Bash (c3c test)
    Preconditions: Lexer modified.
    Steps:
      1. Write a test lexing `#!/usr/bin/env kotlin\nfun main() {}` via `next()`
      2. Assert first token is KW_FUN at expected line/col
      3. Run `c3c test test/lexer_test.c3 2>&1 > .sisyphus/evidence/task-2-happy.txt`
    Expected Result: KW_FUN is first emitted token; line counter accounts for shebang line
    Failure Indicators: First token is HASH or LINE_COMMENT in next() mode; line counter wrong
    Evidence: .sisyphus/evidence/task-2-happy.txt

  Scenario: Negative — `#!` not at start
    Tool: Bash (c3c test)
    Steps:
      1. Test source `fun main() {\n  #!/bin/bash\n}` via `next()`
      2. Assert tokens include HASH and EXCL (not skipped)
    Expected Result: HASH + EXCL tokens emitted
    Failure Indicators: Skipped as shebang
    Evidence: .sisyphus/evidence/task-2-negative.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-2-happy.txt`
  - [ ] `.sisyphus/evidence/task-2-negative.txt`

  **Commit**: YES — `feat(lexer): recognize shebang at file start`. Files: `src/kotlin/lexer.c3`, `test/lexer_test.c3`. Pre-commit: `c3c test`.

- [x] 3. **Lexer: `DOC_COMMENT` token kind for `/** */`**

  **What to do**:
  - Add `DOC_COMMENT` variant to the Token enum in `src/kotlin/token.c3` (group with trivia tokens like `LINE_COMMENT`, `BLOCK_COMMENT`).
  - In `src/kotlin/lexer.c3` `skip_block_comment()` / block comment lexing path, detect when the comment starts with exactly `/**` (and is not `/**/`, the empty 4-char form which is a regular block comment).
  - Emit `DOC_COMMENT` token in `next_all()` mode; skip in `next()` mode (same as BLOCK_COMMENT).
  - Update `TokenKind` helper functions (e.g., `is_trivia()` if exists) to include DOC_COMMENT.
  - Add tests in `test/lexer_test.c3` and `test/lexer_next_all_test.c3` distinguishing `/** doc */` (DOC_COMMENT) from `/* normal */` (BLOCK_COMMENT) from `/**/` (BLOCK_COMMENT, empty).

  **Must NOT do**:
  - Do NOT parse KDoc tags (`@param`, `@return`, etc.) — those are semantic-layer concerns
  - Do NOT modify parser.c3 to consume DOC_COMMENT (lexer trivia, parser already filters via `next()`)
  - Do NOT change behavior in `next()` mode (still skipped — backwards compat for parser)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Token enum addition + small lexer branch + tests
  - **Skills**: [`kls`]
    - `kls`: KLS lexer + token conventions
  - **Skills Evaluated but Omitted**:
    - Other skills not applicable

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with T1, T2, T4)
  - **Blocks**: T5-T11 indirectly
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `src/kotlin/token.c3` — Token enum location; find BLOCK_COMMENT and add DOC_COMMENT adjacent
  - `src/kotlin/lexer.c3:301-323` — `skip_block_comment()` with nesting depth counter; insert `/**` detection at entry
  - `src/kotlin/lexer.c3:257-259` — BLOCK_COMMENT emission in `next_all()` mode; mirror pattern for DOC_COMMENT

  **Test References**:
  - `test/lexer_next_all_test.c3` — BLOCK_COMMENT trivia test pattern

  **External References**:
  - Kotlin spec §1.6 (comments): KDoc is `/** */` distinct from regular block comment in some tooling contexts

  **WHY Each Reference Matters**:
  - token.c3 enum needs the new variant in a logical position (with other trivia)
  - lexer.c3:301-323 shows the existing nesting-comment idiom — DOC_COMMENT also supports nesting per Kotlin convention
  - The `next()`-mode skip path in lexer.c3 must treat DOC_COMMENT identically to BLOCK_COMMENT to preserve parser backwards compat

  **Acceptance Criteria**:
  - [ ] `DOC_COMMENT` enum variant exists in `src/kotlin/token.c3`
  - [ ] `c3c test test/lexer_test.c3 test/lexer_next_all_test.c3` → PASS
  - [ ] Full `c3c test` → PASS (no parser regressions, since `next()` still skips)

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — /** ... */ emits DOC_COMMENT in trivia mode
    Tool: Bash (c3c test)
    Steps:
      1. Lex `/** doc */fun x()` via next_all()
      2. Assert tokens include DOC_COMMENT then KW_FUN
      3. Lex same source via next() — assert first non-WS token is KW_FUN
    Expected Result: DOC_COMMENT emitted in next_all; skipped in next
    Failure Indicators: BLOCK_COMMENT emitted instead; DOC_COMMENT leaks into next() mode
    Evidence: .sisyphus/evidence/task-3-happy.txt

  Scenario: Negative — /**/ empty form is BLOCK_COMMENT, not DOC_COMMENT
    Tool: Bash (c3c test)
    Steps:
      1. Lex `/**/fun x()` via next_all()
      2. Assert first trivia token is BLOCK_COMMENT (not DOC_COMMENT)
    Expected Result: BLOCK_COMMENT emitted
    Failure Indicators: DOC_COMMENT emitted for the empty form
    Evidence: .sisyphus/evidence/task-3-negative.txt

  Scenario: Regression — full test suite
    Tool: Bash
    Steps:
      1. Run `c3c test 2>&1 > .sisyphus/evidence/task-3-regression.txt`
      2. Diff against pre-task baseline (if captured)
    Expected Result: Zero failing tests; no parser tests changed (DOC_COMMENT invisible in next() mode)
    Evidence: .sisyphus/evidence/task-3-regression.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-3-happy.txt`
  - [ ] `.sisyphus/evidence/task-3-negative.txt`
  - [ ] `.sisyphus/evidence/task-3-regression.txt`

  **Commit**: YES — `feat(lexer): emit DOC_COMMENT token for /** */ in trivia mode`. Files: `src/kotlin/token.c3`, `src/kotlin/lexer.c3`, `test/lexer_test.c3`, `test/lexer_next_all_test.c3`. Pre-commit: full `c3c test`.

- [x] 4. **Lexer: `...` RESERVED token**

  **What to do**:
  - Add `RESERVED` variant to Token enum in `src/kotlin/token.c3`.
  - In `src/kotlin/lexer.c3` operator/punctuation lex path (where `..` and `..<` are handled, ~line 692-695), extend the `..` branch: if next char after `..` is also `.`, emit RESERVED token (consuming all 3 dots).
  - Order: `...` must be detected BEFORE `..<` and `..` (longest match first).
  - Add tests asserting `...` lexes as single RESERVED, `..` still RANGE, `..<` still RANGE_UNTIL, `....` lexes as RESERVED + DOT.

  **Must NOT do**:
  - Do NOT use the RESERVED token elsewhere (it's reserved, intentionally inert)
  - Do NOT modify parser to recognize `...` as a production (parser would error if it appeared in expression position; that's correct behavior per spec)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 3-line lexer change + tests
  - **Skills**: [`kls`]
    - `kls`: KLS lexer conventions
  - **Skills Evaluated but Omitted**: N/A

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with T1, T2, T3)
  - **Blocks**: T5-T11 indirectly
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `src/kotlin/lexer.c3:692-695` — Existing `..` and `..<` longest-match dispatch. Insert `...` check before these.
  - `src/kotlin/token.c3` — Token enum location

  **Test References**:
  - `test/lexer_test.c3` — RANGE / RANGE_UNTIL test patterns

  **External References**:
  - Kotlin spec lexical grammar: `RESERVED: '...'` defined as reserved-for-future-use

  **WHY Each Reference Matters**:
  - lexer.c3:692-695 demonstrates the longest-match technique used for `..` vs `..<` — exact location to add `...` precedence
  - Spec confirms `...` is lexically defined but parser-rejected (which is fine — we lex, parser errors gracefully)

  **Acceptance Criteria**:
  - [ ] `c3c test test/lexer_test.c3` → PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — `...` lexes as single RESERVED token
    Tool: Bash (c3c test)
    Steps:
      1. Lex `...` via next()
      2. Assert single token of kind RESERVED with text `"..."`
    Expected Result: One RESERVED token, EOF after
    Failure Indicators: Three DOT tokens or RANGE+DOT
    Evidence: .sisyphus/evidence/task-4-happy.txt

  Scenario: Negative — `..` still RANGE, `..<` still RANGE_UNTIL
    Tool: Bash (c3c test)
    Steps:
      1. Lex `1..10`, `1..<10`, `1...10` separately
      2. Assert respective tokens: INT/RANGE/INT, INT/RANGE_UNTIL/INT, INT/RESERVED/INT
    Expected Result: Each form lexes correctly with longest-match
    Failure Indicators: `1..10` lexes as `1`+RESERVED-prefix; `1...10` lexes as `1`+`..`+`.10`
    Evidence: .sisyphus/evidence/task-4-negative.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-4-happy.txt`
  - [ ] `.sisyphus/evidence/task-4-negative.txt`

  **Commit**: YES — `feat(lexer): add RESERVED token for ...`. Files: `src/kotlin/token.c3`, `src/kotlin/lexer.c3`, `test/lexer_test.c3`. Pre-commit: `c3c test`.

- [x] 5. **Parser: `fun interface` modifier flag**

  **What to do**:
  - Add `MOD_FUN_INTERFACE` flag to mod_flags bitmask in `src/kotlin/ast.c3` (or reuse a free bit; check existing MOD_* enum).
  - In `src/kotlin/parser.c3` `parse_class_like()` dispatcher (find where `KW_INTERFACE` is matched after modifier parsing), add a check: if the preceding modifier set includes `KW_FUN` (soft keyword used as modifier), set `MOD_FUN_INTERFACE` on the resulting `INTERFACE_DECL` node.
  - The soft keyword `KW_FUN` already exists in token.c3; the parser's `parse_modifiers()` may already accept it as a generic modifier or may need explicit allowance. Verify and extend if needed.
  - Add tests in `test/parser_test.c3`: parse `fun interface Predicate<T> { fun test(t: T): Boolean }` → root child is INTERFACE_DECL with `mod_flags & MOD_FUN_INTERFACE != 0`.
  - Negative: `interface Foo` → no MOD_FUN_INTERFACE flag.

  **Must NOT do**:
  - Do NOT enforce single-abstract-method (SAM) constraint at parse time (semantic concern, out-of-scope)
  - Do NOT add SAM-conversion semantics (out-of-scope, type system)
  - Do NOT modify types.c3 or any LSP handler

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: One bit + one parser branch + tests
  - **Skills**: [`kls`]
    - `kls`: parser pattern conventions

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with T6, T7, T8)
  - **Blocks**: F-wave only
  - **Blocked By**: T1-T4 (Wave 1 completes)

  **References**:

  **Pattern References**:
  - `src/kotlin/ast.c3` — search for `MOD_DATA`, `MOD_SEALED`, etc. (existing bitmask flags); add `MOD_FUN_INTERFACE` adjacent
  - `src/kotlin/parser.c3` `parse_class_like()` — find class/interface dispatcher; insert `fun` modifier check
  - `src/kotlin/parser.c3` `parse_modifiers()` — verify it consumes `KW_FUN` as a soft modifier; extend `is_modifier_keyword()` if needed
  - `src/kotlin/token.c3:KW_FUN` — already exists as hard keyword

  **Test References**:
  - `test/parser_test.c3` — find existing `interface` test (e.g., assertion on INTERFACE_DECL); copy structure with mod_flags assertion

  **External References**:
  - Kotlin spec §16.31 (functional interfaces): https://kotlinlang.org/spec/declarations.html

  **WHY Each Reference Matters**:
  - ast.c3 bitmask must be extended without colliding with existing flags
  - parser.c3 must distinguish `fun` as interface modifier vs `fun` as function-decl keyword (context-dependent — only `fun` immediately followed by `interface` is the modifier)
  - Spec confirms `fun interface` is the only valid use of `fun` modifier on classifiers

  **Acceptance Criteria**:
  - [ ] `MOD_FUN_INTERFACE` enum value defined
  - [ ] `c3c test test/parser_test.c3` → PASS
  - [ ] Full `c3c test` → PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — `fun interface Predicate<T>` parses with flag
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun interface Predicate<T> { fun test(t: T): Boolean }`
      2. Assert AST: nodes[0] is FILE; nodes[1] is INTERFACE_DECL with name="Predicate"
      3. Assert nodes[1].mod_flags & MOD_FUN_INTERFACE != 0
    Expected Result: Flag set
    Failure Indicators: Flag absent; parse error; INTERFACE_DECL not produced
    Evidence: .sisyphus/evidence/task-5-happy.txt

  Scenario: Negative — `interface Foo` (no fun) does not set flag
    Tool: Bash (c3c test)
    Steps:
      1. Parse `interface Foo { fun bar() }`
      2. Assert nodes[1] is INTERFACE_DECL with mod_flags & MOD_FUN_INTERFACE == 0
    Expected Result: Flag NOT set
    Failure Indicators: Flag set spuriously
    Evidence: .sisyphus/evidence/task-5-negative.txt

  Scenario: Negative — `fun foo()` (function decl) parses normally, no spurious INTERFACE_DECL
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun foo() {}`
      2. Assert nodes[1] is FUN_DECL (not INTERFACE_DECL)
    Expected Result: FUN_DECL produced; no confusion with `fun interface`
    Failure Indicators: Parser misidentifies as interface
    Evidence: .sisyphus/evidence/task-5-funkw.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-5-happy.txt`
  - [ ] `.sisyphus/evidence/task-5-negative.txt`
  - [ ] `.sisyphus/evidence/task-5-funkw.txt`

  **Commit**: YES — `feat(parser): support fun interface modifier flag`. Files: `src/kotlin/ast.c3`, `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: full `c3c test`.

- [x] 6. **Parser: `field` reference inside property accessor bodies**

  **What to do**:
  - In `src/kotlin/parser.c3`, inside getter/setter body parsing context (or in `parse_name_expr` / `parse_primary` when emitting NAME_EXPR), detect when an identifier `field` appears inside an accessor body (getter or setter for a property).
  - Either: (a) add a new AST kind `BACKING_FIELD_EXPR` in `src/kotlin/ast.c3` and emit it instead of NAME_EXPR when context is accessor-body; OR (b) emit NAME_EXPR with a marker bit / extra_text="field" for downstream identification.
  - Recommendation: option (b) — minimal disruption, downstream consumers (types.c3 etc.) can still ignore the marker until they're updated.
  - Track accessor-body context via a parser flag (`in_accessor_body: bool`) set by `parse_property_accessor()` and reset on body exit.
  - Add tests: parse `var x: Int = 0; get() = field; set(v) { field = v }` → both `field` references emit NAME_EXPR (or BACKING_FIELD_EXPR) with marker.
  - Negative: `field` outside accessor body parses as regular NAME_EXPR with no marker.

  **Must NOT do**:
  - Do NOT wire `field` into types.c3 backing-field semantics (out-of-scope)
  - Do NOT validate that `field` only appears in mutable property accessors (semantic concern)
  - Do NOT modify any LSP handler

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: One parser-state flag, one branch in identifier lex/parse, tests
  - **Skills**: [`kls`]
    - `kls`: parser conventions

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with T5, T7, T8)
  - **Blocks**: F-wave only
  - **Blocked By**: T1-T4

  **References**:

  **Pattern References**:
  - `src/kotlin/parser.c3` `parse_property_accessor()` — entry/exit of accessor body parsing; flag toggle site
  - `src/kotlin/parser.c3` `parse_name_expr()` — where NAME_EXPR is created; check `in_accessor_body` here
  - `src/kotlin/token.c3:KW_FIELD` — token already exists; lexer emits it
  - `src/kotlin/parser.c3` existing `extra_text` marker convention (e.g., `"delegate"` for property delegation expression)

  **Test References**:
  - `test/parser_test.c3` — property accessor tests (find a `get()` or `set(v)` test)

  **External References**:
  - Kotlin spec §11.3 (backing fields): `field` identifier valid only inside custom accessor bodies

  **WHY Each Reference Matters**:
  - parse_property_accessor is the only place that knows we're inside an accessor; the flag must be toggled exactly there
  - Reusing extra_text marker pattern keeps the AST shape stable and lets downstream consumers opt in incrementally

  **Acceptance Criteria**:
  - [ ] `c3c test test/parser_test.c3` → PASS
  - [ ] Full `c3c test` → PASS (no regressions in existing accessor tests)

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — `field` inside getter body marked
    Tool: Bash (c3c test)
    Steps:
      1. Parse `var x: Int = 0\n  get() = field`
      2. Locate the NAME_EXPR for `field` inside the getter body
      3. Assert extra_text == "field" (or AST kind == BACKING_FIELD_EXPR if option (a) chosen)
    Expected Result: Marker present
    Failure Indicators: Plain NAME_EXPR with no marker; parse error
    Evidence: .sisyphus/evidence/task-6-happy.txt

  Scenario: Happy path — `field = v` inside setter body marked
    Tool: Bash (c3c test)
    Steps:
      1. Parse `var x: Int = 0\n  set(v) { field = v }`
      2. Locate the LHS of the assignment (NAME_EXPR for `field`)
      3. Assert extra_text == "field"
    Expected Result: Marker present on LHS
    Evidence: .sisyphus/evidence/task-6-setter.txt

  Scenario: Negative — `field` outside accessor body is unmarked
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun foo() { val field = 1; print(field) }`
      2. Assert NAME_EXPR for the `field` reference inside `print()` has NO marker (regular variable lookup)
    Expected Result: Unmarked NAME_EXPR
    Failure Indicators: Marker spuriously applied
    Evidence: .sisyphus/evidence/task-6-negative.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-6-happy.txt`
  - [ ] `.sisyphus/evidence/task-6-setter.txt`
  - [ ] `.sisyphus/evidence/task-6-negative.txt`

  **Commit**: YES — `feat(parser): mark field reference inside property accessor bodies`. Files: `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: full `c3c test`.

- [x] 7. **Parser: Supertype `by expr` delegation sub-AST**

  **What to do**:
  - In `src/kotlin/parser.c3`, locate `parse_super_types()` and the `skip_delegation_expression()` helper invoked at parser.c3:1736-1739 (per Metis audit).
  - Replace the silent skip with a real expression parse: when `KW_BY` is encountered after a supertype reference, call `parse_expression()` to consume the delegate expression and attach it as a child of the supertype reference (with `extra_text="delegate"` marker, mirroring property-delegation convention at parser.c3:1348-1357).
  - Preserve dual-storage: the supertype reference already exists in the AST; we're adding the expression child WITHOUT removing any existing fields.
  - Add tests: parse `class Foo : List<String> by myList`, `class Bar : Runnable by Runnable { println("x") }` (lambda delegate), `class Baz : I1 by impl1, I2 by impl2` (multiple delegations).
  - Negative: `class Foo : List<String>` (no `by`) parses unchanged.

  **Must NOT do**:
  - Do NOT change how supertype references themselves are stored
  - Do NOT modify property delegation at parser.c3:1348-1357 (already correct per Metis)
  - Do NOT change types.c3 to consume the new delegate expression (out-of-scope)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
    - Reason: Slightly more involved than Wave 1 lexer tasks — parsing inside super-type list with multiple `by` separators, but well-bounded
  - **Skills**: [`kls`]
    - `kls`: parser conventions and existing delegation patterns

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with T5, T6, T8)
  - **Blocks**: F-wave only
  - **Blocked By**: T1-T4

  **References**:

  **Pattern References**:
  - `src/kotlin/parser.c3:1736-1739` — Existing `skip_delegation_expression()` call; THIS is the replacement site
  - `src/kotlin/parser.c3:1348-1357` — Property delegation expression parse with `extra_text="delegate"` marker; mirror exactly
  - `src/kotlin/parser.c3` `parse_super_types()` — full context for understanding supertype list iteration

  **Test References**:
  - `test/parser_test.c3` — search for `class.*by` or `: .* by`; if absent, model new tests on existing supertype tests

  **External References**:
  - Kotlin spec §16.20 (delegation): `: T by expr` syntax in class declarations

  **WHY Each Reference Matters**:
  - parser.c3:1736-1739 is the exact line range to replace (Metis-verified)
  - parser.c3:1348-1357 demonstrates the existing convention — reuse identical marker (`extra_text="delegate"`) so downstream consumers can treat both delegation forms uniformly when they're updated

  **Acceptance Criteria**:
  - [ ] `c3c test test/parser_test.c3` → PASS
  - [ ] Full `c3c test` → PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — single `by` delegation
    Tool: Bash (c3c test)
    Steps:
      1. Parse `class Foo(items: List<String>) : List<String> by items`
      2. Locate the supertype reference for `List<String>`
      3. Assert it has a child expression node (the delegate `items`) with extra_text == "delegate"
    Expected Result: Delegate expression present as sub-AST
    Failure Indicators: Delegate expression skipped (no child); marker missing
    Evidence: .sisyphus/evidence/task-7-happy.txt

  Scenario: Happy path — multiple delegations
    Tool: Bash (c3c test)
    Steps:
      1. Parse `class M(a: I1, b: I2) : I1 by a, I2 by b`
      2. Assert both supertype references have delegate children
    Expected Result: Both delegations parsed
    Evidence: .sisyphus/evidence/task-7-multi.txt

  Scenario: Happy path — lambda delegate
    Tool: Bash (c3c test)
    Steps:
      1. Parse `class Bar : Runnable by Runnable { println("x") }`
      2. Assert delegate child is a complex expression (CALL_EXPR with trailing lambda)
    Expected Result: Full expression sub-AST
    Evidence: .sisyphus/evidence/task-7-lambda.txt

  Scenario: Negative — supertype without `by` parses unchanged
    Tool: Bash (c3c test)
    Steps:
      1. Parse `class Foo : Bar()`
      2. Assert supertype reference has NO delegation child
    Expected Result: No spurious delegate child
    Evidence: .sisyphus/evidence/task-7-negative.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-7-happy.txt`
  - [ ] `.sisyphus/evidence/task-7-multi.txt`
  - [ ] `.sisyphus/evidence/task-7-lambda.txt`
  - [ ] `.sisyphus/evidence/task-7-negative.txt`

  **Commit**: YES — `feat(parser): parse supertype delegation expression as sub-AST`. Files: `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: full `c3c test`.

- [x] 8. **Parser: Intersection bound `<T : A & B>` in TYPE_PARAM**

  **What to do**:
  - In `src/kotlin/parser.c3`, locate `parse_type_params()` and the per-param bound parsing (after the `:` following type-param identifier).
  - Currently a single bound type is parsed (via `skip_type_ref()`); extend to recognize `&` between bound types and capture each as a separate child or as a list.
  - Strategy: store as a single TYPE_PARAM with multiple bound text fragments OR use the existing WHERE_CONSTRAINT pattern internally (preferred — reuse parser.c3:1751-1769 idiom).
  - Verify `skip_type_ref()` handles `&` in this position (per Metis: AMP is handled in skip_type_ref but may collapse the bounds).
  - Add tests: `fun <T : Comparable<T> & Serializable> sort(x: T)` → TYPE_PARAM `T` has two bounds `Comparable<T>` and `Serializable`.
  - Negative: `fun <T : Comparable<T>>` → TYPE_PARAM has single bound.

  **Must NOT do**:
  - Do NOT confuse with `where T : A, T : B` syntax (already handled at parser.c3:1751-1769 — verify, do not modify)
  - Do NOT confuse with definitely-non-nullable `T & Any` in type position (handled in skip_type_ref already)
  - Do NOT modify types.c3 to consume the multi-bound info (out-of-scope)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Small parser branch in existing TYPE_PARAM parsing
  - **Skills**: [`kls`]
    - `kls`: parser + AST conventions

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with T5, T6, T7)
  - **Blocks**: F-wave only
  - **Blocked By**: T1-T4

  **References**:

  **Pattern References**:
  - `src/kotlin/parser.c3` `parse_type_params()` — type parameter parsing entry; bound parsing happens after `:`
  - `src/kotlin/parser.c3:1751-1769` — Existing `where`-clause WHERE_CONSTRAINT idiom; mirror for storing multi-bound info inside TYPE_PARAM
  - `src/kotlin/parser.c3` `skip_type_ref()` — current handling of `&` inside type refs (verify behavior before designing fix)

  **Test References**:
  - `test/parser_test.c3` — type parameter tests

  **External References**:
  - Kotlin spec §16.10 (type constraints): intersection bounds via `&` in type parameter position

  **WHY Each Reference Matters**:
  - parse_type_params is the only entry point for `<T : ...>` syntax
  - WHERE_CONSTRAINT idiom is the existing pattern for "multiple bounds on a type param" — reuse for consistency
  - Need to verify whether skip_type_ref's existing AMP handling (for `T & Any`) interferes with bound-list parsing

  **Acceptance Criteria**:
  - [ ] `c3c test test/parser_test.c3` → PASS
  - [ ] Full `c3c test` → PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — two-bound intersection
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun <T : Comparable<T> & Serializable> sort(x: T) {}`
      2. Locate the TYPE_PARAM for `T`
      3. Assert it has two bound entries: `"Comparable<T>"` and `"Serializable"`
    Expected Result: Both bounds captured
    Failure Indicators: Single collapsed bound `"Comparable<T> & Serializable"`; only one bound; parse error
    Evidence: .sisyphus/evidence/task-8-happy.txt

  Scenario: Happy path — three-bound intersection
    Tool: Bash (c3c test)
    Steps:
      1. Parse `class C<T : A & B & C>(val x: T)`
      2. Assert TYPE_PARAM `T` has three bounds
    Evidence: .sisyphus/evidence/task-8-three.txt

  Scenario: Negative — single bound parses unchanged
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun <T : Comparable<T>> f(x: T) {}`
      2. Assert TYPE_PARAM `T` has exactly one bound
    Evidence: .sisyphus/evidence/task-8-single.txt

  Scenario: Negative — `T & Any` in return-type position is NOT a bound
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun <T> f(x: T): T & Any = x!!`
      2. Assert TYPE_PARAM `T` has zero bounds (the `& Any` is in return-type position, not a constraint)
    Expected Result: Bound list empty for T; return type still includes `& Any`
    Evidence: .sisyphus/evidence/task-8-distinguish.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-8-happy.txt`
  - [ ] `.sisyphus/evidence/task-8-three.txt`
  - [ ] `.sisyphus/evidence/task-8-single.txt`
  - [ ] `.sisyphus/evidence/task-8-distinguish.txt`

  **Commit**: YES — `feat(parser): support intersection bound <T : A & B> in type parameters`. Files: `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: full `c3c test`.

- [x] 9. **Parser: Annotation argument expression sub-AST (DUAL-STORAGE)**

  **What to do**:
  - **CRITICAL DUAL-STORAGE**: This task adds expression sub-AST nodes for annotation arguments WITHOUT removing or changing the existing `annotation_text` field on ANNOTATION_ENTRY nodes.
  - In `src/kotlin/parser.c3`, locate `scan_annotation()` (parser.c3:881, 938 per audit). Currently captures argument range as raw text into `annotation_text`. Modify to ALSO call `parse_value_argument()` repeatedly inside the parens, attaching VALUE_ARGUMENT children to the ANNOTATION_ENTRY.
  - Keep `annotation_text` populated to the same raw-text value as before (snapshot test enforces).
  - Handle annotation array literal arg syntax `@A([1, 2, 3])` — collection literal in annotation context is parsed as a list expression (or as a sequence inside brackets — verify spec). This task ENABLES that downstream.
  - **Capture baseline first**: Before starting this task, run `c3c test 2>&1 > .sisyphus/evidence/baseline-test-output.txt` to enable regression diffing.
  - Add tests: parse `@Suppress("warn1", "warn2")` → ANNOTATION_ENTRY has `annotation_text == "(\"warn1\", \"warn2\")"` AND has 2 VALUE_ARGUMENT children with literal expression sub-ASTs.
  - Add a snapshot test: iterate ALL existing parser_test.c3 fixtures with annotations, assert pre-task annotation_text equals post-task annotation_text.
  - Add cross-consumer regression: run `c3c test test/code_actions_test.c3 test/diagnostics_test.c3 test/semantic_tokens_test.c3` (consumers of `has_annotation()`) — zero regressions.

  **Must NOT do**:
  - **MUST NOT** remove or stop populating `annotation_text` (breaks `ast::has_annotation()` walker and 77 readers across 10 files)
  - Do NOT modify `ast::has_annotation()` to use the new sub-AST (deferred follow-up)
  - Do NOT change behavior of empty-arg annotations `@Foo` (no parens, no children, no annotation_text)
  - Do NOT modify use-site target handling

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Dual-storage requires careful invariant preservation; 77-reader blast radius means strong testing discipline; annotation_text equivalence must be byte-identical
  - **Skills**: [`kls`]
    - `kls`: parser + annotation conventions

  **Parallelization**:
  - **Can Run In Parallel**: YES (with T10)
  - **Parallel Group**: Wave 3 (with T10)
  - **Blocks**: T11, F-wave
  - **Blocked By**: T1-T8 (Wave 2 complete)

  **References**:

  **Pattern References**:
  - `src/kotlin/parser.c3:881` — `scan_annotation()` argument range capture (Metis-verified line)
  - `src/kotlin/parser.c3:938` — `flush_pending_annotations()` / annotation entry build
  - `src/kotlin/parser.c3` `parse_value_argument()` — existing function-call argument parser; reuse for annotation args
  - `src/kotlin/ast.c3` ANNOTATION_ENTRY structure — annotation_text field stays; add VALUE_ARGUMENT children list

  **Test References**:
  - `test/parser_test.c3` — annotation tests
  - `test/code_actions_test.c3`, `test/diagnostics_test.c3`, `test/semantic_tokens_test.c3` — consumers of `has_annotation()`; cross-check no regressions

  **External References**:
  - Kotlin spec §16.18 (annotations): annotation argument syntax including array literal `[...]`

  **WHY Each Reference Matters**:
  - parser.c3:881 / 938 are the EXACT modification sites (Metis-verified)
  - parse_value_argument is battle-tested for call args; identical semantics work for annotation args (positional + named)
  - Cross-consumer test files contain the highest-risk regression sites

  **Acceptance Criteria**:
  - [ ] Baseline captured: `.sisyphus/evidence/baseline-test-output.txt` exists
  - [ ] `c3c test` → PASS with zero regressions vs baseline
  - [ ] Snapshot test: annotation_text byte-identical pre/post for all existing fixtures
  - [ ] Cross-consumer test: code_actions_test, diagnostics_test, semantic_tokens_test all PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — args parsed as sub-AST AND annotation_text preserved
    Tool: Bash (c3c test)
    Steps:
      1. Parse `@Suppress("UNUSED", "DEPRECATION") fun f() {}`
      2. Locate ANNOTATION_ENTRY for @Suppress
      3. Assert annotation_text == "(\"UNUSED\", \"DEPRECATION\")"
      4. Assert it has 2 VALUE_ARGUMENT children, each containing a LITERAL_EXPR (string)
    Expected Result: BOTH stored simultaneously
    Failure Indicators: annotation_text changed; sub-AST missing; child count wrong
    Evidence: .sisyphus/evidence/task-9-happy.txt

  Scenario: Happy path — named args
    Tool: Bash (c3c test)
    Steps:
      1. Parse `@A(name = "x", value = 42) class C`
      2. Assert two VALUE_ARGUMENT children with name fields populated
    Evidence: .sisyphus/evidence/task-9-named.txt

  Scenario: Happy path — array literal `@A([1, 2, 3])`
    Tool: Bash (c3c test)
    Steps:
      1. Parse `@A([1, 2, 3]) class C`
      2. Assert single VALUE_ARGUMENT child containing an array/collection-literal expression
    Expected Result: Sub-AST present
    Evidence: .sisyphus/evidence/task-9-array.txt

  Scenario: Regression — snapshot of annotation_text equivalence
    Tool: Bash (c3c test)
    Steps:
      1. For every annotation in test/parser_test.c3 fixtures, capture annotation_text pre-task (from baseline) and post-task
      2. Assert byte-identical
    Expected Result: Zero diffs
    Failure Indicators: ANY annotation_text changes
    Evidence: .sisyphus/evidence/task-9-snapshot.txt

  Scenario: Regression — cross-consumer test sweep
    Tool: Bash (c3c test)
    Steps:
      1. Run `c3c test test/code_actions_test.c3 test/diagnostics_test.c3 test/semantic_tokens_test.c3 2>&1 > .sisyphus/evidence/task-9-cross.txt`
      2. Assert exit code 0
    Expected Result: All three test files PASS
    Failure Indicators: Any FAIL
    Evidence: .sisyphus/evidence/task-9-cross.txt

  Scenario: Negative — empty-arg annotation `@Foo` unchanged
    Tool: Bash (c3c test)
    Steps:
      1. Parse `@Foo class C`
      2. Assert ANNOTATION_ENTRY has zero VALUE_ARGUMENT children, annotation_text empty/absent
    Evidence: .sisyphus/evidence/task-9-empty.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/baseline-test-output.txt`
  - [ ] `.sisyphus/evidence/task-9-happy.txt`
  - [ ] `.sisyphus/evidence/task-9-named.txt`
  - [ ] `.sisyphus/evidence/task-9-array.txt`
  - [ ] `.sisyphus/evidence/task-9-snapshot.txt`
  - [ ] `.sisyphus/evidence/task-9-cross.txt`
  - [ ] `.sisyphus/evidence/task-9-empty.txt`

  **Commit**: YES — `feat(parser): annotation argument sub-AST (dual-storage)`. Files: `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: full `c3c test` + snapshot diff.

- [x] 10. **Parser: Parameter default-value expression sub-AST (DUAL-STORAGE)**

  **What to do**:
  - **DUAL-STORAGE**: Add expression sub-AST for `param: T = expr` defaults WITHOUT removing the existing `extra_text` field that captures the default's raw text (per Metis: parser.c3:1572 — 13 readers).
  - In `src/kotlin/parser.c3`, locate parameter parsing where `=` after type triggers default-value capture (parser.c3:1572 region).
  - Currently the default expression range is captured into `extra_text`. Modify to ALSO call `parse_expression()` and attach the result as a child of PARAM with marker (reuse `extra_text="default"` pattern OR a child-position convention — pick whichever is consistent with existing AST shape).
  - Keep `extra_text` populated to byte-identical raw text.
  - Handle: literal defaults (`x: Int = 0`), call expressions (`x: List<Int> = listOf()`), lambdas (`x: () -> Int = { 42 }`), nested calls, named args within defaults, vararg + default mix.
  - Add tests: parse `fun f(x: Int = 0, y: String = "hi", z: () -> Int = { 1 + 2 })` → 3 PARAM nodes, each with both extra_text raw AND expression child.
  - Snapshot test: extra_text byte-identical pre/post for all existing PARAM fixtures.
  - Cross-consumer regression: signature_help, inlay_hints, completion (consumers of param default text) — full `c3c test` zero regressions.

  **Must NOT do**:
  - **MUST NOT** remove or stop populating `extra_text` for PARAM nodes (13 readers depend on it)
  - Do NOT change PARAM node identity or move the name/type fields
  - Do NOT modify signature_help.c3, inlay_hints.c3, or any LSP handler that reads PARAM.extra_text
  - Do NOT validate that defaults are compile-time constants (semantic concern)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
    - Reason: Smaller blast radius than T9 (13 vs 77 readers) but same dual-storage discipline required
  - **Skills**: [`kls`]
    - `kls`: parser conventions

  **Parallelization**:
  - **Can Run In Parallel**: YES (with T9)
  - **Parallel Group**: Wave 3 (with T9)
  - **Blocks**: T11, F-wave
  - **Blocked By**: T1-T8

  **References**:

  **Pattern References**:
  - `src/kotlin/parser.c3:1572` — PARAM default-value capture site (Metis-verified)
  - `src/kotlin/parser.c3` `parse_expression()` — reuse for default expression parse
  - `src/kotlin/parser.c3:1348-1357` — property-delegation `extra_text="delegate"` + child pattern; mirror

  **Test References**:
  - `test/parser_test.c3` — search for `=` in parameter context; existing default-param tests
  - `test/signature_help_test.c3`, `test/inlay_hints_test.c3` — cross-consumer regression targets

  **External References**:
  - Kotlin spec §16.30.2 (function value parameters): default value expression syntax

  **WHY Each Reference Matters**:
  - parser.c3:1572 is the EXACT modification site (Metis-verified)
  - Mirroring property-delegation idiom keeps the AST shape consistent with existing dual-storage precedent

  **Acceptance Criteria**:
  - [ ] Baseline captured (reuse `.sisyphus/evidence/baseline-test-output.txt` from T9, or recapture if T9 not run yet)
  - [ ] `c3c test` → PASS with zero regressions vs baseline
  - [ ] Snapshot test: PARAM extra_text byte-identical for all existing fixtures
  - [ ] Cross-consumer test: signature_help_test, inlay_hints_test PASS

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — literal default, dual-storage
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun f(x: Int = 42) {}`
      2. Locate PARAM `x`
      3. Assert extra_text contains "42" (or matches existing format) AND has expression child of LITERAL_EXPR(42)
    Expected Result: BOTH stored
    Failure Indicators: extra_text changed; child missing
    Evidence: .sisyphus/evidence/task-10-happy.txt

  Scenario: Happy path — lambda default
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun f(action: () -> Int = { 1 + 2 }) {}`
      2. Assert PARAM `action` has expression child of LAMBDA_EXPR
    Evidence: .sisyphus/evidence/task-10-lambda.txt

  Scenario: Happy path — call default with named args
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun f(list: List<Int> = listOf(1, 2, 3)) {}`
      2. Assert PARAM `list` has expression child of CALL_EXPR with 3 VALUE_ARGUMENT children
    Evidence: .sisyphus/evidence/task-10-call.txt

  Scenario: Regression — extra_text snapshot
    Tool: Bash (c3c test)
    Steps:
      1. For every PARAM with default in existing fixtures, capture extra_text pre/post
      2. Assert byte-identical
    Expected Result: Zero diffs
    Evidence: .sisyphus/evidence/task-10-snapshot.txt

  Scenario: Regression — cross-consumer sweep
    Tool: Bash (c3c test)
    Steps:
      1. Run `c3c test test/signature_help_test.c3 test/inlay_hints_test.c3 2>&1 > .sisyphus/evidence/task-10-cross.txt`
      2. Assert exit code 0
    Expected Result: PASS
    Evidence: .sisyphus/evidence/task-10-cross.txt

  Scenario: Negative — param without default unchanged
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun f(x: Int) {}`
      2. Assert PARAM `x` has no expression child, extra_text empty
    Evidence: .sisyphus/evidence/task-10-nodefault.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-10-happy.txt`
  - [ ] `.sisyphus/evidence/task-10-lambda.txt`
  - [ ] `.sisyphus/evidence/task-10-call.txt`
  - [ ] `.sisyphus/evidence/task-10-snapshot.txt`
  - [ ] `.sisyphus/evidence/task-10-cross.txt`
  - [ ] `.sisyphus/evidence/task-10-nodefault.txt`

  **Commit**: YES — `feat(parser): parameter default expression sub-AST (dual-storage)`. Files: `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: full `c3c test` + snapshot diff.

- [x] 11. **Parser: TYPE_REF sub-AST for ALL type positions (DUAL-STORAGE — HIGHEST RISK)**

  **What to do**:
  - **HIGHEST-RISK TASK**: Add structured TYPE_REF sub-AST nodes wherever a type appears (param types, return types, property types, type arguments, type bounds, function-type components, intersection-type members) WITHOUT removing or changing the existing `type_text` field anywhere (Metis: 241 readers across 9 files including types.c3, hover.c3, completion.c3, definition.c3, jar_index.c3).
  - **Precedent exists**: parser.c3:1709-1710 already builds TYPE_REF for supertypes. Generalize this to all positions.
  - **Strategy**:
    1. Audit every site where a type-context is parsed: parser.c3 functions like `parse_param()`, `parse_return_type()`, `parse_property_type()`, `parse_type_arguments()`, `parse_type_bounds()`, function-type parsers, intersection (`&`) handling.
    2. For each site: keep existing `type_text` capture; ADDITIONALLY build a TYPE_REF child node containing structured representation (name, generics, nullable flag, function-type components).
    3. Decide TYPE_REF child structure: name string + child TYPE_REF nodes for type args + nullable bit + function-type marker. Reuse existing TYPE_REF kind.
    4. Wire the TYPE_REF child onto the parent (PARAM, FUN_DECL return slot, PROPERTY_DECL, TYPE_PARAM bound, etc.) WITHOUT changing the parent's existing fields.
  - **MUST capture full baseline** before starting: `c3c test 2>&1 > .sisyphus/evidence/baseline-test-output-T11.txt` and `git rev-parse HEAD > .sisyphus/evidence/baseline-commit-T11.txt`.
  - **Cross-consumer regression sweep**: ALL existing tests must pass byte-identically except for new tests added by this task. Run `c3c test` and diff against baseline.
  - **Snapshot test**: For every TYPE_REF-bearing AST node in existing fixtures, capture `type_text` pre/post — must be byte-identical.
  - Add new tests: parse representative type forms — `Int`, `List<String>`, `Map<K, V>`, `Int?`, `(Int) -> String`, `suspend (A, B) -> C?`, `T & Any`, `Comparable<in T>`, `Array<out T>` — assert each produces a TYPE_REF sub-AST with correct structure AND preserved type_text.
  - Add nested test: `Map<String, List<Pair<Int, Boolean>>>` — assert nested TYPE_REF children to depth 4.
  - Update `src/kotlin/incremental.c3` if any new top-level node kinds — verify chunking unaffected (per Metis: parser.c3:314 AST_NODE_LIMIT may need raise; if so, raise to 16384, document in commit).

  **Must NOT do**:
  - **MUST NOT** remove or stop populating `type_text` ANYWHERE (241 readers will break)
  - **MUST NOT** change the format/content of `type_text` (snapshot diff must be byte-identical)
  - **MUST NOT** modify types.c3, flow.c3, hover.c3, completion.c3, definition.c3, jar_index.c3, or any consumer of `type_text` (all readers stay on text path; sub-AST is opt-in for future migrations)
  - **MUST NOT** raise AST_NODE_LIMIT above 16384 without explicit user approval (mid-task escalation if needed)
  - Do NOT modify supertype TYPE_REF construction at parser.c3:1709-1710 (already correct — generalize, don't replace)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 241-reader blast radius, ~10-15 type-context parse sites to audit, dual-storage invariant must hold across ALL sites, AST_NODE_LIMIT may require mid-task tuning, structured TYPE_REF design choices have downstream-migration implications. Requires goal-oriented autonomous problem-solving with thorough audit before implementation.
  - **Skills**: [`kls`]
    - `kls`: parser, AST, incremental conventions all in scope

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (sequential — alone)
  - **Blocks**: F-wave
  - **Blocked By**: T9, T10 (Wave 3 complete — dual-storage discipline established and proven on smaller surfaces first)

  **References**:

  **Pattern References**:
  - `src/kotlin/parser.c3:1709-1710` — Existing TYPE_REF construction for supertypes; THE template to generalize
  - `src/kotlin/parser.c3` `skip_type_ref()` — current text-only capture; understand fully before extending
  - `src/kotlin/parser.c3:314` — AST_NODE_LIMIT (verify if raise needed after type-context expansion)
  - `src/kotlin/ast.c3` — TYPE_REF NodeKind already exists; verify structure suffices for new positions
  - `src/kotlin/incremental.c3:61-100` — chunking logic; verify if new TYPE_REF positions affect top-level decl boundaries (likely NO since types appear inside decls, not as decls)

  **Test References**:
  - `test/parser_test.c3` — type form fixtures
  - All `test/*.c3` — full regression sweep target
  - Cross-consumer hot spots: `test/hover_test.c3`, `test/completion_test.c3`, `test/definition_test.c3`, `test/types_test.c3`, `test/cross_file_*_test.c3`

  **External References**:
  - Kotlin spec §16.10 (types): full type grammar including function types, nullable types, type projections, intersection types
  - Kotlin spec §11.1.5 (suspend function types)

  **WHY Each Reference Matters**:
  - parser.c3:1709-1710 is the proven pattern; generalizing it minimizes design risk
  - skip_type_ref must continue to work in tandem (it produces type_text; the new TYPE_REF construction is parallel)
  - AST_NODE_LIMIT is a known mid-task escalation hazard (Metis-flagged)
  - Cross-consumer test files cover the highest-risk regression sites — 241 readers concentrated in ~6 LSP handlers + types.c3

  **Acceptance Criteria**:
  - [ ] Baseline captured: `.sisyphus/evidence/baseline-test-output-T11.txt` and `.sisyphus/evidence/baseline-commit-T11.txt` exist
  - [ ] `c3c test` → PASS with zero regressions vs baseline
  - [ ] Snapshot: type_text byte-identical for ALL TYPE_REF-bearing nodes in existing fixtures
  - [ ] Cross-consumer regression: hover_test, completion_test, definition_test, types_test, cross_file_*_test all PASS
  - [ ] AST_NODE_LIMIT documented (kept at current value OR raised to 16384 with justification)

  **QA Scenarios** (MANDATORY):

  ```
  Scenario: Happy path — simple type in param position
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun f(x: Int) {}`
      2. Locate PARAM `x`; assert it has both type_text == "Int" AND a TYPE_REF child with name == "Int", no generics, nullable=false
    Expected Result: BOTH stored
    Failure Indicators: type_text changed; TYPE_REF missing
    Evidence: .sisyphus/evidence/task-11-simple.txt

  Scenario: Happy path — generic type in return position
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun f(): List<String> = listOf()`
      2. Locate FUN_DECL return type; assert TYPE_REF with name="List" and one type-arg child TYPE_REF with name="String"
    Evidence: .sisyphus/evidence/task-11-generic.txt

  Scenario: Happy path — nullable function type
    Tool: Bash (c3c test)
    Steps:
      1. Parse `val f: ((Int) -> String)? = null`
      2. Assert PROPERTY_DECL type slot has TYPE_REF marked function-type, nullable=true, with parameter-type and return-type children
    Evidence: .sisyphus/evidence/task-11-functype.txt

  Scenario: Happy path — suspend function type
    Tool: Bash (c3c test)
    Steps:
      1. Parse `val s: suspend (A, B) -> C? = TODO()`
      2. Assert TYPE_REF marked function-type with suspend flag, two param TYPE_REFs, return TYPE_REF (nullable C)
    Evidence: .sisyphus/evidence/task-11-suspend.txt

  Scenario: Happy path — intersection type
    Tool: Bash (c3c test)
    Steps:
      1. Parse `fun <T> f(x: T): T & Any = x!!`
      2. Assert return type TYPE_REF marked intersection, with two member TYPE_REFs (T, Any)
    Evidence: .sisyphus/evidence/task-11-intersect.txt

  Scenario: Happy path — variance projection
    Tool: Bash (c3c test)
    Steps:
      1. Parse `class Box<T>(val items: Array<out T>)`
      2. Assert PARAM `items` TYPE_REF for Array has type-arg child TYPE_REF for T with variance="out"
    Evidence: .sisyphus/evidence/task-11-variance.txt

  Scenario: Happy path — deeply nested generics
    Tool: Bash (c3c test)
    Steps:
      1. Parse `val m: Map<String, List<Pair<Int, Boolean>>> = mapOf()`
      2. Assert TYPE_REF tree has depth 4 with correct names at each level
    Evidence: .sisyphus/evidence/task-11-nested.txt

  Scenario: Regression — type_text snapshot (FULL)
    Tool: Bash (c3c test)
    Steps:
      1. For EVERY type-bearing AST node in EVERY existing fixture, capture type_text pre/post
      2. Assert byte-identical
    Expected Result: Zero diffs across hundreds of nodes
    Failure Indicators: ANY type_text byte change
    Evidence: .sisyphus/evidence/task-11-snapshot.txt

  Scenario: Regression — cross-consumer LSP test sweep
    Tool: Bash (c3c test)
    Steps:
      1. Run `c3c test test/hover_test.c3 test/completion_test.c3 test/definition_test.c3 test/types_test.c3 test/cross_file_hover_test.c3 test/cross_file_completion_test.c3 test/cross_file_definition_test.c3 test/cross_file_references_test.c3 2>&1 > .sisyphus/evidence/task-11-cross.txt`
      2. Assert exit code 0
    Expected Result: All PASS
    Failure Indicators: ANY FAIL = type_text reader broken
    Evidence: .sisyphus/evidence/task-11-cross.txt

  Scenario: Regression — full test suite
    Tool: Bash (c3c test)
    Steps:
      1. Run `c3c test 2>&1 > .sisyphus/evidence/task-11-fulltest.txt`
      2. Diff vs `.sisyphus/evidence/baseline-test-output-T11.txt`
      3. Assert no new failures (new tests added by this task may add new PASS lines; zero new FAIL lines)
    Expected Result: Zero new failures
    Evidence: .sisyphus/evidence/task-11-fulltest.txt + diff
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/baseline-test-output-T11.txt`
  - [ ] `.sisyphus/evidence/baseline-commit-T11.txt`
  - [ ] `.sisyphus/evidence/task-11-simple.txt`
  - [ ] `.sisyphus/evidence/task-11-generic.txt`
  - [ ] `.sisyphus/evidence/task-11-functype.txt`
  - [ ] `.sisyphus/evidence/task-11-suspend.txt`
  - [ ] `.sisyphus/evidence/task-11-intersect.txt`
  - [ ] `.sisyphus/evidence/task-11-variance.txt`
  - [ ] `.sisyphus/evidence/task-11-nested.txt`
  - [ ] `.sisyphus/evidence/task-11-snapshot.txt`
  - [ ] `.sisyphus/evidence/task-11-cross.txt`
  - [ ] `.sisyphus/evidence/task-11-fulltest.txt`

  **Commit**: YES — `feat(parser): TYPE_REF sub-AST for all type positions (dual-storage)`. Files: `src/kotlin/parser.c3`, `src/kotlin/ast.c3` (if NodeKind extension needed), `src/kotlin/incremental.c3` (if AST_NODE_LIMIT raise), `test/parser_test.c3`. Pre-commit: full `c3c test` + snapshot diff + cross-consumer sweep.

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before marking work complete.

- [x] F1. **Plan Compliance Audit** — `oracle`
  Read `.sisyphus/plans/kotlin-parser-spec-gaps.md` end-to-end. For each "Must Have": verify implementation exists (read file, run `c3c test`). For each "Must NOT Have" guardrail: search codebase for forbidden patterns (e.g., `grep -rn 'type_text' src/kotlin/types.c3 | wc -l` MUST equal pre-plan count; no edits to types.c3/flow.c3/contracts.c3/lsp/* per guardrails). Check evidence files exist in `.sisyphus/evidence/`. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [x] F2. **Code Quality Review** — `unspecified-high`
  Run `c3c build` + `c3c test`. Review all changed files in `src/kotlin/` for: AI slop (excessive comments, generic names like `data`/`result`/`temp`), commented-out code, unused functions, broken faults/optionals, missing `mem::free` for new heap allocs, pattern consistency with existing parser style (e.g., `parse_*` naming, parent-pointer setup, `ast::add_node` usage). Check incremental.c3 still works if any new node kinds added.
  Output: `Build [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [x] F3. **Real Manual QA — Full Test Suite + Spec Conformance Corpus** — `unspecified-high`
  Capture baseline (already done before T9 per regression-safety strategy). Run full `c3c test` suite. Diff against baseline — MUST show only added tests, no changed/removed PASS lines. Execute every QA scenario from every task. Run a spec-conformance corpus: parse 20 real-world Kotlin 1.9 source files (pick from kotlin/kotlinx OSS repos: kotlinx.coroutines, kotlinx.serialization, ktor) and assert zero parse errors. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Test diff [CLEAN/N regressions] | Scenarios [N/N pass] | Corpus [N/N parse OK] | VERDICT`

- [x] F4. **Scope Fidelity + Dual-Storage Invariant Audit** — `deep`
  For each task: read "What to do", read git diff. Verify 1:1 (no scope drift, no creep). Check "Must NOT do" compliance — `git diff` MUST show zero edits to `src/kotlin/types.c3`, `src/kotlin/flow.c3`, `src/kotlin/contracts.c3`, `src/lsp/`, `src/workspace.c3`, `src/deps/`, `src/dap/`. Audit dual-storage invariant: for every TYPE_REF/annotation arg/param default node added, verify the corresponding `type_text` / `annotation_text` / `extra_text` field is still populated to the same value as pre-plan (snapshot test passes). Detect cross-task contamination.
  Output: `Tasks [N/N compliant] | Forbidden edits [CLEAN/N issues] | Dual-storage invariant [CLEAN/N issues] | VERDICT`

---

## Commit Strategy

- **T1-T4**: one commit per lexer task. `feat(lexer): add <feature>`. Files: `src/kotlin/lexer.c3`, `src/kotlin/token.c3`, `test/lexer_test.c3`. Pre-commit: `c3c test`.
- **T5-T8**: one commit per parser-production task. `feat(parser): support <feature>`. Files: `src/kotlin/parser.c3`, `src/kotlin/ast.c3` (if new flag/kind), `test/parser_test.c3`. Pre-commit: `c3c test`.
- **T9**: `feat(parser): annotation argument sub-AST (dual-storage)`. Files: `src/kotlin/parser.c3`, `test/parser_test.c3`. Pre-commit: `c3c test`.
- **T10**: `feat(parser): parameter default value sub-AST (dual-storage)`. Same pattern.
- **T11**: `feat(parser): TYPE_REF sub-AST for all type positions (dual-storage)`. Files: `src/kotlin/parser.c3`, `src/kotlin/ast.c3` (if new kind), `test/parser_test.c3`. Pre-commit: full `c3c test` + dual-storage snapshot diff.

---

## Success Criteria

### Verification Commands
```bash
c3c build                                              # Expected: exit 0
c3c test                                               # Expected: exit 0, all tests PASS
diff .sisyphus/evidence/baseline-test-output.txt .sisyphus/evidence/final-test-output.txt  # Expected: only new test PASS lines
grep -rn 'type_text' src/kotlin/types.c3 | wc -l       # Expected: equal to pre-plan count (no removal)
git diff --stat src/kotlin/types.c3 src/kotlin/flow.c3 src/kotlin/contracts.c3 src/lsp/  # Expected: empty (zero changes)
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent (zero edits to forbidden files; text fields preserved)
- [ ] All tests pass with zero regressions
- [ ] Dual-storage invariant verified (snapshot test passes)
- [ ] Spec-conformance corpus parses cleanly (20 real-world Kotlin 1.9 files)
