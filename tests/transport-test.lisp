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
