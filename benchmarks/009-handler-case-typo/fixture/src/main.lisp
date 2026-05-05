(defpackage #:handler-bug/src/main
  (:nicknames #:handler-bug)
  (:use #:cl)
  (:export #:my-error #:safe-op))

(in-package #:handler-bug/src/main)

(define-condition my-error (error) ()
  (:documentation "Domain-specific signal raised by SAFE-OP."))

(defun safe-op ()
  "Run a body that signals MY-ERROR, catching it and returning :HANDLED."
  ;; BUG: handler-case dispatches on TYPE-ERROR, but the body signals
  ;; MY-ERROR, so the handler does not fire and the condition escapes.
  (handler-case (error 'my-error)
    (type-error () :handled)))
