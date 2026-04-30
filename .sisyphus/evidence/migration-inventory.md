# Migration Inventory — semantic sub-AST migration

Generated from read occurrences of `.type_text`, `.annotation_text`, `.extra_text` in `src/**/*.c3` and `test/**/*.c3`, excluding `src/deps/*.c3` and `src/dap/*.c3`. Producer writes (direct field assignment / address-of mutation such as `rebase_slice(&node.field, ...)`) skipped.

## Out-of-scope directories

- `src/deps/*.c3` — skipped per W0 spec
- `src/dap/*.c3` — skipped per W0 spec

## Totals

- `type_text`: 283 reader occurrence(s) across 18 file(s)
- `annotation_text`: 40 reader occurrence(s) across 5 file(s)
- `extra_text`: 197 reader occurrence(s) across 14 file(s)

## type_text readers (Wave C)

Total: 283 reader occurrence(s) across 18 file(s).

### src/kotlin/ast.c3 (count: 1)
- src/kotlin/ast.c3:368 — `format_text` — wave C — target C1 — context: `return self.type_text;`

### src/kotlin/contracts.c3 (count: 1)
- src/kotlin/contracts.c3:388 — `parse_only` — wave C — target C8 — context: `out.type_text = n.type_text;`

### src/kotlin/flow.c3 (count: 4)
- src/kotlin/flow.c3:661 — `parse_only` — wave C — target C9 — context: `cond_type_texts[cond_type_count++] = c.type_text;`
- src/kotlin/flow.c3:662 — `parse_only` — wave C — target C9 — context: `TypeRef tt = types::parse_type_text(c.type_text);`
- src/kotlin/flow.c3:686 — `parse_only` — wave C — target C9 — context: `TypeRef t = types::parse_type_text(cn.type_text);`
- src/kotlin/flow.c3:1031 — `parse_only` — wave C — target C9 — context: `TypeRef t = types::parse_type_text(effect.type_text);`

