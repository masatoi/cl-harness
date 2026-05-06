;;;; src/patch-record.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.8). One patch-record captures
;;;; one source-mutating tool invocation that succeeded -- the file,
;;;; the form (when known), the tool used, the diff summary, the
;;;; current verify outcome attributable to it, and the turn /
;;;; plan-step in which it landed.
;;;;
;;;; Phase B only RECORDS patch-records. Phase C surfaces them in
;;;; context views; Phase E links them to staleness invalidation.

(defpackage #:cl-harness/src/patch-record
  (:use #:cl)
  (:export #:patch-record
           #:make-patch-record
           #:patch-record-path
           #:patch-record-form-type
           #:patch-record-form-name
           #:patch-record-via-tool
           #:patch-record-operation
           #:patch-record-diff-summary
           #:patch-record-applied-at
           #:patch-record-related-step-index
           #:patch-record-turn
           #:patch-record-verify-status
           #:patch-record-verify-source
           #:patch-record-set-verify-status
           #:+supported-verify-statuses+
           #:+supported-verify-sources+))

(in-package #:cl-harness/src/patch-record)

(defparameter +supported-verify-statuses+
  '(:pending :passed :failed)
  "Verify-status keywords accepted by PATCH-RECORD-SET-VERIFY-STATUS.
:PENDING is the initial state; :PASSED / :FAILED are set by the
recorder once a verify-result arrives.")

(defparameter +supported-verify-sources+
  '(:incremental :clean)
  "Verify-source keywords. :INCREMENTAL is the auto-verify after
each source-mutating tool call; :CLEAN is the fresh-worker verify
that runs at run end. Mirror of the distinction
src/verify.lisp:verify-task vs clean-verify-task makes.")

(defclass patch-record ()
  ((path :initarg :path :reader patch-record-path
         :documentation "Pathname of the file the patch modified.")
   (form-type :initarg :form-type :reader patch-record-form-type
              :initform nil
              :documentation "Form-type string (e.g. \"defun\")
when the patch tool targeted a named form, NIL otherwise.")
   (form-name :initarg :form-name :reader patch-record-form-name
              :initform nil
              :documentation "Name of the targeted form, when
applicable.")
   (via-tool :initarg :via-tool :reader patch-record-via-tool
             :documentation "cl-mcp tool name that applied the
patch (e.g. \"lisp-edit-form\", \"lisp-patch-form\",
\"fs-write-file\"). Required, non-empty.")
   (operation :initarg :operation :reader patch-record-operation
              :initform nil
              :documentation "For lisp-edit-form: \"replace\",
\"insert_before\", \"insert_after\". NIL for tools without an
operation argument.")
   (diff-summary :initarg :diff-summary
                 :reader patch-record-diff-summary
                 :initform nil
                 :documentation "First ~500 chars of the unified
diff, or a short summary like \"+1/-1\". NIL when the diff was
unavailable (tool returned no before/after content).")
   (applied-at :initarg :applied-at :reader patch-record-applied-at
               :documentation "GET-UNIVERSAL-TIME at the moment the
patch landed.")
   (related-step-index :initarg :related-step-index
                       :reader patch-record-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the
active step, or NIL outside a develop run.")
   (turn :initarg :turn :reader patch-record-turn
         :documentation "Agent loop turn at which the patch landed.
Useful for ordering when multiple patches share an applied-at
second.")
   (verify-status :initform :pending
                  :reader patch-record-verify-status
                  :documentation "Current verify outcome
attributable to this patch. Updated via
PATCH-RECORD-SET-VERIFY-STATUS once a verify-result arrives.")
   (verify-source :initform nil
                  :reader patch-record-verify-source
                  :documentation "Whether the verify-status came
from an :INCREMENTAL or :CLEAN verify. NIL while
verify-status is :PENDING."))
  (:documentation
   "One source-mutating tool invocation that succeeded, plus the
verify outcome we attribute to it. Phase B records; Phase C/E
consume."))

(defun make-patch-record (&key path via-tool turn
                            form-type form-name operation diff-summary
                            related-step-index
                            (applied-at (get-universal-time)))
  "Construct a PATCH-RECORD. PATH must be a pathname or string;
VIA-TOOL non-empty string; TURN integer."
  (let ((coerced-path (cond
                        ((pathnamep path) path)
                        ((stringp path) (pathname path))
                        (t (error "patch-record: :path must be a ~
pathname or string, got ~S" path)))))
    (unless (and (stringp via-tool) (plusp (length via-tool)))
      (error "patch-record: :via-tool must be a non-empty string, got ~S"
             via-tool))
    (check-type turn integer)
    (when form-type (check-type form-type string))
    (when form-name (check-type form-name string))
    (when operation (check-type operation string))
    (when diff-summary (check-type diff-summary string))
    (when related-step-index (check-type related-step-index integer))
    (make-instance 'patch-record
                   :path coerced-path
                   :form-type form-type
                   :form-name form-name
                   :via-tool via-tool
                   :operation operation
                   :diff-summary diff-summary
                   :applied-at applied-at
                   :related-step-index related-step-index
                   :turn turn)))

(defun patch-record-set-verify-status (record status source)
  "Transition RECORD's verify-status. STATUS must be one of
+SUPPORTED-VERIFY-STATUSES+; SOURCE must be one of
+SUPPORTED-VERIFY-SOURCES+. The transition rule is permissive: a
later setter call (e.g. :CLEAN after :INCREMENTAL) overrides the
prior value, mirroring the original verify-result semantics where
clean-verify is the authoritative truth.

Returns RECORD."
  (unless (member status +supported-verify-statuses+)
    (error "patch-record-set-verify-status: unsupported status ~S; ~
expected one of ~S" status +supported-verify-statuses+))
  (unless (member source +supported-verify-sources+)
    (error "patch-record-set-verify-status: unsupported source ~S; ~
expected one of ~S" source +supported-verify-sources+))
  (setf (slot-value record 'verify-status) status
        (slot-value record 'verify-source) source)
  record)
