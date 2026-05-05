(defpackage #:missing-import/src/main
  (:nicknames #:missing-import)
  (:use #:cl)
  (:export #:add-one))

(in-package #:missing-import/src/main)

(defun add-one (x)
  "Return X plus one."
  (1+ x))
