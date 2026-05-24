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
  (:import-from #:cl-harness/src/state
                #:make-develop-state)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:plan-step-index
                #:plan-step-issue
                #:plan-step-test-name
                #:plan-step-test-source
                #:plan-step-files-to-modify
                ;; v0.4 Phase 1 additions:
                #:plan-step-purpose
                #:plan-step-acceptance-criteria
                #:plan-step-investigation-targets
                #:plan-step-risks
                #:plan-step-needs-exploration
                #:plan-step-adopted-abstractions
                #:plan-step-rejected-abstractions
                #:investigation-target
                #:investigation-target-kind
                #:investigation-target-name
                #:investigation-target-intent
                #:plan-development
                #:parse-predefined-plan
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

;; --- v0.4 Phase 1: enriched plan-step schema -------------------------------

(deftest plan-development-defaults-new-fields-when-absent
  ;; Backward compat: old-style responses (only issue / test_name /
  ;; test_source) must continue to parse, with all v0.4 fields
  ;; defaulting to NIL / :none.
  (let* ((provider (%make-stub-provider
                    :transport (%canned-transport +canonical-plan+)))
         (plan (plan-development "demo" :provider provider)))
    (let ((s (first plan)))
      (ok (null (plan-step-purpose s)))
      (ok (null (plan-step-acceptance-criteria s)))
      (ok (null (plan-step-investigation-targets s)))
      (ok (null (plan-step-risks s)))
      (ok (eq :none (plan-step-needs-exploration s)))
      (ok (null (plan-step-adopted-abstractions s)))
      (ok (null (plan-step-rejected-abstractions s))))))

(defparameter +enriched-plan+
  "{\"steps\":[{
      \"issue\":\"Implement greet under demo package.\",
      \"test_name\":\"greet-says-hello\",
      \"test_source\":\"(deftest greet-says-hello (ok (string= (demo:greet \\\"X\\\") \\\"Hello, X!\\\")))\",
      \"files_to_modify\":[\"src/main.lisp\"],
      \"purpose\":\"Provide a single-arg greeter callable as demo:greet.\",
      \"acceptance_criteria\":[\"greet exists in package demo\",\"greet returns 'Hello, NAME!'\"],
      \"investigation_targets\":[
        {\"kind\":\"package\",\"name\":\"demo\",\"intent\":\"check existing exports\"},
        {\"kind\":\"function\",\"name\":\"format\",\"intent\":\"reuse formatter\"}
      ],
      \"risks\":[\"format directive choice\",\"NAME may be NIL\"],
      \"needs_exploration\":\"lightweight\"
    }]}")

