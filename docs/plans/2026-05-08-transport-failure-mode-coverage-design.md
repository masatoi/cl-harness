# Transport Failure-Mode Coverage — Design

**Date:** 2026-05-08
**Author:** brainstorm session (cl-harness v0.5.1 post-mortem)
**Status:** approved, ready for implementation plan

## Background

The v0.5.0 / v0.5.1 live verification with Qwen/Qwen3.6-35B-A3B
surfaced a real transport bug: dexador's default 10-second
read-timeout broke every develop call against reasoning models,
crashing with `"I/O timeout while doing input on
#<SB-SYS:FD-STREAM ...>"` before any JSONL event could be
written. That bug was caught manually during ad-hoc smoke-testing.

cl-harness has 361 unit tests, all stub-driven — none of them
exercise transport-layer or response-shape failure modes against
actual provider behaviour. The agent loop's stubs return clean
chat-responses; the dexador wrapper has never been tested with
HTTP errors, timeouts, or malformed bodies. Each new failure
mode that surfaces in production is currently a hand-debug-and-
patch cycle.

This design adds **deterministic CI tests for transport failure
modes**, plus a **manual real-LLM "chaos probe"** runner for
end-to-end validation against actual providers.

## Goal

Ensure cl-harness handles common LLM-side / transport-side
failure modes with **typed errors** and **graceful exit
status**, rather than crashing or returning indeterminate
state. Specifically:

- HTTP 401/429/4xx/5xx errors → typed `:error` exit with
  classification keyword.
- Transport timeouts and connection failures → typed `:error`
  exit.
- Empty content (e.g., reasoning models hitting max_tokens
  during their think phase) → clean `:give-up :empty-content`.
- Malformed response shape → typed `:error :malformed-response`.
- The transport-layer robustness is **regression-tested in CI**
  via stubbed `:transport`; no real LLM endpoint required.

## Non-goals

- Retry mechanism (transient errors → immediate `:error` for
  this phase; retry is a separate design).
- `reasoning_content` fallback when `content: null` (separate
  feature).
- Automatic re-prompt loop for empty content (immediate
  `:give-up`; re-prompt could be added later).
- Multi-model chaos probe — single endpoint at a time for now.
- Putting chaos probe in CI — it stays manual / pre-release.

## Approach

**Hybrid testing**:

1. **CI deftests (`tests/transport-test.lisp`, ~10 tests)** —
   stub `:transport` injection point on `make-openai-provider`
   to feed canned (body, status, headers) tuples or to raise
   transport errors. Tests assert that `cl-harness:develop` (or
   a smaller helper) terminates with `:error` / `:give-up` and
   the right `:reason` keyword. No HTTP server, no network. CI-
   fast, deterministic.

2. **Manual chaos probe (`tools/chaos-probe.lisp`, ~4
   scenarios)** — run against a live OpenAI-compatible endpoint
   with deliberately-broken inputs (`max_tokens: 1`, bad URL,
   wrong API key, etc.) to verify the FULL stack (dexador →
   classifier → develop loop → CLI exit). Manual / pre-release.
   The probe runner returns 0 if all scenarios produced the
   expected `:error/:reason` and 1 otherwise.

## Architecture

### New `:reason` slot

`agent-state`, `develop-state`, `develop-result` all gain an
`:initform nil :reader …-reason` slot. The slot is non-NIL only
when status is `:error` or `:give-up` and a specific failure
mode is identified. Existing status keywords
(`:passed/:give-up/:limit-exhausted/:dirty-only/:error/:stuck`)
are unchanged — callers that read only status see no
behavioural change. The slot is **opt-in**: report formatters
include it next to the status when present.

### Failure-mode classifier

New `cl-harness/src/model:%classify-llm-failure` maps
(HTTP status, response body) → reason keyword:

```
status   body shape                 reason keyword
401      any                        :auth-failed
429      any                        :rate-limited
500-599  any                        :http-server-error
4xx other any                       :http-client-error
nil/200  malformed JSON             :malformed-response
nil/200  JSON missing "choices"     :malformed-response
nil/200  JSON valid                 nil (success path)
```

Plus transport-layer raises caught at `complete-chat` boundary:

```
condition                            reason keyword
usocket:timeout-error                :transport-timeout
usocket:connection-refused-error     :transport-unavailable
```

`complete-chat` re-raises a `model-error` with `:kind` set to
the reason keyword. Orchestrator's `develop` catches
`model-error` and finalises `develop-result` with
`:status :error :reason <kw>`.

### Empty content path (C2)

Independent of `%classify-llm-failure`: when `complete-chat`
returns a `chat-response` with empty/NIL content, the agent
loop sets `agent-state-status :give-up` and
`agent-state-reason :empty-content`. No re-prompt this phase.

### Length-truncation path (C3)

When `finish_reason: "length"` AND content is non-empty, the
content is forwarded to `parse-action` unchanged. If the
truncation produced invalid JSON, the existing
`action-parse-error` re-prompt path handles it. No new code.

