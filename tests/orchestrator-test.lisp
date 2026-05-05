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
                #:validate-test-source
                #:materialize-test-source
                #:plan-step->run-config
                #:execute-plan))

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
                isolate-asdf-p)
    (declare (ignore provider mcp-client policy logger
                     clean-verify-p dry-run-p
                     before-clean-verify-fn isolate-asdf-p))
    (push (run-config-issue config) (car calls))
    (let ((status (or (pop (car outcomes)) :passed)))
      (alist-hash-table
       `(("status" . ,status)
         ("turn" . 1)
         ("token-total" . 100))
       :test 'equal))))

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
