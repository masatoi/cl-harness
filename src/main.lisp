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
                #:bench)
  (:import-from #:cl-harness/src/mcp
                #:mcp-client
                #:make-mcp-client
                #:mcp-client-url
                #:mcp-client-session-id
                #:mcp-error
                #:initialize-mcp
                #:list-tools
                #:call-tool)
  (:import-from #:cl-harness/src/model
                #:openai-compatible-provider
                #:make-openai-provider
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
                #:verify-task)
  (:import-from #:cl-harness/src/agent
                #:agent-state
                #:agent-state-status
                #:agent-state-turn
                #:agent-state-patch-count
                #:run-agent)
  (:export #:fix
           #:bench
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
           #:openai-compatible-provider
           #:make-openai-provider
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
           #:agent-state
           #:agent-state-status
           #:agent-state-turn
           #:agent-state-patch-count
           #:run-agent))

(in-package #:cl-harness/src/main)
