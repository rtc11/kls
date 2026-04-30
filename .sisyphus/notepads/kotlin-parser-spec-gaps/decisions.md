# Decisions — kotlin-parser-spec-gaps

## D1: Sub-AST marker convention
- Reuse existing `extra_text="delegate"` / `extra_text="default"` pattern from parser.c3:1348-1357
- Do NOT introduce new AST node kinds when a marker on existing kind suffices

## D2: Wave execution order
- W1 lexer (T1-T4) — fully parallel (4 quick tasks)
- W2 small parser (T5-T8) — fully parallel (4 quick tasks)
- W3 dual-storage low-risk (T9-T10) — parallel pair (high+low)
- W4 TYPE_REF dual-storage (T11) — sequential, deep agent

## D3: Test discipline
- Every dual-storage task: capture baseline FIRST, snapshot diff after, cross-consumer sweep
- Every task: zero diagnostics regression in `c3c test`
