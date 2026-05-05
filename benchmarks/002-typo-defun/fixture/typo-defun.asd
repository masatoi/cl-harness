(asdf:defsystem "typo-defun"
  :class :package-inferred-system
  :description "Phase 5 task fixture: defun name typo for the exported symbol."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("typo-defun/src/main")
  :in-order-to ((test-op (test-op "typo-defun/tests"))))

(asdf:defsystem "typo-defun/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "typo-defun"
               "typo-defun/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "typo-defun/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
