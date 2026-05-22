# review-feedback-routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `%review-implementation` rejection feedback through an inner-loop in `%execute-step` that retries `run-agent` with the feedback prepended to the issue string, bounded by `:max-impl-review-revisions` (default 2). Small-fix rejections recover without plan regeneration.

**Architecture:** Add a retry loop inside the existing `(block run-step (loop ...))` in `%execute-step`. The loop reuses `make-run-config` per iteration to thread an enriched issue string. `%review-implementation` is extended to return `(values approved-p feedback)`. `%enriched-issue` gains a `:review-feedback` keyword that prepends a feedback section ahead of the existing exploration memo. An `:impl-review-passed-p` flag carries the inner-loop verdict out to the outer status determination, eliminating duplicate review calls.

**Tech Stack:** SBCL + ASDF, `rove` for tests, no new dependencies. Modifies the existing orchestrator + cli wiring only.

**Spec:** `docs/superpowers/specs/2026-05-22-review-feedback-routing-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/orchestrator.lisp` | Modify | `%review-implementation` return shape, `%enriched-issue` arg, `%execute-step` loop body + new kwarg, `execute-plan` + `develop` kwarg pass-through |
| `src/cli.lisp` | Modify (L348-area) | Add `:max-impl-review-revisions 2` kwarg to public `develop` and thread to orchestrator |
| `src/cli-main.lisp` | Modify (L238-area + L215-area) | New clingon option + handler getopt |
| `tests/orchestrator-test.lisp` | Modify | 6 new deftests covering inner-loop behavior |
| `README.md` | Modify | Add `--max-impl-review-revisions` flag to develop section |
| `docs/cl-harness-prd.md` | Modify | One-paragraph note in develop section about inner-loop retry |

No new files. All changes are within existing modules.

---

## Task 1: `%review-implementation` returns (values approved-p feedback)

**Files:**
- Modify: `src/orchestrator.lisp` (`%review-implementation` at L497-512)
- Test: `tests/orchestrator-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/orchestrator-test.lisp` (after existing deftests, before final paren of in-package block — i.e., as a new top-level deftest):

```lisp
(deftest review-implementation-returns-feedback
  (testing "approved decision returns (values t nil-or-feedback)"
    (let* ((decision (cl-harness/src/review:make-review-decision
                      :kind :implementation
                      :status :approved
                      :feedback "looks good"))
           (review-fn (lambda (kind &key &allow-other-keys)
                        (declare (ignore kind))
                        decision))
           (state (make-instance 'cl-harness/src/agent:agent-state
                                 :status :passed))
           (devstate (cl-harness/src/state:make-develop-state
                      :goal "g" :review-policy :auto))
           (step (cl-harness/src/planner:make-plan-step
                  :index 0 :issue "x" :test-name "tx"
                  :test-source "(deftest tx)")))
      (multiple-value-bind (approved-p feedback)
          (cl-harness/src/orchestrator::%review-implementation
           step state review-fn nil devstate)
        (ok (eq t approved-p))
        ;; feedback may be the decision's feedback string or nil
        (ok (or (null feedback) (stringp feedback))))))
  (testing "rejected decision returns (values nil feedback-string)"
    (let* ((decision (cl-harness/src/review:make-review-decision
                      :kind :implementation
                      :status :rejected
                      :feedback "rename X to Y"))
           (review-fn (lambda (kind &key &allow-other-keys)
                        (declare (ignore kind))
                        decision))
           (state (make-instance 'cl-harness/src/agent:agent-state
                                 :status :passed))
           (devstate (cl-harness/src/state:make-develop-state
                      :goal "g" :review-policy :auto))
           (step (cl-harness/src/planner:make-plan-step
                  :index 0 :issue "x" :test-name "tx"
                  :test-source "(deftest tx)")))
      (multiple-value-bind (approved-p feedback)
          (cl-harness/src/orchestrator::%review-implementation
           step state review-fn nil devstate)
        (ok (null approved-p))
        (ok (equal "rename X to Y" feedback)))))
  (testing "disabled review returns (values t nil)"
    (let* ((state (make-instance 'cl-harness/src/agent:agent-state
                                 :status :passed))
           (devstate (cl-harness/src/state:make-develop-state
                      :goal "g" :review-policy :none))
           (step (cl-harness/src/planner:make-plan-step
                  :index 0 :issue "x" :test-name "tx"
                  :test-source "(deftest tx)")))
      (multiple-value-bind (approved-p feedback)
          (cl-harness/src/orchestrator::%review-implementation
           step state (lambda (k &key &allow-other-keys) (declare (ignore k))
                              (error "should not be called"))
           nil devstate)
        (ok (eq t approved-p))
        (ok (null feedback))))))
```

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/orchestrator-test::review-implementation-returns-feedback"
```

Expected: rejected case fails (`feedback` is unbound or NIL when it should be `"rename X to Y"`), because the current implementation returns a single boolean.

- [ ] **Step 3: Modify `%review-implementation` to return 2 values**

Use `mcp__cl-mcp__lisp-edit-form` with `operation=replace` on `%review-implementation`. New body:

```lisp
(defun %review-implementation (step state review-fn provider develop-state)
  "Return (VALUES APPROVED-P FEEDBACK) for the implementation review of
STEP. When review is disabled or STATE is not :passed, returns
(VALUES T NIL) (the no-op approve)."
  (if (or (not (%review-enabled-p develop-state))
          (not (eq :passed (%read-status-from-state state))))
      (values t nil)
      (let ((decision
              (%call-review
               review-fn :implementation
               :develop-state develop-state
               :provider provider
               :step step
               :implementation-summary
               (format nil "Step ~D (~A) passed verification."
                       (plan-step-index step)
                       (plan-step-test-name step)))))
        (values (review-decision-approved-p decision)
                (review-decision-feedback decision)))))
