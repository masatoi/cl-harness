(defpackage #:wrong-op/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:wrong-op #:max-of))

(in-package #:wrong-op/tests/main-test)

(deftest max-of-returns-larger
  (testing "max-of 5 3 should be 5"
    (ok (= 5 (max-of 5 3))))
  (testing "max-of 2 9 should be 9"
    (ok (= 9 (max-of 2 9))))
  (testing "max-of 4 4 should be 4"
    (ok (= 4 (max-of 4 4)))))
