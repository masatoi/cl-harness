;;;; develop-benchmarks/103-fizz-buzz/fixture/src/main.lisp
;;;;
;;;; Greenfield: pre-exported FIZZ-BUZZ symbol; the planner-driven
;;;; agent fills in the function body.

(defpackage #:fizz-buzz/src/main
  (:nicknames #:fizz-buzz)
  (:use #:cl)
  (:export #:fizz-buzz))

(in-package #:fizz-buzz/src/main)
