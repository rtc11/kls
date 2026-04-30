# Semantic Sub-AST Migration (Wave-Staged Consumer Cutover)

## TL;DR

> **Quick Summary**: Migrate semantic-layer consumers (kotlin/, lsp/, workspace) from text-based fields (`type_text`, `annotation_text`, `extra_text`) to the dual-stored sub-AST nodes added by `kotlin-parser-spec-gaps.md` (T7, T9, T10, T11/T11b). Each wave is independently shippable; text fields stay populated until ALL readers retire. Strict per-file commit discipline avoids the parallel-agent collision documented in `[W1]` of the prior plan.
>
> **Deliverables**:
> - **Wave 0**: Discovery inventory file + baseline test snapshot (1 task)
> - **Wave A**: `extra_text` migration — supertype delegation marker + PARAM default (3 tasks, 13 readers, 4 files)
> - **Wave B**: `annotation_text` migration — including `ast::has_annotation()` walker variant (5 tasks, 77 readers, 10 files)
> - **Wave C**: `type_text` migration — staged consumer-by-consumer (10 tasks, 241 readers, 20 files)
> - **Wave D**: Optional text-field retirement (planning + risk gate; 1 task, marked OPT-IN)
> - **Wave FINAL**: 4 review tasks (F1 oracle, F2 quality, F3 manual QA, F4 scope/invariant)
>
> **Estimated Effort**: Very Large (20 implementation tasks + 4 review tasks)
> **Parallel Execution**: YES — 5 implementation waves + final wave
> **Critical Path**: W0 → A1 → A2-A3 (parallel) → B1 → B2-B5 (parallel) → C1 → C2-C8 (staged groups) → C9-C10 → D (optional gate) → F1-F4
> **Max Concurrent**: 4 within waves; serialize ALL tasks that touch the same file (per `[W1]` lesson)

---

## Context

### Original Request
Migrate semantic-layer consumers to read the dual-stored sub-AST instead of parsing/scanning text fields, in stages, so each commit keeps the codebase green. Eventual goal: enable removal of text fields. Source plan: `.sisyphus/plans/kotlin-parser-spec-gaps.md`.

### Prior Plan Reference
`.sisyphus/plans/kotlin-parser-spec-gaps.md` (closed) added:
- **TYPE_REF sub-AST** (T11/T11b) — typed children for param types, return types, generics, intersection bounds, function types incl nullable+suspend, deeply nested generics. Coexists with `type_text`.
- **Annotation argument sub-AST** (T9) — VALUE_ARGUMENT children with full expression sub-trees on ANNOTATION_ENTRY. Coexists with `annotation_text`.
- **Parameter default-value sub-AST** (T10) — full expression sub-tree as PARAM child. Coexists with PARAM `extra_text`.
- **Supertype `by` delegate sub-AST** (T7) — full expression as TYPE_REF child, marker `extra_text="delegate"`. Coexists with text storage.

### Dual-Storage Invariant (carried over from prior plan)
- `type_text` (241 readers / 20 files) — populated byte-identical
- `annotation_text` (77 readers / 10 files) — populated byte-identical
- `extra_text` (13 readers / 4 files) — populated byte-identical (param default + delegation marker)

This plan does NOT alter dual-storage on the producer side. Producer-side changes are forbidden until Wave D.

### Interview / Discovery Summary
**Files in scope (verified by ripgrep across `src/` and `test/`):**
- `src/document.c3`, `src/kotlin/{ast,cfg,contracts,flow,parser,types}.c3`, `src/workspace.c3`
- `src/lsp/{call_hierarchy,code_actions,completion,definition,diagnostics,document_link,execute_command,hover,inlay_hints,semantic_tokens,signature_help,type_definition}.c3`
- Tests: `test/{contracts,parser,script_parser,types,workspace}_test.c3`

**Out of scope** (carried over): `src/deps/*.c3`, `src/dap/*.c3`. Producer-side parser/lexer (untouched until Wave D).

**Pre-existing producer convention** (from `learnings.md` + `ast.c3:140-160`):
- `type_text` lives on TYPE_REF nodes
- `annotation_text` lives on ANNOTATION_ENTRY; `ast::has_annotation()` does word-match on the field
- `extra_text` reused for: PARAM default text, NAME_EXPR `field` marker, `delegate` marker on TYPE_REF, operator string on PREFIX/POSTFIX/BINARY/ASSIGNMENT_EXPR, `*` spread on VALUE_ARGUMENT, `trailing` marker on VALUE_ARGUMENT, `arg` / `function` / `function nullable` / `return nullable` markers on TYPE_REF
- **Critical**: only the *PARAM-default* and *supertype-delegate* uses of `extra_text` are in Wave A scope. All other `extra_text` uses (operator strings, spread/trailing markers, type-ref kind markers) are NOT migrated — they're not text-of-source-code and have no sub-AST replacement.

---

## Work Objectives

### Core Objective
Migrate every reader of `type_text` / `annotation_text` / (in-scope) `extra_text` to consume the corresponding sub-AST, file-by-file, with per-file commits, while keeping `c3c test` green at every commit and preserving byte-identical text-field population.

### Concrete Deliverables
- `.sisyphus/evidence/migration-inventory.md` — exhaustive reader list (file:line) classified as `parse_only` / `format_text` / `key_lookup` / `test_assertion`
- `.sisyphus/evidence/baseline-test-output.txt` — pre-migration `c3c test` output
- New helper API in `src/kotlin/ast.c3`:
  - `fn String type_ref_name(ParseResult* pr, int type_ref_idx, Allocator a)` — render type from TYPE_REF children (byte-identical to `type_text` for same input)
  - `fn bool has_annotation_ast(ParseResult* pr, int decl_idx, String name)` — sub-AST-aware variant of `has_annotation`
  - `fn int param_default_expr(ParseResult* pr, int param_idx)` — return child expr index, -1 if absent
  - `fn int supertype_delegate_expr(ParseResult* pr, int type_ref_idx)` — return child expr index, -1 if absent
- Migrated consumers across waves A/B/C, one file per commit (see Execution Strategy)
- Wave D: GO/NO-GO assessment doc — `.sisyphus/evidence/wave-d-readiness.md` — does NOT remove text fields unless explicitly approved
- 4 final review tasks (F1-F4) sign-off

### Definition of Done
- [ ] Inventory file complete with every reader classified
- [ ] `c3c test` exit 0 at every commit (verified per task)
- [ ] Zero diff vs baseline test output beyond intentional new tests
- [ ] All in-scope `parse_only` and `format_text` readers route through new helpers OR sub-AST walking
- [ ] `key_lookup` readers either: keep text key (renderer guarantees identity) OR migrate to AST-index key
- [ ] `test_assertion` readers either: migrated to assert sub-AST shape OR retain text assertions intentionally (documented)
- [ ] Wave D readiness assessment exists; no text-field removal without explicit user GO
- [ ] F1-F4 reviews PASS

### Must Have
- One file (or one tightly-coupled call cluster) = one commit. **No bundling.**
- Every task ends with `c3c test` exit 0 + diff vs baseline shows ONLY added tests / migrated assertions
- Snapshot guard test introduced in Wave 0: for every TYPE_REF / ANNOTATION_ENTRY / PARAM in fixture corpus, assert `node.text_field == render_from_subast(node)`. Fails immediately if producer drifts.
- TDD: every consumer migration starts with a RED test asserting the sub-AST path returns the same answer as the text path on a focused fixture, then implementation, then refactor
- Every task respects DISJOINT-files rule (per `issues.md [W1]`); when two consumer migrations both touch a file, SERIALIZE within wave

### Must NOT Have (Guardrails)
- **MUST NOT** stop populating `type_text`, `annotation_text`, or `extra_text` on the producer side until Wave D explicitly approved (would cascade-break unmigrated readers)
- **MUST NOT** modify `src/deps/*.c3` or `src/dap/*.c3`
- **MUST NOT** modify producer code in `src/kotlin/parser.c3` or `src/kotlin/lexer.c3` (other than possibly adding the new ast.c3 helpers — those go in `ast.c3`, not parser.c3)
- **MUST NOT** break `MAX_FACTS_PER_STATE` / per-function CFG / FlowAnalysis lifecycle (AGENTS.md flow analysis section)
- **MUST NOT** alter smart-cast stability gate semantics (orthogonal feature)
- **MUST NOT** skip baseline snapshot — capture full `c3c test` output BEFORE Wave A starts
- **MUST NOT** bundle multiple consumer-file migrations into a single commit
- **MUST NOT** dispatch parallel agents to the same file within a wave (W1 lesson)
- **MUST NOT** invoke `c3c test test/<file>.c3` (not supported in this build target — per `issues.md`); always use full `c3c test`
- **MUST NOT** repurpose `extra_text` for non-PARAM-default / non-delegate uses (operator strings, spread, kind markers stay text-only — they have no sub-AST equivalent and are not source-text)

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — agent-executed via `c3c test` / `c3c build` / AST inspection programs. Manual KLS smoke runs are a single F3-only step.

