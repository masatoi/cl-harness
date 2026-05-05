(asdf:defsystem "error-signal"
  :class :package-inferred-system
  :description "Phase 5 task fixture: function silently swallows an invalid input."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("error-signal/src/main")
  :in-order-to ((test-op (test-op "error-signal/tests"))))

(asdf:defsystem "error-signal/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "error-signal"
               "error-signal/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "error-signal/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