(deftest plan-development-parses-enriched-fields
  (let* ((provider (%make-stub-provider
                    :transport (%canned-transport +enriched-plan+)))
         (plan (plan-development "demo" :provider provider)))
    (let ((s (first plan)))
      (ok (search "single-arg greeter" (plan-step-purpose s)))
      (let ((ac (plan-step-acceptance-criteria s)))
        (ok (= 2 (length ac)))
        (ok (search "exists" (first ac)))
        (ok (search "Hello, NAME" (second ac))))
      (let ((targets (plan-step-investigation-targets s)))
        (ok (= 2 (length targets)))
        (let ((t1 (first targets)))
          (ok (typep t1 'investigation-target))
          (ok (eq :package (investigation-target-kind t1)))
          (ok (equal "demo" (investigation-target-name t1)))
          (ok (search "exports" (investigation-target-intent t1))))
        (let ((t2 (second targets)))
          (ok (eq :function (investigation-target-kind t2)))
          (ok (equal "format" (investigation-target-name t2)))))
      (ok (= 2 (length (plan-step-risks s))))
      (ok (eq :lightweight (plan-step-needs-exploration s))))))

(deftest plan-development-needs-exploration-keyword-mapping
  ;; Each of the three documented levels parses to its keyword.
  (dolist (pair '(("none" . :none)
                  ("lightweight" . :lightweight)
                  ("deep" . :deep)))
    (let* ((body (format nil
                         "{\"steps\":[{\"issue\":\"x\",\"test_name\":\"t\",\"test_source\":\"(deftest t (ok t))\",\"needs_exploration\":~S}]}"
                         (car pair)))
           (provider (%make-stub-provider
                      :transport (%canned-transport body)))
           (plan (plan-development "demo" :provider provider)))
      (ok (eq (cdr pair)
              (plan-step-needs-exploration (first plan)))
          (format nil "~A maps to ~A"
                  (car pair) (cdr pair))))))

(deftest plan-development-rejects-unknown-needs-exploration
  ;; Anything other than none / lightweight / deep is a planner-error.
  (let* ((body "{\"steps\":[{\"issue\":\"x\",\"test_name\":\"t\",\"test_source\":\"(deftest t (ok t))\",\"needs_exploration\":\"someday\"}]}")
         (provider (%make-stub-provider
                    :transport (%canned-transport body))))
    (ok (handler-case
            (progn (plan-development "demo" :provider provider) nil)
          (planner-error (c)
            (and (search "needs_exploration"
                         (planner-error-message c)) t))))))

(deftest plan-development-investigation-targets-empty-array-yields-nil
  (let* ((body "{\"steps\":[{\"issue\":\"x\",\"test_name\":\"t\",\"test_source\":\"(deftest t (ok t))\",\"investigation_targets\":[]}]}")
         (provider (%make-stub-provider
                    :transport (%canned-transport body)))
         (plan (plan-development "demo" :provider provider)))
    (ok (null (plan-step-investigation-targets (first plan))))))

;; --- v0.4 Phase 2: project inventory injection -----------------------------

(deftest plan-development-prepends-project-inventory-to-user-prompt
  ;; When :project-inventory is supplied, the planner's user message
  ;; must contain the inventory verbatim. We capture the request body
  ;; via a custom transport that records what got sent.
  (let* ((captured (cons nil nil))
         (transport
          (lambda (url headers body)
            (declare (ignore url headers))
            (setf (car captured) body)
            (values (%llm-body +canonical-plan+) 200
                    (make-hash-table :test 'equal))))
         (provider (%make-stub-provider :transport transport))
         (inv "Project Inventory~%=================~%System: demo~%(asdf-stuff)"))
    (plan-development "do the thing"
                      :project-root "/tmp/x"
                      :system "demo"
                      :test-system "demo/tests"
                      :provider provider
                      :project-inventory inv)
    (let* ((req (yason:parse (car captured)))
           (messages (gethash "messages" req))
           (user-msg (find-if (lambda (m)
                                (equal "user" (gethash "role" m)))
                              (coerce messages 'list))))
      (ok user-msg "user message present")
      (when user-msg
        (let ((content (gethash "content" user-msg)))
          (ok (search "Project Inventory" content)
              "inventory header present in user prompt")
          (ok (search "(asdf-stuff)" content)
              "inventory body verbatim in user prompt")
          (ok (search "Goal: do the thing" content)
              "goal still appears below inventory"))))))

(deftest plan-development-no-inventory-keeps-original-prompt-shape
  ;; When :project-inventory is omitted (or nil), the user prompt must
  ;; not gain a stray Project Inventory section.
  (let* ((captured (cons nil nil))
         (transport
          (lambda (url headers body)
            (declare (ignore url headers))
            (setf (car captured) body)
            (values (%llm-body +canonical-plan+) 200
                    (make-hash-table :test 'equal))))
         (provider (%make-stub-provider :transport transport)))
    (plan-development "do the thing" :provider provider)
    (let* ((req (yason:parse (car captured)))
           (messages (gethash "messages" req))
           (user-msg (find-if (lambda (m)
                                (equal "user" (gethash "role" m)))
                              (coerce messages 'list)))
           (content (gethash "content" user-msg)))
      (ok (not (search "Project Inventory" content))))))

;; --- Phase C.6: develop-state opt-in wiring -----------------------------

(deftest plan-development-uses-context-view-when-develop-state-supplied
  ;; When :develop-state is supplied, the user-prompt builder routes
  ;; through context-view->string :planning, which renders the goal
  ;; under a "## Goal" heading and the inventory under a
  ;; "## Project inventory" heading (instead of the legacy
  ;; "Goal: ..." line and bare inventory block). Standalone callers
  ;; that pass no :develop-state keep the old shape -- covered by the
  ;; pre-existing tests above.
  (let* ((captured (cons nil nil))
         (transport
          (lambda (url headers body)
            (declare (ignore url headers))
            (setf (car captured) body)
            (values (%llm-body +canonical-plan+) 200
                    (make-hash-table :test 'equal))))
         (provider (%make-stub-provider :transport transport))
         (s (make-develop-state :goal "g"
                                :project-root "/tmp/"
                                :system "demo"
                                :test-system "demo/tests"
                                :project-inventory "[INVENTORY-MARKER]")))
    (plan-development "g"
                      :provider provider
                      :project-root "/tmp/"
                      :system "demo"
                      :test-system "demo/tests"
                      :project-inventory "[INVENTORY-MARKER]"
                      :develop-state s)
    (let* ((req (yason:parse (car captured)))
           (messages (gethash "messages" req))
           (user-msg (find-if (lambda (m)
                                (equal "user" (gethash "role" m)))
                              (coerce messages 'list)))
           (content (gethash "content" user-msg)))
      (ok user-msg "user message present")
      (ok (search "## Goal" content)
          "context-view :planning Goal heading present")
      (ok (search "## Project inventory" content)
          "context-view :planning Project inventory heading present")
      (ok (search "[INVENTORY-MARKER]" content)
          "inventory body verbatim in user prompt"))))

(deftest default-planner-system-prompt-includes-qualified-guidance
  (testing "system prompt mentions package-qualified test references"
    (ok (search "package-qualified"
                cl-harness/src/planner::+default-planner-system-prompt+)))
  (testing "system prompt includes the counter:make-counter example"
    (ok (search "counter:make-counter"
                cl-harness/src/planner::+default-planner-system-prompt+))))

(deftest default-planner-system-prompt-bans-non-standard-test-helpers
  ;; Backlog #50: 2026-05-24 JSONL aggregate analysis observed planner-
  ;; generated tests calling MOP / introspection helpers that the
  ;; tests/main-test package does NOT inherit:
  ;;   class-slots, arglist, function-lambda-list, exported-symbols.
  ;; Each occurrence leaves the step unsolvable (the agent will not
  ;; reimplement standard library glue). Prompt must explicitly forbid
  ;; these names.
  (let ((prompt cl-harness/src/planner::+default-planner-system-prompt+))
    (testing "prompt names the forbidden helpers"
      (ok (search "class-slots" prompt))
      (ok (search "arglist" prompt))
      (ok (search "function-lambda-list" prompt))
      (ok (search "exported-symbols" prompt)))
    (testing "prompt mentions standard CL / rove restriction"
      (ok (search "standard CL" prompt)))))

(deftest parse-predefined-plan-converts-hashtable-list-to-plan-steps
  ;; backlog #46: develop-task.json may carry a predefined_plan array
  ;; (parsed by yason as list-or-vector of hash-tables) which orchestrator's
  ;; develop uses to bypass the planner LLM call. parse-predefined-plan
  ;; converts the raw parsed value into a list of plan-step instances
  ;; with the same semantics as %hash-to-step in the LLM-driven path.
  (let* ((raw-json
          "[{\"issue\":\"foo\",\"test_name\":\"foo-test\",\"test_source\":\"(deftest foo-test (ok t))\"},
            {\"issue\":\"bar\",\"test_name\":\"bar-test\",\"test_source\":\"(deftest bar-test (ok t))\",\"files_to_modify\":[\"src/x.lisp\"]}]")
         (parsed (yason:parse raw-json))
         (plan (parse-predefined-plan parsed)))
    (ok (= 2 (length plan)))
    (let ((step0 (first plan)))
      (ok (= 0 (plan-step-index step0)))
      (ok (equal "foo-test" (plan-step-test-name step0)))
      (ok (equal "foo" (plan-step-issue step0))))
    (let ((step1 (second plan)))
      (ok (= 1 (plan-step-index step1)))
      (ok (equal "bar-test" (plan-step-test-name step1)))
      (ok (equal '("src/x.lisp") (plan-step-files-to-modify step1))))))

(deftest parse-predefined-plan-signals-on-non-list-input
  ;; Defensive: a scalar or hash-table at the top level is not a valid
  ;; predefined plan; signal planner-error rather than silently swallowing.
  (ok (handler-case (progn (parse-predefined-plan "not a list") nil)
        (planner-error () t))))

(deftest parse-predefined-plan-accepts-empty-list
  ;; An empty predefined plan is allowed (caller can recover with
  ;; replan / give-up); parser should not error.
  (ok (null (parse-predefined-plan '()))))
