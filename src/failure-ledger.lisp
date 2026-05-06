;;;; src/failure-ledger.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.9 + §8). Captures load/test
;;;; failures observed during a develop run. Maintains an active
;;;; vs resolved partition so context views and final reports can
;;;; distinguish "currently broken" from "fixed earlier in the run".
;;;;
;;;; Sourced from VERIFY-RESULT.test-result hash-tables via
;;;; PARSE-FAILURE-RECORDS-FROM-TEST-RESULT. Phase B only RECORDS
;;;; failures; Phase C surfaces them in failure-analysis context
;;;; views (docs/context-management.md §8).

(defpackage #:cl-harness/src/failure-ledger
  (:use #:cl)
  (:export #:failure-record
           #:make-failure-record
           #:failure-record-kind
           #:failure-record-description
           #:failure-record-test-name
           #:failure-record-assertion-form
           #:failure-record-reason
           #:failure-record-source-file
           #:failure-record-source-line
           #:failure-record-related-step-index
           #:failure-record-related-patch
           #:failure-record-observed-at
           #:failure-record-status
           #:failure-record-resolved-at
           #:failure-record-resolved-by-patch
           #:failure-record-verify-source
           #:failure-ledger
           #:make-failure-ledger
           #:failure-ledger-active
           #:failure-ledger-resolved
           #:record-failure
           #:mark-resolved-by
           #:parse-failure-records-from-test-result
           #:+supported-failure-kinds+
           #:+supported-failure-statuses+
           #:+supported-verify-sources+))

(in-package #:cl-harness/src/failure-ledger)

(defparameter +supported-failure-kinds+
  '(:load-failed :test-failed :parse-error :other)
  "Kinds of failure a record can describe. :LOAD-FAILED corresponds
to verify-result :LOAD-FAILED; :TEST-FAILED to a single rove
deftest's failure within :TEST-FAILED. :PARSE-ERROR is reserved
for action-parse / test-source validation failures Phase B doesn't
yet wire. :OTHER is the catch-all.")

(defparameter +supported-failure-statuses+
  '(:active :resolved)
  "Lifecycle of a single failure record.")

(defparameter +supported-verify-sources+
  '(:incremental :clean)
  "Which verify pass observed the failure. Mirrors
src/patch-record.lisp:+supported-verify-sources+.")

(defclass failure-record ()
  ((kind :initarg :kind :reader failure-record-kind
         :documentation "One of +SUPPORTED-FAILURE-KINDS+.")
   (description :initarg :description
                :reader failure-record-description
                :documentation "Short one-line summary suitable
for a context-view header.")
   (test-name :initarg :test-name :initform nil
              :reader failure-record-test-name
              :documentation "For :TEST-FAILED, the rove deftest
name. NIL for other kinds.")
   (assertion-form :initarg :assertion-form :initform nil
                   :reader failure-record-assertion-form
                   :documentation "The failing assertion source as
captured by rove (the \"form\" key in failed_tests entries). NIL
when unavailable.")
   (reason :initarg :reason :initform nil
           :reader failure-record-reason
           :documentation "Error condition message or rove's
\"reason\" field. NIL when unavailable.")
   (source-file :initarg :source-file :initform nil
                :reader failure-record-source-file
                :documentation "Pathname (when extractable) of the
file rove blamed for the failure.")
   (source-line :initarg :source-line :initform nil
                :reader failure-record-source-line
                :documentation "Line number reported by rove, when
available.")
   (related-step-index :initarg :related-step-index
                       :initform nil
                       :reader failure-record-related-step-index
                       :documentation "PLAN-STEP-INDEX of the step
active when the failure was observed.")
   (related-patch :initarg :related-patch :initform nil
                  :reader failure-record-related-patch
                  :documentation "PATCH-RECORD active around the
time of the failure (the most recent patch on the same file at
record time), when known. NIL when no patch context applies.")
   (observed-at :initarg :observed-at
                :reader failure-record-observed-at
                :documentation "GET-UNIVERSAL-TIME at record
time.")
   (status :initform :active :reader failure-record-status
           :documentation "One of +SUPPORTED-FAILURE-STATUSES+.")
   (resolved-at :initform nil
                :reader failure-record-resolved-at
                :documentation "GET-UNIVERSAL-TIME of resolution,
or NIL while :ACTIVE.")
   (resolved-by-patch :initform nil
                      :reader failure-record-resolved-by-patch
                      :documentation "PATCH-RECORD attributed for
the resolution, or NIL when no clear-cut attribution.")
   (verify-source :initarg :verify-source
                  :reader failure-record-verify-source
                  :documentation "Which verify pass observed this
failure: :INCREMENTAL or :CLEAN."))
  (:documentation
   "One observation of a load- or test-time failure during a
develop run. Lifecycle: :ACTIVE on record; :RESOLVED via
MARK-RESOLVED-BY, with optional patch attribution."))

(defun make-failure-record (&key kind description verify-source
                              test-name assertion-form reason
                              source-file source-line
                              related-step-index related-patch
                              (observed-at (get-universal-time)))
  "Construct a FAILURE-RECORD. KIND, DESCRIPTION, VERIFY-SOURCE
required."
  (unless (member kind +supported-failure-kinds+)
    (error "failure-record: unsupported :kind ~S; expected one of ~S"
           kind +supported-failure-kinds+))
  (check-type description string)
  (unless (member verify-source +supported-verify-sources+)
    (error "failure-record: unsupported :verify-source ~S; expected ~S"
           verify-source +supported-verify-sources+))
  (when test-name (check-type test-name string))
  (when assertion-form (check-type assertion-form string))
  (when reason (check-type reason string))
  (when source-line (check-type source-line integer))
  (when related-step-index (check-type related-step-index integer))
  (let ((coerced-source-file
          (cond
            ((null source-file) nil)
            ((pathnamep source-file) source-file)
            ((stringp source-file) (pathname source-file))
            (t (error "failure-record: :source-file must be a ~
pathname, string, or NIL")))))
    (make-instance 'failure-record
                   :kind kind
                   :description description
                   :test-name test-name
                   :assertion-form assertion-form
                   :reason reason
                   :source-file coerced-source-file
                   :source-line source-line
                   :related-step-index related-step-index
                   :related-patch related-patch
                   :observed-at observed-at
                   :verify-source verify-source)))

(defclass failure-ledger ()
  ((%active :initform nil :accessor %active-internal
            :documentation "Reverse-chronological list. Public
accessor FAILURE-LEDGER-ACTIVE reverses on read.")
   (%resolved :initform nil :accessor %resolved-internal
              :documentation "Reverse-chronological list of
resolved records."))
  (:documentation
   "Active vs resolved partition over FAILURE-RECORD instances for
one develop run."))

(defun make-failure-ledger ()
  "Construct an empty FAILURE-LEDGER."
  (make-instance 'failure-ledger))

(defun failure-ledger-active (ledger)
  "Return active failures in observed order (oldest first)."
  (reverse (%active-internal ledger)))

(defun failure-ledger-resolved (ledger)
  "Return resolved failures in resolved-order (oldest resolved
first)."
  (reverse (%resolved-internal ledger)))

(defun record-failure (ledger record)
  "Push RECORD onto LEDGER's active list. Returns LEDGER."
  (push record (%active-internal ledger))
  ledger)

(defun mark-resolved-by (ledger record &key patch)
  "Move RECORD from active to resolved on LEDGER. Sets
record's status, resolved-at, resolved-by-patch (PATCH may be NIL).
Idempotent for records already absent from active. Returns LEDGER."
  (setf (%active-internal ledger)
        (remove record (%active-internal ledger) :test #'eq))
  (setf (slot-value record 'status) :resolved
        (slot-value record 'resolved-at) (get-universal-time)
        (slot-value record 'resolved-by-patch) patch)
  (push record (%resolved-internal ledger))
  ledger)

(defun %extract (h key)
  "Read KEY from hash-table H or return NIL if absent. Mirrors the
defensive pattern PARSE-VERIFY-RESULT uses for missing fields."
  (and (hash-table-p h) (gethash key h)))

(defun %coerce-failed-tests (raw)
  "Yason emits arrays as either VECTOR or LIST depending on parser
config; normalize to a list."
  (cond
    ((null raw) nil)
    ((listp raw) raw)
    ((vectorp raw) (coerce raw 'list))
    (t (error "failure-ledger: unexpected failed_tests shape ~S" raw))))

(defun parse-failure-records-from-test-result
    (test-result &key verify-source related-step-index)
  "Parse cl-mcp's run-tests TEST-RESULT hash-table into a list of
FAILURE-RECORDs. Returns NIL when TEST-RESULT is NIL, has no
failed_tests entry, or the entry is empty.

Each entry contributes one :TEST-FAILED record. Missing fields
become NIL on the record; the parser does not raise on shape drift
beyond the outermost (which is verified by yason's parser)."
  (unless (member verify-source +supported-verify-sources+)
    (error "parse-failure-records-from-test-result: bad ~
:verify-source ~S" verify-source))
  (let ((entries (%coerce-failed-tests
                  (%extract test-result "failed_tests"))))
    (loop for entry in entries
          for source-h = (%extract entry "source")
          collect
          (make-failure-record
           :kind :test-failed
           :description (or (%extract entry "description")
                            (%extract entry "test_name")
                            "unknown failure")
           :test-name (%extract entry "test_name")
           :assertion-form (%extract entry "form")
           :reason (%extract entry "reason")
           :source-file (%extract source-h "file")
           :source-line (let ((l (%extract source-h "line")))
                          (and (integerp l) l))
           :related-step-index related-step-index
           :verify-source verify-source))))
