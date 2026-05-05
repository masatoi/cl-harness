(defpackage #:macro-bug/src/main
  (:nicknames #:macro-bug)
  (:use #:cl)
  (:export #:with-counter))

(in-package #:macro-bug/src/main)

(defmacro with-counter ((name init) &body body)
  "Bind NAME to INIT around BODY, returning NAME's final value.

Useful for incremental counters: callers can mutate NAME inside BODY
and the macro yields the post-BODY value."
  ;; BUG: the expansion returns INIT instead of NAME, so post-BODY
  ;; mutations of NAME never appear in the result.
  `(let ((,name ,init))
     ,@body
     ,init))
