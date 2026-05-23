;;;; tests/model-test.lisp
;;;;
;;;; Phase 1 unit tests for the OpenAI-compatible chat client (PRD §8.2,
;;;; §10.2, §10.3). Pure builder/parser tests plus a stub-transport
;;;; lifecycle test. A real roundtrip is gated behind the
;;;; CL_HARNESS_INTEGRATION_LLM env var (skipped by default).

(defpackage #:cl-harness/tests/model-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/model
                #:openai-compatible-provider
                #:make-openai-provider
                #:provider-base-url
                #:provider-api-key
                #:provider-model
                #:provider-default-temperature
                #:provider-default-max-tokens
                #:provider-transport
                #:make-chat-message
                #:chat-response
                #:chat-response-content
                #:chat-response-role
                #:chat-response-finish-reason
                #:chat-response-prompt-tokens
                #:chat-response-completion-tokens
                #:chat-response-total-tokens
                #:model-error
                #:model-error-message
                #:chat-build-request-body
                #:chat-parse-response
                #:complete-chat))

(in-package #:cl-harness/tests/model-test)

(deftest chat-build-request-body-shape
  (testing "encodes model, messages, temperature, max_tokens"
    (let* ((messages (list (make-chat-message "system" "be brief")
                           (make-chat-message "user" "hi")))
           (s (chat-build-request-body "gpt-4o-mini" messages
                                       :temperature 0.2 :max-tokens 64))
           (parsed (yason:parse s)))
      (ok (equal "gpt-4o-mini" (gethash "model" parsed)))
      (let ((msgs (gethash "messages" parsed)))
        (ok (= 2 (length msgs)))
        (ok (equal "system" (gethash "role" (elt msgs 0))))
        (ok (equal "be brief" (gethash "content" (elt msgs 0))))
        (ok (equal "user" (gethash "role" (elt msgs 1))))
        (ok (equal "hi" (gethash "content" (elt msgs 1)))))
      (ok (= 0.2 (gethash "temperature" parsed)))
      (ok (= 64 (gethash "max_tokens" parsed)))))
  (testing "omits temperature and max_tokens when nil"
    (let* ((messages (list (make-chat-message "user" "yo")))
           (parsed (yason:parse
                    (chat-build-request-body "m" messages
                                             :temperature nil :max-tokens nil))))
      (multiple-value-bind (val present) (gethash "temperature" parsed)
        (declare (ignore val))
        (ok (not present)))
      (multiple-value-bind (val present) (gethash "max_tokens" parsed)
        (declare (ignore val))
        (ok (not present))))))

(deftest chat-parse-response-extracts-content-and-usage
  (testing "happy path returns content, role, finish-reason, token usage"
    (let ((r (chat-parse-response
              "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hi there\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}")))
      (ok (typep r 'chat-response))
      (ok (equal "hi there" (chat-response-content r)))
      (ok (equal "assistant" (chat-response-role r)))
      (ok (equal "stop" (chat-response-finish-reason r)))
      (ok (= 12 (chat-response-prompt-tokens r)))
      (ok (= 3 (chat-response-completion-tokens r)))
      (ok (= 15 (chat-response-total-tokens r)))))
  (testing "missing usage block leaves token slots NIL"
    (let ((r (chat-parse-response
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":\"stop\"}]}")))
      (ok (null (chat-response-prompt-tokens r)))
      (ok (null (chat-response-total-tokens r)))))
  (testing "error envelope signals model-error"
    (ok (handler-case
            (progn
              (chat-parse-response
               "{\"error\":{\"message\":\"bad key\",\"type\":\"auth\"}}")
              nil)
          (model-error (c)
            (search "bad key" (model-error-message c)))))))

(deftest openai-provider-construction-defaults
  (let ((p (make-openai-provider :base-url "http://localhost:8080/v1"
                                 :api-key "sk-fake"
                                 :model "demo"
                                 :temperature 0.1
                                 :max-tokens 32)))
    (ok (typep p 'openai-compatible-provider))
    (ok (equal "http://localhost:8080/v1" (provider-base-url p)))
    (ok (equal "sk-fake" (provider-api-key p)))
    (ok (equal "demo" (provider-model p)))
    (ok (= 0.1 (provider-default-temperature p)))
    (ok (= 32 (provider-default-max-tokens p)))))

(deftest openai-provider-default-max-tokens-is-8192
  ;; Backlog #33: cap pathological generation by defaulting max-tokens
  ;; to a safe upper bound (~2x typical legitimate response of 4k).
  (let ((p (make-openai-provider :base-url "http://localhost:8080/v1"
                                 :api-key "sk-fake"
                                 :model "demo")))
    (ok (= 8192 (provider-default-max-tokens p))
        "default max-tokens is 8192 when caller omits the kwarg"))
  (let ((p (make-openai-provider :base-url "http://localhost:8080/v1"
                                 :api-key "sk-fake"
                                 :model "demo"
                                 :max-tokens nil)))
    (ok (null (provider-default-max-tokens p))
        "explicit :max-tokens nil defers to server default")))

(deftest openai-provider-accepts-read-timeout-kwarg
  ;; Backlog #32: per-provider read-timeout wraps the default transport
  ;; in a closure that passes the timeout to dexador. Custom transport
  ;; takes priority (test stubs / recording transports must keep working).
  (testing "no kwarg: uses default transport function directly"
    (let ((p (make-openai-provider :base-url "http://x/v1"
                                   :api-key "k" :model "m")))
      (ok (eq #'cl-harness/src/model::default-llm-transport
              (provider-transport p)))))
  (testing ":read-timeout supplied wraps default transport in a closure"
    (let ((p (make-openai-provider :base-url "http://x/v1"
                                   :api-key "k" :model "m"
                                   :read-timeout 30)))
      (ok (functionp (provider-transport p)))
      (ok (not (eq #'cl-harness/src/model::default-llm-transport
                   (provider-transport p)))
          "wrapper is a fresh closure, not the bare function")))
  (testing "explicit transport beats :read-timeout (test-stub takes priority)"
    (let* ((stub (lambda (u h b) (declare (ignore u h b)) (values "{}" 200 nil)))
           (p (make-openai-provider :base-url "http://x/v1"
                                    :api-key "k" :model "m"
                                    :transport stub
                                    :read-timeout 30)))
      (ok (eq stub (provider-transport p))
          ":transport overrides :read-timeout"))))

(deftest complete-chat-roundtrip-with-stub-transport
  (let* ((capture (cons nil nil))
         (transport (lambda (url headers body)
                      (push (list :url url :headers headers :body body)
                            (car capture))
                      (values
                       "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}"
                       200
                       (make-hash-table :test 'equal))))
         (p (make-openai-provider :base-url "http://example.test/v1"
                                  :api-key "sk-stub"
                                  :model "demo"
                                  :temperature 0.3
                                  :max-tokens 16
                                  :transport transport))
         (resp (complete-chat p
                              (list (make-chat-message "user" "ping")))))
    (testing "URL targets /v1/chat/completions on the configured base"
      (let ((req (first (car capture))))
        (ok (equal "http://example.test/v1/chat/completions"
                   (getf req :url)))))
    (testing "Authorization and Content-Type headers are set"
      (let* ((req (first (car capture)))
             (h (getf req :headers)))
        (ok (equal "Bearer sk-stub" (gethash "Authorization" h)))
        (ok (equal "application/json" (gethash "Content-Type" h)))))
    (testing "request body uses provider model and default temperature/max-tokens"
      (let* ((req (first (car capture)))
             (parsed (yason:parse (getf req :body))))
        (ok (equal "demo" (gethash "model" parsed)))
        (ok (= 0.3 (gethash "temperature" parsed)))
        (ok (= 16 (gethash "max_tokens" parsed)))))
    (testing "response is parsed into chat-response with usage"
      (ok (typep resp 'chat-response))
      (ok (equal "ok" (chat-response-content resp)))
      (ok (= 3 (chat-response-total-tokens resp)))))
  (testing "call-site overrides take precedence over provider defaults"
    (let* ((capture (cons nil nil))
           (transport (lambda (url headers body)
                        (declare (ignore url headers))
                        (setf (car capture) body)
                        (values
                         "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}"
                         200
                         (make-hash-table :test 'equal))))
           (p (make-openai-provider :base-url "http://example.test/v1"
                                    :api-key "sk-stub"
                                    :model "demo"
                                    :temperature 0.3
                                    :max-tokens 16
                                    :transport transport)))
      (complete-chat p (list (make-chat-message "user" "yo"))
                     :temperature 0.9 :max-tokens 4)
      (let ((parsed (yason:parse (car capture))))
        (ok (= 0.9 (gethash "temperature" parsed)))
        (ok (= 4 (gethash "max_tokens" parsed)))))))

(deftest chat-build-request-body-includes-reasoning-effort
  (testing "reasoning-effort kwarg lands as reasoning_effort in the JSON body"
    (let* ((messages (list (make-chat-message "user" "hi")))
           (parsed (yason:parse
                    (chat-build-request-body "gpt-oss-20b" messages
                                             :reasoning-effort "low"))))
      (ok (equal "low" (gethash "reasoning_effort" parsed)))))
  (testing "omitted reasoning-effort produces no field"
    (let ((parsed (yason:parse
                   (chat-build-request-body
                    "m" (list (make-chat-message "user" "hi"))))))
      (multiple-value-bind (val present) (gethash "reasoning_effort" parsed)
        (declare (ignore val))
        (ok (not present))))))

(deftest chat-build-request-body-merges-extra-body
  (testing "extra-body hash-table fields land at the top level"
    (let* ((extra (alexandria:alist-hash-table
                   '(("tool_choice" . "none")
                     ("custom_field" . 42))
                   :test 'equal))
           (parsed (yason:parse
                    (chat-build-request-body
                     "m" (list (make-chat-message "user" "hi"))
                     :extra-body extra))))
      (ok (equal "none" (gethash "tool_choice" parsed)))
      (ok (= 42 (gethash "custom_field" parsed)))))
  (testing "extra-body alist also accepted"
    (let ((parsed (yason:parse
                   (chat-build-request-body
                    "m" (list (make-chat-message "user" "hi"))
                    :extra-body '(("seed" . 1234))))))
      (ok (= 1234 (gethash "seed" parsed))))))

(deftest complete-chat-applies-provider-defaults-for-reasoning-and-extra
  (let* ((capture (cons nil nil))
         (transport (lambda (u h b)
                      (declare (ignore u h))
                      (setf (car capture) b)
                      (values
                       "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}"
                       200 (make-hash-table :test 'equal))))
         (extra (alexandria:alist-hash-table '(("tool_choice" . "none"))
                                             :test 'equal))
         (p (make-openai-provider :base-url "http://example.test/v1"
                                  :api-key "k" :model "gpt-oss-20b"
                                  :reasoning-effort "medium"
                                  :extra-body extra
                                  :transport transport)))
    (complete-chat p (list (make-chat-message "user" "hi")))
    (let ((parsed (yason:parse (car capture))))
      (testing "reasoning_effort propagates from provider default"
        (ok (equal "medium" (gethash "reasoning_effort" parsed))))
      (testing "extra-body merges into request body"
        (ok (equal "none" (gethash "tool_choice" parsed)))))))

(deftest complete-chat-call-site-overrides-reasoning-and-extra
  (let* ((capture (cons nil nil))
         (transport (lambda (u h b)
                      (declare (ignore u h))
                      (setf (car capture) b)
                      (values
                       "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}"
                       200 (make-hash-table :test 'equal))))
         (p (make-openai-provider :base-url "http://example.test/v1"
                                  :api-key "k" :model "m"
                                  :reasoning-effort "low"
                                  :transport transport)))
    (complete-chat p (list (make-chat-message "user" "hi"))
                   :reasoning-effort "high"
                   :extra-body '(("seed" . 7)))
    (let ((parsed (yason:parse (car capture))))
      (ok (equal "high" (gethash "reasoning_effort" parsed)))
      (ok (= 7 (gethash "seed" parsed))))))

(deftest complete-chat-live-roundtrip
  (testing "live OpenAI-compatible probe (CL_HARNESS_INTEGRATION_LLM=1)"
    (if (uiop:getenv "CL_HARNESS_INTEGRATION_LLM")
        (let* ((base (or (uiop:getenv "CL_HARNESS_LLM_BASE_URL")
                         "http://localhost:8080/v1"))
               (key (or (uiop:getenv "CL_HARNESS_LLM_API_KEY") "dummy"))
               (model (or (uiop:getenv "CL_HARNESS_LLM_MODEL") "gpt-4o-mini"))
               (p (make-openai-provider :base-url base :api-key key
                                        :model model
                                        :temperature 0.0
                                        :max-tokens 16))
               (resp (complete-chat p
                                    (list (make-chat-message
                                           "user"
                                           "Reply with the single word: pong")))))
          (ok (typep resp 'chat-response))
          (ok (stringp (chat-response-content resp))))
        (skip "set CL_HARNESS_INTEGRATION_LLM=1 to enable"))))
