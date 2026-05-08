# Planner Failure-Context Enrichment — Design

**Date:** 2026-05-09
**Author:** brainstorm session
**Status:** approved, ready for implementation plan

## Background

A live `cl-harness:develop` run against the `fib` project terminated
with `:STUCK / :NO-PROGRESS` after 3 replan rounds even though the
underlying failure mode was a single, well-known Common Lisp issue:

```
EXPORT FIB::FIBONACCI causes name-conflicts in #<PACKAGE "FIB/TESTS/MAIN">
between the following symbols:
  FIB::FIBONACCI, FIB/TESTS/MAIN::FIBONACCI
```

(`tests/main.lisp` had `(:use :cl :fib :rove)` and referenced
`fibonacci` unqualified; the test package interned a fresh
internal `fibonacci` before `fib` exported it; subsequent
`(:export #:fibonacci)` then triggered ANSI 11.1.1.2.5 name-
conflict.)

Investigation traced the planner's inability to break the loop to
`%failure-context` in `src/orchestrator.lisp:659-668`, which feeds
the replanner only:

```
"step N (test_name=X) terminated with status :give-up; the executor
could not get the test to pass within its turn / patch budget."
```

The actual `EXPORT FIB::… causes name-conflicts` error string sits on
`develop-step-result.run-agent-state.final-verify.load-result` and is
**never read** by `%failure-context`. The planner has no signal to
adapt the plan beyond renaming the failing test_name. After 3 replans
the no-progress detector fires → `:STUCK`.

REPL-driven failures (`repl-eval` returning `isError=true` with an
unbound-variable / undefined-function condition) are even worse: they
have **no structured surface on `agent-state` at all**. They live only
in the LLM message history and the JSONL transcript. The replanner
cannot see them.

## Goal

Extend the replan path so the planner can read three previously
hidden signals from the failed step:

1. The last `verify-task` result (load-system error, run-tests
   failures).
2. The most-recent N agent-LLM-issued tool calls that returned
   `isError=true` — covers `repl-eval` runtime errors,
   `lisp-edit-form` patch-text mismatches, `lisp-patch-form`
   no-unique-match errors, etc.
3. The `develop-state.failure-ledger`'s active records (test-level
   failures with description + reason).

Concretely: `%failure-context`'s output grows from a single line to a
multi-paragraph block, and the `:PLANNING` context-view gains an
`## Active failures` section.

## Non-goals

- Rich planner system prompt augmentation with Lisp-typical recovery
  recipes (deferred — separate "self-recovery prompting" phase).
- Agent-side automatic recovery for name-conflict (e.g. detect the
  error, run `(delete-package :foo)`, retry) — separate phase.
- Per-tool-error structured ledger on `develop-state` — overkill
  for "show me the last few mistakes" use case; ring buffer is enough.
- Capturing successful tool calls (positive-context ring) — YAGNI.
- repl-eval stack-frame parsing — error-text string is enough; the
  cl-mcp `error_context` JSON shape is a separate complexity.
- Touching `compact-history`, public CLI surface, `cl-harness:develop`
  / `fix` / `bench` kwargs, `cl-harness/binary`, or
  `roswell/cl-harness.ros`.

## Decisions made (from brainstorm)

