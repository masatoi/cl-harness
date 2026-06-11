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
                #:pack-dial-rule)
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
           #:pack-dial-rule))

(in-package #:cl-harness-next/src/main)

(defun substrate-version ()
  "Return the cl-harness-next system version string."
  (asdf:component-version (asdf:find-system "cl-harness-next")))