```

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/orchestrator-test::review-implementation-returns-feedback"
```

Expected: 1 passed (3 testing blocks).

Also run full suite:
```
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```
Expected: 438 passed (437 baseline + 1 new test). Old test at L626-632 that calls `(not (%review-implementation ...))` keeps working because the boolean is the first return value — multiple-value-truthiness preserves backward compat.

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "review-feedback: %review-implementation returns (values approved-p feedback)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `%enriched-issue` accepts `:review-feedback` keyword

**Files:**
- Modify: `src/orchestrator.lisp` (`%enriched-issue` at L307-315)
- Test: `tests/orchestrator-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/orchestrator-test.lisp`:

```lisp
(deftest enriched-issue-with-review-feedback
  (let ((step (cl-harness/src/planner:make-plan-step
               :index 1 :issue "original task body" :test-name "tx"
               :test-source "(deftest tx)")))
    (testing "no extras returns plain issue"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue step nil)))
        (ok (equal "original task body" result))))
    (testing "memo only prepends exploration block"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue
                     step "memo content")))
        (ok (search "## Prior exploration (read-only)" result))
        (ok (search "memo content" result))
        (ok (search "original task body" result))
        (ok (not (search "Prior implementation review feedback" result)))))
    (testing "review-feedback only prepends feedback block"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue
                     step nil :review-feedback "rename X to Y")))
        (ok (search "## Prior implementation review feedback" result))
        (ok (search "rename X to Y" result))
        (ok (search "original task body" result))
        (ok (not (search "Prior exploration" result)))))
    (testing "both prepends review-feedback BEFORE exploration"
      (let* ((result (cl-harness/src/orchestrator::%enriched-issue
                      step "memo content" :review-feedback "rename X to Y"))
             (fb-pos (search "Prior implementation review feedback" result))
             (exp-pos (search "Prior exploration" result))
             (task-pos (search "## Task" result)))
        (ok (and fb-pos exp-pos task-pos))
        (ok (< fb-pos exp-pos))
        (ok (< exp-pos task-pos))))
    (testing "empty-string review-feedback is treated like NIL"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue
                     step nil :review-feedback "")))
        (ok (equal "original task body" result))))))
```

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/orchestrator-test::enriched-issue-with-review-feedback"
```

Expected: fails because `%enriched-issue` doesn't accept `:review-feedback` yet (signals `&KEY argument :REVIEW-FEEDBACK not in lambda list`).

- [ ] **Step 3: Modify `%enriched-issue`**

Use `mcp__cl-mcp__lisp-edit-form` with `operation=replace` on `%enriched-issue`. New body:

```lisp
(defun %enriched-issue (step memo &key review-feedback)
  "Return the issue string fed to the implement step. When
REVIEW-FEEDBACK is non-empty, prepend it as a `Prior implementation
review feedback' block (rendered first because it is the most
recent and most specific signal). When MEMO is non-empty, prepend
the explore memo as a `Prior exploration:' block. The original
issue is shown last under `## Task'. Sections with empty content
are omitted."
  (let* ((fb (and review-feedback (plusp (length review-feedback))
                  review-feedback))
         (mm (and memo (plusp (length memo)) memo)))
    (cond
      ((and (null fb) (null mm))
       (plan-step-issue step))
      (t
       (with-output-to-string (s)
         (when fb
           (format s "## Prior implementation review feedback~%~A~%~%" fb))
         (when mm
           (format s "## Prior exploration (read-only)~%~A~%~%" mm))
         (format s "## Task~%~A" (plan-step-issue step)))))))
```

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/orchestrator-test::enriched-issue-with-review-feedback"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes (5 testing blocks). Full suite: 439 passed (438 + 1).

The existing call site `(plan-step-issue step)` vs the new "memo prepend" path needs care: the OLD `%enriched-issue` returned the bare issue string when memo was nil/empty AND used a different format when memo was non-empty. The new cond preserves both behaviors.

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "review-feedback: %enriched-issue accepts :review-feedback kwarg

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `%execute-step` inner-loop with retry + new kwarg + JSONL event

**Files:**
- Modify: `src/orchestrator.lisp` (`%execute-step` signature + body, especially L514-632)
- Test: `tests/orchestrator-test.lisp` (1 driving deftest for this task; remaining 5 tests in Task 4)

This is the largest task. The TDD test verifies the core "approves on second attempt" behavior; remaining tests come in Task 4 once the infrastructure is in.

- [ ] **Step 1: Write the failing test**

Append to `tests/orchestrator-test.lisp`. The test stubs out `run-fn` and `review-fn` to exercise the inner-loop without LLM/MCP/disk dependencies:

```lisp
(defun %make-fake-passed-state ()
  "A minimal agent-state with status :passed for inner-loop stub tests."
  (make-instance 'cl-harness/src/agent:agent-state :status :passed))

(deftest impl-review-inner-loop-approves-on-second-attempt
  (let* ((run-fn-calls (list))
         (review-fn-calls (list))
         (run-fn (lambda (rc provider mcp-client policy logger
                          &key develop-state)
                   (declare (ignore provider mcp-client policy logger
                                    develop-state))
                   (push (cl-harness/src/config:run-config-issue rc)
                         run-fn-calls)
                   (%make-fake-passed-state)))
         (decisions (list (cl-harness/src/review:make-review-decision
                           :kind :implementation
                           :status :rejected
                           :feedback "rename X to Y")
                          (cl-harness/src/review:make-review-decision
                           :kind :implementation
                           :status :approved
                           :feedback "ok")))
         (review-fn (lambda (kind &key &allow-other-keys)
                      (push kind review-fn-calls)
                      (pop decisions)))
         (step (cl-harness/src/planner:make-plan-step
                :index 1 :issue "fix the bug" :test-name "tx"
                :test-source "(deftest tx)"
                :needs-exploration :none))
         (devstate (cl-harness/src/state:make-develop-state
                    :goal "g" :review-policy :auto))
         (logger nil)
         (test-file "tests/main-test.lisp"))
    (let ((result
           (cl-harness/src/orchestrator::%execute-step
            step run-fn "/tmp/fake-root/" "demo" "demo/tests"
            :generic-mcp test-file logger nil nil nil nil
            :develop-state devstate
            :review-fn review-fn
            :max-impl-review-revisions 2)))
      (testing "run-fn called twice (initial + 1 retry)"
        (ok (= 2 (length run-fn-calls))))
      (testing "review-fn called twice"
        (ok (= 2 (length review-fn-calls))))
      (testing "second run-fn invocation issue contains feedback"
        ;; first call is at the tail of run-fn-calls (push pre-pended)
        (let ((second-issue (first run-fn-calls)))
          (ok (search "Prior implementation review feedback" second-issue))
          (ok (search "rename X to Y" second-issue))))
      (testing "first run-fn invocation has plain issue"
        (let ((first-issue (second run-fn-calls)))
          (ok (not (search "Prior implementation review feedback" first-issue)))))
      (testing "final status is :passed"
        (ok (eq :passed
                (cl-harness/src/orchestrator:develop-step-result-status result)))))))
```

Note: `%execute-step`'s signature requires several positional args (project-root system test-system condition test-file logger provider mcp-client run-limits explore-fn). The test fills them with stubs/nil. Adjust if existing tests in `orchestrator-test.lisp` use a different positional ordering — read the current `%execute-step` lambda list and match it.

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/orchestrator-test::impl-review-inner-loop-approves-on-second-attempt"
```

Expected: fails because `:max-impl-review-revisions` is not yet a kwarg of `%execute-step` (signals `Unknown &KEY argument :MAX-IMPL-REVIEW-REVISIONS`), OR fails because the inner-loop logic isn't there.

- [ ] **Step 3: Modify `%execute-step` signature and loop body**

Use `mcp__cl-mcp__lisp-edit-form` with `operation=replace` on `%execute-step`. Add the new kwarg and replace the existing loop body (current L606-632) with the inner-loop version. New body (full function):

```lisp
(defun %execute-step (step run-fn project-root system test-system
                      condition test-file logger
                      provider mcp-client run-limits explore-fn
                      &key develop-state
                           (review-fn #'review-development-artifact)
                           (max-test-revisions 3)
                           (max-impl-review-revisions 2))
  "Materialize the step's test, optionally run an exploration sub-agent,
build a RUN-CONFIG (with the explore memo prepended to the issue
when present), call RUN-FN, return a DEVELOP-STEP-RESULT.

The body now contains two cooperative retry mechanisms inside the
RUN-STEP loop:

1. Test-change-request loop: when RUN-AGENT returns a
   :TEST-CHANGE-REQUEST action, REVIEW-FN reviews and (on approval)
   MATERIALIZE-TEST-SOURCE appends the new deftest. The loop then
   re-runs RUN-AGENT against the augmented test file.

2. Implementation-review loop: when verification passes but
   REVIEW-FN rejects the implementation, the loop re-runs RUN-AGENT
   with the rejection feedback prepended to the issue string,
   bounded by MAX-IMPL-REVIEW-REVISIONS. On budget exhaustion the
   final status is overwritten to :REVIEW-REJECTED for the outer
   develop loop.

When PLAN-STEP's needs-exploration is :LIGHTWEIGHT or :DEEP and
EXPLORE-FN is non-nil, an explore loop runs FIRST against the same
provider/mcp-client with policy :EXPLORE (read-only). The memo
returned from that loop is captured in the develop-step-result
and prepended to the implement issue.

When DEVELOP-STATE is non-nil, the step's PLAN-STEP-INDEX is written
to its CURRENT-STEP-INDEX slot on entry and cleared (set to NIL) on
exit via UNWIND-PROTECT."
  (validate-test-source (plan-step-test-source step) (plan-step-index step))
  (materialize-test-source (%resolve-test-file-path project-root test-file)
                           (plan-step-test-source step))
  (when develop-state
    (setf (develop-state-current-step-index develop-state)
          (plan-step-index step)))
  (unwind-protect
       (let* ((needs (plan-step-needs-exploration step))
              (do-explore (and explore-fn
                               needs
                               (not (eq :none needs))))
              (explore-policy (when do-explore (make-tool-policy :explore)))
              (run-logger-path
               (merge-pathnames
                (format nil "develop-step-~D-~A-~A.jsonl"
                        (plan-step-index step)
                        (plan-step-test-name step)
                        (get-internal-real-time))
                (uiop:temporary-directory)))
              (explore-orient-config
               (when do-explore
                 (make-run-config :project-root project-root
                                  :system system
                                  :test-system test-system
                                  :issue (plan-step-issue step)
                                  :condition :explore))))
         (%log-develop-event
          logger :step-start
          (alist-hash-table
           `(("step_index" . ,(plan-step-index step))
             ("test_name" . ,(plan-step-test-name step))
             ("issue" . ,(plan-step-issue step))
             ("needs_exploration" . ,(string-downcase
                                      (symbol-name (or needs :none))))
             ("transcript_path" . ,(namestring run-logger-path)))
           :test 'equal))
         (let* ((step-logger (open-run-logger run-logger-path))
                (explore-result
                 (when do-explore
                   (handler-case
                       (funcall explore-fn
                                explore-orient-config provider mcp-client
                                explore-policy step-logger
                                :plan-step step
                                :develop-state develop-state)
                     (error (c)
                       (%log-develop-event
                        logger :explore-aborted
                        (alist-hash-table
                         `(("step_index" . ,(plan-step-index step))
                           ("message" . ,(princ-to-string c)))
                         :test 'equal))
                       nil))))
                (memo (when explore-result (explore-result-memo explore-result)))
                (abstraction-decisions
                 (when memo
                   (parse-abstraction-decisions memo
                                                :step-index (plan-step-index step))))
                (policy (make-tool-policy condition))
                (impl-retry-count 0)
                (review-feedback nil)
                (impl-review-passed-p nil)
                (state
                 (unwind-protect
                      (block run-step
                        (loop
                          for issue = (%enriched-issue
                                       step memo
                                       :review-feedback review-feedback)
                          for rc = (make-run-config
                                    :project-root project-root
                                    :system system
                                    :test-system test-system
                                    :issue issue
                                    :condition condition
                                    :limits (or run-limits
                                                (cl-harness/src/config:make-default-limits)))
                          for state = (funcall run-fn rc provider mcp-client
                                               policy step-logger
                                               :develop-state develop-state)
                          do (cond
                               ;; 1) test-change-request takes priority
                               ((and develop-state
                                     (< (develop-state-test-revision-count
                                         develop-state)
                                         max-test-revisions)
                                     (%maybe-handle-test-change-request
                                      step state test-file review-fn provider
                                      develop-state))
                                (%log-develop-event
                                 logger :test-change-applied
                                 (alist-hash-table
                                  `(("step_index" . ,(plan-step-index step)))
                                  :test 'equal)))
                               ;; 2) verify :passed -> implementation review
                               ((eq :passed (%read-status-from-state state))
                                (multiple-value-bind (approved-p feedback)
                                    (%review-implementation
                                     step state review-fn provider develop-state)
                                  (cond
                                    (approved-p
                                     (setf impl-review-passed-p t)
                                     (return-from run-step state))
                                    ((>= impl-retry-count max-impl-review-revisions)
                                     ;; budget exhausted; outer status logic
                                     ;; will overwrite :passed -> :review-rejected
                                     (return-from run-step state))
                                    (t
                                     (incf impl-retry-count)
                                     (setf review-feedback feedback)
                                     (%log-develop-event
                                      logger :impl-review-retry
                                      (alist-hash-table
                                       `(("step_index" . ,(plan-step-index step))
                                         ("retry_count" . ,impl-retry-count)
                                         ("feedback" . ,(%truncate-feedback
                                                         feedback 1500)))
                                       :test 'equal))))))
                               ;; 3) verify failed or other terminal status
                               (t (return-from run-step state)))))
                   (close-run-logger step-logger)))
                (status (let ((raw (%read-status-from-state state)))
                          (cond
                            ((and (eq :passed raw)
                                  (%review-enabled-p develop-state)
                                  (not impl-review-passed-p))
                             :review-rejected)
                            (t raw))))
                (result (make-instance
                         'develop-step-result
                         :step-index (plan-step-index step)
                         :test-name (plan-step-test-name step)
                         :run-config (make-run-config
                                      :project-root project-root
                                      :system system
                                      :test-system test-system
                                      :issue (plan-step-issue step)
                                      :condition condition
                                      :limits (or run-limits
                                                  (cl-harness/src/config:make-default-limits)))
                         :status status
                         :run-agent-state state
                         :transcript-path run-logger-path
                         :explore-result explore-result
                         :abstraction-decisions abstraction-decisions)))
           (%record-and-resolve-failures develop-state state step)
           (%promote-matching-findings develop-state)
           (when abstraction-decisions
             (cl-harness/src/state:develop-state-record-abstraction-decisions
              develop-state abstraction-decisions))
           (%log-develop-event
            logger :step-end
            (alist-hash-table
             `(("step_index" . ,(plan-step-index step))
               ("status" . ,(string-downcase (symbol-name status)))
               ("review_retries" . ,impl-retry-count)
               ("review_final_outcome"
                . ,(cond
                     ((not (%review-enabled-p develop-state)) "n-a")
                     ((not (eq :passed (%read-status-from-state state)))
                      "n-a")
                     (impl-review-passed-p
                      (if (zerop impl-retry-count)
                          "passed-first-try"
                          "passed-after-retry"))
                     (t "exhausted"))))
             :test 'equal))
           result))
    (when develop-state
      (setf (develop-state-current-step-index develop-state) nil))))
```

**Important**: this rewrite removes the previous separate `rc` let-binding (the loop now creates `rc` per iteration) and removes the old `if`-shaped test-change loop (replaced with `cond`). The `%step-event-payload`-based `:step-end` event is REPLACED with an inline payload that carries `review_retries` + `review_final_outcome`. The `%step-event-payload` helper may now be dead code — leave it alone for this task (it is also used elsewhere); cleanup is a Task 7+ concern only if mallet flags it.

**Also add**: a small local truncation helper alongside `%execute-step`. Insert this defun ABOVE `%execute-step` (e.g., between `%review-implementation` and `%execute-step`):

```lisp
(defun %truncate-feedback (text cap)
  "Truncate TEXT to at most CAP chars, appending an elision footer.
Returns NIL when TEXT is NIL."
  (cond
    ((null text) nil)
    ((<= (length text) cap) text)
    (t (format nil "~A~%[... truncated, ~D chars elided ...]"
               (subseq text 0 cap) (- (length text) cap)))))
```

Use `mcp__cl-mcp__lisp-edit-form` with `operation=insert_before` on `%execute-step` to place it.

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/orchestrator-test::impl-review-inner-loop-approves-on-second-attempt"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes (5 testing blocks). Full suite: 440 passed (439 + 1).

If existing orchestrator tests fail, the most likely cause is that the new `:step-end` payload format diverges from what older tests assert. Inspect the failure: if it is asserting `review_retries`, check the test fixture; if it is asserting only existing fields, the new payload should be a superset and tests should still pass. If a test was reading `%step-event-payload`'s output directly, update the test to read the new fields too.

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "review-feedback: %execute-step inner-loop with :max-impl-review-revisions

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Add 4 remaining inner-loop behavior deftests

**Files:**
- Modify: `tests/orchestrator-test.lisp` (4 new deftests appended)

All 4 deftests verify already-implemented behavior — no source code changes in this task.

- [ ] **Step 1: Write `impl-review-inner-loop-exhausts-budget`**

Append:

```lisp
(deftest impl-review-inner-loop-exhausts-budget
  (let* ((run-fn-calls 0)
         (run-fn (lambda (rc provider mcp-client policy logger
                          &key develop-state)
                   (declare (ignore rc provider mcp-client policy logger
                                    develop-state))
                   (incf run-fn-calls)
                   (%make-fake-passed-state)))
         (review-fn (lambda (kind &key &allow-other-keys)
                      (declare (ignore kind))
                      (cl-harness/src/review:make-review-decision
                       :kind :implementation
                       :status :rejected
                       :feedback "never approved")))
         (step (cl-harness/src/planner:make-plan-step
                :index 1 :issue "x" :test-name "tx"
                :test-source "(deftest tx)" :needs-exploration :none))
         (devstate (cl-harness/src/state:make-develop-state
                    :goal "g" :review-policy :auto))
         (result
          (cl-harness/src/orchestrator::%execute-step
           step run-fn "/tmp/fake-root/" "demo" "demo/tests"
           :generic-mcp "tests/main-test.lisp" nil nil nil nil nil
           :develop-state devstate
           :review-fn review-fn
           :max-impl-review-revisions 1)))
    (testing "run-fn called twice (initial + 1 retry)"
      (ok (= 2 run-fn-calls)))
    (testing "final status is :review-rejected"
      (ok (eq :review-rejected
              (cl-harness/src/orchestrator:develop-step-result-status result))))))
```

- [ ] **Step 2: Write `impl-review-disabled-when-budget-zero`**

```lisp
(deftest impl-review-disabled-when-budget-zero
  (let* ((run-fn-calls 0)
         (run-fn (lambda (rc provider mcp-client policy logger
                          &key develop-state)
                   (declare (ignore rc provider mcp-client policy logger
                                    develop-state))
                   (incf run-fn-calls)
                   (%make-fake-passed-state)))
         (review-fn (lambda (kind &key &allow-other-keys)
                      (declare (ignore kind))
                      (cl-harness/src/review:make-review-decision
                       :kind :implementation
                       :status :rejected
                       :feedback "rejected")))
         (step (cl-harness/src/planner:make-plan-step
                :index 1 :issue "x" :test-name "tx"
                :test-source "(deftest tx)" :needs-exploration :none))
         (devstate (cl-harness/src/state:make-develop-state
                    :goal "g" :review-policy :auto))
         (result
          (cl-harness/src/orchestrator::%execute-step
           step run-fn "/tmp/fake-root/" "demo" "demo/tests"
           :generic-mcp "tests/main-test.lisp" nil nil nil nil nil
           :develop-state devstate
           :review-fn review-fn
           :max-impl-review-revisions 0)))
    (testing "run-fn called once (no retries)"
      (ok (= 1 run-fn-calls)))
    (testing "final status is :review-rejected"
      (ok (eq :review-rejected
              (cl-harness/src/orchestrator:develop-step-result-status result))))))
```

- [ ] **Step 3: Write `impl-review-disabled-when-policy-none`**

```lisp
(deftest impl-review-disabled-when-policy-none
  (let* ((run-fn-calls 0)
         (review-fn-calls 0)
         (run-fn (lambda (rc provider mcp-client policy logger
                          &key develop-state)
                   (declare (ignore rc provider mcp-client policy logger
                                    develop-state))
                   (incf run-fn-calls)
                   (%make-fake-passed-state)))
         (review-fn (lambda (kind &key &allow-other-keys)
                      (declare (ignore kind))
                      (incf review-fn-calls)
                      (cl-harness/src/review:make-review-decision
                       :kind :implementation
                       :status :approved
                       :feedback "")))
         (step (cl-harness/src/planner:make-plan-step
                :index 1 :issue "x" :test-name "tx"
                :test-source "(deftest tx)" :needs-exploration :none))
         (devstate (cl-harness/src/state:make-develop-state
                    :goal "g" :review-policy :none))
         (result
          (cl-harness/src/orchestrator::%execute-step
           step run-fn "/tmp/fake-root/" "demo" "demo/tests"
           :generic-mcp "tests/main-test.lisp" nil nil nil nil nil
           :develop-state devstate
           :review-fn review-fn
           :max-impl-review-revisions 2)))
    (testing "run-fn called once"
      (ok (= 1 run-fn-calls)))
    (testing "review-fn never called (policy :none short-circuits)"
      (ok (= 0 review-fn-calls)))
    (testing "final status is :passed"
      (ok (eq :passed
              (cl-harness/src/orchestrator:develop-step-result-status result))))))
```

- [ ] **Step 4: Write `impl-review-respects-test-change-priority`**

This one is the trickiest — it verifies test-change branch fires when run-fn returns `:test-change-request`. Append:

```lisp
(deftest impl-review-respects-test-change-priority
  ;; run-fn sequence: first call returns :test-change-request, second
  ;; call returns :passed. review-fn approves both test-change and
  ;; implementation. Verifies test-change branch is taken before
  ;; implementation-review branch.
  (let* ((run-fn-call-count 0)
         (run-fn (lambda (rc provider mcp-client policy logger
                          &key develop-state)
                   (declare (ignore rc provider mcp-client policy logger
                                    develop-state))
                   (incf run-fn-call-count)
                   (case run-fn-call-count
                     (1 (make-instance 'cl-harness/src/agent:agent-state
                                       :status :test-change-request
                                       :final-action
                                       (cl-harness/src/action:make-agent-action
                                        :type :test-change-request
                                        :test-source
                                        "(deftest extra-tx (ok t))"
                                        :criteria nil
                                        :rationale "need a new test")))
                     (otherwise (%make-fake-passed-state)))))
         (review-fn (lambda (kind &key &allow-other-keys)
                      (cl-harness/src/review:make-review-decision
                       :kind kind
                       :status :approved
                       :feedback ""))))
    ;; The test file must exist on disk for materialize-test-source.
    (let ((tmp-test-file (merge-pathnames
                          (format nil "scaffold-review-priority-~A.lisp"
                                  (get-internal-real-time))
                          (uiop:temporary-directory))))
      (with-open-file (s tmp-test-file :direction :output
                                       :if-does-not-exist :create
                                       :if-exists :supersede)
        (write-string "(defpackage #:demo/tests/main-test (:use #:cl #:rove))~%(in-package #:demo/tests/main-test)~%" s))
      (unwind-protect
           (let* ((step (cl-harness/src/planner:make-plan-step
                         :index 1 :issue "x" :test-name "tx"
                         :test-source "(deftest tx (ok t))"
                         :needs-exploration :none))
                  (devstate (cl-harness/src/state:make-develop-state
                             :goal "g" :review-policy :auto))
                  (result
                   (cl-harness/src/orchestrator::%execute-step
                    step run-fn (namestring (uiop:pathname-directory-pathname
                                              tmp-test-file))
                    "demo" "demo/tests"
                    :generic-mcp (namestring tmp-test-file) nil nil nil nil nil
                    :develop-state devstate
                    :review-fn review-fn
                    :max-impl-review-revisions 2)))
             (testing "run-fn called twice (test-change + final)"
               (ok (= 2 run-fn-call-count)))
             (testing "final status :passed"
               (ok (eq :passed
                       (cl-harness/src/orchestrator:develop-step-result-status
                        result))))
             (testing "test file extended with extra deftest"
               (let ((content (uiop:read-file-string tmp-test-file)))
                 (ok (search "(deftest extra-tx" content)))))
        (when (probe-file tmp-test-file)
          (delete-file tmp-test-file))))))
```

- [ ] **Step 5: Run tests to verify all 4 pass**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" tests=["cl-harness/tests/orchestrator-test::impl-review-inner-loop-exhausts-budget", "cl-harness/tests/orchestrator-test::impl-review-disabled-when-budget-zero", "cl-harness/tests/orchestrator-test::impl-review-disabled-when-policy-none", "cl-harness/tests/orchestrator-test::impl-review-respects-test-change-priority"]
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 4 passes individually. Full suite: 444 passed (440 + 4).

If `impl-review-respects-test-change-priority` fails because the `agent-action` accessor names differ from what's used here, read `src/action.lisp` for the actual constructor and slot readers, then adjust the test.

- [ ] **Step 6: Commit**

```bash
git add tests/orchestrator-test.lisp
git commit -m "review-feedback: 4 inner-loop behavior tests (exhaust/budget0/policy/test-change)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Thread `:max-impl-review-revisions` through `execute-plan` and `develop`

**Files:**
- Modify: `src/orchestrator.lisp` (`execute-plan` at L668-area, `develop` at L945-area)

- [ ] **Step 1: Add kwarg to `execute-plan` signature**

Use `mcp__cl-mcp__lisp-edit-form` on `execute-plan`. Add `(max-impl-review-revisions 2)` to the `&key` list and pass it to `%execute-step`:

```lisp
(defun execute-plan (plan &key project-root system test-system test-file
                               (condition :generic-mcp) provider mcp-client
                               run-limits log-path
                               (run-fn #'run-agent)
                               (explore-fn #'run-explore-agent)
                               develop-state
                               (review-fn #'review-development-artifact)
                               (max-test-revisions 3)
                               (max-impl-review-revisions 2))
  "Run PLAN ..."
  ;; ... existing body unchanged except for one line:
  ;; Inside the loop where %execute-step is called, ADD :max-impl-review-revisions:
  ;;   (%execute-step step run-fn project-root system test-system
  ;;                  condition test-file logger provider mcp-client
  ;;                  run-limits explore-fn
  ;;                  :develop-state develop-state
  ;;                  :review-fn review-fn
  ;;                  :max-test-revisions max-test-revisions
  ;;                  :max-impl-review-revisions max-impl-review-revisions)
  )
```

Read the existing `execute-plan` body via `mcp__cl-mcp__lisp-read-file` first, then surgically `lisp-edit-form` to add the kwarg + the parameter passthrough. Do NOT rewrite the entire function — only the signature and the single `%execute-step` call site change.

- [ ] **Step 2: Add kwarg to `develop` signature**

Same treatment for `develop` (L945-area). Add `(max-impl-review-revisions 2)` to the `&key` list and thread it to the `execute-plan` call inside `develop`'s body.

- [ ] **Step 3: Verify by reloading and running tests**

```
mcp__cl-mcp__load-system with system="cl-harness", force=true
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 444 passed (still, no new tests but the kwarg should not break existing call sites).

- [ ] **Step 4: Commit**

```bash
git add src/orchestrator.lisp
git commit -m "review-feedback: thread :max-impl-review-revisions through execute-plan/develop

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: CLI plumbing — `src/cli.lisp` programmatic + `src/cli-main.lisp` clingon

**Files:**
- Modify: `src/cli.lisp` (`develop` function around L348)
- Modify: `src/cli-main.lisp` (`develop-handler` at L215-area + `develop-options` at L238-area)

- [ ] **Step 1: Add `:max-impl-review-revisions` to `cli.lisp:develop`**

Read `src/cli.lisp:develop` first via `mcp__cl-mcp__lisp-read-file` with `name_pattern="^develop$"`. Add `(max-impl-review-revisions 2)` to its `&key` list, and add `:max-impl-review-revisions max-impl-review-revisions` to the inner `(cl-harness/src/orchestrator:develop ...)` call.

- [ ] **Step 2: Add `--max-impl-review-revisions` clingon option**

In `src/cli-main.lisp:develop-options` (around L285-289 where `--max-replans` lives), add a sibling:

```lisp
(clingon:make-option :integer :long-name "max-impl-review-revisions"
                     :description "maximum implementation-review retry rounds before :review-rejected (default 2)"
                     :initial-value 2 :key :max-impl-review-revisions)
```

- [ ] **Step 3: Pass-through in `develop-handler`**

In `src/cli-main.lisp:develop-handler` (around L215-234), add the line `:max-impl-review-revisions (clingon:getopt cmd :max-impl-review-revisions)` to the `develop` call.

- [ ] **Step 4: Verify by reloading**

```
mcp__cl-mcp__load-system with system="cl-harness", force=true
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 444 passed. Also verify the clingon command is well-formed:

```
mcp__cl-mcp__repl-eval with code="(length (clingon:command-options (cl-harness/src/cli-main::develop-command)))"
```

Expected: the count is +1 compared to before (one more option). The pre-Task-6 value was 18 (per scaffold doc spec review); now it should be 19.

- [ ] **Step 5: Commit**

```bash
git add src/cli.lisp src/cli-main.lisp
git commit -m "review-feedback: --max-impl-review-revisions CLI flag

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: README + PRD documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/cl-harness-prd.md`

- [ ] **Step 1: Add the flag to README develop section**

Open `README.md` and find `### Develop a feature from a goal — \`cl-harness develop\`` (around L266). Within the bash example block, the flag list currently has `--max-replans 3`. Add `--max-impl-review-revisions 2` immediately after it. Also add a paragraph after the existing terminal-status list:

```markdown
When an LLM review is enabled (default), `develop` runs an
implementation-review gate after each step's verification passes. If
the review rejects, `develop` re-runs the same step with the review
feedback prepended to the issue string, up to
`--max-impl-review-revisions` rounds (default 2). On budget
exhaustion the step is marked `:review-rejected` and the outer
replan loop fires as usual.
```

- [ ] **Step 2: Add one-paragraph note to PRD**

Open `docs/cl-harness-prd.md`. Find the develop-related section (search for `develop` heading; the PRD has multiple sections — pick the one that documents `cl-harness develop`'s workflow). Add a paragraph:

```markdown

### Implementation review feedback loop

After each plan-step's verification passes (`run-tests` returns
green), an LLM-driven implementation review gate runs. If the
review rejects, `%execute-step` re-runs the same step with the
review feedback prepended to the issue string (under a "## Prior
implementation review feedback" header). The retry budget is
controlled by `:max-impl-review-revisions` (default 2; CLI flag
`--max-impl-review-revisions`). On budget exhaustion the step is
marked `:review-rejected` and the outer replan loop takes over.
This avoids regenerating the entire plan when the reviewer's
correction is local to a single step's implementation.

```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/cl-harness-prd.md
git commit -m "docs: README + PRD note on implementation-review inner-loop

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Final integration check

**Files:**
- (verification only)

- [ ] **Step 1: Force-compile entire system to surface warnings**

```
mcp__cl-mcp__load-system with system="cl-harness", force=true, clear_fasls=true, timeout_seconds=240
```

Expected: success. UIOP "redefining" warnings are harmless and pre-existing — only flag warnings whose source mentions `:CL-HARNESS/SRC/ORCHESTRATOR`, `:CL-HARNESS/SRC/CLI`, `:CL-HARNESS/SRC/CLI-MAIN`, or `:CL-HARNESS/TESTS/ORCHESTRATOR-TEST`.

- [ ] **Step 2: Run full test suite**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests", timeout_seconds=600
```

Expected: 444 passed (437 baseline + 1 review-impl-feedback + 1 enriched-issue + 1 inner-loop-approves + 4 follow-up tests = 444). If counts differ, audit the deftest additions.

- [ ] **Step 3: Lint with mallet**

Try:

```bash
which mallet && mallet src/orchestrator.lisp src/cli.lisp src/cli-main.lisp tests/orchestrator-test.lisp || echo "mallet not available — skip"
```

If mallet flags issues, fix in place. Common ones for this kind of change:
- Lines > 100 chars in the new `%execute-step` body
- `let*` where `let` suffices in the new local bindings
- Unused parameters in deftest lambdas (suppress with `(declare (ignore ...))` if intentional)

- [ ] **Step 4: Verify summary log**

```bash
git log --oneline main..HEAD
```

Should show ~7 commits (one per task plus any review-fix commits).

- [ ] **Step 5: If any fixes were needed in Steps 1-3, commit them**

```bash
git status
# if changes:
git add <files>
git commit -m "review-feedback: mallet + compile-warning cleanup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (verified by author)

**Spec coverage check** (every requirement in `docs/superpowers/specs/2026-05-22-review-feedback-routing-design.md`):

| Spec section | Implemented in |
|---|---|
| §1 motivation / §1.1 design choice / §1.2 scope | Architecture, no task |
| §2 data flow | Task 3 |
| §3.1 `%review-implementation` returns 2 values | Task 1 |
| §3.2 `%enriched-issue` `:review-feedback` kwarg | Task 2 |
| §3.3 `%execute-step` new kwarg `:max-impl-review-revisions` | Task 3 |
| §3.4 `execute-plan` / `develop` kwarg pass-through | Task 5 |
| §3.5 CLI flag | Task 6 |
| §4 inner-loop concrete form | Task 3 |
| §5.1 `:impl-review-retry` JSONL event | Task 3 |
| §5.2 `:step-end` payload `review_retries` + `review_final_outcome` | Task 3 |
| §6 develop-state untouched | Task 3 (no slot added; explicitly verified) |
| §7 error handling (model-error / max=0 / review-fn errors) | Task 3 (existing handler-case at outer layer covers; Task 4 verifies max=0 path) |
| §8 Test 1 (approves on second attempt) | Task 3 |
| §8 Test 2 (exhausts budget) | Task 4 |
| §8 Test 3 (enriched-issue contains feedback) | Task 3 (asserted inline) |
| §8 Test 4 (disabled when budget zero) | Task 4 |
| §8 Test 5 (disabled when policy none) | Task 4 |
| §8 Test 6 (test-change priority) | Task 4 |
| §9 README + PRD | Task 7 |
| §10 out-of-scope items | Not implemented (correct) |
| §11 risks | Task 3 (budget; budget=0; max safety net), Task 4 (regression coverage) |
| §12 implementation order | Tasks 1-8 follow it |

**Placeholder scan:** No TBD/TODO outside intentional deferred decisions. The PRD prose contains a placeholder `## Prior implementation review feedback` substring, but that is the literal header string emitted by `%enriched-issue` — not a planning placeholder.

**Type consistency:**
- `%review-implementation` returns `(values approved-p feedback)` — Task 1 defines, Task 3 consumes via `multiple-value-bind`, Task 4 tests verify both paths.
- `%enriched-issue` signature `(step memo &key review-feedback)` — Task 2 defines, Task 3's loop calls with `:review-feedback review-feedback` matching the kwarg name.
- `:max-impl-review-revisions` kwarg name spelled identically across tasks 3, 5, 6.
- `impl-review-passed-p` flag introduced in Task 3 and used in same-task status determination logic; no other task references it.
- `:impl-review-retry` JSONL event payload keys (`step_index`, `retry_count`, `feedback`) defined in Task 3; not referenced by other tasks (deftest verifies via behavior, not payload introspection).
- `review_retries` / `review_final_outcome` `:step-end` keys defined in Task 3; no test currently asserts on them (acceptable — they are observability fields, not behavior).

No issues found. Plan ready.
