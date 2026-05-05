(asdf:defsystem "defmethod-bug"
  :class :package-inferred-system
  :description "Phase 5 task fixture: defmethod specializer typo on a CLOS class."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("defmethod-bug/src/main")
  :in-order-to ((test-op (test-op "defmethod-bug/tests"))))

(asdf:defsystem "defmethod-bug/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "defmethod-bug"
               "defmethod-bug/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "defmethod-bug/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
