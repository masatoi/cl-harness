(defpackage #:error-signal/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:error-signal #:safe-div))

(in-package #:error-signal/tests/main-test)

(deftest safe-div-rejects-zero
  (testing "non-zero divisor returns the quotient"
    (ok (= 2 (safe-div 10 5))))
  (testing "zero divisor signals an error"
    (ok (handler-case (progn (safe-div 1 0) nil)
          (error () t)))))
