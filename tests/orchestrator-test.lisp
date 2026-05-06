;;;; tests/orchestrator-test.lisp
;;;;
;;;; Phase P2 unit tests for src/orchestrator.lisp
;;;; (docs/notes/2026-05-06-planner-orchestrator.md). Covers the
;;;; helpers (test-source validator, materializer, plan-step ->
;;;; run-config builder) plus the full EXECUTE-PLAN loop with an
;;;; injected stub for run-agent.

(defpackage #:cl-harness/tests/orchestrator-test
  (:use #:cl #:rove)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/config
                #:run-config
                #:run-config-system
                #:run-config-test-system
                #:run-config-issue
                #:run-config-condition)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:planner-error
                #:planner-error-message)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-step-result-status
                #:develop-step-result-step-index
                #:develop-step-result-explore-result
                #:develop-result
                #:develop-result-status
                #:develop-result-step-results
                #:develop-result-replan-count
                #:develop-result-limit-hit
                #:validate-test-source
                #:materialize-test-source
                #:plan-step->run-config
                #:execute-plan
                #:develop))

(in-package #:cl-harness/tests/orchestrator-test)

(defun %tmp-path (name)
  (merge-pathnames (format nil "cl-harness-orch-test-~A-~A"
                           name (get-universal-time))
                   (uiop:temporary-directory)))

(defun %make-step (&key (index 0)
                        (issue "Add a foo function.")
                        (test-name "foo-returns-bar")
                        (test-source "(deftest foo-returns-bar (ok t))")
                        (files-to-modify nil))
  (make-instance 'plan-step
                 :index index
                 :issue issue
                 :test-name test-name
                 :test-source test-source
                 :files-to-modify files-to-modify))

;; --- validate-test-source -----------------------------------------------

(deftest validate-test-source-accepts-deftest
  (validate-test-source "(deftest foo (ok t))" 0)
  (ok t "deftest source passed validation"))

(deftest validate-test-source-rejects-defun-shape
  ;; The Qwen-smoke finding that motivated this validator: model
  ;; emits (defun test-foo ()) instead of (deftest foo ...). Reject.
  (ok (handler-case
          (progn (validate-test-source
                  "(defun test-foo () (assert t))" 0)
                 nil)
        (planner-error (c)
          (and (search "deftest" (planner-error-message c)) t)))))

(deftest validate-test-source-rejects-non-string
  (ok (handler-case
          (progn (validate-test-source "" 0) nil)
        (planner-error () t))))

;; --- materialize-test-source --------------------------------------------

(deftest materialize-test-source-appends-form-with-leading-newline
  (let ((path (%tmp-path "materialize-fresh")))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
             (format out "(in-package #:demo/tests/main-test)~%"))
           (materialize-test-source path "(deftest hello (ok t))")
           (let ((contents (uiop:read-file-string path)))
             (ok (search "(in-package #:demo/tests/main-test)" contents))
             (ok (search "(deftest hello (ok t))" contents))
             (let ((pkg-pos (search "(in-package" contents))
                   (test-pos (search "(deftest hello" contents)))
               (ok (< pkg-pos test-pos)
                   "the appended deftest comes after the existing in-package form"))))
      (when (probe-file path) (delete-file path)))))

(deftest materialize-test-source-creates-file-when-missing
  ;; materialize must work even when the test file does not exist
  ;; yet (greenfield scenario where the planner is the first thing
  ;; that writes a deftest).
  (let ((path (%tmp-path "materialize-missing")))
    (unwind-protect
         (progn
           (when (probe-file path) (delete-file path))
           (materialize-test-source path "(deftest g1 (ok t))")
           (ok (probe-file path) "file got created")
           (ok (search "(deftest g1" (uiop:read-file-string path))))
      (when (probe-file path) (delete-file path)))))

;; --- plan-step->run-config -----------------------------------------------

