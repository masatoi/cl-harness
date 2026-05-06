;;;; develop-benchmarks/100-greet/fixture/src/main.lisp
;;;;
;;;; Greenfield: empty package, no greet defun yet. The planner +
;;;; executor are expected to fill this in when driven by the goal
;;;; in develop-task.json.

(defpackage #:greet/src/main
  (:nicknames #:greet)
  (:use #:cl)
  ;; Pre-exporting the target symbol so planner-authored tests that
  ;; refer to GREET:GREET can be READ even before the implementation
  ;; lands. The function binding is what's missing on entry — that's
  ;; the agent's job to add.
  (:export #:greet))

(in-package #:greet/src/main)
