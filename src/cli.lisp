;;;; src/cli.lisp
;;;;
;;;; PRD §8.1 CLI skeleton. Phase 0 ships only entrypoints that parse a tiny
;;;; argv subset into a RUN-CONFIG and report "not implemented" for the agent
;;;; loop itself. A real argument parser (clingon/unix-opts) lands in Phase 1.

(defpackage #:cl-harness/src/cli
  (:use #:cl)
  (:import-from #:cl-harness/src/config
                #:make-run-config
                #:run-limits
                #:make-default-limits
                #:run-limits-max-turns
                #:run-limits-max-tool-calls
                #:run-limits-max-patches
                #:run-limits-max-read-files
                #:run-limits-max-repl-evals
                #:run-limits-max-wall-clock-seconds
                #:run-limits-max-action-parse-errors)
  (:import-from #:cl-harness/src/log
                #:open-run-logger
                #:close-run-logger)
  (:import-from #:cl-harness/src/mcp
                #:close-mcp-client)
  (:import-from #:cl-harness/src/mcp-resolve
                #:resolve-and-build-mcp-client)
  (:import-from #:cl-harness/src/model
                #:make-openai-provider)
  (:import-from #:cl-harness/src/policy
                #:make-tool-policy)
  (:import-from #:cl-harness/src/agent
                #:run-agent
                #:format-final-report)
  (:import-from #:cl-harness/src/bench
                #:run-benchmark-suite
                #:format-suite-report)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-result-status
                #:develop-result-replan-count
                #:develop-result-step-results
                #:develop-result-limit-hit
                #:develop-result-integration-issues
                #:develop-result-develop-state
                #:develop-result-reason)
  (:import-from #:cl-harness/src/report
                #:format-develop-state-report)
  (:import-from #:cl-harness/src/integration
                #:format-integration-issues-markdown)
  (:import-from #:cl-harness/src/inventory
                #:gather-project-inventory)
  (:export #:fix
           #:bench
           #:develop
           #:format-develop-report
           #:format-develop-report-markdown
           #:format-develop-report-structured
           #:not-implemented-error))

(in-package #:cl-harness/src/cli)

(define-condition not-implemented-error (error)
  ((command :initarg :command :reader not-implemented-error-command))
  (:report (lambda (c stream)
             (format stream "cl-harness ~A: not implemented yet (Phase 0 skeleton)."
                     (not-implemented-error-command c)))))

(defun fix
       (
        &key project-root system test-system issue (condition :generic-mcp)
        mcp-url mcp-stdio mcp-command base-url api-key model (temperature 0.0)
        max-tokens reasoning-effort extra-body (retry-p t) dry-run-p log-path
        (log-llm-requests nil))
  "Run the Phase 2 basic fix loop.

Required keyword arguments mirror PRD §11.1: PROJECT-ROOT, SYSTEM,
TEST-SYSTEM, ISSUE. The LLM endpoint is taken from the keyword args or
the CL_HARNESS_LLM_BASE_URL / CL_HARNESS_LLM_API_KEY / CL_HARNESS_LLM_MODEL
environment variables.

The cl-mcp connection is resolved (highest priority first) by:
:MCP-URL > $CL_HARNESS_MCP_URL > :MCP-COMMAND > :MCP-STDIO >
$CL_HARNESS_MCP_COMMAND > built-in stdio default. With nothing
configured the harness spawns its own cl-mcp subprocess via
*DEFAULT-STDIO-COMMAND* and tears it down on exit, so each FIX call
runs against a private worker pool — see
docs/notes/2026-05-06-stdio-transport.md for why that matters.
Pass :MCP-URL or set $CL_HARNESS_MCP_URL to opt back into a shared
HTTP server.

REASONING-EFFORT, when non-NIL, is sent as the OpenAI o1 / gpt-oss
\"reasoning_effort\" field (typically \"low\"/\"medium\"/\"high\").
EXTRA-BODY merges arbitrary top-level keys into every chat-completions
request body (hash-table or alist of (string . value)) — useful for
endpoint quirks like Groq gpt-oss-20b's need for explicit
\"tool_choice\":\"none\" / \"tools\":[].

LOG-LLM-REQUESTS, when non-NIL, instructs the run logger to emit full
:llm-request JSONL events containing the complete message history
sent to the model on each chat completion call.

Returns the populated AGENT-STATE."
  (let* ((config
          (make-run-config :project-root project-root :system system
           :test-system test-system :issue issue :condition condition
           :log-llm-requests log-llm-requests))
         (effective-base-url
          (or base-url (uiop/os:getenv "CL_HARNESS_LLM_BASE_URL")
              (error "fix: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key (uiop/os:getenv "CL_HARNESS_LLM_API_KEY")
              (error "fix: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model (uiop/os:getenv "CL_HARNESS_LLM_MODEL")
              (error "fix: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider
          (make-openai-provider :base-url effective-base-url :api-key
           effective-api-key :model effective-model :temperature temperature
           :max-tokens max-tokens :reasoning-effort reasoning-effort
           :extra-body extra-body :retry-p retry-p))
         (client
          (resolve-and-build-mcp-client :mcp-url mcp-url :mcp-stdio mcp-stdio
           :mcp-command mcp-command :client-name "cl-harness" :client-version
           "0.4.0"))
         (policy (make-tool-policy condition))
         (path
          (or log-path
              (merge-pathnames
               (format nil "cl-harness-fix-~A.jsonl" (get-universal-time))
               (uiop/stream:temporary-directory)))))
    (let ((logger (open-run-logger path)))
      (unwind-protect
          (let ((state
                 (run-agent config provider client policy logger :dry-run-p
                  dry-run-p)))
            (format t "~A" (format-final-report state :log-path path))
            state)
        (close-run-logger logger)
        (close-mcp-client client)))))

(defun bench
       (
        &key suite (conditions '(:generic-mcp)) mcp-url mcp-stdio mcp-command
        base-url api-key model (temperature 0.0) max-tokens reasoning-effort
        extra-body (retry-p t) log-dir (log-llm-requests nil))
  "Run the benchmark suite at SUITE across each condition.

SUITE is the path to a directory containing per-task subdirectories, each
with a task.json and a fixture/ tree (PRD §8.11 REQ-BENCH-001). CONDITIONS
defaults to (:generic-mcp); pass (:file-only :generic-mcp :runtime-native)
to compare modes (REQ-BENCH-002). LLM credentials are resolved the same
way as FIX (kwarg overrides CL_HARNESS_LLM_*); the cl-mcp connection
follows the same priority chain documented on FIX (mcp-url / env-url /
mcp-command / mcp-stdio / env-command / built-in HTTP default).

REASONING-EFFORT and EXTRA-BODY pass through to MAKE-OPENAI-PROVIDER for
reasoning models / endpoint quirks; see FIX's docstring.

LOG-LLM-REQUESTS, when non-NIL, instructs each per-task run logger to emit
full :llm-request JSONL events containing the complete message history.

Returns the flat list of BENCH-RESULTs and prints a one-paragraph aggregate
report plus per-task detail to *STANDARD-OUTPUT*."
  (unless suite
    (error "bench: :suite (path to a directory of tasks) is required"))
  (let* ((effective-base-url
          (or base-url (uiop/os:getenv "CL_HARNESS_LLM_BASE_URL")
              (error
               "bench: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key (uiop/os:getenv "CL_HARNESS_LLM_API_KEY")
              (error "bench: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model (uiop/os:getenv "CL_HARNESS_LLM_MODEL")
              (error "bench: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider
          (make-openai-provider :base-url effective-base-url :api-key
           effective-api-key :model effective-model :temperature temperature
           :max-tokens max-tokens :reasoning-effort reasoning-effort
           :extra-body extra-body :retry-p retry-p))
         (client
          (resolve-and-build-mcp-client :mcp-url mcp-url :mcp-stdio mcp-stdio
           :mcp-command mcp-command :client-name "cl-harness-bench"
           :client-version "0.4.0"))
         (effective-log-dir
          (or log-dir
              (merge-pathnames
               (format nil "cl-harness-bench-~A/" (get-universal-time))
               (uiop/stream:temporary-directory)))))
    (ensure-directories-exist effective-log-dir)
    (unwind-protect
        (let ((results
               (run-benchmark-suite suite provider client :conditions
                conditions :log-dir effective-log-dir :log-llm-requests
                log-llm-requests)))
          (format t "~A" (format-suite-report results))
          (format t "~%Logs: ~A~%" effective-log-dir)
          results)
      (close-mcp-client client))))

(defun %symbol-down (s)
  (cond
    ((null s) "")
    ((stringp s) s)
    ((symbolp s) (string-downcase (symbol-name s)))
    (t (format nil "~A" s))))

(defun format-develop-report (result &key log-path)
  "Render a one-paragraph human-readable summary of a DEVELOP-RESULT,
mirroring the shape of FORMAT-FINAL-REPORT for fix runs."
  (with-output-to-string (s)
    (format s "~&== cl-harness develop report ==~%")
    (format s "Status:           :~A"
            (string-upcase (%symbol-down (develop-result-status result))))
    (let ((reason (develop-result-reason result)))
      (when reason
        (format s " (reason: :~A)" (%symbol-down reason))))
    (when (develop-result-limit-hit result)
      (format s " (limit: :~A)"
              (string-upcase (%symbol-down (develop-result-limit-hit result)))))
    (format s "~%")
    (format s "Replans:          ~D~%" (develop-result-replan-count result))
    (format s "Step results:     ~D~%"
            (length (develop-result-step-results result)))
    (let ((ledger (cl-harness/src/orchestrator:develop-result-abstraction-ledger
                   result)))
      (when ledger
        (format s "Abstractions:     ~D recorded (~D adopted, ~D rejected, ~D deferred)~%"
                (length ledger)
                (count :adopted ledger
                       :key #'cl-harness/src/abstraction:abstraction-decision-kind)
                (count :rejected ledger
                       :key #'cl-harness/src/abstraction:abstraction-decision-kind)
                (count :deferred ledger
                       :key #'cl-harness/src/abstraction:abstraction-decision-kind))))
    (when (eq :passed (develop-result-status result))
      (let ((issues (develop-result-integration-issues result)))
        (format s "Integration:      ~A~%"
                (if issues
                    (format nil "~D issue(s)" (length issues))
                    "clean"))))
    (when log-path (format s "Develop log:      ~A~%" log-path))))

(defun format-develop-report-structured (result)
  "Render a DEVELOP-RESULT's underlying DEVELOP-STATE as a
structured markdown report via CL-HARNESS/SRC/REPORT:
FORMAT-DEVELOP-STATE-REPORT. Returns the report string when
the result carries a non-NIL develop-state; returns NIL when
the back-reference was not populated (legacy callers, test
stubs).

This is the opt-in path; the CLI's default report formatter
(FORMAT-DEVELOP-REPORT) remains unchanged."
  (let ((state (develop-result-develop-state result)))
    (when state
      (format-develop-state-report state))))

(defun format-develop-report-markdown (result &key goal log-path)
  "Render DEVELOP-RESULT as a structured markdown report
(requirement 4.11). Sections: user request (when GOAL is supplied),
status / counts, adopted / rejected / deferred abstractions,
explore notes per step, and per-step status summary.

Empty sections are omitted so the output stays terse for
trivial runs."
  (with-output-to-string (s)
    (format s "# cl-harness develop report~%")
    (when goal
      (format s "~%## User request~%~A~%" goal))
    (format s "~%## Outcome~%")
    (format s "- Status: `:~A`~@[ (reason: `:~A`)~]~%"
            (string-upcase (%symbol-down (develop-result-status result)))
            (let ((reason (develop-result-reason result)))
              (and reason (%symbol-down reason))))
    (when (develop-result-limit-hit result)
      (format s "- Limit hit: `:~A`~%"
              (string-upcase (%symbol-down (develop-result-limit-hit result)))))
    (format s "- Replans: ~D~%" (develop-result-replan-count result))
    (format s "- Step results: ~D~%"
            (length (develop-result-step-results result)))
    (let ((ledger (cl-harness/src/orchestrator:develop-result-abstraction-ledger
                   result)))
      (when ledger
        (format
         s "~A"
         (cl-harness/src/abstraction:format-abstraction-ledger-markdown
          ledger :header-level 2))))
    (when (eq :passed (develop-result-status result))
      (format s "~A"
              (format-integration-issues-markdown
               (develop-result-integration-issues result)
               :header-level 2)))
    (let ((with-explore
           (remove-if-not
            (lambda (sr)
              (cl-harness/src/orchestrator:develop-step-result-explore-result sr))
            (develop-result-step-results result))))
      (when with-explore
        (format s "~%## Exploration notes~%")
        (dolist (sr with-explore)
          (let* ((er (cl-harness/src/orchestrator:develop-step-result-explore-result sr))
                 (memo (and er (cl-harness/src/explore:explore-result-memo er))))
            (format s "~%### Step ~D: ~A~%~A~%"
                    (cl-harness/src/orchestrator:develop-step-result-step-index sr)
                    (cl-harness/src/orchestrator:develop-step-result-test-name sr)
                    (or memo "(no memo)"))))))
    (format s "~%## Per-step status~%")
    (dolist (sr (develop-result-step-results result))
      (format s "- Step ~D `~A`: :~A~%"
              (cl-harness/src/orchestrator:develop-step-result-step-index sr)
              (cl-harness/src/orchestrator:develop-step-result-test-name sr)
              (string-upcase
               (%symbol-down
                (cl-harness/src/orchestrator:develop-step-result-status sr)))))
    (when log-path
      (format s "~%## Logs~%- ~A~%" log-path))))

(defun develop
       (
        &key goal project-root system test-system test-file
        (condition :generic-mcp) mcp-url mcp-stdio mcp-command base-url api-key
        model (temperature 0.0) max-tokens reasoning-effort extra-body
        (retry-p t) (max-replans 3) max-patches max-turns max-tool-calls
        max-wall-clock-seconds run-limits project-inventory
        (gather-inventory-p t) (inventory-byte-budget 5000) (mode :mixed)
        (review-policy :auto) (test-revision-policy :additive-only)
        (max-review-replans 2) (max-test-revisions 3)
        (max-impl-review-revisions 2) log-path (log-llm-requests nil))
  "Plan, execute, and replan-on-failure to drive a high-level GOAL to a
green test suite.

Mirrors the kwarg style of CL-HARNESS:FIX so a shell-CLI invocation
flows the same env-var and override chain (CL_HARNESS_LLM_*,
CL_HARNESS_MCP_*, ...). The provider and cl-mcp client are built here
and torn down on exit; orchestrator-level DEVELOP is called with them
already wired up.

GOAL is the natural-language statement the planner decomposes (one
paragraph; do not include code). TEST-FILE is the rove file the
planner-authored deftest forms get appended to; the file must already
exist with a defpackage that imports rove and the project's main
package.

MODE (v0.4 Phase 6) is :TOP-DOWN, :BOTTOM-UP, or :MIXED (default).
:TOP-DOWN forces every plan-step's needs-exploration to :NONE
(implement-first), :BOTTOM-UP promotes :NONE / NIL needs to
:LIGHTWEIGHT (explore-first), :MIXED leaves the planner's choice
intact.

LOG-LLM-REQUESTS, when non-NIL, instructs each step's run logger to
emit full :llm-request JSONL events containing the complete message
history sent to the model.

Returns the populated DEVELOP-RESULT. Caller is responsible for
inspecting STATUS / REPLAN-COUNT / LIMIT-HIT to decide on follow-up."
  (check-type goal string)
  (let* ((effective-base-url
          (or base-url (uiop/os:getenv "CL_HARNESS_LLM_BASE_URL")
              (error
               "develop: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key (uiop/os:getenv "CL_HARNESS_LLM_API_KEY")
              (error
               "develop: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model (uiop/os:getenv "CL_HARNESS_LLM_MODEL")
              (error "develop: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider
          (make-openai-provider :base-url effective-base-url :api-key
           effective-api-key :model effective-model :temperature temperature
           :max-tokens max-tokens :reasoning-effort reasoning-effort
           :extra-body extra-body :retry-p retry-p))
         (client
          (resolve-and-build-mcp-client :mcp-url mcp-url :mcp-stdio mcp-stdio
           :mcp-command mcp-command :client-name "cl-harness-develop"
           :client-version "0.4.0"))
         (path
          (or log-path
              (merge-pathnames
               (format nil "cl-harness-develop-~A.jsonl" (get-universal-time))
               (uiop/stream:temporary-directory)))))
    (let ((effective-limits
           (or run-limits
               (when
                   (or max-patches max-turns max-tool-calls
                       max-wall-clock-seconds)
                 (let ((d (make-default-limits)))
                   (make-instance 'run-limits :max-turns
                                  (or max-turns (run-limits-max-turns d))
                                  :max-tool-calls
                                  (or max-tool-calls
                                      (run-limits-max-tool-calls d))
                                  :max-patches
                                  (or max-patches (run-limits-max-patches d))
                                  :max-read-files (run-limits-max-read-files d)
                                  :max-repl-evals (run-limits-max-repl-evals d)
                                  :max-wall-clock-seconds
                                  (or max-wall-clock-seconds
                                      (run-limits-max-wall-clock-seconds d))
                                  :max-action-parse-errors
                                  (run-limits-max-action-parse-errors d)))))))
      (let ((effective-inventory
             (or project-inventory
                 (when gather-inventory-p
                   (handler-case
                    (gather-project-inventory :project-root project-root
                     :system system :test-system test-system :byte-budget
                     inventory-byte-budget)
                    (error nil nil))))))
        (unwind-protect
            (let ((result
                   (cl-harness/src/orchestrator:develop goal :project-root
                    project-root :system system :test-system test-system
                    :test-file test-file :provider provider :mcp-client client
                    :condition condition :run-limits effective-limits
                    :project-inventory effective-inventory :mode mode
                    :review-policy review-policy :test-revision-policy
                    test-revision-policy :max-review-replans max-review-replans
                    :max-test-revisions max-test-revisions :max-replans
                    max-replans :max-impl-review-revisions
                    max-impl-review-revisions :log-path path
                    :log-llm-requests log-llm-requests)))
              (format t "~A" (format-develop-report result :log-path path))
              result)
          (close-mcp-client client))))))
