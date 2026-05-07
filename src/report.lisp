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
  (:import-from #:cl-harness/src/state
                #:develop-state
                #:develop-state-goal
                #:develop-state-current-plan
                #:develop-state-step-results
                #:develop-state-patch-records
                #:develop-state-failure-ledger
                #:develop-state-source-facts
                #:develop-state-integration-issues)
  (:import-from #:cl-harness/src/planner
                #:plan-step-test-name
                #:plan-step-issue)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-path
                #:patch-record-via-tool
                #:patch-record-form-name
                #:patch-record-verify-status)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-record-kind
                #:failure-record-description
                #:failure-record-test-name
                #:failure-ledger-active
                #:failure-ledger-resolved
                #:failure-record-resolved-by-patch)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact-stale-p)
  (:export #:summarise-completed-step
           #:summarise-failure-record
           #:format-develop-state-report))

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