### src/kotlin/types.c3 (count: 45)
- src/kotlin/types.c3:810 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:811 — `parse_only` — wave C — target C10 — context: `info.node_types[i] = parse_type_text(node.type_text);`
- src/kotlin/types.c3:816 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:817 — `parse_only` — wave C — target C10 — context: `info.node_types[i] = parse_type_text(node.type_text);`
- src/kotlin/types.c3:822 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:823 — `parse_only` — wave C — target C10 — context: `info.node_types[i] = parse_type_text(node.type_text);`
- src/kotlin/types.c3:828 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:829 — `parse_only` — wave C — target C10 — context: `info.node_types[i] = parse_type_text(node.type_text);`
- src/kotlin/types.c3:834 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:835 — `parse_only` — wave C — target C10 — context: `info.node_types[i] = parse_type_text(node.type_text);`
- src/kotlin/types.c3:877 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:878 — `parse_only` — wave C — target C10 — context: `TypeRef cast_type = parse_type_text(node.type_text);`
- src/kotlin/types.c3:1326 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:1327 — `parse_only` — wave C — target C10 — context: `TypeRef cast_type = parse_type_text(node.type_text);`
- src/kotlin/types.c3:1430 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) return parse_type_text(m.type_text);`
- src/kotlin/types.c3:1430 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) return parse_type_text(m.type_text);`
- src/kotlin/types.c3:1435 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) return parse_type_text(m.type_text);`
- src/kotlin/types.c3:1435 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) return parse_type_text(m.type_text);`
- src/kotlin/types.c3:1710 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) {`
- src/kotlin/types.c3:1711 — `parse_only` — wave C — target C10 — context: `return parse_type_text(m.type_text);`
- src/kotlin/types.c3:2110 — `parse_only` — wave C — target C10 — context: `String rt_text = other_pr.nodes[fidx].type_text;`
- src/kotlin/types.c3:2404 — `parse_only` — wave C — target C10 — context: `fn_param_text = pr.nodes[j].type_text;`
- src/kotlin/types.c3:2453 — `parse_only` — wave C — target C10 — context: `String pt = child.type_text;`
- src/kotlin/types.c3:2599 — `parse_only` — wave C — target C10 — context: `String pt = child.type_text;`
- src/kotlin/types.c3:2742 — `parse_only` — wave C — target C10 — context: `String pt = child.type_text;`
- src/kotlin/types.c3:3218 — `parse_only` — wave C — target C10 — context: `if (n.type_text.len == 0) continue;`
- src/kotlin/types.c3:3223 — `parse_only` — wave C — target C10 — context: `TypeRef target = parse_type_text(pr.nodes[matched].type_text);`
- src/kotlin/types.c3:3399 — `parse_only` — wave C — target C10 — context: `if (node.type_text.len > 0) {`
- src/kotlin/types.c3:3400 — `parse_only` — wave C — target C10 — context: `return parse_type_text(node.type_text);`
- src/kotlin/types.c3:3480 — `parse_only` — wave C — target C10 — context: `if (child.type_text.len > 0) {`
- src/kotlin/types.c3:3481 — `parse_only` — wave C — target C10 — context: `TypeRef declared = parse_type_text(child.type_text);`
- src/kotlin/types.c3:3496 — `parse_only` — wave C — target C10 — context: `if (child.type_text.len > 0) {`
- src/kotlin/types.c3:3497 — `parse_only` — wave C — target C10 — context: `TypeRef declared = parse_type_text(child.type_text);`
- src/kotlin/types.c3:3522 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) return parse_type_text(m.type_text);`
- src/kotlin/types.c3:3522 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) return parse_type_text(m.type_text);`
- src/kotlin/types.c3:4025 — `parse_only` — wave C — target C10 — context: `String pt = m.type_text;`
- src/kotlin/types.c3:4168 — `parse_only` — wave C — target C10 — context: `String pt = child.type_text;`
- src/kotlin/types.c3:4369 — `parse_only` — wave C — target C10 — context: `String pt = child.type_text;`
- src/kotlin/types.c3:4538 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) {`
- src/kotlin/types.c3:4539 — `parse_only` — wave C — target C10 — context: `TypeRef raw = parse_type_text(m.type_text);`
- src/kotlin/types.c3:4599 — `parse_only` — wave C — target C10 — context: `if (m.type_text.len > 0) {`
- src/kotlin/types.c3:4600 — `parse_only` — wave C — target C10 — context: `TypeRef raw = parse_type_text(m.type_text);`
- src/kotlin/types.c3:5282 — `parse_only` — wave C — target C10 — context: `String pt = pr.nodes[j].type_text;`
- src/kotlin/types.c3:5309 — `parse_only` — wave C — target C10 — context: `String pt = pr.nodes[j].type_text;`
- src/kotlin/types.c3:5313 — `parse_only` — wave C — target C10 — context: `String rt = pr.nodes[fun_decl_idx].type_text;`

### src/lsp/call_hierarchy.c3 (count: 2)
- src/lsp/call_hierarchy.c3:228 — `key_lookup` — wave C — target C5 — context: `} else if (node.type_text.len > 0) {`
- src/lsp/call_hierarchy.c3:229 — `key_lookup` — wave C — target C5 — context: `item.set("detail", node.type_text);`

### src/lsp/code_actions.c3 (count: 14)
- src/lsp/code_actions.c3:1475 — `parse_only` — wave C — target C? — context: `if (cap_type.len == 0) cap_type = dn.type_text.len > 0 ? dn.type_text : "Any";`
- src/lsp/code_actions.c3:1475 — `parse_only` — wave C — target C? — context: `if (cap_type.len == 0) cap_type = dn.type_text.len > 0 ? dn.type_text : "Any";`
- src/lsp/code_actions.c3:1644 — `parse_only` — wave C — target C? — context: `enclosing_decl_types[enclosing_decl_count] = n.type_text.len > 0 ? n.type_text : "Any";`
- src/lsp/code_actions.c3:1644 — `parse_only` — wave C — target C? — context: `enclosing_decl_types[enclosing_decl_count] = n.type_text.len > 0 ? n.type_text : "Any";`
- src/lsp/code_actions.c3:1840 — `parse_only` — wave C — target C? — context: `prop_types[prop_count] = n.type_text.len > 0 ? n.type_text : "Any";`
- src/lsp/code_actions.c3:1840 — `parse_only` — wave C — target C? — context: `prop_types[prop_count] = n.type_text.len > 0 ? n.type_text : "Any";`
- src/lsp/code_actions.c3:2554 — `parse_only` — wave C — target C? — context: `if (prop.type_text.len > 0) return null;`
- src/lsp/code_actions.c3:3329 — `parse_only` — wave C — target C? — context: `if (fun_node.type_text.len > 0) return null;`
- src/lsp/code_actions.c3:3453 — `parse_only` — wave C — target C? — context: `if (fun_node.type_text.len > 0) {`
- src/lsp/code_actions.c3:3454 — `parse_only` — wave C — target C? — context: `if (fun_node.type_text == "Unit") returns_unit = true;`
- src/lsp/code_actions.c3:4474 — `parse_only` — wave C — target C? — context: `if (prop.type_text.len == 0) return null;`
- src/lsp/code_actions.c3:5269 — `parse_only` — wave C — target C? — context: `if (prop.type_text.len == 0) return null;`
- src/lsp/code_actions.c3:6433 — `parse_only` — wave C — target C? — context: `if (pd.type_text.len == 0) return null;`
- src/lsp/code_actions.c3:6445 — `format_text` — wave C — target C? — context: `out.append(pd.type_text);`

### src/lsp/completion.c3 (count: 30)
- src/lsp/completion.c3:811 — `key_lookup` — wave C — target C5 — context: `if (n.type_text.len > 0) {`
- src/lsp/completion.c3:814 — `key_lookup` — wave C — target C5 — context: `detail.appendf("type parameter : %s", n.type_text);`
- src/lsp/completion.c3:1061 — `parse_only` — wave C — target C5 — context: `if (n.type_text.len > 0) {`
- src/lsp/completion.c3:1062 — `parse_only` — wave C — target C5 — context: `return types::parse_type_text(n.type_text);`
- src/lsp/completion.c3:1140 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "Any";`
- src/lsp/completion.c3:1140 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "Any";`
- src/lsp/completion.c3:1144 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "Unit";`
- src/lsp/completion.c3:1144 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "Unit";`
- src/lsp/completion.c3:1287 — `format_text` — wave C — target C5 — context: `detail = child.type_text.len > 0 ? child.type_text : "Unit";`
- src/lsp/completion.c3:1287 — `format_text` — wave C — target C5 — context: `detail = child.type_text.len > 0 ? child.type_text : "Unit";`
- src/lsp/completion.c3:1291 — `format_text` — wave C — target C5 — context: `detail = child.type_text.len > 0 ? child.type_text : "";`
- src/lsp/completion.c3:1291 — `format_text` — wave C — target C5 — context: `detail = child.type_text.len > 0 ? child.type_text : "";`
- src/lsp/completion.c3:1302 — `format_text` — wave C — target C5 — context: `detail = child.type_text.len > 0 ? child.type_text : "";`
- src/lsp/completion.c3:1302 — `format_text` — wave C — target C5 — context: `detail = child.type_text.len > 0 ? child.type_text : "";`
- src/lsp/completion.c3:1348 — `format_text` — wave C — target C5 — context: `if (pr.nodes[k].type_text.len > 0) {`
- src/lsp/completion.c3:1349 — `format_text` — wave C — target C5 — context: `sig.appendf(": %s", pr.nodes[k].type_text);`
- src/lsp/completion.c3:1354 — `format_text` — wave C — target C5 — context: `if (fun_node.type_text.len > 0) {`
- src/lsp/completion.c3:1355 — `format_text` — wave C — target C5 — context: `sig.appendf(": %s", fun_node.type_text);`
- src/lsp/completion.c3:1366 — `format_text` — wave C — target C5 — context: `if (prop_node.type_text.len > 0) {`
- src/lsp/completion.c3:1367 — `format_text` — wave C — target C5 — context: `sig.appendf(": %s", prop_node.type_text);`
- src/lsp/completion.c3:1406 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "Unit";`
- src/lsp/completion.c3:1406 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "Unit";`
- src/lsp/completion.c3:1410 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "";`
- src/lsp/completion.c3:1410 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "";`
- src/lsp/completion.c3:1421 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "";`
- src/lsp/completion.c3:1421 — `format_text` — wave C — target C5 — context: `detail = m.type_text.len > 0 ? m.type_text : "";`
- src/lsp/completion.c3:1465 — `format_text` — wave C — target C5 — context: `if (m.type_text.len > 0) {`
- src/lsp/completion.c3:1466 — `format_text` — wave C — target C5 — context: `sig.appendf(": %s", m.type_text);`
- src/lsp/completion.c3:1476 — `format_text` — wave C — target C5 — context: `if (m.type_text.len > 0) {`
- src/lsp/completion.c3:1477 — `format_text` — wave C — target C5 — context: `sig.appendf(": %s", m.type_text);`

### src/lsp/definition.c3 (count: 14)
- src/lsp/definition.c3:552 — `parse_only` — wave C — target C5 — context: `String param_type = strip_type_suffix(n.type_text);`
- src/lsp/definition.c3:2377 — `parse_only` — wave C — target C5 — context: `if (fn_node.type_text.len == 0) continue;`
- src/lsp/definition.c3:2378 — `parse_only` — wave C — target C5 — context: `String rt = fn_node.type_text;`
- src/lsp/definition.c3:2458 — `parse_only` — wave C — target C5 — context: `String rt = m.type_text;`
- src/lsp/definition.c3:2638 — `parse_only` — wave C — target C5 — context: `if (n.type_text.len > 0) {`
- src/lsp/definition.c3:2639 — `parse_only` — wave C — target C5 — context: `String t = n.type_text;`
- src/lsp/definition.c3:2683 — `parse_only` — wave C — target C5 — context: `if (n.type_text.len > 0) {`
- src/lsp/definition.c3:2684 — `parse_only` — wave C — target C5 — context: `return types::parse_type_text(n.type_text);`
- src/lsp/definition.c3:2756 — `parse_only` — wave C — target C5 — context: `if (p.type_text.len == 0) continue;`
- src/lsp/definition.c3:2758 — `parse_only` — wave C — target C5 — context: `TypeRef tref = types::parse_type_text(p.type_text);`
- src/lsp/definition.c3:2818 — `parse_only` — wave C — target C5 — context: `if (p.type_text.len == 0) continue;`
- src/lsp/definition.c3:2820 — `parse_only` — wave C — target C5 — context: `TypeRef tref = types::parse_type_text(p.type_text);`
- src/lsp/definition.c3:3323 — `parse_only` — wave C — target C5 — context: `if (m.type_text.len > 0) {`
- src/lsp/definition.c3:3324 — `parse_only` — wave C — target C5 — context: `return types::parse_type_text(m.type_text);`

### src/lsp/diagnostics.c3 (count: 20)
- src/lsp/diagnostics.c3:727 — `parse_only` — wave C — target C11 — context: `TypeRef declared_type = types::parse_type_text(n.type_text);`
- src/lsp/diagnostics.c3:776 — `parse_only` — wave C — target C11 — context: `if (fun_node.type_text.len == 0) return; // no explicit return type`
- src/lsp/diagnostics.c3:778 — `parse_only` — wave C — target C11 — context: `TypeRef declared_return = types::parse_type_text(fun_node.type_text);`
- src/lsp/diagnostics.c3:891 — `parse_only` — wave C — target C11 — context: `TypeRef param_type = types::parse_type_text(ast.nodes[param_idx].type_text);`
- src/lsp/diagnostics.c3:1341 — `parse_only` — wave C — target C11 — context: `if (n.type_text.len == 0) continue;`
- src/lsp/diagnostics.c3:1344 — `parse_only` — wave C — target C11 — context: `TypeRef tref = types::parse_type_text(n.type_text);`
- src/lsp/diagnostics.c3:1366 — `format_text` — wave C — target C11 — context: `if (n.type_text.len > 0) {`
- src/lsp/diagnostics.c3:1367 — `format_text` — wave C — target C11 — context: `return n.type_text;`
- src/lsp/diagnostics.c3:2694 — `parse_only` — wave C — target C11 — context: `String target_text = node.type_text.trim();`
- src/lsp/diagnostics.c3:2870 — `parse_only` — wave C — target C11 — context: `if (subtypes[x] == cond.type_text) { covered[x] = true; break; }`
- src/lsp/diagnostics.c3:3250 — `parse_only` — wave C — target C11 — context: `type_text = ast.nodes[p].type_text;`
- src/lsp/diagnostics.c3:3845 — `parse_only` — wave C — target C11 — context: `if (variants[x] == cond.type_text) { covered[x] = true; break; }`
- src/lsp/diagnostics.c3:4105 — `parse_only` — wave C — target C11 — context: `String target_text = node.type_text.trim();`
- src/lsp/diagnostics.c3:4314 — `parse_only` — wave C — target C11 — context: `if (n.type_text.len > 0 && type_text_mentions(n.type_text, name)) return true;`
- src/lsp/diagnostics.c3:4453 — `parse_only` — wave C — target C11 — context: `if (n.type_text.len == 0) continue; // no explicit type`
- src/lsp/diagnostics.c3:4461 — `parse_only` — wave C — target C11 — context: `types::TypeRef declared = types::parse_type_text(n.type_text);`
- src/lsp/diagnostics.c3:4614 — `format_text` — wave C — target C11 — context: `if (n.type_text.len == 0) continue;`
- src/lsp/diagnostics.c3:4615 — `format_text` — wave C — target C11 — context: `if (!type_text_is_unit(n.type_text)) continue;`
- src/lsp/diagnostics.c3:5202 — `parse_only` — wave C — target C11 — context: `if (n.type_text.len == 0) continue;`
- src/lsp/diagnostics.c3:5213 — `parse_only` — wave C — target C11 — context: `types::TypeRef declared = types::parse_type_text(n.type_text);`

### src/lsp/execute_command.c3 (count: 3)
- src/lsp/execute_command.c3:315 — `key_lookup` — wave C — target C4 — context: `mj.set("type", m.type_text);`
- src/lsp/execute_command.c3:596 — `key_lookup` — wave C — target C4 — context: `if (n.type_text.len > 0) node.set("type_text", n.type_text);`
- src/lsp/execute_command.c3:596 — `key_lookup` — wave C — target C4 — context: `if (n.type_text.len > 0) node.set("type_text", n.type_text);`

### src/lsp/hover.c3 (count: 16)
- src/lsp/hover.c3:588 — `format_text` — wave C — target C5 — context: `if (child.type_text.len > 0) {`
- src/lsp/hover.c3:589 — `format_text` — wave C — target C5 — context: `ds.appendf(": %s", child.type_text);`
- src/lsp/hover.c3:596 — `format_text` — wave C — target C5 — context: `if (node.type_text.len > 0) {`
- src/lsp/hover.c3:597 — `format_text` — wave C — target C5 — context: `ds.appendf(": %s", node.type_text);`
- src/lsp/hover.c3:632 — `format_text` — wave C — target C5 — context: `if (node.type_text.len > 0) {`
- src/lsp/hover.c3:633 — `format_text` — wave C — target C5 — context: `ds.appendf(": %s", node.type_text);`
- src/lsp/hover.c3:644 — `format_text` — wave C — target C5 — context: `if (node.type_text.len > 0) {`
- src/lsp/hover.c3:645 — `format_text` — wave C — target C5 — context: `ds.appendf(" = %s", node.type_text);`
- src/lsp/hover.c3:662 — `format_text` — wave C — target C5 — context: `if (child.type_text.len > 0) {`
- src/lsp/hover.c3:663 — `format_text` — wave C — target C5 — context: `ds.appendf(": %s", child.type_text);`
- src/lsp/hover.c3:679 — `format_text` — wave C — target C5 — context: `if (node.type_text.len > 0) {`
- src/lsp/hover.c3:680 — `format_text` — wave C — target C5 — context: `ds.appendf(": %s", node.type_text);`
- src/lsp/hover.c3:740 — `format_text` — wave C — target C5 — context: `if (child.type_text.len > 0) {`
- src/lsp/hover.c3:741 — `format_text` — wave C — target C5 — context: `ds.appendf(" : %s", child.type_text);`
- src/lsp/hover.c3:772 — `format_text` — wave C — target C5 — context: `if (child.type_text.len > 0) {`
- src/lsp/hover.c3:773 — `format_text` — wave C — target C5 — context: `ds.appendf(" : %s", child.type_text);`

### src/lsp/inlay_hints.c3 (count: 19)
- src/lsp/inlay_hints.c3:301 — `parse_only` — wave C — target C5 — context: `if (node.type_text.len > 0) continue;`
- src/lsp/inlay_hints.c3:406 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) {`
- src/lsp/inlay_hints.c3:407 — `format_text` — wave C — target C5 — context: `return decl.type_text;`
- src/lsp/inlay_hints.c3:416 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) {`
- src/lsp/inlay_hints.c3:417 — `format_text` — wave C — target C5 — context: `return decl.type_text;`
- src/lsp/inlay_hints.c3:435 — `format_text` — wave C — target C5 — context: `if (init_expr.type_text.len > 0) {`
- src/lsp/inlay_hints.c3:436 — `format_text` — wave C — target C5 — context: `return init_expr.type_text;`
- src/lsp/inlay_hints.c3:518 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) return decl.type_text;`
- src/lsp/inlay_hints.c3:518 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) return decl.type_text;`
- src/lsp/inlay_hints.c3:589 — `parse_only` — wave C — target C5 — context: `if (node.type_text.len > 0) continue;`
- src/lsp/inlay_hints.c3:845 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) return decl.type_text;`
- src/lsp/inlay_hints.c3:845 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) return decl.type_text;`
- src/lsp/inlay_hints.c3:852 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) return decl.type_text;`
- src/lsp/inlay_hints.c3:852 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) return decl.type_text;`
- src/lsp/inlay_hints.c3:866 — `format_text` — wave C — target C5 — context: `if (node.type_text.len > 0) return node.type_text;`
- src/lsp/inlay_hints.c3:866 — `format_text` — wave C — target C5 — context: `if (node.type_text.len > 0) return node.type_text;`
- src/lsp/inlay_hints.c3:916 — `parse_only` — wave C — target C5 — context: `cast_type = cond.type_text;`
- src/lsp/inlay_hints.c3:1201 — `parse_only` — wave C — target C5 — context: `if (pr.nodes[j].type_text.len > 0) continue; // already has annotation`
- src/lsp/inlay_hints.c3:1361 — `parse_only` — wave C — target C5 — context: `String t = pr.nodes[k].type_text;`

### src/lsp/signature_help.c3 (count: 4)
- src/lsp/signature_help.c3:220 — `format_text` — wave C — target C5 — context: `if (decl.type_text.len > 0) {`
- src/lsp/signature_help.c3:221 — `format_text` — wave C — target C5 — context: `label.appendf(": %s", decl.type_text);`
- src/lsp/signature_help.c3:332 — `format_text` — wave C — target C5 — context: `if (child.type_text.len > 0) {`
- src/lsp/signature_help.c3:333 — `format_text` — wave C — target C5 — context: `label.appendf(": %s", child.type_text);`

### src/lsp/type_definition.c3 (count: 4)
- src/lsp/type_definition.c3:154 — `parse_only` — wave C — target C2 — context: `if (n.type_text.len > 0) {`
- src/lsp/type_definition.c3:155 — `parse_only` — wave C — target C2 — context: `TypeRef tr = types::parse_type_text(n.type_text);`
- src/lsp/type_definition.c3:163 — `parse_only` — wave C — target C2 — context: `if (n.type_text.len > 0) {`
- src/lsp/type_definition.c3:164 — `parse_only` — wave C — target C2 — context: `TypeRef tr = types::parse_type_text(n.type_text);`

### src/workspace.c3 (count: 28)
- src/workspace.c3:268 — `parse_only` — wave C — target C7 — context: `if (m.type_text.len > 0) mem::free(m.type_text.ptr);`
- src/workspace.c3:268 — `parse_only` — wave C — target C7 — context: `if (m.type_text.len > 0) mem::free(m.type_text.ptr);`
- src/workspace.c3:371 — `parse_only` — wave C — target C7 — context: `.type_text = comp_child.type_text.len > 0 ? comp_child.type_text.copy(mem) : "",`
- src/workspace.c3:371 — `parse_only` — wave C — target C7 — context: `.type_text = comp_child.type_text.len > 0 ? comp_child.type_text.copy(mem) : "",`
- src/workspace.c3:387 — `parse_only` — wave C — target C7 — context: `cm.param_types[pi] = pr.nodes[p].type_text.len > 0 ? pr.nodes[p].type_text.copy(mem) : "";`
- src/workspace.c3:387 — `parse_only` — wave C — target C7 — context: `cm.param_types[pi] = pr.nodes[p].type_text.len > 0 ? pr.nodes[p].type_text.copy(mem) : "";`
- src/workspace.c3:394 — `parse_only` — wave C — target C7 — context: `.type_text = comp_child.type_text.len > 0 ? comp_child.type_text.copy(mem) : "",`
- src/workspace.c3:394 — `parse_only` — wave C — target C7 — context: `.type_text = comp_child.type_text.len > 0 ? comp_child.type_text.copy(mem) : "",`
- src/workspace.c3:424 — `parse_only` — wave C — target C7 — context: `.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",`
- src/workspace.c3:424 — `parse_only` — wave C — target C7 — context: `.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",`
- src/workspace.c3:440 — `parse_only` — wave C — target C7 — context: `m.param_types[pi] = pr.nodes[k].type_text.len > 0 ? pr.nodes[k].type_text.copy(mem) : "";`
- src/workspace.c3:440 — `parse_only` — wave C — target C7 — context: `m.param_types[pi] = pr.nodes[k].type_text.len > 0 ? pr.nodes[k].type_text.copy(mem) : "";`
- src/workspace.c3:447 — `parse_only` — wave C — target C7 — context: `.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",`
- src/workspace.c3:447 — `parse_only` — wave C — target C7 — context: `.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",`
- src/workspace.c3:487 — `parse_only` — wave C — target C7 — context: `.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",`
- src/workspace.c3:487 — `parse_only` — wave C — target C7 — context: `.type_text = child.type_text.len > 0 ? child.type_text.copy(mem) : "",`
- src/workspace.c3:570 — `parse_only` — wave C — target C7 — context: `.type_text = n.type_text.len > 0 ? n.type_text.copy(mem) : "",`
- src/workspace.c3:570 — `parse_only` — wave C — target C7 — context: `.type_text = n.type_text.len > 0 ? n.type_text.copy(mem) : "",`
- src/workspace.c3:587 — `parse_only` — wave C — target C7 — context: `m.param_types[pi] = pr.nodes[k].type_text.len > 0 ? pr.nodes[k].type_text.copy(mem) : "";`
- src/workspace.c3:587 — `parse_only` — wave C — target C7 — context: `m.param_types[pi] = pr.nodes[k].type_text.len > 0 ? pr.nodes[k].type_text.copy(mem) : "";`
- src/workspace.c3:669 — `parse_only` — wave C — target C7 — context: `.type_text = m_node.type_text.len > 0 ? m_node.type_text.copy(mem) : "",`
- src/workspace.c3:669 — `parse_only` — wave C — target C7 — context: `.type_text = m_node.type_text.len > 0 ? m_node.type_text.copy(mem) : "",`
- src/workspace.c3:682 — `parse_only` — wave C — target C7 — context: `.type_text = m_node.type_text.len > 0 ? m_node.type_text.copy(mem) : "",`
- src/workspace.c3:682 — `parse_only` — wave C — target C7 — context: `.type_text = m_node.type_text.len > 0 ? m_node.type_text.copy(mem) : "",`
- src/workspace.c3:712 — `parse_only` — wave C — target C7 — context: `.type_text = m_node.type_text.len > 0 ? m_node.type_text.copy(mem) : "",`
- src/workspace.c3:712 — `parse_only` — wave C — target C7 — context: `.type_text = m_node.type_text.len > 0 ? m_node.type_text.copy(mem) : "",`
- src/workspace.c3:901 — `parse_only` — wave C — target C7 — context: `if (n.name.len == 0 || n.type_text.len == 0) continue;`
- src/workspace.c3:919 — `parse_only` — wave C — target C7 — context: `.aliased_type_text = n.type_text.copy(mem),`

### test/contracts_test.c3 (count: 2)
- test/contracts_test.c3:164 — `test_assertion` — wave C — target C12 — context: `assert(buf[0].type_text == "String", "type is String, got '%s'",`
- test/contracts_test.c3:165 — `test_assertion` — wave C — target C12 — context: `buf[0].type_text);`

### test/parser_test.c3 (count: 69)
- test/parser_test.c3:304 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "String", "expected return type 'String', got '%s'", fun.type_text);`
- test/parser_test.c3:304 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "String", "expected return type 'String', got '%s'", fun.type_text);`
- test/parser_test.c3:315 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "Int", "expected return type 'Int', got '%s'", fun.type_text);`
- test/parser_test.c3:315 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "Int", "expected return type 'Int', got '%s'", fun.type_text);`
- test/parser_test.c3:396 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "Int", "expected return type 'Int', got '%s'", fun.type_text);`
- test/parser_test.c3:396 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "Int", "expected return type 'Int', got '%s'", fun.type_text);`
- test/parser_test.c3:429 — `test_assertion` — wave C — target C12 — context: `assert(prop.type_text == "String", "expected type 'String', got '%s'", prop.type_text);`
- test/parser_test.c3:429 — `test_assertion` — wave C — target C12 — context: `assert(prop.type_text == "String", "expected type 'String', got '%s'", prop.type_text);`
- test/parser_test.c3:462 — `test_assertion` — wave C — target C12 — context: `assert(prop.type_text == "Int", "expected type 'Int', got '%s'", prop.type_text);`
- test/parser_test.c3:462 — `test_assertion` — wave C — target C12 — context: `assert(prop.type_text == "Int", "expected type 'Int', got '%s'", prop.type_text);`
- test/parser_test.c3:475 — `test_assertion` — wave C — target C12 — context: `assert(ta.type_text == "List<String>", "expected type 'List<String>', got '%s'", ta.type_text);`
- test/parser_test.c3:475 — `test_assertion` — wave C — target C12 — context: `assert(ta.type_text == "List<String>", "expected type 'List<String>', got '%s'", ta.type_text);`
- test/parser_test.c3:696 — `test_assertion` — wave C — target C12 — context: `assert(ch.type_text == "Int", "expected param type 'Int', got '%s'", ch.type_text);`
- test/parser_test.c3:696 — `test_assertion` — wave C — target C12 — context: `assert(ch.type_text == "Int", "expected param type 'Int', got '%s'", ch.type_text);`
- test/parser_test.c3:1504 — `test_assertion` — wave C — target C12 — context: `assert(prop.type_text == "String", "expected type 'String', got '%s'", prop.type_text);`
- test/parser_test.c3:1504 — `test_assertion` — wave C — target C12 — context: `assert(prop.type_text == "String", "expected type 'String', got '%s'", prop.type_text);`
- test/parser_test.c3:1934 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "Exception", "expected type 'Exception', got '%s'", param.type_text);`
- test/parser_test.c3:1934 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "Exception", "expected type 'Exception', got '%s'", param.type_text);`
- test/parser_test.c3:3219 — `test_assertion` — wave C — target C12 — context: `assert(ch.type_text == "suspend Exchange.() -> Any?",`
- test/parser_test.c3:3220 — `test_assertion` — wave C — target C12 — context: `"expected type 'suspend Exchange.() -> Any?', got '%s'", ch.type_text);`
- test/parser_test.c3:3358 — `test_assertion` — wave C — target C12 — context: `assert(bound.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", bound.type_text);`
- test/parser_test.c3:3358 — `test_assertion` — wave C — target C12 — context: `assert(bound.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", bound.type_text);`
- test/parser_test.c3:3378 — `parse_only` — wave C — target C12 — context: `if (ch.type_text == "Comparable<T>") found_comparable = true;`
- test/parser_test.c3:3379 — `test_assertion` — wave C — target C12 — context: `if (ch.type_text == "Serializable") found_serializable = true;`
- test/parser_test.c3:3694 — `test_assertion` — wave C — target C12 — context: `assert(c0.type_text == "Int", "child 0 type should be 'Int', got '%s'", c0.type_text);`
- test/parser_test.c3:3694 — `test_assertion` — wave C — target C12 — context: `assert(c0.type_text == "Int", "child 0 type should be 'Int', got '%s'", c0.type_text);`
- test/parser_test.c3:3698 — `test_assertion` — wave C — target C12 — context: `assert(c1.type_text == "String", "child 1 type should be 'String', got '%s'", c1.type_text);`
- test/parser_test.c3:3698 — `test_assertion` — wave C — target C12 — context: `assert(c1.type_text == "String", "child 1 type should be 'String', got '%s'", c1.type_text);`
- test/parser_test.c3:3769 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[j].type_text == "String", "param 0 type should be 'String', got '%s'", r.nodes[j].type_text);`
- test/parser_test.c3:3769 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[j].type_text == "String", "param 0 type should be 'String', got '%s'", r.nodes[j].type_text);`
- test/parser_test.c3:3772 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[j].type_text == "Int", "param 1 type should be 'Int', got '%s'", r.nodes[j].type_text);`
- test/parser_test.c3:3772 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[j].type_text == "Int", "param 1 type should be 'Int', got '%s'", r.nodes[j].type_text);`
- test/parser_test.c3:3979 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[k].type_text == "Int", "setter param type should be 'Int', got '%s'", r.nodes[k].type_text);`
- test/parser_test.c3:3979 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[k].type_text == "Int", "setter param type should be 'Int', got '%s'", r.nodes[k].type_text);`
- test/parser_test.c3:4514 — `test_assertion` — wave C — target C12 — context: `assert(p.type_text == "Int", "expected type 'Int', got '%s'", p.type_text);`
- test/parser_test.c3:4514 — `test_assertion` — wave C — target C12 — context: `assert(p.type_text == "Int", "expected type 'Int', got '%s'", p.type_text);`
- test/parser_test.c3:4524 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[i].type_text == "String", "expected return type 'String', got '%s'", r.nodes[i].type_text);`
- test/parser_test.c3:4524 — `test_assertion` — wave C — target C12 — context: `assert(r.nodes[i].type_text == "String", "expected return type 'String', got '%s'", r.nodes[i].type_text);`
- test/parser_test.c3:4627 — `test_assertion` — wave C — target C12 — context: `assert(arg.type_text == "Map<String, List<Int>>", "expected 'Map<String, List<Int>>', got '%s'", arg.type_text);`
- test/parser_test.c3:4627 — `test_assertion` — wave C — target C12 — context: `assert(arg.type_text == "Map<String, List<Int>>", "expected 'Map<String, List<Int>>', got '%s'", arg.type_text);`
- test/parser_test.c3:4650 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "Int", "expected param type_text 'Int', got '%s'", param.type_text);`
- test/parser_test.c3:4650 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "Int", "expected param type_text 'Int', got '%s'", param.type_text);`
- test/parser_test.c3:4664 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "List<String>", "expected return type_text 'List<String>', got '%s'", fun.type_text);`
- test/parser_test.c3:4664 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "List<String>", "expected return type_text 'List<String>', got '%s'", fun.type_text);`
- test/parser_test.c3:4693 — `parse_only` — wave C — target C12 — context: `(int)i, (int)n.parent, (int)n.kind, n.name, n.type_text,`
- test/parser_test.c3:4707 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "((Int) -> String)?",`
- test/parser_test.c3:4708 — `test_assertion` — wave C — target C12 — context: `"expected fun type_text '((Int) -> String)?', got '%s'", fun.type_text);`
- test/parser_test.c3:4712 — `test_assertion` — wave C — target C12 — context: `assert(tr.type_text == "((Int) -> String)?",`
- test/parser_test.c3:4713 — `test_assertion` — wave C — target C12 — context: `"expected tr type_text '((Int) -> String)?', got '%s'", tr.type_text);`
- test/parser_test.c3:4732 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "suspend (A, B) -> C?",`
- test/parser_test.c3:4733 — `test_assertion` — wave C — target C12 — context: `"expected param type_text 'suspend (A, B) -> C?', got '%s'", param.type_text);`
- test/parser_test.c3:4752 — `test_assertion` — wave C — target C12 — context: `assert(ret.type_text == "C?",`
- test/parser_test.c3:4753 — `test_assertion` — wave C — target C12 — context: `"expected return type_text 'C?', got '%s'", ret.type_text);`
- test/parser_test.c3:4763 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "Map<String, List<Pair<Int, Boolean>>>",`
- test/parser_test.c3:4764 — `test_assertion` — wave C — target C12 — context: `"expected fun type_text, got '%s'", fun.type_text);`
- test/parser_test.c3:4768 — `test_assertion` — wave C — target C12 — context: `assert(map_tr.type_text == "Map<String, List<Pair<Int, Boolean>>>",`
- test/parser_test.c3:4769 — `test_assertion` — wave C — target C12 — context: `"expected outer type_text, got '%s'", map_tr.type_text);`
- test/parser_test.c3:4779 — `test_assertion` — wave C — target C12 — context: `assert(list_tr.type_text == "List<Pair<Int, Boolean>>",`
- test/parser_test.c3:4780 — `test_assertion` — wave C — target C12 — context: `"expected list type_text, got '%s'", list_tr.type_text);`
- test/parser_test.c3:4787 — `test_assertion` — wave C — target C12 — context: `assert(pair_tr.type_text == "Pair<Int, Boolean>",`
- test/parser_test.c3:4788 — `test_assertion` — wave C — target C12 — context: `"expected pair type_text, got '%s'", pair_tr.type_text);`
- test/parser_test.c3:4806 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "T & Any", "expected return type_text 'T & Any', got '%s'", fun.type_text);`
- test/parser_test.c3:4806 — `test_assertion` — wave C — target C12 — context: `assert(fun.type_text == "T & Any", "expected return type_text 'T & Any', got '%s'", fun.type_text);`
- test/parser_test.c3:4821 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "Array<out T>", "expected param type_text 'Array<out T>', got '%s'", param.type_text);`
- test/parser_test.c3:4821 — `test_assertion` — wave C — target C12 — context: `assert(param.type_text == "Array<out T>", "expected param type_text 'Array<out T>', got '%s'", param.type_text);`
- test/parser_test.c3:4846 — `test_assertion` — wave C — target C12 — context: `assert(wc.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", wc.type_text);`
- test/parser_test.c3:4846 — `test_assertion` — wave C — target C12 — context: `assert(wc.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", wc.type_text);`
- test/parser_test.c3:4862 — `test_assertion` — wave C — target C12 — context: `assert(wc.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", wc.type_text);`
- test/parser_test.c3:4862 — `test_assertion` — wave C — target C12 — context: `assert(wc.type_text == "Comparable<T>", "expected 'Comparable<T>', got '%s'", wc.type_text);`

