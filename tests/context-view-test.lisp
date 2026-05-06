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
