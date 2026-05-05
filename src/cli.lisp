;;;; src/cli.lisp
;;;;
;;;; PRD §8.1 CLI skeleton. Phase 0 ships only entrypoints that parse a tiny
;;;; argv subset into a RUN-CONFIG and report "not implemented" for the agent
;;;; loop itself. A real argument parser (clingon/unix-opts) lands in Phase 1.

(defpackage #:cl-harness/src/cli
  (:use #:cl)
  (:import-from #:cl-harness/src/config
                #:make-run-config)
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
                 (condition :runtime-native))
  "Entry point for the `cl-harness fix' command (PRD §8.1 REQ-CLI-001).

Phase 0 builds a RUN-CONFIG and signals NOT-IMPLEMENTED-ERROR. The real agent
loop (LLM provider, MCP client, workflow engine) lands in later phases."
  (let ((config (make-run-config :project-root project-root
                                 :system system
                                 :test-system test-system
                                 :issue issue
                                 :condition condition)))
    (declare (ignorable config))
    (error 'not-implemented-error :command "fix")))

(defun bench (&key suite condition model base-url mcp-url)
  "Entry point for the `cl-harness bench' command (PRD §8.1 REQ-CLI-002).

Phase 0 validates inputs and signals NOT-IMPLEMENTED-ERROR."
  (declare (ignore suite condition model base-url mcp-url))
  (error 'not-implemented-error :command "bench"))