### Test Decision
- **Infrastructure**: YES (`c3c test`, ~50 test files, ~2780 baseline tests post prior plan)
- **TDD**: YES — every task is RED → GREEN → REFACTOR. Migration tasks add a focused fixture asserting the sub-AST consumer matches the text consumer pre-migration, then flip the consumer.
- **Framework**: c3c built-in test runner

### QA Policy
Every implementation task includes agent-executed QA scenarios using `Bash` for `c3c test` + small C3 programs that build a parser fixture and assert helper-output / consumer-output equivalence. Evidence to `.sisyphus/evidence/task-{wave}-{N}-{slug}.txt`.

### Regression Safety (MANDATORY)
- **Baseline capture (Wave 0)**: `c3c test 2>&1 > .sisyphus/evidence/baseline-test-output.txt` — required artifact
- **Per-task post-verification**: `c3c test 2>&1 > .sisyphus/evidence/post-{task-id}-test-output.txt && diff` MUST show only added tests / intentionally migrated assertions
- **Snapshot guard test (Wave 0 deliverable)**: `test/dual_storage_snapshot_test.c3` — iterates fixture corpus, asserts `node.text == render_from_subast(node)` for TYPE_REF / ANNOTATION_ENTRY / PARAM. Fails fast if producer drifts.
- **Cross-consumer regression for shared structures**: After every Wave B task, run full `c3c test` (cannot scope-filter). After every Wave C task touching `types.c3`, capture `flow_test`, `types_test`, `cross_file_*_test` results from the full run for evidence.

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 0 (Sequential — start immediately, prerequisite for all):
└── W0: Inventory + helpers + baseline + snapshot guard test [deep]

Wave A (extra_text migration — small blast, mostly disjoint):
├── A1: ast.c3 helpers `param_default_expr`, `supertype_delegate_expr` + tests [quick]   (depends W0)
├── A2: src/lsp/inlay_hints.c3 — PARAM default consumer migration [unspecified-low]      (depends A1)
├── A3: src/lsp/signature_help.c3 — PARAM default consumer migration [unspecified-low]   (depends A1)
└── A4: src/kotlin/symbols.c3 — supertype delegate marker consumer migration [quick]     (depends A1)
    NOTE: A2 and A3 touch DIFFERENT files; safe parallel. Both depend on A1 helpers.

Wave B (annotation_text migration — 77 readers, 10 files):
├── B1: ast.c3 `has_annotation_ast()` sub-AST walker + render helper [unspecified-low]   (depends W0)
├── B2: src/kotlin/types.c3 annotation consumers [unspecified-low]                       (depends B1)
├── B3: src/lsp/diagnostics.c3 annotation consumers [unspecified-low]                    (depends B1)
├── B4: src/lsp/code_actions.c3 annotation consumers [unspecified-low]                   (depends B1)
├── B5: src/lsp/semantic_tokens.c3 annotation consumers [unspecified-low]                (depends B1)
└── B6: remaining annotation consumers (hover, completion, inlay_hints, code_lens) [unspecified-low]  (depends B1)
    NOTE: B2-B6 ALL touch DIFFERENT files. Safe parallel. Sequential dispatch only if shared helper churn.

Wave C (type_text migration — 241 readers, 20 files; HIGH RISK; staged):

  Wave C-pre (helpers):
  └── C1: ast.c3 `type_ref_name(pr, idx, alloc)` renderer + snapshot test [deep]          (depends W0)
       Renderer must produce byte-identical output to existing `type_text` for every fixture.

  Wave C-1 (peripheral consumers — small files, low coupling):
  ├── C2: src/lsp/type_definition.c3 type_text consumers [unspecified-low]                (depends C1)
  ├── C3: src/lsp/document_link.c3 type_text consumers [quick]                            (depends C1)
  ├── C4: src/lsp/execute_command.c3 type_text consumers [quick]                          (depends C1)
  └── C5: src/lsp/call_hierarchy.c3 + signature_help.c3 + inlay_hints.c3 + completion.c3 + definition.c3 + hover.c3 + semantic_tokens.c3 type_text consumers
       SERIALIZE these 7 — ONE PER COMMIT. Same wave, sequential dispatch.

  Wave C-2 (workspace + document layer):
  ├── C6: src/document.c3 type_text consumers [unspecified-low]                           (depends C1)
  └── C7: src/workspace.c3 type_text consumers [unspecified-high]                         (depends C1, C6)
       (C7 may key-lookup off type_text; needs careful renderer-identity check)

  Wave C-3 (kotlin frontend — highest risk):
  ├── C8: src/kotlin/contracts.c3 + cfg.c3 type_text consumers [unspecified-high]         (depends C1)
  ├── C9: src/kotlin/flow.c3 type_text consumers [unspecified-high]                       (depends C1, C8)
  └── C10: src/kotlin/types.c3 type_text consumers [deep]                                 (depends C1-C9)
       types.c3 has 50+ readers and is core to inference. Sub-step ordering MANDATORY:
         (a) inference helpers first (low-coupling readers)
         (b) resolution paths (mid-coupling)
         (c) diagnostic paths last
       Each sub-step is its own commit. Atomic per call-cluster.

  Wave C-diagnostics:
  └── C11: src/lsp/diagnostics.c3 type_text consumers [unspecified-high]                  (depends C10)
       Diagnostics relies on resolved types from types.c3; do AFTER C10.

  Wave C-tests:
  └── C12: test/{types,workspace,contracts,parser,script_parser}_test.c3 fixture migration [unspecified-low]   (depends C10, C11)
       Migrate test_assertion-class readers OR document why kept on text path.

Wave D (OPTIONAL, GATED — text-field retirement assessment):
└── D1: Readiness assessment + risk doc; NO code changes [oracle]                         (depends C12)
       Output: `.sisyphus/evidence/wave-d-readiness.md`. Gates any future plan to flip producer side.

Wave FINAL (4 parallel reviews):
├── F1: Plan compliance + dual-storage invariant audit [oracle]
├── F2: Code quality (dead helpers, indentation drift à la prior F2) [unspecified-high]
├── F3: Real manual QA — full c3c test + run KLS against a real Kotlin project (hover/completion/diagnostics smoke) [unspecified-high]
└── F4: Scope fidelity + dual-storage invariant final check [deep]
-> Present results -> Get explicit user okay

