;;;; src/main.lisp
;;;;
;;;; Top-level facade for cl-harness. Re-exports the user-facing API surface
;;;; (config + log + cli) so callers can `(:use :cl-harness)' without knowing
;;;; the internal package-inferred-system layout. Re-exports work via
;;;; :import-from + :export, which share symbol identity with the source
;;;; packages — no fdefinition shimming required.

(defpackage #:cl-harness/src/main
  (:nicknames #:cl-harness)
  (:use #:cl)
  (:import-from #:cl-harness/src/config
                #:run-config
                #:make-run-config)
  (:import-from #:cl-harness/src/log
                #:run-logger
                #:open-run-logger
                #:close-run-logger
                #:log-event
                #:with-run-logger)
  (:import-from #:cl-harness/src/cli
                #:fix
                #:bench
                #:develop)
  (:import-from #:cl-harness/src/cli-main
                #:main)
  (:import-from #:cl-harness/src/mcp
                #:mcp-client
                #:make-mcp-client
                #:mcp-client-url
                #:mcp-client-session-id
                #:mcp-error
                #:initialize-mcp
                #:list-tools
                #:call-tool
                #:close-mcp-client)
  (:import-from #:cl-harness/src/mcp-stdio
                #:make-stdio-mcp-client
                #:make-stdio-mcp-transport
                #:stdio-mcp-transport
                #:stdio-mcp-error)
  (:import-from #:cl-harness/src/model
                #:openai-compatible-provider
                #:make-openai-provider
                #:provider-default-reasoning-effort
                #:provider-default-extra-body
                #:make-chat-message
                #:chat-response
                #:chat-response-content
                #:chat-response-total-tokens
                #:complete-chat
                #:model-error)
  (:import-from #:cl-harness/src/action
                #:agent-action
                #:agent-action-type
                #:parse-action
                #:action-parse-error)
  (:import-from #:cl-harness/src/policy
                #:tool-policy
                #:make-tool-policy
                #:policy-mode
                #:allowed-tool-p)
  (:import-from #:cl-harness/src/verify
                #:verify-result
                #:verify-result-status
                #:verify-result-success-p
                #:verify-task
                #:clean-verify-task)
  (:import-from #:cl-harness/src/agent
                #:agent-state
                #:agent-state-status
                #:agent-state-turn
                #:agent-state-final-verify
                #:agent-state-patch-count
                #:agent-state-patch-attempts
                #:agent-state-token-total
                #:agent-state-tool-call-count
                #:agent-state-read-file-count
                #:agent-state-repl-eval-count
                #:agent-state-limit-hit
                #:run-agent
                #:format-final-report)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:plan-step-index
                #:plan-step-issue
                #:plan-step-test-name
                #:plan-step-test-source
                #:plan-step-files-to-modify
                #:plan-development
                #:planner-error)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-step-result
                #:develop-step-result-status
                #:develop-step-result-step-index
                #:develop-step-result-test-name
                #:develop-step-result-run-config
                #:develop-step-result-run-agent-state
                #:develop-result
                #:develop-result-status
                #:develop-result-final-plan
                #:develop-result-step-results
                #:develop-result-replan-count
                #:develop-result-limit-hit
                #:execute-plan)
  (:import-from #:cl-harness/src/compact
                #:approximate-history-tokens
                #:compact-history)
  (:import-from #:cl-harness/src/bench
                #:bench-task
                #:bench-task-id
                #:bench-result
                #:bench-result-status
                #:bench-result-success-p
                #:bench-result-limit-hit
                #:bench-result-tool-call-count
                #:bench-result-read-file-count
                #:bench-result-repl-eval-count
                #:load-bench-task
                #:discover-tasks
                #:run-benchmark-task
                #:run-benchmark-task-trials
                #:run-benchmark-suite
                #:aggregate-results
                #:format-suite-report
                #:format-suite-report-markdown)
  (:export #:fix
           #:bench
           #:develop
           #:main
           #:run-config
           #:make-run-config
           #:run-logger
           #:open-run-logger
           #:close-run-logger
           #:log-event
           #:with-run-logger
           #:mcp-client
           #:make-mcp-client
           #:mcp-client-url
           #:mcp-client-session-id
           #:mcp-error
           #:initialize-mcp
           #:list-tools
           #:call-tool
           #:close-mcp-client
           #:make-stdio-mcp-client
           #:make-stdio-mcp-transport
           #:stdio-mcp-transport
           #:stdio-mcp-error
           #:openai-compatible-provider
           #:make-openai-provider
           #:provider-default-reasoning-effort
           #:provider-default-extra-body
           #:make-chat-message
           #:chat-response
           #:chat-response-content
           #:chat-response-total-tokens
           #:complete-chat
           #:model-error
           #:agent-action
           #:agent-action-type
           #:parse-action
           #:action-parse-error
           #:tool-policy
           #:make-tool-policy
           #:policy-mode
           #:allowed-tool-p
           #:verify-result
           #:verify-result-status
           #:verify-result-success-p
           #:verify-task
           #:clean-verify-task
           #:agent-state
           #:agent-state-status
           #:agent-state-turn
           #:agent-state-final-verify
           #:agent-state-patch-count
           #:agent-state-patch-attempts
           #:agent-state-token-total
           #:agent-state-tool-call-count
           #:agent-state-read-file-count
           #:agent-state-repl-eval-count
           #:agent-state-limit-hit
           #:run-agent
           #:format-final-report
           #:plan-step
           #:plan-step-index
           #:plan-step-issue
           #:plan-step-test-name
           #:plan-step-test-source
           #:plan-step-files-to-modify
           #:plan-development
           #:planner-error
           #:develop-step-result
           #:develop-step-result-status
           #:develop-step-result-step-index
           #:develop-step-result-test-name
           #:develop-step-result-run-config
           #:develop-step-result-run-agent-state
           #:develop-result
           #:develop-result-status
           #:develop-result-final-plan
           #:develop-result-step-results
           #:develop-result-replan-count
           #:develop-result-limit-hit
           #:execute-plan
           #:approximate-history-tokens
           #:compact-history
           #:bench-task
           #:bench-task-id
           #:bench-result
           #:bench-result-status
           #:bench-result-success-p
           #:bench-result-limit-hit
           #:bench-result-tool-call-count
           #:bench-result-read-file-count
           #:bench-result-repl-eval-count
           #:load-bench-task
           #:discover-tasks
           #:run-benchmark-task
           #:run-benchmark-task-trials
           #:run-benchmark-suite
           #:aggregate-results
           #:format-suite-report
           #:format-suite-report-markdown))

(in-package #:cl-harness/src/main)
