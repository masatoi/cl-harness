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
           #:model-error))

(in-package #:cl-harness/src/main)
