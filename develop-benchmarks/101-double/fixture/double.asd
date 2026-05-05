(asdf:defsystem "double"
  :class :package-inferred-system
  :description "P3 develop-benchmarks fixture 101: greenfield double function."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("double/src/main")
  :in-order-to ((test-op (test-op "double/tests"))))

(asdf:defsystem "double/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "double"
               "double/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "double/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
