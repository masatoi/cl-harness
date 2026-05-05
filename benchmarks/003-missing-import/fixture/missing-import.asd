(asdf:defsystem "missing-import"
  :class :package-inferred-system
  :description "Phase 5 task fixture: test imports a misspelled exported symbol."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("missing-import/src/main")
  :in-order-to ((test-op (test-op "missing-import/tests"))))

(asdf:defsystem "missing-import/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "missing-import"
               "missing-import/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "missing-import/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
