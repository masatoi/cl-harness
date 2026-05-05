;;;; src/cli.lisp
;;;;
;;;; PRD §8.1 CLI skeleton. Phase 0 ships only entrypoints that parse a tiny
;;;; argv subset into a RUN-CONFIG and report "not implemented" for the agent
;;;; loop itself. A real argument parser (clingon/unix-opts) lands in Phase 1.

(defpackage #:cl-harness/src/cli
  (:use #:cl)
  (:import-from #:cl-harness/src/config
                #:make-run-config)
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
                #:develop-result-limit-hit)
  (:export #:fix
           #:bench
           #:develop
           #:not-implemented-error))

(in-package #:cl-harness/src/cli)

(define-condition not-implemented-error (error)
  ((command :initarg :command :reader not-implemented-error-command))
  (:report (lambda (c stream)
             (format stream "cl-harness ~A: not implemented yet (Phase 0 skeleton)."
                     (not-implemented-error-command c)))))

(defun fix (&key project-root system test-system issue
                 (condition :generic-mcp)
                 mcp-url mcp-stdio mcp-command
                 base-url api-key model
                 (temperature 0.0) (max-tokens 1024)
                 reasoning-effort extra-body
                 dry-run-p
                 log-path)
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

Returns the populated AGENT-STATE."
  (let* ((config (make-run-config :project-root project-root
                                  :system system
                                  :test-system test-system
                                  :issue issue
                                  :condition condition))
         (effective-base-url
          (or base-url
              (uiop:getenv "CL_HARNESS_LLM_BASE_URL")
              (error "fix: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key
              (uiop:getenv "CL_HARNESS_LLM_API_KEY")
              (error "fix: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model
              (uiop:getenv "CL_HARNESS_LLM_MODEL")
              (error "fix: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider (make-openai-provider
                    :base-url effective-base-url
                    :api-key effective-api-key
                    :model effective-model
                    :temperature temperature
                    :max-tokens max-tokens
                    :reasoning-effort reasoning-effort
                    :extra-body extra-body))
         (client (resolve-and-build-mcp-client
                  :mcp-url mcp-url
                  :mcp-stdio mcp-stdio
                  :mcp-command mcp-command
                  :client-name "cl-harness"
                  :client-version "0.2.0"))
         (policy (make-tool-policy condition))
         (path (or log-path
                   (merge-pathnames
                    (format nil "cl-harness-fix-~A.jsonl"
                            (get-universal-time))
                    (uiop:temporary-directory)))))
    (let ((logger (open-run-logger path)))
      (unwind-protect
           (let ((state (run-agent config provider client policy logger
                                   :dry-run-p dry-run-p)))
             (format t "~A" (format-final-report state :log-path path))
             state)
        (close-run-logger logger)
        (close-mcp-client client)))))

(defun bench (&key suite
                   (conditions '(:generic-mcp))
                   mcp-url mcp-stdio mcp-command
                   base-url api-key model
                   (temperature 0.0) (max-tokens 2048)
                   reasoning-effort extra-body
                   log-dir)
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

Returns the flat list of BENCH-RESULTs and prints a one-paragraph aggregate
report plus per-task detail to *STANDARD-OUTPUT*."
  (unless suite
    (error "bench: :suite (path to a directory of tasks) is required"))
  (let* ((effective-base-url
          (or base-url
              (uiop:getenv "CL_HARNESS_LLM_BASE_URL")
              (error "bench: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key
              (uiop:getenv "CL_HARNESS_LLM_API_KEY")
              (error "bench: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model
              (uiop:getenv "CL_HARNESS_LLM_MODEL")
              (error "bench: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider (make-openai-provider
                    :base-url effective-base-url
                    :api-key effective-api-key
                    :model effective-model
                    :temperature temperature
                    :max-tokens max-tokens
                    :reasoning-effort reasoning-effort
                    :extra-body extra-body))
         (client (resolve-and-build-mcp-client
                  :mcp-url mcp-url
                  :mcp-stdio mcp-stdio
                  :mcp-command mcp-command
                  :client-name "cl-harness-bench"
                  :client-version "0.2.0"))
         (effective-log-dir
          (or log-dir
              (merge-pathnames
               (format nil "cl-harness-bench-~A/" (get-universal-time))
               (uiop:temporary-directory)))))
    (ensure-directories-exist effective-log-dir)
    (unwind-protect
         (let ((results (run-benchmark-suite suite provider client
                                             :conditions conditions
                                             :log-dir effective-log-dir)))
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
    (when (develop-result-limit-hit result)
      (format s " (limit: :~A)"
              (string-upcase (%symbol-down (develop-result-limit-hit result)))))
    (format s "~%")
    (format s "Replans:          ~D~%" (develop-result-replan-count result))
    (format s "Step results:     ~D~%"
            (length (develop-result-step-results result)))
    (when log-path (format s "Develop log:      ~A~%" log-path))))

(defun develop (&key goal project-root system test-system test-file
                     (condition :generic-mcp)
                     mcp-url mcp-stdio mcp-command
                     base-url api-key model
                     (temperature 0.0) (max-tokens 4096)
                     reasoning-effort extra-body
                     (max-replans 3)
                     log-path)
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

Returns the populated DEVELOP-RESULT. Caller is responsible for
inspecting STATUS / REPLAN-COUNT / LIMIT-HIT to decide on follow-up."
  (check-type goal string)
  (let* ((effective-base-url
          (or base-url
              (uiop:getenv "CL_HARNESS_LLM_BASE_URL")
              (error "develop: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key
              (uiop:getenv "CL_HARNESS_LLM_API_KEY")
              (error "develop: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model
              (uiop:getenv "CL_HARNESS_LLM_MODEL")
              (error "develop: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider (make-openai-provider
                    :base-url effective-base-url
                    :api-key effective-api-key
                    :model effective-model
                    :temperature temperature
                    :max-tokens max-tokens
                    :reasoning-effort reasoning-effort
                    :extra-body extra-body))
         (client (resolve-and-build-mcp-client
                  :mcp-url mcp-url
                  :mcp-stdio mcp-stdio
                  :mcp-command mcp-command
                  :client-name "cl-harness-develop"
                  :client-version "0.2.0"))
         (path (or log-path
                   (merge-pathnames
                    (format nil "cl-harness-develop-~A.jsonl"
                            (get-universal-time))
                    (uiop:temporary-directory)))))
    (unwind-protect
         (let ((result (cl-harness/src/orchestrator:develop
                        goal
                        :project-root project-root
                        :system system
                        :test-system test-system
                        :test-file test-file
                        :provider provider
                        :mcp-client client
                        :condition condition
                        :max-replans max-replans
                        :log-path path)))
           (format t "~A" (format-develop-report result :log-path path))
           result)
      (close-mcp-client client))))
