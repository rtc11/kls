# F2 Quality Review

## Verdict: PASS WITH NOTES

Wave C migrations are functionally correct, stylistically consistent, and free of AI-slop indicators. Two helpers added during Wave A1 are currently unused (parked for future use per directive). Two render call sites in `execute_command.c3` deviate from the canonical fallback pattern; both are deemed safe (caller-side handling) but worth flagging as recommended cleanups.

No inline cleanups applied — all findings are either out-of-scope per F2 authority rules (Wave D / future use) or stylistic-only with no functional impact.

---

## Helpers Usage Audit

| Helper | Defined In | Call Sites (consumers) | Status |
|---|---|---|---|
| `ast::has_annotation_ast` | `src/kotlin/ast.c3` | `src/lsp/semantic_tokens.c3` (B5), `src/lsp/hover.c3` (B6) | USED (2) |
| `ast::param_default_expr` | `src/kotlin/ast.c3` | — | DEAD |
| `ast::supertype_delegate_expr` | `src/kotlin/ast.c3` | — | DEAD |
| `ast::has_delegate_child` | `src/kotlin/ast.c3` | `src/lsp/diagnostics.c3` (`property_is_delegated`) | USED (1) |
| `ast::type_ref_name` | `src/kotlin/ast.c3` | call_hierarchy, code_actions, completion, execute_command, hover, inlay_hints, signature_help, type_definition (8 files, 30+ sites) | USED |
| `ast::node_index` | `src/kotlin/ast.c3` | workspace, call_hierarchy, code_lens, completion, execute_command, hover, inlay_hints, signature_help (8 files) | USED |
| File-local `find_type_ref_child` | call_hierarchy / code_actions / completion / hover / inlay_hints / signature_help / type_definition | each file's own consumers | USED in each |
| File-local `find_return_type_ref_child` | call_hierarchy / completion / hover / inlay_hints / signature_help / type_definition | each file's own consumers | USED in each (call_hierarchy uses only return variant) |

**Dead helpers (REPORT only — keep per directive):**
- `param_default_expr` (ast.c3:482) — added in A1 (`4d9b8b1`) for future PARAM-default sub-AST consumers; current consumers still use `ast::param_default_text` (extra_text path).
- `supertype_delegate_expr` (ast.c3:500) — added in A1 (`4d9b8b1`) for future delegate-expression consumers; current consumers (`property_is_delegated`) only need the boolean predicate, which is served by `has_delegate_child`.

Both helpers compile, are tested implicitly by build, and stay reserved for the inevitable Wave D / Wave E sub-AST migrations against PARAM defaults and supertype delegates.

---

## Indentation/Style Drift

None observed. Spot-checked diffs in:
- `hover.c3` (610–739) — tab-indented, brace style consistent with surrounding code.
- `inlay_hints.c3` (400–545, 855–965) — same.
- `completion.c3` (1170–1444) — same.
- `code_actions.c3` (655–702, 1485–1502, 1660–1675, 1865–1876, 6475–6488) — same.
- `signature_help.c3` (215–248, 335–365) — same; uses if/else fallback (style choice, see Renderer Call-Site section).
- `call_hierarchy.c3` (210–256) — same; uses nested if-fallback (style choice).
- `execute_command.c3` (15–46, 280–304) — same.
- `type_definition.c3` (185–224) — same.

No stray braces, no blank-line drift, no tab/space mixing introduced by Wave C.

---

## Defensive Guard Audit

The canonical render-with-fallback pattern (per F2 directive, established by hover.c3 post-C5f) is:

```c3
String t = (ref_idx != ast::NO_PARENT && content.len > 0)
    ? ast::type_ref_name(pr, ref_idx, content, tmem)
    : "";
String rendered = t.len > 0 ? t : decl.type_text;
```

Inventory of all 30+ render sites:

| File | Sites | Pattern |
|---|---|---|
| `hover.c3` | 6 (lines 617, 630, 671, 688, 711, 733) | Canonical (parens around guard). |
| `completion.c3` | 8 (lines 1176, 1186, 1335, 1345, 1362, 1414, 1425, 1443) | Canonical (parens around guard). |
| `code_actions.c3` | 5 (lines 666, 1494, 1669, 1870, 6480) | Canonical (parens around guard). |
| `inlay_hints.c3` | 8 (lines 409, 424, 448, 536, 870, 884, 904, 959) | Canonical SEMANTICS, but `(ref_idx != NO_PARENT && content.len > 0)` written without outer parens. Equivalent precedence; cosmetic-only difference. |
| `type_definition.c3` | 2 (lines 193, 206) | No `content.len > 0` guard; relies on `type_ref_name` returning "" for OOB (`end > source.len`). Falls back via `if (type_text.len > 0)`. Functionally safe. |
| `signature_help.c3` | 2 (lines 223, 343) | `(ref != NO_PARENT && source.len > 0)` ternary, then `if (..len > 0) ... else fallback to .type_text` (if/else style instead of nested ternary). Functionally equivalent. |
| `call_hierarchy.c3` | 1 (line 245) | Bare call with `if (return_type_idx != ast::NO_PARENT)` outer guard, nested `if/else if` fallback. Functionally equivalent. |
| `execute_command.c3` | 3 (lines 41, 299, 647) | **DEVIATES** — see below. |

