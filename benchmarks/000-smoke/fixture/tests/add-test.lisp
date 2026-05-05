;;;; tests/fixtures/000-smoke/tests/add-test.lisp
;;;;
;;;; Failing rove test exposing the bug in smoke:add.

(defpackage #:smoke/tests/add-test
  (:use #:cl #:rove)
  (:import-from #:smoke #:add))

(in-package #:smoke/tests/add-test)

(deftest add-returns-sum
  (testing "2 + 3 should be 5"
    (ok (= 5 (add 2 3))))
  (testing "10 + 7 should be 17"
    (ok (= 17 (add 10 7)))))
