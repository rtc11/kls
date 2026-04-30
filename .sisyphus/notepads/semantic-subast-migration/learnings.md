# Learnings — semantic-subast-migration

## Inherited from kotlin-parser-spec-gaps

### C3 Conventions (from AGENTS.md)
- snake_case fns/vars; PascalCase types; SCREAMING for constants/enums/faults
- Tabs for indent
- Module header: `module kls::submodule;` first line
- Faults: `faultdef NAME1, NAME2;` flat list; return with `~` suffix
- Memory: `mem`/`tmem` builtins; `@pool() { ... };` for request scopes
- Optionals: `!` rethrow, `!!` panic, `??` default, `if (try x = ...)`, `if (catch e = ...)`
- Slice: `[start..end]` inclusive both, `[start:length]` start+count

### Build/Test
- `c3c build` — full build
- `c3c test` — full suite (~2782 tests baseline post prior plan)
- `c3c test test/<file>.c3` NOT SUPPORTED (per issues.md [W1]) — always full
- `lsp_diagnostics` for `.c3` NOT available in this env — use `c3c test`

### Producer AST shape (from prior T7/T9/T10/T11 commits)
- TYPE_REF: text in `type_text` field; sub-AST children for params/return/generics. extra_text markers: `arg`, `function`, `function nullable`, `return nullable`, `delegate`
- ANNOTATION_ENTRY: text in `annotation_text`; VALUE_ARGUMENT children w/ full expr trees
- PARAM: default text in `extra_text`; child expression node from `parse_expression(PREC_NONE)`
- Supertype delegate: TYPE_REF child = delegate expression, extra_text="delegate" on the TYPE_REF

### DUAL-STORAGE INVARIANT (carried — CRITICAL)
- `type_text` (241 readers / 20 files) — populated byte-identical
- `annotation_text` (77 readers / 10 files) — populated byte-identical
- `extra_text` (13 readers / 4 files) — only PARAM-default + supertype-delegate uses are in scope
- Other extra_text uses (operator strings on PREFIX/POSTFIX/BINARY/ASSIGNMENT_EXPR; `*` spread on VALUE_ARGUMENT; `trailing` marker; TYPE_REF kind markers `arg`/`function`/etc) — STAY ON TEXT, no sub-AST replacement

### Key file refs
- `src/kotlin/ast.c3:140-160` — node field defs
- `src/kotlin/ast.c3:324-456` — existing helpers (`has_annotation`, `is_spread`, etc.)
- `src/kotlin/ast.c3:368` — existing `type_text` accessor
- `src/kotlin/ast.c3:324-330` — existing `has_annotation` (text-based)

### Parallel-agent gotcha (from issues.md W1 of prior plan)
- DO NOT dispatch parallel agents to the SAME file within a wave — they collide
- When two tasks both touch one file → SERIALIZE within wave
## 2026-04-30 W0 — inventory + snapshot guard
- Inventory counts from W0 scan: `type_text` 283 readers across 18 files; `annotation_text` 40 readers across 5 files; `extra_text` 197 readers across 14 files. This does NOT match plan's stated 241/77/13; inventory includes many out-of-scope marker reads on `extra_text`, and fewer `annotation_text` reads than plan claimed.
- Top 5 hottest files by field:
  - `type_text`: `test/parser_test.c3` 69, `src/kotlin/types.c3` 45, `src/lsp/completion.c3` 30, `src/workspace.c3` 28, `src/lsp/diagnostics.c3` 20.
  - `annotation_text`: `test/parser_test.c3` 35, `src/kotlin/ast.c3` 2, `src/lsp/hover.c3` 1, `src/lsp/semantic_tokens.c3` 1, `test/script_parser_test.c3` 1.
  - `extra_text`: `test/parser_test.c3` 81, `src/lsp/diagnostics.c3` 40, `src/lsp/code_actions.c3` 32, `src/kotlin/types.c3` 12, `src/kotlin/flow.c3` 10.
- Surprising pattern: many `.type_text` / `.extra_text` reads in tests and producer-adjacent helper code dominate raw counts; `annotation_text` current live consumers appear concentrated almost entirely in parser tests plus `ast::has_annotation`.
- Snapshot guard added in `test/dual_storage_snapshot_test.c3`; smoke proof confirmed guard trips on intentional renderer drift (`TYPE_REF 5 mismatch: 'T' vs 'BROKEN'`).


