# Learnings — kotlin-parser-spec-gaps

## Conventions (from AGENTS.md + plan)
- C3 naming: snake_case fns/vars, PascalCase types, SCREAMING for constants/enums/faults
- Indent: tabs
- Module headers: `module kls::submodule;` first line
- Tests via `c3c test` (e.g. `c3c test test/lexer_test.c3`)
- Faults: `faultdef NAME1, NAME2;` flat list; return with `~` suffix
- Memory: `mem`/`tmem` builtins; `@pool() { ... };` for request scopes
- Slice: `[start..end]` inclusive both, `[start:length]` start+count
- Optionals: `!` rethrow, `!!` panic, `??` default, `if (try x = ...)` success unwrap, `if (catch e = ...)` failure unwrap

## DUAL-STORAGE INVARIANT (CRITICAL)
- `type_text` (241 readers) — NEVER remove/change format
- `annotation_text` (77 readers) — NEVER remove/change format
- `extra_text` (13 readers) — NEVER remove/change format
- Sub-AST additions opt-in: keep text fields populated byte-identical; readers stay on text path until explicit migration

## Pattern References (verified by Metis)
- `parser.c3:1709-1710` — supertype TYPE_REF construction (template for T11)
- `parser.c3:1736-1739` — `skip_delegation_expression()` for supertype `by` (T7 site)
- `parser.c3:1751-1769` — WHERE_CONSTRAINT pattern (T8 mirror)
- `parser.c3:1572` — PARAM default `extra_text` capture (T10 site)
- `parser.c3:1348-1357` — property delegation `extra_text="delegate"` + child (T7/T10 mirror)
- `parser.c3:881, 938` — `scan_annotation()` text capture (T9 site)
- `parser.c3:314` — AST_NODE_LIMIT (T11 may need raise to 16384)
- `lexer.c3:692-695` — `..` and `..<` longest-match dispatch (T4 site)
- `lexer.c3:452-456` — float suffix parsing (T1 site)
- `lexer.c3:284-288` — line comment skip (T2 mirror for `#!`)
- `lexer.c3:301-323` — block comment nesting (T3 site)
- `lexer.c3:257-259` — BLOCK_COMMENT trivia emit (T3 mirror)
- `lexer.c3:104-141` — `lex_normal_token` entry (T2 BOF check site)
- `token.c3:99` — KW_FIELD already exists (T6 just needs marker, not new token)

## Auto-resolved gaps (already implemented)
- `data object`, suspend fn types, `Type::class`, labeled lambdas, multi-bound `where`, property `by` — DONE
- Only **supertype** delegation is text-only, not property delegation

## Build commands
- `c3c build` — full build
- `c3c test` — full test suite
- `c3c test test/<file>.c3` — single test file

## Task T1 learnings
- `lexer.c3:452-456` float-suffix branch handles both plain floats and integer-shaped float literals with explicit suffix.
- `FLOAT_LITERAL` reused for `d`/`D`; no new token kind needed.
- `c3c test test/lexer_test.c3` passed with 2710 tests after adding suffix coverage.

## Task T6 learnings
- `parse_property_accessor()` needs save/restore state around both block-body and expression-body accessors.
- `field` marker can stay on existing `NAME_EXPR.extra_text`; no AST kind change.

## Task T7 learnings
- Supertype `by` delegate now parsed via `parse_expression(PREC_NONE)` and adopted as TYPE_REF child via `adopt_children(ref_idx, delegate_children_start)`.
- Kept `skip_delegation_expression()` function (no other callers, but leaving for safety; may remove in cleanup pass).
- TYPE_ARG nodes are still adopted by enclosing CLASS, not the TYPE_REF (existing convention preserved).
- Fault return syntax: `return NOT_FOUND~;` (tilde, not `?` — `?` is for unwrap).

## Task T8 learnings
- TYPE_PARAM bounds need dedicated bound parser; plain `skip_type_ref()` over-consumes `&` and merges intersection bounds.
- Bound children can reuse `TYPE_REF` nodes; store each bound slice on child `type_text` so tests can count bounds via child kind.
- Keep `T & Any` outside `<...>` untouched; only type-param `:` parsing should split intersection bounds.

## T9: Annotation argument sub-AST (DUAL-STORAGE)

- `build_annotation_entry` re-lexes captured @-range with sub-lexer (saves outer lexer/current/previous).
- Strategy: after dotted-name parsing leaves sub-parser at LPAREN, advance past `(`, loop `parse_value_argument()` while not at RPAREN/EOF, eat trailing `)`.
- `annotation_text` byte-identity preserved by keeping the existing `self.source[r.args_start:r.args_end - r.args_start]` write untouched. Verified: existing tests `annotation_entry_args_text_captured`, `annotation_entry_with_use_site_target`, `annotation_entry_on_class` still PASS unchanged.
- Sub-parser node positions are slice-relative — fixed up by adding `r.start_offset` to start_offset/end_offset/name_offset for all nodes added during the args parse (range `[va_children_start, node_count)`).
- VALUE_ARGUMENT nodes added by `parse_value_argument` have `parent == NO_PARENT`; we re-parent only those (top-level VAs) to ANNOTATION_ENTRY, count them, set children_start/child_count manually (cannot reuse `adopt_children` because we want only top-level VAs counted, nested expression nodes already have parents from `parse_value_argument`'s internal `adopt_children`).
- Bracketed form `@target:[A B]` skipped naturally — that path returns at line ~757 with args_start=args_end=0; sub-AST code gated by `if (self.at(LPAREN))` after restoring sub-parser to args.
- Wait — actually the sub-AST loop runs inside `build_annotation_entry` after the dotted-name parse on the re-lexed slice. For bracketed form, `r.args_start == 0` so legacy `annotation_text` write is skipped, and at that point in sub-parser, sub-lexer is positioned somewhere inside `[...]` text — but `at(LPAREN)` will be false there, so sub-AST loop also no-ops. Correct.
- `STRING_TEMPLATE_EXPR` (not LITERAL_EXPR) is what `"foo"` parses to — string literals always go through the template parser since they may contain `$`-templates.

## T10: PARAM default-value sub-AST (dual-storage)

- Pattern: replace `skip_param_default()` with `parse_expression(PREC_NONE)`; capture `extra_text` via existing offset arithmetic (byte-identical to skip-based capture). Adopt orphans via `adopt_children(idx, children_start)`.
- No sub-lexer needed (param parsing runs in main lexer) — no offset fixup like T9.
- `parse_expression` natively stops at COMMA/RPAREN (no infix precedence), matches `skip_param_default` termination semantics.
- GOTCHA: `count_kind`/`get_child` rely on `children_start` for sequential walk. CALL_EXPR is built post-hoc (args parsed first, then call wraps), so its `children_start` may precede actual child indices. Tests on CALL_EXPR sub-children should walk the full node array filtering by `parent == call_idx` instead of using `get_child`.
- 5 tests added, all pass. Total 2740 → 2745.
