(defpackage #:format-arity/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:format-arity #:describe-pair))

(in-package #:format-arity/tests/main-test)

(deftest pair-mentions-both
  (testing "Alice and Bob both appear"
    (let ((s (describe-pair "Alice" "Bob")))
      (ok (search "Alice" s))
      (ok (search "Bob" s)))))
