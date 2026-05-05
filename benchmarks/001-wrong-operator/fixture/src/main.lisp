(defpackage #:wrong-op/src/main
  (:nicknames #:wrong-op)
  (:use #:cl)
  (:export #:max-of))

(in-package #:wrong-op/src/main)

(defun max-of (a b)
  "Return the larger of A and B."
  ;; BUG: comparison is inverted — should be > not <.
  (if (< a b) a b))