Critical Path: W0 → A1 → A2/A3/A4 → B1 → B2-B6 → C1 → C2-C5 → C6 → C7 → C8 → C9 → C10 → C11 → C12 → D1 → F1-F4
Max parallel within wave: 4 (Wave A inner, Wave B inner, Wave C-1 small files only)
Forced serialization points: any wave-internal pair touching the same file
```

### Dependency Matrix

| Task | Depends On | Blocks | Reason |
|------|------------|--------|--------|
| W0 | none | ALL | inventory + helpers + baseline + snapshot guard required first |
| A1 | W0 | A2, A3, A4 | helper API |
| A2 | A1 | F-wave | inlay_hints PARAM default consumer |
| A3 | A1 | F-wave | signature_help PARAM default consumer |
| A4 | A1 | F-wave | symbols supertype delegate consumer |
| B1 | W0 | B2-B6 | `has_annotation_ast` helper |
| B2-B6 | B1 | F-wave | per-file annotation consumer migrations (disjoint files) |
| C1 | W0 | C2-C12 | TYPE_REF renderer is foundation |
| C2-C5 | C1 | C6+ | small-file consumer migrations |
| C6 | C1 | C7 | document.c3 before workspace.c3 |
| C7 | C1, C6 | C10 | workspace before types.c3 (workspace publishes types) |
| C8 | C1 | C9, C10 | contracts/cfg before flow |
| C9 | C1, C8 | C10 | flow before types (types calls flow) |
| C10 | C1-C9 | C11 | types.c3 last in kotlin/ |
| C11 | C10 | C12 | diagnostics consumes resolved types |
| C12 | C10, C11 | D1 | test fixture migration after producers stable |
| D1 | C12 | F-wave | readiness assessment |
| F1-F4 | All implementation | user okay | parallel reviews |

### Agent Dispatch Summary

- **W0**: 1 task — `deep` (inventory rigor + helper design)
- **Wave A**: 4 tasks — A1 `quick`, A2 `unspecified-low`, A3 `unspecified-low`, A4 `quick`
- **Wave B**: 6 tasks — B1 `unspecified-low`, B2-B6 each `unspecified-low`
- **Wave C**: 12 tasks — C1 `deep`, C2-C5 mostly `quick`/`unspecified-low`, C6 `unspecified-low`, C7 `unspecified-high`, C8-C9 `unspecified-high`, C10 `deep`, C11 `unspecified-high`, C12 `unspecified-low`
- **Wave D**: 1 task — `oracle` (assessment, NOT code)
- **Wave FINAL**: 4 tasks — F1 `oracle`, F2 `unspecified-high`, F3 `unspecified-high`, F4 `deep`

---

## TODOs

> Per-task fields: What / Must NOT / Recommended Agent Profile (category + skills) / Parallelization / References (Pattern + Test + External + WHY) / Acceptance Criteria / QA Scenarios / Evidence / Commit.
> Skills evaluated for every task: `kls` (always relevant — KLS conventions), `git-master` (only when commit complexity warrants), `playwright` (never — no browser), `frontend-ui-ux` (never), `caveman`/`caveman-compress` (never — communication mode, not work skill), `ai-slop-remover` (post-task cleanup, not in-task), `review-work` (used in F-wave only).

### W0. Discovery + Helpers + Baseline + Snapshot Guard

**What to do**:
1. Generate `.sisyphus/evidence/migration-inventory.md`. For each of `type_text`, `annotation_text`, `extra_text`:
   - List every reader by `file:line`
   - Classify each reader: `parse_only` | `format_text` | `key_lookup` | `test_assertion`
   - Tag each reader's wave (A / B / C) and target task
   - For `extra_text`: explicitly note which readers are PARAM-default / supertype-delegate (in scope) vs operator/spread/kind-marker (out of scope, leave on text)
2. Capture baseline: `c3c test 2>&1 > .sisyphus/evidence/baseline-test-output.txt` (full suite — file-scoped not supported per `issues.md`).
3. Add `test/dual_storage_snapshot_test.c3`: parses a fixed fixture string covering type refs (simple, generic, function, nullable function, suspend, intersection bound, deeply nested), annotations (positional, named, array literal, use-site), PARAM defaults, and supertype delegations. For each TYPE_REF / ANNOTATION_ENTRY / PARAM, asserts `node.<text_field> == render_<subast>(node)` (renderer can be a stub returning `node.<text_field>` initially — replaced in C1 / B1 / A1 with real renderers). Test guarantees future text-field-shape regressions fire IMMEDIATELY.

**Must NOT do**:
- MUST NOT modify any `src/` consumer files
- MUST NOT add real renderer logic yet — that's A1/B1/C1 scope
- MUST NOT use `c3c test test/<file>.c3` (not supported)

**Recommended Agent Profile**:
- **Category**: `deep`
  - Reason: Inventory rigor + cross-file classification + designing snapshot fixture coverage requires deep understanding
- **Skills**: [`kls`]
- **Skills Evaluation**:
  - INCLUDED `kls`: Required — AST shape, conventions
  - OMITTED `git-master`: Single trivial commit
  - OMITTED `playwright`/`frontend-ui-ux`: irrelevant
  - OMITTED `ai-slop-remover`: pre-implementation, nothing to clean
  - OMITTED `review-work`: F-wave only

**Parallelization**:
- Can Run In Parallel: NO — prerequisite for ALL waves
- Blocks: every other task
- Blocked By: none

**References**:
- **Pattern**: `src/kotlin/ast.c3:140-160` (field defs); `src/kotlin/ast.c3:324-456` (existing `has_annotation`/`is_spread`/etc helpers)
- **Test**: `test/parser_test.c3` `type_ref_*_dual_storage` tests (added by T11/T11b) for snapshot fixture inspiration
- **External**: prior plan §`Verification Strategy` for snapshot pattern
- **WHY**: ast.c3 helpers are the canonical home for new APIs; T11b tests prove the dual-storage invariant the snapshot test must lock down

**Acceptance Criteria**:
- [ ] `.sisyphus/evidence/migration-inventory.md` lists every reader with classification + target task
- [ ] `.sisyphus/evidence/baseline-test-output.txt` exists, exit code 0
- [ ] `test/dual_storage_snapshot_test.c3` exists; full `c3c test` PASS

**QA Scenarios**:
```
Scenario: baseline captured
  Steps: run c3c test, redirect to baseline file, assert exit 0
  Evidence: .sisyphus/evidence/baseline-test-output.txt

Scenario: snapshot guard fires on intentional drift (smoke)
  Steps: temporarily mutate one TYPE_REF render stub to return wrong value, run c3c test, assert dual_storage_snapshot_test FAILS, revert, rerun, assert PASS
  Evidence: .sisyphus/evidence/task-w0-snapshot-smoke.txt
