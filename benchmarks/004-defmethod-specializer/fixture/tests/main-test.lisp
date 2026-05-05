(defpackage #:defmethod-bug/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:defmethod-bug #:dog #:bark))

(in-package #:defmethod-bug/tests/main-test)

(deftest bark-from-dog
  (testing "bark on a dog returns a greeting that mentions the dog's name"
    (let ((rex (make-instance 'dog :name "Rex")))
      (ok (search "Rex" (bark rex))))))
