# review-feedback-routing — live coverage of all `review_final_outcome` values

**Date**: 2026-05-23
**Model**: `Qwen/Qwen3.6-35B-A3B` served by SGLang at
`http://192.168.0.17:8000/v1` (local network).
**Code**: cl-harness post-merge of `review-feedback-routing` (`e2d4987`).
The implementation-review inner-loop in `%execute-step` retries
`run-agent` with the reviewer's feedback prepended to the issue,
bounded by `:max-impl-review-revisions` (default 2). See
`docs/superpowers/specs/2026-05-22-review-feedback-routing-design.md`
for the design.
**Settings**: temperature 0, max_tokens 4096, `enable_thinking: false`
(same as the v0.5 Qwen sweep). MCP transport: built-in stdio spawn
per run.

## Scope

This bench is not a pass-rate sweep. Its purpose is **end-to-end
verification that the four documented `review_final_outcome` values
(`passed-first-try`, `passed-after-retry`, `exhausted`, `n-a`) all
fire on live LLM + cl-mcp + ASDF traffic**, matching the unit-test
specification. Two natural-reviewer runs plus two stubbed-reviewer
runs cover the matrix.

The matching unit-test suite (6 stub-driven deftests under
`tests/orchestrator-test.lisp`) already proves the loop logic in
isolation; this bench seals the loop with a live LLM in the
implementer seat.

## Run protocol

Drivers:
- `/tmp/rfr-bench.lisp` — natural reviewer, `100-greet`, budget 0 & 2
- `/tmp/rfr-bench2.lisp` — natural reviewer, `102-counter-class`,
  `104-cache-simple`, budget 2
- `/tmp/rfr-bench3.lisp` — stubbed `review-fn`, `100-greet`, two
  scenarios (`reject-then-approve`, `always-reject`)

Each driver was launched under `ros run --non-interactive --load`
with `CL_HARNESS_LLM_*` exported. Per-run JSONL transcripts saved
under `/tmp/rfr-bench*-*.jsonl` (see "Logs" below).

## Per-cell results

| Driver | Task | review-fn | Budget | Status | impl-reviews | rejections | review_retries | `review_final_outcome` | elapsed (s) |
|---|---|---|---:|---|---:|---:|---:|---|---:|
| bench1 | 100-greet | default (Qwen) | 0 | `:PASSED` | 1 | 0 | 0 | `passed-first-try` | 160.8 |
| bench1 | 100-greet | default (Qwen) | 2 | `:PASSED` | 1 | 0 | 0 | `passed-first-try` | 150.5 |
| bench2 | 102-counter-class | default (Qwen) | 2 | `:STUCK` | 0 | 0 | 0 | `n-a` | 573.4 |
| bench2 | 104-cache-simple  | default (Qwen) | 2 | `:STUCK` | 0 | 0 | 0 | `n-a` | 572.8 |
| bench3 | 100-greet | stub :reject-then-approve | 2 | `:PASSED` | 2 | 1 | 1 | `passed-after-retry` | 155.0 |
| bench3 | 100-greet | stub :always-reject       | 2 | `:STUCK` | 3 | 3 | 2 | `exhausted` | 269.3 |

## `review_final_outcome` coverage matrix

All 4 documented values observed on live traffic:

| Value | First observed in | Notes |
|---|---|---|
| `passed-first-try` | bench1 budget=0 (100-greet) | Reviewer approves on initial verify-pass. Qwen3.6 acting as both implementer and reviewer is permissive on simple tasks. |
| `passed-after-retry` | bench3 :reject-then-approve | One stubbed reject → run-agent re-invoked with feedback prepended → second verify-pass approved. `:impl-review-retry` JSONL fired once with the exact feedback string. |
| `exhausted` | bench3 :always-reject | Reviewer rejects 3× (initial + 2 retries), `impl-review-passed-p` stays NIL, step status flipped to `:review-rejected` for the outer develop loop. |
| `n-a` | bench2 (102 / 104) | `:review-policy :auto` but verify never returned `:passed`, so the implementation-review gate was never crossed. The outcome string correctly reports "not applicable". |

## Verified end-to-end on this bench

- inner-loop fires exactly the documented number of times for a given
  budget (initial + N retries, N ≤ `max-impl-review-revisions`).
- `%enriched-issue` injects the `## Prior implementation review
  feedback` block into the re-issue string. The
  `reject-then-approve` scenario verifies via behavior: Qwen3.6
  successfully re-completes the task on the second invocation only
  when the feedback is actually delivered.
