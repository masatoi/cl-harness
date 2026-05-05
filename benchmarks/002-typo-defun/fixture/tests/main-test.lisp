(defpackage #:typo-defun/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:typo-defun #:greet))

(in-package #:typo-defun/tests/main-test)

(deftest greet-says-hi
  (testing "greet \"Alice\" returns \"Hi Alice\""
    (ok (string= "Hi Alice" (greet "Alice"))))
  (testing "greet \"Bob\" returns \"Hi Bob\""
    (ok (string= "Hi Bob" (greet "Bob")))))
