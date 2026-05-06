# Phase A: `develop-state` central run-state Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce `develop-state` as the central in-memory state object for one `develop` invocation, replacing the ad-hoc local-variable + keyword-argument threading currently used in `src/orchestrator.lisp`.

**Architecture:** New file `src/state.lisp` defines a CLOS class `develop-state` plus a `make-develop-state` constructor and `develop-state-record-step-result` mutator. `develop` in `src/orchestrator.lisp` is refactored to construct one `develop-state` at the top of the loop and read/write its slots instead of carrying loop-local variables. The public surface — `develop`'s keyword arguments and the `develop-result` return value — is unchanged. This phase is a pure refactor that prepares ground for Phases B–E (source / patch / failure / view / reporting).

**Tech stack:** Common Lisp (SBCL), ASDF `:package-inferred-system`, rove tests, alexandria. Project rules in `CLAUDE.md` apply: 2-space indent, ≤100 columns, lower-case lisp-case, docstrings on public symbols, no `:local-nicknames` (use `:import-from` + `:export`).

**Out of scope (deferred):**
- Source-fact / patch-record / runtime-vocabulary / failure-ledger slots (Phase B)
- Context-view generator (Phase C)
- Tool-result compression / finding-ization (Phase D)
- Staleness invalidation, structured reporting (Phase E)

**Acceptance criteria:**
1. `src/state.lisp` exports `develop-state`, `make-develop-state`, `develop-state-record-step-result`, the readers `develop-state-goal / -project-root / -system / -test-system / -condition / -run-limits / -project-inventory / -mode`, the accessors `develop-state-current-plan / -replan-count / -last-failure-test-name / -status / -limit-hit / -integration-issues`, and `develop-state-step-results` (returns oldest-first list).
2. `tests/state-test.lisp` covers construction defaults, mode validation, slot accessors, and step-result ordering. All assertions green.
3. `src/orchestrator.lisp:develop` builds one `develop-state` at entry; the replan loop and the post-loop integration-check + result construction read/write that state object instead of `let`-bound locals.
4. The full `cl-harness/tests` rove suite passes — same test count, same outcomes, **zero behavioral regression**.
5. `cl-harness.asd` lists `cl-harness/tests/state-test` in the test system's `:depends-on`.
6. `mallet src/state.lisp src/orchestrator.lisp tests/state-test.lisp` reports no new warnings.
7. `(asdf:compile-system :cl-harness :force t)` is clean (no warnings introduced by the refactor).

**Risks & mitigations:**
- **R1: package-inferred-system rewrites `defpackage` to `uiop:define-package`**, and the bundled UIOP rejects `:local-nicknames`. → All new packages use `:import-from` + `:export` only; do not introduce `:local-nicknames`.
- **R2: name collision between `develop-state-status` and `develop-result-status`**. → Keep both; their semantics are identical at end-of-run, but `develop-state-status` evolves during the loop. Cross-reference in docstrings.
- **R3: hidden coupling — orchestrator imports a symbol from state, state must not import from orchestrator**. → `state.lisp` is a pure data container; no imports from `orchestrator`. Status-from-step-result inspection stays inline in orchestrator.
- **R4: `develop` is the public API; the refactor must not change observable behavior**. → No new keyword args, no removed slots on `develop-result`. Existing `tests/orchestrator-test.lisp` is the regression net.

**Working agreement:**
- Use cl-mcp tools (`lisp-edit-form`, `lisp-patch-form`, `lisp-read-file`, `repl-eval`, `run-tests`) per `prompts/repl-driven-development.md`. No raw `cat`/`sed`/`grep` against Lisp source.
- First action of every implementation session: `fs-set-project-root` on the repo root.
- Commit after each green test cycle. Use feature branch `phase-a-develop-state` (the executing-plans skill creates a worktree if needed).

---

## Task 1: Create the empty state package skeleton (red test)

**Files:**
- Create: `tests/state-test.lisp`
- Modify: `cl-harness.asd` — add `cl-harness/tests/state-test` to `cl-harness/tests` `:depends-on`.

**Step 1: Write the failing test**

Create `tests/state-test.lisp` with exactly:

