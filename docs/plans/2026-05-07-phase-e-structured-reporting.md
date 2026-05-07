# Phase E: Structured reporting + staleness foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Surface the structured data Phases A-D have been recording (`source-facts`, `patch-records`, `failure-ledger`, `step-results`) as a comprehensive develop-state report, and add the `source-fact-stale-p` predicate as the foundation for future staleness-driven invalidation.

**Architecture:** New file `src/report.lisp` introduces `format-develop-state-report` which takes a `develop-state` and produces a markdown report with sections for goal / plan / completed-steps / patches / resolved-failures / integration-issues. Per-step and per-failure summarizer helpers live in the same file. New predicate `source-fact-stale-p` lands in `src/source-fact.lisp` (compares `mtime-at-read` to current `file-write-date`); no consumer integration in this phase — it's a building block. The CLI's `develop` command gains an opt-in route to the structured report (existing `format-develop-report` stays as the default for backward compatibility). The `cl-harness:fix` standalone path is unchanged — `format-final-report` remains the agent-loop reporter for that command.

**Tech stack:** Common Lisp (SBCL), ASDF `:package-inferred-system`, rove tests, alexandria, local-time. Phase A/B/C/D patterns apply: data files have zero inbound deps on consumers; `:import-from` only; docstrings on public symbols; internal helpers `%`-prefixed.

**Out of scope (deferred):**
- **Staleness invalidation in context-view generation** — `source-fact-stale-p` lands as a predicate but `make-context-view` does NOT yet filter on staleness. Phase F can wire that in once the runtime-vocabulary ledger exists (so the same staleness machinery covers both source AND vocabulary).
- **Runtime-vocabulary ledger** — Phase B' (separate plan, deferred).
- **Replacing `format-final-report` for `cl-harness:fix`** — that's the agent-loop reporter; replacing it would touch the standalone path. Phase E only enhances the orchestrator (`develop`) reporter.
- **Resolved-failures rendering inside context-view's `:implementation` formatter** — Phase C deliberately renders only active failures; resolved are kept for the audit trail (this report). Don't change Phase C behavior.
- **Patch-attribution narrative** ("step 0's patch on `src/greet.lisp` resolved test `greet-returns-hello`") — the data is there via `failure-record-resolved-by-patch` linkage from Phase B, but a richer human-readable narrative is Phase F polish.
- **JSONL `:develop-end` event emission** — orchestrator currently has no top-level closure event; adding one would require changes across `develop` + readers. The structured report is generated on-demand from in-memory state; emit-on-end is a separate concern.

**Acceptance criteria:**
1. `src/source-fact.lisp` exports a new `source-fact-stale-p` predicate that returns T when `(file-write-date path) > (source-fact-mtime-at-read fact)`, NIL otherwise. NIL `mtime-at-read` (no recorded baseline) is reported as NOT stale (no signal to compare against).
2. `src/report.lisp` exports `format-develop-state-report (state &key (stream nil))`, returning a markdown string (when `:stream nil`) or writing to `:stream` and returning `(values)`.
3. The report contains, in order: `# Goal`, `## Plan` (numbered steps), `## Completed steps` (per-step one-line summary including status + patch count + active-failure count for that step), `## Patches applied` (per-patch one-line: file, tool, form-name, verify-status), `## Resolved failures` (per-resolved-failure one-line with attribution to resolving patch when known), `## Active failures` (one-line per still-active failure), `## Integration issues` (when present), `## Source facts` (count + stale count via `source-fact-stale-p`).
4. `src/cli.lisp:format-develop-report` is unchanged. A NEW function `format-develop-report-structured` wraps `format-develop-state-report`. The CLI's `develop` command gets an opt-in `--structured-report` flag (or equivalent) that picks the new formatter.
5. New `tests/report-test.lisp` covers the structured formatter (substring presence per section, empty-state handling, multi-step scenarios) and the `source-fact-stale-p` predicate.
6. Full `cl-harness/tests` rove suite passes via cl-mcp `run-tests` — Phase D baseline 267/0 plus the new tests, zero regressions.
7. mallet clean on Phase E-touched files.
8. `(asdf:compile-system :cl-harness :force t)` clean.
9. `docs/context-management.md` §14 updated to mark Phase E landed; §10 (Reporting) marked addressed; §9 (Staleness) noted as foundation laid (predicate present, consumer in Phase F).

**Risks & mitigations:**

- **R1: Existing CLI's `format-develop-report` is widely-relied-upon by tests / external callers.** → Phase E does NOT modify it. The new structured reporter is opt-in via a new flag/function. All existing CLI tests pass unchanged.

