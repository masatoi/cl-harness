(asdf:defsystem "let-bug"
  :class :package-inferred-system
  :description "Phase 5 task fixture: dependent binding under LET instead of LET*."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("let-bug/src/main")
  :in-order-to ((test-op (test-op "let-bug/tests"))))

(asdf:defsystem "let-bug/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "let-bug"
               "let-bug/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "let-bug/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
