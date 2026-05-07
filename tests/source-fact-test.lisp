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
                #:source-fact-via-tool
                #:source-fact-stale-p))

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

(deftest source-fact-stale-p-returns-nil-when-mtime-not-recorded
  ;; When mtime-at-read is explicitly NIL (the recorder declined to
  ;; stat at read time), there's no baseline to compare against.
  ;; Predicate returns NIL — "no staleness signal".
  (let ((s (make-source-fact :path "/tmp/cl-harness-stale-test.lisp"
                             :via-tool "lisp-read-file"
                             :mtime-at-read nil)))
    (ok (null (source-fact-stale-p s)))))

(deftest source-fact-stale-p-returns-nil-when-file-missing
  ;; If the file no longer exists, file-write-date errors. The
  ;; predicate must not propagate; it returns NIL (no baseline match
  ;; → no signal). Phase F may upgrade to a dedicated :missing state.
  (let ((s (make-source-fact :path "/tmp/cl-harness-stale-no-such-file.lisp"
                             :via-tool "lisp-read-file"
                             :mtime-at-read 100)))
    (ok (null (source-fact-stale-p s)))))

(deftest source-fact-stale-p-returns-t-when-file-newer
  ;; Construct a fact with an old mtime, then write the file with a
  ;; current timestamp; predicate should report stale.
  (let* ((path #P"/tmp/cl-harness-stale-newer.lisp"))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (let ((s (make-source-fact :path path
                                    :via-tool "lisp-read-file"
                                    :mtime-at-read 100)))
           (ok (source-fact-stale-p s)))
      (when (probe-file path) (delete-file path)))))

(deftest source-fact-stale-p-returns-nil-when-mtime-equal
  ;; Construct a fact whose recorded mtime EQUALS the current file's
  ;; mtime. No staleness.
  (let* ((path #P"/tmp/cl-harness-stale-equal.lisp"))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (let ((s (make-source-fact :path path
                                    :via-tool "lisp-read-file"
                                    :mtime-at-read (file-write-date path))))
           (ok (null (source-fact-stale-p s))))
      (when (probe-file path) (delete-file path)))))
