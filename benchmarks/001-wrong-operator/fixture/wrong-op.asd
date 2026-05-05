(asdf:defsystem "wrong-op"
  :class :package-inferred-system
  :description "Phase 5 task fixture: max-of uses the wrong comparison."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("wrong-op/src/main")
  :in-order-to ((test-op (test-op "wrong-op/tests"))))

(asdf:defsystem "wrong-op/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "wrong-op"
               "wrong-op/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "wrong-op/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
