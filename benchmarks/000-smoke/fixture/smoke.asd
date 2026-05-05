;;;; tests/fixtures/000-smoke/smoke.asd
;;;;
;;;; Phase 3.5 end-to-end smoke fixture (package-inferred-system layout
;;;; mirroring cl-harness's own tests). The ADD function in src/add.lisp
;;;; is deliberately broken; the cl-harness agent loop is supposed to
;;;; observe the failing rove test and patch it back to addition.

(asdf:defsystem "smoke"
  :class :package-inferred-system
  :description "Smoke fixture for cl-harness end-to-end runs."
  :license "MIT"
  :version "0.0.1"
  :depends-on ("smoke/src/add")
  :in-order-to ((test-op (test-op "smoke/tests"))))

(asdf:defsystem "smoke/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "smoke"
               "smoke/tests/add-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "smoke/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
