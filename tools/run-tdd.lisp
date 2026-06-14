;;;; run-tdd.lisp — TDD bootstrap with cl-harness-next authoring-policy.
;;;; The LLM authors failing tests (gated RED-first + review); template-fix
;;;; fills the stub. Needs CL_HARNESS_LLM_* + MCP_PROJECT_ROOT(=stub project).
;;;;   ros run --load run-tdd.lisp

(require :asdf)
(asdf:load-system :cl-harness-next)
(asdf:load-system "cl-harness-next/src/template-policy")

(defpackage #:run-tdd (:use #:cl #:cl-harness-next))
(in-package #:run-tdd)

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

(defparameter *system* "clh-demo")
(defparameter *test-system* "clh-demo/tests")

(defun env-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment :condition :runtime-native :event-log log))

(defun policy-factory (mission)
  (make-instance 'cl-harness-next/src/authoring-policy:authoring-policy
   :mode :tdd
   :goal (mission-goal mission)
   :system *system* :test-system *test-system*
   :source-file "src/main.lisp"
   :test-file "tests/main-test.lisp"
   :test-package "clh-demo/tests/main-test"
   :author-fn (make-judge-fn
               *provider*
               :system-prompt
               cl-harness-next/src/authoring-policy:+test-author-system-prompt+)
   :reviewer (make-instance 'cl-harness-next/src/review-oracle:review-oracle
              :judge-fn (make-judge-fn *provider*)
              :profile (list :id :tests-review :strictness :strict
                             :instructions
                             "Approve only rove tests that genuinely assert the goal."))
   :fix-policy (make-instance 'cl-harness-next/src/template-policy:template-fix-policy
                :system *system* :test-system *test-system*
                :snippet-fn (make-judge-fn
                             *provider*
                             :system-prompt
                             cl-harness-next/src/template-policy:+template-snippet-system-prompt+)
                :source-files (list "src/main.lisp") :clear-fasls t :k 3)
   :clear-fasls t :k 3))

(defun governor-factory (mission)
  (declare (ignore mission))
  (make-instance 'governor :max-actions 300
                 :max-consecutive-failed-patches nil
                 :max-stalled-verify-cycles nil
                 :max-consecutive-identical-actions nil))

(defun main ()
  (let* ((log-path (merge-pathnames (format nil "tdd-~A.jsonl" (get-universal-time))
                                    (uiop:temporary-directory)))
         (mission (make-instance 'mission :id "tdd-add"
                    :goal "Implement (add a b) to return the sum a+b, with tests."
                    :acceptance-criteria (list "clh-demo/tests is green")
                    :log-path log-path))
         (queue (make-instance 'mission-queue)))
    (enqueue-mission queue mission)
    (format t "~&;;; tdd log: ~A~%" log-path) (finish-output)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'env-factory
                     :policy-factory #'policy-factory
                     :governor-factory #'governor-factory
                     :max-steps 300)
      (format t "~&;;; STATUS: ~A~%;;; REASON: ~A~%" status reason)
      (finish-output)
      (uiop:quit (if (eq status :done) 0 1)))))

(main)
