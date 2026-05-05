(defpackage #:format-arity/src/main
  (:nicknames #:format-arity)
  (:use #:cl)
  (:export #:describe-pair))

(in-package #:format-arity/src/main)

(defun describe-pair (a b)
  "Return a human-readable string mentioning both A and B."
  ;; BUG: format directive only consumes one ~A, so B never appears
  ;; in the output. The test asserts that both are present.
  (format nil "(~A)" a b))
