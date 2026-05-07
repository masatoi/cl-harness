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
                #:summarise-failure-record
                #:format-develop-state-report))

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
  ;; emit Goal, but skip the per-ledger sections.
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
