# F4 Scope Fidelity + Dual-Storage Invariant Final Check

## Verdict: REJECT

## In-Scope File Audit

Touched files since `75116f4..HEAD`:

- ❌ `.sisyphus/evidence/F1-audit.md` — out-of-scope
- ❌ `.sisyphus/evidence/F3-qa.md` — out-of-scope
- ❌ `.sisyphus/evidence/F3-test-output.txt` — out-of-scope
- ❌ `.sisyphus/evidence/wave-d-readiness.md` — out-of-scope doc artifact
- ❌ `.sisyphus/notepads/semantic-subast-migration/issues.md` — out-of-scope
- ❌ `.sisyphus/notepads/semantic-subast-migration/learnings.md` — out-of-scope
- ❌ `.sisyphus/plans/semantic-subast-migration.md` — out-of-scope **and conflicts with Work Context read-only rule**
- ✅ `src/kotlin/ast.c3`
- ✅ `src/lsp/call_hierarchy.c3`
- ✅ `src/lsp/code_actions.c3`
- ✅ `src/lsp/completion.c3`
- ✅ `src/lsp/definition.c3`
- ✅ `src/lsp/diagnostics.c3`
- ✅ `src/lsp/execute_command.c3`
- ✅ `src/lsp/hover.c3`
- ✅ `src/lsp/inlay_hints.c3`
- ✅ `src/lsp/semantic_tokens.c3`
- ✅ `src/lsp/signature_help.c3`
- ✅ `src/lsp/type_definition.c3`
- ❌ `test/dual_storage_snapshot_test.c3` — not in declared in-scope test list, though explicitly required by W0 guardrail

Producer / forbidden area audit:

- `src/kotlin/parser.c3` — no touches since baseline in git diff; producer unchanged
- `src/kotlin/lexer.c3` — no touches since baseline in git diff; producer unchanged
- `src/deps/*` — no touches
- `src/dap/*` — no touches

Assessment:

- Code-scope fidelity for semantic-layer files: **mostly good**
- Strict file-scope fidelity against declared in-scope list: **failed** due to multiple `.sisyphus/*` writes and `test/dual_storage_snapshot_test.c3`

## Dual-Storage Invariant

Snapshot guard:

- `test/dual_storage_snapshot_test.c3` exists
- `c3c test` at HEAD: **2802 passed, 0 failed, 0 skipped**
- Snapshot tests observed passing:
  - `test_snapshot_annotation_dual_storage`
  - `test_snapshot_param_default_dual_storage`
  - `test_snapshot_supertype_delegate_dual_storage`
  - `test_snapshot_type_ref_dual_storage`

Live field readers in `src/`:

- `.type_text` — **216** matches across **16** files
- `.annotation_text` — **14** matches across **3** files
- `.extra_text` — **204** matches across **18** files

Per-field final check:

- `type_text`
  - Live readers: many (`src/kotlin/types.c3`, `src/lsp/diagnostics.c3`, `src/lsp/completion.c3`, `src/workspace.c3`, etc.)
  - Parser still populates it at many sites (e.g. `src/kotlin/parser.c3:947,1242,1382,1619,1703,2437,2704,4140,4189,4703`)
  - Status: **alive and still producer-populated**
- `annotation_text`
  - Live readers: `src/kotlin/ast.c3` (`AstNode.has_annotation`) and `src/document.c3` rebase maintenance
  - Parser still populates it (e.g. `src/kotlin/parser.c3:953,1064,1137,1281,1420,1456,1516,1604,4653`)
  - Status: **alive and still producer-populated**
- `extra_text`
  - Live readers: many in `src/kotlin/flow.c3`, `src/kotlin/types.c3`, `src/kotlin/contracts.c3`, `src/lsp/diagnostics.c3`, `src/lsp/code_actions.c3`, `src/kotlin/ast.c3`, etc.
  - Parser still populates it broadly (e.g. delegate markers, operators, receiver text, nullability markers)
  - Status: **alive and still producer-populated**

