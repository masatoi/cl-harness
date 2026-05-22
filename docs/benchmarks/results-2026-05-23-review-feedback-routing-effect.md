# review-on vs review-off effect — N=1 across 5 fixtures

**Date**: 2026-05-23
**Model**: `Qwen/Qwen3.6-35B-A3B` (SGLang @ 192.168.0.17:8000)
**Code**: cl-harness post-merge of `review-feedback-routing` (`e2d4987`).
**Settings**: temperature 0, max_tokens 4096, `enable_thinking: false`,
`:max-replans 1`, single trial per cell. stdio MCP transport.
**Driver**: `/tmp/rfr-bench4.lisp` (10 cells = 5 fixtures × 2 arms).

## Question

Does enabling the LLM-driven review pipeline (`:review-policy :auto`
+ `:max-impl-review-revisions 2`) change pass-rate compared to fully
disabled review (`:review-policy :none`) on greenfield develop
benchmarks?

The companion doc
`results-2026-05-23-review-feedback-routing.md` already confirms all
four `review_final_outcome` values fire correctly on live traffic.
This bench attempts the next-level question: **does the feature
actually help solve harder problems?**

## Result table

| Task | review-off | review-on | Notes |
|---|---|---|---|
| 102-counter-class | **ERROR** (Qwen I/O timeout @ 876s) | `:STUCK` (741s) | Both fail; off errored at the LLM endpoint. |
| 103-fizz-buzz     | `:LIMIT-EXHAUSTED` (422s, 3-step plan, 0 impl-reviews) | **`:PASSED`** (447s, 2-step plan, 2 impl-reviews, 0 rejections) | **Only fixture with a clean pass-rate diff.** |
| 104-cache-simple  | `:STUCK` (344s) | **ERROR** (Qwen I/O timeout @ 2853s) | Both fail; on errored. |
| 105-validate-email | **ERROR** (Qwen I/O timeout @ 1002s) | `:LIMIT-EXHAUSTED` (676s) | Both fail; off errored. |
| 106-format-currency | **`:PASSED`** (513s, 3-step plan, 0 impl-reviews) | **ERROR** (Qwen I/O timeout @ 819s) | off passes; on errored before reaching a conclusion. |

**4 of 10 cells errored at the LLM endpoint.** The SGLang Qwen3
server became unstable under the ~2-hour continuous-load profile of
this bench; the harness's dexador read-timeout (600s, since v0.5.1)
correctly surfaced the failures rather than hanging. The errored
cells are not signal about the feature — they are signal about the
endpoint's stability under sustained load.

## Cells with clean comparison

Only **103-fizz-buzz** produced clean results in both arms. N=1
clean comparison.

- **off** → `:LIMIT-EXHAUSTED` after running a 3-step planner-authored
  plan, replanning once, and being unable to converge before
  `:max-replans 1` was hit.
- **on** → `:PASSED` with a 2-step plan, no replans, 2 implementation
  reviews (one per step), zero rejections.

## Interpretation

Two things appear true:

1. **`:review-policy :auto` can improve pass-rate**, at least on this
   one fixture under this configuration. Same model, same goal,
   same code, same budgets — the only difference is the upstream
   review pipeline being on.

2. **The improvement is not from the new inner-loop.** Both arms had
   `impl-rejections: 0` and `review_retries: 0`. The reviewer never
   rejected, so the new retry loop never fired. The mechanism that
   helped was either:
   - `generate-develop-spec` extracting acceptance_criteria from the
     goal and threading them into the planner's prompt, OR
   - the plan-review / test-review gates causing the planner to
     converge on a different (here: smaller, 2-step instead of
     3-step) plan that fits the `:max-replans 1` budget.

This is consistent with the design (see
`docs/superpowers/specs/2026-05-22-review-feedback-routing-design.md`
§1.1): the new feature is one of several review-enabled behaviors.
The bench measures the package, not the feature in isolation.

The companion doc isolates the feature with a stubbed reviewer
(reject-then-approve, always-reject) and confirms the inner-loop
mechanics work end-to-end on live LLM traffic; this bench fails to
find a natural rejection because Qwen3.6 acting as its own reviewer
consistently approves its own implementation.

## Limitations

- **N=1 clean comparison.** One fixture is not a population. The
  observation is a positive instance, not a statistic. Multi-trial
  multi-model sweeps would be the next step.
- **Endpoint instability dominated the run.** 40% error rate on
  LLM calls during a 2-hour bench window. Re-running on a quieter
  endpoint (or with retries-on-transport-failure tuned higher) is
  the obvious next move if this bench is to be a primary
  measurement.
- **No natural inner-loop engagement.** This bench's signal is
  about the review-pipeline-as-a-whole, not the new retry feature.
  The retry feature's value (catching rejected implementations and
  retrying with feedback) requires either:
  - a stricter reviewer that actually rejects (different model,
    different prompt, multi-trial sample to catch occasional
    rejections), or
  - synthetic scenarios with a stub reviewer (covered in the
    companion doc).
- **Plan-size confound on 103-fizz-buzz.** off's 3-step plan vs
  on's 2-step plan is the proximate cause of off's
  `:LIMIT-EXHAUSTED` and on's `:PASSED`. Increasing
  `:max-replans` would likely close this gap, suggesting the
  on-arm benefit here is in part a planner-budget effect.
- **`:max-replans 1` for runtime bounding.** Production default is
  3. Both arms got 1 replan budget. Easier tasks would normally
  recover via replan; here neither arm got that chance on 102/104.
- **Single-task wall-clock varied 343s – 2853s.** Latency from
  the endpoint dominated; not a feature signal.

## Recommendation

To turn this into a stable measurement, the next experiment should:

1. **Use a stricter (cross-model) reviewer.** Either a different
   LLM in the reviewer seat, or a tighter `review-development-artifact`
   system prompt that flags substantive issues. Without that, Qwen
   self-review is too permissive to exercise the new feature.
2. **Run multiple trials.** N=3 per cell at minimum to bound LLM
   variance.
3. **Increase `:max-replans` to the default 3.** The current
   N=1-replan bound makes pass-rate dependent on planner stability,
   not on the feature being measured.
4. **Possibly reduce the fixture set** to ones in the
   "medium-difficulty band" where the implementer can reach
   verify-green (so the implementation review actually fires) but
   the test is loose enough that a stricter reviewer would catch
   gaps.

## Summary

- The hypothesis "enabling the reviewer improves pass-rate on
  harder problems" has **one supportive instance**
  (103-fizz-buzz: off failed, on passed) in this bench.
- The improvement is **not** attributable to the new inner-loop
  feature in isolation — `:impl-review-retry` never fired.
- The companion live-coverage bench independently confirms the
  inner-loop mechanics work; quantitative pass-rate impact awaits
  a stricter-reviewer experiment.
