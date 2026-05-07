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
  (let ((state (cl-harness/src/state:make-develop-state
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
  ;; make-abstraction-decision signature: (kind name &key rationale step-index)
  ;; -- kind and name are positional, NOT keyword args.
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

(deftest summarise-step-result-filters-patches-by-step-index
  ;; A patch on a different step (related-step-index 99) must NOT
  ;; appear in this step's what-changed list.
  (let ((state (cl-harness/src/state:make-develop-state
                :goal "g" :project-root "/tmp/p"
                :system "x" :test-system "x/tests"))
        (step-result (make-instance
                      'cl-harness/src/orchestrator:develop-step-result
                      :step-index 0
                      :test-name "first-test"
                      :run-config nil
                      :status :passed))
        (other-patch (cl-harness/src/patch-record:make-patch-record
                      :path "src/other.lisp" :via-tool "lisp-edit-form"
                      :form-type "defun" :form-name "elsewhere"
                      :related-step-index 99 :turn 1)))
    (cl-harness/src/state:develop-state-record-step-result state step-result)
    (cl-harness/src/state:develop-state-record-patch-record state other-patch)
    (let ((sum (summarise-step-result step-result state)))
      ;; what-changed must be empty (no patches on step 0).
      (ok (null (subtask-summary-what-changed sum))))))
