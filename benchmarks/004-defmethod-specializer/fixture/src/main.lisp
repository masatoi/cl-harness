(defpackage #:defmethod-bug/src/main
  (:nicknames #:defmethod-bug)
  (:use #:cl)
  (:export #:dog #:dog-name #:bark))

(in-package #:defmethod-bug/src/main)

(defclass dog ()
  ((name :initarg :name :reader dog-name)))

;; BUG: bark is specialized on STRING, but the test calls (bark <dog>),
;; which signals NO-APPLICABLE-METHOD at runtime.
(defmethod bark ((d string))
  (format nil "Woof from ~A" d))