### test/workspace_test.c3 (count: 7)
- test/workspace_test.c3:445 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "String", "expected String return type, got '%s'", m.type_text);`
- test/workspace_test.c3:445 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "String", "expected String return type, got '%s'", m.type_text);`
- test/workspace_test.c3:458 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "String", "expected String type, got '%s'", m.type_text);`
- test/workspace_test.c3:458 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "String", "expected String type, got '%s'", m.type_text);`
- test/workspace_test.c3:494 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "String", "expected String type");`
- test/workspace_test.c3:499 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "Int", "expected Int type");`
- test/workspace_test.c3:666 — `test_assertion` — wave C — target C12 — context: `assert(m.type_text == "Int", "expected return type 'Int'");`

## annotation_text readers (Wave B)

Total: 40 reader occurrence(s) across 5 file(s).

### src/kotlin/ast.c3 (count: 2)
- src/kotlin/ast.c3:327 — `parse_only` — wave B — target B1 — context: `if (self.annotation_text.len == 0 || name.len == 0) return false;`
- src/kotlin/ast.c3:328 — `parse_only` — wave B — target B1 — context: `String text = self.annotation_text;`

### src/lsp/hover.c3 (count: 1)
- src/lsp/hover.c3:792 — `format_text` — wave B — target B6 — context: `if (node.annotation_text.len == 0) return;`

