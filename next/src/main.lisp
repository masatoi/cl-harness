;;;; next/src/main.lisp
;;;;
;;;; Public facade for cl-harness-next. Re-exports the user-facing API
;;;; via :import-from + :export (shared symbol identity). Populated as
;;;; modules land; starts as a stub so the system skeleton loads.

(defpackage #:cl-harness-next/src/main
  (:nicknames #:cl-harness-next)
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:+event-types+
                #:unknown-event-type
                #:unknown-event-type-name
                #:harness-event
                #:make-harness-event
                #:event-seq
                #:event-type
                #:event-timestamp
                #:event-schema-version
                #:event-payload
                #:event->json-string
                #:json-string->event)
  (:import-from #:cl-harness-next/src/event-log
                #:event-log
                #:open-event-log
                #:event-log-path
                #:event-log-next-seq
                #:emit-event
                #:read-events
                #:replay-events
                #:event-log-parse-error
                #:event-log-parse-error-path
                #:event-log-parse-error-line-number
                #:event-log-parse-error-cause)
  (:import-from #:cl-harness-next/src/policy-pack
                #:parse-semver
                #:semver<
                #:policy-pack
                #:load-policy-pack
                #:policy-pack-invalid
                #:policy-pack-invalid-message
                #:policy-pack-invalid-path
                #:pack-name
                #:pack-version
                #:pack-source-path
                #:pack-fingerprint
                #:pack-prompts
                #:pack-budgets
                #:pack-oracle-profiles
                #:pack-dial-rules
                #:pack-prompt
                #:pack-budget
                #:pack-oracle-profile
                #:pack-dial-rule
                #:pack-tool-policies
                #:pack-tool-policy)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:transport-close
                #:mcp-client
                #:make-mcp-client
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message
                #:mcp-error-data
                #:initialize-mcp
                #:list-tools
                #:call-tool
                #:close-mcp-client)
  (:import-from #:cl-harness-next/src/mcp-stdio
                #:make-stdio-mcp-client
                #:stdio-mcp-error
                #:stdio-mcp-error-message
                #:*default-stdio-command*)
  (:import-from #:cl-harness-next/src/action-space
                #:action-space
                #:make-action-space
                #:action-space-mode
                #:allowed-tools
                #:action-allowed-p)
  (:import-from #:cl-harness-next/src/environment
                #:action-not-allowed
                #:action-not-allowed-tool
                #:action-not-allowed-mode
                #:environment
                #:environment-action-space
                #:perform-action
                #:environment-close
                #:cl-mcp-environment
                #:make-cl-mcp-environment
                #:environment-event-log)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model
                #:make-world-model
                #:make-standard-world-model
                #:world-model-projection
                #:world-model-last-seq
                #:update-world-model
                #:build-world-model)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context
                #:estimate-tokens)
  (:export #:substrate-version
           ;; event
           #:+event-types+
           #:unknown-event-type
           #:unknown-event-type-name
           #:harness-event
           #:make-harness-event
           #:event-seq
           #:event-type
           #:event-timestamp
           #:event-schema-version
           #:event-payload
           #:event->json-string
           #:json-string->event
           ;; event-log
           #:event-log
           #:open-event-log
           #:event-log-path
           #:event-log-next-seq
           #:emit-event
           #:read-events
           #:replay-events
           #:event-log-parse-error
           #:event-log-parse-error-path
           #:event-log-parse-error-line-number
           #:event-log-parse-error-cause
           ;; policy-pack
           #:parse-semver
           #:semver<
           #:policy-pack
           #:load-policy-pack
           #:policy-pack-invalid
           #:policy-pack-invalid-message
           #:policy-pack-invalid-path
           #:pack-name
           #:pack-version
           #:pack-source-path
           #:pack-fingerprint
           #:pack-prompts
           #:pack-budgets
           #:pack-oracle-profiles
           #:pack-dial-rules
           #:pack-prompt
           #:pack-budget
           #:pack-oracle-profile
           #:pack-dial-rule
           ;; mcp
           #:mcp-transport
           #:transport-send-request
           #:transport-close
           #:mcp-client
           #:make-mcp-client
           #:mcp-error
           #:mcp-error-code
           #:mcp-error-message
           #:mcp-error-data
           #:initialize-mcp
           #:list-tools
           #:call-tool
           #:close-mcp-client
           #:make-stdio-mcp-client
           #:stdio-mcp-error
           #:stdio-mcp-error-message
           #:*default-stdio-command*
           ;; action-space
           #:action-space
           #:make-action-space
           #:action-space-mode
           #:allowed-tools
           #:action-allowed-p
           ;; environment
           #:action-not-allowed
           #:action-not-allowed-tool
           #:action-not-allowed-mode
           #:environment
           #:environment-action-space
           #:perform-action
           #:environment-close
           #:cl-mcp-environment
           #:make-cl-mcp-environment
           #:environment-event-log
           ;; policy-pack (SP2 additions)
           #:pack-tool-policies
           #:pack-tool-policy
           ;; world-model
           #:world-model
           #:make-world-model
           #:make-standard-world-model
           #:world-model-projection
           #:world-model-last-seq
           #:update-world-model
           #:build-world-model
           #:clean-verified-p
           ;; context-compiler
           #:compile-context
           #:estimate-tokens))

(in-package #:cl-harness-next/src/main)

(defun substrate-version ()
  "Return the cl-harness-next system version string."
  (asdf:component-version (asdf:find-system "cl-harness-next")))
