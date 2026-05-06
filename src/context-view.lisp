;;;; src/context-view.lisp
;;;;
;;;; Phase C of the context-management refactor
;;;; (docs/context-management.md §4-§5). Generates phase-specific
;;;; CONTEXT-VIEW snapshots from a DEVELOP-STATE: the structured
;;;; form callers can either inspect directly or render via
;;;; CONTEXT-VIEW->STRING for splicing into LLM prompts.
;;;;
;;;; Phase C MVP: data layer + 3 phase formatters (:PLANNING,
;;;; :EXPLORATION, :IMPLEMENTATION). Testing-phase view is folded
;;;; into :IMPLEMENTATION (cl-harness's run-agent loop runs both).
;;;; Integration-phase view is deferred to Phase E.

(defpackage #:cl-harness/src/context-view
  (:use #:cl)
  (:import-from #:cl-harness/src/state
                #:develop-state
                #:develop-state-goal
                #:develop-state-project-inventory
                #:develop-state-current-plan
                #:develop-state-current-step-index
                #:develop-state-source-facts
                #:develop-state-patch-records
                #:develop-state-failure-ledger)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact-related-step-index)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-related-step-index)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger-active)
  (:export #:context-view
           #:make-context-view
           #:context-view-phase
           #:context-view-goal
           #:context-view-current-step
           #:context-view-current-plan
           #:context-view-relevant-source-facts
           #:context-view-relevant-patch-records
           #:context-view-active-failures
           #:context-view-prior-plan
           #:context-view-failure-context
           #:context-view-project-inventory
           #:context-view->string
           #:+supported-phases+))

(in-package #:cl-harness/src/context-view)

(defparameter +supported-phases+
  '(:planning :exploration :implementation)
  "Phases for which MAKE-CONTEXT-VIEW and CONTEXT-VIEW->STRING are
defined. Mirrors a subset of docs/context-management.md §4.2:
testing folds into implementation (cl-harness's run-agent runs
both); integration is deferred to Phase E.")

(defclass context-view ()
  ((phase :initarg :phase :reader context-view-phase
          :documentation "One of +SUPPORTED-PHASES+.")
   (goal :initarg :goal :initform nil :reader context-view-goal
         :documentation "Current GOAL string (always populated).")
   (project-inventory :initarg :project-inventory :initform nil
                      :reader context-view-project-inventory
                      :documentation "Snapshot of develop-state's
project-inventory (text block today; Phase B's runtime-vocabulary
will replace this slot's data source). Populated for :PLANNING.")
   (current-plan :initarg :current-plan :initform nil
                 :reader context-view-current-plan
                 :documentation "List of PLAN-STEP. Populated for
:PLANNING (in replan mode) and :IMPLEMENTATION (for context).")
   (current-step :initarg :current-step :initform nil
                 :reader context-view-current-step
                 :documentation "Active PLAN-STEP, or NIL when
between steps (e.g. :PLANNING). Populated for :EXPLORATION and
:IMPLEMENTATION.")
   (relevant-source-facts :initarg :relevant-source-facts
                          :initform nil
                          :reader context-view-relevant-source-facts
                          :documentation "SOURCE-FACTs filtered to
those bound to the current step. Populated for :EXPLORATION and
:IMPLEMENTATION.")
   (relevant-patch-records :initarg :relevant-patch-records
                           :initform nil
                           :reader context-view-relevant-patch-records
                           :documentation "PATCH-RECORDs filtered
to the current step. Populated for :IMPLEMENTATION.")
   (active-failures :initarg :active-failures :initform nil
                    :reader context-view-active-failures
                    :documentation "Currently-active FAILURE-RECORDs
from the failure-ledger. Populated for :IMPLEMENTATION (so the
agent loop sees what's still broken).")
   (prior-plan :initarg :prior-plan :initform nil
               :reader context-view-prior-plan
               :documentation "PLAN-STEP list from the failed prior
round, or NIL on initial planning. Populated for :PLANNING in replan
mode (caller passes :prior-plan).")
   (failure-context :initarg :failure-context :initform nil
                    :reader context-view-failure-context
                    :documentation "Human-readable failure summary
from the failed prior round, or NIL on initial planning. Populated
for :PLANNING in replan mode (caller passes :failure-context)."))
  (:documentation
   "A snapshot of DEVELOP-STATE filtered for one phase. Pure data;
no behaviour beyond construction and the CONTEXT-VIEW->STRING
formatter dispatch."))

(defun %related-to-step-p (item step-index getter)
  "Return T when ITEM's GETTER (a related-step-index reader) equals
STEP-INDEX. Used to filter ledger lists. Returns NIL when STEP-INDEX
is NIL (no current step, no items match)."
  (and step-index
       (eql step-index (funcall getter item))))

(defun %filter-source-facts (state step-index)
  (and step-index
       (remove-if-not
        (lambda (f) (%related-to-step-p f step-index
                                        #'source-fact-related-step-index))
        (develop-state-source-facts state))))

(defun %filter-patch-records (state step-index)
  (and step-index
       (remove-if-not
        (lambda (p) (%related-to-step-p p step-index
                                        #'patch-record-related-step-index))
        (develop-state-patch-records state))))

(defun %active-failures (state)
  (let ((ledger (develop-state-failure-ledger state)))
    (and ledger (failure-ledger-active ledger))))

(defun make-context-view (state &key phase step prior-plan failure-context)
  "Build a CONTEXT-VIEW snapshot from STATE for PHASE. STEP is the
active PLAN-STEP (required for :EXPLORATION and :IMPLEMENTATION;
ignored for :PLANNING). PRIOR-PLAN and FAILURE-CONTEXT are
:PLANNING-only kwargs for the replan path.

The returned view is independent of STATE -- subsequent state
mutations do not propagate."
  (unless (member phase +supported-phases+)
    (error "make-context-view: unsupported :phase ~S; expected one of ~S"
           phase +supported-phases+))
  (let ((step-index (and state (develop-state-current-step-index state))))
    (case phase
      (:planning
       (make-instance 'context-view
                      :phase :planning
                      :goal (and state (develop-state-goal state))
                      :project-inventory (and state
                                              (develop-state-project-inventory
                                               state))
                      :current-plan (and state
                                         (develop-state-current-plan state))
                      :prior-plan prior-plan
                      :failure-context failure-context))
      (:exploration
       (make-instance 'context-view
                      :phase :exploration
                      :goal (and state (develop-state-goal state))
                      :current-step step
                      :relevant-source-facts (%filter-source-facts
                                              state step-index)))
      (:implementation
       (make-instance 'context-view
                      :phase :implementation
                      :goal (and state (develop-state-goal state))
                      :current-plan (and state
                                         (develop-state-current-plan state))
                      :current-step step
                      :relevant-source-facts (%filter-source-facts
                                              state step-index)
                      :relevant-patch-records (%filter-patch-records
                                               state step-index)
                      :active-failures (%active-failures state))))))

(defgeneric context-view->string (view phase)
  (:documentation
   "Render VIEW as a phase-appropriate markdown-ish string suitable
for splicing into an LLM prompt's context section. The string is
self-contained: a caller can either use it as the entire context
block or splice it into a larger scaffold. PHASE must match
VIEW's phase slot -- it's a parameter for dispatch convenience.
Phase C MVP supports :PLANNING, :EXPLORATION, :IMPLEMENTATION."))

;; Default fallback -- unsupported phase raises; methods land in Tasks 3-5.
(defmethod context-view->string ((view context-view) phase)
  (declare (ignore view))
  (error "context-view->string: no method for phase ~S" phase))
