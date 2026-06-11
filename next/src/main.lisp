;;;; next/src/main.lisp
;;;;
;;;; Public facade for cl-harness-next. Re-exports the user-facing API
;;;; via :import-from + :export (shared symbol identity). Populated as
;;;; modules land; starts as a stub so the system skeleton loads.

(defpackage #:cl-harness-next/src/main
  (:nicknames #:cl-harness-next)
  (:use #:cl)
  (:export #:substrate-version))

(in-package #:cl-harness-next/src/main)

(defun substrate-version ()
  "Return the cl-harness-next system version string."
  (asdf:component-version (asdf:find-system "cl-harness-next")))
