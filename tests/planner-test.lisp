;;;; tests/planner-test.lisp
;;;;
;;;; Phase P1 unit tests for src/planner.lisp
;;;; (docs/notes/2026-05-06-planner-orchestrator.md). Drives the
;;;; planner through a stub LLM provider, asserts plan-step parsing,
;;;; markdown-fence tolerance, and error paths.

(defpackage #:cl-harness/tests/planner-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/model
                #:make-openai-provider)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:plan-step-index
                #:plan-step-issue
                #:plan-step-test-name
                #:plan-step-test-source
                #:plan-step-files-to-modify
                #:plan-development
                #:planner-error
                #:planner-error-message))

(in-package #:cl-harness/tests/planner-test)

(defun %escape-json (s)
  (with-output-to-string (out) (yason:encode s out)))

(defun %llm-body (content)
  "Wrap CONTENT into an OpenAI-style chat completion response."
  (format nil
          "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":~A},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
          (%escape-json content)))

(defun %canned-transport (content)
  (lambda (url headers body)
    (declare (ignore url headers body))
    (values (%llm-body content) 200 (make-hash-table :test 'equal))))

(defun %make-stub-provider (&key transport)
  (make-openai-provider :base-url "http://example.test/v1"
                        :api-key "k"
                        :model "demo"
                        :temperature 0.0
                        :max-tokens 16
                        :transport transport))

(defparameter +canonical-plan+
  "{\"steps\":[{\"issue\":\"Add a greet function under package demo that takes a NAME and returns \\\"Hello, NAME!\\\".\",\"test_name\":\"greet-says-hello\",\"test_source\":\"(deftest greet-says-hello (ok (string= \\\"Hello, Alice!\\\" (demo:greet \\\"Alice\\\"))))\",\"files_to_modify\":[\"src/main.lisp\",\"tests/main-test.lisp\"]}]}")

(deftest plan-development-parses-canonical-plan
  ;; A planner that returns the schema verbatim must produce one
  ;; PLAN-STEP with all four fields populated.
  (let* ((provider (%make-stub-provider
                    :transport (%canned-transport +canonical-plan+)))
         (plan (plan-development "demo goal"
                                 :project-root "/tmp/proj"
                                 :system "demo"
                                 :test-system "demo/tests"
                                 :provider provider)))
    (ok (= 1 (length plan)))
    (let ((step (first plan)))
      (ok (typep step 'plan-step))
      (ok (= 0 (plan-step-index step)))
      (ok (search "greet function" (plan-step-issue step)))
      (ok (equal "greet-says-hello" (plan-step-test-name step)))
      (ok (search "(deftest greet-says-hello"
                  (plan-step-test-source step)))
      (ok (equal '("src/main.lisp" "tests/main-test.lisp")
                 (plan-step-files-to-modify step))))))

(deftest plan-development-strips-markdown-code-fence
  ;; Every chat model occasionally wraps its JSON in ```json fences.
  ;; Planner must drop the fence and parse the inner JSON.
  (let* ((fenced (format nil "```json~%~A~%```" +canonical-plan+))
         (provider (%make-stub-provider
                    :transport (%canned-transport fenced)))
         (plan (plan-development "demo" :provider provider)))
    (ok (= 1 (length plan)))
    (ok (equal "greet-says-hello"
               (plan-step-test-name (first plan))))))

(deftest plan-development-returns-multiple-steps-in-order
  (let* ((multi
          "{\"steps\":[
            {\"issue\":\"Step A\",\"test_name\":\"a-test\",\"test_source\":\"(deftest a-test (ok t))\",\"files_to_modify\":[]},
            {\"issue\":\"Step B (depends on A)\",\"test_name\":\"b-test\",\"test_source\":\"(deftest b-test (ok t))\",\"files_to_modify\":[\"src/x.lisp\"]},
            {\"issue\":\"Step C\",\"test_name\":\"c-test\",\"test_source\":\"(deftest c-test (ok t))\",\"files_to_modify\":[]}
          ]}")
         (provider (%make-stub-provider
                    :transport (%canned-transport multi)))
         (plan (plan-development "demo" :provider provider)))
    (ok (= 3 (length plan)))
    (ok (equal '(0 1 2) (mapcar #'plan-step-index plan)))
    (ok (equal '("a-test" "b-test" "c-test")
               (mapcar #'plan-step-test-name plan)))
    ;; Step 2's files-to-modify hint propagates as a list of strings.
    (ok (equal '("src/x.lisp")
               (plan-step-files-to-modify (second plan))))))

(deftest plan-development-signals-on-non-json
  ;; A model that ignores the schema and replies in prose must not
  ;; produce silent plan-step garbage.
  (let ((provider (%make-stub-provider
                   :transport (%canned-transport
                               "I don't understand. Please clarify."))))
    (ok (handler-case
            (progn (plan-development "demo" :provider provider) nil)
          (planner-error (c)
            (and (search "JSON" (planner-error-message c)) t))))))

(deftest plan-development-signals-on-missing-steps-key
  ;; The schema requires a top-level "steps" array. A response that
  ;; satisfies json.parse but lacks "steps" must be rejected.
  (let ((provider (%make-stub-provider
                   :transport (%canned-transport
                               "{\"plan\":[{\"issue\":\"x\"}]}"))))
    (ok (handler-case
            (progn (plan-development "demo" :provider provider) nil)
          (planner-error (c)
            (and (search "steps" (planner-error-message c)) t))))))

(deftest plan-development-tolerates-missing-files-to-modify
  ;; files_to_modify is optional; planner must default it to an
  ;; empty list when absent rather than erroring.
  (let* ((minimal
          "{\"steps\":[{\"issue\":\"foo\",\"test_name\":\"foo-test\",\"test_source\":\"(deftest foo-test (ok t))\"}]}")
         (provider (%make-stub-provider
                    :transport (%canned-transport minimal)))
         (plan (plan-development "demo" :provider provider)))
    (ok (= 1 (length plan)))
    (ok (null (plan-step-files-to-modify (first plan))))))

(deftest plan-development-rejects-step-missing-required-fields
  ;; issue, test_name, test_source are required; missing any of them
  ;; signals planner-error.
  (let* ((bad "{\"steps\":[{\"issue\":\"only\"}]}")
         (provider (%make-stub-provider
                    :transport (%canned-transport bad))))
    (ok (handler-case
            (progn (plan-development "demo" :provider provider) nil)
          (planner-error (c)
            (and (search "test_name" (planner-error-message c)) t))))))