### src/lsp/semantic_tokens.c3 (count: 1)
- src/lsp/semantic_tokens.c3:246 — `parse_only` — wave B — target B5 — context: `if (n.annotation_text.len > 0 && n.has_annotation("Deprecated")) {`

### test/parser_test.c3 (count: 35)
- test/parser_test.c3:22 — `parse_only` — wave B — target B1 — context: `String ann = r.nodes[i].annotation_text;`
- test/parser_test.c3:4081 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "Test", "expected annotation_text 'Test', got '%s'", fun.annotation_text);`
- test/parser_test.c3:4081 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "Test", "expected annotation_text 'Test', got '%s'", fun.annotation_text);`
- test/parser_test.c3:4093 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "Test Ignore", "expected 'Test Ignore', got '%s'", fun.annotation_text);`
- test/parser_test.c3:4093 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "Test Ignore", "expected 'Test Ignore', got '%s'", fun.annotation_text);`
- test/parser_test.c3:4107 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "Test", "expected 'Test' (simple name), got '%s'", fun.annotation_text);`
- test/parser_test.c3:4107 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "Test", "expected 'Test' (simple name), got '%s'", fun.annotation_text);`
- test/parser_test.c3:4119 — `test_assertion` — wave B — target B1 — context: `assert(cls.annotation_text == "RunWith", "expected 'RunWith', got '%s'", cls.annotation_text);`
- test/parser_test.c3:4119 — `test_assertion` — wave B — target B1 — context: `assert(cls.annotation_text == "RunWith", "expected 'RunWith', got '%s'", cls.annotation_text);`
- test/parser_test.c3:4131 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "", "expected empty annotation_text, got '%s'", fun.annotation_text);`
- test/parser_test.c3:4131 — `test_assertion` — wave B — target B1 — context: `assert(fun.annotation_text == "", "expected empty annotation_text, got '%s'", fun.annotation_text);`
- test/parser_test.c3:4143 — `test_assertion` — wave B — target B1 — context: `assert(prop.annotation_text == "JvmName", "expected 'JvmName', got '%s'", prop.annotation_text);`
- test/parser_test.c3:4143 — `test_assertion` — wave B — target B1 — context: `assert(prop.annotation_text == "JvmName", "expected 'JvmName', got '%s'", prop.annotation_text);`
- test/parser_test.c3:4223 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"foo\")", "expected args slice '(\"foo\")', got '%s'", a.annotation_text);`
- test/parser_test.c3:4223 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"foo\")", "expected args slice '(\"foo\")', got '%s'", a.annotation_text);`
- test/parser_test.c3:4232 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"hello\")", "expected '(\"hello\")', got '%s'", a.annotation_text);`
- test/parser_test.c3:4232 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"hello\")", "expected '(\"hello\")', got '%s'", a.annotation_text);`
- test/parser_test.c3:4241 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "", "expected empty args text, got '%s'", a.annotation_text);`
- test/parser_test.c3:4241 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "", "expected empty args text, got '%s'", a.annotation_text);`
- test/parser_test.c3:4264 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(JUnit4::class)", "expected args '(JUnit4::class)', got '%s'", a.annotation_text);`
- test/parser_test.c3:4264 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(JUnit4::class)", "expected args '(JUnit4::class)', got '%s'", a.annotation_text);`
- test/parser_test.c3:4278 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"Foo\")", "expected args '(\"Foo\")', got '%s'", a.annotation_text);`
- test/parser_test.c3:4278 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"Foo\")", "expected args '(\"Foo\")', got '%s'", a.annotation_text);`
- test/parser_test.c3:5383 — `test_assertion` — wave B — target B1 — context: `assert(r.nodes[i].annotation_text == "JvmName",`
- test/parser_test.c3:5384 — `test_assertion` — wave B — target B1 — context: `"expected annotation_text='JvmName', got '%s'", r.nodes[i].annotation_text);`
- test/parser_test.c3:5550 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(\"UNUSED\", \"DEPRECATION\")",`
- test/parser_test.c3:5551 — `test_assertion` — wave B — target B1 — context: `"expected legacy annotation_text byte-identical, got '%s'", a.annotation_text);`
- test/parser_test.c3:5573 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "(name = \"x\", value = 42)",`
- test/parser_test.c3:5574 — `test_assertion` — wave B — target B1 — context: `"expected byte-identical annotation_text, got '%s'", a.annotation_text);`
- test/parser_test.c3:5594 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "([1, 2, 3])",`
- test/parser_test.c3:5595 — `test_assertion` — wave B — target B1 — context: `"expected byte-identical annotation_text, got '%s'", a.annotation_text);`
- test/parser_test.c3:5608 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "()",`
- test/parser_test.c3:5609 — `test_assertion` — wave B — target B1 — context: `"expected legacy annotation_text '()', got '%s'", a.annotation_text);`
- test/parser_test.c3:5621 — `test_assertion` — wave B — target B1 — context: `assert(a.annotation_text == "",`
- test/parser_test.c3:5622 — `test_assertion` — wave B — target B1 — context: `"expected empty annotation_text for no-parens annotation, got '%s'", a.annotation_text);`

