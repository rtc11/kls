# Wave D Readiness Assessment

**Plan**: `.sisyphus/plans/semantic-subast-migration.md`
**Task**: D1 (Wave D readiness)
**Date**: 2026-04-30
**Verdict**: **CONDITIONAL GO — defer indefinitely; revisit only if measured perf/maintenance pain warrants**

---

## 1. Wave C Outcome Recap

### Real renderer migrations (text-fallback preserved)
| Task | File | RENDER | DEFER | GATE |
|---|---|---|---|---|
| B5/B6 | annotations | 2 | — | — |
| C2 | type_definition.c3 | 4 | — | — |
| C4 | execute_command.c3 | 2 | — | — |
| C5a | call_hierarchy.c3 | 2 | — | — |
| C5b | signature_help.c3 | 4 | — | — |
| C5c | inlay_hints.c3 | 8 | 1 | 3 |
| C5d | completion.c3 | 8 | 7 | 2 |
| C5f | hover.c3 | 8 | 2 | 1 |
| C11b | code_actions.c3 | 5 | — | 7 |
| **Total RENDER** | | **43** | | |

### NO-OP / DEFER tasks (architectural blockers)
| Task | File | Readers | Reason |
|---|---|---|---|
| C5e | definition.c3 | 15 | 8 text-consumer DEFER + 7 GATE; 0 renderer sites |
| C6 | document.c3 | 1 | dual-storage maintenance (incremental rebase) |
| C7 | workspace.c3 | 18 | cache writers (populate `MemberDecl.type_text`) |
| C8a | contracts.c3 | 1 | text propagation into `ContractEffect.type_text` |
| C8b | cfg.c3 | 0 | n/a |
| C9 | flow.c3 | 5 | all `parse_type_text` consumers |
| C10a/b/c | types.c3 | 43 | ~30+ `parse_type_text`, rest text-key compares |
| C11 | diagnostics.c3 | 22 | mostly `parse_type_text` + text-helper consumers |
| C12 | tests | ~50 | intentional dual-storage validation |

**Test count**: 2802 PASS throughout Wave C; zero regressions.

---

## 2. Architectural Blockers for Wave D

To remove `type_text`, `annotation_text`, `extra_text` from `AstNode`, we need:

### Blocker 1: Sub-AST → TypeRef builder
- **Scope**: Replace every `types::parse_type_text(n.type_text)` call with a sub-AST traversal that builds the same `TypeRef` structure.
- **Call sites affected**: ~40+ across types.c3, flow.c3, diagnostics.c3, contracts.c3, definition.c3, completion.c3.
- **Risk**: TYPE_REF sub-AST coverage gaps. Prior plan `kotlin-parser-spec-gaps.md` (T11/T11b) shipped TYPE_REF nodes for "param types, return types, generics, intersection bounds, function types incl nullable+suspend, deeply nested generics" — but the C5d/f DEFER notes flagged TYPE_PARAM upper bounds intersection (`T : A & B`) as not yet representable via `find_type_ref_child` (only first child returned). Real coverage gap: `WHERE_CONSTRAINT` bounds suffer the same limit.
- **Effort**: Large. Equivalent to writing a second parser pass.

### Blocker 2: MemberDecl / ContractEffect / Fact AST-handle extension
- **Current state**: These structs cache text fields populated from parser output. Consumers read text → `parse_type_text` → TypeRef.
- **Required change**: Replace `String type_text` with `(String uri, uint node_idx)` handle, OR with a pre-built `TypeRef`.
- **Dangling-handle risk**: ParseResult is regenerated on edit (incremental or full reparse). Stored `node_idx` becomes invalid. Need either:
  - Rebuild cache on every reparse (current cost amortized vs new full rebuild cost — needs measurement), OR
  - Stable AST identity across reparses (hard — incremental.c3 chunk-based reparse already invalidates node indices), OR
  - Pre-resolved TypeRef (loses text-key compare capability — see Blocker 3).
