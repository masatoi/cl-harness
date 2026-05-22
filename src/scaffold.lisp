;;;; src/scaffold.lisp
;;;;
;;;; LLM-free, deterministic ASDF + rove scaffold generator.
;;;; Spec: docs/superpowers/specs/2026-05-22-scaffold-command-design.md

(defpackage #:cl-harness/src/scaffold
  (:use #:cl)
  (:export #:scaffold
           #:scaffold-result
           #:scaffold-result-status
           #:scaffold-result-paths-written
           #:scaffold-result-conflicts
           #:scaffold-error
           #:scaffold-error-message
           #:scaffold-bad-system-name
           #:scaffold-bad-system-name-name
           #:scaffold-partial-state
           #:scaffold-partial-state-existing
           #:scaffold-partial-state-missing))

(in-package #:cl-harness/src/scaffold)
