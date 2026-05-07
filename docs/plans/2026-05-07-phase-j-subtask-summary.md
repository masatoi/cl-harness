# Phase J — Subtask Summary + Resolved-Failures Hooks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Compress completed plan-steps into **structured `subtask-summary` records** (what completed, what changed, tests added, verification, design impacts) and let the `:implementation` view consume them as compressed history. As a small companion change, surface **resolved failures** in the `:implementation` view as one-line regression-relevant references — not as active failures, but so the agent can avoid re-introducing fixed bugs.

**Architecture:**
- **New module** `src/subtask-summary.lisp`: a record class `subtask-summary` with five required structured fields (`step-index`, `test-name`, `what-changed`, `tests-added`, `verification`) plus optional `design-impact` text and a `:summarised-at` timestamp.
- **Builder** `summarise-step-result` in the same package: given a `develop-step-result` and the develop-state, produce a `subtask-summary`. Reuses Phase E's `summarise-completed-step` for the test-name / status line and aggregates patch-records / failure-ledger info for the rest.
- **No new slot** on `develop-state` — the summaries are *derived* from the existing `step-results` + `patch-records` + `failure-ledger` slots. Reproducing them is cheap; storing them would invite drift.
- **`:implementation` view** gains a `## Completed subtask summaries` block listing the structured summary of every prior step (oldest first) plus a `## Recently resolved failures (regression watch)` block listing the most recent N (default 3) resolved failures with their attributed patch.
- **No orchestrator changes.** Phase J is a pure consumer-side phase: data already exists, this just packages and renders it.

**Tech Stack:** SBCL / ASDF `:package-inferred-system` / Rove tests / alexandria / `:import-from` + `:export` only.

---

## Why this phase

`docs/context-management.md` §6.4 (Completed Subtasks) and §6.5 (Resolved Failures) prescribe:
- Compress completed subtasks into summaries, not detailed history.
- Don't include resolved failures as active.
- Optionally include short references for regression / background.

Today the `:implementation` view shows only the **current** step's patches and active failures. Prior steps' work is invisible to the agent — it has to re-read the develop-result if it wants to know "what did we already build?". The result is duplicate effort and occasional regressions on already-fixed failures.

Phase J keeps the implementation small: the data is already in `develop-state`. We add a builder + a view block. No state mutation, no new tools, no new model calls.

---

## Design contract

