(defpackage #:missing-import/tests/main-test
  (:use #:cl #:rove)
  ;; BUG: typo — should be #:add-one, not #:add-tow.
  (:import-from #:missing-import #:add-tow))

(in-package #:missing-import/tests/main-test)

(deftest add-one-increments
  (testing "add-one 5 returns 6"
    (ok (= 6 (add-tow 5))))
  (testing "add-one 0 returns 1"
    (ok (= 1 (add-tow 0)))))