### test/script_parser_test.c3 (count: 1)
- test/script_parser_test.c3:17 — `parse_only` — wave B — target B1 — context: `String ann = r.nodes[i].annotation_text;`

## extra_text readers (Wave A + out-of-scope markers)

Total: 197 reader occurrence(s) across 14 file(s).

### src/kotlin/ast.c3 (count: 3)
- src/kotlin/ast.c3:436 — `format_text` — wave OUT — target OUT-OF-SCOPE — spread marker (out-of-scope, leave on text) — context: `return value_arg.extra_text == "*";`
- src/kotlin/ast.c3:448 — `format_text` — wave A — target A1 — PARAM-default (in scope) — context: `return param.extra_text;`
- src/kotlin/ast.c3:456 — `format_text` — wave A — target A1 — PARAM-default (in scope) — context: `return param.extra_text.len > 0;`

### src/kotlin/contracts.c3 (count: 3)
- src/kotlin/contracts.c3:353 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `switch (a.extra_text) {`
- src/kotlin/contracts.c3:389 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool pos = n.extra_text == "is";`
- src/kotlin/contracts.c3:409 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool eq = n.extra_text == "==";`

### src/kotlin/flow.c3 (count: 10)
- src/kotlin/flow.c3:372 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `return n.extra_text;`
- src/kotlin/flow.c3:387 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "==" && n.extra_text != "!=") return "";`
- src/kotlin/flow.c3:399 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `return n.extra_text == "==" ? "==null" : "!=null";`
- src/kotlin/flow.c3:404 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `return n.extra_text == "==" ? "==null" : "!=null";`
- src/kotlin/flow.c3:482 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op2 = n.extra_text;`
- src/kotlin/flow.c3:593 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (entry.extra_text == "else") return;`
- src/kotlin/flow.c3:656 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (c.kind != TYPE_CHECK_EXPR || c.extra_text != "is") {`
- src/kotlin/flow.c3:685 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool is_pos = cn.extra_text == "is";`
- src/kotlin/flow.c3:740 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text == "!!") {`
- src/kotlin/flow.c3:752 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text == "?:") {`

### src/kotlin/parser.c3 (count: 1)
- src/kotlin/parser.c3:4117 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String marker = self.result.nodes[idx].extra_text;`

### src/kotlin/types.c3 (count: 12)
- src/kotlin/types.c3:468 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String text = node.extra_text;`
- src/kotlin/types.c3:879 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text == "as?") {`
- src/kotlin/types.c3:1328 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text == "as?") {`
- src/kotlin/types.c3:1904 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `return pr.nodes[j].extra_text == "?.";`
- src/kotlin/types.c3:1910 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `return pr.nodes[parent].extra_text == "?.";`
- src/kotlin/types.c3:1930 — `parse_only` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `if (child.extra_text == "trailing") continue;`
- src/kotlin/types.c3:3387 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text.len == 0) continue;  // not an extension`
- src/kotlin/types.c3:3390 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String ext_recv = node.extra_text;`
- src/kotlin/types.c3:4330 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String recv_text = other_pr.nodes[fun_idx].extra_text;`
- src/kotlin/types.c3:4919 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = node.extra_text;`
- src/kotlin/types.c3:5040 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = node.extra_text;`
- src/kotlin/types.c3:5079 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = node.extra_text;`

### src/lsp/call_hierarchy.c3 (count: 2)
- src/lsp/call_hierarchy.c3:223 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text.len > 0) {`
- src/lsp/call_hierarchy.c3:226 — `key_lookup` — wave OUT — target OUT-OF-SCOPE — unclassified extra_text use — context: `detail.appendf("%s.%s", node.extra_text, node.name);`

### src/lsp/code_actions.c3 (count: 32)
- src/lsp/code_actions.c3:658 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = n.extra_text;`
- src/lsp/code_actions.c3:997 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool is_else = en.extra_text == "else";`
- src/lsp/code_actions.c3:2225 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text.len == 0) continue; // extra_text = full import path`
- src/lsp/code_actions.c3:2228 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String path = n.extra_text;`
- src/lsp/code_actions.c3:2435 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String path = n.extra_text;`
- src/lsp/code_actions.c3:3994 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "+") continue;`
- src/lsp/code_actions.c3:4010 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (parent.kind != BINARY_EXPR || parent.extra_text != "+") break;`
- src/lsp/code_actions.c3:4155 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "?:") continue;`
- src/lsp/code_actions.c3:4503 — `parse_only` — wave A — target A? — supertype-delegate (in scope) — context: `if (init.extra_text == "delegate") return null;`
- src/lsp/code_actions.c3:4627 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "else") continue;`
- src/lsp/code_actions.c3:4729 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "==" && n.extra_text != "!=") continue;`
- src/lsp/code_actions.c3:4759 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String lit = l_is_bool_lit ? l.extra_text : r.extra_text;`
- src/lsp/code_actions.c3:4759 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String lit = l_is_bool_lit ? l.extra_text : r.extra_text;`
- src/lsp/code_actions.c3:4760 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool is_eq = (bin.extra_text == "==");`
- src/lsp/code_actions.c3:5055 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (ast.nodes[c].extra_text == "else") continue;`
- src/lsp/code_actions.c3:5086 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op_text = cond.extra_text == "is" ? "is" : "!is";`
- src/lsp/code_actions.c3:5394 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text == "?.") continue;`
- src/lsp/code_actions.c3:5766 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (cond.kind != BINARY_EXPR || cond.extra_text != "!=") return null;`
- src/lsp/code_actions.c3:5777 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (ast.nodes[cond_rhs].kind != LITERAL_EXPR || ast.nodes[cond_rhs].extra_text != "0") return null;`
- src/lsp/code_actions.c3:5941 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (lit.extra_text != "true" && lit.extra_text != "false") return ast::NO_PARENT;`
- src/lsp/code_actions.c3:5946 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "true" && n.extra_text != "false") return ast::NO_PARENT;`
- src/lsp/code_actions.c3:6013 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String then_val = ast.nodes[then_lit].extra_text;`
- src/lsp/code_actions.c3:6014 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String else_val = ast.nodes[else_lit].extra_text;`
- src/lsp/code_actions.c3:6177 — `parse_only` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `if (ch.extra_text == "trailing") {`
- src/lsp/code_actions.c3:6197 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String outer_dot = callee.extra_text == "?." ? "?." : ".";`
- src/lsp/code_actions.c3:6278 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (inner_dot.extra_text == "?.") return null;`
- src/lsp/code_actions.c3:6566 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (cond.extra_text == "!=") {`
- src/lsp/code_actions.c3:6568 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `} else if (cond.extra_text == "==") {`
- src/lsp/code_actions.c3:6621 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (ast.nodes[null_branch].extra_text != "null") return null;`
- src/lsp/code_actions.c3:6732 — `parse_only` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `if (ch.extra_text == "trailing") return null;     // trailing lambda — bail`
- src/lsp/code_actions.c3:6733 — `parse_only` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `if (ch.extra_text == "*") return null;            // spread — bail`
- src/lsp/code_actions.c3:6871 — `parse_only` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `if (ch.extra_text != "trailing") return null;`

### src/lsp/definition.c3 (count: 3)
- src/lsp/definition.c3:2234 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String receiver = n.extra_text;`
- src/lsp/definition.c3:2505 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String receiver = n.extra_text;`
- src/lsp/definition.c3:3000 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != full_import_path) continue;`

### src/lsp/diagnostics.c3 (count: 40)
- src/lsp/diagnostics.c3:240 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String path = node.extra_text;`
- src/lsp/diagnostics.c3:328 — `key_lookup` — wave OUT — target OUT-OF-SCOPE — unclassified extra_text use — context: `message.appendf("Unused import: %s", node.extra_text);`
- src/lsp/diagnostics.c3:527 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `return n.extra_text;`
- src/lsp/diagnostics.c3:541 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String path = n.extra_text;`
- src/lsp/diagnostics.c3:1044 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = n.extra_text;`
- src/lsp/diagnostics.c3:1564 — `key_lookup` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String receiver = n.extra_text;`
- src/lsp/diagnostics.c3:2092 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "++" && n.extra_text != "--") continue;`
- src/lsp/diagnostics.c3:2219 — `parse_only` — wave A — target A? — supertype-delegate (in scope) — context: `if (n.extra_text == "delegate") return true;`
- src/lsp/diagnostics.c3:2253 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text != "++" && n.extra_text != "--") continue;`
- src/lsp/diagnostics.c3:2693 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text == "as?") continue;`
- src/lsp/diagnostics.c3:2856 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (entry.extra_text == "else") { has_else = true; break; }`
- src/lsp/diagnostics.c3:2868 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (cond.kind != TYPE_CHECK_EXPR || cond.extra_text != "is") continue;`
- src/lsp/diagnostics.c3:2968 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (entry.extra_text == "else") { has_else = true; break; }`
- src/lsp/diagnostics.c3:3052 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text != "!!") continue;`
- src/lsp/diagnostics.c3:3134 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text != "==" && node.extra_text != "!=") continue;`
- src/lsp/diagnostics.c3:3191 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool always_true = node.extra_text == "!=";`
- src/lsp/diagnostics.c3:3320 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text != "?.") continue;`
- src/lsp/diagnostics.c3:3443 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text == "true" || n.extra_text == "false") return n.extra_text;`
- src/lsp/diagnostics.c3:3443 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text == "true" || n.extra_text == "false") return n.extra_text;`
- src/lsp/diagnostics.c3:3443 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.extra_text == "true" || n.extra_text == "false") return n.extra_text;`
- src/lsp/diagnostics.c3:3473 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text != "?:") continue;`
- src/lsp/diagnostics.c3:3499 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (lhs.extra_text != "null") is_non_null = true;`
- src/lsp/diagnostics.c3:3709 — `parse_only` — wave OUT — target OUT-OF-SCOPE — spread marker (out-of-scope, leave on text) — context: `if (va.extra_text == "*") { args_match = false; break; }`
- src/lsp/diagnostics.c3:3828 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (entry.extra_text == "else") {`
- src/lsp/diagnostics.c3:3843 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (cond.kind != TYPE_CHECK_EXPR || cond.extra_text != "is") continue;`
- src/lsp/diagnostics.c3:4028 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text != "==" && node.extra_text != "!=") continue;`
- src/lsp/diagnostics.c3:4052 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String lit = l_is_bool_lit ? l.extra_text : r.extra_text;`
- src/lsp/diagnostics.c3:4052 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String lit = l_is_bool_lit ? l.extra_text : r.extra_text;`
- src/lsp/diagnostics.c3:4053 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool is_eq = (node.extra_text == "==");`
- src/lsp/diagnostics.c3:4104 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text != "is" && node.extra_text != "!is") continue;`
- src/lsp/diagnostics.c3:4131 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `bool always_true = (node.extra_text == "is");`
- src/lsp/diagnostics.c3:4198 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (ast.nodes[entries[k]].extra_text == "else") {`
- src/lsp/diagnostics.c3:4419 — `parse_only` — wave A — target A? — supertype-delegate (in scope) — context: `if (n.extra_text == "delegate") continue; // by-delegated property`
- src/lsp/diagnostics.c3:4501 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text == "?.") continue;`
- src/lsp/diagnostics.c3:4654 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = n.extra_text;`
- src/lsp/diagnostics.c3:4752 — `parse_only` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `if (ch.extra_text == "trailing") {`
- src/lsp/diagnostics.c3:4851 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String op = n.extra_text;`
- src/lsp/diagnostics.c3:4928 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (ast.nodes[c].extra_text == "else") else_count++;`
- src/lsp/diagnostics.c3:5085 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (init.extra_text == "null") return false;`
- src/lsp/diagnostics.c3:5269 — `parse_only` — wave OUT — target OUT-OF-SCOPE — spread marker (out-of-scope, leave on text) — context: `String op = node.extra_text;`

### src/lsp/document_link.c3 (count: 1)
- src/lsp/document_link.c3:141 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String path = n.extra_text;`

