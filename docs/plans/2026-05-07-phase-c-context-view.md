# Phase C: `context-view` Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce a structured `context-view` module that, given the `develop-state` from Phase A+B, generates phase-specific compressed sections that the existing prompt-builders can splice into LLM prompts in place of the current ad-hoc string assembly.

**Architecture:** New file `src/context-view.lisp` defines a CLOS class `context-view` (a snapshot of state with phase-relevant slots filled), `make-context-view` (constructor that selects which slots to populate based on `:phase`), and a generic function `context-view->string` with `(eql ...)` specializers for each supported phase (`:planning`, `:exploration`, `:implementation`). The 3 existing prompt-builder call sites (`src/planner.lisp`, `src/explore.lisp`, `src/agent.lisp`) get **surgically rewritten** so that ONLY the ad-hoc context block is replaced with `(context-view->string view phase)` — surrounding scaffolds (system prompt, tool listing, JSON schema instructions) stay byte-identical, minimising behavioural regression risk.

**Tech stack:** Common Lisp (SBCL), ASDF `:package-inferred-system`, rove tests, alexandria. Phase A and Phase B's patterns apply: data files have zero inbound deps on orchestrator/agent; validation in constructors; test stubs use `&allow-other-keys` to absorb future kwargs.

**Out of scope (deferred):**
- **Testing phase view** — `cl-harness` doesn't separate testing from implementation; the same `run-agent` loop runs both. The implementation formatter handles both.
- **Integration phase view** — the post-success integration check has its own data path via `src/integration.lisp`; defer to Phase E (when context views start feeding the final report).
- **Runtime-vocabulary slot/section** — the structured packages/exports/classes/etc. ledger from `docs/context-management.md` §3.4 is its own deferred Phase B follow-up plan; until it lands, the context-view's `runtime-vocabulary` section is empty / falls back to `project-inventory` text.
- **Tool-result compression** — `src/compact.lisp` is dormant infrastructure; Phase D is its territory. Phase C reads what's already recorded in develop-state, doesn't re-compress on the fly.
- **Staleness invalidation** — Phase E. Phase C produces views from whatever's currently recorded; if a source-fact is stale, the view shows it as recorded.
- **Structured reporting from develop-state** — Phase E.

**Acceptance criteria:**
1. `src/state.lisp` gains a `current-step-index` slot (integer or NIL) with a public reader and a `setf` accessor. `develop-state` slot count goes from 18 → 19.
2. `src/orchestrator.lisp:%execute-step` sets `(setf (develop-state-current-step-index develop-state) (plan-step-index step))` at entry and clears it (back to NIL) at exit; pre-existing tests must still pass with the new bookkeeping.
3. `src/context-view.lisp` exports `context-view`, `make-context-view`, accessor names, and the generic function `context-view->string`.
4. `tests/context-view-test.lisp` covers (a) the data-layer constructor (correct slot population per phase), and (b) each of the 3 formatters (substring presence on a sample state).
5. `src/planner.lisp:plan-development` (specifically its `%build-user-prompt` helper or equivalent) uses `context-view->string :planning` for the goal/plan/inventory/replan-context section. The system prompt and JSON schema instructions are unchanged.
6. `src/explore.lisp:run-explore-agent` (its `%initial-explore-user-prompt` or equivalent) uses `context-view->string :exploration` for the issue/investigation-targets/source-summary section.
7. `src/agent.lisp:run-agent`'s initial-user-prompt assembly uses `context-view->string :implementation` for the issue/verify-summary/relevant-sources section.
8. The full `cl-harness/tests` rove suite passes via cl-mcp `run-tests` — Phase B baseline 229/0 + new context-view-test deftests + zero regressions in planner-test/explore tests/agent-test/orchestrator-test/develop-bench-test.
9. `mallet` clean on Phase C-touched files.
10. `(asdf:compile-system :cl-harness :force t)` clean.
11. `docs/context-management.md` §14 updated to mark Phase C landed; cross-references which §3 / §4 / §5 sections are now fulfilled.

**Risks & mitigations:**

- **R1: Behavioural regression in the agent loop.** Replacing the prompt-context section changes what the LLM sees, which can shift action selection. → Wiring tasks 6-8 are **strictly behaviour-preserving**: the new context-view->string output must contain (at minimum) the same identifiable substrings as the current ad-hoc text — the test suite's stub-LLM happy-path tests must continue to pass without modification, AND Phase C's new wiring tests assert specific substrings appear in the constructed prompt. If a wiring task can't preserve the behavior, STOP and adjust the formatter rather than tweak the test.

- **R2: `current-step-index` is set but not cleared.** If `%execute-step` errors after setting current-step-index, the state could leak a stale index into later code. → Use `unwind-protect` to clear on exit. The clear is also idempotent (NIL on no-op).

- **R3: `make-context-view` walks the entire `source-facts`/`patch-records`/`failure-ledger` lists per call.** For long runs these could be hundreds of items. → Phase C MVP filters by `related-step-index = current-step-index` only. Phase E may add more sophisticated relevance scoring; for now O(n) walks are fine since the lists are bounded by per-run budgets.

- **R4: context-view package depends on state, source-fact, patch-record, failure-ledger.** That's 4 inbound deps for one new module. → Acceptable; context-view is the consumer module by design. The reverse direction must NOT happen — none of state.lisp, source-fact.lisp, patch-record.lisp, failure-ledger.lisp may import from context-view.

- **R5: existing prompt scaffolds may have hidden state dependencies (e.g. tool-schema-hints in agent.lisp depends on policy).** → Wiring tasks ONLY replace the context section, not the scaffold. The scaffold's existing state inputs (policy, run-config) remain function-arg passthroughs.

- **R6: `:exploration` and `:implementation` formatters need access to plan-step data; the current callers receive `plan-step` as an argument but it's not in develop-state per se.** → `make-context-view` accepts `:step` as an explicit kwarg (the active plan-step). The formatter uses both the step (issue, investigation-targets) and develop-state slots (relevant ledger entries).

- **R7: planning context-view for replan needs `prior-plan` and `failure-context`.** → `make-context-view` accepts `:prior-plan` and `:failure-context` kwargs explicitly. They're orthogonal to develop-state (per Phase A's design, current-plan IS the prior-plan after replan; we don't add a separate slot).

**Working agreement:**
- cl-mcp tools (`lisp-edit-form`, `lisp-patch-form`, `lisp-read-file`, `repl-eval`, `run-tests`) for all Lisp source modifications. No shell `grep`/`sed`/`cat` against Lisp source.
- First action of every implementation session: cl-mcp `fs-set-project-root` on the repo root.
- Commit after each green TDD cycle. Use feature branch `phase-c-context-view`.
- Phase A/B lessons that apply: keep new state files dependency-free of orchestrator; constructor validation; tests use `&allow-other-keys` for kwarg absorption; test helpers put overrides FIRST in `apply` (per CLHS 3.4.1.4 leftmost-key wins).

