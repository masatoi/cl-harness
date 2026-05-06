;;;; tests/patch-record-test.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.8, docs/plans/2026-05-07-phase-b-source-patch-failure.md).
;;;; Covers PATCH-RECORD construction, defaults, validation, and
;;;; the verify-status state machine.

(defpackage #:cl-harness/tests/patch-record-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record
                #:make-patch-record
                #:patch-record-path
                #:patch-record-form-type
                #:patch-record-form-name
                #:patch-record-via-tool
                #:patch-record-operation
                #:patch-record-diff-summary
                #:patch-record-applied-at
                #:patch-record-related-step-index
                #:patch-record-turn
                #:patch-record-verify-status
                #:patch-record-verify-source
                #:patch-record-set-verify-status))

(in-package #:cl-harness/tests/patch-record-test)

(defun %make (&rest overrides)
  (apply #'make-patch-record
         :path #P"/tmp/demo/src/greet.lisp"
         :via-tool "lisp-edit-form"
         :turn 5
         overrides))

(deftest make-patch-record-accepts-required-args
  (let ((p (%make)))
    (ok (typep p 'patch-record))
    (ok (equal #P"/tmp/demo/src/greet.lisp" (patch-record-path p)))
    (ok (string= "lisp-edit-form" (patch-record-via-tool p)))
    (ok (= 5 (patch-record-turn p)))))

(deftest make-patch-record-defaults
  (let ((p (%make)))
    (ok (null (patch-record-form-type p)))
    (ok (null (patch-record-form-name p)))
    (ok (null (patch-record-operation p)))
    (ok (or (null (patch-record-diff-summary p))
            (stringp (patch-record-diff-summary p))))
    (ok (null (patch-record-related-step-index p)))
    (ok (eq :pending (patch-record-verify-status p)))
    (ok (null (patch-record-verify-source p)))
    (ok (numberp (patch-record-applied-at p)))))

(deftest make-patch-record-with-full-detail
  (let ((p (%make :form-type "defun"
                  :form-name "greet"
                  :operation "replace"
                  :diff-summary "+1/-1"
                  :related-step-index 0)))
    (ok (string= "defun" (patch-record-form-type p)))
    (ok (string= "greet" (patch-record-form-name p)))
    (ok (string= "replace" (patch-record-operation p)))
    (ok (string= "+1/-1" (patch-record-diff-summary p)))
    (ok (= 0 (patch-record-related-step-index p)))))

(deftest make-patch-record-rejects-bad-via-tool
  (ok (handler-case
          (progn (make-patch-record :path #P"/tmp/x.lisp"
                                    :via-tool ""
                                    :turn 1)
                 nil)
        (error () t))))

(deftest patch-record-set-verify-status-pending-to-passed
  (let ((p (%make)))
    (patch-record-set-verify-status p :passed :incremental)
    (ok (eq :passed (patch-record-verify-status p)))
    (ok (eq :incremental (patch-record-verify-source p)))))

(deftest patch-record-set-verify-status-rejects-bad-status
  (let ((p (%make)))
    (ok (handler-case
            (progn (patch-record-set-verify-status p :bogus :incremental)
                   nil)
          (error () t)))
    (ok (eq :pending (patch-record-verify-status p)))))

(deftest patch-record-set-verify-status-rejects-bad-source
  (let ((p (%make)))
    (ok (handler-case
            (progn (patch-record-set-verify-status p :passed :elsewhere)
                   nil)
          (error () t)))
    (ok (eq :pending (patch-record-verify-status p)))
    (ok (null (patch-record-verify-source p)))))

(deftest patch-record-set-verify-status-allows-clean-overrides-incremental
  ;; A clean verify after an incremental verify is the authoritative
  ;; truth; the helper accepts the transition.
  (let ((p (%make)))
    (patch-record-set-verify-status p :passed :incremental)
    (patch-record-set-verify-status p :failed :clean)
    (ok (eq :failed (patch-record-verify-status p)))
    (ok (eq :clean (patch-record-verify-source p)))))