| Q | Decision | Rationale |
|---|---|---|
| Q1 (scope) | **(b'-β): verify + last N=3 tool-error + `:PLANNING` view active-failures** | (a') alone misses REPL errors — cl-harness's "runtime-native" pitch. (c') prompt-engineering is model-dependent; defer. (b') closes v0.5 design漏れ where replan path doesn't see active-failure ledger. |
| Q2 (entry shape) | **(ii) `:tool-name :args-summary :error-text :turn`** | Pure name without args strips actionable signal; full args+stack frames inflate context. ~150-300 chars/entry × 3 = ~1KB total. |
| Q3 (render) | **(A) hybrid**: `%failure-context` returns multi-paragraph string; active-failure-ledger gets its own `## Active failures` block via existing renderer | Single block helps LLM read time-ordered narrative; separate active-failures section reuses `:IMPLEMENTATION` view's renderer for free. |
| Q4 (populate trigger) | **(P) agent-LLM-issued tool calls only** | Excludes harness-internal `verify-task` calls so the ring doesn't duplicate the verify-error section. |

## Architecture

Three layers touched, no slot added to `develop-state` or
`develop-step-result`:

```
[1] src/agent.lisp                   [2] src/orchestrator.lisp       [3] src/context-view.lisp
─────────────────────                ─────────────────────────       ──────────────────────────
agent-state                          %failure-context                :PLANNING render
+ last-tool-errors slot              ↓ multi-paragraph string        + ## Active failures
  (ring N=3, plist entries)            from:                            section (reuses
                                       ・final-verify.load-result      existing
step-turn populate                     ・final-verify.test-result      active-failure
+ on isError=true,                     ・last-tool-errors ring         renderer)
  call record-tool-error
  (LLM-issued only)
```

### Invariants (preserve)

- `develop-step-result` shape unchanged.
- `agent-state-reason` semantics unchanged (LLM/transport failures
  only; tool errors are a separate axis).
- `:IMPLEMENTATION` view unchanged.
- 397 pre-existing deftests pass with no regression.
- No new export from `cl-harness/src/main` (facade); no
  README/CHANGELOG public-API note required.

## Data flow

### Populate path

```
LLM emits action (parse-action)
  → step-turn dispatches to call-tool
       → tool-result hash; if "isError" is true:
            record-tool-error state
              :tool-name <tool-name>
              :args-summary (%summarize-tool-args tool-name args)
              :error-text  (extract first content[].text up to 800 chars)
              :turn        (agent-state-turn state)
            → tool-result still flows through normal LLM-history /
              JSONL paths; ring is a parallel record.
```

Per-step natural reset: `agent-state` is created fresh in each
`run-agent` invocation, so the ring starts empty per step. No bleed-in.

### Read path

```
step ends with non-:passed status
  → orchestrator builds develop-step-result (carrying agent-state)
  → replan loop calls planner-fn with:
       :failure-context (%failure-context last-result)
       :develop-state state
       :prior-plan ...

%failure-context reads:
  develop-step-result-step-index
  develop-step-result-test-name
  develop-step-result-status
  develop-step-result-run-agent-state
    → agent-state-final-verify.load-result   (verify-task load-system error)
    → agent-state-final-verify.test-result   (verify-task run-tests failures)
    → agent-state-last-tool-errors           (the new ring)

Returns multi-paragraph string. Sections with empty data are omitted.

context-view->string (:planning):
  ## Goal ...
  ## Project inventory ...
  ## Prior plan ...
  ## Prior failure context     ← multi-paragraph string from %failure-context
  ## Active failures           ← NEW: pulled from develop-state.failure-ledger
  ## Runtime vocabulary ...
```

### Replan prompt token budget

Each replan round adds:

- verify-error: ~50-200 tokens
- tool-errors ring (N=3): ~200-600 tokens
- active-failures: ~30-100 tokens
- **Total: ~300-900 tokens added**

`develop`'s default planner max-tokens is 4096, comfortably
absorbing this.

### Verify-error / tool-error redundancy

`verify-task`'s automatic load-system call is harness-internal and
**not** populated to the ring (Q4 (P)). The ring captures only what
the agent's LLM issued. Therefore:

- If load-system fails inside `verify-task`: only the `### Last verify
  error (load-system)` section shows it.
- If load-system was issued by the LLM (e.g. agent retried after
  patch): the ring captures it; the verify-error section captures
  the post-step verify pass result. These describe different time
  points — no duplication.

## New surface

### `agent-state-last-tool-errors` slot

```lisp
(last-tool-errors :initform nil
                  :accessor agent-state-last-tool-errors
                  :documentation "Ring of up to +TOOL-ERROR-RING-SIZE+
plist entries for the most-recent agent-LLM-issued tool calls that
returned isError=true. Each entry: (:TOOL-NAME string :ARGS-SUMMARY
string :ERROR-TEXT string :TURN integer). Head is most recent.
Populated only by RECORD-TOOL-ERROR; per-step naturally because
agent-state is created fresh per RUN-AGENT.")
```

### `+tool-error-ring-size+` defparameter

```lisp
(defparameter +tool-error-ring-size+ 3
  "Maximum number of recent agent-LLM-issued tool errors retained on
AGENT-STATE.LAST-TOOL-ERRORS. Internal — not exported.")
```

### `record-tool-error` function

```lisp
(defun record-tool-error (state tool-name args-summary error-text turn)
  "Push a new tool-error entry to STATE's last-tool-errors ring;
truncate to +TOOL-ERROR-RING-SIZE+. Internal — called from STEP-TURN
when an LLM-issued tool call returns isError=true.")
```

### `%summarize-tool-args` (internal)

cl-mcp tool dispatch table:

| Tool | Extracted key(s) | Output example |
|---|---|---|
| `repl-eval` | `code` (≤200 char) | `(my-parser "")` |
| `lisp-edit-form` | `form_type` + `form_name` + `operation` | `defun fibonacci (replace)` |
| `lisp-patch-form` | `form_type` + `form_name` | `defpackage fib` |
| `run-tests` | `system` (+ `test`) | `fib/tests` or `fib/tests::test-fib` |
| `load-system` | `system` | `fib` |
| `fs-write-file` | `path` | `/path/to/foo.lisp` |
| `lisp-read-file` | `path` (+ `name_pattern`) | `src/main.lisp [pattern: ^fib$]` |
| `code-find` / `code-describe` / `code-find-references` | `name` (+ `kind`) | `fibonacci [defun]` |
| (other) | JSON dump | `{"foo":"bar",...}` (≤200 char) |

Guards: missing keys default to `""`; embedded newlines in `code` are
flattened to spaces; every dispatch path passes through a 200-char
truncate; result wrapped in `(or ... "(no args)")`.

### `%failure-context` revised return value

Single string, multi-paragraph, sections omitted when empty:

```
step <N> (test_name=<X>) terminated with status <Y>.

### Last verify error (load-system)
<load-result error-text, ≤800 char>

### Last verify error (run-tests)
<failed_tests, up to 3 entries with description>

### Recent tool errors (most recent first; agent-LLM-issued only)
1. [turn <T>] <tool-name> <args-summary> → <error-text first line, ≤200 char>
2. ...
```

### `:PLANNING` view active-failures section

Added immediately after the existing `## Prior failure context` block
(line 384 area in `context-view.lisp`):

```lisp
(when (context-view-active-failures view)
  (format s "~%## Active failures (test-level)~%")
  (dolist (rec (context-view-active-failures view))
    (format s "- ~A: ~A~@[~%  reason: ~A~]~%"
            (failure-record-test-name rec)
            (failure-record-description rec)
            (failure-record-reason rec))))
```

`make-context-view` `:planning` branch updated to populate
`:active-failures` from `develop-state.failure-ledger`'s active
partition (mirroring the existing `:implementation` branch).

## Acceptance criteria

The phase is complete when:

1. `agent-state-last-tool-errors` slot exists, default NIL.
2. `record-tool-error` pushes to the ring, truncates at 4th entry.
3. `step-turn` calls `record-tool-error` automatically when an
   agent-LLM-issued tool call returns `isError=true`; harness-
   internal calls (e.g. verify-task's load-system) are NOT
   recorded.
4. `%failure-context`'s return value contains the verify-load
   error, run-tests failures, and tool-error ring entries when each
   is non-empty; sections are omitted when their data is empty.
5. `:PLANNING` view rendering includes `## Active failures
   (test-level)` when `develop-state.failure-ledger` has at least
   one active record.
6. No regression in pre-existing 397 deftests.
7. ~10 new deftests pass (final count: ~407):
   - `record-tool-error-pushes-and-truncates`
   - `step-turn-records-tool-error-when-iserror-true`
   - `step-turn-skips-recording-on-success`
   - `summarize-tool-args-handles-known-tools`
   - `summarize-tool-args-falls-back-to-json-dump`
   - `summarize-tool-args-flattens-newlines`
   - `failure-context-includes-load-error-when-final-verify-load-failed`
   - `failure-context-includes-tool-errors-when-ring-non-empty`
   - `failure-context-omits-empty-sections`
   - `planning-view-renders-active-failures`
8. mallet clean, force-compile clean.
9. `agent-state-last-tool-errors` is exported from
   `cl-harness/src/agent`. No re-export from `src/main.lisp`.
10. Manual smoke verification (not auto-deftest): a fib-style
    project replicating the EXPORT name-conflict produces a
    JSONL transcript whose `replan-trigger` event payload
    contains the literal `"EXPORT FIB::"` substring (proving the
    error reaches the planner).

## Files touched

| Path | Action | LOC est. |
|---|---|---|
| `src/agent.lisp` | + `last-tool-errors` slot, + reader export, + `+tool-error-ring-size+`, + `record-tool-error`, + `%summarize-tool-args`, populate hook in `step-turn` | ~60 |
| `src/orchestrator.lisp` | rewrite `%failure-context` body (multi-paragraph), add imports for verify-result accessors and ring reader | ~50 |
| `src/context-view.lisp` | populate `:active-failures` in `:planning` branch of `make-context-view`, add `## Active failures` render block in `%format-planning-view` | ~15 |
| `tests/agent-test.lisp` | + 6 deftests | ~80 |
| `tests/orchestrator-test.lisp` | + 3 deftests | ~50 |
| `tests/context-view-test.lisp` | + 1 deftest | ~10 |
| **Total** | | **~265** |

No `cl-harness.asd` change. No `src/main.lisp` change. No
`tools/chaos-probe.lisp` / `roswell/cl-harness.ros` change.

## Out of scope (deferred to future phases)

- Planner system prompt: Lisp-typical recovery recipes (name-conflict
  → delete-package, etc.).
- Agent-side automatic recovery for known transient runtime errors.
- Tool-error ledger on `develop-state` (replacing the per-step ring).
- repl-eval stack-frame structured parsing.
- "What worked" / positive-context ring.
- Non-test-level failures in `failure-ledger` (currently the ledger
  only records `failed_tests` from rove output).
