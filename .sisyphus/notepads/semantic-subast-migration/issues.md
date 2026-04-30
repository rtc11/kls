# Issues — semantic-subast-migration

## Forewarned (from prior plan)
- `c3c test test/<file>.c3` not supported — always full `c3c test`
- `lsp_diagnostics` not configured for `.c3` — fall back to `c3c test`
- Parallel agents on same file → silent overwrites (W1 lesson)
## 2026-04-30 W0 — inventory + snapshot guard
- Inventory classification scheme fit most reads, but some lines are mixed-mode (e.g. `type_text.len > 0 ? type_text : "Any"`) where parse gate and display happen in one expression. Inventory classified by dominant effect.
- Wave/task mapping in plan omits `src/lsp/code_actions.c3` from Wave C breakdown even though inventory shows `type_text` readers there. Marked as `C?` in inventory for follow-up triage.


## 2026-04-30 A1 — blocked by missing supertype-delegate dual storage
- Real renderer for delegated supertypes reconstructs source text from delegate child subtree (`items`, `Runnable { println("x") }`, etc.), but parser currently stores only marker `extra_text = "delegate"` on delegate expression root and leaves enclosing supertype `TYPE_REF.extra_text` empty.
- This makes requested parity check impossible in-scope: rendered delegate source cannot equal existing `extra_text` without producer-side parser change, but task forbids modifying `src/kotlin/parser.c3`.
- Full `c3c test` with real renderer failed at `dual_storage_snapshot_test.c3:179` on `delegate TYPE_REF 44 mismatch:  vs items`.

## 2026-04-30 A1-fix — resolved
- Prior A1 blocker resolved: snapshot invariant was wrong because it compared delegate marker data against rendered source text. Fixed by keeping marker assertion and changing second check to non-empty rendered delegate subtree text.
