# LLM Retry Policy — Design

**Date:** 2026-05-08
**Author:** brainstorm session
**Status:** approved, ready for implementation plan

## Background

The transport-failure-mode-coverage phase (merged 2026-05-08, commit
`0596936`) classified LLM failures into typed `model-error :kind`
values: `:auth-failed`, `:rate-limited`, `:http-server-error`,
`:http-client-error`, `:transport-timeout`,
`:transport-unavailable`, `:malformed-response`, `:empty-content`.
That phase deliberately deferred retry strategy as a separate
design.

The reviewer's final-merge note flagged it again: "Consider a
separate retry/backoff design for `:rate-limited` and
`:transport-timeout`." This document captures the design.

## Goal

Add a **minimal** automatic retry policy to `complete-chat` so
genuinely transient failures (server-side spike, rate-limit
spike, network blip) recover automatically without bothering the
caller. Keep the surface tiny: 1 retry, no backoff, only on the
3 most-clearly-transient reasons.

## Non-goals

- Backoff (fixed delay, exponential, `Retry-After` honoring) —
  separate phase.
- Configurable retry count beyond on/off — YAGNI for now.
- Retry of `:malformed-response` or `:transport-unavailable` —
  borderline transient, deferred until production data shows
  it's worth the false-positive cost.
- Per-call retry override (only per-provider). YAGNI.
- Logging individual retry attempts to JSONL — separate phase
  if needed.

## Decisions made (from brainstorm)

| Q | Decision | Rationale |
|---|---|---|
| Q1 (aggressiveness) | **α: 1 retry, no backoff, max 2 attempts total** | Smallest surface; covers the cheap transient case; can be expanded if production shows need. |
| Q2 (retriable reasons) | **A: `:http-server-error`, `:rate-limited`, `:transport-timeout`** | Most-clearly-transient set. `:malformed-response` / `:transport-unavailable` deferred to avoid false-positive retries on persistent failures. |
| Q3 (placement + config) | **(b): in `complete-chat`, with `:retry-p` boolean kwarg on `make-openai-provider`, default T** | chaos-probe / tests can opt out cleanly. Single boolean kwarg is the minimum useful surface. |

## Architecture

### New `+retriable-reasons+` defparameter

```lisp
(defparameter +retriable-reasons+
  '(:http-server-error :rate-limited :transport-timeout)
  "MODEL-ERROR :KIND values that COMPLETE-CHAT retries once when the
provider's RETRY-P slot is true. The other reasons are deliberately
NOT retried: :auth-failed and :http-client-error are caller-side
issues; :malformed-response and :transport-unavailable are
borderline-transient and excluded until production data shows
otherwise; :empty-content is already mapped to :give-up upstream.")
```

Internal — not added to `:export`. Tests reference it via
`cl-harness/src/model::+retriable-reasons+` (single colon also
works since defparameters are resolved at read time).

### New `retry-p` slot on `openai-compatible-provider`

```lisp
(retry-p :initarg :retry-p :initform t :reader provider-retry-p
         :documentation "When non-NIL (default), COMPLETE-CHAT
retries once on transient MODEL-ERRORs (those whose :KIND is in
+RETRIABLE-REASONS+). NIL disables retry — useful for chaos-probe
runs and tests that intentionally trigger failures.")
```

`provider-retry-p` reader exported via `:export`. Not re-exported
from `src/main.lisp` (internal API; chaos-probe and tests use the
package-qualified form).

### `make-openai-provider :retry-p` kwarg

Add `:retry-p` to the existing kwarg list. Default T. Threaded
through `make-instance` to populate the slot.

### Retry loop in `complete-chat`

The existing `complete-chat` body (transport call → classifier →
`chat-parse-response`) gets wrapped in a 1-attempt retry loop:

```lisp
(let ((attempt 0)
      (max-attempts 2))
  (loop
    (handler-case
        (return (do-the-existing-complete-chat-body ...))
      (model-error (c)
        (cond
          ((and (provider-retry-p provider)
                (< attempt (1- max-attempts))
                (member (model-error-type c) +retriable-reasons+))
           (incf attempt))
          (t (error c)))))))
```

`max-attempts = 2` means: 1 initial attempt + 1 retry. Hardcoded
since Q1 chose α.

The handler-case in the existing body (around `usocket:timeout-error`
and `connection-refused-error`) already converts those to
`model-error`, so the retry loop only needs to catch `model-error`
at the top level — single condition class to handle.

## Test surface

6 deftests in `tests/transport-test.lisp` (391 → 397):

1. **`complete-chat-retries-once-on-http-server-error-and-succeeds`**
   — `%canned-transport` returns `(500, error envelope)` then
   `(200, success body)`. Default `:retry-p t`. Expect: returns the
   second call's `chat-response`, no raise.
2. **`complete-chat-retries-once-on-rate-limited-and-succeeds`** —
   same shape with HTTP 429.
3. **`complete-chat-retries-once-on-timeout-and-succeeds`** — first
   call raises `usocket:timeout-error`, second returns success.
4. **`complete-chat-raises-after-retry-exhausted`** — both calls
   return 500. Expect: `model-error :http-server-error` raised after
   the 2nd attempt.
5. **`complete-chat-does-not-retry-non-retriable-reasons`** — first
   call returns 401. Expect: immediate raise; verify by introspecting
   the transport's remaining canned-response queue (1 entry left
   means no retry).
6. **`complete-chat-retry-p-nil-disables-retry`** — provider
   constructed with `:retry-p nil`. First call returns 500. Expect:
   immediate raise; canned-queue still has the un-consumed second
   entry.

`%canned-transport` is already defined in `tests/transport-test.lisp`
from Task 2 — it's a closure-based stub. Tests 5 and 6 introspect
the closure's remaining list to verify retry didn't fire; we need
to expose the closure's state to make this assertion. Either:
(a) Wrap `%canned-transport` to return both the function AND a
counter accessor, OR (b) verify by exhausting the queue and
expecting the test to NOT see "stub transport exhausted".
Approach (a) is cleaner.

## Files touched

| Path | Action |
|---|---|
| `src/model.lisp` | + `+retriable-reasons+` defparameter, + `retry-p` slot, + `:retry-p` kwarg, + retry loop, + `provider-retry-p` export |
| `tests/transport-test.lisp` | + 6 deftests, possibly + helper for transport call-count introspection |

No `cl-harness.asd` change. No `src/main.lisp` change. No new
package import (everything stays inside `cl-harness/src/model`).

## Acceptance criteria

The phase is complete when:

1. `+retriable-reasons+` is added with the 3 reasons.
2. `provider-retry-p` slot defaults T; `:retry-p nil` disables retry.
3. `complete-chat` executes at most 2 attempts; retries only on
   `+retriable-reasons+` membership AND `provider-retry-p` true.
4. 6 new deftests pass; total 391 → 397.
5. mallet clean; force-compile clean.
6. No regression in pre-existing 391 tests.
7. `chaos-probe.lisp` continues to work (its scenarios should
   actually use `:retry-p nil` to avoid doubling probe time on
   intentional failures — small follow-up task).

## Out of scope (deferred to future phases)

- Backoff strategies (fixed delay, exponential, `Retry-After`).
- Configurable max-attempts beyond on/off.
- Retry of `:malformed-response` / `:transport-unavailable`.
- JSONL events for retry attempts.
- Per-call retry override.
