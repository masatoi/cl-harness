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
               "bordeaux-threads"
               "cl-harness-next/src/main")
  :in-order-to ((test-op (test-op "cl-harness-next/tests"))))

(asdf:defsystem "cl-harness-next/tests"
  :class :package-inferred-system
  :pathname "next"
  :depends-on ("rove"
               "cl-harness-next"
               "cl-harness-next/tests/main-test"
               "cl-harness-next/tests/event-test"
               "cl-harness-next/tests/event-log-test"
               "cl-harness-next/tests/policy-pack-test"
               "cl-harness-next/tests/mcp-client-test"
               "cl-harness-next/tests/mcp-stdio-test"
               "cl-harness-next/tests/action-space-test"
               "cl-harness-next/tests/environment-test"
               "cl-harness-next/tests/projection-test"
               "cl-harness-next/tests/goal-projection-test"
               "cl-harness-next/tests/exploration-ledger-test"
               "cl-harness-next/tests/change-ledger-test"
               "cl-harness-next/tests/verification-ledger-test"
               "cl-harness-next/tests/world-model-test"
               "cl-harness-next/tests/context-compiler-test"
               "cl-harness-next/tests/oracle-test"
               "cl-harness-next/tests/invariant-oracle-test"
               "cl-harness-next/tests/verification-oracle-test"
               "cl-harness-next/tests/review-oracle-test"
               "cl-harness-next/tests/governor-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cl-harness-next/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