---

## Task 1: Add `current-step-index` slot to `develop-state`

**Files:**
- Modify: `src/state.lisp` — add slot + accessor; bump exports.
- Modify: `tests/state-test.lisp` — add 2 deftests.
- Modify: `src/orchestrator.lisp` — set/clear in `%execute-step` via `unwind-protect`.

### Step 1.1: Failing test

Append to `tests/state-test.lisp`'s `:import-from #:cl-harness/src/state` clause:
```
                #:develop-state-current-step-index
```

Append at end of file:

```lisp
(deftest develop-state-current-step-index-defaults-to-nil
  (let ((s (%make)))
    (ok (null (develop-state-current-step-index s)))))

(deftest develop-state-current-step-index-is-writable
  (let ((s (%make)))
    (setf (develop-state-current-step-index s) 3)
    (ok (= 3 (develop-state-current-step-index s)))
    (setf (develop-state-current-step-index s) nil)
    (ok (null (develop-state-current-step-index s)))))
```

### Step 1.2: Red

cl-mcp `run-tests` `{"system": "cl-harness/tests/state-test"}` — fails on missing accessor `develop-state-current-step-index`.

### Step 1.3: Implement slot

Use cl-mcp `lisp-patch-form` on `src/state.lisp`'s defpackage to add `#:develop-state-current-step-index` to the `:export` list (place it adjacent to other `develop-state-*` accessor exports).

Use cl-mcp `lisp-patch-form` on `develop-state` defclass to add a new slot AFTER the existing `current-plan` slot (since current-step-index logically modifies how current-plan is read):

```
   (current-step-index :initform nil
                       :accessor develop-state-current-step-index
                       :documentation "PLAN-STEP-INDEX of the step
the orchestrator is currently executing, or NIL when not inside a
step (e.g. before the loop starts, between steps, or after the
final step). Set by %execute-step at entry, cleared at exit. Used
by MAKE-CONTEXT-VIEW to filter ledger entries to those belonging
to the active step.")
```

### Step 1.4: Wire `%execute-step` to set/clear the index

cl-mcp `lisp-read-file src/orchestrator.lisp` `name_pattern="^%execute-step$"` to find the function. Identify its body's outer scope.

Use cl-mcp `lisp-edit-form replace` to wrap the existing body in an `unwind-protect` that sets the index at entry and clears it at exit. Pseudocode for the wrapping (the actual body stays unchanged):

```lisp
(defun %execute-step (step run-fn ... develop-state)
  ;; ... existing arg processing ...
  (when develop-state
    (setf (develop-state-current-step-index develop-state)
          (plan-step-index step)))
  (unwind-protect
       (progn
         ;; ... ENTIRE existing body ...
         )
    (when develop-state
      (setf (develop-state-current-step-index develop-state) nil))))
```

The `(when develop-state ...)` guards mean the bookkeeping is inert when `%execute-step` is called outside a develop-state run (test stubs, etc.).

If `%execute-step` is large and `lisp-edit-form replace` is too risky, use `lisp-patch-form` to insert just the entry and exit hooks at the right scope boundaries.

### Step 1.5: Verify green

cl-mcp `load-system` `{"system": "cl-harness", "force": true}` — clean.
cl-mcp `run-tests` `{"system": "cl-harness/tests/state-test"}` — 15/0 (was 13, +2).
cl-mcp `run-tests` `{"system": "cl-harness/tests/orchestrator-test"}` — 17/0 (no regressions).
cl-mcp `run-tests` `{"system": "cl-harness/tests"}` — 231/0 (was 229, +2).

### Step 1.6: Commit

```bash
git checkout -b phase-c-context-view
git add src/state.lisp src/orchestrator.lisp tests/state-test.lisp
git commit -m "$(cat <<'EOF'
feat: develop-state.current-step-index slot (Phase C.1 precondition)

Adds a CURRENT-STEP-INDEX slot to DEVELOP-STATE (integer or NIL,
defaults NIL, public setf accessor). The orchestrator's
%execute-step now sets the slot to the active plan-step's index
on entry and clears it via unwind-protect on exit, so MAKE-CONTEXT-VIEW
(Task 2 onward) can filter source-facts / patch-records / failure
records to those bound to the active step.

The wiring is gated on a non-NIL develop-state, so test stubs that
inject hash-tables or call %execute-step without a develop-state
are unaffected.

Phase C of the context-management refactor
(docs/plans/2026-05-07-phase-c-context-view.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create `src/context-view.lisp` data layer

**Files:**
- Create: `tests/context-view-test.lisp`
- Create: `src/context-view.lisp`
- Modify: `cl-harness.asd`

### Step 2.1: Failing test

Create `tests/context-view-test.lisp`:

```lisp
;;;; tests/context-view-test.lisp
;;;;
;;;; Phase C of the context-management refactor
;;;; (docs/context-management.md §4-§5,
;;;; docs/plans/2026-05-07-phase-c-context-view.md).
;;;; Covers MAKE-CONTEXT-VIEW data-layer construction. Per-phase
;;;; CONTEXT-VIEW->STRING formatters are tested in their own
;;;; deftests (Tasks 3-5).

