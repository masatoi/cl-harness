(asdf:defsystem "email-validator"
  :class :package-inferred-system
  :description "v0.4 develop-benchmarks fixture 105: greenfield email-shape predicate."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("email-validator/src/main")
  :in-order-to ((test-op (test-op "email-validator/tests"))))

(asdf:defsystem "email-validator/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "email-validator"
               "email-validator/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "email-validator/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
