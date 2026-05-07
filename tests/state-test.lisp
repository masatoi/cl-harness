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
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger-active)
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
                #:develop-state-current-step-index
                #:develop-state-step-results
                #:develop-state-replan-count
                #:develop-state-last-failure-test-name
                #:develop-state-status
                #:develop-state-limit-hit
                #:develop-state-integration-issues
                #:develop-state-record-step-result
                #:develop-state-source-facts
                #:develop-state-record-source-fact
                #:develop-state-patch-records
                #:develop-state-record-patch-record
                #:develop-state-failure-ledger
                #:develop-state-record-failure
                #:develop-state-runtime-vocabulary
                #:develop-state-record-runtime-vocab-fact
                #:develop-state-repl-findings
                #:develop-state-record-repl-finding
                #:develop-state-project-summary
                #:develop-state-set-project-summary
                #:develop-state-mark-project-summary-dirty)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:make-runtime-vocab-fact
                #:runtime-vocab-fact-name)
  (:import-from #:cl-harness/src/repl-finding
                #:make-repl-finding
                #:repl-finding-hypothesis)
  (:import-from #:cl-harness/src/project-summary
                #:make-project-summary
                #:project-summary-dirty-p))

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
    (ok (string= "/tmp/cl-harness-state-test/" (develop-state-project-root s)))
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

(deftest develop-state-source-facts-default-empty
  (let ((s (%make)))
    (ok (null (develop-state-source-facts s)))))

(deftest develop-state-record-source-fact-preserves-order
  (let ((s (%make)))
    (develop-state-record-source-fact s :first-fact)
    (develop-state-record-source-fact s :second-fact)
    (develop-state-record-source-fact s :third-fact)
    (ok (equal '(:first-fact :second-fact :third-fact)
               (develop-state-source-facts s)))))

(deftest develop-state-patch-records-default-empty
  (let ((s (%make)))
    (ok (null (develop-state-patch-records s)))))

(deftest develop-state-record-patch-record-preserves-order
  (let ((s (%make)))
    (develop-state-record-patch-record s :first-patch)
    (develop-state-record-patch-record s :second-patch)
    (ok (equal '(:first-patch :second-patch)
               (develop-state-patch-records s)))))

(deftest develop-state-failure-ledger-is-auto-initialized
  ;; Unlike source-facts and patch-records (lists),
  ;; failure-ledger is an object that develop-state owns from
  ;; construction. We expect a non-NIL ledger right out of the box.
  (let ((s (%make)))
    (ok (not (null (develop-state-failure-ledger s))))))

(deftest develop-state-failure-ledger-is-per-instance
  ;; Each develop-state must get its own ledger; an :initform
  ;; expression evaluated at class-init time would share one
  ;; ledger between every instance. Verify two states have
  ;; non-eq ledgers.
  (let ((s1 (%make))
        (s2 (%make)))
    (ok (not (eq (develop-state-failure-ledger s1)
                 (develop-state-failure-ledger s2))))))

(deftest develop-state-record-failure-routes-to-ledger
  (let* ((s (%make))
         (l (develop-state-failure-ledger s)))
    (develop-state-record-failure s :a-failure-record)
    (ok (equal '(:a-failure-record) (failure-ledger-active l)))))

(deftest develop-state-current-step-index-defaults-to-nil
  (let ((s (%make)))
    (ok (null (develop-state-current-step-index s)))))

(deftest develop-state-current-step-index-is-writable
  (let ((s (%make)))
    (setf (develop-state-current-step-index s) 3)
    (ok (= 3 (develop-state-current-step-index s)))
    (setf (develop-state-current-step-index s) nil)
    (ok (null (develop-state-current-step-index s)))))

(deftest develop-state-records-runtime-vocab-facts-in-order
  (let ((s (%make))
        (f1 (make-runtime-vocab-fact
             :kind :function :name "f1" :via-tool "code-describe"))
        (f2 (make-runtime-vocab-fact
             :kind :function :name "f2" :via-tool "code-describe")))
    (develop-state-record-runtime-vocab-fact s f1)
    (develop-state-record-runtime-vocab-fact s f2)
    (let ((facts (develop-state-runtime-vocabulary s)))
      (ok (= 2 (length facts)))
      (ok (string= "f1" (runtime-vocab-fact-name (first facts))))
      (ok (string= "f2" (runtime-vocab-fact-name (second facts)))))))

(deftest develop-state-runtime-vocabulary-defaults-to-empty
  (let ((s (%make)))
    (ok (null (develop-state-runtime-vocabulary s)))))

(deftest develop-state-records-repl-findings-in-order
  (let ((s (%make))
        (f1 (make-repl-finding
             :hypothesis "h1" :probe "p1" :finding "fnd1" :decision "d1"))
        (f2 (make-repl-finding
             :hypothesis "h2" :probe "p2" :finding "fnd2" :decision "d2")))
    (develop-state-record-repl-finding s f1)
    (develop-state-record-repl-finding s f2)
    (let ((findings (develop-state-repl-findings s)))
      (ok (= 2 (length findings)))
      (ok (string= "h1" (repl-finding-hypothesis (first findings))))
      (ok (string= "h2" (repl-finding-hypothesis (second findings)))))))

(deftest develop-state-repl-findings-defaults-to-empty
  (let ((s (%make)))
    (ok (null (develop-state-repl-findings s)))))

(deftest develop-state-stores-and-flips-project-summary-dirty
  (let ((s (%make))
        (sum (make-project-summary
              :project-root "/tmp/p/" :system "x" :test-system "x/tests")))
    (develop-state-set-project-summary s sum)
    (ok (eq sum (develop-state-project-summary s)))
    (ok (null (project-summary-dirty-p sum)))
    (develop-state-mark-project-summary-dirty s)
    (ok (eq t (project-summary-dirty-p sum)))))

(deftest develop-state-mark-project-summary-dirty-handles-nil-slot
  ;; If the slot is NIL (caller never gathered a summary) the helper
  ;; is a no-op rather than raising.
  (let ((s (%make)))
    (develop-state-mark-project-summary-dirty s)
    (ok (null (develop-state-project-summary s)))))
