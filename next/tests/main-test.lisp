;;;; next/tests/main-test.lisp
;;;;
;;;; Facade smoke tests + cross-module integration tests for
;;;; cl-harness-next (SP1: L0 substrate).

(defpackage #:cl-harness-next/tests/main-test
  (:use #:cl #:rove))

(in-package #:cl-harness-next/tests/main-test)

(deftest facade-package-exists
  (ok (find-package '#:cl-harness-next))
  (ok (equal "0.1.0" (cl-harness-next:substrate-version))))
