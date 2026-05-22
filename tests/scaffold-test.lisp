;;;; tests/scaffold-test.lisp
;;;;
;;;; rove deftests for cl-harness/src/scaffold. All tests run against
;;;; uiop:with-temporary-directory tmpdirs and never touch the network
;;;; or an LLM provider.

(defpackage #:cl-harness/tests/scaffold-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/scaffold
                #:scaffold
                #:scaffold-result
                #:scaffold-result-status
                #:scaffold-result-paths-written
                #:scaffold-result-conflicts
                #:scaffold-bad-system-name
                #:scaffold-partial-state
                #:scaffold-partial-state-existing
                #:scaffold-partial-state-missing))

(in-package #:cl-harness/tests/scaffold-test)

(deftest system-name-validation
  (testing "valid system names pass"
    (ok (cl-harness/src/scaffold::%validate-system-name "demo"))
    (ok (cl-harness/src/scaffold::%validate-system-name "foo-bar"))
    (ok (cl-harness/src/scaffold::%validate-system-name "a1")))
  (testing "invalid system names raise scaffold-bad-system-name"
    (dolist (bad '("Demo" "foo_bar" "" "0name" "-leading" "trailing-"))
      (ok (handler-case
              (progn (cl-harness/src/scaffold::%validate-system-name bad) nil)
            (scaffold-bad-system-name () t))
          (format nil "~S should be rejected" bad)))))