(deftest plan-step->run-config-fills-template-with-issue
  (let* ((step (%make-step :issue "Implement foo."))
         (rc (plan-step->run-config
              step
              :project-root "/tmp/proj"
              :system "demo"
              :test-system "demo/tests"
              :condition :generic-mcp)))
    (ok (typep rc 'run-config))
    (ok (equal "demo" (run-config-system rc)))
    (ok (equal "demo/tests" (run-config-test-system rc)))
    (ok (equal "Implement foo." (run-config-issue rc)))
    (ok (eq :generic-mcp (run-config-condition rc)))))

;; --- execute-plan --------------------------------------------------------

(defun %make-test-file (path)
  "Write a minimal package-inferred-system test file at PATH so each
step's deftest can append legally."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (format out "(defpackage #:demo/tests/main-test (:use #:cl #:rove))~%")
    (format out "(in-package #:demo/tests/main-test)~%")))

(defun %fake-runner (calls outcomes)
  "Build a function that records each call and returns successive
outcomes from the OUTCOMES list. Each outcome should be a status
keyword (:passed / :give-up / :limit-exhausted / etc.); the returned
hash carries that status so the orchestrator can read it via
gethash and stop on non-:passed."
  (lambda (config provider mcp-client policy logger
           &key clean-verify-p dry-run-p before-clean-verify-fn
                isolate-asdf-p develop-state
           &allow-other-keys)
    (declare (ignore provider mcp-client policy logger
                     clean-verify-p dry-run-p
                     before-clean-verify-fn isolate-asdf-p
                     develop-state))
    (push (run-config-issue config) (car calls))
    (let ((status (or (pop (car outcomes)) :passed)))
      (alist-hash-table
       `(("status" . ,status)
         ("turn" . 1)
         ("token-total" . 100))
       :test 'equal))))

(defun %fake-explorer (memos &optional log)
  "Build an explore-fn that hands out canned memos in order. LOG, when
supplied, is a cons-cell whose CAR is appended with each call so a
test can verify the explorer was invoked with the right plan-step."
  (lambda (config provider mcp-client policy logger
           &key max-turns plan-step)
    (declare (ignore config provider mcp-client policy logger max-turns))
    (when log (push plan-step (car log)))
    (let ((memo (or (pop (car memos))
                    "memo: investigated nothing in particular.")))
      (make-instance
       'cl-harness/src/explore:explore-result
       :status :reported
       :memo memo
       :turns 1
       :token-total 50))))

(deftest execute-plan-runs-each-step-in-order
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-log"))
         (steps (list (%make-step :index 0 :issue "First."
                                  :test-name "first-test")
                      (%make-step :index 1 :issue "Second."
                                  :test-name "second-test")
                      (%make-step :index 2 :issue "Third."
                                  :test-name "third-test")))
         (call-log (cons '() nil))
         (outcomes (cons (list :passed :passed :passed) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((results (execute-plan
                           steps
                           :project-root (namestring project-root)
                           :system "demo"
                           :test-system "demo/tests"
                           :test-file test-file
                           :log-path log-path
                           :run-fn runner)))
             (ok (= 3 (length results)))
             (ok (every (lambda (r) (eq :passed (develop-step-result-status r)))
                        results))
             (ok (equal '(0 1 2) (mapcar #'develop-step-result-step-index results)))
             (ok (equal '("First." "Second." "Third.")
                        (reverse (car call-log)))
                 "runner saw the three issues in plan order")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest execute-plan-stops-on-first-failure
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-log-fail"))
         (steps (list (%make-step :index 0 :issue "Step A."
                                  :test-name "a-test")
                      (%make-step :index 1 :issue "Step B."
                                  :test-name "b-test")
                      (%make-step :index 2 :issue "Step C."
                                  :test-name "c-test")))
         (call-log (cons '() nil))
         (outcomes (cons (list :passed :give-up :passed) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((results (execute-plan
                           steps
                           :project-root (namestring project-root)
                           :system "demo"
                           :test-system "demo/tests"
                           :test-file test-file
                           :log-path log-path
                           :run-fn runner)))
             (ok (= 2 (length results))
                 "stopped after step 1's :give-up, never invoked step 2")
             (ok (eq :passed (develop-step-result-status (first results))))
             (ok (eq :give-up (develop-step-result-status (second results))))
             (ok (= 2 (length (car call-log)))
                 "run-fn was called exactly twice")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest execute-plan-emits-develop-level-jsonl-events
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-jsonl"))
         (steps (list (%make-step :index 0)
                      (%make-step :index 1)))
         (call-log (cons '() nil))
         (outcomes (cons (list :passed :passed) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (execute-plan
            steps
            :project-root (namestring project-root)
            :system "demo"
            :test-system "demo/tests"
            :test-file test-file
            :log-path log-path
            :run-fn runner)
           (let ((events
                  (with-open-file (in log-path :direction :input)
                    (loop for line = (read-line in nil nil)
                          while line collect (yason:parse line)))))
             (let ((types (mapcar (lambda (e) (gethash "type" e)) events)))
               (ok (search '("develop-start" "plan" "step-start" "step-end"
                             "step-start" "step-end" "develop-end")
                           types :test #'equal)
                   "emitted ordered develop-start, plan, per-step pairs, develop-end"))
             (let ((develop-end
                    (find-if (lambda (e)
                               (equal "develop-end" (gethash "type" e)))
                             events)))
               (ok develop-end "develop-end event present")
               (when develop-end
                 (ok (equal "passed" (gethash "status" develop-end)))))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest execute-plan-validates-test-source-before-run
  ;; If a plan step's test_source isn't a (deftest ...) form, the
  ;; orchestrator must reject the whole plan before any run-fn call.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-log-bad"))
         (steps (list (%make-step :index 0)
                      (%make-step :index 1
                                  :test-source "(defun test-not-deftest ())")))
         (call-log (cons '() nil))
         (outcomes (cons '() nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (ok (handler-case
                   (progn (execute-plan
                           steps
                           :project-root (namestring project-root)
                           :system "demo"
                           :test-system "demo/tests"
                           :test-file test-file
                           :log-path log-path
                           :run-fn runner)
                          nil)
                 (planner-error (c)
                   (and (search "deftest" (planner-error-message c)) t))))
           (ok (zerop (length (car call-log)))
               "run-fn must not be called when plan validation fails"))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

;; --- develop (P3) -------------------------------------------------------

(defun %canned-planner (plans)
  "Return a planner-fn that hands out PLANS in order. Each plan is a
list of PLAN-STEP. Calls past the end of the list reuse the last
plan (so a stuck loop test can keep getting the same response)."
  (let ((remaining plans))
    (lambda (goal &key project-root system test-system provider
                       prior-plan failure-context system-prompt
                       project-inventory mode)
      (declare (ignore goal project-root system test-system provider
                       prior-plan failure-context system-prompt
                       project-inventory mode))
      (cond
        ((null remaining)
         (error "canned-planner exhausted"))
        ((null (cdr remaining))
         (car remaining))
        (t (pop remaining))))))

(deftest develop-passes-on-first-attempt-when-plan-passes
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-p3-pass"))
         (plan-1 (list (%make-step :index 0 :test-name "alpha")))
         (planner-fn (%canned-planner (list plan-1)))
         (call-log (cons '() nil))
         (outcomes (cons (list :passed) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result (develop "ship feature X"
                                  :project-root (namestring project-root)
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :test-file test-file
                                  :log-path log-path
                                  :planner-fn planner-fn
                                  :run-fn runner)))
             (ok (typep result 'develop-result))
             (ok (eq :passed (develop-result-status result)))
             (ok (zerop (develop-result-replan-count result)))
             (ok (null (develop-result-limit-hit result)))
             (ok (= 1 (length (develop-result-step-results result))))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest develop-replans-once-and-recovers
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-p3-replan"))
         (plan-1 (list (%make-step :index 0 :test-name "alpha"
                                   :test-source "(deftest alpha (ok t))")))
         (plan-2 (list (%make-step :index 0 :test-name "beta"
                                   :test-source "(deftest beta (ok t))")))
         (planner-fn (%canned-planner (list plan-1 plan-2)))
         (call-log (cons '() nil))
         (outcomes (cons (list :give-up :passed) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result (develop "do the thing"
                                  :project-root (namestring project-root)
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :test-file test-file
                                  :log-path log-path
                                  :planner-fn planner-fn
                                  :run-fn runner)))
             (ok (eq :passed (develop-result-status result)))
             (ok (= 1 (develop-result-replan-count result))
                 "replanned exactly once before passing")
             (ok (= 2 (length (develop-result-step-results result)))
                 "step results from both rounds are kept")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest develop-limit-exhausted-when-replans-budget-runs-out
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-p3-limit"))
         ;; Three different plans, each emitting a step that fails. We
         ;; ride out max-replans=2 → 1 initial round + 2 replans = 3
         ;; rounds, every one fails, then exhaust the budget.
         (plan-1 (list (%make-step :index 0 :test-name "alpha")))
         (plan-2 (list (%make-step :index 0 :test-name "beta")))
         (plan-3 (list (%make-step :index 0 :test-name "gamma")))
         (planner-fn (%canned-planner (list plan-1 plan-2 plan-3)))
         (call-log (cons '() nil))
         (outcomes (cons (list :give-up :give-up :give-up) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result (develop "stubborn goal"
                                  :project-root (namestring project-root)
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :test-file test-file
                                  :log-path log-path
                                  :max-replans 2
                                  :planner-fn planner-fn
                                  :run-fn runner)))
             (ok (eq :limit-exhausted (develop-result-status result)))
             (ok (eq :max-replans (develop-result-limit-hit result)))
             (ok (= 2 (develop-result-replan-count result)))
             (ok (= 3 (length (develop-result-step-results result)))
                 "three rounds × one step each = three step results")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest develop-stuck-when-replan-repeats-failing-step
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-p3-stuck"))
         ;; Initial plan and replan both produce the SAME first step
         ;; (same test_name). Stuck detection should fire after the
         ;; first replan, before consuming a second runner call on the
         ;; identical plan.
         (plan-shared (list (%make-step :index 0 :test-name "alpha")))
         (planner-fn (%canned-planner (list plan-shared plan-shared)))
         (call-log (cons '() nil))
         (outcomes (cons (list :give-up :give-up) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result (develop "fragile goal"
                                  :project-root (namestring project-root)
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :test-file test-file
                                  :log-path log-path
                                  :max-replans 5
                                  :planner-fn planner-fn
                                  :run-fn runner)))
             (ok (eq :stuck (develop-result-status result)))
             (ok (eq :no-progress (develop-result-limit-hit result)))
             (ok (= 1 (develop-result-replan-count result))
                 "only one replan was attempted; the second-round repeat got caught")
             (ok (= 1 (length (develop-result-step-results result)))
                 "stuck detection fires before the runner is invoked on the identical plan")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

;; --- v0.4 Phase 3: explore phase --------------------------------------

(deftest execute-plan-skips-explore-when-needs-exploration-is-none
  ;; Default plan-step has needs-exploration :none, so the explorer
  ;; must not be invoked.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-no-explore"))
         (steps (list (%make-step :index 0 :test-name "first")))
         (call-log (cons '() nil))
         (explore-log (cons '() nil))
         (runner (%fake-runner call-log (cons (list :passed) nil)))
         (explorer (%fake-explorer (cons '() nil) explore-log)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (execute-plan
            steps
            :project-root (namestring project-root)
            :system "demo"
            :test-system "demo/tests"
            :test-file test-file
            :log-path log-path
            :run-fn runner
            :explore-fn explorer)
           (ok (zerop (length (car explore-log)))
               "explore-fn not invoked when needs-exploration is :none"))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest execute-plan-runs-explore-and-prepends-memo-when-requested
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-with-explore"))
         (steps (list (make-instance
                       'plan-step
                       :index 0
                       :issue "Implement feature X."
                       :test-name "x-test"
                       :test-source "(deftest x-test (ok t))"
                       :files-to-modify nil
                       :needs-exploration :lightweight)))
         (call-log (cons '() nil))
         (explore-log (cons '() nil))
         (runner (%fake-runner call-log (cons (list :passed) nil)))
         (explorer (%fake-explorer
                    (cons (list "memo: package X already exists, has Y exported.")
                          nil)
                    explore-log)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((results (execute-plan
                           steps
                           :project-root (namestring project-root)
                           :system "demo"
                           :test-system "demo/tests"
                           :test-file test-file
                           :log-path log-path
                           :run-fn runner
                           :explore-fn explorer)))
             (ok (= 1 (length (car explore-log)))
                 "explore-fn was invoked once for the lightweight step")
             (let* ((step-result (first results))
                    (er (develop-step-result-explore-result step-result)))
               (ok er "develop-step-result carries the explore-result")
               (when er
                 (ok (search "package X already exists"
                             (cl-harness/src/explore:explore-result-memo er)))))
             ;; The implement runner saw the enriched issue (memo prepended).
             (let ((seen-issue (first (car call-log))))
               (ok (search "## Prior exploration" seen-issue))
               (ok (search "package X already exists" seen-issue))
               (ok (search "## Task" seen-issue))
               (ok (search "Implement feature X" seen-issue)))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest execute-plan-records-failures-and-resolves-on-pass
  ;; Phase B Task 8: %execute-step must parse each verify-result's
  ;; failed_tests via PARSE-FAILURE-RECORDS-FROM-TEST-RESULT and
  ;; record them on develop-state's failure-ledger. When a later
  ;; step's verify shows a previously-active failure absent, that
  ;; failure is moved to :RESOLVED via MARK-RESOLVED-BY.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-b8-ledger"))
         (steps (list (%make-step :index 0 :test-name "step-one"
                                  :test-source "(deftest step-one (ok t))"
                                  :issue "First.")
                      (%make-step :index 1 :test-name "step-two"
                                  :test-source "(deftest step-two (ok t))"
                                  :issue "Second.")))
         (ds (cl-harness/src/state:make-develop-state
              :goal "g"
              :project-root (namestring project-root)
              :system "demo"
              :test-system "demo/tests"))
         ;; Step counter so the stub can return different verify-results.
         (counter (cons 0 nil))
         (failing-test-result
          (alist-hash-table
           `(("passed" . 0)
             ("failed" . 1)
             ("failed_tests"
              . ,(vector
                  (alist-hash-table
                   `(("test_name" . "step-one")
                     ("description" . "step-one assertion failed")
                     ("form" . "(ok nil)")
                     ("reason" . "expected truthy")
                     ("source"
                      . ,(alist-hash-table
                          `(("file" . "/tmp/demo/src/feature.lisp")
                            ("line" . 12))
                          :test 'equal)))
                   :test 'equal))))
           :test 'equal))
         (passing-test-result
          (alist-hash-table
           `(("passed" . 1)
             ("failed" . 0))
           :test 'equal))
         (failing-verify
          (make-instance 'cl-harness/src/verify:verify-result
                         :status :test-failed
                         :passed 0 :failed 1
                         :test-result failing-test-result))
         (passing-verify
          (make-instance 'cl-harness/src/verify:verify-result
                         :status :passed
                         :passed 1 :failed 0
                         :test-result passing-test-result))
         (runner
          (lambda (config provider mcp-client policy logger
                   &key clean-verify-p dry-run-p before-clean-verify-fn
                        isolate-asdf-p develop-state
                   &allow-other-keys)
            (declare (ignore config provider mcp-client policy logger
                             clean-verify-p dry-run-p
                             before-clean-verify-fn isolate-asdf-p
                             develop-state))
            (let* ((idx (car counter))
                   (state (cl-harness/src/agent::%make-agent-state-for-tests))
                   (vr (if (zerop idx) failing-verify passing-verify)))
              (incf (car counter))
              (setf (cl-harness/src/agent:agent-state-status state) :passed)
              (setf (cl-harness/src/agent:agent-state-final-verify state) vr)
              state))))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (execute-plan steps
                         :project-root (namestring project-root)
                         :system "demo"
                         :test-system "demo/tests"
                         :test-file test-file
                         :log-path log-path
                         :run-fn runner
                         :develop-state ds)
           (let* ((ledger (cl-harness/src/state:develop-state-failure-ledger ds))
                  (active (cl-harness/src/failure-ledger:failure-ledger-active
                           ledger))
                  (resolved (cl-harness/src/failure-ledger:failure-ledger-resolved
                             ledger)))
             (ok (zerop (length active))
                 "step-one's failure resolved after step-two's clean verify")
             (ok (= 1 (length resolved))
                 "exactly one failure record was moved to :resolved")
             (when (= 1 (length resolved))
               (let ((rec (first resolved)))
                 (ok (equal "step-one"
                            (cl-harness/src/failure-ledger:failure-record-test-name
                             rec))
                     "resolved record names step-one")))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))
