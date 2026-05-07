;;;; src/source-fact.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.5). One source-fact records that
;;;; the agent (or the orchestrator) read a particular file (and
;;;; optionally a particular form within it) at a particular point
;;;; in time, with the file's mtime at the moment of read.
;;;;
;;;; Phase B only RECORDS source-facts. Phase C consumes them in
;;;; context-view generation; Phase E uses them for staleness
;;;; invalidation. This file therefore stays a pure data container
;;;; with zero inbound deps on other cl-harness packages.

(defpackage #:cl-harness/src/source-fact
  (:use #:cl)
  (:export #:source-fact
           #:make-source-fact
           #:source-fact-path
           #:source-fact-form-type
           #:source-fact-form-name
           #:source-fact-read-at
           #:source-fact-mtime-at-read
           #:source-fact-related-step-index
           #:source-fact-via-tool
           #:source-fact-stale-p))

(in-package #:cl-harness/src/source-fact)

(defclass source-fact ()
  ((path :initarg :path :reader source-fact-path
         :documentation "Pathname of the file that was read. Always a
PATHNAME after MAKE-SOURCE-FACT (string inputs are coerced).")
   (form-type :initarg :form-type :reader source-fact-form-type
              :initform nil
              :documentation "When the read targeted a specific
top-level form, the form-type string (e.g. \"defun\", \"defclass\").
NIL when the read was whole-file or pattern-driven.")
   (form-name :initarg :form-name :reader source-fact-form-name
              :initform nil
              :documentation "Name of the targeted form, when
applicable. NIL otherwise.")
   (read-at :initarg :read-at :reader source-fact-read-at
            :documentation "GET-UNIVERSAL-TIME at the moment of
record. Always populated by MAKE-SOURCE-FACT.")
   (mtime-at-read :initarg :mtime-at-read
                  :reader source-fact-mtime-at-read
                  :initform nil
                  :documentation "FILE-WRITE-DATE of PATH at the
moment of read, or NIL when the file did not exist (or the call
site declined to stat it).")
   (related-step-index :initarg :related-step-index
                       :reader source-fact-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the step
active when the read happened, or NIL outside a develop run.")
   (via-tool :initarg :via-tool :reader source-fact-via-tool
             :documentation "Name of the cl-mcp tool that performed
the read (e.g. \"lisp-read-file\", \"fs-read-file\",
\"clgrep-search\"). Required, non-empty."))
  (:documentation
   "One observation that a particular file/form was read at a
particular time, with the file's mtime at that moment captured for
later staleness checks. Phase B records source-facts; Phase E uses
them for invalidation."))

(defun make-source-fact (&key path via-tool form-type form-name
                           related-step-index
                           (read-at (get-universal-time))
                           (mtime-at-read nil mtime-supplied-p))
  "Construct a SOURCE-FACT. PATH must be a pathname or string (string
is coerced to pathname). VIA-TOOL must be a non-empty string.
MTIME-AT-READ defaults to the file's FILE-WRITE-DATE when PATH
exists; pass an explicit value (including NIL) to override the
auto-stat."
  (let ((coerced-path (cond
                        ((pathnamep path) path)
                        ((stringp path) (pathname path))
                        (t (error "source-fact: :path must be a ~
pathname or string, got ~S" path)))))
    (unless (and (stringp via-tool) (plusp (length via-tool)))
      (error "source-fact: :via-tool must be a non-empty string, got ~S"
             via-tool))
    (when form-type (check-type form-type string))
    (when form-name (check-type form-name string))
    (when related-step-index (check-type related-step-index integer))
    (let ((effective-mtime
            (if mtime-supplied-p
                mtime-at-read
                (handler-case (file-write-date coerced-path)
                  (error () nil)))))
      (make-instance 'source-fact
                     :path coerced-path
                     :form-type form-type
                     :form-name form-name
                     :read-at read-at
                     :mtime-at-read effective-mtime
                     :related-step-index related-step-index
                     :via-tool via-tool))))

(defun source-fact-stale-p (fact)
  "Return T when FACT's path on disk has been modified since the
read recorded by the fact (i.e. (file-write-date path) >
(source-fact-mtime-at-read fact)). Returns NIL when:
- The fact has no recorded mtime (no baseline to compare against).
- The file no longer exists (no current mtime to read).
- The file's mtime equals or precedes the recorded baseline.

The third branch is the typical 'no staleness' case: the file is
unchanged since the read.

This is a pure predicate — no side effects, no caching. Phase E
introduces it as a building block; Phase F may wire it into
context-view filtering or invalidation."
  (let ((recorded (source-fact-mtime-at-read fact)))
    (and recorded
         (let ((current (handler-case (file-write-date (source-fact-path fact))
                          (error () nil))))
           (and current (> current recorded))))))
