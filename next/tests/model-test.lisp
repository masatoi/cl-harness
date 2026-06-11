;;;; next/tests/model-test.lisp
;;;;
;;;; Tests for next/src/model.lisp (adapt-copy of legacy src/model.lisp).
;;;; A recording stub transport replaces the network; pinned behaviors:
;;;; request-body shape, response parsing with usage, failure
;;;; classification (401 / 500), single retry on transient errors.

(defpackage #:cl-harness-next/tests/model-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/model
                #:make-openai-provider
                #:make-chat-message
                #:chat-build-request-body
                #:chat-parse-response
                #:complete-chat
                #:chat-response-content
                #:chat-response-role
                #:chat-response-total-tokens
                #:model-error
                #:model-error-type))

(in-package #:cl-harness-next/tests/model-test)

(defparameter *success-body*
  (concatenate 'string
               "{\"choices\":[{\"message\":{\"role\":\"assistant\","
               "\"content\":\"hi\"},\"finish_reason\":\"stop\"}],"
               "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,"
               "\"total_tokens\":3}}"))

(defun %counted-transport (responses)
  "Return (values transport-fn counter-thunk). Each call pops one
(BODY . STATUS) entry; the last entry repeats."
  (let ((remaining responses)
        (calls 0))
    (values (lambda (url headers body)
              (declare (ignore url headers body))
              (incf calls)
              (destructuring-bind (response-body . status)
                  (if (rest remaining)
                      (pop remaining)
                      (first remaining))
                (values response-body status (make-hash-table :test #'equal))))
            (lambda () calls))))

(defun %provider (responses &key (retry-p t))
  (multiple-value-bind (transport counter) (%counted-transport responses)
    (values (make-openai-provider :base-url "http://x/v1"
                                  :api-key "k" :model "m"
                                  :transport transport
                                  :retry-p retry-p)
            counter)))

(deftest request-body-shape
  (let ((parsed (yason:parse
                 (chat-build-request-body
                  "m" (list (make-chat-message "user" "hi"))
                  :temperature 0.5 :max-tokens 32))))
    (ok (equal "m" (gethash "model" parsed)))
    (ok (equal "user" (gethash "role" (elt (gethash "messages" parsed) 0))))
    (ok (equal "hi" (gethash "content" (elt (gethash "messages" parsed) 0))))
    (ok (= 32 (gethash "max_tokens" parsed)))))

(deftest parse-response-extracts-content-and-usage
  (let ((response (chat-parse-response *success-body*)))
    (ok (equal "hi" (chat-response-content response)))
    (ok (equal "assistant" (chat-response-role response)))
    (ok (= 3 (chat-response-total-tokens response)))))

(deftest complete-chat-roundtrip
  (let ((provider (%provider (list (cons *success-body* 200)))))
    (ok (equal "hi" (chat-response-content
                     (complete-chat provider
                                    (list (make-chat-message "user" "q"))))))))

(deftest auth-failure-classified-and-not-retried
  (multiple-value-bind (provider counter)
      (%provider (list (cons "{\"error\":{\"message\":\"bad key\"}}" 401)))
    (ok (handler-case
            (progn (complete-chat provider
                                  (list (make-chat-message "user" "q")))
                   nil)
          (model-error (e) (eq :auth-failed (model-error-type e)))))
    (ok (= 1 (funcall counter)))))

(deftest server-error-retried-once
  (multiple-value-bind (provider counter)
      (%provider (list (cons "{\"error\":{\"message\":\"oops\"}}" 500)))
    (ok (handler-case
            (progn (complete-chat provider
                                  (list (make-chat-message "user" "q")))
                   nil)
          (model-error (e) (eq :http-server-error (model-error-type e)))))
    (ok (= 2 (funcall counter)))))

(deftest retry-disabled-calls-once
  (multiple-value-bind (provider counter)
      (%provider (list (cons "{\"error\":{\"message\":\"oops\"}}" 500))
                 :retry-p nil)
    (ok (handler-case
            (progn (complete-chat provider
                                  (list (make-chat-message "user" "q")))
                   nil)
          (model-error () t)))
    (ok (= 1 (funcall counter)))))