- **Workspace cache**: `src/workspace.c3` populates MemberDecl across all `.kt` files; cross-file ParseResult lifetime/ownership becomes the central concern.

### Blocker 3: Text-key compares
- **Pattern**: `if (pt == tp_names[t])` in types.c3 type-parameter substitution (5+ sites).
- **Reason text-based**: Type parameter NAMES match text identifiers; no TypeRef equivalent for "raw name string before resolution."
- **Migration**: Either keep small text representations alongside TypeRef (partial dual-storage retained), OR add `TypeRef.raw_name_text` field (essentially moves the text into the TypeRef struct — net zero memory savings).

### Blocker 4: Incremental edit propagation
- `src/document.c3:rebase_string_slices` updates text-field pointers on edit. If text fields are removed, the rebase logic disappears — but any code holding raw byte-offset slices into source must use a different invalidation strategy. Current sub-AST parent/child indices are NOT rebased today; if removed text fields are replaced by source-slice rendering at every read, every read-site needs `String source` threaded through.

---

## 3. Cost-Benefit Analysis

### Memory (Wave D potential gain)
- Per AstNode: 3 × `String` = 3 × 16 bytes = 48 bytes saved per node (assuming 64-bit String = ptr + len).
- Typical .kt file: ~500-2000 AST nodes. Workspace: 100s of files.
- Estimated savings: **single-digit MB across a large workspace**. Negligible.

### Performance
- **`parse_type_text` cost**: O(text length) per call. Called frequently (type resolution hot path).
- **Sub-AST traversal cost**: O(AST depth) — typically smaller, but allocation patterns differ (sub-AST traversal still allocates TypeRef trees).
- **Likely modest win** for `parse_type_text` replacement (estimate 1.2-1.5x speedup on type-heavy files), but ONLY if the sub-AST → TypeRef builder is well-implemented. Current type resolution is NOT a measured bottleneck.

### Maintenance
- **Current dual-storage cost**: Parser must populate text + sub-AST. Writers updated every time parser changes. Snapshot test (`dual_storage_snapshot_test.c3`) protects byte-identity.
- **Post-Wave-D**: Single source of truth (sub-AST). But: every consumer needs `String source` threading (already done for ~15 renderer sites in Wave C), and every text-consumer site needs sub-AST→TypeRef migration.
- **Migration cost**: Touches 80+ sites in types.c3 + diagnostics.c3 + workspace.c3 alone. Risk of regression high (these are type-resolution hot paths).
- **Net**: Wave D maintenance burden during migration > current dual-storage burden indefinitely.

### Conclusion
**Wave D is NOT worth doing today.** Cost (large migration, regression risk in type-resolution backbone) exceeds benefit (~MB memory, modest perf win, marginal maintenance simplification).

---

## 4. Risk Assessment

### Test coverage adequacy
- **2802 tests** cover lexer, parser, type inference, all LSP features, cross-file resolution, smart casts, contracts, JDWP/DAP.
- `dual_storage_snapshot_test.c3` validates parser produces byte-identical text + sub-AST.
- **Gap**: NO test asserts `sub_ast_to_typeref(node) == parse_type_text(node.type_text)`. Wave D would require this equivalence test for every TYPE_REF shape before migration.
- **Coverage of text-consumer sites**: Implicit via end-to-end LSP feature tests (cross_file_*, smart_cast_diagnostic_test, types_test). A regression in TypeRef construction would fail these — but pinpointing the cause would be hard.

### Rollback complexity
- Wave D would touch ~80 sites in types.c3 + workspace.c3 + diagnostics.c3 simultaneously to remove the field.
- Cannot do field removal incrementally (compile breaks the moment one consumer is missed).
- Per-consumer migration to sub-AST consumption could be staged BEFORE field removal, then removal in a single commit — but staging requires Blocker 1 (TypeRef builder) shipped first.

