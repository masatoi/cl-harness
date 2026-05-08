;;;; tests/transport-test.lisp
;;;;
;;;; Failure-mode coverage for the LLM transport layer
;;;; (docs/plans/2026-05-08-transport-failure-mode-coverage-design.md).
;;;; Stubs the :transport injection point on MAKE-OPENAI-PROVIDER so
;;;; tests are deterministic and require no real HTTP endpoint.

(defpackage #:cl-harness/tests/transport-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/model
                #:%classify-llm-failure))

(in-package #:cl-harness/tests/transport-test)

(deftest classify-llm-failure-401-is-auth-failed
  (ok (eq :auth-failed (%classify-llm-failure 401 "{}"))))

(deftest classify-llm-failure-429-is-rate-limited
  (ok (eq :rate-limited (%classify-llm-failure 429 "{}"))))

(deftest classify-llm-failure-500-is-http-server-error
  (ok (eq :http-server-error (%classify-llm-failure 500 "{}")))
  (ok (eq :http-server-error (%classify-llm-failure 503 "{}"))))

(deftest classify-llm-failure-404-is-http-client-error
  (ok (eq :http-client-error (%classify-llm-failure 404 "{}")))
  (ok (eq :http-client-error (%classify-llm-failure 400 "{}"))))

(deftest classify-llm-failure-non-json-body-is-malformed-response
  (ok (eq :malformed-response (%classify-llm-failure 200 "not-json"))))

(deftest classify-llm-failure-missing-choices-is-malformed-response
  (ok (eq :malformed-response (%classify-llm-failure 200 "{\"x\":1}"))))

(deftest classify-llm-failure-empty-choices-is-malformed-response
  (ok (eq :malformed-response (%classify-llm-failure 200 "{\"choices\":[]}"))))

(deftest classify-llm-failure-success-shape-returns-nil
  (ok (null (%classify-llm-failure
             200
             "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"))))

;; --- complete-chat error wrapping ---------------------------------

(defun %make-stub-provider (transport-fn &key (model "stub"))
  "Build an OPENAI-COMPATIBLE-PROVIDER whose transport is replaced
by TRANSPORT-FN, a 3-arg function (URL HEADERS BODY) returning
(values response-body status response-headers) or raising a
condition."
  (cl-harness/src/model:make-openai-provider
   :base-url "http://stub.invalid/v1"
   :api-key "stub-key"
   :model model
   :transport transport-fn))

(defun %canned-transport (responses)
  "Sequence-of-responses transport. Each call pops one entry. Each
entry is either (BODY STATUS HEADERS) tuple or a CONDITION instance
to SIGNAL via ERROR."
  (let ((remaining responses))
    (lambda (url headers body)
      (declare (ignore url headers body))
      (let ((next (or (pop remaining)
                      (error "stub transport exhausted"))))
        (cond
          ((typep next 'condition) (error next))
          ((listp next)
           (values (first next) (second next)
                   (or (third next) (make-hash-table :test 'equal))))
          (t (error "bad stub response: ~S" next)))))))

(defun %expect-model-error-kind (provider expected-kind)
  "Drive PROVIDER through one COMPLETE-CHAT call. Return T iff a
MODEL-ERROR with :KIND = EXPECTED-KIND was signalled."
  (handler-case
      (progn
        (cl-harness/src/model:complete-chat
         provider
         (list (cl-harness/src/model:make-chat-message "user" "hi")))
        nil)
    (cl-harness/src/model:model-error (c)
      (eq expected-kind (cl-harness/src/model:model-error-type c)))))

(deftest complete-chat-401-signals-auth-failed
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "{\"error\":{\"message\":\"bad key\"}}"
                                401 nil))))))
    (ok (%expect-model-error-kind provider :auth-failed))))

(deftest complete-chat-500-signals-http-server-error
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "{\"error\":{\"message\":\"internal\"}}"
                                500 nil))))))
    (ok (%expect-model-error-kind provider :http-server-error))))

(deftest complete-chat-429-signals-rate-limited
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "{\"error\":{\"message\":\"slow down\"}}"
                                429 nil))))))
    (ok (%expect-model-error-kind provider :rate-limited))))

(deftest complete-chat-malformed-body-signals-malformed-response
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "<html>oops</html>" 200 nil))))))
    (ok (%expect-model-error-kind provider :malformed-response))))

(deftest complete-chat-timeout-signals-transport-timeout
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (make-condition 'usocket:timeout-error :socket nil))))))
    (ok (%expect-model-error-kind provider :transport-timeout))))

(deftest complete-chat-connection-refused-signals-transport-unavailable
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (make-condition 'usocket:connection-refused-error :socket nil))))))
    (ok (%expect-model-error-kind provider :transport-unavailable))))
