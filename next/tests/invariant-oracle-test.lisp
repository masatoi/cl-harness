;;;; next/tests/invariant-oracle-test.lisp
;;;;
;;;; Unit tests for next/src/invariant-oracle.lisp — the deterministic
;;;; AST gate generalizing legacy validate-test-source (spec §7
;;;; invariant oracle, §12 test-change L1 defense).

(defpackage #:cl-harness-next/tests/invariant-oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/invariant-oracle
                #:invariant-oracle))

(in-package #:cl-harness-next/tests/invariant-oracle-test)

(defparameter *good-test-source*
  "(in-package :foo)

(deftest my-test
  (ok (= 1 1)))")

(deftest clean-single-deftest-passes
  (ok (verdict-pass-p
       (evaluate (make-instance 'invariant-oracle) *good-test-source*))))

(deftest skip-anywhere-fails
  (let ((verdict (evaluate (make-instance 'invariant-oracle)
                           "(deftest t1 (if x (skip \"later\") (ok t)))")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "skip" (verdict-reason verdict)))))

(deftest deftest-count-must-be-one
  (ok (not (verdict-pass-p
            (evaluate (make-instance 'invariant-oracle)
                      "(deftest a (ok t)) (deftest b (ok t))"))))
  (ok (not (verdict-pass-p
            (evaluate (make-instance 'invariant-oracle)
                      "(defun helper () 1)")))))

(deftest unreadable-source-fails
  (let ((verdict (evaluate (make-instance 'invariant-oracle)
                           "(deftest a (ok t)")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "unreadable" (verdict-reason verdict)))))

(deftest read-eval-is-rejected-by-reader
  (ok (not (verdict-pass-p
            (evaluate (make-instance 'invariant-oracle)
                      "(deftest a (ok #.(+ 1 2)))")))))

(deftest invariants-are-configurable
  (let ((oracle (make-instance 'invariant-oracle :invariants '(:no-skip))))
    (ok (verdict-pass-p
         (evaluate oracle "(deftest a (ok t)) (deftest b (ok t))")))))

(deftest package-qualified-deftest-counts
  (ok (verdict-pass-p
       (evaluate (make-instance 'invariant-oracle)
                 "(rove:deftest a (ok t))"))))