```lisp
;;;; tests/state-test.lisp
;;;;
;;;; Phase A of the context-management refactor
;;;; (docs/context-management.md, docs/plans/2026-05-06-phase-a-develop-state.md).
;;;; Covers DEVELOP-STATE construction defaults, mode validation, slot
;;;; accessors, and step-result ordering. The orchestrator-side
;;;; refactor that consumes DEVELOP-STATE has its own regression
;;;; coverage in tests/orchestrator-test.lisp.

(defpackage #:cl-harness/tests/state-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/state
                #:develop-state
                #:make-develop-state
                #:develop-state-goal
                #:develop-state-project-root
                #:develop-state-system
                #:develop-state-test-system
                #:develop-state-condition
                #:develop-state-run-limits
                #:develop-state-project-inventory
                #:develop-state-mode
                #:develop-state-current-plan
                #:develop-state-step-results
                #:develop-state-replan-count
                #:develop-state-last-failure-test-name
                #:develop-state-status
                #:develop-state-limit-hit
                #:develop-state-integration-issues
                #:develop-state-record-step-result))

(in-package #:cl-harness/tests/state-test)

(defun %make ()
  (make-develop-state :goal "implement greet"
                      :project-root "/tmp/cl-harness-state-test/"
                      :system "demo"
                      :test-system "demo/tests"))

(deftest make-develop-state-accepts-required-args
  (let ((s (%make)))
    (ok (typep s 'develop-state))
    (ok (string= "implement greet" (develop-state-goal s)))
    (ok (string= "demo" (develop-state-system s)))
    (ok (string= "demo/tests" (develop-state-test-system s)))))

(deftest make-develop-state-defaults
  (let ((s (%make)))
    (ok (eq :mixed (develop-state-mode s)))
    (ok (eq :generic-mcp (develop-state-condition s)))
    (ok (null (develop-state-current-plan s)))
    (ok (null (develop-state-step-results s)))
    (ok (zerop (develop-state-replan-count s)))
    (ok (null (develop-state-last-failure-test-name s)))
    (ok (eq :unknown (develop-state-status s)))
    (ok (null (develop-state-limit-hit s)))
    (ok (null (develop-state-integration-issues s)))
    (ok (null (develop-state-run-limits s)))
    (ok (null (develop-state-project-inventory s)))))

(deftest make-develop-state-rejects-bad-mode
  (ok (handler-case
          (progn (make-develop-state :goal "g"
                                     :project-root "/tmp/"
                                     :system "s"
                                     :test-system "s/tests"
                                     :mode :nonsense)
                 nil)
        (error () t))))

(deftest make-develop-state-rejects-non-string-goal
  (ok (handler-case
          (progn (make-develop-state :goal 42
                                     :project-root "/tmp/"
                                     :system "s"
                                     :test-system "s/tests")
                 nil)
        (error () t))))

(deftest develop-state-record-step-result-preserves-order
  ;; STEP-RESULTS must return oldest-first so callers iterating it
  ;; see execution order, matching DEVELOP-RESULT-STEP-RESULTS.
  (let ((s (%make)))
    (develop-state-record-step-result s :first)
    (develop-state-record-step-result s :second)
    (develop-state-record-step-result s :third)
    (let ((results (develop-state-step-results s)))
      (ok (equal '(:first :second :third) results)))))

(deftest develop-state-mutators-are-writable
  (let ((s (%make)))
    (setf (develop-state-current-plan s) '(:plan-step-stub))
    (setf (develop-state-replan-count s) 2)
    (setf (develop-state-last-failure-test-name s) "foo-test")
    (setf (develop-state-status s) :passed)
    (setf (develop-state-limit-hit s) :max-replans)
    (setf (develop-state-integration-issues s) '(:issue))
    (ok (equal '(:plan-step-stub) (develop-state-current-plan s)))
    (ok (= 2 (develop-state-replan-count s)))
    (ok (string= "foo-test" (develop-state-last-failure-test-name s)))
    (ok (eq :passed (develop-state-status s)))
    (ok (eq :max-replans (develop-state-limit-hit s)))
    (ok (equal '(:issue) (develop-state-integration-issues s)))))
```

**Step 2: Register the test system in `cl-harness.asd`**

Use `lisp-patch-form` against `defsystem "cl-harness/tests"`. The patch:

- `form_type`: `defsystem`
- `form_name`: `"cl-harness/tests"`
- `old_text`: `"cl-harness/tests/develop-bench-test")`
- `new_text`: `"cl-harness/tests/develop-bench-test"\n               "cl-harness/tests/state-test")`

(Verify the closing paren stays at the end of the new last entry.)

**Step 3: Run the failing test**

