# Decisions — semantic-subast-migration

(append timestamped entries as they arise)

## 2026-04-30 W0-postmortem — Wave A scope correction

**Real inventory (W0) vs plan estimates diverged for Wave A.**

Plan assumed PARAM-default readers in `src/lsp/inlay_hints.c3` (A2) and `src/lsp/signature_help.c3` (A3). Inventory shows ZERO PARAM-default reader sites in either file (only operator-string `extra_text` use, out of scope). Plan assumed supertype-delegate readers in `src/kotlin/symbols.c3` (A4). Inventory shows ZERO; real consumers are `src/lsp/code_actions.c3:4503` and `src/lsp/diagnostics.c3:2219,4419`.

**Decision (Option 1 — retarget, do not redraft):**

- A1: ast.c3 add `param_default_expr(pr, idx)` + `supertype_delegate_expr(pr, idx)` helpers; rewrite ast.c3:448,456 PARAM-default readers via helpers; replace `render_param_default_stub` and `render_supertype_delegate_stub` in test/dual_storage_snapshot_test.c3 with real renderers (call helpers, return text via stable allocator). Snapshot guard then proves dual-storage parity.
- A2: RETARGET → no-op. Document zero in-scope consumers in inlay_hints.c3. Mark `- [x]` with note.
- A3: RETARGET → no-op. Same as A2 for signature_help.c3.
- A4: RETARGET → migrate `src/lsp/code_actions.c3:4503` and `src/lsp/diagnostics.c3:2219,4419` (`extra_text == "delegate"` → `supertype_delegate_expr(pr, idx) != ast::NO_PARENT` or equivalent boolean helper `has_supertype_delegate(pr, idx)`). Two consumer files = two commits per per-file-per-commit rule. Rename A4 → A4a (code_actions) + A4b (diagnostics).

**Wave B and C target lists also need spot-check before dispatch** — annotation_text inventory: ast.c3(2)/hover.c3(1)/semantic_tokens.c3(1) match plan's B2-B5. type_text: 18 files match plan's C series. No expected mismatches.

**Why Option 1**: migration plan should match real reader graph, not aspirational feature work. A2/A3 phantom files don't justify Prometheus re-draft.