- **R2: `format-develop-state-report` walks ledgers without bound.** A long run could have hundreds of source-facts. → Phase E renders SUMMARIES (counts), not full enumerations, except for the patches and failures sections (which are bounded by `max-patches` / typical failure counts). The "Source facts" section is just `(length source-facts)` + stale count; not per-fact rendering.

- **R3: `source-fact-stale-p` performs `file-write-date` per call.** Calling it on hundreds of facts in a tight loop has filesystem cost. → Phase E only calls it for the report's stale-count summary (one pass). Phase F may add caching or batch-stat when the predicate is consumed by context-view filtering.

- **R4: The `develop` CLI's existing markdown output (`format-develop-report-markdown`) overlaps in scope with the new structured reporter.** → Phase E's reporter is more comprehensive (consumes ledgers); the existing markdown output is a thin slice. Either co-exist (caller picks) or eventually deprecate. For Phase E MVP, both exist; the new one is opt-in.

- **R5: Tests for `format-develop-state-report` are brittle if asserted on exact text.** → Tests assert substring presence (per Phase A/B/C convention) and structural shape (empty sections elided, populated sections present), not exact byte sequences.

- **R6: Phase B's `make-failure-record` validates `kind` against `+supported-failure-kinds+`. Phase E's report formatter must handle every kind without crashing.** → The formatter uses generic accessors; `kind` is just a keyword in the output. Tests cover at least `:test-failed` and `:load-failed` paths.

**Working agreement:**
- cl-mcp tools (`lisp-edit-form`, `lisp-patch-form`, `lisp-read-file`, `repl-eval`, `run-tests`) for Lisp source modifications. No shell `grep`/`sed`/`cat` against Lisp source.
- First action of every implementation session: cl-mcp `fs-set-project-root` on the repo root.
- Commit after each green TDD cycle. Use feature branch `phase-e-reporting`.
- Phase A-D lessons that apply: keep new files dependency-free of consumers; constructor validation; tests use `&allow-other-keys` to absorb future kwargs; place base-vs-head worktrees OUTSIDE `~/.roswell/local-projects/` to avoid the Phase C/D ASDF source-registry trap.

---

## Task 1: `source-fact-stale-p` predicate

**Files:**
- Modify: `src/source-fact.lisp`
- Modify: `tests/source-fact-test.lisp`

### Step 1.1: Survey

cl-mcp `lisp-read-file src/source-fact.lisp` to confirm the existing exports (`source-fact`, `make-source-fact`, accessors `source-fact-path`, `source-fact-mtime-at-read`, etc.). Phase B Task 1 established the slot semantics: `mtime-at-read` is auto-stat'd via `file-write-date` at construction time.

### Step 1.2: Failing tests

Append to `tests/source-fact-test.lisp` (after the last existing deftest, with appropriate `:import-from` updates for `source-fact-stale-p`):

```lisp
(deftest source-fact-stale-p-returns-nil-when-mtime-not-recorded
  ;; When mtime-at-read is explicitly NIL (the recorder declined to
  ;; stat at read time), there's no baseline to compare against.
  ;; Predicate returns NIL — "no staleness signal".
  (let ((s (make-source-fact :path "/tmp/cl-harness-stale-test.lisp"
                             :via-tool "lisp-read-file"
                             :mtime-at-read nil)))
    (ok (null (source-fact-stale-p s)))))

(deftest source-fact-stale-p-returns-nil-when-file-missing
  ;; If the file no longer exists, file-write-date errors. The
  ;; predicate must not propagate; it returns NIL (no baseline match
  ;; → no signal). Phase F may upgrade to a dedicated :missing state.
  (let ((s (make-source-fact :path "/tmp/cl-harness-stale-no-such-file.lisp"
                             :via-tool "lisp-read-file"
                             :mtime-at-read 100)))
    (ok (null (source-fact-stale-p s)))))

(deftest source-fact-stale-p-returns-t-when-file-newer
  ;; Construct a fact with an old mtime, then write the file with a
  ;; current timestamp; predicate should report stale.
  (let* ((path #P"/tmp/cl-harness-stale-newer.lisp"))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (let ((s (make-source-fact :path path
                                    :via-tool "lisp-read-file"
                                    :mtime-at-read 100)))
           (ok (source-fact-stale-p s)))
      (when (probe-file path) (delete-file path)))))

(deftest source-fact-stale-p-returns-nil-when-mtime-equal
  ;; Construct a fact whose recorded mtime EQUALS the current file's
  ;; mtime. No staleness.
  (let* ((path #P"/tmp/cl-harness-stale-equal.lisp"))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (let ((s (make-source-fact :path path
                                    :via-tool "lisp-read-file"
                                    :mtime-at-read (file-write-date path))))
           (ok (null (source-fact-stale-p s))))
      (when (probe-file path) (delete-file path)))))
```

