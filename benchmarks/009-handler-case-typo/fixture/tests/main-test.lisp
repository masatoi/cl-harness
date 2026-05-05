(defpackage #:handler-bug/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:handler-bug #:safe-op))

(in-package #:handler-bug/tests/main-test)

(deftest safe-op-handles-my-error
  (testing "safe-op returns :HANDLED rather than escaping the condition"
    (ok (eq :handled (safe-op)))))
