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
