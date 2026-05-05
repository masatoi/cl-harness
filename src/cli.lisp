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
                #:make-mcp-client
                #:initialize-mcp)
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
  (:export #:fix
           #:bench
           #:not-implemented-error))

(in-package #:cl-harness/src/cli)

(define-condition not-implemented-error (error)
  ((command :initarg :command :reader not-implemented-error-command))
  (:report (lambda (c stream)
             (format stream "cl-harness ~A: not implemented yet (Phase 0 skeleton)."
                     (not-implemented-error-command c)))))

(defun fix (&key project-root system test-system issue
                 (condition :generic-mcp)
                 mcp-url
                 base-url api-key model
                 (temperature 0.0) (max-tokens 1024)
                 reasoning-effort extra-body
                 dry-run-p
                 log-path)
  "Run the Phase 2 basic fix loop.

Required keyword arguments mirror PRD §11.1: PROJECT-ROOT, SYSTEM,
TEST-SYSTEM, ISSUE. The LLM endpoint is taken from the keyword args or
the CL_HARNESS_LLM_BASE_URL / CL_HARNESS_LLM_API_KEY / CL_HARNESS_LLM_MODEL
environment variables. The cl-mcp HTTP URL defaults to
http://127.0.0.1:3001/mcp (override via :MCP-URL or CL_HARNESS_MCP_URL).

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
         (client (make-mcp-client
                  (or mcp-url
                      (uiop:getenv "CL_HARNESS_MCP_URL")
                      "http://127.0.0.1:3001/mcp")))
         (policy (make-tool-policy condition))
         (path (or log-path
                   (merge-pathnames
                    (format nil "cl-harness-fix-~A.jsonl"
                            (get-universal-time))
                    (uiop:temporary-directory)))))
    (initialize-mcp client
                    :client-name "cl-harness"
                    :client-version "0.0.1")
    (let ((logger (open-run-logger path)))
      (unwind-protect
           (let ((state (run-agent config provider client policy logger
                                   :dry-run-p dry-run-p)))
             (format t "~A" (format-final-report state :log-path path))
             state)
        (close-run-logger logger)))))

(defun bench (&key suite
                   (conditions '(:generic-mcp))
                   mcp-url
                   base-url api-key model
                   (temperature 0.0) (max-tokens 2048)
                   reasoning-effort extra-body
                   log-dir)
  "Run the benchmark suite at SUITE across each condition.

SUITE is the path to a directory containing per-task subdirectories, each
with a task.json and a fixture/ tree (PRD §8.11 REQ-BENCH-001). CONDITIONS
defaults to (:generic-mcp); pass (:file-only :generic-mcp :runtime-native)
to compare modes (REQ-BENCH-002). LLM credentials and the cl-mcp HTTP URL
are resolved the same way as FIX (kwarg overrides CL_HARNESS_LLM_*).

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
         (client (make-mcp-client
                  (or mcp-url
                      (uiop:getenv "CL_HARNESS_MCP_URL")
                      "http://127.0.0.1:3001/mcp")))
         (effective-log-dir
          (or log-dir
              (merge-pathnames
               (format nil "cl-harness-bench-~A/" (get-universal-time))
               (uiop:temporary-directory)))))
    (ensure-directories-exist effective-log-dir)
    (initialize-mcp client
                    :client-name "cl-harness-bench"
                    :client-version "0.0.1")
    (let ((results (run-benchmark-suite suite provider client
                                        :conditions conditions
                                        :log-dir effective-log-dir)))
      (format t "~A" (format-suite-report results))
      (format t "~%Logs: ~A~%" effective-log-dir)
      results)))