## 2026-04-30 W0 — Inventory contradicts plan estimates

Plan-time blast-radius numbers (241/77/13) came from Metis without actually grepping. Real W0 inventory: 283/40/197. extra_text especially undercounted because plan didn't account for operator-string OUT-OF-SCOPE noise dominating. **Lesson**: Always run W0 BEFORE drafting per-file task targets. For future plans, Metis estimates ≠ ground truth; W0/inventory is the ground truth.

## 2026-04-30 A1 — param default + supertype delegate sub-AST helpers
- Added `fn uint param_default_expr(ParseResult* pr, uint param_idx)` in `src/kotlin/ast.c3`; walks direct PARAM children and returns first non-`TYPE_REF` child, or `ast::NO_PARENT`. Child-order rule from `parse_param_with_mods`: optional type-annotation `TYPE_REF` attached first, default-expression roots adopted after `parse_expression(...)`.
- Added `fn uint supertype_delegate_expr(ParseResult* pr, uint type_ref_idx)` in `src/kotlin/ast.c3`; walks direct TYPE_REF children and returns child whose `extra_text == "delegate"`, or `ast::NO_PARENT`. Parser tags delegate expression root itself before `adopt_children(ref_idx, delegate_children_start)`.
- Real snapshot renderers in `test/dual_storage_snapshot_test.c3` now reconstruct source from sub-AST byte spans using `AstNode.start_offset` and `AstNode.end_offset`; subtree end chosen as max `end_offset` across root + descendants. This proves parser-kept text fields still match sub-AST coverage for PARAM defaults and supertype delegates.

## 2026-04-30 A1-fix — supertype-delegate marker vs source-text distinction
- Supertype-delegate has MARKER dual storage only: delegate expression child keeps `extra_text = "delegate"`; there is no parallel source-text field on enclosing supertype `TYPE_REF`.
- PARAM-default has SOURCE-TEXT dual storage: `PARAM.extra_text` stores source slice while child sub-AST stores parsed expression.
- Snapshot guard must distinguish invariants: PARAM default checks rendered source == stored source text; supertype delegate checks marker presence plus rendered subtree text non-empty. Do not conflate marker and source-text paths.
- Future Wave A4 delegate consumers in `src/lsp/code_actions.c3` and `src/lsp/diagnostics.c3` only need `extra_text == "delegate"` reads replaced with `supertype_delegate_expr(pr, idx) != NO_PARENT`; no source-text migration exists for delegate.

## 2026-04-30 A4 — delegate marker is on child, not parent
- Delegate marker set on delegate expression subtree root, then that root adopted as child of PROPERTY_DECL or supertype TYPE_REF.
- `has_delegate_child(pr, parent_idx)` fits parent-child scan for PROPERTY_DECL delegate checks.
- Self-marker checks where node already bound as child stay direct `extra_text == "delegate"`; no helper needed.

## 2026-04-30 B1 — annotation sub-AST helper
- Added `has_annotation_ast(ParseResult* result, uint parent_idx, String simple_name)` in `src/kotlin/ast.c3`; scans direct `ANNOTATION_ENTRY` children via `children_start` + `child.parent == parent_idx` and matches against child `name`, which parser already stores as simple last identifier of qualified annotation path.
- Use-site target handling stays implicit in parser shape: targets like `get:` / `set:` / `field:` live in `ANNOTATION_ENTRY.type_text`, so helper ignores them and simple-name matching stays aligned with legacy `AstNode.has_annotation` semantics.
- Dual storage still required in Wave B1: kept `AstNode.has_annotation` text-based fast path unchanged because receiver method has no `ParseResult*`; sub-AST helper exists beside it for staged consumer migration, Wave D removes text fallback later.
- Deferred `annotation_args_text` in `ast.c3`: `ParseResult` has no source slice/bytes field, so helper cannot reconstruct annotation arg text there without producer/storage changes outside B1 scope. Snapshot test keeps passthrough renderer with defer note.

## 2026-04-30 B6 — hover JVM annotation migration

- `append_jvm_annotations` in `src/lsp/hover.c3` migrated to sub-AST: added `ParseResult* pr` param, derived `idx` via `ast::node_index(pr, node)` to avoid threading idx through every `build_signature` caller (12 callers, several rely on default `node_idx=0`).
- Dropped `node.annotation_text.len == 0` early-return — `has_annotation_ast` short-circuits via children iter.
- Single caller at line 559 (inside `build_signature`) updated to pass `pr`.
- 2802 PASS.

