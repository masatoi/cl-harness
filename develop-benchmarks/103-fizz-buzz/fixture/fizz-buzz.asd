(asdf:defsystem "fizz-buzz"
  :class :package-inferred-system
  :description "v0.4 develop-benchmarks fixture 103: greenfield FizzBuzz function."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("fizz-buzz/src/main")
  :in-order-to ((test-op (test-op "fizz-buzz/tests"))))

(asdf:defsystem "fizz-buzz/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "fizz-buzz"
               "fizz-buzz/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "fizz-buzz/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
