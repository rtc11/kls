# F3 Manual QA Report

## Verdict: PASS WITH NOTES

All tests pass. LSP initialize handshake works against real binary. One pre-existing
behavioural note re: stdin EOF handling (see Issues §1) — not introduced by this migration.

## Build Status

```
$ c3c build
Program linked to executable 'build/kls'.
```

Exit 0. Clean build.

## Test Run

- Baseline (W0, commit `75116f4`): **2798 passed, 0 failed, 0 skipped**
- HEAD (post Wave A–E): **2802 passed, 0 failed, 0 skipped**
- Net delta: **+4 tests** (exact match to A1 dual-storage snapshot guard expansions)

Full output: `.sisyphus/evidence/F3-test-output.txt`.

### Diff vs baseline (only relevant section)

```diff
145a146,149
> Testing kls::dual_storage_snapshot_test::test_snapshot_annotation_dual_storage ......... [PASS]
> Testing kls::dual_storage_snapshot_test::test_snapshot_param_default_dual_storage ...... [PASS]
> Testing kls::dual_storage_snapshot_test::test_snapshot_supertype_delegate_dual_storage . [PASS]
> Testing kls::dual_storage_snapshot_test::test_snapshot_type_ref_dual_storage ........... [PASS]
2801c2805
< 2798 tests run.
---
> 2802 tests run.
2803c2807
< Test Result: PASSED: 2798 passed, 0 failed, 0 skipped.
---
> Test Result: PASSED: 2802 passed, 0 failed, 0 skipped.
```

No regressions. No removed tests. No skipped tests.

## Binary Smoke

`./build/kls < /dev/null` — process did not crash, did not segfault. Repeatedly logs
`[kls] Error processing message: io::EOF` in tight loop on stderr (see Issues §1).
Process must be killed externally. No memory corruption observed.

## LSP Initialize Smoke

Real LSP `initialize` request piped into the binary:

**Request** (`Content-Length: 116\r\n\r\n` + JSON body):
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file:///tmp","capabilities":{}}}
```

**Response** (excerpt — full ~2.3KB, valid JSON-RPC):
```
Content-Length: 2295

{"jsonrpc":"2.0","id":1,"result":{"capabilities":{
  "documentSymbolProvider":true,
  "executeCommandProvider":{"commands":["kotlin.runMain","kotlin.runTest", ...]},
  "implementationProvider":true,
  "callHierarchyProvider":true,
  "semanticTokensProvider":{...},
  "renameProvider":{"prepareProvider":true},
  "definitionProvider":true,
  "linkedEditingRangeProvider":true,
  "foldingRangeProvider":true,
  "referencesProvider":true,
  "hoverProvider":true,
  "typeHierarchyProvider":true,
  "documentFormattingProvider":true,
  "inlayHintProvider":{"resolveProvider":true},
  "signatureHelpProvider":{"triggerCharacters":["(",","]},
  "codeLensProvider":{"resolveProvider":true},
  "declarationProvider":true,
  "textDocumentSync":{"save":true,"change":2,"openClose":true},
  "typeDefinitionProvider":true,
  "workspaceSymbolProvider":true,
  "workspace":{"fileOperations":{"didChangeWatchedFiles":{"watchers":[...]}}},
  "codeActionProvider":{"codeActionKinds":["quickfix","source.organizeImports", ...],"resolveProvider":true},
  "documentHighlightProvider":true,
  ...
}}}
```

Stderr log:
```
[kls] Kotlin Language Server starting...
[kls] Server ready, waiting for messages on stdin...
[kls] rootUri: file:///tmp
[14:36:32:0592] [INFO] [kls] Workspace root: /tmp
```

**Verdict**: Capabilities response well-formed, all expected providers advertised,
Content-Length framing correct, JSON-RPC 2.0 envelope intact.

## Hover Smoke

`grep "hover" .sisyphus/evidence/F3-test-output.txt | grep -c FAIL` → **0**.
All hover tests (in-file + cross-file) pass.

## Cross-File Completion Smoke

`cross_file_completion_test`: **30 tests**, all PASS, 0 fail.

## Smart-Cast Diagnostic Smoke

`smart_cast_diagnostic_test`: **9 tests**, all PASS, 0 fail.

## Aggregate Coverage Spot-Check

Hover + cross-file + smart-cast namespaces combined: **122 PASS / 0 FAIL**.

## Memory / Other

Skipped — `leaks` integration not wired and not in scope for F3.

## Issues Found

1. **(PRE-EXISTING, not introduced by this migration)** `./build/kls < /dev/null`
   enters a tight stderr-spamming loop printing `Error processing message: io::EOF`
   instead of exiting cleanly when stdin reaches EOF. Hot CPU loop until killed.
   Out of scope for the semantic-subast migration. File a follow-up issue.

## Recommendation

**APPROVE F3.**

Build clean, full test suite green at 2802 PASS / 0 FAIL / 0 SKIP, exact +4 delta
matches A1's dual-storage snapshot guards, real LSP initialize handshake works,
all hover / cross-file completion / smart-cast diagnostic tests pass.

The Wave A–E work is verified at the binary level. Migration is functionally complete.
