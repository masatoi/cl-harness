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
  (:export #:fix
           #:bench
           #:run-config
           #:make-run-config
           #:run-logger
           #:open-run-logger
           #:close-run-logger
           #:log-event
           #:with-run-logger))

(in-package #:cl-harness/src/main)
