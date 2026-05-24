(asdf:defsystem "cache"
  :class :package-inferred-system
  :description "v0.4 develop-benchmarks fixture 104: greenfield key-value cache class."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("cache/src/main")
  :in-order-to ((test-op (test-op "cache/tests"))))

(asdf:defsystem "cache/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "cache"
               "cache/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cache/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