### Stub transport for CI

`make-openai-provider :transport <fn>` already accepts a custom
transport function (signature `(url headers body) → (values
response-body status response-headers)`). The test suite
defines a small `%fake-transport` factory that takes canned
responses and serves them in sequence:

```lisp
(defun %fake-transport (canned-responses)
  "Each call to the returned function pops one (body status
   headers) tuple from CANNED-RESPONSES. When CANNED-RESPONSES
   contains a CONDITION instead of a tuple, the transport
   raises that condition."
  ...)
```

This lets a single test simulate a sequence of responses or a
specific failure raise.

### Chaos probe shape

`tools/chaos-probe.lisp` is a standalone load script that:

1. Reads endpoint config from environment (same as the CLI:
   `CL_HARNESS_LLM_BASE_URL`, `CL_HARNESS_LLM_API_KEY`,
   `CL_HARNESS_LLM_MODEL`).
2. Runs 4 scenarios:
   - **P1**: `cl-harness:develop` with `:max-tokens 1` against a
     trivial fixture. Asserts `develop-result-reason` is
     `:empty-content`.
   - **P2**: `:max-tokens 50` with a complex fixture. Asserts
     truncation is handled (run completes or `:give-up`, no
     crash).
   - **P3**: `:base-url "http://127.0.0.1:9999/v1"`. Asserts
     `:transport-unavailable`.
   - **P4**: `:api-key "invalid"`. Asserts `:auth-failed`.
3. Prints a one-line PASS/FAIL per scenario; exits 0 if all
   pass, 1 otherwise.

Invocation:

```bash
sbcl --noinform --non-interactive --load tools/chaos-probe.lisp
```

## Test surface delta

CI count: 361 → ~371. New file `tests/transport-test.lisp` with:

| # | Mode | reason keyword |
|---|---|---|
| T1 | HTTP 5xx | `:http-server-error` |
| T2 | HTTP 401 | `:auth-failed` |
| T3 | HTTP 429 | `:rate-limited` |
| T4 | HTTP 4xx (e.g., 404) | `:http-client-error` |
| T5 | read-timeout | `:transport-timeout` |
| T6 | connect refused | `:transport-unavailable` |
| C2 | content NIL/empty | `:empty-content` (status `:give-up`) |
| C3 | finish_reason length, content non-empty | NIL (forwarded to parser) |
| B1 | non-JSON body | `:malformed-response` |
| B2 | choices missing/empty | `:malformed-response` |

Plus `tools/chaos-probe.lisp` (not tested by CI itself).

## Files touched

| Path | Action |
|---|---|
| `src/model.lisp` | + `%classify-llm-failure`, transport error wrapping in `complete-chat` |
| `src/agent.lisp` | + `:reason` slot; empty-content path |
| `src/state.lisp` | + `:reason` slot on `develop-state`; reader |
| `src/orchestrator.lisp` | model-error catch; reason propagation to `develop-result` |
| `src/cli.lisp` | report formatter shows `:reason` next to status |
| `src/main.lisp` | re-export `develop-result-reason` (plus `agent-state-reason`?) |
| `tests/transport-test.lisp` | NEW, 10 deftests |
| `cl-harness.asd` | register `cl-harness/tests/transport-test` |
| `tools/chaos-probe.lisp` | NEW, 4 scenarios + entry point |

## Implementation order (per Acceptance §3.C)

1. `%classify-llm-failure` + `complete-chat` error catch.
2. `:reason` slots on agent-state / develop-state / develop-result.
3. Orchestrator catches model-error → `develop-result-reason`.
4. `tests/transport-test.lisp` 10 deftests (TDD).
5. Empty-content `:give-up :empty-content` in agent loop + C2 test.
6. Report formatters render `:reason`.
7. `tools/chaos-probe.lisp` + manual run against Qwen3.6.
8. mallet / force-compile / docs.
9. final review + merge.

## Acceptance criteria

The phase is complete when:

1. `develop-result-reason` populates correctly across the 10 CI
   deftests; status remains `:error` or `:give-up` per the
   table.
2. `tests/transport-test.lisp` adds 10 deftests; total CI count
   361 → ~371.
3. mallet clean across all touched files; force-compile clean.
4. `:reason` slot is exposed via reader, re-exported from
   `src/main`, and surfaced in both report formatters.
5. `tools/chaos-probe.lisp` runs to completion against Qwen3.6
   with all 4 scenarios PASS (manual verification).
6. The dexador timeout regression case (T5) is covered by an
   automated test.
7. No regression in pre-existing 361 tests.

## Out of scope (carried forward)

- Retry strategies for T1/T2/T5 (transient errors).
- `reasoning_content` → `content` fallback.
- Empty-content automatic re-prompt loop.
- Multi-model chaos probe.
- CI integration of chaos probe.
- Status keyword refactor (e.g., elevating reasons to top-level
  status). Current design keeps existing status keywords + opt-
  in `:reason` slot for compatibility.
