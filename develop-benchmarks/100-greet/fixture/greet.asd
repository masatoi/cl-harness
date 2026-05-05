(asdf:defsystem "greet"
  :class :package-inferred-system
  :description "P3 develop-benchmarks fixture 100: greenfield greet function."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("greet/src/main")
  :in-order-to ((test-op (test-op "greet/tests"))))

(asdf:defsystem "greet/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "greet"
               "greet/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "greet/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