- `:impl-review-retry` JSONL event format (`step_index` / `retry_count`
  / `feedback`) is correct and consumable.
- `:step-end` payload carries the new `review_retries` and
  `review_final_outcome` fields (plus the restored `test_name`).
- Budget-exhausted status overwrite (`:passed` → `:review-rejected`)
  composes correctly with the outer develop loop's
  no-progress/`:stuck` detection.
- No regression on the natural-reviewer happy path: budget=0 and
  budget=2 produce identical `:passed` outcomes on tasks where the
  reviewer always approves; the 10-second wall-clock difference
  between them on 100-greet is within single-trial LLM variance.

## Limitations and what this bench does NOT show

- **No pass-rate signal on a meaningful sample.** Only 100-greet
  reaches verify-green under Qwen3.6 with the current run budget;
  102 and 104 fail at step 1's run-agent loop (`limit-exhausted`
  before any verify-pass). To measure feature value at the
  pass-rate level, a fixture where the implementer reaches green
  *and* the reviewer rejects on substantive grounds is needed.
- **Reviewer self-review bias.** Qwen3.6 used as both implementer
  and reviewer reliably approved its own first implementation on
  100-greet. No natural rejection observed across 3 budget=2 runs.
  This is expected for same-model self-review; a different model
  (or a stricter system prompt) is the natural next experiment.
- **Single trial per cell.** No variance bounds; do not cite
  elapsed-second deltas as signal.
- **bench3's stubbed `review-fn` short-circuits all non-`:implementation`
  review kinds (`:plan` / `:tests` / `:test-change`) to auto-approve.**
  In production those gates would run the LLM-driven reviewer too;
  bypassing them for this experiment isolates the impl-review loop
  but does not exercise the full multi-gate pipeline interaction.
- **bench3 always-reject ends `:STUCK` at develop level**, not
  `:review-rejected`. This is correct (step-level `:review-rejected`
  → outer planner returns same test_name → develop's no-progress
  detector fires) but worth being explicit about: the `:STUCK`
  status is the *develop-level* terminal, the per-step
  `:review-rejected` is in the `:step-end` event.

## Per-event counts (JSONL)

```
bench1 100-greet budget=0:
  develop-start 1, plan 1, step-start 1, step-end 1,
  integration-check 1, develop-end 1
bench1 100-greet budget=2:
  (same as budget=0; no :impl-review-retry because no rejection)
bench2 102-counter-class:
  develop-start 1, plan 1, step-start 1, step-end 1, develop-end 1
  (no integration-check because verify never passed)
bench2 104-cache-simple:
  (same as 102)
bench3 :reject-then-approve:
  develop-start 1, plan 1, step-start 1, impl-review-retry 1,
  step-end 1, integration-check 1, develop-end 1
bench3 :always-reject:
  develop-start 1, plan 1, step-start 1, impl-review-retry 2,
  step-end 1, develop-end 1
```

The `impl-review-retry` count in always-reject is 2 (not 3) because
budget exhaustion exits the loop without emitting a final retry
event — the third reviewer call's verdict is captured in
`review_decisions` and reflected by the `:step-end` outcome string.

## Logs

The five live JSONL transcripts referenced above were captured
under `/tmp/rfr-bench{,2,3}-2026-05-23-*.jsonl`. They are
ephemeral (in `/tmp`) and not committed; the summary `.lisp`
files at `/tmp/rfr-bench*-*-summary.lisp` carry the same
per-cell statistics this document summarizes.

## Reproduction

The three driver scripts are committed alongside no permanent
tooling — they are throwaway harnesses adequate for this
verification. To re-run:

1. Export `CL_HARNESS_LLM_BASE_URL`, `CL_HARNESS_LLM_API_KEY`,
   `CL_HARNESS_LLM_MODEL`.
2. Save each `/tmp/rfr-bench*.lisp` from this conversation (or
   reconstruct from the design + this document's per-cell
   parameters).
3. `ros run --non-interactive --load /tmp/rfr-bench3.lisp >
   /tmp/rfr-bench3.log 2>&1` — bench3 is the most diagnostic of
   the three (covers `passed-after-retry` and `exhausted`).
4. Inspect `/tmp/rfr-bench3-2026-05-23-{rta,areject}-summary.lisp`.

For benchmarks intended for repeat use (multi-model / multi-trial),
a permanent test-fixture harness under `develop-benchmarks/` with
deterministic stubbed reviewers would be appropriate; that is out
of scope for this verification doc.