### Step 1.3: Red

cl-mcp `run-tests cl-harness/tests/source-fact-test`. Expected: 4 new tests fail with `source-fact-stale-p` undefined.

### Step 1.4: Implement

Use cl-mcp `lisp-patch-form` on `src/source-fact.lisp`'s defpackage to add `#:source-fact-stale-p` to `:export`.

Use cl-mcp `lisp-edit-form` `insert_after` (target the existing `make-source-fact` defun, or whichever is the last form) to add:

```lisp
(defun source-fact-stale-p (fact)
  "Return T when FACT's path on disk has been modified since the
read recorded by the fact (i.e. (file-write-date path) > 
(source-fact-mtime-at-read fact)). Returns NIL when:
- The fact has no recorded mtime (no baseline to compare against).
- The file no longer exists (no current mtime to read).
- The file's mtime equals or precedes the recorded baseline.

The third branch is the typical 'no staleness' case: the file is
unchanged since the read.

This is a pure predicate — no side effects, no caching. Phase E
introduces it as a building block; Phase F may wire it into
context-view filtering or invalidation."
  (let ((recorded (source-fact-mtime-at-read fact)))
    (and recorded
         (let ((current (handler-case (file-write-date (source-fact-path fact))
                          (error () nil))))
           (and current (> current recorded))))))
```

### Step 1.5: Verify green

cl-mcp `lisp-check-parens` on `src/source-fact.lisp`.
cl-mcp `load-system` `{"system": "cl-harness", "force": true}` — clean.
cl-mcp `run-tests cl-harness/tests/source-fact-test` — 4 new tests pass.
cl-mcp `run-tests cl-harness/tests` — full suite green; expect 271/0 (was 267, +4).

### Step 1.6: Commit

```bash
git checkout -b phase-e-reporting
git add src/source-fact.lisp tests/source-fact-test.lisp
git commit -m "$(cat <<'EOF'
feat: source-fact-stale-p predicate (Phase E.1 staleness foundation)

Adds SOURCE-FACT-STALE-P predicate: returns T when the file on
disk has been modified since the read recorded by the fact.
Defensive against missing files (file-write-date errors are
swallowed) and missing baselines (NIL mtime-at-read returns NIL —
no signal).

Pure predicate, no side effects, no caching. Phase E introduces
it as a building block; Phase F may wire it into context-view
filtering or per-fact invalidation. The structured report (Phase
E Task 3) uses it for an aggregate "stale count" line in the
"Source facts" summary.

Phase E of the context-management refactor
(docs/plans/2026-05-07-phase-e-structured-reporting.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Step + failure summarizer helpers

**Files:**
- Create: `src/report.lisp` (new file; just the helpers; the formatter lands in Task 3)
- Create: `tests/report-test.lisp` (new file)
- Modify: `cl-harness.asd` to register `cl-harness/tests/report-test`

### Step 2.1: Failing tests

Create `tests/report-test.lisp`:

```lisp
;;;; tests/report-test.lisp
;;;;
;;;; Phase E of the context-management refactor
;;;; (docs/context-management.md §10,
;;;; docs/plans/2026-05-07-phase-e-structured-reporting.md).
;;;; Covers per-step / per-failure summarizer helpers (Task 2)
;;;; and the FORMAT-DEVELOP-STATE-REPORT formatter (Task 3).

