;;;; tests/explore-test.lisp

(defpackage #:cl-harness/tests/explore-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/action
                #:agent-action)
  (:import-from #:cl-harness/src/repl-finding
                #:repl-finding
                #:repl-finding-hypothesis
                #:repl-finding-probe
                #:repl-finding-finding
                #:repl-finding-decision
                #:repl-finding-related-step-index)
  (:import-from #:cl-harness/src/state
                #:make-develop-state
                #:develop-state-repl-findings))

(in-package #:cl-harness/tests/explore-test)

(defun %make-finding-action ()
  "Build an :FINDING AGENT-ACTION with non-empty sub-fields."
  (make-instance 'agent-action
                 :type :finding
                 :hypothesis "aggregation as pure function suffices"
                 :probe "(reduce #'+ '(1 2 3)) -> 6"
                 :finding "pure function works for current scope"
                 :decision "promote ordinary function, not macro"))

(defun %make-state ()
  (make-develop-state
   :goal "phase-h test"
   :project-root #P"/tmp/cl-harness-explore-test/"
   :system "demo"
   :test-system "demo/tests"))

(deftest record-finding-from-action-persists-on-develop-state
  (let ((action (%make-finding-action))
        (state (%make-state)))
    (cl-harness/src/explore::%record-finding-from-action action state nil)
    (let ((findings (develop-state-repl-findings state)))
      (ok (= 1 (length findings)))
      (let ((f (first findings)))
        (ok (typep f 'repl-finding))
        (ok (string= "aggregation as pure function suffices"
                     (repl-finding-hypothesis f)))
        (ok (string= "(reduce #'+ '(1 2 3)) -> 6"
                     (repl-finding-probe f)))
        (ok (string= "pure function works for current scope"
                     (repl-finding-finding f)))
        (ok (string= "promote ordinary function, not macro"
                     (repl-finding-decision f)))))))

(deftest record-finding-from-action-returns-finding
  (let* ((action (%make-finding-action))
         (state (%make-state))
         (returned (cl-harness/src/explore::%record-finding-from-action
                    action state nil)))
    (ok (typep returned 'repl-finding))
    (ok (eq returned (first (develop-state-repl-findings state))))))

(deftest record-finding-from-action-tolerates-nil-state
  ;; When DEVELOP-STATE is NIL (standalone callers), the helper returns
  ;; NIL and signals nothing. The action is still well-formed.
  (let ((action (%make-finding-action)))
    (ok (null (cl-harness/src/explore::%record-finding-from-action
               action nil nil)))))

(deftest record-finding-from-action-threads-step-index-from-plan-step
  (let* ((state (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
         (step (make-instance 'cl-harness/src/planner:plan-step
                              :index 7
                              :test-name "t"
                              :test-source "(deftest t)"
                              :issue "explore"))
         (action (make-instance 'cl-harness/src/action:agent-action
                                :type :finding
                                :hypothesis "h"
                                :probe "p"
                                :finding "f"
                                :decision "d"))
         (finding (cl-harness/src/explore::%record-finding-from-action
                   action state step)))
    (ok (eql 7 (repl-finding-related-step-index finding)))
    (ok (eql 7 (repl-finding-related-step-index
                (first (develop-state-repl-findings state)))))))
