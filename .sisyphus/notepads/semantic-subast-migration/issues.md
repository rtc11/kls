# Issues — semantic-subast-migration

## Forewarned (from prior plan)
- `c3c test test/<file>.c3` not supported — always full `c3c test`
- `lsp_diagnostics` not configured for `.c3` — fall back to `c3c test`
- Parallel agents on same file → silent overwrites (W1 lesson)
## 2026-04-30 W0 — inventory + snapshot guard
- Inventory classification scheme fit most reads, but some lines are mixed-mode (e.g. `type_text.len > 0 ? type_text : "Any"`) where parse gate and display happen in one expression. Inventory classified by dominant effect.
- Wave/task mapping in plan omits `src/lsp/code_actions.c3` from Wave C breakdown even though inventory shows `type_text` readers there. Marked as `C?` in inventory for follow-up triage.

