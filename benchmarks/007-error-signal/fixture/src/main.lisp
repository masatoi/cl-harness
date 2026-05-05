(defpackage #:error-signal/src/main
  (:nicknames #:error-signal)
  (:use #:cl)
  (:export #:safe-div))

(in-package #:error-signal/src/main)

(defun safe-div (a b)
  "Return A divided by B, signalling an error when B is zero."
  ;; BUG: zero divisor is silently mapped to 0, but callers expect an
  ;; error condition so they can distinguish "unable to compute" from
  ;; "zero result".
  (if (zerop b) 0 (/ a b)))
