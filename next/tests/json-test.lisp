;;;; next/tests/json-test.lisp
;;;;
;;;; Regression tests for next/src/json.lisp: next/'s JSON decoding is
;;;; pinned (hash-table objects, LIST arrays, t/nil booleans) even when
;;;; ambient yason globals say otherwise — the cl-mcp worker setfs
;;;; *parse-json-arrays-as-vectors* globally, which made arrays parse
;;;; as vectors there and as lists in clean images (SP5a finding).

(defpackage #:cl-harness-next/tests/json-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/json
                #:parse-json)
  (:import-from #:cl-harness-next/src/event
                #:event-payload
                #:json-string->event)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:agent-action-arguments))

(in-package #:cl-harness-next/tests/json-test)

(deftest parse-json-pins-arrays-to-lists
  (let ((yason:*parse-json-arrays-as-vectors* t))
    (ok (listp (parse-json "[1,2,3]")))
    (ok (equal '(1 2 3) (parse-json "[1,2,3]")))))

(deftest event-payload-arrays-are-lists-under-hostile-globals
  (let ((yason:*parse-json-arrays-as-vectors* t))
    (let ((event (json-string->event
                  (concatenate 'string
                               "{\"seq\":1,\"type\":\"run_start\","
                               "\"timestamp\":\"t\",\"schema_version\":1,"
                               "\"payload\":{\"acceptance_criteria\":"
                               "[\"a\",\"b\"]}}"))))
      (ok (listp (gethash "acceptance_criteria" (event-payload event))))
      (ok (equal '("a" "b")
                 (gethash "acceptance_criteria" (event-payload event)))))))

(deftest action-argument-arrays-are-lists-under-hostile-globals
  (let ((yason:*parse-json-arrays-as-vectors* t))
    (let ((action (parse-action
                   (concatenate 'string
                                "{\"type\":\"tool_call\",\"tool\":\"run-tests\","
                                "\"arguments\":{\"tests\":[\"t1\",\"t2\"]}}"))))
      (ok (listp (gethash "tests" (agent-action-arguments action)))))))

(deftest object-keys-stay-strings-under-hostile-key-fn
  ;; SP8 final-review hardening: the one interning-relevant decoder
  ;; knob is pinned too — an ambient key-fn cannot intern wire keys.
  (let ((yason:*parse-object-key-fn*
          (lambda (key) (intern (string-upcase key) :keyword))))
    (let ((parsed (parse-json "{\"some_wire_key\":1}")))
      (ok (equal '("some_wire_key")
                 (alexandria:hash-table-keys parsed))))))
