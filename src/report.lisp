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
