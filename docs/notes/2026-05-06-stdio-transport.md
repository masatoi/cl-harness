# cl-harness ↔ cl-mcp: stdio Transport Migration — 2026-05-06

## Why

The current architecture has a single failure mode that surfaces both
in development and in benchmarks:

`cl-harness:fix` and `cl-harness:bench` connect over HTTP to a
shared cl-mcp HTTP server (default `http://127.0.0.1:3001/mcp`). The
.mcp.json in this repo points Claude Code at the same endpoint, so
when an interactive session evaluates `(cl-harness:fix ...)` from
inside the cl-mcp worker that Claude Code is already bound to, the
harness opens a *second* MCP HTTP session against the *same* server
and is given a different worker out of the pool.

cl-mcp does not currently GC idle sessions. Each `cl-harness:fix`
call therefore leaks one worker, which stays in the `bound` slice of
the pool until the cl-mcp server itself restarts. After ~16 calls
the 16-slot pool is exhausted; the next `load-system` fails with a
"pool size limit error", every verify-task starts reporting
`load-failed`, and the agent sees its own correctly-applied patches
as failed. This was the root cause of the second smoke run in
`docs/notes/2026-05-06-qwen-smoke.md` (and likely also the cause of
issue #2 in that file's "two harness defects" section).

The architectural answer is that cl-harness should not share a
cl-mcp instance with anything else. MCP's primary transport is
stdio, designed precisely so each client owns a dedicated server
subprocess whose lifetime is tied to the client's. cl-mcp already
implements stdio (`cl-mcp/src/run:run :transport :stdio`) — the
work is on the cl-harness side.

## Goal

`cl-harness:fix` and `cl-harness:bench` spawn their own cl-mcp
subprocess by default, communicate over its stdin/stdout, and tear
the subprocess down on exit. HTTP stays available for cases where it
is genuinely needed (remote cl-mcp, sharing with Claude Code on
purpose).

## What cl-mcp already provides

- `cl-mcp/src/run:run :transport :stdio` reads newline-delimited JSON
  from `*standard-input*`, writes responses to `*standard-output*`,
  and runs the same JSON-RPC protocol the HTTP server speaks (just
  framed by NDJSON instead of HTTP request/response). No upstream
  work is required.

## What cl-harness needs

### Phase A — Abstract the transport in `src/mcp.lisp`

Today `mcp-client` is HTTP-aware (URL, session id, transport closure
that wraps `dex:post`). Refactor so:

- `mcp-client` is an abstract base with a `transport` slot.
- Two concrete subclasses: `http-mcp-client`, `stdio-mcp-client`.
- `call-tool`, `initialize-mcp`, etc. dispatch on the transport via a
  generic function `transport-send-request` rather than calling the
  HTTP closure directly.

No behavioural change. HTTP path is preserved 1:1. Existing tests
(which inject a fake transport closure today) keep working with at
most a thin shim. Foundation for Phase B.

### Phase B — Implement the stdio client

```lisp
(defclass stdio-mcp-client (mcp-client)
  ((process :reader stdio-client-process)
   (next-id :initform 0 :accessor stdio-client-next-id)
   (pending :initform (make-hash-table) :reader stdio-client-pending)
   (reader-thread :reader stdio-client-reader-thread)
   (closed-p :initform nil :accessor stdio-client-closed-p)))

(defun make-stdio-mcp-client (command-and-args
                              &key (timeout-seconds 60))
  ;; uiop:launch-program with :input :stream :output :stream
  ;; spawn a reader thread parsing NDJSON from stdout
  ;; route each parsed response by id to a pending bordeaux-threads
  ;; condition variable / promise
  ...)

(defmethod transport-send-request ((c stdio-mcp-client) body)
  ;; assign a fresh id, register pending entry, write line, force-output,
  ;; wait on the response with timeout, return the parsed JSON
  ...)

(defmethod close-mcp-client ((c stdio-mcp-client))
  (setf (stdio-client-closed-p c) t)
  (uiop:terminate-process (stdio-client-process c))
  (uiop:wait-process (stdio-client-process c))
  (bt:join-thread (stdio-client-reader-thread c)))
```

Add bordeaux-threads (and yason already in deps) to the .asd. The
reader thread is the simplest design that handles arbitrary
interleaving and future server-initiated notifications.

Tests: an in-process loop-back transport for unit tests, plus one
integration test that actually spawns cl-mcp and runs an `initialize`
+ `tools/call` round-trip. Skip the integration test cleanly when
cl-mcp is not on the source-registry.

### Phase C — CLI flags

```
--mcp-url <url>        explicit HTTP endpoint
--mcp-command "<cmd>"  shell command to spawn the cl-mcp subprocess
--mcp-stdio            shorthand for the built-in default command
```

Resolution order (highest priority first):

1. `--mcp-url` (kwarg)
2. `$CL_HARNESS_MCP_URL`
3. `--mcp-command` (kwarg) / `--mcp-stdio`
4. `$CL_HARNESS_MCP_COMMAND`
5. Built-in default stdio command (Phase D switches this on)

Built-in default candidate:

```
ros run -s cl-mcp -e "(cl-mcp/src/run:run :transport :stdio)" --quiet
```

If a `cl-mcp` binary is on `$PATH` use that; otherwise fall back to
the `ros run` form. Document the resolution rules in README.

### Phase D — Flip the default

Default to stdio when nothing else is configured. README updated to
explain why — share-the-server is now an explicit opt-in, not an
accidental ambient state. `docs/notes/2026-05-06-qwen-smoke.md`
gets a footnote noting this resolves the pool exhaustion path
identified there.

## Trade-offs we accept

- **Startup cost.** Spawning fresh SBCL + loading cl-mcp via
  Quicklisp adds 5–15 s per `fix` invocation. For benchmarks this is
  amortised. For interactive single-shot fixes it is noticeable; the
  HTTP escape hatch stays available for that case. Long-term, a
  pre-built cl-mcp binary collapses this to ~0.5 s.
- **Debug visibility.** HTTP can be poked with curl; stdio is a child
  process pipe. Mitigated by routing the cl-mcp subprocess's stderr
  to the harness's transcript directory (so server-side errors stay
  inspectable post-mortem).
- **Two transports to maintain.** Both code paths have to keep
  passing the same MCP test contract. Cost is small once the
  transport abstraction in Phase A is in place.

## Out of scope here

- Adding idle-session GC to cl-mcp. Worth doing upstream
  independently, but the stdio path makes it non-blocking for
  cl-harness.
- Building cl-mcp into a standalone binary for fast startup. Future
  optimisation; the `ros run` path is enough to ship.
- Migrating `.mcp.json` (which Claude Code reads) — that file
  legitimately wants HTTP and is not affected by this change.

## Migration order

1. **Phase A** (transport abstraction, no behaviour change) — small,
   reviewable, lands by itself.
2. **Phase B** (stdio client + tests) — additive, default still HTTP.
3. **Phase C** (CLI flags, default still HTTP) — operators can opt
   in.
4. **Phase D** (flip default, README) — communications change for
   external users, gets its own commit.

Each phase is independently testable and revertible.
