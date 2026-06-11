;;;; next/tests/judge-test.lisp
;;;;
;;;; Tests for next/src/judge.lisp — the bridge closing SP4's deferred
;;;; item: an LLM provider becomes the review oracle's judge-fn.

(defpackage #:cl-harness-next/tests/judge-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/model
                #:make-openai-provider)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle)
  (:import-from #:cl-harness-next/src/judge
                #:make-judge-fn))

(in-package #:cl-harness-next/tests/judge-test)

(defun %canned-provider (content &optional captured-bodies)
  "Provider whose transport always returns CONTENT; request bodies are
pushed onto the CAPTURED-BODIES list head when supplied."
  (make-openai-provider
   :base-url "http://x/v1" :api-key "k" :model "m"
   :transport
   (lambda (url headers body)
     (declare (ignore url headers))
     (when captured-bodies (push body (car captured-bodies)))
     (values (with-output-to-string (out)
               (yason:encode
                (alexandria:plist-hash-table
                 (list "choices"
                       (list (alexandria:plist-hash-table
                              (list "message"
                                    (alexandria:plist-hash-table
                                     (list "role" "assistant"
                                           "content" content)
                                     :test #'equal)
                                    "finish_reason" "stop")
                              :test #'equal)))
                 :test #'equal)
                out))
             200 (make-hash-table :test #'equal)))))

(deftest judge-fn-returns-content
  (let ((judge (make-judge-fn (%canned-provider "APPROVE fine"))))
    (ok (equal "APPROVE fine" (funcall judge "prompt")))))

(deftest provider-drives-review-oracle-end-to-end
  (let* ((captured (list nil))
         (judge (make-judge-fn (%canned-provider "REJECT: too vague"
                                                 captured)
                               :system-prompt "Be terse."))
         (verdict (evaluate (make-instance 'review-oracle
                                           :profile '(:id :review-plan
                                                      :strictness :strict)
                                           :judge-fn judge)
                            "the plan")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "too vague" (verdict-reason verdict)))
    ;; The system prompt rode along in the request body.
    (ok (search "Be terse." (first (car captured))))))