Invariant result: **PASS** at HEAD. No field is dead. Producer-side storage remains active.

## Wave D Readiness

- `.sisyphus/evidence/wave-d-readiness.md` exists
- Verdict is explicit: **"CONDITIONAL GO — defer indefinitely; revisit only if measured perf/maintenance pain warrants"**
- Real blockers documented:
  1. Sub-AST → `TypeRef` builder gap
  2. `MemberDecl` / `ContractEffect` / `Fact` AST-handle lifetime problem
  3. Text-key compare dependence
  4. Incremental edit propagation / stale-handle risk

Status: **PASS**

## Commit History Quality

- Commits since baseline: **25**
- Message format audit against allowed patterns `feat(scope):`, `refactor(scope):`, `docs(scope):`, `chore(scope):`
- Violations found: **0**

Observed history quality:

- Per-task granularity looks clean
- No local evidence of squash-style “mega commit” history
- Force-push history is **not verifiable from local log alone**

Status: **PASS with note** (format clean; force-push unverifiable)

## Acceptance Criteria Tally

1. **Inventory file complete with every reader classified** — **MET**
   - Evidence: `.sisyphus/evidence/migration-inventory.md`

2. **`c3c test` exit 0 at every commit (verified per task)** — **PARTIAL**
   - HEAD is green
   - F1/F3/Wave-D docs claim continuous green runs
   - This review did **not** replay every historical commit

3. **Zero diff vs baseline test output beyond intentional new tests** — **MET**
   - Evidence: F3 diff shows only +4 snapshot tests and updated totals `2798 -> 2802`

4. **All in-scope `parse_only` and `format_text` readers route through new helpers OR sub-AST walking** — **NOT MET (literal reading)**
   - Many in-scope readers remain text-consumers by deliberate Wave-D deferral (`types.c3`, `flow.c3`, `contracts.c3`, `diagnostics.c3`, `definition.c3`, `workspace.c3`)
   - Those sites are documented, but criterion text says “all”

5. **`key_lookup` readers either keep text key or migrate to AST-index key** — **MET**
   - Evidence: Wave-D readiness and C5/C7 notes document retained text-key rationale

6. **`test_assertion` readers either migrated to sub-AST shape OR retain text assertions intentionally (documented)** — **MET**
   - Evidence: C12 documented intentional retention; snapshot test remains active

7. **Wave D readiness assessment exists; no text-field removal without explicit user GO** — **MET**
   - Evidence: readiness doc exists; producer fields still populated

8. **F1-F4 reviews PASS** — **NOT MET**
   - `F1-audit.md` exists and passes
   - `F2-quality.md` exists and passes with notes
   - `F3-qa.md` exists and passes with notes
   - F4 verdict is **REJECT**

## Renderer-vs-Fallback Spot-Check

Five migrated sites checked:

1. `src/lsp/signature_help.c3:223-229`
   - `String t = ... type_ref_name(...)`: **No** (uses `return_type_text` variable)
   - `String rendered = t.len > 0 ? t : decl.type_text`: **No** (inline fallback)
   - Tests would fail if output regressed: **Yes** (`test/signature_help_test.c3` asserts `name: String`, `a: Int`, `: String`)
   - Tests prove fallback branch executes: **No direct proof**

2. `src/lsp/inlay_hints.c3:423-427`
   - `String t = ... type_ref_name(...)`: **Yes**
   - `String rendered = ...`: **No** (inline `return t.len > 0 ? t : decl.type_text`)
   - Output covered by tests: **Yes** (`test/inlay_hints_test.c3` asserts `: Int`, `: String`, function-return-derived hints)
   - Tests prove fallback branch executes: **No direct proof**

3. `src/lsp/completion.c3:1443-1446`
   - `String t = ... type_ref_name(...)`: **Yes**
   - `String rendered = t.len > 0 ? t : prop_node.type_text`: **Yes**
   - Output covered by tests: **Yes** (`test/cross_file_completion_test.c3` asserts detail `Int` / `String`)
   - Tests prove fallback branch executes: **No direct proof**

