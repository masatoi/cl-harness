(asdf:defsystem "counter"
  :class :package-inferred-system
  :description "v0.4 develop-benchmarks fixture 102: greenfield counter defclass with two generic functions."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("counter/src/main")
  :in-order-to ((test-op (test-op "counter/tests"))))

(asdf:defsystem "counter/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "counter"
               "counter/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "counter/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
