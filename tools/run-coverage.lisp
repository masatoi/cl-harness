;;;; run-coverage.lisp — :coverage live demo with cl-harness-next authoring-policy.
;;;;
;;;; The target project's code is already CORRECT; the LLM authors PASSING
;;;; coverage tests, gated GREEN-first (the verify run is scoped to the authored
;;;; test BY NAME, so passed/failed count only the authored test) plus a review
;;;; judge. There is NO fix phase — on review approval the mission finishes.
;;;; Companion to run-tdd.lisp (which drives the red-first :tdd bootstrap).
;;;;
;;;; Run (needs CL_HARNESS_LLM_* + MCP_PROJECT_ROOT = the target project):
;;;;   CL_HARNESS_LLM_BASE_URL=http://host:8000/v1 CL_HARNESS_LLM_API_KEY=... \
;;;;   CL_HARNESS_LLM_MODEL=Qwen/... MCP_PROJECT_ROOT=/path/to/clh-cov-demo \
;;;;   ros run --load tools/run-coverage.lisp
;;;;
;;;; Target project shape (the fixture used to verify this script is `clh-cov-demo`,
;;;; external like run-tdd's `clh-demo`):
;;;;   <root>/clh-cov-demo.asd     defsystems `clh-cov-demo` + `clh-cov-demo/tests`
;;;;   <root>/src/main.lisp        correct code, e.g. (defun add (a b) (+ a b)),
;;;;                               package clh-cov-demo/src/main, (:export #:add)
;;;;   <root>/tests/main-test.lisp skeleton only — defpackage #:clh-cov-demo/tests/main-test
;;;;                               (:use #:cl #:rove #:clh-cov-demo/src/main) + in-package.
;;;;                               The defpackage NAME must equal :test-package below
;;;;                               (clh-cov-demo/tests/main-test); the scoped verify
;;;;                               run-tests "test" arg is <test-package>::cl-harness-authored-tests.
;;;; The dial inserts a `cl-harness-authored-tests` deftest after the in-package
;;;; form, verifies it green (scoped run), and finishes on review approval.

(require :asdf)
(asdf:load-system :cl-harness-next)
(asdf:load-system "cl-harness-next/src/template-policy")

(defpackage #:run-coverage (:use #:cl #:cl-harness-next))
(in-package #:run-coverage)

(defun env (n) (or (uiop:getenv n) (error "missing ~A" n)))

(defun thinking-off ()
  (let ((ctk (make-hash-table :test 'equal)) (top (make-hash-table :test 'equal)))
    (setf (gethash "enable_thinking" ctk) 'yason:false
          (gethash "chat_template_kwargs" top) ctk)
    top))

(defparameter *provider*
  (make-openai-provider :base-url (env "CL_HARNESS_LLM_BASE_URL")
                        :api-key (env "CL_HARNESS_LLM_API_KEY")
                        :model (env "CL_HARNESS_LLM_MODEL")
                        :max-tokens 2048 :extra-body (thinking-off)))

(defparameter *system* "clh-cov-demo")
(defparameter *test-system* "clh-cov-demo/tests")

(defun env-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment :condition :runtime-native :event-log log))

(defun policy-factory (mission)
  (make-instance 'cl-harness-next/src/authoring-policy:authoring-policy
   :mode :coverage
   :goal (mission-goal mission)
   :system *system* :test-system *test-system*
   :source-file "src/main.lisp"
   :test-file "tests/main-test.lisp"
   :test-package "clh-cov-demo/tests/main-test"
   :author-fn (make-judge-fn
               *provider*
               :system-prompt
               cl-harness-next/src/authoring-policy:+test-author-system-prompt+)
   :reviewer (make-instance 'cl-harness-next/src/review-oracle:review-oracle
              :judge-fn (make-judge-fn *provider*)
              :profile (list :id :tests-review :strictness :strict
                             :instructions
                             "Approve only rove tests that genuinely assert the goal (reject tautologies)."))
   :clear-fasls t :k 3))

(defun governor-factory (mission)
  (declare (ignore mission))
  (make-instance 'governor :max-actions 200
                 :max-consecutive-failed-patches nil
                 :max-stalled-verify-cycles nil
                 :max-consecutive-identical-actions nil))

(defun main ()
  (let* ((log-path (merge-pathnames (format nil "cov-~A.jsonl" (get-universal-time))
                                    (uiop:temporary-directory)))
         (mission (make-instance 'mission :id "cov-add"
                    :goal "Add coverage tests asserting that (add a b) returns the sum a+b."
                    :acceptance-criteria (list "clh-cov-demo/tests is green")
                    :log-path log-path))
         (queue (make-instance 'mission-queue)))
    (enqueue-mission queue mission)
    (format t "~&;;; coverage log: ~A~%" log-path) (finish-output)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'env-factory
                     :policy-factory #'policy-factory
                     :governor-factory #'governor-factory
                     :max-steps 200)
      (format t "~&;;; STATUS: ~A~%;;; REASON: ~A~%" status reason)
      (finish-output)
      (uiop:quit (if (eq status :done) 0 1)))))

(main)
