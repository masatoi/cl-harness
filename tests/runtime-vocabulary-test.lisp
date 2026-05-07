;;;; tests/runtime-vocabulary-test.lisp

(defpackage #:cl-harness/tests/runtime-vocabulary-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:runtime-vocab-fact
                #:make-runtime-vocab-fact
                #:runtime-vocab-fact-kind
                #:runtime-vocab-fact-name
                #:runtime-vocab-fact-package
                #:runtime-vocab-fact-via-tool
                #:runtime-vocab-fact-probed-at
                #:runtime-vocab-fact-stale-p
                #:+supported-runtime-vocab-kinds+))

(in-package #:cl-harness/tests/runtime-vocabulary-test)

(deftest make-runtime-vocab-fact-records-required-fields
  (let ((fact (make-runtime-vocab-fact
               :kind :function :name "foo" :package "CL-USER"
               :via-tool "code-describe")))
    (ok (typep fact 'runtime-vocab-fact))
    (ok (eq :function (runtime-vocab-fact-kind fact)))
    (ok (string= "foo" (runtime-vocab-fact-name fact)))
    (ok (string= "CL-USER" (runtime-vocab-fact-package fact)))
    (ok (string= "code-describe" (runtime-vocab-fact-via-tool fact)))
    (ok (integerp (runtime-vocab-fact-probed-at fact)))))

(deftest make-runtime-vocab-fact-rejects-unknown-kind
  (ok (handler-case
          (progn
            (make-runtime-vocab-fact :kind :goblin :name "x" :via-tool "t")
            nil)
        (error () t))))

(deftest make-runtime-vocab-fact-rejects-empty-name
  (ok (handler-case
          (progn
            (make-runtime-vocab-fact :kind :function :name "" :via-tool "t")
            nil)
        (error () t))))

(deftest make-runtime-vocab-fact-rejects-empty-via-tool
  (ok (handler-case
          (progn
            (make-runtime-vocab-fact :kind :function :name "x" :via-tool "")
            nil)
        (error () t))))

(deftest supported-kinds-cover-spec
  ;; docs/context-management.md §3.4: package, exported/internal symbols,
  ;; functions, generic functions, methods, classes, macros, conditions,
  ;; ASDF systems, test systems. We collapse to a flat keyword set.
  (dolist (k '(:package :symbol :function :generic-function :method
               :class :macro :condition :asdf-system))
    (ok (member k +supported-runtime-vocab-kinds+) (format nil "~A" k))))

(deftest stale-p-returns-nil-when-no-source-file
  (let ((fact (make-runtime-vocab-fact
               :kind :function :name "foo" :via-tool "code-describe")))
    (ok (null (runtime-vocab-fact-stale-p fact)))))

(deftest stale-p-returns-t-when-source-file-mtime-exceeds-probed-at
  (let ((path (uiop:tmpize-pathname
               (merge-pathnames "rv-stale-test.lisp"
                                (uiop:default-temporary-directory))))
        (fact nil))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output
                                   :if-does-not-exist :create
                                   :if-exists :supersede)
             (format s ";; placeholder~%"))
           (setf fact (make-runtime-vocab-fact
                       :kind :function :name "foo"
                       :source-file path
                       :probed-at 100
                       :via-tool "code-describe"))
           (ok (runtime-vocab-fact-stale-p fact)))
      (when (probe-file path) (delete-file path)))))

(deftest stale-p-returns-nil-when-source-file-mtime-is-fresh
  (let ((path (uiop:tmpize-pathname
               (merge-pathnames "rv-fresh-test.lisp"
                                (uiop:default-temporary-directory))))
        (fact nil))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output
                                   :if-does-not-exist :create
                                   :if-exists :supersede)
             (format s ";; placeholder~%"))
           (setf fact (make-runtime-vocab-fact
                       :kind :function :name "foo"
                       :source-file path
                       :probed-at (file-write-date path)
                       :via-tool "code-describe"))
           (ok (null (runtime-vocab-fact-stale-p fact))))
      (when (probe-file path) (delete-file path)))))
