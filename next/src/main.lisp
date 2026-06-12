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
                #:build-world-model
                #:refresh-world-model)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context
                #:estimate-tokens)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:result-error-p
                #:interaction-succeeded-p)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:consult
                #:verdict
                #:make-verdict
                #:verdict-oracle
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/invariant-oracle
                #:invariant-oracle
                #:oracle-invariants)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle
                #:oracle-system
                #:oracle-test-system
                #:oracle-mode)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle
                #:oracle-profile
                #:oracle-judge-fn)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-action-count
                #:governor-patch-count
                #:governor-consecutive-failed-patches
                #:governor-stalled-verify-cycles
                #:governor-breaches
                #:check-governor
                #:governor-intervention
                #:progress-stalled
                #:budget-exhausted
                #:oracle-conflict
                #:intervention-governor
                #:intervention-reason
                #:reset-governor-progress)
  (:import-from #:cl-harness-next/src/model
                #:model-provider
                #:openai-compatible-provider
                #:make-openai-provider
                #:make-chat-message
                #:complete-chat
                #:chat-response
                #:chat-response-content
                #:chat-response-role
                #:chat-response-finish-reason
                #:chat-response-prompt-tokens
                #:chat-response-completion-tokens
                #:chat-response-total-tokens
                #:model-error
                #:model-error-message
                #:model-error-type)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:agent-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-thought
                #:action-parse-error
                #:action-parse-error-message)
  (:import-from #:cl-harness-next/src/judge
                #:make-judge-fn)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:decision
                #:make-decision
                #:decision-kind
                #:decision-tool
                #:decision-arguments
                #:decision-oracle
                #:decision-subject
                #:decision-payload
                #:decision-reason
                #:kernel
                #:make-kernel
                #:kernel-environment
                #:kernel-event-log
                #:kernel-world-model
                #:kernel-policy
                #:kernel-governor
                #:kernel-status
                #:kernel-reason
                #:kernel-step-count
                #:kernel-last-verdict
                #:kernel-last-result
                #:kernel-last-action-error
                #:kernel-step
                #:run-kernel
                #:handle-intervention)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy
                #:policy-state
                #:policy-system
                #:policy-test-system
                #:+scripted-fix-system-prompt+)
  (:import-from #:cl-harness-next/src/llm-policies
                #:llm-step-policy
                #:guided-policy
                #:self-directed-policy
                #:policy-agenda
                #:policy-invariants
                #:make-subgoal
                #:subgoal-label
                #:subgoal-predicate
                #:default-fix-agenda
                #:+guided-system-prompt+
                #:+self-directed-system-prompt+)
  (:import-from #:cl-harness-next/src/adaptive-policy
                #:adaptive-policy
                #:policy-levels
                #:policy-level-index)
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
           #:refresh-world-model
           #:clean-verified-p
           ;; context-compiler
           #:compile-context
           #:estimate-tokens
           ;; projection protocol (SP4 additions)
           #:projection
           #:apply-event
           #:apply-interaction
           #:result-error-p
           #:interaction-succeeded-p
           ;; oracles
           #:oracle
           #:oracle-name
           #:evaluate
           #:consult
           #:verdict
           #:make-verdict
           #:verdict-oracle
           #:verdict-pass-p
           #:verdict-reason
           #:invariant-oracle
           #:oracle-invariants
           #:verification-oracle
           #:oracle-system
           #:oracle-test-system
           #:oracle-mode
           #:review-oracle
           #:oracle-profile
           #:oracle-judge-fn
           ;; governor
           #:governor
           #:governor-action-count
           #:governor-patch-count
           #:governor-consecutive-failed-patches
           #:governor-stalled-verify-cycles
           #:governor-breaches
           #:check-governor
           #:governor-intervention
           #:progress-stalled
           #:budget-exhausted
           #:oracle-conflict
           #:intervention-governor
           #:intervention-reason
           ;; model
           #:model-provider
           #:openai-compatible-provider
           #:make-openai-provider
           #:make-chat-message
           #:complete-chat
           #:chat-response
           #:chat-response-content
           #:chat-response-role
           #:chat-response-finish-reason
           #:chat-response-prompt-tokens
           #:chat-response-completion-tokens
           #:chat-response-total-tokens
           #:model-error
           #:model-error-message
           #:model-error-type
           ;; action
           #:parse-action
           #:agent-action
           #:agent-action-type
           #:agent-action-tool
           #:agent-action-arguments
           #:agent-action-status
           #:agent-action-summary
           #:agent-action-thought
           #:action-parse-error
           #:action-parse-error-message
           ;; judge
           #:make-judge-fn
           ;; kernel
           #:control-policy
           #:decide
           #:decision
           #:make-decision
           #:decision-kind
           #:decision-tool
           #:decision-arguments
           #:decision-oracle
           #:decision-subject
           #:decision-reason
           #:kernel
           #:make-kernel
           #:kernel-environment
           #:kernel-event-log
           #:kernel-world-model
           #:kernel-policy
           #:kernel-governor
           #:kernel-status
           #:kernel-reason
           #:kernel-step-count
           #:kernel-last-verdict
           #:kernel-last-result
           #:kernel-last-action-error
           #:kernel-step
           #:run-kernel
           ;; scripted-policy
           #:scripted-fix-policy
           #:policy-state
           #:policy-system
           #:policy-test-system
           #:+scripted-fix-system-prompt+
           ;; llm-policies
           #:llm-step-policy
           #:guided-policy
           #:self-directed-policy
           #:policy-agenda
           #:policy-invariants
           #:make-subgoal
           #:subgoal-label
           #:subgoal-predicate
           #:default-fix-agenda
           #:+guided-system-prompt+
           #:+self-directed-system-prompt+
           ;; adaptive
           #:adaptive-policy
           #:policy-levels
           #:policy-level-index
           ;; kernel/governor SP6 additions
           #:decision-payload
           #:handle-intervention
           #:reset-governor-progress))

(in-package #:cl-harness-next/src/main)

(defun substrate-version ()
  "Return the cl-harness-next system version string."
  (asdf:component-version (asdf:find-system "cl-harness-next")))
