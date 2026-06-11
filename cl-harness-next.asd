;;;; cl-harness-next.asd
;;;;
;;;; Greenfield redesign substrate (spec:
;;;; docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md).
;;;; Coexists with the legacy "cl-harness" system; sources live under next/.

(asdf:defsystem "cl-harness-next"
  :class :package-inferred-system
  :pathname "next"
  :description "L0 substrate for the autonomous cl-harness redesign."
  :author "cl-harness contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria"
               "yason"
               "local-time"
               "ironclad"
               "cl-harness-next/src/main")
  :in-order-to ((test-op (test-op "cl-harness-next/tests"))))

(asdf:defsystem "cl-harness-next/tests"
  :class :package-inferred-system
  :pathname "next"
  :depends-on ("rove"
               "cl-harness-next"
               "cl-harness-next/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cl-harness-next/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
