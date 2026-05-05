(defpackage #:macro-bug/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:macro-bug #:with-counter))

(in-package #:macro-bug/tests/main-test)

(deftest counter-returns-final-value
  (testing "two incf calls leave counter at 2"
    (ok (= 2 (with-counter (c 0) (incf c) (incf c)))))
  (testing "no body leaves counter at init"
    (ok (= 7 (with-counter (c 7))))))
