# Goal-Backed Review Gates for `develop`

## Summary

`develop` currently risks treating planner-generated tests as the
source of truth. This plan changes that hierarchy: the natural-language
goal is first distilled into explicit acceptance criteria, and those
criteria become the reference for planning, test generation,
implementation, and review.

The new flow adds LLM-driven review gates around the plan, generated
tests, implementation result, and any requested test changes. Test
changes are additive-only in this phase: the harness may add coverage,
but must not weaken, delete, skip, or relax existing tests.

## Key Changes

- Add a `develop-spec` concept generated at the start of `develop`.
  It contains the original goal, numbered acceptance criteria
  (`AC-1`, `AC-2`, ...), non-goals, and risk notes. This becomes the
  source of truth above generated tests.

- Add a Plan Review Gate after planner output. The reviewer checks
  whether the plan covers all acceptance criteria, whether step order is
  coherent, and whether any step overreaches the goal. Rejected plans
  are sent back to the planner with review feedback.

- Add a Test Adequacy Review Gate before materializing planner-authored
  tests. The reviewer checks whether each `test_source` actually
  constrains its mapped acceptance criteria, instead of being only a
  smoke test or implementation-shaped assertion.

- Extend the implementer action schema with `test_change_request`.
  During implementation, the agent may report that the current generated
  tests are incomplete or misleading. The request must include the
  affected criteria, rationale, and proposed additive test source.

- Add a Test Change Review Gate. Only additive changes are approved:
  adding a new `deftest`, or adding assertions/cases to generated tests.
  Deleting tests, weakening expectations, skipping tests, or changing
  existing project tests is rejected.

- Add an Implementation Review Gate after a step passes verification.
  The reviewer checks that the implementation satisfies the acceptance
  criteria, does not merely overfit the generated tests, and remains
  consistent with existing package/export/ASDF conventions.

- Record review state on `develop-state`: review decisions, generated
  test records, and test change requests. Include these in the
  structured develop report.

- Add `develop` controls with safe defaults:
  `:review-policy :auto`, `:test-revision-policy :additive-only`,
  `:max-review-replans 2`, and `:max-test-revisions 3`. Unless a
  separate review provider is supplied, reuse the main provider.

## Behavioral Flow

1. Generate a `develop-spec` from the goal.
2. Generate an initial plan and tests with the planner.
3. Run Plan Review. If rejected, replan with the feedback.
4. Run Test Adequacy Review. If rejected, revise the plan/tests before
   materializing tests.
5. Materialize only approved generated tests.
6. Run the implementer loop as today.
7. If the implementer emits `test_change_request`, run Test Change
   Review and apply only approved additive test changes.
8. After step verification passes, run Implementation Review.
9. If Implementation Review rejects, feed the review feedback into the
   next fix/replan context.
10. Finish only after all steps pass, clean verification passes, and
    integration review/reporting completes.

## Test Plan

- A plan that does not cover all acceptance criteria is rejected before
  any generated test is materialized.

- A syntactically valid `(deftest ...)` that does not constrain the
  relevant acceptance criteria is rejected by Test Adequacy Review.

- A `test_change_request` adding a new `deftest` for an uncovered
  criterion is approved and materialized.

- A `test_change_request` that deletes an assertion, weakens an
  expected value, skips a test, or modifies existing project tests is
  rejected.

- Implementation Review feedback is propagated into the next
  implementation or replan context when a passing step is rejected.

- Review budget exhaustion returns `:limit-exhausted` and records the
  corresponding review limit in `limit-hit`.

- Existing `fix`, `bench`, and `develop` with review disabled retain
  current behavior.

## Assumptions

- Review gates are LLM-automated by default.

- Acceptance criteria, not generated tests, are the source of truth.

- Test revisions are additive-only in this phase.

- Human approval, mutation testing, non-Rove verifiers, and changing
  existing test expectations are deferred to later plans.
