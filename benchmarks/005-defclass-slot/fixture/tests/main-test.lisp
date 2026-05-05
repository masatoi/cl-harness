(defpackage #:defclass-bug/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:defclass-bug #:user #:user-name))

(in-package #:defclass-bug/tests/main-test)

(deftest user-stores-name
  (testing "make-instance accepts :name and reader returns it"
    (let ((u (make-instance 'user :name "Alice")))
      (ok (string= "Alice" (user-name u))))))
