;;;; src/subtask-summary.lisp
;;;;
;;;; Phase J of the context-management refactor
;;;; (docs/context-management.md §6.4). One subtask-summary
;;;; compresses a completed plan-step into a fixed-shape record
;;;; (what changed, tests added, verification, design impact) so the
;;;; :implementation context view can show prior subtasks without
;;;; replaying their full history.
;;;;
;;;; The record is DERIVED from the existing develop-state ledgers:
;;;; step-results, patch-records, abstraction-decisions on the step.
;;;; We don't store summaries on develop-state; we rebuild them on
;;;; demand via SUMMARISE-STEP-RESULT.

(defpackage #:cl-harness/src/subtask-summary
  (:use #:cl)
  (:import-from #:cl-harness/src/step-result
                #:develop-step-result-step-index
                #:develop-step-result-test-name
                #:develop-step-result-status
                #:develop-step-result-abstraction-decisions)
  (:import-from #:cl-harness/src/state
                #:develop-state-patch-records)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-path
                #:patch-record-form-type
                #:patch-record-form-name
                #:patch-record-related-step-index)
  (:import-from #:cl-harness/src/abstraction
                #:abstraction-decision-kind
                #:abstraction-decision-name)
  (:export #:subtask-summary
           #:make-subtask-summary
           #:subtask-summary-step-index
           #:subtask-summary-test-name
           #:subtask-summary-what-changed
           #:subtask-summary-tests-added
           #:subtask-summary-verification
           #:subtask-summary-design-impact
           #:subtask-summary-summarised-at
           #:summarise-step-result
           #:+supported-verification-statuses+))

(in-package #:cl-harness/src/subtask-summary)

(defparameter +supported-verification-statuses+
  '(:passed :give-up :limit-exhausted :dirty-only :error :review-rejected)
  "Verification keywords accepted by MAKE-SUBTASK-SUMMARY. Mirrors
DEVELOP-STEP-RESULT-STATUS. :REVIEW-REJECTED is the status the
orchestrator overlays on a verify-passed step whose implementation
review exhausted its retry budget (src/orchestrator.lisp
%execute-step). Without it summarise-step-result errors on the
replan path triggered by impl-review exhaustion.")

(defclass subtask-summary ()
  ((step-index :initarg :step-index :reader subtask-summary-step-index)
   (test-name :initarg :test-name :reader subtask-summary-test-name)
   (what-changed :initarg :what-changed :initform nil
                 :reader subtask-summary-what-changed)
   (tests-added :initarg :tests-added :initform nil
                :reader subtask-summary-tests-added)
   (verification :initarg :verification
                 :reader subtask-summary-verification)
   (design-impact :initarg :design-impact :initform nil
                  :reader subtask-summary-design-impact)
   (summarised-at :initarg :summarised-at
                  :reader subtask-summary-summarised-at))
  (:documentation
   "Compressed view of one completed plan-step. All slots are
plain values (integers, strings, lists of strings) so the record
serialises trivially."))

(defun make-subtask-summary (&key step-index test-name
                               what-changed tests-added
                               verification design-impact
                               (summarised-at (get-universal-time)))
  "Construct a SUBTASK-SUMMARY. STEP-INDEX integer; TEST-NAME string;
WHAT-CHANGED / TESTS-ADDED lists of strings; VERIFICATION must be a
member of +SUPPORTED-VERIFICATION-STATUSES+; DESIGN-IMPACT optional
string."
  (check-type step-index integer)
  (check-type test-name string)
  (unless (member verification +supported-verification-statuses+)
    (error "subtask-summary: unsupported :verification ~S; expected ~S"
           verification +supported-verification-statuses+))
  (dolist (entry what-changed) (check-type entry string))
  (dolist (entry tests-added) (check-type entry string))
  (when design-impact (check-type design-impact string))
  (make-instance 'subtask-summary
                 :step-index step-index
                 :test-name test-name
                 :what-changed what-changed
                 :tests-added tests-added
                 :verification verification
                 :design-impact design-impact
                 :summarised-at summarised-at))

(defun %describe-patch (patch)
  "One-line description of PATCH for the WHAT-CHANGED list."
  (format nil "~A~A"
          (namestring (patch-record-path patch))
          (if (patch-record-form-name patch)
              (format nil " (~A ~A)"
                      (or (patch-record-form-type patch) "")
                      (patch-record-form-name patch))
              "")))

(defun %describe-decision (decision)
  (format nil "~(~A~): ~A"
          (abstraction-decision-kind decision)
          (abstraction-decision-name decision)))

(defun summarise-step-result (step-result state)
  "Build a SUBTASK-SUMMARY from STEP-RESULT (a DEVELOP-STEP-RESULT)
and STATE (a DEVELOP-STATE). What-changed is derived from STATE's
patch-records filtered by step-index; tests-added is the step's own
test-name; design-impact is the step's abstraction-decisions joined
with '; '."
  (let* ((step-index (develop-step-result-step-index step-result))
         (test-name (or (develop-step-result-test-name step-result)
                        "(no test name)"))
         (status (develop-step-result-status step-result))
         (patches
           (remove-if-not
            (lambda (p)
              (eql step-index (patch-record-related-step-index p)))
            (develop-state-patch-records state)))
         (decisions (develop-step-result-abstraction-decisions step-result)))
    (make-subtask-summary
     :step-index step-index
     :test-name test-name
     :what-changed (mapcar #'%describe-patch patches)
     :tests-added (list test-name)
     :verification status
     :design-impact
     (and decisions
          (format nil "~{~A~^; ~}"
                  (mapcar #'%describe-decision decisions))))))
