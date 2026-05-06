;;;; develop-benchmarks/105-validate-email/fixture/src/main.lisp

(defpackage #:email-validator/src/main
  (:nicknames #:email-validator)
  (:use #:cl)
  (:export #:validate-email))

(in-package #:email-validator/src/main)
