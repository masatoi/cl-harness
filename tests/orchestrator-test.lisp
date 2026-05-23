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
                #:develop-result-develop-state
                #:develop-result-status
                #:develop-result-step-results
                #:develop-result-replan-count
                #:develop-result-limit-hit
                #:validate-test-source
                #:materialize-test-source
                #:plan-step->run-config
                #:execute-plan
                #:develop)
  (:import-from #:cl-harness/src/state
                #:make-develop-state))

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
           &key max-turns plan-step develop-state &allow-other-keys)
    (declare (ignore config provider mcp-client policy logger max-turns
                     develop-state))
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

(deftest execute-plan-resolves-relative-test-file-under-project-root
  (let* ((project-root (merge-pathnames
                        (format nil "cl-harness-orch-root-~A/"
                                (get-universal-time))
                        (uiop:temporary-directory)))
         (relative (format nil "tests/relative-~A.lisp"
                           (get-universal-time)))
         (project-test-file (merge-pathnames relative project-root))
         (cwd-test-file (merge-pathnames relative *default-pathname-defaults*))
         (log-path (%tmp-path "develop-log-relative"))
         (steps (list (%make-step :index 0
                                  :test-name "relative-test"
                                  :test-source "(deftest relative-test (ok t))")))
         (call-log (cons '() nil))
         (outcomes (cons (list :passed) nil))
         (runner (%fake-runner call-log outcomes)))
    (unwind-protect
         (progn
           (when (probe-file cwd-test-file) (delete-file cwd-test-file))
           (%make-test-file project-test-file)
           (execute-plan steps
                         :project-root (namestring project-root)
                         :system "demo"
                         :test-system "demo/tests"
                         :test-file relative
                         :log-path log-path
                         :run-fn runner)
           (ok (probe-file project-test-file))
           (ok (not (probe-file cwd-test-file))
               "relative test-file must not be materialized under cwd")
           (let ((content (uiop:read-file-string project-test-file)))
             (ok (search "(deftest relative-test" content))))
      (when (probe-file cwd-test-file) (delete-file cwd-test-file))
      (when (probe-file project-test-file) (delete-file project-test-file))
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
                       project-inventory mode develop-state)
      (declare (ignore goal project-root system test-system provider
                       prior-plan failure-context system-prompt
                       project-inventory mode develop-state))
      (cond
        ((null remaining)
         (error "canned-planner exhausted"))
        ((null (cdr remaining))
         (car remaining))
        (t (pop remaining))))))

(deftest develop-threads-develop-state-into-planner-fn
  ;; Phase C wiring follow-up: %execute-plan must thread its
  ;; develop-state through to planner-fn so the planner's user
  ;; prompt is built via the :planning context-view formatter
  ;; instead of the legacy ad-hoc string assembly. The test stub
  ;; captures the develop-state it receives; the test asserts it
  ;; is non-NIL on both the initial-plan call and the replan call.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-c-wire"))
         (plan-1 (list (%make-step :index 0 :test-name "alpha"
                                   :test-source "(deftest alpha (ok t))")))
         (plan-2 (list (%make-step :index 0 :test-name "beta"
                                   :test-source "(deftest beta (ok t))")))
         (captured-states (cons '() nil))
         (planner-fn
          (let ((remaining (list plan-1 plan-2)))
            (lambda (goal &key develop-state &allow-other-keys)
              (declare (ignore goal))
              (push develop-state (car captured-states))
              (cond ((null remaining) (error "exhausted"))
                    ((null (cdr remaining)) (car remaining))
                    (t (pop remaining))))))
         (outcomes (cons (list :give-up :passed) nil))
         (runner (%fake-runner (cons '() nil) outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (develop "thread state through planner"
                    :project-root (namestring project-root)
                    :system "demo"
                    :test-system "demo/tests"
                    :test-file test-file
                    :log-path log-path
                    :planner-fn planner-fn
                    :run-fn runner)
           (let ((calls (reverse (car captured-states))))
             (ok (= 2 (length calls)))
             (ok (every (lambda (s)
                          (typep s 'cl-harness/src/state:develop-state))
                        calls))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest develop-auto-gathers-project-summary
  ;; Phase I auto-gather: cl-harness:develop should populate
  ;; develop-state-project-summary by calling gather-project-summary
  ;; against the live project-root, so the :planning view sees the
  ;; structured summary alongside the existing project-inventory text.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-i-gather"))
         (plan-1 (list (%make-step :index 0 :test-name "alpha"
                                   :test-source "(deftest alpha (ok t))")))
         (planner-fn (%canned-planner (list plan-1)))
         (outcomes (cons (list :passed) nil))
         (runner (%fake-runner (cons '() nil) outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let* ((result (develop "auto-gather smoke"
                                   :project-root (namestring project-root)
                                   :system "demo"
                                   :test-system "demo/tests"
                                   :test-file test-file
                                   :log-path log-path
                                   :planner-fn planner-fn
                                   :run-fn runner))
                  (state (cl-harness/src/orchestrator:develop-result-develop-state
                          result)))
             (ok (cl-harness/src/state:develop-state-project-summary state)
                 "develop populated project-summary slot via gather-project-summary")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

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

(deftest develop-replans-when-plan-review-rejects
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-review-replan"))
         (plan-1 (list (%make-step :index 0 :test-name "weak-test")))
         (plan-2 (list (%make-step :index 0 :test-name "strong-test")))
         (planner-fn (%canned-planner (list plan-1 plan-2)))
         (decisions (cons (list :rejected :approved :approved) nil))
         (review-fn
           (lambda (kind &key &allow-other-keys)
             (let ((status (or (pop (car decisions)) :approved)))
               (cl-harness/src/review:make-review-decision
                :kind kind
                :status status
                :feedback (if (eq :rejected status)
                              "missing acceptance criterion"
                              "")))))
         (outcomes (cons (list :passed) nil))
         (runner (%fake-runner (cons '() nil) outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let* ((result (develop "reviewed goal"
                                   :project-root (namestring project-root)
                                   :system "demo"
                                   :test-system "demo/tests"
                                   :test-file test-file
                                   :log-path log-path
                                   :review-policy :auto
                                   :planner-fn planner-fn
                                   :review-fn review-fn
                                   :run-fn runner))
                  (state (develop-result-develop-state result)))
             (ok (eq :passed (develop-result-status result)))
             (ok (= 1 (cl-harness/src/state:develop-state-review-replan-count
                       state)))
             (ok (= 4 (length
                       (cl-harness/src/state:develop-state-review-decisions
                        state))))
             (ok (string= "strong-test"
                          (cl-harness/src/planner:plan-step-test-name
                           (first (cl-harness/src/orchestrator:develop-result-final-plan
                                   result)))))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest execute-plan-marks-step-review-rejected
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "execute-review-rejected"))
         (state (make-develop-state :goal "review implementation"
                                    :project-root (namestring project-root)
                                    :system "demo"
                                    :test-system "demo/tests"
                                    :review-policy :auto))
         (step (%make-step :index 0 :test-name "alpha"))
         (review-fn
           (lambda (kind &key &allow-other-keys)
             (cl-harness/src/review:make-review-decision
              :kind kind
              :status (if (eq kind :implementation) :rejected :approved)
              :feedback "implementation overfits the test")))
         (outcomes (cons (list :passed) nil))
         (runner (%fake-runner (cons '() nil) outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((results (execute-plan
                           (list step)
                           :project-root (namestring project-root)
                           :system "demo"
                           :test-system "demo/tests"
                           :test-file test-file
                           :log-path log-path
                           :run-fn runner
                           :review-fn review-fn
                           :develop-state state)))
             (ok (= 1 (length results)))
             (ok (eq :review-rejected
                     (develop-step-result-status (first results))))))
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

(deftest fresh-source-surface-p-detects-empty-and-trivial-src
  (let ((root (uiop:ensure-directory-pathname
               (%tmp-path "fresh-src-probe"))))
    (unwind-protect
         (progn
           (ensure-directories-exist root)
           (testing "no src/ subdirectory: NOT eligible for downgrade"
             (ok (not (cl-harness/src/orchestrator::%fresh-source-surface-p
                       (namestring root)))
                 "missing src/ returns NIL (respect planner)"))
           (testing "src/ exists but is empty: eligible for downgrade"
             (ensure-directories-exist (merge-pathnames "src/" root))
             (ok (cl-harness/src/orchestrator::%fresh-source-surface-p
                  (namestring root))
                 "empty src/ counts as fresh"))
           (testing "src/main.lisp with only in-package: eligible"
             (with-open-file (out (merge-pathnames "src/main.lisp" root)
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
               (format out "(in-package #:demo)~%")
               (format out ";; not yet implemented~%"))
             (ok (cl-harness/src/orchestrator::%fresh-source-surface-p
                  (namestring root))
                 "in-package-only src/main.lisp counts as fresh"))
           (testing "src/main.lisp with a defun: NOT eligible"
             (with-open-file (out (merge-pathnames "src/main.lisp" root)
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
               (format out "(in-package #:demo)~%")
               (format out "(defun greet (name) (format nil \"Hi ~~A\" name))~%"))
             (ok (not (cl-harness/src/orchestrator::%fresh-source-surface-p
                       (namestring root)))
                 "src/main.lisp with a defun is not fresh")))
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))

(deftest execute-plan-downgrades-needs-exploration-on-fresh-source
  (let* ((project-root (uiop:ensure-directory-pathname
                        (%tmp-path "downgrade-fresh")))
         (test-file (merge-pathnames
                     (format nil "tests/main-test-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-with-downgrade"))
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
                    (cons (list "memo: SHOULD NOT BE CALLED") nil)
                    explore-log)))
    (unwind-protect
         (progn
           (ensure-directories-exist project-root)
           (ensure-directories-exist
            (merge-pathnames "src/" project-root))
           (%make-test-file test-file)
           (ok (cl-harness/src/orchestrator::%fresh-source-surface-p
                (namestring project-root))
               "precondition: empty src/ counts as fresh")
           (execute-plan steps
                         :project-root (namestring project-root)
                         :system "demo"
                         :test-system "demo/tests"
                         :test-file test-file
                         :log-path log-path
                         :run-fn runner
                         :explore-fn explorer)
           (testing "explore-fn was NOT invoked (downgrade fired)"
             (ok (zerop (length (car explore-log)))))
           (testing "develop log contains :explore-downgrade event"
             (let ((log-contents (uiop:read-file-string log-path)))
               (ok (search "\"explore-downgrade\"" log-contents))
               (ok (search "\"from\":\"lightweight\"" log-contents))
               (ok (search "\"to\":\"none\"" log-contents))
               (ok (search "\"reason\":\"fresh-source-surface\""
                           log-contents)))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path))
      (when (uiop:directory-exists-p project-root)
        (uiop:delete-directory-tree project-root :validate t)))))

(deftest execute-plan-keeps-explore-when-source-has-code
  (let* ((project-root (uiop:ensure-directory-pathname
                        (%tmp-path "keep-explore")))
         (test-file (merge-pathnames
                     (format nil "tests/main-test-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-keep-explore"))
         (steps (list (make-instance
                       'plan-step
                       :index 0
                       :issue "Extend existing greet to handle NIL."
                       :test-name "x-test"
                       :test-source "(deftest x-test (ok t))"
                       :files-to-modify nil
                       :needs-exploration :lightweight)))
         (call-log (cons '() nil))
         (explore-log (cons '() nil))
         (runner (%fake-runner call-log (cons (list :passed) nil)))
         (explorer (%fake-explorer
                    (cons (list "memo: pretend we explored") nil)
                    explore-log)))
    (unwind-protect
         (progn
           (ensure-directories-exist
            (merge-pathnames "src/" project-root))
           (with-open-file (out (merge-pathnames "src/main.lisp" project-root)
                                :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
             (format out "(in-package #:demo)~%")
             (format out "(defun greet (name) (format nil \"Hi ~~A\" name))~%"))
           (%make-test-file test-file)
           (execute-plan steps
                         :project-root (namestring project-root)
                         :system "demo"
                         :test-system "demo/tests"
                         :test-file test-file
                         :log-path log-path
                         :run-fn runner
                         :explore-fn explorer)
           (testing "explore-fn WAS invoked (no downgrade)"
             (ok (= 1 (length (car explore-log)))))
           (testing "develop log has NO :explore-downgrade event"
             (let ((log-contents (uiop:read-file-string log-path)))
               (ok (not (search "explore-downgrade" log-contents))))))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path))
      (when (uiop:directory-exists-p project-root)
        (uiop:delete-directory-tree project-root :validate t)))))

(deftest execute-plan-threads-develop-state-into-explore-fn
  ;; Phase C.7 wiring: when EXECUTE-PLAN is invoked with a
  ;; :develop-state, %execute-step must thread that state into the
  ;; explore-fn callback so the explorer can render the user prompt
  ;; via the :exploration formatter. The explorer fixture below
  ;; captures the develop-state it received; the test asserts it
  ;; matches the develop-state the test passed in.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-thread-state"))
         (steps (list (make-instance
                       'plan-step
                       :index 0
                       :issue "Implement feature Y."
                       :test-name "y-test"
                       :test-source "(deftest y-test (ok t))"
                       :files-to-modify nil
                       :needs-exploration :lightweight)))
         (state (make-develop-state
                 :goal "g"
                 :project-root (namestring project-root)
                 :system "demo"
                 :test-system "demo/tests"))
         (call-log (cons '() nil))
         (captured-state (cons nil nil))
         (runner (%fake-runner call-log (cons (list :passed) nil)))
         (explorer
          (lambda (config provider mcp-client policy logger
                   &key plan-step develop-state &allow-other-keys)
            (declare (ignore config provider mcp-client policy logger
                             plan-step))
            (setf (car captured-state) develop-state)
            (make-instance 'cl-harness/src/explore:explore-result
                           :status :reported
                           :memo "memo: ok"
                           :turns 1
                           :token-total 50))))
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
            :explore-fn explorer
            :develop-state state)
           (ok (eq state (car captured-state))
               "explore-fn received the develop-state passed to execute-plan"))
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

(deftest develop-result-develop-state-defaults-to-nil
  ;; The new optional slot defaults to NIL for backward compat
  ;; with constructors that don't pass it.
  (let ((r (make-instance 'cl-harness/src/orchestrator:develop-result
                          :status :passed
                          :final-plan nil
                          :step-results nil)))
    (ok (null (cl-harness/src/orchestrator:develop-result-develop-state r)))))

(deftest develop-result-develop-state-accepts-back-ref
  ;; When the orchestrator constructs a develop-result, it now
  ;; passes the in-memory develop-state via :develop-state.
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/" :system "demo"
             :test-system "demo/tests"))
         (r (make-instance 'cl-harness/src/orchestrator:develop-result
                           :status :passed
                           :final-plan nil
                           :step-results nil
                           :develop-state s)))
    (ok (eq s (cl-harness/src/orchestrator:develop-result-develop-state r)))))

(deftest promote-matching-findings-flips-promoted-flag-when-hypothesis-in-diff
  (let ((state (cl-harness/src/state:make-develop-state
                :goal "g" :project-root "/tmp/p"
                :system "x" :test-system "x/tests"))
        (finding (cl-harness/src/repl-finding:make-repl-finding
                  :hypothesis "implement greet helper"
                  :probe "(greet \"Alice\")"
                  :finding "returns Hello, Alice!"
                  :decision "promote ordinary function"))
        (patch (cl-harness/src/patch-record:make-patch-record
                :path "src/foo.lisp" :via-tool "lisp-edit-form"
                :diff-summary "+ (defun greet (name) ...)
;; implement greet helper for the public API"
                :turn 1)))
    (cl-harness/src/state:develop-state-record-repl-finding state finding)
    (cl-harness/src/state:develop-state-record-patch-record state patch)
    (ok (null (cl-harness/src/repl-finding:repl-finding-promoted-to-source-p
               finding)))
    (cl-harness/src/orchestrator::%promote-matching-findings state)
    (ok (eq t (cl-harness/src/repl-finding:repl-finding-promoted-to-source-p
               finding)))
    (ok (eq patch (cl-harness/src/repl-finding:repl-finding-linked-patch
                   finding)))))

(deftest promote-matching-findings-leaves-unpromoted-when-no-patch-matches
  (let ((state (cl-harness/src/state:make-develop-state
                :goal "g" :project-root "/tmp/p"
                :system "x" :test-system "x/tests"))
        (finding (cl-harness/src/repl-finding:make-repl-finding
                  :hypothesis "implement zonk function"
                  :probe "p" :finding "f" :decision "d"))
        (patch (cl-harness/src/patch-record:make-patch-record
                :path "src/foo.lisp" :via-tool "lisp-edit-form"
                :diff-summary "+ (defun greet (name) ...)"
                :turn 1)))
    (cl-harness/src/state:develop-state-record-repl-finding state finding)
    (cl-harness/src/state:develop-state-record-patch-record state patch)
    (cl-harness/src/orchestrator::%promote-matching-findings state)
    (ok (null (cl-harness/src/repl-finding:repl-finding-promoted-to-source-p
               finding)))))

(deftest promote-matching-findings-handles-nil-state
  ;; The hook is called from the orchestrator's post-step path with
  ;; whatever develop-state is bound. Test stubs may pass NIL.
  (ok (null (cl-harness/src/orchestrator::%promote-matching-findings nil))))

(deftest promote-matching-findings-skips-already-promoted-finding
  ;; Idempotence: if a finding is already promoted (linked to patch A),
  ;; a later run that finds patch B matching the same hypothesis must
  ;; NOT clobber the prior linkage.
  (let ((state (cl-harness/src/state:make-develop-state
                :goal "g" :project-root "/tmp/p"
                :system "x" :test-system "x/tests"))
        (finding (cl-harness/src/repl-finding:make-repl-finding
                  :hypothesis "implement greet helper"
                  :probe "p" :finding "f" :decision "d"))
        (patch-a (cl-harness/src/patch-record:make-patch-record
                  :path "src/foo.lisp" :via-tool "lisp-edit-form"
                  :diff-summary "implement greet helper" :turn 1))
        (patch-b (cl-harness/src/patch-record:make-patch-record
                  :path "src/bar.lisp" :via-tool "lisp-edit-form"
                  :diff-summary "implement greet helper" :turn 2)))
    (cl-harness/src/state:develop-state-record-repl-finding state finding)
    (cl-harness/src/state:develop-state-record-patch-record state patch-a)
    (cl-harness/src/orchestrator::%promote-matching-findings state)
    ;; Now add patch-b and call again — linkage should remain patch-a.
    (cl-harness/src/state:develop-state-record-patch-record state patch-b)
    (cl-harness/src/orchestrator::%promote-matching-findings state)
    (ok (eq patch-a (cl-harness/src/repl-finding:repl-finding-linked-patch
                     finding)))))

(deftest develop-result-reason-defaults-to-nil
  (let ((r (make-instance 'cl-harness/src/orchestrator:develop-result
                          :status :passed
                          :final-plan nil
                          :step-results nil)))
    (ok (null (cl-harness/src/orchestrator:develop-result-reason r)))))

;; --- failure-context-enrichment helpers --------------------------

(defun %make-stub-step-result-with-state (&key (step-index 0)
                                               (test-name "demo")
                                               (status :give-up)
                                               agent-state)
  "Build a develop-step-result whose run-agent-state slot points to
the supplied AGENT-STATE. Used to drive the new %FAILURE-CONTEXT
multi-paragraph branches without spinning up a real run-agent."
  (make-instance 'cl-harness/src/step-result:develop-step-result
                 :step-index step-index
                 :test-name test-name
                 :status status
                 :run-agent-state agent-state))

(deftest failure-context-omits-empty-sections
  ;; Stub agent-state with NIL final-verify and empty ring; output
  ;; should be the single-paragraph form (no subheaders).
  (let* ((state (make-instance 'cl-harness/src/agent::agent-state))
         (sr (%make-stub-step-result-with-state
              :step-index 1 :test-name "foo" :status :give-up
              :agent-state state))
         (out (cl-harness/src/orchestrator::%failure-context sr)))
    (ok (search "step 1" out))
    (ok (search "foo" out))
    (ok (search ":give-up" out))
    (ok (not (search "### " out))
        "no subheaders emitted when no enrichment data available")))

(deftest failure-context-includes-tool-errors-when-ring-non-empty
  ;; Push 2 tool-error entries onto agent-state's ring; verify both
  ;; show up in the rendered string in newest-first order.
  (let ((state (make-instance 'cl-harness/src/agent::agent-state)))
    (cl-harness/src/agent::record-tool-error
     state "lisp-edit-form" "defun foo (replace)" "form-name not unique" 5)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(boom)" "INPUT unbound" 6)
    (let* ((sr (%make-stub-step-result-with-state
                :step-index 0 :test-name "x" :status :give-up
                :agent-state state))
           (out (cl-harness/src/orchestrator::%failure-context sr)))
      (ok (search "### Recent tool errors" out))
      (ok (search "repl-eval" out))
      (ok (search "INPUT unbound" out))
      (ok (search "lisp-edit-form" out))
      (ok (search "form-name not unique" out))
      (ok (< (search "INPUT unbound" out)
             (search "form-name not unique" out))
          "newest entry rendered first"))))

(deftest failure-context-includes-load-error-when-final-verify-load-failed
  ;; Stub final-verify slot with a verify-result whose load-result
  ;; carries an EXPORT name-conflict isError=true text.
  (let* ((load-fail
          (alist-hash-table
           `(("isError" . t)
             ("content"
              . ,(vector
                  (alist-hash-table
                   '(("type" . "text")
                     ("text"
                      . "EXPORT FIB::FIBONACCI causes name-conflicts in #<PACKAGE \"FIB/TESTS/MAIN\"> between the following symbols: FIB::FIBONACCI, FIB/TESTS/MAIN::FIBONACCI"))
                   :test 'equal))))
           :test 'equal))
         (vr (make-instance 'cl-harness/src/verify:verify-result
                            :status :load-failed
                            :load-result load-fail))
         (state (make-instance 'cl-harness/src/agent::agent-state)))
    (setf (cl-harness/src/agent:agent-state-final-verify state) vr)
    (let* ((sr (%make-stub-step-result-with-state
                :step-index 0 :test-name "y" :status :give-up
                :agent-state state))
           (out (cl-harness/src/orchestrator::%failure-context sr)))
      (ok (search "### Last verify error (load-system)" out))
      (ok (search "EXPORT FIB::FIBONACCI" out))
      (ok (search "name-conflicts" out)))))

(deftest failure-context-omits-load-error-when-text-is-empty
  ;; Regression for code-quality reviewer I1: empty content[].text
  ;; must NOT emit the ### Last verify error (load-system) subheader.
  (let* ((load-fail
          (alist-hash-table
           `(("isError" . t)
             ("content"
              . ,(vector
                  (alist-hash-table
                   '(("type" . "text") ("text" . ""))
                   :test 'equal))))
           :test 'equal))
         (vr (make-instance 'cl-harness/src/verify:verify-result
                            :status :load-failed
                            :load-result load-fail))
         (state (make-instance 'cl-harness/src/agent::agent-state)))
    (setf (cl-harness/src/agent:agent-state-final-verify state) vr)
    (let* ((sr (%make-stub-step-result-with-state
                :step-index 0 :test-name "z" :status :give-up
                :agent-state state))
           (out (cl-harness/src/orchestrator::%failure-context sr)))
      (ok (not (search "### Last verify error (load-system)" out))
          "empty error text → subheader omitted"))))

(deftest review-implementation-returns-feedback
  (testing "approved decision returns (values t nil-or-feedback)"
    (let* ((decision (cl-harness/src/review:make-review-decision
                      :kind :implementation
                      :status :approved
                      :feedback "looks good"))
           (review-fn (lambda (kind &key &allow-other-keys)
                        (declare (ignore kind))
                        decision))
           (state (make-instance 'cl-harness/src/agent:agent-state))
           (devstate (cl-harness/src/state:make-develop-state
                      :goal "g"
                      :project-root "/tmp"
                      :system "demo"
                      :test-system "demo/tests"
                      :review-policy :auto))
           (step (make-instance 'cl-harness/src/planner:plan-step
                                :index 0
                                :issue "x"
                                :test-name "tx"
                                :test-source "(deftest tx)")))
      (setf (cl-harness/src/agent:agent-state-status state) :passed)
      (multiple-value-bind (approved-p feedback)
          (cl-harness/src/orchestrator::%review-implementation
           step state review-fn nil devstate)
        (ok (eq t approved-p))
        (ok (or (null feedback) (stringp feedback))))))
  (testing "rejected decision returns (values nil feedback-string)"
    (let* ((decision (cl-harness/src/review:make-review-decision
                      :kind :implementation
                      :status :rejected
                      :feedback "rename X to Y"))
           (review-fn (lambda (kind &key &allow-other-keys)
                        (declare (ignore kind))
                        decision))
           (state (make-instance 'cl-harness/src/agent:agent-state))
           (devstate (cl-harness/src/state:make-develop-state
                      :goal "g"
                      :project-root "/tmp"
                      :system "demo"
                      :test-system "demo/tests"
                      :review-policy :auto))
           (step (make-instance 'cl-harness/src/planner:plan-step
                                :index 0
                                :issue "x"
                                :test-name "tx"
                                :test-source "(deftest tx)")))
      (setf (cl-harness/src/agent:agent-state-status state) :passed)
      (multiple-value-bind (approved-p feedback)
          (cl-harness/src/orchestrator::%review-implementation
           step state review-fn nil devstate)
        (ok (null approved-p))
        (ok (equal "rename X to Y" feedback)))))
  (testing "disabled review returns (values t nil)"
    (let ((state (make-instance 'cl-harness/src/agent:agent-state))
          (devstate (cl-harness/src/state:make-develop-state
                     :goal "g"
                     :project-root "/tmp"
                     :system "demo"
                     :test-system "demo/tests"
                     :review-policy :none))
          (step (make-instance 'cl-harness/src/planner:plan-step
                               :index 0
                               :issue "x"
                               :test-name "tx"
                               :test-source "(deftest tx)")))
      (setf (cl-harness/src/agent:agent-state-status state) :passed)
      (multiple-value-bind (approved-p feedback)
          (cl-harness/src/orchestrator::%review-implementation
           step state (lambda (k &key &allow-other-keys)
                        (declare (ignore k))
                        (error "should not be called"))
           nil devstate)
        (ok (eq t approved-p))
        (ok (null feedback))))))

(deftest enriched-issue-with-review-feedback
  (let ((step (make-instance 'plan-step
                             :index 1 :issue "original task body" :test-name "tx"
                             :test-source "(deftest tx)")))
    (testing "no extras returns plain issue"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue step nil)))
        (ok (equal "original task body" result))))
    (testing "memo only prepends exploration block"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue
                     step "memo content")))
        (ok (search "## Prior exploration (read-only)" result))
        (ok (search "memo content" result))
        (ok (search "original task body" result))
        (ok (not (search "Prior implementation review feedback" result)))))
    (testing "review-feedback only prepends feedback block"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue
                     step nil :review-feedback "rename X to Y")))
        (ok (search "## Prior implementation review feedback" result))
        (ok (search "rename X to Y" result))
        (ok (search "original task body" result))
        (ok (not (search "Prior exploration" result)))))
    (testing "both prepends review-feedback BEFORE exploration"
      (let* ((result (cl-harness/src/orchestrator::%enriched-issue
                      step "memo content" :review-feedback "rename X to Y"))
             (fb-pos (search "Prior implementation review feedback" result))
             (exp-pos (search "Prior exploration" result))
             (task-pos (search "## Task" result)))
        (ok (and fb-pos exp-pos task-pos))
        (ok (< fb-pos exp-pos))
        (ok (< exp-pos task-pos))))
    (testing "empty-string review-feedback is treated like NIL"
      (let ((result (cl-harness/src/orchestrator::%enriched-issue
                     step nil :review-feedback "")))
        (ok (equal "original task body" result))))))

(defun %make-fake-passed-state ()
  "A minimal agent-state with status :passed for inner-loop stub tests."
  (let ((s (make-instance 'cl-harness/src/agent:agent-state)))
    (setf (cl-harness/src/agent:agent-state-status s) :passed)
    s))

(deftest impl-review-inner-loop-approves-on-second-attempt
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-inner-loop-~A.lisp"
                             (get-universal-time))
                     project-root))
         (run-fn-calls (list))
         (run-fn (lambda (rc provider mcp-client policy logger
                          &key develop-state &allow-other-keys)
                   (declare (ignore provider mcp-client policy logger
                                    develop-state))
                   (push (cl-harness/src/config:run-config-issue rc)
                         run-fn-calls)
                   (%make-fake-passed-state)))
         (decisions (list (cl-harness/src/review:make-review-decision
                           :kind :implementation
                           :status :rejected
                           :feedback "rename X to Y")
                          (cl-harness/src/review:make-review-decision
                           :kind :implementation
                           :status :approved
                           :feedback "ok")))
         (review-fn (lambda (kind &key &allow-other-keys)
                      (declare (ignore kind))
                      (pop decisions)))
         (step (make-instance 'cl-harness/src/planner:plan-step
                              :index 1
                              :issue "fix the bug"
                              :test-name "tx"
                              :test-source "(deftest tx (ok t))"
                              :needs-exploration :none))
         (devstate (cl-harness/src/state:make-develop-state
                    :goal "g"
                    :project-root (namestring project-root)
                    :system "demo"
                    :test-system "demo/tests"
                    :review-policy :auto)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result
                  (cl-harness/src/orchestrator::%execute-step
                   step run-fn (namestring project-root) "demo" "demo/tests"
                   :generic-mcp test-file nil nil nil nil nil
                   :develop-state devstate
                   :review-fn review-fn
                   :max-impl-review-revisions 2)))
             (testing "run-fn called twice (initial + 1 retry)"
               (ok (= 2 (length run-fn-calls))))
             (testing "second run-fn invocation issue contains feedback"
               (let ((second-issue (first run-fn-calls)))
                 (ok (search "Prior implementation review feedback" second-issue))
                 (ok (search "rename X to Y" second-issue))))
             (testing "first run-fn invocation has plain issue"
               (let ((first-issue (second run-fn-calls)))
                 (ok (not (search "Prior implementation review feedback"
                                  first-issue)))))
             (testing "final status is :passed"
               (ok (eq :passed
                       (cl-harness/src/orchestrator:develop-step-result-status
                        result))))))
      (when (probe-file test-file) (delete-file test-file)))))

(deftest impl-review-inner-loop-exhausts-budget
  ;; run-fn always returns :passed; review-fn always rejects.
  ;; With max-impl-review-revisions 1, we expect 2 run-fn calls (initial +
  ;; 1 retry) and a final status of :review-rejected.
  (let* ((project-root (uiop:temporary-directory))
         (test-file
          (merge-pathnames
           (format nil "cl-harness-exhaust-~A.lisp" (get-universal-time))
           project-root))
         (run-fn-calls 0)
         (run-fn
          (lambda (rc provider mcp-client policy logger
                   &key develop-state &allow-other-keys)
            (declare (ignore rc provider mcp-client policy logger
                             develop-state))
            (incf run-fn-calls)
            (%make-fake-passed-state)))
         (review-fn
          (lambda (kind &key &allow-other-keys)
            (declare (ignore kind))
            (cl-harness/src/review:make-review-decision
             :kind :implementation
             :status :rejected
             :feedback "never approved")))
         (step
          (make-instance 'cl-harness/src/planner:plan-step
                         :index 1
                         :issue "x"
                         :test-name "tx"
                         :test-source "(deftest tx (ok t))"
                         :needs-exploration :none))
         (devstate
          (cl-harness/src/state:make-develop-state
           :goal "g"
           :project-root (namestring project-root)
           :system "demo"
           :test-system "demo/tests"
           :review-policy :auto)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result
                  (cl-harness/src/orchestrator::%execute-step
                   step run-fn (namestring project-root) "demo" "demo/tests"
                   :generic-mcp test-file nil nil nil nil nil
                   :develop-state devstate
                   :review-fn review-fn
                   :max-impl-review-revisions 1)))
             (testing "run-fn called twice (initial + 1 retry)"
               (ok (= 2 run-fn-calls)))
             (testing "final status is :review-rejected"
               (ok (eq :review-rejected
                       (cl-harness/src/orchestrator:develop-step-result-status
                        result))))))
      (when (probe-file test-file) (delete-file test-file)))))

(deftest impl-review-disabled-when-budget-zero
  ;; With max-impl-review-revisions 0, the loop exits on the first rejection
  ;; without retrying. run-fn is called once; status is :review-rejected.
  (let* ((project-root (uiop:temporary-directory))
         (test-file
          (merge-pathnames
           (format nil "cl-harness-budget0-~A.lisp" (get-universal-time))
           project-root))
         (run-fn-calls 0)
         (run-fn
          (lambda (rc provider mcp-client policy logger
                   &key develop-state &allow-other-keys)
            (declare (ignore rc provider mcp-client policy logger
                             develop-state))
            (incf run-fn-calls)
            (%make-fake-passed-state)))
         (review-fn
          (lambda (kind &key &allow-other-keys)
            (declare (ignore kind))
            (cl-harness/src/review:make-review-decision
             :kind :implementation
             :status :rejected
             :feedback "rejected")))
         (step
          (make-instance 'cl-harness/src/planner:plan-step
                         :index 1
                         :issue "x"
                         :test-name "tx"
                         :test-source "(deftest tx (ok t))"
                         :needs-exploration :none))
         (devstate
          (cl-harness/src/state:make-develop-state
           :goal "g"
           :project-root (namestring project-root)
           :system "demo"
           :test-system "demo/tests"
           :review-policy :auto)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result
                  (cl-harness/src/orchestrator::%execute-step
                   step run-fn (namestring project-root) "demo" "demo/tests"
                   :generic-mcp test-file nil nil nil nil nil
                   :develop-state devstate
                   :review-fn review-fn
                   :max-impl-review-revisions 0)))
             (testing "run-fn called once (no retries)"
               (ok (= 1 run-fn-calls)))
             (testing "final status is :review-rejected"
               (ok (eq :review-rejected
                       (cl-harness/src/orchestrator:develop-step-result-status
                        result))))))
      (when (probe-file test-file) (delete-file test-file)))))

(deftest impl-review-disabled-when-policy-none
  ;; With review-policy :none, the loop never calls review-fn and returns
  ;; :passed directly after run-fn succeeds.
  (let* ((project-root (uiop:temporary-directory))
         (test-file
          (merge-pathnames
           (format nil "cl-harness-policy-none-~A.lisp" (get-universal-time))
           project-root))
         (run-fn-calls 0)
         (review-fn-calls 0)
         (run-fn
          (lambda (rc provider mcp-client policy logger
                   &key develop-state &allow-other-keys)
            (declare (ignore rc provider mcp-client policy logger
                             develop-state))
            (incf run-fn-calls)
            (%make-fake-passed-state)))
         (review-fn
          (lambda (kind &key &allow-other-keys)
            (declare (ignore kind))
            (incf review-fn-calls)
            (cl-harness/src/review:make-review-decision
             :kind :implementation
             :status :approved
             :feedback "")))
         (step
          (make-instance 'cl-harness/src/planner:plan-step
                         :index 1
                         :issue "x"
                         :test-name "tx"
                         :test-source "(deftest tx (ok t))"
                         :needs-exploration :none))
         (devstate
          (cl-harness/src/state:make-develop-state
           :goal "g"
           :project-root (namestring project-root)
           :system "demo"
           :test-system "demo/tests"
           :review-policy :none)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result
                  (cl-harness/src/orchestrator::%execute-step
                   step run-fn (namestring project-root) "demo" "demo/tests"
                   :generic-mcp test-file nil nil nil nil nil
                   :develop-state devstate
                   :review-fn review-fn
                   :max-impl-review-revisions 2)))
             (testing "run-fn called once"
               (ok (= 1 run-fn-calls)))
             (testing "review-fn never called (policy :none short-circuits)"
               (ok (= 0 review-fn-calls)))
             (testing "final status is :passed"
               (ok (eq :passed
                       (cl-harness/src/orchestrator:develop-step-result-status
                        result))))))
      (when (probe-file test-file) (delete-file test-file)))))

(deftest impl-review-respects-test-change-priority
  ;; run-fn returns :test-change-request on first call, :passed on second.
  ;; review-fn approves both test-change and implementation. The
  ;; test-change branch must fire FIRST, then implementation review.
  (let* ((project-root (uiop:temporary-directory))
         (test-file
          (merge-pathnames
           (format nil "cl-harness-priority-~A.lisp" (get-universal-time))
           project-root))
         (run-fn-call-count 0)
         (run-fn
          (lambda (rc provider mcp-client policy logger
                   &key develop-state &allow-other-keys)
            (declare (ignore rc provider mcp-client policy logger
                             develop-state))
            (incf run-fn-call-count)
            (case run-fn-call-count
              (1
               (let ((s (make-instance 'cl-harness/src/agent:agent-state)))
                 (setf (cl-harness/src/agent:agent-state-status s)
                       :test-change-request)
                 (setf (cl-harness/src/agent:agent-state-final-action s)
                       (make-instance 'cl-harness/src/action:agent-action
                                      :type :test-change-request
                                      :test-source "(deftest extra-tx (ok t))"
                                      :criteria nil
                                      :rationale "need a new test"))
                 s))
              (otherwise (%make-fake-passed-state)))))
         (review-fn
          (lambda (kind &key &allow-other-keys)
            (cl-harness/src/review:make-review-decision
             :kind kind
             :status :approved
             :feedback "")))
         (step
          (make-instance 'cl-harness/src/planner:plan-step
                         :index 1
                         :issue "x"
                         :test-name "tx"
                         :test-source "(deftest tx (ok t))"
                         :needs-exploration :none))
         (devstate
          (cl-harness/src/state:make-develop-state
           :goal "g"
           :project-root (namestring project-root)
           :system "demo"
           :test-system "demo/tests"
           :review-policy :auto)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let ((result
                  (cl-harness/src/orchestrator::%execute-step
                   step run-fn (namestring project-root) "demo" "demo/tests"
                   :generic-mcp test-file nil nil nil nil nil
                   :develop-state devstate
                   :review-fn review-fn
                   :max-impl-review-revisions 2)))
             (testing "run-fn called twice (test-change + final)"
               (ok (= 2 run-fn-call-count)))
             (testing "final status :passed"
               (ok (eq :passed
                       (cl-harness/src/orchestrator:develop-step-result-status
                        result))))
             (testing "test file extended with extra deftest"
               (let ((content (uiop:read-file-string test-file)))
                 (ok (search "(deftest extra-tx" content))))))
      (when (probe-file test-file) (delete-file test-file)))))
