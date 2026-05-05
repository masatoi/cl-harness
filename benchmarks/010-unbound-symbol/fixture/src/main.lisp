(defpackage #:unbound-symbol/src/main
  (:nicknames #:unbound-symbol)
  (:use #:cl)
  (:export #:sum-counts))

(in-package #:unbound-symbol/src/main)

(defun sum-counts (items)
  "Return the total count across ITEMS by summing each item's length."
  (let ((total 0))
    (dolist (item items)
      ;; BUG: SIZE is unbound here; should be (LENGTH item).
      (incf total size))
    total))
