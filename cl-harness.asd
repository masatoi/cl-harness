;;;; cl-harness.asd

(asdf:defsystem "cl-harness"
  :class :package-inferred-system
  :description "Runtime-native coding agent harness for Common Lisp."
  :author "cl-harness contributors"
  :license "MIT"
  :version "0.0.1"
  :depends-on ("alexandria"
               "yason"
               "local-time"
               "dexador"
               "cl-harness/src/main")
  :in-order-to ((test-op (test-op "cl-harness/tests"))))

(asdf:defsystem "cl-harness/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "cl-harness"
               "cl-harness/tests/main-test"
               "cl-harness/tests/mcp-test"
               "cl-harness/tests/model-test"
               "cl-harness/tests/action-test"
               "cl-harness/tests/policy-test"
               "cl-harness/tests/verify-test"
               "cl-harness/tests/agent-test"
               "cl-harness/tests/bench-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cl-harness/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