## 2026-04-30 B5 — semantic_tokens annotation migration

- `compute_modifiers` had single caller (`build_name_table` line 122). Threaded `ParseResult* pr, uint idx` plus existing `AstNode* n`. Caller already had `pr` + loop var `i` in scope → zero-friction.
- Dropped `n.annotation_text.len > 0` guard — `has_annotation_ast` short-circuits on `child_count == 0` so guard was redundant.
- Concurrency note: parallel B6 (hover.c3) was mid-edit during B5. `git stash` raced — stash captured intermediate hover.c3 state which failed to build (`Implicitly casting 'ParseResult*' to 'AstNode*'`). Resolved by isolating semantic_tokens diff via `git diff stash@{0}^ stash@{0} -- <file> | git apply` and waiting for B6 to settle (it auto-committed during stash dance, branch went 5→6 ahead). Lesson: when parallel agents touch sibling files, use file-scoped stash or just commit-and-test-quick rather than full repo stash.
- Tests: 2802 PASS, 0 FAIL after commit `c04fe55`.

## 2026-04-30 C1 — type_ref_name renderer
- Added `type_ref_name(ParseResult* result, uint type_ref_idx, String source, Allocator alloc)` in `src/kotlin/ast.c3`. Strategy uses source-slice reconstruction from `AstNode.start_offset..end_offset` for byte-identical parity with legacy `type_text`.
- `ParseResult` still has no stored source field, so helper cannot be `ParseResult*`-only today; caller must pass `String source`. This matches prior A1/B1 finding that ast.c3 renderers needing exact text must receive source explicitly.
- Source-slice strategy naturally covers plain dotted refs, generic args, function types (`extra_text` markers `function` / `receiver` / `param` / `return`), intersection types (`intersection`), variance (`MOD_IN`/`MOD_OUT`), `suspend`, star projections, and nullable suffixes because parser already set exact TYPE_REF span in producer.
- Updated snapshot guard to replace TYPE_REF passthrough stub with real renderer call; parity assertion now proves `type_text` remains byte-identical to sub-AST span text for all fixture TYPE_REF nodes.

## 2026-04-30 C2 — type_definition migration
- Migrated 4 readers in `src/lsp/type_definition.c3:resolve_type_name` (was lines 154/155/163/164) from `n.type_text` to `ast::type_ref_name(pr, type_ref_idx, source, tmem)`.
- Source threading: added `String source` param to `resolve_type_name`; sole caller `handle_type_definition` already had `doc.content` in scope, zero-friction pass-through.
- Idx threading: `pr` and loop var `i` already in scope. But helper requires a TYPE_REF idx, while loop visits decl nodes (PARAM/FUN_DECL/PROPERTY_DECL/...). Added two file-local helpers:
  - `find_type_ref_child(pr, decl_idx)` — first direct TYPE_REF child (covers PARAM type annotations); scans `pr.nodes` for `child.parent == decl_idx && kind == TYPE_REF`.
  - `find_return_type_ref_child(pr, fun_idx)` — TYPE_REF child of FUN_DECL with `extra_text == "return"` (matches parser marker at `src/kotlin/parser.c3:1243`).
- Producer gap noted: PROPERTY_DECL at `parser.c3:1382` does NOT call `attach_type_ref_child_from_text` (text-only). My helpers return `ast::NO_PARENT` for PROPERTY_DECL → empty text → fall through to TypeInfo branch. Dual-storage invariant preserves field for any future producer-side completion before Wave D removes text path.
- Pattern note: when caller-loop visits decls but reader needs a TYPE_REF, prefer two narrow finder helpers per call site (annotation vs return) over a generic "any TYPE_REF child" helper — semantics differ (annotation vs return marker).
- Concurrency: encountered unrelated WIP in `src/lsp/execute_command.c3` + test that broke baseline (`Implicitly casting WorkspaceIndex* to DocumentStore*`). Stashed via path-scoped `git stash push -- src/lsp/execute_command.c3 test/execute_command_test.c3` before testing my isolated change. Reapplied after commit. Lesson: ALWAYS `git status` first; path-scoped stash beats full-tree stash when foreign WIP is present.
- `c3c test`: 2802 PASSED, 0 failed, 0 skipped.
- Commit: `0f9bcbb`.