(defpackage #:cl-harness/tests/context-view-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/state
                #:make-develop-state
                #:develop-state-source-facts
                #:develop-state-patch-records
                #:develop-state-failure-ledger
                #:develop-state-current-step-index
                #:develop-state-record-source-fact
                #:develop-state-record-patch-record
                #:develop-state-record-failure)
  (:import-from #:cl-harness/src/source-fact
                #:make-source-fact)
  (:import-from #:cl-harness/src/patch-record
                #:make-patch-record)
  (:import-from #:cl-harness/src/failure-ledger
                #:make-failure-record)
  (:import-from #:cl-harness/src/context-view
                #:context-view
                #:make-context-view
                #:context-view-phase
                #:context-view-goal
                #:context-view-current-step
                #:context-view-relevant-source-facts
                #:context-view-relevant-patch-records
                #:context-view-active-failures
                #:context-view-prior-plan
                #:context-view-failure-context
                #:context-view-project-inventory))

(in-package #:cl-harness/tests/context-view-test)

(defun %state ()
  (let ((s (make-develop-state :goal "implement greet"
                               :project-root "/tmp/cv-test/"
                               :system "demo"
                               :test-system "demo/tests"
                               :project-inventory "demo .asd inventory")))
    (setf (develop-state-current-step-index s) 0)
    s))

(deftest make-context-view-rejects-bad-phase
  (ok (handler-case
          (progn (make-context-view (%state) :phase :nonsense) nil)
        (error () t))))

(deftest make-context-view-planning-fills-goal-and-inventory
  (let ((v (make-context-view (%state) :phase :planning)))
    (ok (typep v 'context-view))
    (ok (eq :planning (context-view-phase v)))
    (ok (string= "implement greet" (context-view-goal v)))
    (ok (string= "demo .asd inventory"
                 (context-view-project-inventory v)))
    (ok (null (context-view-current-step v)))))

(deftest make-context-view-planning-passes-replan-context
  (let* ((s (%state))
         (v (make-context-view s :phase :planning
                                 :prior-plan '(:dummy-plan)
                                 :failure-context "step 0 failed")))
    (ok (equal '(:dummy-plan) (context-view-prior-plan v)))
    (ok (string= "step 0 failed" (context-view-failure-context v)))))

(deftest make-context-view-implementation-filters-by-step
  ;; Only ledger entries with related-step-index = current-step-index
  ;; should appear in the relevant-* slots.
  (let* ((s (%state)))
    (develop-state-record-source-fact
     s (make-source-fact :path "/tmp/a.lisp" :via-tool "lisp-read-file"
                         :related-step-index 0))
    (develop-state-record-source-fact
     s (make-source-fact :path "/tmp/b.lisp" :via-tool "lisp-read-file"
                         :related-step-index 1))
    (develop-state-record-patch-record
     s (make-patch-record :path "/tmp/a.lisp" :via-tool "lisp-edit-form"
                          :turn 1 :related-step-index 0))
    (develop-state-record-patch-record
     s (make-patch-record :path "/tmp/b.lisp" :via-tool "lisp-edit-form"
                          :turn 2 :related-step-index 1))
    (let ((v (make-context-view s :phase :implementation)))
      (ok (= 1 (length (context-view-relevant-source-facts v))))
      (ok (= 1 (length (context-view-relevant-patch-records v)))))))

(deftest make-context-view-implementation-includes-active-failures
  (let* ((s (%state)))
    (develop-state-record-failure
     s (make-failure-record :kind :test-failed
                            :description "greet-test fails"
                            :verify-source :incremental
                            :related-step-index 0))
    (let ((v (make-context-view s :phase :implementation)))
      (ok (= 1 (length (context-view-active-failures v)))))))

(deftest make-context-view-exploration-uses-step-arg
  (let* ((s (%state))
         (step :sentinel-step)
         (v (make-context-view s :phase :exploration :step step)))
    (ok (eq :sentinel-step (context-view-current-step v)))))

(deftest make-context-view-implementation-uses-step-arg
  (let* ((s (%state))
         (step :sentinel-step)
         (v (make-context-view s :phase :implementation :step step)))
    (ok (eq :sentinel-step (context-view-current-step v)))))

(deftest make-context-view-planning-ignores-step-arg
  (let* ((s (%state))
         (v (make-context-view s :phase :planning :step :sentinel-step)))
    (ok (null (context-view-current-step v)))))
```

### Step 2.2: Register the test system

cl-mcp `lisp-patch-form` on `cl-harness.asd`'s `cl-harness/tests`:
- `old_text`: `"cl-harness/tests/failure-ledger-test")`
- `new_text`: `"cl-harness/tests/failure-ledger-test"\n               "cl-harness/tests/context-view-test")`

### Step 2.3: Red

cl-mcp `run-tests` `{"system": "cl-harness/tests"}` fails on missing package `cl-harness/src/context-view`.

### Step 2.4: Implement `src/context-view.lisp`

```lisp
;;;; src/context-view.lisp
;;;;
;;;; Phase C of the context-management refactor
;;;; (docs/context-management.md §4-§5). Generates phase-specific
;;;; CONTEXT-VIEW snapshots from a DEVELOP-STATE: the structured
;;;; form callers can either inspect directly or render via
;;;; CONTEXT-VIEW->STRING for splicing into LLM prompts.
;;;;
;;;; Phase C MVP: data layer + 3 phase formatters (:PLANNING,
;;;; :EXPLORATION, :IMPLEMENTATION). Testing-phase view is folded
;;;; into :IMPLEMENTATION (cl-harness's run-agent loop runs both).
;;;; Integration-phase view is deferred to Phase E.

(defpackage #:cl-harness/src/context-view
  (:use #:cl)
  (:import-from #:cl-harness/src/state
                #:develop-state
                #:develop-state-goal
                #:develop-state-project-inventory
                #:develop-state-current-plan
                #:develop-state-current-step-index
                #:develop-state-source-facts
                #:develop-state-patch-records
                #:develop-state-failure-ledger)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact-related-step-index)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-related-step-index)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger-active)
  (:export #:context-view
           #:make-context-view
           #:context-view-phase
           #:context-view-goal
           #:context-view-current-step
           #:context-view-current-plan
           #:context-view-relevant-source-facts
           #:context-view-relevant-patch-records
           #:context-view-active-failures
           #:context-view-prior-plan
           #:context-view-failure-context
           #:context-view-project-inventory
           #:context-view->string
           #:+supported-phases+))

(in-package #:cl-harness/src/context-view)

(defparameter +supported-phases+
  '(:planning :exploration :implementation)
  "Phases for which MAKE-CONTEXT-VIEW and CONTEXT-VIEW->STRING are
defined. Mirrors a subset of docs/context-management.md §4.2:
testing folds into implementation (cl-harness's run-agent runs
both); integration is deferred to Phase E.")

(defclass context-view ()
  ((phase :initarg :phase :reader context-view-phase
          :documentation "One of +SUPPORTED-PHASES+.")
   (goal :initarg :goal :initform nil :reader context-view-goal
         :documentation "Current GOAL string (always populated).")
   (project-inventory :initarg :project-inventory :initform nil
                      :reader context-view-project-inventory
                      :documentation "Snapshot of develop-state's
project-inventory (text block today; Phase B's runtime-vocabulary
will replace this slot's data source). Populated for :PLANNING.")
   (current-plan :initarg :current-plan :initform nil
                 :reader context-view-current-plan
                 :documentation "List of PLAN-STEP. Populated for
:PLANNING (in replan mode) and :IMPLEMENTATION (for context).")
   (current-step :initarg :current-step :initform nil
                 :reader context-view-current-step
                 :documentation "Active PLAN-STEP, or NIL when
between steps (e.g. :PLANNING). Populated for :EXPLORATION and
:IMPLEMENTATION.")
   (relevant-source-facts :initarg :relevant-source-facts
                          :initform nil
                          :reader context-view-relevant-source-facts
                          :documentation "SOURCE-FACTs filtered to
those bound to the current step. Populated for :EXPLORATION and
:IMPLEMENTATION.")
   (relevant-patch-records :initarg :relevant-patch-records
                           :initform nil
                           :reader context-view-relevant-patch-records
                           :documentation "PATCH-RECORDs filtered
to the current step. Populated for :IMPLEMENTATION.")
   (active-failures :initarg :active-failures :initform nil
                    :reader context-view-active-failures
                    :documentation "Currently-active FAILURE-RECORDs
from the failure-ledger. Populated for :IMPLEMENTATION (so the
agent loop sees what's still broken).")
   (prior-plan :initarg :prior-plan :initform nil
               :reader context-view-prior-plan
               :documentation "PLAN-STEP list from the failed prior
round, or NIL on initial planning. Populated for :PLANNING in replan
mode (caller passes :prior-plan).")
   (failure-context :initarg :failure-context :initform nil
                    :reader context-view-failure-context
                    :documentation "Human-readable failure summary
from the failed prior round, or NIL on initial planning. Populated
for :PLANNING in replan mode (caller passes :failure-context)."))
  (:documentation
   "A snapshot of DEVELOP-STATE filtered for one phase. Pure data;
no behaviour beyond construction and the CONTEXT-VIEW->STRING
formatter dispatch."))

(defun %related-to-step-p (item step-index getter)
  "Return T when ITEM's GETTER (a related-step-index reader) equals
STEP-INDEX. Used to filter ledger lists. Returns NIL when STEP-INDEX
is NIL (no current step → no items match)."
  (and step-index
       (eql step-index (funcall getter item))))

(defun %filter-source-facts (state step-index)
  (and step-index
       (remove-if-not
        (lambda (f) (%related-to-step-p f step-index
                                        #'source-fact-related-step-index))
        (develop-state-source-facts state))))

(defun %filter-patch-records (state step-index)
  (and step-index
       (remove-if-not
        (lambda (p) (%related-to-step-p p step-index
                                        #'patch-record-related-step-index))
        (develop-state-patch-records state))))

(defun %active-failures (state)
  (let ((ledger (develop-state-failure-ledger state)))
    (and ledger (failure-ledger-active ledger))))

(defun make-context-view (state &key phase step prior-plan failure-context)
  "Build a CONTEXT-VIEW snapshot from STATE for PHASE. STEP is the
active PLAN-STEP (required for :EXPLORATION and :IMPLEMENTATION;
ignored for :PLANNING). PRIOR-PLAN and FAILURE-CONTEXT are
:PLANNING-only kwargs for the replan path.

The returned view is independent of STATE — subsequent state
mutations do not propagate."
  (unless (member phase +supported-phases+)
    (error "make-context-view: unsupported :phase ~S; expected one of ~S"
           phase +supported-phases+))
  (let ((step-index (and state (develop-state-current-step-index state))))
    (case phase
      (:planning
       (make-instance 'context-view
                      :phase :planning
                      :goal (and state (develop-state-goal state))
                      :project-inventory (and state
                                              (develop-state-project-inventory
                                               state))
                      :current-plan (and state
                                         (develop-state-current-plan state))
                      :prior-plan prior-plan
                      :failure-context failure-context))
      (:exploration
       (make-instance 'context-view
                      :phase :exploration
                      :goal (and state (develop-state-goal state))
                      :current-step step
                      :relevant-source-facts (%filter-source-facts
                                              state step-index)))
      (:implementation
       (make-instance 'context-view
                      :phase :implementation
                      :goal (and state (develop-state-goal state))
                      :current-plan (and state
                                         (develop-state-current-plan state))
                      :current-step step
                      :relevant-source-facts (%filter-source-facts
                                              state step-index)
                      :relevant-patch-records (%filter-patch-records
                                               state step-index)
                      :active-failures (%active-failures state))))))

(defgeneric context-view->string (view phase)
  (:documentation
   "Render VIEW as a phase-appropriate markdown-ish string suitable
for splicing into an LLM prompt's context section. The string is
self-contained: a caller can either use it as the entire context
block or splice it into a larger scaffold. PHASE must match
VIEW's phase slot — it's a parameter for dispatch convenience.
Phase C MVP supports :PLANNING, :EXPLORATION, :IMPLEMENTATION."))

;; Default fallback — unsupported phase raises; methods land in Tasks 3-5.
(defmethod context-view->string ((view context-view) phase)
  (declare (ignore view))
  (error "context-view->string: no method for phase ~S" phase))
```

### Step 2.5: Verify green

cl-mcp `load-system` clean. `run-tests cl-harness/tests/context-view-test` 8/8 pass. Full suite 239/0 (231 + 8 new).

### Step 2.6: Commit

```bash
git add src/context-view.lisp tests/context-view-test.lisp cl-harness.asd
git commit -m "$(cat <<'EOF'
feat: context-view data layer (Phase C.2)

Adds src/context-view.lisp with the CONTEXT-VIEW CLOS class,
MAKE-CONTEXT-VIEW constructor, slot accessors, and the empty
CONTEXT-VIEW->STRING generic-function dispatcher (concrete
methods land in Tasks 3-5).

CONTEXT-VIEW captures a snapshot of DEVELOP-STATE filtered to
phase-relevant slots: GOAL and PROJECT-INVENTORY for :PLANNING,
plus CURRENT-STEP, RELEVANT-SOURCE-FACTS / -PATCH-RECORDS,
ACTIVE-FAILURES for :EXPLORATION / :IMPLEMENTATION. The
constructor walks DEVELOP-STATE's source-facts / patch-records
lists and filters by the active CURRENT-STEP-INDEX (set by
%execute-step in Task 1). PRIOR-PLAN and FAILURE-CONTEXT are
:PLANNING-only kwargs for the replan path.

Pure data container with one direction of dependency (state +
ledgers IN; nothing back to context-view). Phases D and E will
extend the slot set; Phase C MVP omits :TESTING (folded into
:IMPLEMENTATION) and :INTEGRATION (deferred to Phase E).

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `:planning` formatter

**Files:**
- Modify: `tests/context-view-test.lisp` — append formatter tests.
- Modify: `src/context-view.lisp` — add `(eql :planning)` method.

### Step 3.1: Failing test

Append to `tests/context-view-test.lisp`:

```lisp
(defun %render-planning (s &key prior-plan failure-context)
  (let ((v (make-context-view s :phase :planning
                                :prior-plan prior-plan
                                :failure-context failure-context)))
    (context-view->string v :planning)))

(deftest planning-formatter-includes-goal
  (let ((out (%render-planning (%state))))
    (ok (search "implement greet" out))))

(deftest planning-formatter-includes-project-inventory
  (let ((out (%render-planning (%state))))
    (ok (search "demo .asd inventory" out))))

(deftest planning-formatter-omits-replan-block-on-initial
  (let ((out (%render-planning (%state))))
    (ok (not (search "Prior plan" out)))
    (ok (not (search "Prior failure" out)))))

(deftest planning-formatter-includes-replan-block-on-replan
  (let ((out (%render-planning (%state)
                               :prior-plan '(:dummy)
                               :failure-context "step 0 failed")))
    (ok (search "Prior plan" out))
    (ok (search "step 0 failed" out))))
```

### Step 3.2: Red

`run-tests cl-harness/tests/context-view-test` — fails because the default `context-view->string` method raises.

### Step 3.3: Implement `:planning` method

Append to `src/context-view.lisp` (after the default method, BEFORE the closing of the file):

```lisp
(defmethod context-view->string ((view context-view) (phase (eql :planning)))
  "Planning-phase view: goal, project inventory, prior-plan + failure
context (replan only). The output is a multi-section markdown block
that the planner's user-prompt builder can splice in place of its
current ad-hoc inventory + goal + replan block."
  (with-output-to-string (s)
    (when (context-view-project-inventory view)
      (format s "## Project inventory~%~A~%~%"
              (context-view-project-inventory view)))
    (format s "## Goal~%~A~%"
            (or (context-view-goal view) ""))
    (when (context-view-prior-plan view)
      (format s "~%## Prior plan (failed last round)~%~S~%"
              (context-view-prior-plan view)))
    (when (context-view-failure-context view)
      (format s "~%## Prior failure context~%~A~%"
              (context-view-failure-context view)))))
```

### Step 3.4: Verify green

`run-tests cl-harness/tests/context-view-test` — 12/12 pass (8 prior + 4 new).
Full suite: 243/0.

### Step 3.5: Commit

```bash
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "$(cat <<'EOF'
feat: context-view :planning formatter (Phase C.3)

Adds the (eql :planning) method on CONTEXT-VIEW->STRING. The
formatter renders project-inventory, goal, and (on replan)
prior-plan + failure-context as ## markdown sections. The
unconditional sections are goal alone; project-inventory is
emitted only when non-NIL; the prior-plan / failure-context block
is emitted only when both kwargs were supplied to MAKE-CONTEXT-VIEW.

Tests verify substring presence on initial vs replan paths.

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `:exploration` formatter

**Files:**
- Modify: `tests/context-view-test.lisp` — append 4 deftests.
- Modify: `src/context-view.lisp` — add `(eql :exploration)` method.

### Step 4.1: Failing test

The exploration view needs to render: current step's issue, current step's investigation-targets (if any), and a summary of relevant source-facts (which files have been read). To test, we need a real `plan-step`. Add to test file's defpackage `:import-from`:

```
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:make-investigation-target)
```

Wait, `make-investigation-target` may not exist — verify via clgrep. If absent, construct via `make-instance 'investigation-target ...`.

Append to `tests/context-view-test.lisp`:

```lisp
(defun %step (&key (index 0)
                (issue "Add greet function.")
                (test-name "greet-returns-hello")
                (test-source "(rove:deftest greet-returns-hello (rove:ok t))")
                (investigation-targets nil))
  (make-instance 'cl-harness/src/planner:plan-step
                 :index index
                 :issue issue
                 :test-name test-name
                 :test-source test-source
                 :investigation-targets investigation-targets))

(deftest exploration-formatter-includes-step-issue
  (let* ((s (%state))
         (v (make-context-view s :phase :exploration
                                 :step (%step :issue "Add greet."))))
    (ok (search "Add greet."
                (context-view->string v :exploration)))))

(deftest exploration-formatter-includes-investigation-targets
  (let* ((s (%state))
         (target (make-instance 'cl-harness/src/planner:investigation-target
                                :kind :function :name "existing-greeter"
                                :intent "check signature"))
         (v (make-context-view s :phase :exploration
                                 :step (%step :investigation-targets
                                              (list target)))))
    (let ((out (context-view->string v :exploration)))
      (ok (search "existing-greeter" out))
      (ok (search "check signature" out)))))

(deftest exploration-formatter-handles-no-step-gracefully
  ;; Defensive: caller passed :phase :exploration but no :step. The
  ;; formatter should not crash; it emits a "no current step" notice.
  (let* ((s (%state))
         (v (make-context-view s :phase :exploration)))
    (ok (stringp (context-view->string v :exploration)))))

(deftest exploration-formatter-summarises-relevant-source-facts
  (let* ((s (%state)))
    (cl-harness/src/state:develop-state-record-source-fact
     s (cl-harness/src/source-fact:make-source-fact
        :path "/tmp/cv-test/src/greet.lisp"
        :via-tool "lisp-read-file"
        :related-step-index 0))
    (let* ((v (make-context-view s :phase :exploration
                                   :step (%step :index 0)))
           (out (context-view->string v :exploration)))
      (ok (search "greet.lisp" out)))))
```

The test imports `cl-harness/src/planner` and `cl-harness/src/source-fact` directly via fully-qualified names; the existing context-view-test defpackage already imports planner via... wait, it doesn't. Add:

```
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:investigation-target)
```

(`investigation-target` is the class symbol; `plan-step-investigation-targets` is the reader.)

### Step 4.2: Red

`run-tests cl-harness/tests/context-view-test` — fails on missing `:exploration` method.

### Step 4.3: Implement `:exploration` method

Append to `src/context-view.lisp`. First, add `:import-from` for planner symbols (only for reading plan-step / investigation-target slots — not a circular dep because planner doesn't import context-view):

Update the `defpackage`:
```
  (:import-from #:cl-harness/src/planner
                #:plan-step-issue
                #:plan-step-investigation-targets
                #:investigation-target-kind
                #:investigation-target-name
                #:investigation-target-intent)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact-related-step-index
                #:source-fact-path
                #:source-fact-form-type
                #:source-fact-form-name)
```

(`source-fact-path` etc. were not yet imported; add them now.)

Then add the method:

```lisp
(defmethod context-view->string ((view context-view)
                                  (phase (eql :exploration)))
  "Exploration-phase view: current step's issue, investigation
targets (if any), and a one-line summary of relevant source-facts
(which files have been read in this step). Defensive: when no
:STEP was passed, emit a placeholder so the formatter never errors."
  (with-output-to-string (s)
    (let ((step (context-view-current-step view)))
      (cond
        ((null step)
         (format s "## Current step~%(no current step)~%"))
        (t
         (format s "## Current step~%~A~%"
                 (or (plan-step-issue step) ""))
         (let ((targets (plan-step-investigation-targets step)))
           (when targets
             (format s "~%## Investigation targets~%")
             (dolist (target targets)
               (format s "- [~A] ~A — ~A~%"
                       (string-downcase
                        (symbol-name (investigation-target-kind target)))
                       (investigation-target-name target)
                       (investigation-target-intent target))))))))
    (let ((facts (context-view-relevant-source-facts view)))
      (when facts
        (format s "~%## Source already read in this step~%")
        (dolist (fact facts)
          (format s "- ~A~A~%"
                  (namestring (source-fact-path fact))
                  (if (source-fact-form-name fact)
                      (format nil " :: ~A~A"
                              (or (source-fact-form-type fact) "")
                              (source-fact-form-name fact))
                      "")))))))
```

### Step 4.4: Verify green

`run-tests cl-harness/tests/context-view-test` — 16/16. Full suite 247/0.

### Step 4.5: Commit

```bash
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "$(cat <<'EOF'
feat: context-view :exploration formatter (Phase C.4)

Adds the (eql :exploration) method on CONTEXT-VIEW->STRING. The
formatter renders the current step's issue, the planner-supplied
investigation_targets (one bullet per target with kind, name,
intent), and a list of relevant source-facts (files already read
during this step). Defensive against a NIL :STEP — emits a
placeholder rather than erroring.

Imports plan-step / investigation-target accessors from planner
(read-only direction; planner does not import context-view, so no
cycle).

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `:implementation` formatter

**Files:**
- Modify: `tests/context-view-test.lisp` — 4 deftests.
- Modify: `src/context-view.lisp` — `(eql :implementation)` method + a few more imports.

### Step 5.1: Failing test

Append to `tests/context-view-test.lisp`:

```lisp
(deftest implementation-formatter-includes-step-issue
  (let* ((s (%state))
         (v (make-context-view s :phase :implementation
                                 :step (%step :issue "Add greet."))))
    (ok (search "Add greet."
                (context-view->string v :implementation)))))

(deftest implementation-formatter-summarises-relevant-patches
  (let* ((s (%state)))
    (cl-harness/src/state:develop-state-record-patch-record
     s (cl-harness/src/patch-record:make-patch-record
        :path "/tmp/cv-test/src/greet.lisp"
        :via-tool "lisp-edit-form"
        :form-type "defun"
        :form-name "greet"
        :related-step-index 0
        :turn 1))
    (let* ((v (make-context-view s :phase :implementation
                                   :step (%step :index 0)))
           (out (context-view->string v :implementation)))
      (ok (search "greet.lisp" out))
      (ok (search "lisp-edit-form" out)))))

(deftest implementation-formatter-includes-active-failures
  (let* ((s (%state)))
    (cl-harness/src/state:develop-state-record-failure
     s (cl-harness/src/failure-ledger:make-failure-record
        :kind :test-failed
        :description "greet returned wrong"
        :test-name "greet-returns-hello"
        :verify-source :incremental
        :related-step-index 0))
    (let* ((v (make-context-view s :phase :implementation
                                   :step (%step :index 0)))
           (out (context-view->string v :implementation)))
      (ok (search "greet returned wrong" out))
      (ok (search "greet-returns-hello" out)))))

(deftest implementation-formatter-omits-failure-section-when-clean
  (let* ((s (%state))
         (v (make-context-view s :phase :implementation
                                 :step (%step :index 0))))
    (ok (not (search "Active failures" (context-view->string
                                        v :implementation))))))
```

### Step 5.2: Red

Tests fail on missing `:implementation` method.

### Step 5.3: Implement `:implementation` method

Add `:import-from` for the patch-record / failure-record accessors. Update `src/context-view.lisp`'s defpackage:

```
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-related-step-index
                #:patch-record-path
                #:patch-record-via-tool
                #:patch-record-form-type
                #:patch-record-form-name
                #:patch-record-verify-status)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger-active
                #:failure-record-test-name
                #:failure-record-description
                #:failure-record-reason)
```

Then add the method:

```lisp
(defmethod context-view->string ((view context-view)
                                  (phase (eql :implementation)))
  "Implementation-phase view: current step's issue, a short
summary of relevant patch-records (what's been changed in this
step), and the active failure list (what's still broken). Source
facts are not enumerated — the agent's own tool calls are the
authoritative read log; the source-fact slot is reserved for
later phases that need it."
  (with-output-to-string (s)
    (let ((step (context-view-current-step view)))
      (cond
        ((null step)
         (format s "## Current step~%(no current step)~%"))
        (t
         (format s "## Current step~%~A~%"
                 (or (plan-step-issue step) "")))))
    (let ((patches (context-view-relevant-patch-records view)))
      (when patches
        (format s "~%## Patches applied in this step~%")
        (dolist (p patches)
          (format s "- ~A (~A~A)~%"
                  (namestring (patch-record-path p))
                  (patch-record-via-tool p)
                  (if (patch-record-form-name p)
                      (format nil " on ~A~A"
                              (or (patch-record-form-type p) "")
                              (patch-record-form-name p))
                      "")))))
    (let ((failures (context-view-active-failures view)))
      (when failures
        (format s "~%## Active failures~%")
        (dolist (f failures)
          (format s "- ~A: ~A~A~%"
                  (or (failure-record-test-name f) "(unnamed)")
                  (or (failure-record-description f) "(no description)")
                  (if (failure-record-reason f)
                      (format nil " (~A)" (failure-record-reason f))
                      "")))))))
```

### Step 5.4: Verify green

`run-tests cl-harness/tests/context-view-test` — 20/20. Full suite 251/0.

### Step 5.5: Commit

```bash
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "$(cat <<'EOF'
feat: context-view :implementation formatter (Phase C.5)

Adds the (eql :implementation) method on CONTEXT-VIEW->STRING.
The formatter renders the current step's issue, a one-bullet-per
summary of relevant patch-records (file + tool + form), and the
active failure list (test-name + description + reason). Source
facts are NOT rendered in this phase — the agent's own tool
calls are the authoritative read log within the agent loop.

Sections are emitted only when their data is non-empty (the
"Active failures" header is skipped on a clean run, etc.).

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `planner.lisp:%build-user-prompt` to use the planning view

**Files:**
- Modify: `src/planner.lisp` — replace the ad-hoc inventory/goal/replan block in `%build-user-prompt` with a call to `context-view->string view :planning`. Add `:import-from` for `context-view` symbols.
- Modify: `tests/planner-test.lisp` — verify the constructed prompt still contains the same identifying substrings.

### Step 6.1: Survey the current prompt builder

Use cl-mcp `lisp-read-file src/planner.lisp` `name_pattern="^%build-user-prompt$"`. Identify:
- The exact lines that assemble the inventory + goal + mode + project-root + system + test-system + replan blocks.
- Whether the function takes a `develop-state` argument or assembles from individual kwargs (`goal`, `project-inventory`, `prior-plan`, `failure-context`).

The planner's `plan-development` call site (per the survey) accepts kwargs `:goal :project-root :system :test-system :provider :project-inventory :mode :prior-plan :failure-context`. None of these are develop-state; they're individual fields.

**Approach for Phase C wiring**: rather than threading `develop-state` through the planner-fn callback (which would break test stubs), create a *transient* `develop-state` inside `%build-user-prompt` from the existing kwargs, render the planning view, splice it into the user prompt. This keeps the planner's external contract unchanged.

Alternative (cleaner): add `:develop-state` as an optional kwarg to `plan-development`; if non-NIL, derive the planning view from it; otherwise fall back to the existing string assembly. The orchestrator's `develop` function already constructs a develop-state and can pass it. Test stubs that don't pass it keep using the old path.

**Recommended: the alternative** (additive kwarg). Test stubs and the bench harness retain the old code path; production goes through the new path.

### Step 6.2: Failing test

Append to `tests/planner-test.lisp` a test that constructs a develop-state, calls `plan-development` (with a stubbed transport that captures the user prompt), and asserts the captured prompt contains both `## Goal` and `## Project inventory` headers (signs that the planning view formatter ran).

The exact form depends on the existing canned-transport stub; mirror its pattern. Sketch:

```lisp
(deftest plan-development-uses-context-view-when-develop-state-supplied
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/" :system "demo"
             :test-system "demo/tests"
             :project-inventory "[INVENTORY-MARKER]"))
         (captured-prompt nil)
         (transport (%capturing-canned-transport
                     #'(lambda (body) (setf captured-prompt body))
                     "{\"steps\":[]}")))
    (cl-harness/src/planner:plan-development "g"
      :provider transport
      :project-root "/tmp/"
      :system "demo" :test-system "demo/tests"
      :project-inventory "[INVENTORY-MARKER]"
      :develop-state s)
    (ok (search "## Goal" captured-prompt))
    (ok (search "## Project inventory" captured-prompt))
    (ok (search "[INVENTORY-MARKER]" captured-prompt))))
```

Define `%capturing-canned-transport` if it doesn't exist (or use the existing canned-transport with a side-channel capture).

Run `run-tests cl-harness/tests/planner-test` — fails because `:develop-state` kwarg doesn't exist on `plan-development` yet.

### Step 6.3: Implement the wiring

Use cl-mcp to:

1. Add `:import-from` for `cl-harness/src/context-view` symbols (`make-context-view`, `context-view->string`) to `src/planner.lisp`'s defpackage.

2. Add `:develop-state` to `plan-development`'s `&key` list (initform NIL).

3. Inside `%build-user-prompt`, when `develop-state` is non-NIL, replace the inventory + goal + replan block with `(context-view->string (make-context-view develop-state :phase :planning :prior-plan prior-plan :failure-context failure-context) :planning)`.

   When `develop-state` is NIL, keep the existing string assembly (for backward compatibility with test stubs and any external caller).

4. The mode-instruction, project-root, system, test-system, and prior-plan/failure-context-when-no-state-supplied paths stay byte-identical.

### Step 6.4: Verify green

cl-mcp `load-system` clean.
`run-tests cl-harness/tests/planner-test` — pre-existing tests pass + new test passes.
`run-tests cl-harness/tests/orchestrator-test` — no regressions.
`run-tests cl-harness/tests/develop-bench-test` — no regressions (bench harness uses the planner, but with the develop-state path).
Full suite — 252/0 (251 + 1 new planner test).

If any pre-existing planner-test fails, STOP. Likely cause: the new code path activated where it shouldn't have (e.g. develop-state was inadvertently set non-NIL in a test).

### Step 6.5: Commit

```bash
git add src/planner.lisp tests/planner-test.lisp
git commit -m "$(cat <<'EOF'
feat: wire planner to context-view :planning (Phase C.6)

PLAN-DEVELOPMENT now accepts an optional :develop-state kwarg.
When non-NIL, %build-user-prompt renders the inventory + goal +
replan block via CONTEXT-VIEW->STRING with the :planning phase
formatter. When NIL (test stubs, external callers without a
develop-state), the existing ad-hoc string assembly is used —
backward-compatible.

The orchestrator's DEVELOP loop will start passing :develop-state
in Task 8 (or via execute-plan threading already in place from
Phase B); for Task 6 the wiring is opt-in.

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire `explore.lisp:run-explore-agent` to use the exploration view

**Files:**
- Modify: `src/explore.lisp` — accept `:develop-state` kwarg; rebuild `%initial-explore-user-prompt` to use `context-view->string :exploration` when develop-state is present.
- Modify: `tests/explore-test.lisp` — add a wiring test (if explore-test exists; else add to agent-test).
- Modify: `src/orchestrator.lisp` — in `%execute-step`, when calling `explore-fn`, pass `:develop-state state`.

### Step 7.1: Survey

cl-mcp `lisp-read-file src/explore.lisp` `name_pattern="^run-explore-agent$"` and `name_pattern="^%initial-explore-user-prompt$"`. Identify the kwargs and the prompt assembly site.

Confirm a `tests/explore-test.lisp` exists or whether explore tests live in `agent-test.lisp`.

### Step 7.2: Failing test

Sketch (adapt to whichever test file holds explore-related tests):

```lisp
(deftest run-explore-agent-uses-context-view-when-develop-state-supplied
  ;; Drive run-explore-agent with a develop-state + a stub LLM that
  ;; emits one finish action. Capture the initial user prompt and
  ;; verify the :exploration formatter's section headers appear.
  ...)
```

The existing explore-test stubs (per `agent-test.lisp` pattern from Phase B Task 6) are the template.

### Step 7.3: Implement

1. Add `:import-from` for context-view symbols in `src/explore.lisp`'s defpackage.

2. Add `:develop-state` to `run-explore-agent`'s `&key` list (initform NIL).

3. Inside `%initial-explore-user-prompt` (or the in-line user-prompt assembly), branch on `develop-state` non-NIL:
   - When non-NIL: replace the issue + investigation-targets section with `(context-view->string (make-context-view develop-state :phase :exploration :step plan-step) :exploration)`.
   - When NIL: keep existing assembly.

4. In `src/orchestrator.lisp:%execute-step`, when calling `explore-fn`, pass `:develop-state develop-state`.

### Step 7.4: Verify green

`load-system` clean. Pre-existing explore tests pass. New wiring test passes. Full suite green.

### Step 7.5: Commit

```bash
git add src/explore.lisp src/orchestrator.lisp tests/explore-test.lisp  # or agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: wire explore-agent to context-view :exploration (Phase C.7)

RUN-EXPLORE-AGENT now accepts an optional :develop-state kwarg.
When non-NIL, the initial user prompt's issue + investigation-
targets section is rendered via CONTEXT-VIEW->STRING with the
:exploration formatter. The orchestrator's %execute-step now
threads :develop-state when invoking the explore-fn callback.

Standalone callers (test stubs, hypothetical external callers
that drive explore directly) retain the existing string-assembly
path.

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Wire `agent.lisp:run-agent` to use the implementation view

**Files:**
- Modify: `src/agent.lisp` — assembly of `initial-user-prompt` now branches on `develop-state` non-NIL.
- Modify: `tests/agent-test.lisp` — wiring test.

### Step 8.1: Survey

cl-mcp `lisp-read-file src/agent.lisp` `name_pattern="^initial-user-prompt$"` (it may be a `let`-bound variable in `run-agent`, not a defun; if so, search for the `(format nil ...)` call that builds it).

The Phase B survey identified lines 476-486 as the assembly. Confirm.

### Step 8.2: Failing test

Append to `tests/agent-test.lisp` a wiring test mirroring Phase B Task 6's `run-agent-records-patch-into-develop-state` pattern, but capturing the LLM-bound prompt and asserting it contains the :implementation formatter's section headers.

### Step 8.3: Implement

1. Add `:import-from` for context-view symbols in `src/agent.lisp`'s defpackage.

2. Inside `run-agent`'s `let*` that constructs `initial-user-prompt`, branch on `develop-state` non-NIL:
   - When non-NIL: take the issue + verify-summary + verify-detail-prose section and replace ONLY the issue portion with `(context-view->string (make-context-view develop-state :phase :implementation :step CURRENT-STEP) :implementation)`. The verify-summary / detail-prose stays as-is (it's already structured Phase A output).
   - When NIL: keep existing assembly.

3. The `CURRENT-STEP` argument is tricky: `run-agent` currently doesn't have direct access to the `plan-step`. Options:
   - **A**: extract step from develop-state via `(elt (develop-state-current-plan develop-state) (develop-state-current-step-index develop-state))`. Defensive: handle NIL index.
   - **B**: thread `:plan-step` as a new kwarg from orchestrator.

   **Recommended A** — the orchestrator's `%execute-step` (modified in Task 1) sets `current-step-index` on the state already, so the lookup is straightforward. Avoids adding another kwarg.

4. The default for run-agent's standalone callers (cl-harness:fix) is develop-state = NIL, current-step-index NIL. The fallback path uses the existing string assembly.

### Step 8.4: Verify green

`load-system` clean. Run `cl-harness/tests/agent-test`, `cl-harness/tests/orchestrator-test`, `cl-harness/tests/develop-bench-test` — all green. Particularly the agent's existing happy-path tests (`run-agent-finishes-passed-after-patch-and-reverify` etc.) must keep passing — they stub the LLM with canned responses that depend on action shape, not prompt text.

### Step 8.5: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: wire run-agent to context-view :implementation (Phase C.8)

RUN-AGENT's initial-user-prompt assembly now uses CONTEXT-VIEW->
STRING with the :implementation formatter for the issue / step
section when develop-state is non-NIL on the constructed agent-
state. The verify-summary and verify-detail-prose sections (Phase A
output) stay byte-identical.

The current step is looked up via ELT on develop-state's
current-plan at the current-step-index slot (set by Task 1's
%execute-step bookkeeping). Defensive on NIL index.

Standalone cl-harness:fix callers (no develop-state) continue to
use the existing string-assembly path. Verified by the existing
agent-test happy-path suite continuing to pass.

Phase C of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Lint + force-compile + regression sweep

Mirrors Phase B Task 9.

### Steps

1. `mallet src/context-view.lisp src/state.lisp src/orchestrator.lisp src/planner.lisp src/explore.lisp src/agent.lisp tests/context-view-test.lisp tests/state-test.lisp tests/planner-test.lisp tests/explore-test.lisp tests/agent-test.lisp tests/orchestrator-test.lisp` — fix any new warnings on Phase C files.
2. `(asdf:compile-system :cl-harness :force t)` via cl-mcp `repl-eval` — clean.
3. cl-mcp `run-tests` `{"system": "cl-harness/tests"}` — confirm pre-existing pass count + new Phase C tests, all passing.
4. Shell `rove cl-harness.asd` — same pre-existing 5-failure set in `develop-bench-test`, no new failures.
5. Commit only if mallet required fixes.

---

## Task 10: Docs annotation + final review + merge

### Step 10.1: Update `docs/context-management.md` §14

Mark Phase C landed; cross-reference §4 / §5 fulfilment.

```markdown
| C | `make-context-view` + 3 phase formatters (planning / exploration / implementation), wired into planner / explore / agent | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-c-context-view.md` |
```

Update the "fulfilment" paragraph to note that §4 / §5 are now (mostly) addressed for the 3 active phases; testing is folded into implementation; integration is deferred to Phase E.

### Step 10.2: Final code review

`superpowers:code-reviewer` over the entire `phase-c-context-view` branch (base = post-Phase-B `main` SHA; head = current branch tip). Checklist:

- All 3 wiring tasks (6, 7, 8) preserve standalone-caller behavior (fix path inert).
- `current-step-index` is correctly set/cleared in `%execute-step` via `unwind-protect`.
- The 3 formatters produce output containing the spec-defined substrings.
- No `:local-nicknames`.
- mallet clean, force-compile clean.
- Test counts: context-view-test 20+, planner-test +1, explore-test +1, agent-test +1, orchestrator-test +0 (Task 1's wiring is internal).

### Step 10.3: Merge to main

`superpowers:finishing-a-development-branch` skill, `--no-ff` merge with summary message highlighting:
- The 3 new files (`src/context-view.lisp`, `tests/context-view-test.lisp`).
- The wiring in 3 prompt-builder sites (planner, explore, agent).
- The `current-step-index` slot on develop-state.
- Strict behaviour-preservation contract honoured (standalone fix path inert).

---

## Verification checklist (run before opening a PR)

- [ ] `src/context-view.lisp` exists with the documented exports
- [ ] `src/state.lisp` has `current-step-index` slot (slot count 19)
- [ ] `src/orchestrator.lisp:%execute-step` sets/clears `current-step-index` via `unwind-protect`
- [ ] `cl-harness.asd` registers `cl-harness/tests/context-view-test`
- [ ] `plan-development` accepts optional `:develop-state` kwarg; falls back to existing path when NIL
- [ ] `run-explore-agent` accepts optional `:develop-state` kwarg; same fallback semantics
- [ ] `run-agent`'s initial-user-prompt assembly uses `:implementation` formatter when develop-state non-NIL; falls back otherwise
- [ ] Standalone `cl-harness:fix` path is unaffected (verified by existing agent-test happy-path suite)
- [ ] mallet clean on Phase C files
- [ ] `(asdf:compile-system :cl-harness :force t)` clean
- [ ] Full `cl-harness/tests` rove suite green
- [ ] `docs/context-management.md` §14 updated

## Rollback plan

If a wiring task surfaces a behavioural regression that can't be diagnosed quickly:

1. `git checkout main -- src/planner.lisp src/explore.lisp src/agent.lisp` — restore the wiring sites.
2. Keep `src/context-view.lisp`, `tests/context-view-test.lisp`, and the `current-step-index` slot (additive; safe to keep).
3. Open an issue describing the regression and re-attempt one wiring at a time.

The split between data-layer tasks (1-5) and wiring tasks (6-8) is intentional so the rollback boundary is clean: the data layer is independently useful, and wiring rolls back per-file.
