;;;; develop-benchmarks/102-counter-class/fixture/src/main.lisp
;;;;
;;;; Greenfield: defpackage with the target API symbols pre-exported
;;;; so planner-authored tests can READ before the implementation
;;;; lands. The agent's job is to add the defclass, defgenerics, and
;;;; methods.

(defpackage #:counter/src/main
  (:nicknames #:counter)
  (:use #:cl)
  (:export #:counter
           #:make-counter
           #:counter-value
           #:increment
           #:reset-counter))

(in-package #:counter/src/main)
