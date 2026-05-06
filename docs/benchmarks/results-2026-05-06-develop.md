# develop-benchmarks v0.4 — greenfield suite × multi-model

**Date**: TBD (run pending)
**Code**: cl-harness v0.4.x (Phase 7 fixture set)
**Suite**: `develop-benchmarks/` (7 tasks: 100-greet, 101-double,
102-counter-class, 103-fizz-buzz, 104-cache-simple, 105-validate-email,
106-format-currency)

## Run protocol

For each (task × model × mode) cell:

1. Copy `develop-benchmarks/<task>/fixture/` to a fresh tmpdir via
   `cl-harness:prepare-develop-task-sandbox`.
2. Invoke `cl-harness:develop` with:
   - `:goal` from `develop-task.json`
   - `:project-root` set to the sandbox
   - `:test-file` set to `<sandbox>/tests/main-test.lisp`
   - `:mode` set to the cell's mode (`:mixed` is the default; the run
     also covers `:top-down` and `:bottom-up` for comparison on a
     subset of tasks).
   - `:max-replans 3`, `:max-patches 6`, `:max-turns 30`.
3. Record from the returned `develop-result`:
   - `develop-result-status` (`:passed` / `:limit-exhausted` / `:stuck`)
   - `develop-result-replan-count`
   - length of `develop-result-step-results`
   - sum of `develop-step-result-run-agent-state`'s turn / token counts
   - length of `develop-result-abstraction-ledger`
   - length of `develop-result-integration-issues` (Phase 5)
   - elapsed wall-clock seconds
4. Write the develop-level JSONL transcript path under
   `docs/benchmarks/logs/2026-05-06-develop/<task>-<model>-<mode>.jsonl`.

## Per-task results

| Task | Model | Mode | Status | Replans | Steps | Turns | Tokens | Issues | Elapsed s | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 100-greet | _TBD_ | mixed | _TBD_ | | | | | | | |
| 101-double | _TBD_ | mixed | _TBD_ | | | | | | | |
| 102-counter-class | _TBD_ | mixed | _TBD_ | | | | | | | |
| 103-fizz-buzz | _TBD_ | mixed | _TBD_ | | | | | | | |
| 104-cache-simple | _TBD_ | mixed | _TBD_ | | | | | | | |
| 105-validate-email | _TBD_ | mixed | _TBD_ | | | | | | | |
| 106-format-currency | _TBD_ | mixed | _TBD_ | | | | | | | |

(Repeat the table per (model × mode) combination.)

## Per-condition aggregate

| Model | Mode | Tasks | Passed | Pass-rate | Mean replans | Mean turns | Mean tokens | Mean elapsed s |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| _TBD_ | mixed | 7 | _TBD_ | | | | | |
| _TBD_ | top-down | 7 | _TBD_ | | | | | |
| _TBD_ | bottom-up | 7 | _TBD_ | | | | | |

## Mode comparison (per-task)

For tasks where multiple modes were attempted, list pass-rate and mean
turns side-by-side so the explore-first vs implement-first trade-off
is visible.

| Task | Mixed | Top-down | Bottom-up |
|---|---|---|---|
| _TBD_ | | | |

## Anomalies

(Document any cells where status was reported as `:passed` but
inspection showed an unfixed sandbox, or where the integration check
flagged exports that did not show up in failed_tests, etc.)

## Comparison with v0.3 baseline

The v0.3 develop-benchmarks set covers only `100-greet` / `101-double`
(2 tasks). Compare those two cells here for regression detection.

| Task | v0.3 | v0.4 (this run) |
|---|---|---|
| 100-greet | _from results-2026-05-06.md_ | _TBD_ |
| 101-double | _from results-2026-05-06.md_ | _TBD_ |

## Methodology notes

- Sandbox copies are deleted after each run, so `develop-result-step-results`
  is the only durable record of the per-step `run-agent-state`.
- `:integration-issues` per task should be 0 for greenfield work; any
  non-zero value indicates a planner-authored test imported a symbol
  the executor never exported.
- Mode-comparison cells use the same goal + sandbox seed; only
  `:mode` differs. Run them in randomised order to keep network /
  endpoint variance from biasing the comparison.
