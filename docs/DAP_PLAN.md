# DAP Support Plan for KLS

Debug Adapter Protocol (DAP) support as `--dap` mode. Reuses JSON-RPC framing, subprocess management, classpath resolution from LSP server.

## Phases

### Phase 1: Infrastructure & Transport
DAP message loop running, responding to `initialize`.

- `--dap` flag in `main.c3` → branch to `DapServer.run()`
- `src/dap/server.c3` — DapServer struct, read/dispatch loop (reuses `json_rpc`)
- `src/dap/types.c3` — DAP types: Breakpoint, StackFrame, Scope, Variable, Thread, Source, Capabilities
- `src/dap/lifecycle.c3` — initialize (return capabilities), disconnect, terminate

### Phase 2: Launch & Attach
Launch Kotlin program under debug, attach to running JVM.

- `src/dap/jdwp/transport.c3` — TCP socket to JDWP agent, handshake, command/reply framing (11-byte header)
- `src/dap/jdwp/protocol.c3` — JDWP command sets: VirtualMachine, ReferenceType, ClassType, Method, ObjectReference, ThreadReference, StackFrame, EventRequest, Event
- `src/dap/jdwp/ids.c3` — ID management (object/type/thread/frame IDs) with lookup maps
- `src/dap/launch.c3` — `launch` request: resolve classpath, spawn JVM with `-agentlib:jdwp`, parse port, connect
- `src/dap/attach.c3` — `attach` request: connect to existing JDWP agent at host:port

### Phase 3: Breakpoints & Execution Control
Set breakpoints, pause/continue/step.

- `src/dap/breakpoints.c3` — `setBreakpoints`: source+line → JDWP EventRequest.Set(BREAKPOINT)
- `src/dap/execution.c3` — `continue`, `next`, `stepIn`, `stepOut`, `pause` → JDWP SINGLE_STEP
- `src/dap/events.c3` — JDWP event listener: breakpoint hit → `stopped`, thread death → `thread`, VM death → `terminated`

### Phase 4: Inspection
View threads, stack frames, variables.

- `src/dap/threads.c3` — `threads` request via JDWP AllThreads
- `src/dap/stacktrace.c3` — `stackTrace` via JDWP ThreadReference.Frames
- `src/dap/variables.c3` — `scopes` + `variables` via JDWP GetValues
- `src/dap/evaluate.c3` — `evaluate`: name-only lookups initially

### Phase 5: Polish
- Exception breakpoints (`setExceptionBreakpoints`)
- Source mapping (JVM class → .kt files via workspace index)
- Output handling (debuggee stdout/stderr → DAP `output` events)
- Configuration (main class, args, JVM args, env, classpath overrides)

## File Structure

```
src/dap/
  server.c3          # DapServer, dispatch loop
  types.c3           # DAP protocol types
  lifecycle.c3       # initialize, disconnect, terminate
  launch.c3          # launch request
  attach.c3          # attach request
  breakpoints.c3     # setBreakpoints
  execution.c3       # continue/step
  events.c3          # JDWP→DAP events
  threads.c3         # threads request
  stacktrace.c3      # stackTrace request
  variables.c3       # scopes + variables
  evaluate.c3        # evaluate request
  jdwp/
    transport.c3     # TCP socket, handshake, framing
    protocol.c3      # JDWP command encoding/decoding
    ids.c3           # ID management
```

## Reused from LSP Server
- `json_rpc.c3` — Content-Length framing, send_response/notification/error (identical transport)
- `log.c3` — Leveled stderr logging
- `deps/classpath.c3` — Build system detection, JAR resolution (needed for launch)
- `execute_command.c3` — Subprocess spawning patterns
- Server dispatch pattern from `server.c3`

## Complexity
| Phase | Effort | Notes |
|-------|--------|-------|
| 1 | Small | Copy-adapt existing patterns |
| 2 | **Large** | JDWP binary protocol is bulk of new work |
| 3 | Medium | JDWP commands well-documented |
| 4 | Medium-Large | Variable tree traversal fiddly |
| 5 | Medium | Incremental improvements |
