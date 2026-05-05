(asdf:defsystem "unbound-symbol"
  :class :package-inferred-system
  :description "Phase 5 task fixture: function references an unbound symbol."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("unbound-symbol/src/main")
  :in-order-to ((test-op (test-op "unbound-symbol/tests"))))

(asdf:defsystem "unbound-symbol/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "unbound-symbol"
               "unbound-symbol/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "unbound-symbol/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
