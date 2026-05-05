(asdf:defsystem "format-arity"
  :class :package-inferred-system
  :description "Phase 5 task fixture: format string drops a positional argument."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("format-arity/src/main")
  :in-order-to ((test-op (test-op "format-arity/tests"))))

(asdf:defsystem "format-arity/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "format-arity"
               "format-arity/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "format-arity/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