Via cl-mcp `run-tests`:
```json
{"system": "cl-harness/tests"}
```

**Expected:** Compilation failure for package `cl-harness/src/state` not existing — this is the red signal that drives Task 2.

**Step 4: Commit**

```bash
git checkout -b phase-a-develop-state
git add tests/state-test.lisp cl-harness.asd
git commit -m "$(cat <<'EOF'
test: red tests for develop-state central run-state (Phase A.1)

Adds tests/state-test.lisp covering DEVELOP-STATE construction
defaults, mode validation, accessor writability, and step-result
ordering. cl-harness.asd registers the new test system. The package
cl-harness/src/state does not yet exist; tests fail at compile time
on purpose, driving Task 2.

Phase A of the context-management refactor
(docs/plans/2026-05-06-phase-a-develop-state.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `src/state.lisp` (green)

**Files:**
- Create: `src/state.lisp`

**Step 1: Write the implementation**

`src/state.lisp` body, exact:

```lisp
;;;; src/state.lisp
;;;;
;;;; Phase A of the context-management refactor
;;;; (docs/context-management.md). Central in-memory state for one
;;;; DEVELOP invocation. This file deliberately stays minimal: it is
;;;; a data container, nothing more. Smart helpers (failure
;;;; detection, status transitions) live in the orchestrator. Phases
;;;; B–E will extend this class with source/patch/runtime/failure
;;;; slots without changing the public shape introduced here.

