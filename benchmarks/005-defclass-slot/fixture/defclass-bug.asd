(asdf:defsystem "defclass-bug"
  :class :package-inferred-system
  :description "Phase 5 task fixture: defclass slot has a misspelled :initarg."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("defclass-bug/src/main")
  :in-order-to ((test-op (test-op "defclass-bug/tests"))))

(asdf:defsystem "defclass-bug/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "defclass-bug"
               "defclass-bug/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "defclass-bug/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