1. **`subtask-summary` is derived, not stored.** Constructed on-demand by `summarise-step-result`. The constructor accepts pre-built field values for callers that want to inject; the builder fills them from a `develop-step-result` + `develop-state`.
2. **One record per completed step.** No aggregation across steps; the view formatter does the iteration.
3. **`what-changed`** is a list of one-line strings (one per patch-record on this step), not a free-text blob. The view formatter joins them with newlines.
4. **`tests-added`** is a list of test-name strings (extracted from this step's `plan-step-test-name`) — typically one entry per step, but kept as a list to allow future multi-test steps.
5. **`verification`** is a single keyword: `:passed` / `:give-up` / `:limit-exhausted` / `:dirty-only` / `:error` (mirroring `develop-step-result-status`).
6. **`design-impact`** is optional. Phase J populates it from `abstraction-decisions` on the step result when present, joined with `; `. Absent on steps without abstraction decisions.
7. **Resolved-failures block is capped.** Default 3 entries (most recent first). Configurable via a parameter `+resolved-failures-context-limit+` so a future tuning pass can adjust without touching consumers.
8. **`:implementation` view formatting.** New blocks appear AFTER the current step's `## Active failures` block. Order: Completed subtask summaries, then Recently resolved failures.
9. **No re-export from `src/main`.**

---

## Files touched

| Path | Action |
|---|---|
| `src/subtask-summary.lisp` | **Create** — record class, constructor, `summarise-step-result` builder |
| `src/context-view.lisp` | Modify — view slots; `:implementation` formatter renders both new blocks |
| `cl-harness.asd` | Modify — add `cl-harness/tests/subtask-summary-test` to test deps |
| `tests/subtask-summary-test.lisp` | **Create** |
| `tests/context-view-test.lisp` | Modify |

---

## Task 1: `subtask-summary` data module + builder

**Files:**
- Create: `src/subtask-summary.lisp`
- Create: `tests/subtask-summary-test.lisp`
- Modify: `cl-harness.asd`

### Step 1: Failing tests

```lisp
;;;; tests/subtask-summary-test.lisp

(defpackage #:cl-harness/tests/subtask-summary-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/subtask-summary
                #:subtask-summary
                #:make-subtask-summary
                #:subtask-summary-step-index
                #:subtask-summary-test-name
                #:subtask-summary-what-changed
                #:subtask-summary-tests-added
                #:subtask-summary-verification
                #:subtask-summary-design-impact
                #:subtask-summary-summarised-at
                #:summarise-step-result))

(in-package #:cl-harness/tests/subtask-summary-test)

(deftest make-subtask-summary-records-fields
  (let ((s (make-subtask-summary
            :step-index 0
            :test-name "first-test"
            :what-changed (list "src/foo.lisp (defun bar)")
            :tests-added (list "first-test")
            :verification :passed
            :design-impact "adopted: pure function over macro")))
    (ok (typep s 'subtask-summary))
    (ok (= 0 (subtask-summary-step-index s)))
    (ok (string= "first-test" (subtask-summary-test-name s)))
    (ok (equal '("src/foo.lisp (defun bar)") (subtask-summary-what-changed s)))
    (ok (equal '("first-test") (subtask-summary-tests-added s)))
    (ok (eq :passed (subtask-summary-verification s)))
    (ok (string= "adopted: pure function over macro"
                 (subtask-summary-design-impact s)))
    (ok (integerp (subtask-summary-summarised-at s)))))

(deftest make-subtask-summary-rejects-unknown-verification
  (ok (handler-case
          (progn
            (make-subtask-summary
             :step-index 0 :test-name "t"
             :what-changed nil :tests-added nil
             :verification :wat)
            nil)
        (error () t))))

(deftest summarise-step-result-builds-from-step-result-and-state
  ;; Build a develop-state with one completed step result and one
  ;; patch-record bound to that step. summarise-step-result should
  ;; derive a subtask-summary whose what-changed lists the patch's
  ;; namestring + form.
  (let* ((state (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
         (step-result (make-instance
                       'cl-harness/src/orchestrator:develop-step-result
                       :step-index 0
                       :test-name "first-test"
                       :run-config nil
                       :status :passed))
         (patch (cl-harness/src/patch-record:make-patch-record
                 :path "src/foo.lisp" :via-tool "lisp-edit-form"
                 :form-type "defun" :form-name "bar"
                 :related-step-index 0 :turn 1)))
    (cl-harness/src/state:develop-state-record-step-result state step-result)
    (cl-harness/src/state:develop-state-record-patch-record state patch)
    (let ((sum (summarise-step-result step-result state)))
      (ok (= 0 (subtask-summary-step-index sum)))
      (ok (string= "first-test" (subtask-summary-test-name sum)))
      (ok (eq :passed (subtask-summary-verification sum)))
      (ok (= 1 (length (subtask-summary-what-changed sum))))
      (ok (search "src/foo.lisp"
                  (first (subtask-summary-what-changed sum))))
      (ok (search "defun bar"
                  (first (subtask-summary-what-changed sum)))))))

(deftest summarise-step-result-pulls-design-impact-from-abstractions
  (let* ((state (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
         (decision (cl-harness/src/abstraction:make-abstraction-decision
                    :adopted "defun greet"
                    :rationale "pure function suffices"
                    :step-index 0))
         (step-result (make-instance
                       'cl-harness/src/orchestrator:develop-step-result
                       :step-index 0
                       :test-name "first-test"
                       :run-config nil
                       :status :passed
                       :abstraction-decisions (list decision))))
    (cl-harness/src/state:develop-state-record-step-result state step-result)
    (let ((sum (summarise-step-result step-result state)))
      (ok (search "defun greet"
                  (or (subtask-summary-design-impact sum) ""))))))
```

Update `cl-harness.asd` with `"cl-harness/tests/subtask-summary-test"`.

### Step 2: Run — expect FAIL

### Step 3: Implement `src/subtask-summary.lisp`

```lisp
;;;; src/subtask-summary.lisp
;;;;
;;;; Phase J of the context-management refactor
;;;; (docs/context-management.md §6.4). One subtask-summary
;;;; compresses a completed plan-step into a fixed-shape record
;;;; (what changed, tests added, verification, design impact) so the
;;;; :implementation context view can show prior subtasks without
;;;; replaying their full history.
;;;;
;;;; The record is DERIVED from the existing develop-state ledgers:
;;;; step-results, patch-records, failure-ledger, abstraction-
;;;; decisions. We don't store summaries on develop-state; we
;;;; rebuild them on demand via SUMMARISE-STEP-RESULT.

(defpackage #:cl-harness/src/subtask-summary
  (:use #:cl)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-step-result
                #:develop-step-result-step-index
                #:develop-step-result-test-name
                #:develop-step-result-status
                #:develop-step-result-abstraction-decisions)
  (:import-from #:cl-harness/src/state
                #:develop-state-patch-records)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-path
                #:patch-record-form-type
                #:patch-record-form-name
                #:patch-record-related-step-index)
  (:import-from #:cl-harness/src/abstraction
                #:abstraction-decision-kind
                #:abstraction-decision-name)
  (:export #:subtask-summary
           #:make-subtask-summary
           #:subtask-summary-step-index
           #:subtask-summary-test-name
           #:subtask-summary-what-changed
           #:subtask-summary-tests-added
           #:subtask-summary-verification
           #:subtask-summary-design-impact
           #:subtask-summary-summarised-at
           #:summarise-step-result
           #:+supported-verification-statuses+))

(in-package #:cl-harness/src/subtask-summary)

(defparameter +supported-verification-statuses+
  '(:passed :give-up :limit-exhausted :dirty-only :error)
  "Verification keywords accepted by MAKE-SUBTASK-SUMMARY. Mirrors
DEVELOP-STEP-RESULT-STATUS.")

(defclass subtask-summary ()
  ((step-index :initarg :step-index :reader subtask-summary-step-index)
   (test-name :initarg :test-name :reader subtask-summary-test-name)
   (what-changed :initarg :what-changed :initform nil
                 :reader subtask-summary-what-changed)
   (tests-added :initarg :tests-added :initform nil
                :reader subtask-summary-tests-added)
   (verification :initarg :verification
                 :reader subtask-summary-verification)
   (design-impact :initarg :design-impact :initform nil
                  :reader subtask-summary-design-impact)
   (summarised-at :initarg :summarised-at
                  :reader subtask-summary-summarised-at))
  (:documentation
   "Compressed view of one completed plan-step. All slots are
plain values (integers, strings, lists of strings) so the record
serialises trivially."))

(defun make-subtask-summary (&key step-index test-name
                               what-changed tests-added
                               verification design-impact
                               (summarised-at (get-universal-time)))
  "Construct a SUBTASK-SUMMARY. STEP-INDEX integer; TEST-NAME string;
WHAT-CHANGED / TESTS-ADDED lists of strings; VERIFICATION must be a
member of +SUPPORTED-VERIFICATION-STATUSES+; DESIGN-IMPACT optional
string."
  (check-type step-index integer)
  (check-type test-name string)
  (unless (member verification +supported-verification-statuses+)
    (error "subtask-summary: unsupported :verification ~S; expected ~S"
           verification +supported-verification-statuses+))
  (dolist (entry what-changed) (check-type entry string))
  (dolist (entry tests-added) (check-type entry string))
  (when design-impact (check-type design-impact string))
  (make-instance 'subtask-summary
                 :step-index step-index
                 :test-name test-name
                 :what-changed what-changed
                 :tests-added tests-added
                 :verification verification
                 :design-impact design-impact
                 :summarised-at summarised-at))

(defun %describe-patch (patch)
  "One-line description of PATCH for the WHAT-CHANGED list."
  (format nil "~A~A"
          (namestring (patch-record-path patch))
          (if (patch-record-form-name patch)
              (format nil " (~A ~A)"
                      (or (patch-record-form-type patch) "")
                      (patch-record-form-name patch))
              "")))

(defun %describe-decision (decision)
  (format nil "~(~A~): ~A"
          (abstraction-decision-kind decision)
          (abstraction-decision-name decision)))

(defun summarise-step-result (step-result state)
  "Build a SUBTASK-SUMMARY from STEP-RESULT (a DEVELOP-STEP-RESULT)
and STATE (a DEVELOP-STATE). What-changed is derived from STATE's
patch-records filtered by step-index; tests-added is the step's own
test-name; design-impact is the step's abstraction-decisions joined
with '; '."
  (let* ((step-index (develop-step-result-step-index step-result))
         (test-name (or (develop-step-result-test-name step-result)
                        "(no test name)"))
         (status (develop-step-result-status step-result))
         (patches
           (remove-if-not
            (lambda (p)
              (eql step-index (patch-record-related-step-index p)))
            (develop-state-patch-records state)))
         (decisions (develop-step-result-abstraction-decisions
                     step-result)))
    (make-subtask-summary
     :step-index step-index
     :test-name test-name
     :what-changed (mapcar #'%describe-patch patches)
     :tests-added (list test-name)
     :verification status
     :design-impact
     (and decisions
          (format nil "~{~A~^; ~}"
                  (mapcar #'%describe-decision decisions))))))
```

### Step 4: Run — expect PASS, commit

```
git add src/subtask-summary.lisp tests/subtask-summary-test.lisp cl-harness.asd
git commit -m "feat: subtask-summary record + summarise-step-result builder (Phase J)"
```

---

## Task 2: `:implementation` view consumes summaries + resolved failures

**Files:**
- Modify: `src/context-view.lisp`
- Modify: `tests/context-view-test.lisp`

### Step 1: Failing tests

```lisp
(deftest implementation-formatter-renders-completed-subtask-summaries
  ;; Build develop-state with a completed step + a patch on that
  ;; step + a current step. :implementation view should include
  ;; "## Completed subtask summaries" with one bullet for the prior
  ;; step.
  )

(deftest implementation-formatter-omits-summaries-when-no-prior-steps
  ;; Single in-flight step, no completed steps -> no
  ;; "## Completed subtask summaries" header.
  )

(deftest implementation-formatter-renders-recently-resolved-failures
  ;; Build develop-state with one resolved failure. :implementation
  ;; view should include "## Recently resolved failures (regression
  ;; watch)" with one bullet.
  )

(deftest implementation-formatter-caps-resolved-failures-at-limit
  ;; Push 5 resolved failures. Default limit is 3. View should show
  ;; only the 3 most recent.
  )

(deftest implementation-formatter-omits-resolved-failures-when-empty
  ;; No resolved failures -> no header.
  )
```

### Step 2: Implement

In `src/context-view.lisp`:
- Add `:import-from #:cl-harness/src/state #:develop-state-step-results`. (`develop-state-failure-ledger` is already imported.)
- Add `:import-from #:cl-harness/src/failure-ledger #:failure-ledger-resolved`.
- Add `:import-from #:cl-harness/src/subtask-summary #:summarise-step-result #:subtask-summary-step-index #:subtask-summary-test-name #:subtask-summary-what-changed #:subtask-summary-verification #:subtask-summary-design-impact`.
- Define a parameter:

```lisp
(defparameter +resolved-failures-context-limit+ 3
  "How many recently-resolved failures the :IMPLEMENTATION view
includes as regression watch entries. Configurable so a tuning pass
can adjust without touching consumer code.")
```

- Add two slots to `context-view`:

```lisp
(completed-subtask-summaries :initarg :completed-subtask-summaries
                             :initform nil
                             :reader context-view-completed-subtask-summaries
                             :documentation "List of SUBTASK-SUMMARY
records, one per completed step, oldest first. Populated for
:IMPLEMENTATION.")
(recently-resolved-failures :initarg :recently-resolved-failures
                            :initform nil
                            :reader context-view-recently-resolved-failures
                            :documentation "Most-recent
+RESOLVED-FAILURES-CONTEXT-LIMIT+ resolved FAILURE-RECORDs, newest
first. Populated for :IMPLEMENTATION.")
```

- Populate them in the `:implementation` branch of `make-context-view`:

```lisp
(let* ((completed (and state
                       (remove-if-not
                        (lambda (r)
                          (and (slot-boundp r 'cl-harness/src/orchestrator::status)
                               (member (cl-harness/src/orchestrator:develop-step-result-status r)
                                       '(:passed))))
                        (cl-harness/src/state:develop-state-step-results state))))
       (summaries (and completed
                       (mapcar (lambda (r) (summarise-step-result r state))
                               completed)))
       (resolved (and state
                      (let ((ledger (cl-harness/src/state:develop-state-failure-ledger state)))
                        (and ledger
                             (let ((all (failure-ledger-resolved ledger)))
                               (subseq (reverse all)
                                       0 (min (length all)
                                              +resolved-failures-context-limit+))))))))
  ;; ... in make-instance:
  ;;   :completed-subtask-summaries summaries
  ;;   :recently-resolved-failures resolved
  )
```

(Adjust the surrounding `make-instance` call accordingly.)

- In the `:implementation` formatter, AFTER the existing `## Active failures` block, append:

```lisp
(let ((summaries (context-view-completed-subtask-summaries view)))
  (when summaries
    (format s "~%## Completed subtask summaries~%")
    (dolist (sum summaries)
      (format s "- step ~A (~A): ~A~%"
              (subtask-summary-step-index sum)
              (subtask-summary-test-name sum)
              (string-downcase (symbol-name (subtask-summary-verification sum))))
      (dolist (entry (subtask-summary-what-changed sum))
        (format s "    - changed: ~A~%" entry))
      (when (subtask-summary-design-impact sum)
        (format s "    - design: ~A~%"
                (subtask-summary-design-impact sum))))))
(let ((resolved (context-view-recently-resolved-failures view)))
  (when resolved
    (format s "~%## Recently resolved failures (regression watch)~%")
    (dolist (f resolved)
      (format s "- ~A: ~A~A~%"
              (or (failure-record-test-name f) "(unnamed)")
              (failure-record-description f)
              (if (failure-record-resolved-by-patch f)
                  (format nil " (resolved by patch on ~A)"
                          (namestring (patch-record-path
                                       (failure-record-resolved-by-patch f))))
                  ""))))))
```

(The formatter needs `failure-record-resolved-by-patch` imported from `cl-harness/src/failure-ledger` and `patch-record-path` already imported. Add them to the `:import-from` blocks.)

### Step 3: Run — expect PASS, commit

```
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "feat: subtask summaries + resolved-failure refs in :implementation view (Phase J)"
```

---

## Task 3: Lint + force-compile + regression sweep

```bash
mallet src/subtask-summary.lisp src/context-view.lisp \
       tests/subtask-summary-test.lisp tests/context-view-test.lisp
```

Address warnings, force-compile, full test sweep. Test count grows by ~9-10.

```
git commit -m "style: address mallet feedback on Phase J files"
```

---

## Task 4: Docs annotation + final review + merge

### Step 1: Update §14

```markdown
| J | structured `subtask-summary` record + `summarise-step-result` builder; `:implementation` view renders prior steps as compressed bullets and lists most-recent resolved failures (regression watch, default cap 3) | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-j-subtask-summary.md` |
```

Update trailing prose: §6.4 (Completed Subtasks) and §6.5 (Resolved Failures) are now addressed for the `:implementation` view. With Phase J landed, the §14 deferred list shrinks to nothing — all original sections of `docs/context-management.md` have at least an MVP implementation.

### Step 2: Final review + merge

`superpowers:code-reviewer` over the branch. Checklist:
- `subtask-summary` is constructed via the builder, never stored on develop-state.
- `:implementation` view byte-identical to current behaviour when no completed steps and no resolved failures.
- Resolved-failures cap honoured (default 3).
- mallet clean, force-compile clean.
- No `:local-nicknames`, no new `src/main` re-exports.

`superpowers:finishing-a-development-branch` → `--no-ff` merge.

---

## Verification checklist

- [ ] `make-subtask-summary` validates verification keyword and field types.
- [ ] `summarise-step-result` correctly populates what-changed from filtered patch-records.
- [ ] `summarise-step-result` populates design-impact from abstraction-decisions when present.
- [ ] `:implementation` view shows completed summaries oldest-first.
- [ ] `:implementation` view shows resolved failures newest-first, capped at +RESOLVED-FAILURES-CONTEXT-LIMIT+.
- [ ] `:implementation` view emits no new headers when both lists are empty (byte-identical to today).
- [ ] No regression in pre-Phase-J test count.
- [ ] mallet clean, force-compile clean.
- [ ] §14 updated; deferred-list cleared.

---

## Acceptance criteria

Phase J is complete when:

1. `subtask-summary` record + `summarise-step-result` builder land.
2. `:implementation` view renders completed summaries and recently-resolved failures.
3. No develop-state slot was added (summaries are derived).
4. mallet and force-compile clean.
5. Test count grows by ~9-10 with no pre-existing failures introduced.
6. §14 marks Phase J landed and the deferred-list of context-management sections is empty.