**Notable: `execute_command.c3`**
- Lines 41 (`resolved_member_type_text`) and 299 (`member_type_text`): return `ast::type_ref_name(...)` directly. If TYPE_REF has degenerate offsets (`end <= start` or `end > source.len`), helper returns "" and the function returns "" instead of falling back to `member.type_text`.
- Line 41 path is partly protected by line 38 precheck `if (n.type_text.len == 0) continue;`, so worst case caller sees "" instead of the cached text.
- Line 299 has no equivalent precheck; same risk.
- Line 647 (`execute_ast_at` chain rendering): bare call with `if (text.len > 0) node.set("type_text", text);` → degenerate TYPE_REFs simply omit the field. Acceptable for a debug-introspection command.

These are not bugs in practice (the parser does not emit degenerate TYPE_REF offsets in observed runs), but they break the "always fall back to text" invariant the rest of the codebase upholds. Recommendation deferred to Wave D housekeeping.

**Allocator consistency:** All 30+ sites use `tmem`. No `mem` slips. No `Allocator` parameter inconsistencies.

---

## Renderer Call-Site Consistency

Within each consumer file, all sites use the same pattern (per the table above). No file mixes e.g. `(pr, ref, content, tmem)` and `(pr, ref, source, mem)`. Argument-name aliasing (`source` vs `content`) reflects the local variable name in scope, not a semantic difference.

---

## AI-Slop Findings

None at the threshold of action. Notes:

- **Comments:** Every render site has a clear surrounding context. Wave C did not add any "increment x by 1" type comments. The `// TODO(wave-D):` comments in definition.c3 / hover.c3 / completion.c3 all carry concrete rationale (text-consumer description + migration blocker). The `// 'find_type_ref_child' only yields first TYPE_REF` notes in completion.c3 (line 841) and hover.c3 (lines 799, 834) explain a real semantic limitation — keep.
- **Defensive checks:** The `content.len > 0` / `source.len > 0` guards in canonical sites can theoretically never fire (a document without content would not be in the store), but they document intent and cost nothing. Keep.
- **Variable naming:** `pref_idx`, `ret_idx`, `aref_idx`, `cref_idx`, `sref_idx` in hover.c3 (one per case branch) are short and serve uniqueness within the switch. Acceptable.
- **Dead branches / TODO without rationale:** None found.
- **Verbose names:** None.
- **Commented-out code:** None.

---

## DEFER Comment Audit

Sample (from `git grep TODO(wave-D)` across `src/lsp/`):

| File | Count | All have rationale? |
|---|---|---|
| `src/lsp/completion.c3` | 5 | Yes — each cites the text-consumer pattern (e.g. "MemberDecl.type_text is workspace-cache state with no AST link", "TYPE_PARAM upper bounds may be intersection"). |
| `src/lsp/definition.c3` | 8 | Yes — each describes the consumer (e.g. "raw-scans return type for '<'/'?'", "scope-walk var-type lookup raw-scans type_text", "types::parse_type_text re-parses PARAM type text into TypeRef"). |
| `src/lsp/hover.c3` | 2 | Yes — TYPE_PARAM / WHERE_CONSTRAINT intersection-bound limitation. |

All DEFER comments follow the format `// TODO(wave-D): <consumer description> — <migration blocker>`. No bare `// TODO` without context.

Migration-completeness sanity:
- Every Wave-C migrated render site retains a `text fallback` (canonical or stylistic variant). Dual-storage invariant holds.
- No producer files (`src/kotlin/parser.c3`, `src/kotlin/lexer.c3`) were touched — text fields still populated alongside sub-AST.

---

## Cleanups Applied

None. All findings are either:
1. Out-of-scope per F2 authority rules (helper removal, text-field removal, producer changes), or
2. Stylistic-only with no functional impact.

---

## Cleanups Recommended (Deferred to Wave D housekeeping)

1. **`execute_command.c3:41`, `:299`** — wrap with the canonical `t.len > 0 ? t : member.type_text` fallback so degenerate TYPE_REF offsets don't drop the cached text.
2. **`inlay_hints.c3` render sites** — add outer parens around `(ref != NO_PARENT && content.len > 0)` for visual consistency with hover.c3 / completion.c3 / code_actions.c3 (cosmetic).
3. **`signature_help.c3:226-230`, `:346-350`** — collapse the if/else fallback into the canonical `String rendered = t.len > 0 ? t : decl.type_text;` ternary form (cosmetic).
4. **`call_hierarchy.c3:243-256`** — same flatten as above (cosmetic).
5. **A1 dead helpers** (`param_default_expr`, `supertype_delegate_expr`) — wire into the relevant consumers when their respective text-consumers (PARAM default text, supertype delegate text) get migrated in Wave D. Keep both helpers in ast.c3 in the meantime.

---

## Recommendation

**APPROVE Wave C as-is.** Code quality is high, patterns are consistent enough that any reader can recognize the canonical fallback shape after seeing two examples, and all DEFER comments carry actionable rationale. The two `execute_command.c3` deviations and the cosmetic style variations are documented for follow-up but do not block Wave C closure.
