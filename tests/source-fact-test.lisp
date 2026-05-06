;;;; tests/source-fact-test.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.5, docs/plans/2026-05-07-phase-b-source-patch-failure.md).
;;;; Covers SOURCE-FACT construction, defaults, and validation. The
;;;; develop-state-side recording semantics are tested in
;;;; tests/state-test.lisp once Task 4 lands the slot wiring.

(defpackage #:cl-harness/tests/source-fact-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact
                #:make-source-fact
                #:source-fact-path
                #:source-fact-form-type
                #:source-fact-form-name
                #:source-fact-read-at
                #:source-fact-mtime-at-read
                #:source-fact-related-step-index
                #:source-fact-via-tool))

(in-package #:cl-harness/tests/source-fact-test)

(defun %make (&rest overrides)
  (apply #'make-source-fact
         :path #P"/tmp/demo/src/greet.lisp"
         :via-tool "lisp-read-file"
         overrides))

(deftest make-source-fact-accepts-required-args
  (let ((s (%make)))
    (ok (typep s 'source-fact))
    (ok (equal #P"/tmp/demo/src/greet.lisp" (source-fact-path s)))
    (ok (string= "lisp-read-file" (source-fact-via-tool s)))))

(deftest make-source-fact-defaults
  (let ((s (%make)))
    (ok (null (source-fact-form-type s)))
    (ok (null (source-fact-form-name s)))
    (ok (null (source-fact-related-step-index s)))
    (ok (numberp (source-fact-read-at s)))
    (ok (or (null (source-fact-mtime-at-read s))
            (numberp (source-fact-mtime-at-read s))))))

(deftest make-source-fact-with-form-targeting
  (let ((s (%make :form-type "defun"
                  :form-name "greet"
                  :related-step-index 2)))
    (ok (string= "defun" (source-fact-form-type s)))
    (ok (string= "greet" (source-fact-form-name s)))
    (ok (= 2 (source-fact-related-step-index s)))))

(deftest make-source-fact-rejects-non-pathname-path
  (ok (handler-case
          (progn (make-source-fact :path 42 :via-tool "lisp-read-file")
                 nil)
        (error () t))))

(deftest make-source-fact-rejects-blank-via-tool
  (ok (handler-case
          (progn (make-source-fact :path #P"/tmp/x.lisp" :via-tool "")
                 nil)
        (error () t))))

(deftest make-source-fact-coerces-string-path-to-pathname
  (let ((s (make-source-fact :path "/tmp/demo/src/greet.lisp"
                             :via-tool "lisp-read-file")))
    (ok (pathnamep (source-fact-path s)))
    (ok (equal #P"/tmp/demo/src/greet.lisp" (source-fact-path s)))))