(defpackage #:cl-harness/tests/report-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/state
                #:make-develop-state
                #:develop-state-record-step-result
                #:develop-state-record-patch-record
                #:develop-state-record-failure
                #:develop-state-current-step-index)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-step-result)
  (:import-from #:cl-harness/src/planner
                #:plan-step)
  (:import-from #:cl-harness/src/patch-record
                #:make-patch-record)
  (:import-from #:cl-harness/src/failure-ledger
                #:make-failure-record)
  (:import-from #:cl-harness/src/report
                #:summarise-completed-step
                #:summarise-failure-record))

(in-package #:cl-harness/tests/report-test)

(defun %step (&key (index 0)
                (issue "Add greet.")
                (test-name "greet-returns-hello")
                (test-source "(rove:deftest greet-returns-hello (rove:ok t))"))
  (make-instance 'cl-harness/src/planner:plan-step
                 :index index
                 :issue issue
                 :test-name test-name
                 :test-source test-source))

(defun %step-result (&key (status :passed) (step-index 0)
                       (test-name "greet-returns-hello"))
  (make-instance 'develop-step-result
                 :step-index step-index
                 :test-name test-name
                 :run-config nil
                 :status status))

(deftest summarise-completed-step-renders-passed
  (let ((s (summarise-completed-step (%step-result))))
    (ok (search "step 0" s))
    (ok (search "greet-returns-hello" s))
    (ok (search "passed" s))))

(deftest summarise-completed-step-renders-give-up
  (let ((s (summarise-completed-step (%step-result :status :give-up))))
    (ok (search "give-up" s))))

(deftest summarise-failure-record-renders-test-name-and-description
  (let* ((f (make-failure-record :kind :test-failed
                                 :description "greet returns wrong value"
                                 :test-name "greet-returns-hello-name"
                                 :verify-source :incremental))
         (s (summarise-failure-record f)))
    (ok (search "greet-returns-hello-name" s))
    (ok (search "greet returns wrong value" s))))

(deftest summarise-failure-record-handles-nil-test-name
  ;; :load-failed has NIL test-name; the helper must not crash.
  (let* ((f (make-failure-record :kind :load-failed
                                 :description "package error"
                                 :verify-source :clean))
         (s (summarise-failure-record f)))
    (ok (search "load-failed" s))
    (ok (search "package error" s))))
```

### Step 2.2: Register the test system

cl-mcp `lisp-patch-form` on `cl-harness.asd`:
- `path`: `cl-harness.asd`
- `form_type`: `defsystem`
- `form_name`: `"cl-harness/tests"`
- `old_text`: `"cl-harness/tests/context-view-test")`
- `new_text`: `"cl-harness/tests/context-view-test"\n               "cl-harness/tests/report-test")`

(Verify exact `:depends-on` tail before patching; the implementer should read the .asd first.)

### Step 2.3: Red

cl-mcp `run-tests cl-harness/tests` — expect compilation failure on missing `cl-harness/src/report` package.

### Step 2.4: Create `src/report.lisp` (helpers only)

```lisp
;;;; src/report.lisp
;;;;
;;;; Phase E of the context-management refactor
;;;; (docs/context-management.md §10). Generates a structured
;;;; markdown report from a DEVELOP-STATE: the surface that
;;;; Phase A-D's recorded ledgers (source-facts, patch-records,
;;;; failure-ledger, step-results) finally render as user-facing
;;;; output.
;;;;
;;;; This file holds only the public formatter API and small
;;;; per-record summarizer helpers. CLI integration lives in
;;;; src/cli.lisp; this module is consumer-agnostic.

(defpackage #:cl-harness/src/report
  (:use #:cl)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-step-result-step-index
                #:develop-step-result-test-name
                #:develop-step-result-status)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-record-kind
                #:failure-record-description
                #:failure-record-test-name)
  (:export #:summarise-completed-step
           #:summarise-failure-record))

(in-package #:cl-harness/src/report)

(defun summarise-completed-step (result)
  "Return a one-line markdown summary of a DEVELOP-STEP-RESULT.
Format: 'step <N>: <test-name> (<status>)'."
  (format nil "step ~A: ~A (~(~A~))"
          (develop-step-result-step-index result)
          (or (develop-step-result-test-name result) "(no test name)")
          (develop-step-result-status result)))

(defun summarise-failure-record (failure)
  "Return a one-line markdown summary of a FAILURE-RECORD. The
test-name is included when non-NIL (e.g. :TEST-FAILED kind);
:LOAD-FAILED records use the kind keyword in its place. The
description is always emitted."
  (format nil "~A: ~A"
          (or (failure-record-test-name failure)
              (string-downcase (symbol-name (failure-record-kind failure))))
          (or (failure-record-description failure) "(no description)")))
```

### Step 2.5: Verify green

cl-mcp `lisp-check-parens` on `src/report.lisp`.
cl-mcp `load-system` clean.
cl-mcp `run-tests cl-harness/tests/report-test` — 4 deftests pass.
Full suite — 275/0 (was 271, +4).

### Step 2.6: Commit

```bash
git add src/report.lisp tests/report-test.lisp cl-harness.asd
git commit -m "$(cat <<'EOF'
feat: report module per-record summarizer helpers (Phase E.2)

Adds src/report.lisp with two summarizer helpers:
SUMMARISE-COMPLETED-STEP renders a one-line markdown summary of
a DEVELOP-STEP-RESULT; SUMMARISE-FAILURE-RECORD does the same
for a FAILURE-RECORD (handling NIL test-name on :LOAD-FAILED
records by falling back to the kind keyword).

These are the building blocks for FORMAT-DEVELOP-STATE-REPORT
(Task 3), which composes them into a comprehensive structured
report. Pure data-formatting; no side effects, no I/O.

Phase E of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `format-develop-state-report` structured formatter

**Files:**
- Modify: `src/report.lisp`
- Modify: `tests/report-test.lisp`

### Step 3.1: Failing tests

Append to `tests/report-test.lisp`:

```lisp
;; Update :import-from #:cl-harness/src/report to add the formatter:
;;   #:format-develop-state-report

(defun %report (state)
  (cl-harness/src/report:format-develop-state-report state))

(deftest format-develop-state-report-includes-goal
  (let ((s (make-develop-state :goal "implement greet"
                               :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests")))
    (let ((out (%report s)))
      (ok (search "# Goal" out))
      (ok (search "implement greet" out)))))

(deftest format-develop-state-report-renders-completed-steps
  (let ((s (make-develop-state :goal "g"
                               :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests")))
    (develop-state-record-step-result s (%step-result :step-index 0
                                                      :status :passed))
    (develop-state-record-step-result s (%step-result :step-index 1
                                                      :status :give-up))
    (let ((out (%report s)))
      (ok (search "## Completed steps" out))
      (ok (search "step 0" out))
      (ok (search "step 1" out)))))

(deftest format-develop-state-report-renders-patches
  (let ((s (make-develop-state :goal "g"
                               :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests")))
    (develop-state-record-patch-record
     s (make-patch-record :path "/tmp/x.lisp"
                          :via-tool "lisp-edit-form"
                          :form-name "greet"
                          :turn 1))
    (let ((out (%report s)))
      (ok (search "## Patches applied" out))
      (ok (search "x.lisp" out))
      (ok (search "lisp-edit-form" out)))))

(deftest format-develop-state-report-omits-empty-sections
  ;; A pristine state with no steps / patches / failures should
  ;; emit Goal + Plan, but skip the per-ledger sections.
  (let ((s (make-develop-state :goal "g"
                               :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests")))
    (let ((out (%report s)))
      (ok (search "# Goal" out))
      (ok (not (search "## Patches applied" out)))
      (ok (not (search "## Active failures" out)))
      (ok (not (search "## Resolved failures" out))))))

(deftest format-develop-state-report-renders-active-failures
  (let ((s (make-develop-state :goal "g"
                               :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests")))
    (develop-state-record-failure
     s (make-failure-record :kind :test-failed
                            :description "greet wrong"
                            :test-name "greet-returns-hello"
                            :verify-source :incremental))
    (let ((out (%report s)))
      (ok (search "## Active failures" out))
      (ok (search "greet-returns-hello" out)))))

(deftest format-develop-state-report-supports-stream-arg
  (let ((s (make-develop-state :goal "g"
                               :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests")))
    (let ((written
            (with-output-to-string (out)
              (cl-harness/src/report:format-develop-state-report
               s :stream out))))
      (ok (search "# Goal" written)))))
```

### Step 3.2: Red

cl-mcp `run-tests cl-harness/tests/report-test` — 6 new tests fail (formatter undefined).

### Step 3.3: Implement

Extend `src/report.lisp`'s defpackage to import the additional accessors and to export `format-develop-state-report`:

Add to `:import-from #:cl-harness/src/state`:
```
                #:develop-state
                #:develop-state-goal
                #:develop-state-current-plan
                #:develop-state-step-results
                #:develop-state-patch-records
                #:develop-state-failure-ledger
                #:develop-state-source-facts
                #:develop-state-integration-issues
```

Add `:import-from` clauses for:
- `#:cl-harness/src/planner` → `plan-step-test-name`, `plan-step-issue`
- `#:cl-harness/src/patch-record` → `patch-record-path`, `patch-record-via-tool`, `patch-record-form-name`, `patch-record-verify-status`
- `#:cl-harness/src/failure-ledger` → `failure-ledger-active`, `failure-ledger-resolved`, `failure-record-resolved-by-patch`
- `#:cl-harness/src/source-fact` → `source-fact-stale-p` (so the report can summarise stale count)

Add the formatter:

```lisp
(defun %render-section-header (stream title)
  (format stream "~%## ~A~%" title))

(defun %render-plan-section (stream state)
  (let ((plan (develop-state-current-plan state)))
    (when plan
      (%render-section-header stream "Plan")
      (loop for step in plan
            for i from 0
            do (format stream "~D. ~A — ~A~%"
                       i
                       (or (plan-step-test-name step) "(no test name)")
                       (or (plan-step-issue step) "(no issue text)"))))))

(defun %render-completed-steps-section (stream state)
  (let ((results (develop-state-step-results state)))
    (when results
      (%render-section-header stream "Completed steps")
      (dolist (r results)
        (format stream "- ~A~%" (summarise-completed-step r))))))

(defun %render-patches-section (stream state)
  (let ((patches (develop-state-patch-records state)))
    (when patches
      (%render-section-header stream "Patches applied")
      (dolist (p patches)
        (format stream "- ~A (~A~A) [~(~A~)]~%"
                (namestring (patch-record-path p))
                (patch-record-via-tool p)
                (if (patch-record-form-name p)
                    (format nil " on ~A" (patch-record-form-name p))
                    "")
                (patch-record-verify-status p))))))

(defun %render-failures-section (stream state header accessor)
  (let* ((ledger (develop-state-failure-ledger state))
         (failures (and ledger (funcall accessor ledger))))
    (when failures
      (%render-section-header stream header)
      (dolist (f failures)
        (format stream "- ~A~A~%"
                (summarise-failure-record f)
                (if (failure-record-resolved-by-patch f)
                    (format nil " (resolved by patch on ~A)"
                            (namestring (patch-record-path
                                         (failure-record-resolved-by-patch f))))
                    ""))))))

(defun %render-integration-issues-section (stream state)
  (let ((issues (develop-state-integration-issues state)))
    (when issues
      (%render-section-header stream "Integration issues")
      (format stream "~D issue~:P detected by static check.~%"
              (length issues)))))

(defun %render-source-facts-section (stream state)
  (let* ((facts (develop-state-source-facts state))
         (count (length facts))
         (stale-count (count-if #'source-fact-stale-p facts)))
    (when (plusp count)
      (%render-section-header stream "Source facts")
      (format stream "~D fact~:P recorded; ~D stale~:P detected.~%"
              count stale-count))))

(defun format-develop-state-report (state &key (stream nil))
  "Render STATE (a DEVELOP-STATE) as a structured markdown report.
When STREAM is NIL (default), return the report as a string. When
STREAM is non-NIL, write to STREAM and return (VALUES).

The report has the following sections (each emitted only when
its data is non-empty, except the Goal which is always present):
# Goal
## Plan
## Completed steps
## Patches applied
## Active failures
## Resolved failures
## Integration issues
## Source facts"
  (cond
    ((null stream)
     (with-output-to-string (s)
       (format-develop-state-report state :stream s)))
    (t
     (format stream "# Goal~%~A~%" (or (develop-state-goal state) ""))
     (%render-plan-section stream state)
     (%render-completed-steps-section stream state)
     (%render-patches-section stream state)
     (%render-failures-section stream state "Active failures"
                                #'failure-ledger-active)
     (%render-failures-section stream state "Resolved failures"
                                #'failure-ledger-resolved)
     (%render-integration-issues-section stream state)
     (%render-source-facts-section stream state)
     (values))))
```

Add `#:format-develop-state-report` to the `:export` list.

### Step 3.4: Verify green

cl-mcp `lisp-check-parens` clean.
cl-mcp `load-system` clean.
cl-mcp `run-tests cl-harness/tests/report-test` — 10 pass (4 prior + 6 new).
Full suite — 281/0 (was 275, +6).

### Step 3.5: Commit

```bash
git add src/report.lisp tests/report-test.lisp
git commit -m "$(cat <<'EOF'
feat: format-develop-state-report structured markdown formatter (Phase E.3)

Composes the per-record summarizers (Task 2) into a comprehensive
markdown report from a DEVELOP-STATE. Sections (each emitted only
when its data is non-empty, except Goal which is always present):
# Goal
## Plan (numbered list of plan-steps)
## Completed steps (one-line per develop-step-result)
## Patches applied (one-line per patch-record with verify-status)
## Active failures (from failure-ledger)
## Resolved failures (from failure-ledger; includes resolved-by-patch
   attribution when known)
## Integration issues (count when present)
## Source facts (count + stale count via SOURCE-FACT-STALE-P)

Supports two output modes: (FORMAT-DEVELOP-STATE-REPORT state)
returns a string; (FORMAT-DEVELOP-STATE-REPORT state :stream s)
writes to stream and returns (VALUES). Tests cover both modes,
empty-state section omission, and per-section substring presence.

Phase E of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire the structured report into the CLI's `develop` command

**Files:**
- Modify: `src/cli.lisp`
- Modify: `tests/agent-test.lisp` or wherever CLI tests live (probably none specific to report output — verify)

### Step 4.1: Survey

cl-mcp `lisp-read-file src/cli.lisp` `name_pattern="^format-develop-report$"` and the `develop` command's body. Identify:
- Where the existing `format-develop-report` call is.
- Whether the CLI accepts kwargs / clingon flags that could host an opt-in.

cl-mcp `clgrep-search` for `format-develop-report` in `src/cli.lisp` and `src/cli-main.lisp` to find all call sites.

### Step 4.2: Failing test

Skip if there are no existing CLI report tests (per the survey, there aren't). Adding new tests for the CLI integration is challenging because it requires constructing a `develop-result` with associated `develop-state` — feasible but verbose.

**Recommended approach**: skip end-to-end CLI tests for Phase E.1; the formatter tests (Task 3) cover the structured-report behavior directly. The CLI wiring is glue code; existing CLI tests covering `develop` (which still call the legacy `format-develop-report` path) will continue to pass, confirming the legacy path is unaffected.

If desired, add ONE smoke test that constructs a develop-state, threads it through `develop-result`, calls the new structured-report function, and asserts a substring. Defer if the test setup is cumbersome.

### Step 4.3: Implement

Phase E's CLI integration is intentionally thin: add a new function `format-develop-state-report` (already in `src/report.lisp`) and let the CLI optionally invoke it. The exact mechanism depends on the CLI's argument-parsing setup (clingon options).

Two designs:

**Option A: New CLI flag.** Add `--report=structured` to the `develop` command's clingon options. When set, the CLI calls `format-develop-state-report` from the develop-state stored on the develop-result.

But — the survey shows `develop-result` does NOT carry the develop-state directly; it carries derived slots (status, final-plan, etc.). To use Option A, the CLI would need access to the underlying `develop-state` instance.

**Option B: New separate function.** Add `format-develop-report-structured` in `src/cli.lisp` that, given a `develop-state`, calls `format-develop-state-report`. The orchestrator's `develop` function would need to either: return both `develop-result` AND `develop-state`, OR add a `develop-state` slot on `develop-result`.

Cleaner: add a `develop-state` slot on `develop-result`. This was deferred in Phase A's plan ("Phase B+ may want to expose develop-state on develop-result"); Phase E is the natural time.

**Recommended: Option B with a minimal develop-result extension.**

1. Add `develop-state` slot to `develop-result` in `src/orchestrator.lisp` (with `:initform nil` for backward compat; existing code that constructs `develop-result` without this slot continues to work; the orchestrator's `develop` function passes the state via `:develop-state state` to the constructor).

2. Add `develop-result-develop-state` reader.

3. In `src/cli.lisp`, add `format-develop-report-structured (result)` that pulls the state and formats.

4. Provide an opt-in path (e.g. environment variable or a kwarg on the CLI's `develop` invocation) so that users can request the structured report.

The exact CLI wiring is judgment-calls about UX. For Phase E MVP, ADD the structured report function but DO NOT switch the default. Document its existence; users can call it from the REPL or a future flag can flip the default.

### Step 4.4: Verify green

cl-mcp `load-system` clean.
cl-mcp `run-tests cl-harness/tests` — 281/0 (no test-count change; orchestrator-test should continue passing with the new `:develop-state` slot since it's `:initform nil`).

If a new orchestrator-test deftest is added to verify the slot is populated, the count goes up by 1.

### Step 4.5: Commit

```bash
git add src/orchestrator.lisp src/cli.lisp tests/orchestrator-test.lisp
git commit -m "$(cat <<'EOF'
feat: expose develop-state on develop-result + CLI structured-report wrapper (Phase E.4)

DEVELOP-RESULT gains an optional :develop-state slot
(initform NIL, public reader DEVELOP-RESULT-DEVELOP-STATE).
Existing constructors that don't pass :develop-state continue
to work unchanged; the orchestrator's DEVELOP function now
passes the in-memory state for downstream consumers.

CLI gains FORMAT-DEVELOP-REPORT-STRUCTURED (in src/cli.lisp)
that takes a DEVELOP-RESULT, pulls the develop-state, and
delegates to FORMAT-DEVELOP-STATE-REPORT (Task 3). The function
is exposed but the CLI's default report path is UNCHANGED;
users can invoke the structured report from the REPL or via a
future flag flip.

Phase E of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Lint + force-compile + regression sweep

Mirrors Phase A/B/C/D Task 9.

### Steps

1. `mallet src/source-fact.lisp src/report.lisp src/orchestrator.lisp src/cli.lisp tests/source-fact-test.lisp tests/report-test.lisp tests/orchestrator-test.lisp` — fix any new warnings on Phase E files. Use Option A (no worktree) per the Phase C/D lesson, OR place worktree OUTSIDE `~/.roswell/local-projects/`.

2. `(asdf:compile-system :cl-harness :force t)` via cl-mcp `repl-eval` — clean.

3. cl-mcp `run-tests` `{"system": "cl-harness/tests"}` — confirm pre-existing pass count + new Phase E tests, all passing.

4. Shell `rove cl-harness.asd` — same pre-existing 5-failure set in `develop-bench-test`, no new failures.

5. Commit only if mallet required fixes.

---

## Task 6: Docs annotation + final review + merge

### Step 6.1: Update `docs/context-management.md` §14

Mark Phase E landed; cross-reference §10 (Reporting) as addressed; §9 (Staleness) as foundation laid.

```markdown
| E | 構造化レポート (`format-develop-state-report`) + `source-fact-stale-p` 述語 | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-e-structured-reporting.md` |
```

Update the trailing paragraph to note that §10 (Reporting) is now addressed for orchestrator-driven runs (`develop`); `cl-harness:fix` retains its agent-loop reporter. §9 (Staleness) has the predicate but no consumer integration; Phase F can wire it into context-view filtering. §6.4 / §6.5 remain partially covered (resolved-failures section in the report; completed-subtask narrative is per-step one-liners). §3.3 / §3.4 / §3.6 remain for Phase B' or follow-up.

### Step 6.2: Final code review

`superpowers:code-reviewer` over the entire `phase-e-reporting` branch. Checklist:
- `source-fact-stale-p` is a pure predicate; no side effects beyond `file-write-date` syscall.
- `format-develop-state-report` produces the documented sections and respects empty-state omission.
- `develop-result` slot addition is backward-compatible.
- CLI default behavior unchanged.
- mallet clean, force-compile clean.
- No `:local-nicknames`.
- Test counts: source-fact-test +4, report-test 10, orchestrator-test +0-1.

### Step 6.3: Merge to main

`superpowers:finishing-a-development-branch`, `--no-ff` merge with summary message highlighting:
- The new `format-develop-state-report` formatter and its sections.
- The `source-fact-stale-p` predicate as a building block.
- The `develop-result.develop-state` slot extension.
- The CLI wrapper (`format-develop-report-structured`) as opt-in.
- Phase E completes the multi-phase context-management refactor; outstanding items go to Phase F or separate plans.

---

## Verification checklist (before opening a PR)

- [ ] `src/source-fact.lisp` exports `source-fact-stale-p`
- [ ] `src/report.lisp` exists with documented exports
- [ ] `tests/report-test.lisp` covers helpers + formatter
- [ ] `cl-harness.asd` registers `cl-harness/tests/report-test`
- [ ] `develop-result` has optional `:develop-state` slot
- [ ] CLI wrapper `format-develop-report-structured` exists
- [ ] Default CLI behavior is unchanged
- [ ] mallet clean on Phase E files
- [ ] `(asdf:compile-system :cl-harness :force t)` clean
- [ ] Full `cl-harness/tests` rove suite green
- [ ] `docs/context-management.md` §14 updated

## Rollback plan

If anything surfaces a regression:

1. Tasks 1-3 are pure additions (new file, new predicate). Safe to keep regardless.
2. Task 4 is the only task that touches existing files (`src/orchestrator.lisp` for the slot, `src/cli.lisp` for the wrapper). If the slot addition breaks existing develop-result consumers, `git revert` Task 4 leaves Tasks 1-3 in place — the foundation stands, the CLI integration just gets deferred.

The split between data/foundation tasks (1-3) and integration task (4) keeps the rollback boundary clean.

## Beyond Phase E

After Phase E lands, the multi-phase context-management refactor is complete for the originally-scoped work. Outstanding items for separate future plans:

- **Phase B' (runtime-vocabulary)**: structured packages / exports / classes / generic functions ledger; foundation for §9 staleness on runtime state. Survey from earlier phases recommended a `repl-eval`-driven introspection approach.
- **Phase F (staleness consumption)**: wire `source-fact-stale-p` into `make-context-view` so views filter or annotate stale facts; once runtime-vocabulary lands, mirror the same pattern there.
- **Phase G (orchestrator → planner-fn full wiring)**: thread `:develop-state` into `funcall planner-fn` calls (per the FIXME comments in `src/orchestrator.lisp`). Validate ordering changes against a real model before flipping production.
- **Replacing `format-final-report`**: replace agent-loop reporter for `cl-harness:fix` with a state-derived equivalent; today it reads `agent-state` counters directly.

These are deferable; Phase E ships the orchestrator-side reporting and the staleness predicate, which are the highest-value items.
