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

(deftest complete-chat-generic-socket-error-signals-transport-unavailable
  ;; usocket:socket-error is the parent of connection-refused-error.
  ;; This deftest fires the parent class to ensure the handler arm
  ;; catches DNS / host-unreachable / network-unreachable / etc., not
  ;; just connection-refused.
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (make-condition 'usocket:socket-error
                                          :socket nil))))))
    (ok (%expect-model-error-kind provider :transport-unavailable))))

(deftest complete-chat-200-with-error-envelope-preserves-openai-type
  ;; %classify-llm-failure should DEFER to chat-parse-response when the
  ;; body has an OpenAI {"error": {"type": ...}} envelope, so the
  ;; pre-existing model-error :kind <openai-type> path stays
  ;; reachable.
  (let* ((envelope-body
           "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad\"}}")
         (provider (%make-stub-provider
                    (%canned-transport
                     (list (list envelope-body 200 nil))))))
    (ok (handler-case
            (progn
              (cl-harness/src/model:complete-chat
               provider
               (list (cl-harness/src/model:make-chat-message "user" "hi")))
              nil)
          (cl-harness/src/model:model-error (c)
            ;; The envelope's "type" string lands as the :kind value.
            (equal "invalid_request_error"
                   (cl-harness/src/model:model-error-type c)))))))

;; --- end-to-end develop with stub transport ---------------------
;;
;; These tests drive cl-harness/src/orchestrator:develop with a stub
;; provider whose %canned-transport returns a failure-shaped response
;; on the FIRST LLM call (the planner). Since the orchestrator's first
;; LLM-bearing operation is plan-development, a model-error raised
;; there should be caught at the top of develop and recorded as
;; :status :error :reason <kw> on develop-result.

(defun %make-test-file (path)
  "Create an empty rove test file at PATH so the orchestrator's
test-file plumbing doesn't trip on file-not-found."
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (format s "(defpackage #:transport-test/main (:use #:cl #:rove))~%~%")
    (format s "(in-package #:transport-test/main)~%"))
  path)

(defun %tmp-transport-test-path (label)
  (merge-pathnames
   (format nil "transport-test-~A-~A.lisp" label (get-universal-time))
   (uiop:default-temporary-directory)))

(defun %drive-develop-with-canned-response (responses)
  "Run cl-harness/src/orchestrator:develop with a stub provider
returning RESPONSES. Returns the develop-result. RESPONSES is a list
suitable for %CANNED-TRANSPORT (each entry is (BODY STATUS HEADERS)
or a CONDITION instance)."
  (let ((tf (%make-test-file (%tmp-transport-test-path "develop")))
        (provider (%make-stub-provider (%canned-transport responses))))
    (unwind-protect
         (cl-harness/src/orchestrator:develop
          "smoke goal"
          :project-root (namestring (uiop:default-temporary-directory))
          :system "demo"
          :test-system "demo/tests"
          :test-file tf
          :provider provider
          :mcp-client nil
          :run-fn (lambda (&rest args)
                    (declare (ignore args))
                    (cl-harness/src/agent::%make-agent-state-for-tests
                     :status :passed))
          :explore-fn nil)
      (when (probe-file tf) (delete-file tf)))))

(deftest develop-with-401-yields-error-auth-failed
  (let ((result (%drive-develop-with-canned-response
                 (list (list "{\"error\":{\"message\":\"bad key\"}}"
                             401 nil)))))
    (ok (eq :error (cl-harness/src/orchestrator:develop-result-status
                    result)))
    (ok (eq :auth-failed (cl-harness/src/orchestrator:develop-result-reason
                          result)))))

(deftest develop-with-500-yields-error-http-server-error
  (let ((result (%drive-develop-with-canned-response
                 (list (list "{\"error\":{\"message\":\"oops\"}}"
                             500 nil)))))
    (ok (eq :error (cl-harness/src/orchestrator:develop-result-status
                    result)))
    (ok (eq :http-server-error
            (cl-harness/src/orchestrator:develop-result-reason result)))))

(deftest develop-with-429-yields-error-rate-limited
  (let ((result (%drive-develop-with-canned-response
                 (list (list "{\"error\":{\"message\":\"slow\"}}"
                             429 nil)))))
    (ok (eq :error (cl-harness/src/orchestrator:develop-result-status
                    result)))
    (ok (eq :rate-limited
            (cl-harness/src/orchestrator:develop-result-reason result)))))

(deftest develop-with-malformed-body-yields-error-malformed-response
  (let ((result (%drive-develop-with-canned-response
                 (list (list "<html>oops</html>" 200 nil)))))
    (ok (eq :error (cl-harness/src/orchestrator:develop-result-status
                    result)))
    (ok (eq :malformed-response
            (cl-harness/src/orchestrator:develop-result-reason result)))))
