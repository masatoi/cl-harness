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
               "cl-harness/src/main")
  :in-order-to ((test-op (test-op "cl-harness/tests"))))

(asdf:defsystem "cl-harness/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "cl-harness"
               "cl-harness/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cl-harness/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