(defpackage #:cl-harness/src/state
  (:use #:cl)
  (:export #:develop-state
           #:make-develop-state
           #:develop-state-goal
           #:develop-state-project-root
           #:develop-state-system
           #:develop-state-test-system
           #:develop-state-condition
           #:develop-state-run-limits
           #:develop-state-project-inventory
           #:develop-state-mode
           #:develop-state-current-plan
           #:develop-state-step-results
           #:develop-state-replan-count
           #:develop-state-last-failure-test-name
           #:develop-state-status
           #:develop-state-limit-hit
           #:develop-state-integration-issues
           #:develop-state-record-step-result))

(in-package #:cl-harness/src/state)

(defparameter +supported-modes+ '(:top-down :bottom-up :mixed)
  "Development modes accepted by MAKE-DEVELOP-STATE. Mirrors
CL-HARNESS/SRC/PLANNER:+SUPPORTED-DEVELOPMENT-MODES+ but is
duplicated here so this file has no inbound dependency on PLANNER.
Keep them in sync.")

(defparameter +supported-conditions+
  '(:file-only :generic-mcp :runtime-native :explore)
  "Tool-policy conditions accepted by MAKE-DEVELOP-STATE. Mirrors
CL-HARNESS/SRC/CONFIG:RUN-CONFIG's CONDITION ECASE.")

(defclass develop-state ()
  ((goal :initarg :goal :reader develop-state-goal :type string
         :documentation "User goal string passed to DEVELOP.")
   (project-root :initarg :project-root
                 :reader develop-state-project-root
                 :documentation "Repository root the run targets.")
   (system :initarg :system :reader develop-state-system
           :documentation "Primary ASDF system name (string).")
   (test-system :initarg :test-system
                :reader develop-state-test-system
                :documentation "Test ASDF system name (string).")
   (condition :initarg :condition
              :reader develop-state-condition
              :initform :generic-mcp
              :documentation "Tool-policy condition keyword. One of
+SUPPORTED-CONDITIONS+.")
   (run-limits :initarg :run-limits
               :reader develop-state-run-limits
               :initform nil
               :documentation "RUN-LIMITS instance shared by every
step's RUN-CONFIG, or NIL to let the step default kick in.")
   (project-inventory :initarg :project-inventory
                      :reader develop-state-project-inventory
                      :initform nil
                      :documentation "Optional project-inventory
text block (currently produced by INVENTORY:GATHER-PROJECT-INVENTORY)
threaded into the planner. Phase B promotes this to a structured
runtime-vocabulary slot.")
   (mode :initarg :mode :reader develop-state-mode :initform :mixed
         :documentation "Development mode keyword, one of
+SUPPORTED-MODES+.")
   (current-plan :initform nil :accessor develop-state-current-plan
                 :documentation "PLAN-STEP list currently being
executed. Replaced wholesale on each replan round.")
   (step-results :initform nil :accessor %step-results
                 :documentation "Reverse-chronological list of
DEVELOP-STEP-RESULT instances. Internal; callers use
DEVELOP-STATE-STEP-RESULTS for execution order.")
   (replan-count :initform 0 :accessor develop-state-replan-count
                 :documentation "How many times the planner has been
re-invoked during this run.")
   (last-failure-test-name
    :initform nil :accessor develop-state-last-failure-test-name
    :documentation "Test name of the previous round's failing step.
Used by the orchestrator to detect a stuck loop.")
   (status :initform :unknown :accessor develop-state-status
           :documentation "Current terminal status keyword. Becomes
the final DEVELOP-RESULT status when the loop exits.")
   (limit-hit :initform nil :accessor develop-state-limit-hit
              :documentation "Which budget tripped, if any —
:MAX-REPLANS or :NO-PROGRESS or NIL.")
   (integration-issues :initform nil
                       :accessor develop-state-integration-issues
                       :documentation "INTEGRATION-ISSUE list found
by the post-success static check, or NIL when none ran."))
  (:documentation
   "Central state for one DEVELOP invocation. Aggregates the goal,
project context, current plan, step outcomes across replan rounds,
and terminal status. Does not own external resources (provider,
mcp-client, logger) — those remain function-local to the
orchestration loop. Phases B–E will extend this class with
additional slots (source-facts, patch-records, failure-ledger,
runtime-vocabulary) without touching the existing slot set."))

(defun make-develop-state (&key goal project-root system test-system
                             (condition :generic-mcp)
                             run-limits project-inventory
                             (mode :mixed))
  "Construct a DEVELOP-STATE for one DEVELOP run. GOAL must be a
non-empty string; PROJECT-ROOT, SYSTEM, TEST-SYSTEM must be
non-NIL. MODE defaults to :MIXED and must be one of
+SUPPORTED-MODES+. CONDITION defaults to :GENERIC-MCP and must be
one of +SUPPORTED-CONDITIONS+."
  (check-type goal string)
  (assert (plusp (length goal)) (goal)
          "develop-state: :goal must be a non-empty string")
  (assert project-root (project-root)
          "develop-state: :project-root is required")
  (check-type system string)
  (check-type test-system string)
  (unless (member mode +supported-modes+)
    (error "develop-state: unsupported :mode ~S; expected one of ~S"
           mode +supported-modes+))
  (unless (member condition +supported-conditions+)
    (error "develop-state: unsupported :condition ~S; expected one of ~S"
           condition +supported-conditions+))
  (make-instance 'develop-state
                 :goal goal
                 :project-root project-root
                 :system system
                 :test-system test-system
                 :condition condition
                 :run-limits run-limits
                 :project-inventory project-inventory
                 :mode mode))

(defun develop-state-record-step-result (state step-result)
  "Append STEP-RESULT (typically a DEVELOP-STEP-RESULT) to STATE's
internal step-results list. The slot is kept reverse-chronological
internally; DEVELOP-STATE-STEP-RESULTS reverses on read so callers
see execution order. Returns STATE."
  (push step-result (%step-results state))
  state)

(defun develop-state-step-results (state)
  "Return STATE's recorded step results in execution order
(oldest first). Mirrors DEVELOP-RESULT-STEP-RESULTS so the two
are interchangeable for downstream readers."
  (reverse (%step-results state)))
```

**Step 2: Verify parens / load**

Run cl-mcp `lisp-check-parens` on `src/state.lisp` to confirm balanced. Then `load-system` for `cl-harness`:
```json
{"system": "cl-harness", "force": true}
```
Expected: load succeeds with no warnings.

**Step 3: Run tests**

```json
{"system": "cl-harness/tests"}
```
Expected: all 6 deftests in `cl-harness/tests/state-test` pass; no other tests regress.

**Step 4: Commit**

```bash
git add src/state.lisp
git commit -m "$(cat <<'EOF'
feat: implement develop-state central run-state (Phase A.2)

Adds src/state.lisp with the DEVELOP-STATE CLOS class, its
constructor MAKE-DEVELOP-STATE, the mutator
DEVELOP-STATE-RECORD-STEP-RESULT, and accessors covering goal,
project context, mode, current plan, step results, replan count,
status, limit-hit, and integration issues.

The class is a pure data container with no inbound deps on
orchestrator. Slot validation rejects bad modes / conditions and
non-string goals. STEP-RESULTS is stored reverse-chronological
internally; the public accessor reverses on read so callers see
execution order.

Tests in tests/state-test.lisp now pass.

Phase A of the context-management refactor
(docs/plans/2026-05-06-phase-a-develop-state.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Refactor `develop` to thread `develop-state`

**Files:**
- Modify: `src/orchestrator.lisp` — package-level `:import-from` adds the state symbols; `develop` body is rewritten to use state.

**Step 1: Add `:import-from` for state in orchestrator's defpackage**

Use `lisp-patch-form` on `defpackage` `cl-harness/src/orchestrator`:
- `old_text`: `(:import-from #:cl-harness/src/integration`
- `new_text`: `(:import-from #:cl-harness/src/state\n                #:develop-state\n                #:make-develop-state\n                #:develop-state-goal\n                #:develop-state-project-root\n                #:develop-state-system\n                #:develop-state-test-system\n                #:develop-state-condition\n                #:develop-state-run-limits\n                #:develop-state-project-inventory\n                #:develop-state-mode\n                #:develop-state-current-plan\n                #:develop-state-step-results\n                #:develop-state-replan-count\n                #:develop-state-last-failure-test-name\n                #:develop-state-status\n                #:develop-state-limit-hit\n                #:develop-state-integration-issues\n                #:develop-state-record-step-result)\n  (:import-from #:cl-harness/src/integration`

**Step 2: Rewrite `develop` body via `lisp-edit-form` with operation `replace`**

The new body — preserving every observable behavior, only the internal threading changes:

```lisp
(defun develop (goal
                &key project-root system test-system test-file
                     provider mcp-client
                     (condition :generic-mcp)
                     run-limits
                     project-inventory
                     (mode :mixed)
                     log-path
                     (max-replans 3)
                     (planner-fn #'plan-development)
                     (run-fn #'run-agent)
                     (explore-fn #'run-explore-agent))
  "Plan, execute, and replan-on-failure end-to-end.

Workflow:
  1. Call PLANNER-FN(GOAL, ...) to obtain the initial plan.
  2. EXECUTE-PLAN the result; record outcomes on STATE.
  3. If the last step :PASSED -> success.
  4. Otherwise, if MAX-REPLANS is exhausted -> :LIMIT-EXHAUSTED.
  5. Otherwise, call PLANNER-FN with PRIOR-PLAN and FAILURE-CONTEXT
     populated to ask for a revised plan.
  6. If the revised plan's first step has the same TEST-NAME as the
     failed step -> :STUCK (no progress).
  7. Otherwise, EXECUTE-PLAN the revised plan and loop.

Returns a DEVELOP-RESULT capturing the final status, the final
plan, every step result across every round, the replan count, and
which budget (if any) tripped.

Internally the loop drives a DEVELOP-STATE (Phase A of the
context-management refactor); the DEVELOP-RESULT is built from
that state at the end. Callers do not see the state object —
DEVELOP's keyword arguments and return type are unchanged.

The orchestrator does not own PROVIDER or MCP-CLIENT; callers build
them per cl-harness:fix conventions and pass them through. PLANNER-FN
and RUN-FN are injection points for tests; defaults are
PLAN-DEVELOPMENT and RUN-AGENT respectively.

LOG-PATH, when supplied, is the develop-level JSONL path. EXECUTE-PLAN
appends per-round events; DEVELOP wraps them with replan-trigger
events so a single transcript shows the full multi-round history.
(EXECUTE-PLAN's own develop-start / develop-end events are emitted
once per round; readers should disambiguate by replan-index, which
is added to the payload here.)

MODE (v0.4 Phase 6) selects the development style:
:TOP-DOWN  - implement-first; every plan-step's needs-exploration is
             coerced to :NONE before execution.
:BOTTOM-UP - explore-first; :NONE / NIL needs-exploration is promoted
             to :LIGHTWEIGHT.
:MIXED     - let the planner decide per step (default)."
  (check-type goal string)
  (check-type max-replans (integer 0))
  (unless (member mode +supported-development-modes+)
    (error "develop: unsupported :mode ~S; expected one of ~S"
           mode +supported-development-modes+))
  (let ((state (make-develop-state :goal goal
                                   :project-root project-root
                                   :system system
                                   :test-system test-system
                                   :condition condition
                                   :run-limits run-limits
                                   :project-inventory project-inventory
                                   :mode mode)))
    (setf (develop-state-current-plan state)
          (%apply-mode-to-plan
           (funcall planner-fn goal
                    :project-root project-root
                    :system system
                    :test-system test-system
                    :provider provider
                    :project-inventory project-inventory
                    :mode mode)
           mode))
    (loop
      (let* ((round-results (execute-plan
                             (develop-state-current-plan state)
                             :project-root project-root
                             :system system
                             :test-system test-system
                             :test-file test-file
                             :condition condition
                             :provider provider
                             :mcp-client mcp-client
                             :run-limits run-limits
                             :log-path log-path
                             :run-fn run-fn
                             :explore-fn explore-fn))
             (last-result (car (last round-results))))
        (dolist (r round-results)
          (develop-state-record-step-result state r))
        (cond
          ((null last-result)
           (setf (develop-state-status state) :empty)
           (return))
          ((eq :passed (develop-step-result-status last-result))
           (setf (develop-state-status state) :passed)
           (return))
          ((>= (develop-state-replan-count state) max-replans)
           (setf (develop-state-status state) :limit-exhausted
                 (develop-state-limit-hit state) :max-replans)
           (return))
          (t
           (let ((this-failure (develop-step-result-test-name last-result)))
             (when (and (develop-state-last-failure-test-name state)
                        (equal (develop-state-last-failure-test-name state)
                               this-failure))
               (setf (develop-state-status state) :stuck
                     (develop-state-limit-hit state) :no-progress)
               (return))
             (setf (develop-state-last-failure-test-name state)
                   this-failure))
           (incf (develop-state-replan-count state))
           (let ((new-plan (%apply-mode-to-plan
                            (funcall planner-fn goal
                                     :project-root project-root
                                     :system system
                                     :test-system test-system
                                     :provider provider
                                     :project-inventory project-inventory
                                     :mode mode
                                     :prior-plan (develop-state-current-plan state)
                                     :failure-context
                                     (%failure-context last-result))
                            mode)))
             (when (equal (%first-test-name new-plan)
                          (develop-state-last-failure-test-name state))
               (setf (develop-state-status state) :stuck
                     (develop-state-limit-hit state) :no-progress)
               (return))
             (setf (develop-state-current-plan state) new-plan))))))
    (when (and (eq (develop-state-status state) :passed) project-root)
      (handler-case
          (let ((issues (find-integration-issues
                         (gather-package-graph project-root))))
            (setf (develop-state-integration-issues state) issues)
            (when log-path
              (let ((logger (open-run-logger log-path)))
                (unwind-protect
                     (log-event
                      logger :integration-check
                      (alist-hash-table
                       `(("issue_count" . ,(length issues))
                         ("issues"
                          . ,(map 'vector
                                  (lambda (i)
                                    (alist-hash-table
                                     `(("kind"
                                        . ,(string-downcase
                                            (symbol-name
                                             (integration-issue-kind i))))
                                       ("package"
                                        . ,(integration-issue-package i))
                                       ("file"
                                        . ,(let ((f (integration-issue-file i)))
                                             (if f (namestring f) "")))
                                       ("description"
                                        . ,(integration-issue-description i)))
                                     :test 'equal))
                                  issues)))
                       :test 'equal))
                  (close-run-logger logger)))))
        (error () nil)))
    (make-instance 'develop-result
                   :status (develop-state-status state)
                   :final-plan (develop-state-current-plan state)
                   :step-results (develop-state-step-results state)
                   :replan-count (develop-state-replan-count state)
                   :limit-hit (develop-state-limit-hit state)
                   :integration-issues
                   (develop-state-integration-issues state))))
```

Use `lisp-edit-form` with:
- `form_type`: `defun`
- `form_name`: `develop`
- `operation`: `replace`
- `content`: the entire defun above
- `dry_run`: `true` first to verify the match, then run with `dry_run: false`

**Step 3: Verify nothing else in `orchestrator.lisp` referenced the removed locals**

The original `develop` had `let` locals `plan / results / replans / last-failure-test-name / status / limit-hit / integration-issues`. None of them are referenced outside the body, but double-check: `clgrep-search` for `last-failure-test-name` in `src/orchestrator.lisp` should return zero hits after the refactor (the new code uses `develop-state-last-failure-test-name` instead).

**Step 4: Compile + run full test suite**

```json
{"system": "cl-harness", "force": true}
```
Then:
```json
{"system": "cl-harness/tests"}
```
Expected:
- Compilation clean (no new warnings).
- All previously passing tests still pass (`cl-harness/tests/orchestrator-test` is the key regression net here).
- New `state-test` tests pass.

If any orchestrator-test regresses, **stop and diagnose** before continuing. Likely cause: a slot got renamed or a setf path got dropped. Compare the new `develop` body line-by-line against the original.

**Step 5: Commit**

```bash
git add src/orchestrator.lisp
git commit -m "$(cat <<'EOF'
refactor: thread develop-state through develop loop (Phase A.3)

Replaces the let-bound locals (plan, results, replans,
last-failure-test-name, status, limit-hit, integration-issues) in
DEVELOP with reads/writes against a single DEVELOP-STATE
constructed at the top of the function. EXECUTE-PLAN's contract is
unchanged; DEVELOP-RESULT is still built from state at the end and
its slot set is identical.

No behavioral change. Existing orchestrator-test, planner-test, and
develop-bench-test suites pass unchanged. This is the ground-laying
refactor for Phases B-E (source / patch / failure / view /
reporting), which extend DEVELOP-STATE with additional slots.

Phase A of the context-management refactor
(docs/plans/2026-05-06-phase-a-develop-state.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Lint, force-compile, and final regression sweep

**Files:** none modified (this task is verification + cleanup).

**Step 1: Run mallet on the new and changed files**

```bash
mallet src/state.lisp src/orchestrator.lisp tests/state-test.lisp
```
Expected: zero warnings.

If mallet flags anything, fix in place via `lisp-patch-form` (NOT shell `sed`), re-run, and amend the relevant commit (or add a follow-up commit `style: address mallet feedback`).

**Step 2: Force-compile the whole system**

Via cl-mcp `repl-eval`:
```lisp
(asdf:compile-system :cl-harness :force t)
```
Expected: no warnings, no errors.

**Step 3: Run the full test suite via the project's test-op path**

From a clean shell (stale-image fallback per `CLAUDE.md`):
```bash
rove cl-harness.asd
```
Expected: all tests pass; same count as before Phase A plus the new 6 state-test deftests.

**Step 4: Verify no behavioral surprises in develop-bench**

`develop-bench-test` exercises `develop` end-to-end with stub planner/run-fn. If those tests pass, the refactor preserved external behavior. If they fail, **do not paper over** — root-cause the slot/contract drift.

**Step 5: Commit (only if mallet required fixes)**

If steps 1–4 produced no changes, this task ends with no new commit. Otherwise:
```bash
git add -p   # stage just the lint fixes
git commit -m "style: address mallet feedback on Phase A files"
```

---

## Task 5: Update Phase A landing notes (optional)

**Files:**
- Modify: `docs/context-management.md` may get a forward-pointer to this plan, or a "Phase A landed" annotation. Keep it minimal — the plan document itself is the canonical record.

**Step 1: Decide whether to annotate**

If the user wants a paper trail for future readers of `docs/context-management.md`, append a short "Implementation status" section pointing at this plan. Otherwise skip.

**Step 2 (if annotating): patch with `lisp-patch-form` is wrong here — this is markdown.**

Use `Edit` (the standard editor) with a small append.

**Step 3: Commit**

```bash
git add docs/context-management.md
git commit -m "docs: link Phase A plan from context-management requirements"
```

---

## Verification checklist (run before opening a PR)

- [ ] `src/state.lisp` exists and exports the documented symbols
- [ ] `tests/state-test.lisp` exists, all deftests green
- [ ] `cl-harness.asd` lists `cl-harness/tests/state-test`
- [ ] `develop` in `src/orchestrator.lisp` constructs and threads `develop-state`
- [ ] `develop`'s public signature unchanged (same keyword args, same `develop-result` return type)
- [ ] `(asdf:compile-system :cl-harness :force t)` clean
- [ ] `rove cl-harness.asd` green
- [ ] `mallet src/state.lisp src/orchestrator.lisp tests/state-test.lisp` clean
- [ ] No imports from `orchestrator` to `state` package — only state -> orchestrator-via-symbol-resolution would create a cycle, and we don't do that

## Rollback plan

If the refactor surfaces a behavioral regression that cannot be quickly diagnosed:
1. `git checkout main -- src/orchestrator.lisp` — restore the old `develop`.
2. Keep `src/state.lisp` and `tests/state-test.lisp` (they are pure additions).
3. Open an issue describing the regression, then iterate on the orchestrator change in isolation.

The state package is independently useful for Phase B even if the orchestrator refactor is delayed; Phase A's split into Tasks 1–2 vs. Task 3 is intentional so the rollback boundary is clean.
