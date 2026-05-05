;;;; develop-benchmarks/100-greet/fixture/src/main.lisp
;;;;
;;;; Greenfield: empty package, no greet defun yet. The planner +
;;;; executor are expected to fill this in when driven by the goal
;;;; in develop-task.json.

(defpackage #:greet/src/main
  (:nicknames #:greet)
  (:use #:cl))

(in-package #:greet/src/main)