### Dangling handle risk
- Most acute for workspace.c3's MemberDecl cache: cross-file `(uri, node_idx)` handles must survive any reparse of any file in the workspace.
- Current text-copy approach is naturally stale-safe: cached strings are independent of source.
- Pre-resolved TypeRef approach is also stale-safe but loses laziness.
- **No clear win** unless a stable cross-reparse identity scheme is designed.

---

## 5. Recommendation: CONDITIONAL DEFER

### Verdict
**Wave C is the natural endpoint of this migration.** Wave D is technically feasible but:
1. Cost-benefit analysis does NOT justify the work today.
2. The DEFER notes left in Wave C (`// TODO(wave-D): ...`) are accurate technical-debt markers; they document why each site stays on text.
3. The dual-storage invariant is enforced by `dual_storage_snapshot_test.c3` — drift is mechanically prevented.

### Conditions to revisit Wave D
Reopen Wave D ONLY if at least ONE of:
1. **Measured perf bottleneck** in type resolution attributable to `parse_type_text` (profile required).
2. **Memory pressure** in large monorepo workspaces (measure: peak RSS of `kls` indexing 10K+ .kt files).
3. **Dual-storage drift bug** where parser populates text and sub-AST inconsistently, causing user-visible incorrect behavior (snapshot test should catch this — if it slips through, dual-storage is genuinely fragile).
4. **Major parser refactor** lands that already invalidates the sub-AST handles, making MemberDecl extension cheap-by-coincidence.

### What stays in Wave D scope (if reopened)
- D2: Sub-AST → TypeRef builder (replaces `parse_type_text`); ~3 weeks of focused work.
- D3: MemberDecl / ContractEffect / Fact AST-handle or pre-resolved-TypeRef extension; design choice required up-front.
- D4: Workspace cache rebuild strategy (full vs incremental).
- D5: Field removal commit (single atomic change after D2-D4 ship).
- D6: TypeRef-equivalence test additions (regression net for D2).

### Plan acceptance
The original plan acceptance criteria (lines 75-82):
- `[x]` Inventory file complete with every reader classified — DONE (W0)
- `[x]` `c3c test` exit 0 at every commit — DONE (2802 PASS throughout)
- `[x]` Zero diff vs baseline test output beyond intentional new tests — DONE
- `[x]` All in-scope `parse_only` and `format_text` readers route through new helpers OR sub-AST walking — DONE for renderer sites; documented for text-consumer sites
- `[x]` `key_lookup` readers either: keep text key (renderer guarantees identity) OR migrate to AST-index key — DONE (kept text key per documented rationale)
- `[x]` `test_assertion` readers either: migrated to assert sub-AST shape OR retain text assertions intentionally (documented) — DONE (retained per C12 rationale)
- `[x]` Wave D readiness assessment exists; no text-field removal without explicit user GO — THIS DOCUMENT
- `[ ]` F1-F4 reviews PASS — pending

All non-review acceptance criteria met. Wave C is shippable.

---

## 6. Recommended Plan Edits

1. Mark D1 done with verdict `CONDITIONAL DEFER`.
2. Leave D2-D6 sub-tasks unmentioned (they are conditional and out of scope until conditions met).
3. Update top-level acceptance criteria checkboxes per section 5 above.
4. Final wave (F1-F4) is the next active gate.

---

## 7. Summary for Final Wave Reviewers

- Wave C migrated **43 renderer sites** to sub-AST source-slice rendering with text fallback.
- Remaining text-field readers are documented with `// TODO(wave-D): <reason>` markers covering 4 distinct blocker categories (parse_type_text consumers, MemberDecl-cache writers/readers, text-key compares, intersection-bound TYPE_PARAM rendering).
- Dual-storage invariant intact; no producer changes; 2802 tests pass.
- Wave D explicitly deferred per cost-benefit analysis.
- Final wave should validate: (a) no producer modifications, (b) test count unchanged, (c) all DEFER comments cite a real Wave D blocker, (d) no broken `find_type_ref_child` / `find_return_type_ref_child` paste-helpers across the 5 consumer files (call_hierarchy, signature_help, inlay_hints, completion, hover).
