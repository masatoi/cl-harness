(defpackage #:typo-defun/src/main
  (:nicknames #:typo-defun)
  (:use #:cl)
  (:export #:greet))

(in-package #:typo-defun/src/main)

;; BUG: defun is named `gret`, but the package exports `greet`.
;; Calling typo-defun:greet at test time errors with "undefined function".
(defun gret (name)
  "Return a friendly greeting for NAME."
  (format nil "Hi ~A" name))
