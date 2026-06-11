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
                #:unknown-event-type
                #:make-harness-event
                #:event-seq
                #:event-type
                #:event-timestamp
                #:event-schema-version
                #:event-payload
                #:event->json-string
                #:json-string->event))

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

(deftest event-json-roundtrip
  (let* ((payload (let ((h (make-hash-table :test #'equal)))
                    (setf (gethash "tool" h) "run-tests"
                          (gethash "ok" h) t
                          (gethash "count" h) 3)
                    h))
         (event (make-harness-event :action payload :seq 7))
         (line (event->json-string event))
         (back (json-string->event line)))
    (ok (not (find #\Newline line)))
    (ok (= 7 (event-seq back)))
    (ok (eq :action (event-type back)))
    (ok (equal (event-timestamp event) (event-timestamp back)))
    (ok (= 1 (event-schema-version back)))
    (ok (equal "run-tests" (gethash "tool" (event-payload back))))
    (ok (eq t (gethash "ok" (event-payload back))))
    (ok (= 3 (gethash "count" (event-payload back))))))

(deftest nil-payload-roundtrip
  (let ((back (json-string->event
               (event->json-string (make-harness-event :note nil :seq 1)))))
    (ok (null (event-payload back)))))

(deftest timestamp-defaults-to-now
  (let ((event (make-harness-event :note nil :seq 1)))
    (ok (stringp (event-timestamp event)))
    (ok (plusp (length (event-timestamp event))))))

(deftest make-event-validates-type
  (ok (handler-case (progn (make-harness-event :bogus nil :seq 1) nil)
        (unknown-event-type () t))))

(deftest unknown-event-type-prints-without-initargs
  ;; Final-review fix: conditions must print even when constructed bare.
  (ok (stringp (princ-to-string (make-condition 'unknown-event-type)))))