### src/lsp/hover.c3 (count: 4)
- src/lsp/hover.c3:570 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text.len > 0) {`
- src/lsp/hover.c3:571 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `ds.appendf("%s.", node.extra_text);`
- src/lsp/hover.c3:628 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (node.extra_text.len > 0) {`
- src/lsp/hover.c3:629 — `format_text` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `ds.appendf("%s.", node.extra_text);`

### src/workspace.c3 (count: 4)
- src/workspace.c3:549 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (n.name.len == 0 || n.extra_text.len == 0) continue;`
- src/workspace.c3:560 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String recv = n.extra_text;`
- src/workspace.c3:1484 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `map.package_name = node.extra_text;`
- src/workspace.c3:1490 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `String path = node.extra_text;`

### test/parser_test.c3 (count: 81)
- test/parser_test.c3:68 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(pkg.extra_text == "com.example.app", "expected 'com.example.app', got '%s'", pkg.extra_text);`
- test/parser_test.c3:68 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(pkg.extra_text == "com.example.app", "expected 'com.example.app', got '%s'", pkg.extra_text);`
- test/parser_test.c3:81 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(imp.extra_text == "kotlin.io.println", "expected 'kotlin.io.println', got '%s'", imp.extra_text);`
- test/parser_test.c3:81 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(imp.extra_text == "kotlin.io.println", "expected 'kotlin.io.println', got '%s'", imp.extra_text);`
- test/parser_test.c3:91 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(imp.extra_text == "kotlin.io.*", "expected 'kotlin.io.*', got '%s'", imp.extra_text);`
- test/parser_test.c3:91 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(imp.extra_text == "kotlin.io.*", "expected 'kotlin.io.*', got '%s'", imp.extra_text);`
- test/parser_test.c3:1210 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text == "42", "expected extra_text '42', got '%s'", p.extra_text);`
- test/parser_test.c3:1210 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text == "42", "expected extra_text '42', got '%s'", p.extra_text);`
- test/parser_test.c3:1225 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text.len > 0, "extra_text must remain populated");`
- test/parser_test.c3:1240 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text.len > 0, "extra_text must remain populated");`
- test/parser_test.c3:1266 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text.len > 0, "extra_text must remain populated for vararg+default");`
- test/parser_test.c3:1280 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text.len == 0, "expected empty extra_text without default, got '%s'", p.extra_text);`
- test/parser_test.c3:1280 — `test_assertion` — wave A — target A1 — PARAM-default (in scope) — context: `assert(p.extra_text.len == 0, "expected empty extra_text without default, got '%s'", p.extra_text);`
- test/parser_test.c3:1310 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun_node.extra_text == "TopologyDescription.Source", "expected 'TopologyDescription.Source', got '%s'", fun_node.extra_text);`
- test/parser_test.c3:1310 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun_node.extra_text == "TopologyDescription.Source", "expected 'TopologyDescription.Source', got '%s'", fun_node.extra_text);`
- test/parser_test.c3:2265 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(lit.extra_text == "42", "expected '42', got '%s'", lit.extra_text);`
- test/parser_test.c3:2265 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(lit.extra_text == "42", "expected '42', got '%s'", lit.extra_text);`
- test/parser_test.c3:2389 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(dot.extra_text == "?.", "expected '?.' safe call");`
- test/parser_test.c3:2443 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(bin.extra_text == "+", "expected operator '+', got '%s'", bin.extra_text);`
- test/parser_test.c3:2443 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(bin.extra_text == "+", "expected operator '+', got '%s'", bin.extra_text);`
- test/parser_test.c3:2461 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(bin.extra_text == ">=", "expected operator '>=', got '%s'", bin.extra_text);`
- test/parser_test.c3:2461 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(bin.extra_text == ">=", "expected operator '>=', got '%s'", bin.extra_text);`
- test/parser_test.c3:2478 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(outer.extra_text == "||", "expected outermost operator '||', got '%s'", outer.extra_text);`
- test/parser_test.c3:2478 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(outer.extra_text == "||", "expected outermost operator '||', got '%s'", outer.extra_text);`
- test/parser_test.c3:2568 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(assign.extra_text == "=", "expected operator '=', got '%s'", assign.extra_text);`
- test/parser_test.c3:2568 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(assign.extra_text == "=", "expected operator '=', got '%s'", assign.extra_text);`
- test/parser_test.c3:2605 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prefix.extra_text == "-", "expected operator '-', got '%s'", prefix.extra_text);`
- test/parser_test.c3:2605 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prefix.extra_text == "-", "expected operator '-', got '%s'", prefix.extra_text);`
- test/parser_test.c3:3445 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text == "String", "expected receiver 'String', got '%s'", fun.extra_text);`
- test/parser_test.c3:3445 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text == "String", "expected receiver 'String', got '%s'", fun.extra_text);`
- test/parser_test.c3:3456 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text == "List<Int>", "expected receiver 'List<Int>', got '%s'", fun.extra_text);`
- test/parser_test.c3:3456 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text == "List<Int>", "expected receiver 'List<Int>', got '%s'", fun.extra_text);`
- test/parser_test.c3:3467 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text.len > 0, "expected non-empty receiver type for nullable extension");`
- test/parser_test.c3:3478 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text.len == 0, "expected no receiver on regular fun, got '%s'", fun.extra_text);`
- test/parser_test.c3:3478 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(fun.extra_text.len == 0, "expected no receiver on regular fun, got '%s'", fun.extra_text);`
- test/parser_test.c3:3489 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prop.extra_text == "String", "expected receiver 'String', got '%s'", prop.extra_text);`
- test/parser_test.c3:3489 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prop.extra_text == "String", "expected receiver 'String', got '%s'", prop.extra_text);`
- test/parser_test.c3:3500 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prop.extra_text.len == 0, "expected no receiver on regular property, got '%s'", prop.extra_text);`
- test/parser_test.c3:3500 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prop.extra_text.len == 0, "expected no receiver on regular property, got '%s'", prop.extra_text);`
- test/parser_test.c3:3511 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(prop.extra_text.len > 0, "expected non-empty receiver type for nullable extension property");`
- test/parser_test.c3:3918 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — NAME_EXPR field marker (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text == "field",`
- test/parser_test.c3:3919 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — NAME_EXPR field marker (out-of-scope, leave on text) — context: `"expected getter field NAME_EXPR extra_text='field', got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:3939 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — NAME_EXPR field marker (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text == "field",`
- test/parser_test.c3:3940 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — NAME_EXPR field marker (out-of-scope, leave on text) — context: `"expected setter field NAME_EXPR extra_text='field', got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:4212 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(a.extra_text == "org.junit.Test", "extra_text should be full dotted path, got '%s'", a.extra_text);`
- test/parser_test.c3:4212 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(a.extra_text == "org.junit.Test", "extra_text should be full dotted path, got '%s'", a.extra_text);`
- test/parser_test.c3:4402 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `assert(r.nodes[j].extra_text == "trailing",`
- test/parser_test.c3:4403 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `"expected trailing marker, got '%s'", r.nodes[j].extra_text);`
- test/parser_test.c3:4440 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `assert(r.nodes[last_va].extra_text == "trailing",`
- test/parser_test.c3:4441 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — trailing marker (out-of-scope, leave on text) — context: `"expected last VA to be trailing, got '%s'", r.nodes[last_va].extra_text);`
- test/parser_test.c3:4670 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(arg.extra_text == "arg", "expected type arg marker 'arg', got '%s'", arg.extra_text);`
- test/parser_test.c3:4670 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(arg.extra_text == "arg", "expected type arg marker 'arg', got '%s'", arg.extra_text);`
- test/parser_test.c3:4694 — `parse_only` — wave OUT — target OUT-OF-SCOPE — unclassified extra_text use — context: `n.extra_text, (ulong)n.mod_flags)!!;`
- test/parser_test.c3:4710 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(tr.extra_text == "function nullable",`
- test/parser_test.c3:4711 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `"expected 'function nullable' marker, got '%s'", tr.extra_text);`
- test/parser_test.c3:4719 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(p.extra_text == "param", "expected 'param' marker, got '%s'", p.extra_text);`
- test/parser_test.c3:4719 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(p.extra_text == "param", "expected 'param' marker, got '%s'", p.extra_text);`
- test/parser_test.c3:4722 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(ret.extra_text == "return", "expected 'return' marker, got '%s'", ret.extra_text);`
- test/parser_test.c3:4722 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(ret.extra_text == "return", "expected 'return' marker, got '%s'", ret.extra_text);`
- test/parser_test.c3:4735 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(tr.extra_text == "function",`
- test/parser_test.c3:4736 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `"expected 'function' marker, got '%s'", tr.extra_text);`
- test/parser_test.c3:4744 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected param 0 'A'/'param', got '%s'/'%s'", p0.name, p0.extra_text);`
- test/parser_test.c3:4747 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected param 1 'B'/'param', got '%s'/'%s'", p1.name, p1.extra_text);`
- test/parser_test.c3:4750 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(ret.extra_text == "return nullable",`
- test/parser_test.c3:4751 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `"expected 'return nullable' marker, got '%s'", ret.extra_text);`
- test/parser_test.c3:4775 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `"expected first arg 'String'/'arg', got '%s'/'%s'", str_arg.name, str_arg.extra_text);`
- test/parser_test.c3:4794 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `"expected 'Int'/'arg', got '%s'/'%s'", int_arg.name, int_arg.extra_text);`
- test/parser_test.c3:4797 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `"expected 'Boolean'/'arg', got '%s'/'%s'", bool_arg.name, bool_arg.extra_text);`
- test/parser_test.c3:4808 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(tr.extra_text == "intersection", "expected intersection marker, got '%s'", tr.extra_text);`
- test/parser_test.c3:4808 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — TYPE_REF kind marker (out-of-scope, leave on text) — context: `assert(tr.extra_text == "intersection", "expected intersection marker, got '%s'", tr.extra_text);`
- test/parser_test.c3:5210 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text == "foo",`
- test/parser_test.c3:5211 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected RETURN_EXPR.extra_text='foo', got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:5225 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text == "outer",`
- test/parser_test.c3:5226 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected BREAK_EXPR.extra_text='outer', got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:5240 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text == "loop",`
- test/parser_test.c3:5241 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected CONTINUE_EXPR.extra_text='loop', got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:5256 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text == "block",`
- test/parser_test.c3:5257 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected LAMBDA_EXPR.extra_text='block', got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:5270 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text.len == 0,`
- test/parser_test.c3:5271 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `"expected empty extra_text for unlabeled return, got '%s'", r.nodes[i].extra_text);`
- test/parser_test.c3:5311 — `test_assertion` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `assert(r.nodes[i].extra_text != "bogus",`

### test/types_test.c3 (count: 1)
- test/types_test.c3:789 — `parse_only` — wave OUT — target OUT-OF-SCOPE — operator string (out-of-scope, leave on text) — context: `if (name.len == 0 || pr.nodes[i].name == name || pr.nodes[i].extra_text == name) {`