4. `src/lsp/code_actions.c3:1493-1498`
   - `String t = ... type_ref_name(...)`: **No** (uses `dn_t` / `dn_rendered`)
   - Equivalent fallback variable exists: **Yes** (`dn_rendered`)
   - Output covered by tests: **Yes** (`test/code_actions_test.c3` data-class generation asserts generated signatures with `String` / `Int`)
   - Tests prove fallback branch executes: **No direct proof**

5. `src/lsp/hover.c3:616-633`
   - `String t = ... type_ref_name(...)`: **No** (uses `pt` / `rt`, then `prendered` / `rendered`)
   - Equivalent fallback variable exists: **Yes**
   - Output covered by tests: **Yes** (`test/hover_test.c3` asserts `fun greet`, `name: String`, `: String`, `val count: Int`)
   - Tests prove fallback branch executes: **No direct proof**

Conclusion:

- Renderer + fallback pattern exists broadly, but not always in the exact literal variable names requested
- Tests strongly cover rendered output
- Tests do **not** directly demonstrate fallback branch execution at these sites

## Semantic-Layer Immutability

Git diff audit over `src/kotlin/flow.c3 src/kotlin/cfg.c3 src/kotlin/contracts.c3` since baseline:

- `MAX_FACTS_PER_STATE` — absent from changed hunks
- `STDLIB_CONTRACTS` — absent from changed hunks
- `clear_flow` / `is_stable_for_smart_cast` live in `src/kotlin/types.c3`; F1 also reports no touches there since baseline

Result:

- `flow.c3`, `cfg.c3`, `contracts.c3` immutability check: **PASS**
- `types.c3` smart-cast lifecycle/stability logic: **no touched-file evidence in this review; corroborated by F1 PASS**

## Cross-Reviewer Concurrence

- **F1 present**: `.sisyphus/evidence/F1-audit.md`
  - Agreement: producer immutability, snapshot status, no deps/dap drift, tests green
  - Disagreement: F1 says “Issues Found: None” and effectively treats scope as clean; this F4 review flags strict scope violations for `.sisyphus/plans/semantic-subast-migration.md`, multiple `.sisyphus/evidence/*` / notepad writes, and `test/dual_storage_snapshot_test.c3`
- **F2 present**: `.sisyphus/evidence/F2-quality.md`
  - Agreement: migrated render sites mostly follow renderer+fallback discipline; `execute_command.c3` has minor pattern deviations worth noting
  - No disagreement on code quality significance; this F4 review focuses on scope/process fidelity rather than implementation style
- **F3 present**: `.sisyphus/evidence/F3-qa.md`
  - Agreement: build/test/binary smoke all pass
  - No substantive disagreement

## Issues Found

1. **Scope violation** — multiple touched files are outside declared in-scope list (`.sisyphus/evidence/*`, `.sisyphus/notepads/*`, plan file, snapshot test file).
2. **Plan file was modified since baseline** — conflicts with current Work Context rule that plan files are sacred/read-only.
3. **Acceptance criterion §78 not literally satisfied** — several in-scope text-consumer readers remain deferred to Wave D rather than migrated.
4. **Acceptance criterion §82 not satisfied** — F4 does not pass.
5. **Fallback-branch coverage gap** — output is tested, but direct exercise of text-fallback branches is not proven by targeted tests.

## Final Recommendation

**Reject final gate for strict process fidelity.**

Code health at HEAD looks good: build passes, full suite passes, producer-side dual storage remains intact, commit message discipline is clean, and Wave D readiness is documented.

But final gate asked for skeptical fidelity review, and on that bar this branch still has unresolved process failures:

- out-of-scope file churn exists,
- sacred plan file was modified earlier in the series,
- one acceptance criterion is only partially supported,
- one acceptance criterion is not met,
- sibling review set is incomplete.
