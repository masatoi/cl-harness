;;;; tests/fixtures/000-smoke/src/add.lisp
;;;;
;;;; ADD is supposed to return X+Y, but is currently coded as X-Y.
;;;; The accompanying test in tests/add-test.lisp will fail until the
;;;; cl-harness agent loop patches the body back to use #'+.

(defpackage #:smoke/src/add
  (:nicknames #:smoke)
  (:use #:cl)
  (:export #:add))

(in-package #:smoke/src/add)

(defun add (x y)
  "Return the sum of X and Y."
  (- x y))