```

**Evidence to Capture**: inventory file, baseline file, snapshot smoke log

**Commit**: YES — `chore(migration): inventory + baseline + dual-storage snapshot guard`. Files: `.sisyphus/evidence/migration-inventory.md`, `.sisyphus/evidence/baseline-test-output.txt`, `test/dual_storage_snapshot_test.c3`. Pre-commit: `c3c test`.

---

### A1. ast.c3 helpers: `param_default_expr` + `supertype_delegate_expr`

**What to do**:
- Add to `src/kotlin/ast.c3`:
  - `fn int param_default_expr(ParseResult* pr, int param_idx)` — walk PARAM children, return index of first non-VALUE_ARGUMENT non-modifier expression child (the default), -1 if none
  - `fn int supertype_delegate_expr(ParseResult* pr, int type_ref_idx)` — return TYPE_REF child whose role is the delegate (per T7 convention, marker `extra_text="delegate"` may be on parent or child — verify shape and document)
- Update `test/dual_storage_snapshot_test.c3` to call real renderers for these two cases (replace stubs)
- Add focused unit tests in same snapshot file or new `test/migration_helpers_test.c3` asserting helpers return -1 / valid index across fixtures

**Must NOT do**:
- MUST NOT modify any consumer file
- MUST NOT change PARAM / TYPE_REF storage layout

**Agent Profile**:
- **Category**: `quick`
  - Reason: Two pure helpers + tests
- **Skills**: [`kls`]
- **Evaluation**: INCLUDED `kls` (AST conventions). OMITTED others (irrelevant).

**Parallelization**:
- Can Run In Parallel: NO with itself; YES with B1 / C1 (different files OK, but ast.c3 is shared — SERIALIZE A1, B1, C1 across waves)
- Blocks: A2, A3, A4
- Blocked By: W0

**References**:
- **Pattern**: prior plan T7/T10 commit notes in `learnings.md` lines 53-58, 75-81
- **Test**: `test/parser_test.c3` PARAM default and delegate tests
- **External**: source plan T7 + T10 sections
- **WHY**: T7/T10 producer code defines the AST shape — helpers must match it exactly

**Acceptance Criteria**:
- [ ] Two helpers exist with documented contracts
- [ ] Snapshot guard test now exercises real renderers for param-default + delegate
- [ ] Full `c3c test` PASS with zero diff vs baseline (only new tests added)

**QA Scenarios**:
```
Scenario: param_default_expr returns valid child index for default-having PARAM, -1 otherwise
Scenario: supertype_delegate_expr returns child for `class Foo : I by impl`, -1 for `class Foo : I`
Scenario: snapshot guard test still PASSES (renderers byte-identical)
Evidence: .sisyphus/evidence/task-a1-{happy,negative,snapshot}.txt
```

**Commit**: YES — `feat(ast): add param_default_expr + supertype_delegate_expr helpers`. Files: `src/kotlin/ast.c3`, `test/dual_storage_snapshot_test.c3` (or new `test/migration_helpers_test.c3`). Pre-commit: `c3c test`.

---

### A2. Migrate `src/lsp/inlay_hints.c3` PARAM default consumer

**What to do**:
- Identify every read of `param.extra_text` in `src/lsp/inlay_hints.c3` (inventory from W0)
- Replace each with `ast::param_default_expr(pr, param_idx)` index check, OR with a renderer call if the consumer needs the default text for display
- Add a focused test in `test/inlay_hints_test.c3` (existing) asserting hint behavior unchanged for PARAM-with-default fixture
- TDD: RED test asserts new code path matches old output on fixture, then implementation, then refactor

**Must NOT do**:
- MUST NOT touch other consumer files
- MUST NOT change inlay_hints output format
- MUST NOT remove fallback to text path if helper fails — leave defensive `?? param.extra_text` style guard during transition

**Agent Profile**:
- **Category**: `unspecified-low`
- **Skills**: [`kls`]
- **Evaluation**: INCLUDED `kls`. OMITTED others.

**Parallelization**:
- Can Run In Parallel: YES with A3, A4 (disjoint files)
- Blocks: F-wave
- Blocked By: A1

**References**:
- **Pattern**: existing `inlay_hints.c3` PARAM iteration; A1 helper signature
- **Test**: `test/inlay_hints_test.c3`
- **External**: AGENTS.md inlay_hints feature description
- **WHY**: keep test coverage tight to detect output drift

**Acceptance Criteria**:
- [ ] All `param.extra_text` reads in this file route through new helper OR documented as out-of-scope
- [ ] `test/inlay_hints_test.c3` PASS
- [ ] Full `c3c test` PASS, zero baseline diff except new tests

**QA Scenarios**:
```
Scenario: PARAM with default produces same hint text pre/post
Scenario: PARAM without default produces no default-related hint
Scenario: full c3c test green
Evidence: .sisyphus/evidence/task-a2-*.txt
```

**Commit**: YES — `refactor(inlay_hints): use ast::param_default_expr instead of extra_text`. Files: `src/lsp/inlay_hints.c3`, `test/inlay_hints_test.c3`. Pre-commit: full `c3c test`.

---

### A3. Migrate `src/lsp/signature_help.c3` PARAM default consumer

**What**: Mirror A2 against `src/lsp/signature_help.c3` and `test/signature_help_test.c3`.

**Must NOT**: same as A2; no other-file edits.

**Agent**: `unspecified-low` + `kls`.

**Parallelization**: Parallel with A2, A4. Depends A1.

**References**: A1 helper, prior `signature_help_test.c3` tests.

**Acceptance**: signature help output unchanged; full `c3c test` PASS.

**QA**: pre/post identical signature for PARAM-with-default and without; evidence in `.sisyphus/evidence/task-a3-*.txt`.

**Commit**: `refactor(signature_help): use ast::param_default_expr instead of extra_text`. Files: `src/lsp/signature_help.c3`, `test/signature_help_test.c3`. Pre-commit: full `c3c test`.

---

### A4. Migrate `src/kotlin/symbols.c3` supertype delegate consumer

**What**: Replace `extra_text == "delegate"` checks (and any related delegate-text reads) with `ast::supertype_delegate_expr` index check.

**Must NOT**: Touch other files. Do NOT alter how non-delegate supertypes are recorded.

**Agent**: `quick` + `kls`.

**Parallelization**: Parallel with A2, A3. Depends A1.

**References**: `src/kotlin/symbols.c3`, A1 helper, T7 producer code reference in `learnings.md:53-58`.

**Acceptance**: symbol-scan output for fixture-with-delegations unchanged; full `c3c test` PASS.

**QA**: per inventory, run snapshot for class-with-delegate fixture pre/post; evidence in `.sisyphus/evidence/task-a4-*.txt`.

**Commit**: `refactor(symbols): use ast::supertype_delegate_expr instead of extra_text marker`. Files: `src/kotlin/symbols.c3`, `test/symbols_test.c3`. Pre-commit: full `c3c test`.

---

### B1. ast.c3 `has_annotation_ast()` walker + arg renderer

**What to do**:
- Add to `src/kotlin/ast.c3`:
  - `fn bool has_annotation_ast(ParseResult* pr, int decl_idx, String name)` — walks pre-decl ANNOTATION_ENTRY siblings, returns true if any matches `name` (last simple-name component of dotted entry)
  - `fn String annotation_args_text(ParseResult* pr, int annot_idx, Allocator a)` — renders VALUE_ARGUMENT children as the parenthesized arg text (must be byte-identical to existing `annotation_text` for fixture set)
- Update snapshot guard test to call real renderer for ANNOTATION_ENTRY (replace stub)
- Add unit tests asserting `has_annotation_ast` matches existing `has_annotation` for every fixture

**Must NOT**:
- MUST NOT modify `has_annotation` (text-based) — both must coexist during migration
- MUST NOT remove `annotation_text` field

**Agent**: `unspecified-low` + `kls`. (Renderer byte-identity is non-trivial.)

**Parallelization**: Parallel with A1, C1 (all hit ast.c3 — SERIALIZE A1 → B1 → C1 across helper waves). Depends W0.

**References**: `ast.c3:324-330` `has_annotation`; T9 producer code in `learnings.md:64-74`; `test/parser_test.c3` annotation tests.

**Acceptance**: Two helpers, snapshot test exercising real annotation renderer, full `c3c test` PASS.

**QA**:
```
Scenario: has_annotation_ast == has_annotation for full fixture set (sweep test)
Scenario: annotation_args_text byte-identical to annotation_text for fixtures
Evidence: .sisyphus/evidence/task-b1-{sweep,bytes}.txt
```

**Commit**: `feat(ast): add has_annotation_ast walker + annotation_args_text renderer`. Files: `src/kotlin/ast.c3`, `test/dual_storage_snapshot_test.c3` or `test/migration_helpers_test.c3`. Pre-commit: full `c3c test`.

---

### B2. Migrate `src/kotlin/types.c3` annotation consumers

**What**: Replace `has_annotation()` / `annotation_text` reads in `src/kotlin/types.c3` with `has_annotation_ast` / `annotation_args_text`. Per inventory list. TDD: RED fixture parity test, then flip, then refactor.

**Must NOT**: Modify producer; alter type-inference semantics; touch other consumer files.

**Agent**: `unspecified-low` + `kls`.

**Parallelization**: Parallel with B3-B6 (all disjoint files). Depends B1.

**References**: B1 helpers; existing types.c3 annotation reads (e.g., `@Deprecated`, `@JvmStatic`, `@JvmField` checks per AGENTS.md).

**Acceptance**: types_test PASS; full `c3c test` zero diff vs baseline (except new test).

**QA**: deprecated-symbol detection fixture; @JvmStatic/@JvmField cosmetic display preserved; evidence per scenario.

**Commit**: `refactor(types): consume annotation sub-AST via has_annotation_ast`. Files: `src/kotlin/types.c3`, `test/types_test.c3`. Pre-commit: full `c3c test`.

---

### B3. Migrate `src/lsp/diagnostics.c3` annotation consumers

**What**: Same pattern, target file `src/lsp/diagnostics.c3` (deprecated usage diagnostics, etc.). RED-GREEN-REFACTOR.

**Must NOT**: Touch other files; change diagnostic message text.

**Agent**: `unspecified-low` + `kls`.

**Parallelization**: Parallel with B2, B4-B6. Depends B1.

**Acceptance**: diagnostics_test PASS; full `c3c test` zero diff.

**Commit**: `refactor(diagnostics): consume annotation sub-AST`. Files: `src/lsp/diagnostics.c3`, `test/diagnostics_test.c3`. Pre-commit: full `c3c test`.

---

### B4. Migrate `src/lsp/code_actions.c3` annotation consumers

**What**: Mirror; target `src/lsp/code_actions.c3` + `test/code_actions_test.c3`.

**Agent**: `unspecified-low` + `kls`. Parallel with B2, B3, B5, B6. Depends B1.

**Commit**: `refactor(code_actions): consume annotation sub-AST`. Pre-commit: full `c3c test`.

---

### B5. Migrate `src/lsp/semantic_tokens.c3` annotation consumers

**What**: Mirror; target `src/lsp/semantic_tokens.c3` + `test/semantic_tokens_test.c3`.

**Agent**: `unspecified-low` + `kls`. Parallel with B2-B4, B6. Depends B1.

**Commit**: `refactor(semantic_tokens): consume annotation sub-AST`. Pre-commit: full `c3c test`.

---

### B6. Migrate remaining annotation consumers

**What**: Per inventory — sweep `src/lsp/{hover,completion,inlay_hints,code_lens,call_hierarchy,definition,document_link}.c3` (only those flagged in W0 inventory as actual annotation readers). **One file per commit.** SERIALIZE within this task.

**Must NOT**: Bundle multiple files into one commit; touch files not in inventory.

**Agent**: `unspecified-low` + `kls`. Internally serial; can run while B2-B5 run in parallel only if disjoint files.

**Acceptance**: Per file: associated test PASS, full `c3c test` PASS.

**Commit pattern**: One commit per file, `refactor(<feature>): consume annotation sub-AST`.

---

### C1. ast.c3 `type_ref_name(pr, idx, alloc)` renderer + extended snapshot test

**What to do**:
- Add to `src/kotlin/ast.c3`:
  - `fn String type_ref_name(ParseResult* pr, int type_ref_idx, Allocator a)` — walks TYPE_REF children to render the type-text. Must produce **byte-identical** output to existing `type_text` for every fixture covering: simple, generic (1+ args), nested generic (`Map<String, List<Pair<Int, Boolean>>>`), nullable, function type, nullable function type (`((Int) -> String)?`), suspend function (`suspend (A, B) -> C?`), intersection bound (`<T : A & B>`), variance markers (`in`/`out`).
- Extend snapshot guard test to call real `type_ref_name` for every TYPE_REF in the fixture corpus
- If renderer cannot achieve byte-identity for some shape, document it in `.sisyphus/evidence/migration-inventory.md` and add a `string_difference_allowlist` to the snapshot test (any allowlisted divergence MUST be cleared before Wave D)

**Must NOT**:
- MUST NOT modify producer
- MUST NOT change `type_text` field

**Agent**: `deep` + `kls`. Foundation for 12 downstream tasks; renderer correctness is critical.

**Parallelization**: SERIAL with A1, B1 (all touch ast.c3). Depends W0.

**References**: T11 / T11b producer code in `learnings.md:46-54`; `test/parser_test.c3` `type_ref_*_dual_storage` tests; `ast.c3:368` existing `type_text` accessor.

**Acceptance**: Renderer + snapshot full coverage; `c3c test` PASS; allowlist (if any) documented.

**QA**:
```
Scenario: byte-identity for every TYPE_REF in fixture corpus
Scenario: renderer handles deeply nested generics (4+ levels)
Scenario: function-type variants (regular, nullable, suspend, suspend nullable)
Scenario: intersection bounds in TYPE_PARAM
Evidence: .sisyphus/evidence/task-c1-*.txt
```

**Commit**: `feat(ast): add type_ref_name renderer for TYPE_REF sub-AST`. Files: `src/kotlin/ast.c3`, `test/dual_storage_snapshot_test.c3`. Pre-commit: full `c3c test`.

---

### C2. Migrate `src/lsp/type_definition.c3` type_text consumers

**What**: Replace `type_text` reads with `type_ref_name(pr, idx, tmem)` calls. RED-GREEN-REFACTOR. Per inventory.

**Must NOT**: Touch other files.

**Agent**: `unspecified-low` + `kls`. Parallel with C3, C4 (disjoint files). Depends C1.

**Acceptance**: `test/type_definition_test.c3` PASS; full `c3c test` zero diff.

**Commit**: `refactor(type_definition): consume TYPE_REF sub-AST via type_ref_name`. Pre-commit: full `c3c test`.

---

### C3. Migrate `src/lsp/document_link.c3` type_text consumers

**Agent**: `quick` + `kls`. Parallel with C2, C4. Depends C1.

**Commit**: `refactor(document_link): consume TYPE_REF sub-AST`. Pre-commit: full `c3c test`.

---

### C4. Migrate `src/lsp/execute_command.c3` type_text consumers

**Agent**: `quick` + `kls`. Parallel with C2, C3. Depends C1.

**Commit**: `refactor(execute_command): consume TYPE_REF sub-AST`. Pre-commit: full `c3c test`.

---

### C5. Migrate remaining LSP type_text consumers (SERIAL, ONE PER COMMIT)

**Files (in order — each its own task-instance and commit)**:
1. `src/lsp/call_hierarchy.c3`
2. `src/lsp/signature_help.c3`
3. `src/lsp/inlay_hints.c3`
4. `src/lsp/completion.c3`
5. `src/lsp/definition.c3`
6. `src/lsp/hover.c3`
7. `src/lsp/semantic_tokens.c3`

**What** (each sub-task): Replace `type_text` reads with `type_ref_name`; preserve hover/completion/etc display strings exactly. RED-GREEN-REFACTOR per file.

**Must NOT**: Bundle files into one commit. Run two C5 sub-tasks in parallel (same wave, but they're different files — IF inventory confirms disjoint, parallel allowed; default to serial to honor `[W1]` lesson).

**Agent**: `unspecified-low` + `kls` per sub-task.

**Parallelization**: Default SERIAL across the 7 files (safer per W1). User may flip to parallel if confident inventory shows zero shared helpers.

**Depends**: C1.

**Commit pattern**: Per file — `refactor(<feature>): consume TYPE_REF sub-AST`. Pre-commit: full `c3c test`.

---

### C6. Migrate `src/document.c3` type_text consumers

**What**: Per inventory — likely cache key or AST traversal. If `key_lookup` reads exist, ensure `type_ref_name` produces identical key string (renderer identity guaranteed by C1).

**Must NOT**: Change cache invalidation semantics.

**Agent**: `unspecified-low` + `kls`. Depends C1. Parallel with C5 only if disjoint inventory.

**Commit**: `refactor(document): consume TYPE_REF sub-AST`. Pre-commit: full `c3c test`.

---

### C7. Migrate `src/workspace.c3` type_text consumers

**What**: Per inventory — workspace symbol index uses `type_text` heavily (20+ readers). Most likely `format_text` for symbol display + `key_lookup` for member resolution. Renderer must be byte-identical (verified by C1 snapshot). RED test: workspace symbol search returns identical results pre/post for fixture project.

**Must NOT**: Change workspace index public API; alter symbol resolution semantics.

**Agent**: `unspecified-high` + `kls`. Higher risk: cross-file lookups.

**Depends**: C1, C6.

**Acceptance**: `test/workspace_test.c3` PASS; `test/cross_file_*_test.c3` PASS (run via full `c3c test`); zero baseline diff except new tests.

**Commit**: `refactor(workspace): consume TYPE_REF sub-AST for symbol index`. Pre-commit: full `c3c test`.

---

### C8. Migrate `src/kotlin/contracts.c3` + `src/kotlin/cfg.c3` type_text consumers

**What**: Per inventory — contracts.c3 reads `type_text` for `PRED_IS_TYPE` predicates; cfg.c3 may read for branch labels. **BUT** these are 2 disjoint files — split into C8a (contracts) + C8b (cfg) — one commit each.

**Must NOT**: Modify CFG construction; modify contract effect extraction logic; alter `STDLIB_CONTRACTS` table; touch flow.c3 or types.c3.

**Agent**: `unspecified-high` + `kls` per sub-task. Serialize C8a → C8b (both touch kotlin/ closely).

**Depends**: C1.

**Acceptance**: `test/contracts_test.c3`, `test/cfg_test.c3` PASS; full `c3c test` zero diff.

**Commits**:
- C8a: `refactor(contracts): consume TYPE_REF sub-AST in predicate extraction`. File: `src/kotlin/contracts.c3`, `test/contracts_test.c3`.
- C8b: `refactor(cfg): consume TYPE_REF sub-AST`. File: `src/kotlin/cfg.c3`.

---

### C9. Migrate `src/kotlin/flow.c3` type_text consumers

**What**: Flow analysis reads `type_text` to compare narrowing facts. **CRITICAL**: do NOT touch `MAX_FACTS_PER_STATE`, per-function CFG/FlowAnalysis lifecycle, or smart-cast stability gate. Renderer identity (C1) guarantees fact-key stability.

**Must NOT**: Modify worklist solver; alter `Fact` struct layout; change `enclosing_func` map; touch contracts apply_call paths beyond the type_text read sites.

**Agent**: `unspecified-high` + `kls`.

**Depends**: C1, C8.

**Acceptance**: `test/flow_test.c3`, `test/smart_cast_diagnostic_test.c3`, `test/contracts_test.c3` all PASS; full `c3c test` zero diff.

**QA**: smart-cast scenarios (param/local val/var; cross-lambda inheritance) produce identical narrowing pre/post.

**Commit**: `refactor(flow): consume TYPE_REF sub-AST in fact comparison`. Files: `src/kotlin/flow.c3`, `test/flow_test.c3` (only if RED test added). Pre-commit: full `c3c test`.

---

### C10. Migrate `src/kotlin/types.c3` type_text consumers (STAGED, MULTI-COMMIT)

**What**: types.c3 has 50+ readers. SUB-PLAN within this task — split into 3 sequential commits:
- **C10a — inference helpers**: low-coupling readers in inference utilities (e.g., simple `TypeRef` constructions). RED test: pick 3 fixtures, assert `resolve_types` produces identical `cached_types` pre/post.
- **C10b — resolution paths**: `resolve_name_expr_type`, `resolve_dot_expr_type`, member resolution. RED test: cross-file member resolution fixture pre/post identical.
- **C10c — diagnostic-feeding paths**: type info exposed to diagnostics. RED test: smart-cast-impossible diagnostic fires in identical positions pre/post.

**Must NOT**: Alter the 10-phase `resolve_types` ordering; modify `free_type_info` (must still call `clear_flow`); touch member-property smart cast logic; alter `is_stable_for_smart_cast`; touch `member_access_is_stable`; touch dependency-resolution paths (`resolve_dep_name_by_import`, `find_dep_member_definition`); touch workspace pointer (`g_workspace`).

**Agent**: `deep` + `kls`. Highest-risk file. May warrant oracle consult mid-task if renderer divergence appears.

**Depends**: C1-C9.

**Acceptance per sub-commit**:
- [ ] `test/types_test.c3` PASS
- [ ] `test/cross_file_*_test.c3` PASS (5 files via full run)
- [ ] `test/smart_cast_diagnostic_test.c3` PASS
- [ ] `test/contracts_test.c3` PASS
- [ ] Full `c3c test` zero baseline diff except added tests

**QA**: per AGENTS.md type system + smart cast tests; cross-file member completion / hover / definition / references unchanged.

**Commits**:
- C10a: `refactor(types): consume TYPE_REF sub-AST in inference helpers`
- C10b: `refactor(types): consume TYPE_REF sub-AST in name/dot resolution`
- C10c: `refactor(types): consume TYPE_REF sub-AST in diagnostic-facing paths`
Pre-commit per: full `c3c test`.

---

### C11. Migrate `src/lsp/diagnostics.c3` type_text consumers

**What**: Diagnostics consumes resolved types from types.c3. Replace remaining `type_text` reads (those NOT covered in B3 annotation work) with `type_ref_name`.

**Must NOT**: Modify diagnostic message wording; alter `add_smart_cast_impossible_diagnostics` logic.

**Agent**: `unspecified-high` + `kls`.

**Depends**: C10.

**Acceptance**: `test/diagnostics_test.c3`, `test/smart_cast_diagnostic_test.c3` PASS; full `c3c test` zero diff.

**Commit**: `refactor(diagnostics): consume TYPE_REF sub-AST in type-display paths`. Pre-commit: full `c3c test`.

---

### C12. Migrate test fixtures

**What**: Per inventory `test_assertion`-class readers in `test/{types,workspace,contracts,parser,script_parser}_test.c3`. For each:
- If assertion is testing producer (parser correctness) → KEEP on text-field path (parser still populates it; assertion is appropriate)
- If assertion is testing consumer (semantic layer) → migrate to assert sub-AST shape
- Document choice in commit message

**Must NOT**: Delete tests; reduce coverage.

**Agent**: `unspecified-low` + `kls`.

**Depends**: C10, C11.

**Acceptance**: Full `c3c test` PASS; new test count ≥ baseline.

**Commit**: One per touched test file — `test(<area>): migrate type_text assertions to sub-AST where consumer-facing`. Pre-commit: full `c3c test`.

---

### D1. Wave D readiness assessment (NO CODE CHANGES — gated)

**What**: Produce `.sisyphus/evidence/wave-d-readiness.md`:
- For each text field, list ALL remaining readers (post-migration)
- Classify: `legitimate-text-keeper` (parser tests asserting producer output) vs `accidental-leftover` (consumer that should have migrated)
- For `accidental-leftover` readers: list, recommend follow-up tasks
- For producer side: enumerate every line that POPULATES the text fields and classify whether populate-call could be removed if all readers retired
- Risk assessment: what would break if `type_text` / `annotation_text` / `extra_text` were removed today?
- GO/NO-GO recommendation with criteria for future GO

**Must NOT**: Modify any code; modify producer; remove text fields.

**Agent**: `oracle`.

**Skills**: [`kls`].

**Skills Evaluation**:
- INCLUDED `kls`: Required — needs full understanding of producer convention
- OMITTED `git-master`: pure analysis, single doc commit
- OMITTED others.

**Depends**: C12.

**Acceptance**: Doc exists; user reviews; explicit GO required for any future Wave D removal plan.

**Commit**: `docs(migration): wave-d readiness assessment for text-field retirement`. File: `.sisyphus/evidence/wave-d-readiness.md`. Pre-commit: none (doc only).

---

## Final Review Tasks

### F1. Plan compliance + dual-storage invariant audit

**Agent**: `oracle`. Skills: [`kls`].

**What**:
- Verify every TODO in this plan was completed in the order specified (or document deviation)
- Verify dual-storage invariant: every text field still byte-identical to renderer output across full fixture corpus
- Verify NO producer changes shipped (compare `src/kotlin/parser.c3`, `src/kotlin/lexer.c3` to pre-plan baseline)
- Verify out-of-scope files (`src/deps/*`, `src/dap/*`) unchanged
- Verify `MAX_FACTS_PER_STATE`, CFG/FlowAnalysis lifecycle, smart-cast stability gate untouched

**Acceptance**: written audit report; all checks PASS.

**Commit**: `docs(migration): F1 plan compliance audit`. File: `.sisyphus/evidence/F1-audit.md`.

---

### F2. Code quality review

**Agent**: `unspecified-high`. Skills: [`kls`, `ai-slop-remover`].

**Skills Evaluation**:
- INCLUDED `kls`: KLS conventions
- INCLUDED `ai-slop-remover`: per prior plan F2 finding (dead helpers, indentation drift) — exactly the issue this plan must catch
- OMITTED others.

**What**:
- Detect dead helpers (e.g., text-based `has_annotation` if all readers gone — report, do NOT remove)
- Detect indentation drift (per prior F2 stray `}` and tab issues)
- Detect missed `?? text_fallback` defensive guards left in by mistake
- Detect inconsistent renderer call sites (some places use renderer, others still text)

**Acceptance**: report of issues + recommended cleanup tasks (cleanup tasks deferred to a follow-up plan if non-trivial; trivial cleanups committed inline).

**Commit**: `docs(migration): F2 code quality review` + optional inline cleanup commits.

---

### F3. Real manual QA

**Agent**: `unspecified-high`. Skills: [`kls`].

**What**:
- Run full `c3c test` from clean checkout; capture exit + diff vs baseline
- Build `kls` binary; run against a real Kotlin sample project (e.g., the AGENTS.md test fixture or any small open-source Kotlin project locally available)
- Smoke test:
  - hover on a typed declaration — verify type appears
  - completion in dot-expression — verify cross-file members
  - diagnostics on a deliberately-broken file — verify smart-cast-impossible fires
  - go-to-definition + find-references work cross-file
- Capture screenshots/log evidence

**Acceptance**: written manual QA report; all smoke scenarios PASS; full `c3c test` exit 0 with zero diff vs baseline (ignoring intentional new tests).

**Commit**: `docs(migration): F3 manual QA report`.

---

### F4. Scope fidelity + dual-storage invariant final check

**Agent**: `deep`. Skills: [`kls`].

**What**:
- Cross-reference every changed file against the in-scope list; flag any out-of-scope edits
- Re-run `dual_storage_snapshot_test.c3` against expanded fixture corpus
- Confirm that for each text field, EITHER all live readers route through the new helper OR remaining readers are formally documented as text-keepers (parser tests, etc.)
- Confirm Wave D readiness assessment exists and recommends future steps

**Acceptance**: written final fidelity report; user okay obtained.

**Commit**: `docs(migration): F4 scope + invariant final check`.

---

## Atomic Commit Strategy

**Rules**:
1. **One file (or one tightly-coupled call cluster) = one commit**. Bundling forbidden.
2. **Pre-commit hook**: full `c3c test` exit 0 (no `--no-verify`).
3. **Commit message format**:
   - `feat(scope): ...` — new helper additions (W0, A1, B1, C1)
   - `refactor(scope): ...` — consumer migrations (Wave A/B/C)
   - `test(scope): ...` — fixture migrations (C12)
   - `docs(scope): ...` — assessment / review docs (D1, F1-F4)
   - `chore(scope): ...` — inventory / baseline (W0)
4. **Per-commit verification command** captured in evidence: `c3c test 2>&1 | tail -50` saved to `.sisyphus/evidence/post-{task-id}-test-output.txt`.
5. **Diff against baseline**: `diff baseline-test-output.txt post-{task-id}-test-output.txt` — must show ONLY added tests.
6. **No squashing**: history must show per-file migration steps for bisectability.

---

## Plan-Level Acceptance Checklist

- [x] W0 inventory file complete; baseline captured; snapshot guard test green
- [ ] A1 helpers shipped; A2-A4 consumer migrations green and per-file committed
- [ ] B1 helpers shipped; B2-B6 consumer migrations green and per-file committed
- [ ] C1 renderer shipped with byte-identity; snapshot test covers all TYPE_REF shapes
- [ ] C2-C12 consumer migrations green and per-file committed (C5 + C8 + C10 internally split per the wave spec)
- [ ] D1 readiness assessment exists; NO text-field removal without future explicit user GO
- [ ] F1 oracle PASS — plan compliance + dual-storage invariant intact
- [ ] F2 quality PASS — no dead helpers / drift / missed guards
- [ ] F3 manual QA PASS — full test + real-project smoke
- [ ] F4 scope check PASS — zero out-of-scope edits; invariant holds
- [ ] Every commit kept `c3c test` exit 0 (verifiable via `.sisyphus/evidence/post-*` logs)
- [ ] Every commit is per-file or per-tight-cluster; zero bundled commits
- [ ] Producer files (`src/kotlin/parser.c3`, `src/kotlin/lexer.c3`) UNCHANGED relative to pre-plan baseline
- [ ] `src/deps/*.c3` and `src/dap/*.c3` UNCHANGED
- [ ] `MAX_FACTS_PER_STATE`, CFG/FlowAnalysis lifecycle, smart-cast stability gate UNCHANGED
- [ ] User explicit okay received

---

## TODO List (ADD THESE)

> CALLER: Add these TODOs using TodoWrite and execute by wave. Each TODO maps 1:1 to a task above. Internal sub-commits (C5/C8/C10) listed inline.

### Wave 0 (Start Immediately — no dependencies)
- [x] **W0**: Inventory + helpers stub + baseline + snapshot guard
  - Depends: None. Blocks: all.
  - Category: `deep`. Skills: [`kls`].
  - QA: baseline file exists exit 0; snapshot test green; smoke-mutation-revert proves guard fires.

### Wave A (After W0)
- [x] **A1**: ast.c3 `param_default_expr` + `supertype_delegate_expr` helpers
  - Depends: W0. Blocks: A2, A3, A4.
  - Category: `quick`. Skills: [`kls`].
  - QA: helpers pass focused tests; snapshot guard still green.
  - Done: commit `4d9b8b1`. 2802 PASS / 0 FAIL (+4 snapshot tests vs 2798 baseline).
- [x] **A2**: Migrate `src/lsp/inlay_hints.c3` PARAM default consumer — RETARGETED → NO-OP
  - W0 inventory shows ZERO PARAM-default reader sites in `src/lsp/inlay_hints.c3`. Plan estimate was wrong; feature does not consume PARAM defaults today. No migration needed.
- [x] **A3**: Migrate `src/lsp/signature_help.c3` PARAM default consumer — RETARGETED → NO-OP
  - W0 inventory shows ZERO PARAM-default reader sites in `src/lsp/signature_help.c3`. Same as A2; no migration needed.
- [x] **A4**: Migrate supertype-delegate consumers — RETARGETED → `src/lsp/code_actions.c3` + `src/lsp/diagnostics.c3` (split A4a + A4b)
  - W0 inventory: real consumers are `src/lsp/code_actions.c3:4503` (A4a) and `src/lsp/diagnostics.c3:2219,4419` (A4b). NOT `src/kotlin/symbols.c3` (zero consumers). Per per-file-per-commit rule, split.
  - A4a: code_actions.c3 — swap `extra_text == "delegate"` to `ast::supertype_delegate_expr(pr, idx) != ast::NO_PARENT`. Category `quick`, skills [kls].
  - A4b: diagnostics.c3 — same swap at 2 sites. Category `quick`, skills [kls].
  - Done: commits `13e6a42` (add `has_delegate_child` helper in ast.c3) + `3a81362` (use helper in `property_is_delegated`). 2802 tests pass. Self-marker sites at code_actions:4503 and diagnostics:4419 left as-is (single-node check, no helper needed).

### Wave B (After A4 to keep ast.c3 serial; or after A1 if no ast.c3 conflict)
- [x] **B1**: ast.c3 `has_annotation_ast` + `annotation_args_text`
  - Depends: W0 (and serialized after A1 due to ast.c3). Blocks: B2-B6.
  - Category: `unspecified-low`. Skills: [`kls`].
  - Done: commit `eed1a5f` adds `has_annotation_ast(pr, parent_idx, simple_name)` walking ANNOTATION_ENTRY children matching `.name == simple_name` (same idiom as existing `find_annotation`). `AstNode.has_annotation` body unchanged (dual storage preserved). `annotation_args_text` DEFERRED — `ParseResult` does not expose source bytes from `ast.c3`, so renderer cannot slice; snapshot annotation stub keeps text passthrough until Wave D removes fallback. 2802 PASS.
- [x] **B2**: NO-OP — zero `annotation_text` consumers in `src/kotlin/types.c3` per W0 inventory.
- [x] **B3**: NO-OP — zero `annotation_text` consumers in `src/lsp/diagnostics.c3` per W0 inventory (annotations only; type_text consumers remain for Wave C).
- [x] **B4**: NO-OP — zero `annotation_text` consumers in `src/lsp/code_actions.c3` per W0 inventory.
- [x] **B5**: `src/lsp/semantic_tokens.c3:246` — swap `n.annotation_text.len > 0 && n.has_annotation("Deprecated")` to `ast::has_annotation_ast(pr, idx, "Deprecated")`. Requires threading `ParseResult*` + node index into `compute_modifiers`. Category `unspecified-low`, skills [`kls`].
  - Done: commit `c04fe55`. `compute_modifiers(AstNode*)` → `compute_modifiers(ParseResult*, uint, AstNode*)`. Single caller `build_name_table` updated to pass `(pr, i, n)`. Guard dropped (helper short-circuits on no children). 2802 PASS.
- [x] **B6**: `src/lsp/hover.c3:792` (`append_jvm_annotations`) — swap guard + 4 `has_annotation` calls (JvmStatic/JvmField/JvmOverloads/JvmName) to `has_annotation_ast`. Requires threading `ParseResult*` + node index. Category `unspecified-low`, skills [`kls`].
  - Done: commit `8c4c456`. `append_jvm_annotations(DString*, AstNode*)` → `append_jvm_annotations(DString*, ParseResult*, AstNode*)`. Uses existing `ast::node_index(pr, node)` helper (already used 4× in hover.c3) to derive idx — avoids touching 12 `build_signature` callers. All 4 JVM annotation calls migrated. Guard dropped. 2802 PASS.
- [x] (B-wave bookkeeping) Wave B complete: B1+B5+B6 real commits (`eed1a5f`, `c04fe55`, `8c4c456`); B2/B3/B4 no-ops per W0 inventory. 2802 PASS preserved across all three commits. All annotation_text consumers migrated except `AstNode.has_annotation` itself (kept until Wave D removes text fallback) and snapshot stub `render_annotation_args_stub` (deferred — ast.c3 has no source access).

### Wave C (After B6; ast.c3 serialization)
- [x] **C1**: ast.c3 `type_ref_name` renderer + extended snapshot
  - Depends: W0 (serial after A1, B1). Blocks: C2-C12.
  - Category: `deep`. Skills: [`kls`].
  - Done: commit `90f5e45`. Helper `fn String type_ref_name(ParseResult* result, uint type_ref_idx, String source, Allocator alloc)` slices `source[start_offset..end_offset]` — byte-identical to legacy `type_text`, naturally covers dotted names/generics/function-types/intersections/suspend/variance/star/nullability. `ParseResult` has no `.source` field so caller must pass source (consistent with B1 `annotation_args_text` deferral). Snapshot test `test_snapshot_type_ref_dual_storage` updated: stub removed, real renderer called with fixture source, assertion proves parity. 2802 PASS.
  - **C2-C12 implication**: every consumer-site migration must have `String source` in scope. Workspace-loaded docs already carry source; in-memory ParseResults from incremental edits also retain source (verify per-file). If unreachable at a call site, escalate or pass through.
- [x] **C2**: `src/lsp/type_definition.c3` migration (4 type_text readers at :154,155,163,164 — feed `types::parse_type_text`) — `unspecified-low` + [`kls`]. Parallel C4. Depends C1.
  - Done: commit `0f9bcbb`. `resolve_type_name` gains `String source` param; `handle_type_definition` passes `doc.content`. Two file-local helpers `find_type_ref_child` + `find_return_type_ref_child` locate TYPE_REF child of PARAM/FUN_DECL. PROPERTY_DECL has no TYPE_REF child in producer yet (text-only); helpers return `NO_PARENT`, dual-storage fallthrough preserves correctness via TypeInfo branch. 2802 PASS.
- [x] **C3**: `src/lsp/document_link.c3` migration — NO-OP. W0 inventory mis-counted; zero `.type_text` readers in this file. Marked done with rationale.
- [x] **C4**: `src/lsp/execute_command.c3` migration (2 readers at :315,596 — JSON serialization `m.type_text` and `n.type_text`) — `quick` + [`kls`]. Parallel C2. Depends C1.
  - Done: commit `3dc4676`. Added `resolved_member_type_text` + `member_type_text` helpers (slight dup — followup cleanup candidate) using `workspace.get_cached_ast` + `store.get(uri).content` for source, walking to TYPE_REF child via `ast::find_child(pr, n, TYPE_REF)` then `type_ref_name`. Split `execute_query_index` into `_with_store` variant + thin wrapper for backward compat. Falls back to legacy `member.type_text` when AST/source unavailable (defensive). 2802 PASS.
- [ ] **C5a-g**: SERIAL one-per-commit:
  - [x] C5a: `src/lsp/call_hierarchy.c3` — detail now from return-type TYPE_REF via `ast::type_ref_name`; text fallback stays.
- [x] C5b: `src/lsp/signature_help.c3` — migrated return + param type rendering to `ast::type_ref_name` with text fallback
  - C5c: `src/lsp/inlay_hints.c3`
  - C5d: `src/lsp/completion.c3`
  - C5e: `src/lsp/definition.c3`
  - C5f: `src/lsp/hover.c3`
  - C5g: `src/lsp/semantic_tokens.c3`
  - Each `unspecified-low` + [`kls`]. Each Depends C1.
- [ ] **C6**: `src/document.c3` migration — `unspecified-low` + [`kls`]. Depends C1.
- [ ] **C7**: `src/workspace.c3` migration — `unspecified-high` + [`kls`]. Depends C1, C6.
- [ ] **C8a**: `src/kotlin/contracts.c3` migration — `unspecified-high` + [`kls`]. Depends C1.
- [ ] **C8b**: `src/kotlin/cfg.c3` migration — `unspecified-high` + [`kls`]. Depends C8a.
- [ ] **C9**: `src/kotlin/flow.c3` migration — `unspecified-high` + [`kls`]. Depends C1, C8b.
- [ ] **C10a**: `src/kotlin/types.c3` inference-helpers migration — `deep` + [`kls`]. Depends C1-C9.
- [ ] **C10b**: `src/kotlin/types.c3` resolution-paths migration — `deep` + [`kls`]. Depends C10a.
- [ ] **C10c**: `src/kotlin/types.c3` diagnostic-paths migration — `deep` + [`kls`]. Depends C10b.
- [ ] **C11**: `src/lsp/diagnostics.c3` type_text migration — `unspecified-high` + [`kls`]. Depends C10c.
- [ ] **C11b**: `src/lsp/code_actions.c3` type_text migration (12 readers — MISSING from original plan; added per W0 inventory) — `unspecified-low` + [`kls`]. Depends C1.
- [ ] **C12**: test fixture migration — `unspecified-low` + [`kls`]. One commit per test file. Depends C10c, C11.

### Wave D (Optional, gated)
- [ ] **D1**: Wave D readiness assessment doc — `oracle` + [`kls`]. NO code. Depends C12.

### Wave FINAL (parallel, after D1)
- [ ] **F1**: Plan compliance audit — `oracle` + [`kls`]
- [ ] **F2**: Code quality review — `unspecified-high` + [`kls`, `ai-slop-remover`]
- [ ] **F3**: Real manual QA — `unspecified-high` + [`kls`]
- [ ] **F4**: Scope + invariant final check — `deep` + [`kls`]

## Execution Instructions

1. **Wave 0** (sequential, prerequisite):
   ```
   task(category="deep", load_skills=["kls"], run_in_background=false, prompt="W0: <full task spec>")
   ```
2. **Wave A** (A1 first, then A2/A3/A4 in parallel):
   ```
   task(category="quick", load_skills=["kls"], run_in_background=false, prompt="A1: ...")
   # then PARALLEL:
   task(category="unspecified-low", load_skills=["kls"], run_in_background=false, prompt="A2: ...")
   task(category="unspecified-low", load_skills=["kls"], run_in_background=false, prompt="A3: ...")
   task(category="quick", load_skills=["kls"], run_in_background=false, prompt="A4: ...")
   ```
3. **Wave B** (B1 first, then B2-B6 — parallel for disjoint files; serial within B6):
   ```
   task(category="unspecified-low", load_skills=["kls"], run_in_background=false, prompt="B1: ...")
   # then PARALLEL B2-B5; B6 internally serial
   ```
4. **Wave C** (C1 first, then waves C-1, C-2, C-3, C-diagnostics, C-tests sequentially per dependency matrix; C5/C8/C10 internally serial per sub-step)
5. **Wave D** sequential after C12
6. **Wave FINAL** all 4 in parallel after D1
7. Final QA: verify Plan-Level Acceptance Checklist all green; obtain explicit user okay
````

---

## Summary

- **Plan path**: `.sisyphus/plans/semantic-subast-migration.md`
- **Status**: Draft displayed inline above; **not written** (plan-mode read-only)
- **Task counts**:
  - Wave 0: 1
  - Wave A: 4 (A1-A4)
  - Wave B: 6 (B1-B6; B6 internally per-file)
  - Wave C: 12 logical (C1-C12; with C5 splitting into 7 commits, C8 into 2, C10 into 3 → ~22 commits in Wave C alone)
  - Wave D: 1 (gated, no-code)
  - Wave FINAL: 4 (F1-F4)
  - **Total tasks: 28** (with Wave C internal commits, ~50 atomic commits expected)
- **Critical path**: W0 → A1 → A2/A3/A4 → B1 → B2-B6 → C1 → C2-C5 → C6 → C7 → C8 → C9 → C10 → C11 → C12 → D1 → F1-F4
- **Parallelization**: max 4 within waves; ast.c3 serialization point across A1/B1/C1; same-file parallel forbidden per `[W1]` lesson

**To save**: exit plan mode, then I will write file verbatim. Or confirm override and I will write now.

<task_metadata>
session_id: ses_22213ecd1ffeVOBrAi7KKxH1PX
task_id: ses_22213ecd1ffeVOBrAi7KKxH1PX
subagent: plan
</task_metadata>
  - B6: remaining annotation consumers (hover, completion, inlay_hints, code_lens, call_hierarchy, definition, document_link) — `unspecified-low` + [`kls`]; ONE FILE PER COMMIT, internally serial

### Wave C (After Wave B; C1 first; C5/C8/C10 internally split)
- [ ] **C1**: ast.c3 `type_ref_name` renderer + extended snapshot
  - Depends: W0 (serialized after A1, B1 due to ast.c3). Blocks: C2-C12.
  - Category: `deep`. Skills: [`kls`]. QA: byte-identity for full TYPE_REF fixture corpus.
- [ ] **C2**: `src/lsp/type_definition.c3` — `unspecified-low` + [`kls`]. Parallel C3, C4.
- [ ] **C3**: `src/lsp/document_link.c3` — `quick` + [`kls`]. Parallel C2, C4.
- [ ] **C4**: `src/lsp/execute_command.c3` — `quick` + [`kls`]. Parallel C2, C3.
- [ ] **C5**: Remaining LSP type_text consumers — SERIAL, one-per-commit:
  - C5a: `src/lsp/call_hierarchy.c3`
- [x] C5b: `src/lsp/signature_help.c3` — migrated return + param type rendering to `ast::type_ref_name` with text fallback
  - C5c: `src/lsp/inlay_hints.c3`
  - C5d: `src/lsp/completion.c3`
  - C5e: `src/lsp/definition.c3`
  - C5f: `src/lsp/hover.c3`
  - C5g: `src/lsp/semantic_tokens.c3`
  - Each: `unspecified-low` + [`kls`].
- [ ] **C6**: `src/document.c3` — `unspecified-low` + [`kls`].
- [ ] **C7**: `src/workspace.c3` — `unspecified-high` + [`kls`]. Depends C1, C6.
- [ ] **C8**: contracts + cfg — split:
  - C8a: `src/kotlin/contracts.c3` — `unspecified-high` + [`kls`]
  - C8b: `src/kotlin/cfg.c3` — `unspecified-high` + [`kls`]
- [ ] **C9**: `src/kotlin/flow.c3` — `unspecified-high` + [`kls`]. Depends C1, C8.
- [ ] **C10**: `src/kotlin/types.c3` — `deep` + [`kls`]. Depends C1-C9. Sub-commits:
  - C10a: inference helpers
  - C10b: name/dot resolution
  - C10c: diagnostic-feeding paths
- [ ] **C11**: `src/lsp/diagnostics.c3` (type display) — `unspecified-high` + [`kls`]. Depends C10.
- [ ] **C12**: test fixture migration (`test/{types,workspace,contracts,parser,script_parser}_test.c3`) — `unspecified-low` + [`kls`]. ONE FILE PER COMMIT.

### Wave D (After C12 — GATED, no code changes)
- [ ] **D1**: Wave-D readiness assessment — `oracle` + [`kls`]. Doc only.

### Wave FINAL (After ALL implementation, 4 in parallel)
- [ ] **F1**: Plan compliance + dual-storage invariant audit — `oracle` + [`kls`]
- [ ] **F2**: Code quality (dead helpers, drift, missed guards) — `unspecified-high` + [`kls`, `ai-slop-remover`]
- [ ] **F3**: Real manual QA — full `c3c test` + KLS smoke against real Kotlin project — `unspecified-high` + [`kls`]
- [ ] **F4**: Scope fidelity + dual-storage invariant final check — `deep` + [`kls`]
