(defpackage #:let-bug/src/main
  (:nicknames #:let-bug)
  (:use #:cl)
  (:export #:compute-result))

(in-package #:let-bug/src/main)

(defun compute-result (x)
  "Double X then add one."
  ;; BUG: LET binds A and B in parallel, so B's value form cannot
  ;; reference the new A. The fix is to use LET* (sequential bindings).
  (let ((a (* x 2))
        (b (+ a 1)))
    b))