## 2026-04-30 C4 — execute_command migration
- `execute_query_index` now threads `store` and resolves member `type` via cached AST + `ast::type_ref_name(pr, ast::node_index(pr, type_node), source, tmem)`; fallback stays `member.type_text` when cache/source missing.
- `execute_ast_at` now uses `source` for offset lookup and `ast::type_ref_name(pr, cur, source, tmem)` for chain entries; helper reuses existing `ast::find_child` + `ast::node_index` path.
- `c3c test`: 2802 PASS, 0 FAIL.

## 2026-04-30 C5a — call_hierarchy migration
- `handle_prepare`, `collect_incoming_from_ast`, and `collect_outgoing_from_function` now thread `String source` into `build_item`.
- `build_item` resolves FUN_DECL / CONSTRUCTOR_DECL detail from return-type TYPE_REF via `find_return_type_ref_child(pr, fun_idx)` + `ast::type_ref_name(pr, return_type_idx, source, tmem)`.
- Legacy `node.type_text` fallback stays for empty source or missing TYPE_REF, so detail JSON stays byte-identical.
- `c3c test`: 2802 PASS, 0 FAIL.

## 2026-04-30 C5b — signature_help migration
- `build_signature_help` now threads existing `source` into `append_params` and resolves FUN_DECL return type through `find_return_type_ref_child(pr, decl_idx)` + `ast::type_ref_name(pr, return_type_idx, source, tmem)`.
- `append_params` now resolves PARAM annotations through `find_type_ref_child(pr, i)` + `ast::type_ref_name(pr, type_ref_idx, source, tmem)`.
- Legacy `decl.type_text` / `child.type_text` fallback stays when source empty or TYPE_REF missing, so signature labels stay byte-identical.

## 2026-04-30 C5c — inlay_hints migration
- Migrated 8 of 12 non-gate `.type_text` reader sites in `src/lsp/inlay_hints.c3` to dual-storage with `ast::type_ref_name` + text fallback. File-local helpers `find_type_ref_child` + `find_return_type_ref_child` pasted from C5b template.
- Source threading: ZERO new params. All migrated reader fns already had `String content` in scope (`infer_type_from_initializer`, `infer_dot_expr_type`, `infer_expr_type_string`, `collect_smart_cast_hints`). The C5b/C5a "thread `String source`" pattern was unnecessary here — `content` IS the source. Kept variable name `content` to avoid invasive rename.
- Per-site decisions:
  - 301 (PROPERTY_DECL gate), 589 (FUN_DECL gate), 1201 (lambda PARAM gate): **STAYED ON TEXT** (presence checks; migrating to `find_type_ref_child(...) != NO_PARENT` doesn't help dual-storage retirement since text path stays alive equally either way). Future Wave D needs to migrate these alongside text-field deletion.
  - 406 (CALL_EXPR initializer → fn return): `find_return_type_ref_child` (decl is FUN_DECL via `is_call=true`).
  - 416 (NAME_EXPR initializer → var type): `find_type_ref_child` (decl is PROPERTY_DECL/PARAM via `is_call=false`).
  - 435 (TYPE_CAST_EXPR initializer): `find_type_ref_child(pr, cast_idx)` — TYPE_CAST_EXPR has TYPE_REF child via `attach_type_ref_child_from_text`.
  - 518 (DOT_EXPR fallback decl type): `find_type_ref_child` (decl from `is_call=false` lookup).
  - 845 (CALL_EXPR in `infer_expr_type_string`): `find_return_type_ref_child` (FUN_DECL).
  - 852 (NAME_EXPR in `infer_expr_type_string`): `find_type_ref_child`.
  - 866 (TYPE_CAST_EXPR in `infer_expr_type_string`): `find_type_ref_child(pr, idx)` — `idx` already in scope as fn param.
  - 916 (TYPE_CHECK_EXPR `cond.type_text`): `find_type_ref_child(pr, condition_idx)` — verified `attach_type_ref_child_from_text` at parser.c3:2321 + 3996.
  - 1361 (PARAM type_text inside `resolve_lambda_callee_param_type`): **DEFERRED**. This fn has no `source` in scope. Threading would require adding `String source` to fn signature; sole external caller `src/lsp/hover.c3:169` (`resolve_lambda_param_type` chain) would also need the param — but hover.c3 modification is forbidden by C5c scope. Legacy text path retained. Recommend bundling 1361 with C5f (hover migration) which already touches hover.c3.
- Build clean, 2802 PASS / 0 FAIL preserved.
