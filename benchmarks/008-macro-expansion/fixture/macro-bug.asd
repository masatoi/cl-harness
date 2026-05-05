(asdf:defsystem "macro-bug"
  :class :package-inferred-system
  :description "Phase 5 task fixture: with-counter macro expansion bug."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("macro-bug/src/main")
  :in-order-to ((test-op (test-op "macro-bug/tests"))))

(asdf:defsystem "macro-bug/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "macro-bug"
               "macro-bug/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "macro-bug/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
