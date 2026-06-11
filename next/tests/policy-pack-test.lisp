;;;; next/tests/policy-pack-test.lisp
;;;;
;;;; Unit tests for next/src/policy-pack.lisp: semver, hardened sexp
;;;; loading, schema validation, accessors, content fingerprint
;;;; (spec §10.1 — policy pack as versioned, fingerprinted data).

(defpackage #:cl-harness-next/tests/policy-pack-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/policy-pack
                #:parse-semver
                #:semver<))

(in-package #:cl-harness-next/tests/policy-pack-test)

(deftest semver-parses-to-integer-triple
  (ok (equal '(1 2 3) (parse-semver "1.2.3")))
  (ok (equal '(0 1 0) (parse-semver "0.1.0"))))

(deftest semver-rejects-non-semver
  (dolist (bad '("1.2" "1.2.3.4" "1.2.x" "" "v1.2.3"))
    (ok (handler-case (progn (parse-semver bad) nil)
          (error () t))
        (format nil "~S should not parse" bad))))

(deftest semver-comparison
  (ok (semver< "0.9.9" "0.10.0"))
  (ok (semver< "1.0.0" "2.0.0"))
  (ok (semver< "1.0.0" "1.0.1"))
  (ok (not (semver< "1.0.0" "1.0.0")))
  (ok (not (semver< "2.0.0" "1.9.9"))))
