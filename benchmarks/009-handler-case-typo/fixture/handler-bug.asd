(asdf:defsystem "handler-bug"
  :class :package-inferred-system
  :description "Phase 5 task fixture: handler-case dispatches on the wrong condition type."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("handler-bug/src/main")
  :in-order-to ((test-op (test-op "handler-bug/tests"))))

(asdf:defsystem "handler-bug/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "handler-bug"
               "handler-bug/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "handler-bug/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
