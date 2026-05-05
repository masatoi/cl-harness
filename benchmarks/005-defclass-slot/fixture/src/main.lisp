(defpackage #:defclass-bug/src/main
  (:nicknames #:defclass-bug)
  (:use #:cl)
  (:export #:user #:user-name))

(in-package #:defclass-bug/src/main)

(defclass user ()
  ;; BUG: :initarg is :usrname, so callers passing :name at make-instance
  ;; get an invalid-initarg error.
  ((name :initarg :usrname :reader user-name)))
