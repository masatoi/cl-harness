;;;; next/src/json.lisp
;;;;
;;;; Pinned JSON decoding for all of next/ (SP5a hardening). The
;;;; cl-mcp worker setfs yason:*parse-json-arrays-as-vectors* globally,
;;;; so raw yason:parse behaves differently inside that environment
;;;; than in a clean image. Every wire-parsing site in next/ goes
;;;; through PARSE-JSON so consumers can rely on hash-table objects,
;;;; LIST arrays, and t/nil booleans unconditionally.

(defpackage #:cl-harness-next/src/json
  (:use #:cl)
  (:export #:parse-json))

(in-package #:cl-harness-next/src/json)

(defun parse-json (input)
  "yason:parse with pinned decoder settings — hash-table objects, list
arrays, t/nil booleans — immune to ambient yason globals."
  (let ((yason:*parse-json-arrays-as-vectors* nil)
        (yason:*parse-json-booleans-as-symbols* nil)
        (yason:*parse-object-as* :hash-table)
        ;; The one interning-relevant decoder knob: keys stay strings.
        (yason:*parse-object-key-fn* #'identity))
    (yason:parse input)))
