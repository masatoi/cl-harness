(defpackage #:unbound-symbol/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:unbound-symbol #:sum-counts))

(in-package #:unbound-symbol/tests/main-test)

(deftest sum-counts
  (testing "summing string lengths"
    (ok (= 9 (sum-counts '("abc" "def" "ghi")))))
  (testing "empty input returns zero"
    (ok (= 0 (sum-counts '())))))
