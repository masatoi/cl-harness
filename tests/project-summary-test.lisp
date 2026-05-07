;;;; tests/project-summary-test.lisp

(defpackage #:cl-harness/tests/project-summary-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/project-summary
                #:project-summary
                #:make-project-summary
                #:project-summary-project-root
                #:project-summary-system
                #:project-summary-test-system
                #:project-summary-asd-files
                #:project-summary-source-files
                #:project-summary-test-files
                #:project-summary-text
                #:project-summary-gathered-at
                #:project-summary-dirty-p
                #:project-summary-mark-dirty
                #:gather-project-summary))

(in-package #:cl-harness/tests/project-summary-test)

(deftest make-project-summary-records-fields
  (let ((s (make-project-summary
            :project-root "/tmp/p/"
            :system "x"
            :test-system "x/tests"
            :asd-files (list "x.asd")
            :source-files (list "src/main.lisp")
            :test-files (list "tests/main-test.lisp")
            :text "raw inventory text")))
    (ok (typep s 'project-summary))
    (ok (string= "x" (project-summary-system s)))
    (ok (string= "x/tests" (project-summary-test-system s)))
    (ok (pathnamep (project-summary-project-root s)))
    (ok (equal '("x.asd") (project-summary-asd-files s)))
    (ok (string= "raw inventory text" (project-summary-text s)))
    (ok (null (project-summary-dirty-p s)))
    (ok (integerp (project-summary-gathered-at s)))))

(deftest mark-dirty-flips-flag
  (let ((s (make-project-summary
            :project-root "/tmp/p/" :system "x" :test-system "x/tests")))
    (ok (null (project-summary-dirty-p s)))
    (project-summary-mark-dirty s)
    (ok (eq t (project-summary-dirty-p s)))))

(deftest mark-dirty-is-idempotent
  (let ((s (make-project-summary
            :project-root "/tmp/p/" :system "x" :test-system "x/tests")))
    (project-summary-mark-dirty s)
    (project-summary-mark-dirty s)
    (ok (eq t (project-summary-dirty-p s)))))

(deftest gather-project-summary-builds-from-real-tree
  ;; Smoke test: run gather-project-summary against the cl-harness
  ;; project itself (we know it has at least one .asd, src/main.lisp,
  ;; and tests/main-test.lisp).
  (let* ((this-root
           (asdf:system-relative-pathname :cl-harness ""))
         (s (gather-project-summary
             :project-root this-root
             :system "cl-harness"
             :test-system "cl-harness/tests")))
    (ok (typep s 'project-summary))
    (ok (member "cl-harness.asd" (project-summary-asd-files s)
                :test #'string=))
    (ok (member "src/main.lisp" (project-summary-source-files s)
                :test #'string=))
    (ok (member "tests/main-test.lisp" (project-summary-test-files s)
                :test #'string=))
    (ok (and (stringp (project-summary-text s))
             (plusp (length (project-summary-text s)))))))
