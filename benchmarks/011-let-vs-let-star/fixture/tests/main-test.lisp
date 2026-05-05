(defpackage #:let-bug/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:let-bug #:compute-result))

(in-package #:let-bug/tests/main-test)

(deftest compute-result-correct
  (testing "(compute-result 2) returns 5 (= 2*2 + 1)"
    (ok (= 5 (compute-result 2))))
  (testing "(compute-result 7) returns 15 (= 7*2 + 1)"
    (ok (= 15 (compute-result 7)))))
