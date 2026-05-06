(asdf:defsystem "money"
  :class :package-inferred-system
  :description "v0.4 develop-benchmarks fixture 106: greenfield format-currency function."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("money/src/main")
  :in-order-to ((test-op (test-op "money/tests"))))

(asdf:defsystem "money/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "money"
               "money/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "money/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
