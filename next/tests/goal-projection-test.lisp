;;;; next/tests/goal-projection-test.lisp
;;;;
;;;; Unit tests for next/src/goal-projection.lisp (§3.1 goal context,
;;;; §3.7 design decisions).

(defpackage #:cl-harness-next/tests/goal-projection-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-projection
                #:goal-text
                #:acceptance-criteria
                #:non-goals
                #:decisions
                #:decision-text
                #:decision-rationale
                #:decision-seq))

(in-package #:cl-harness-next/tests/goal-projection-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %feed (projection type seq &rest plist)
  (apply-event projection
               (make-harness-event type (when plist (apply #'%hash plist))
                                   :seq seq)))

(deftest run-start-populates-goal
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :run-start 1
           "goal" "Fix the failing test"
           "acceptance_criteria" (list "tests pass" "no warnings")
           "non_goals" (list "refactor"))
    (ok (equal "Fix the failing test" (goal-text projection)))
    (ok (equal '("tests pass" "no warnings")
               (acceptance-criteria projection)))
    (ok (equal '("refactor") (non-goals projection)))))

(deftest decision-events-accumulate
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :decision 3
           "kind" "decision" "text" "use a class" "rationale" "two impls")
    (%feed projection :decision 7
           "kind" "decision" "text" "no macro")
    (let ((decisions (decisions projection)))
      (ok (= 2 (length decisions)))
      ;; Newest first.
      (ok (equal "no macro" (decision-text (first decisions))))
      (ok (= 7 (decision-seq (first decisions))))
      (ok (equal "two impls" (decision-rationale (second decisions)))))))

(deftest non-decision-kinds-are-ignored
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :decision 1 "kind" "finding" "hypothesis" "h"
           "probe" "p" "finding" "f" "decision" "d")
    (ok (null (decisions projection)))))

(deftest malformed-payloads-are-ignored
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :run-start 1)
    (%feed projection :note 2 "goal" "not a run-start")
    (ok (null (goal-text projection)))
    (ok (null (decisions projection)))))
