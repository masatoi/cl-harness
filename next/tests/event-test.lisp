;;;; next/tests/event-test.lisp
;;;;
;;;; Unit tests for next/src/event.lisp: type vocabulary, wire-name
;;;; conversion, JSON roundtrip (spec §8.1 — coarse, versioned schema).

(defpackage #:cl-harness-next/tests/event-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:+event-types+
                #:event-type-name
                #:event-type-keyword
                #:unknown-event-type))

(in-package #:cl-harness-next/tests/event-test)

(deftest wire-name-conversion
  (ok (equal "run_start" (event-type-name :run-start)))
  (ok (equal "oracle_result" (event-type-name :oracle-result)))
  (ok (eq :run-start (event-type-keyword "run_start")))
  (ok (eq :note (event-type-keyword "note"))))

(deftest unknown-types-signal
  (ok (handler-case (progn (event-type-name :no-such-type) nil)
        (unknown-event-type () t)))
  (ok (handler-case (progn (event-type-keyword "no_such_type") nil)
        (unknown-event-type () t))))

(deftest vocabulary-is-coarse
  ;; Spec §8.1: keep the vocabulary deliberately small. If this test
  ;; starts failing because the list grew past 12, stop and check the
  ;; new type really cannot be expressed as a payload of an existing one.
  (ok (<= (length +event-types+) 12)))
