;;;; next/src/adaptive-policy.lisp
;;;;
;;;; The adaptive dial (spec §6.1): an ordered list of policies,
;;;; highest autonomy first. DECIDE delegates to the current level; a
;;;; PROGRESS-STALLED intervention demotes one level — same kernel,
;;;; same world model, fresh stall allowance (the governor's stall
;;;; counters reset; spent budgets stay spent, so BUDGET-EXHAUSTED
;;;; still aborts).

(defpackage #:cl-harness-next/src/adaptive-policy
  (:use #:cl)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:handle-intervention)
  (:import-from #:cl-harness-next/src/governor
                #:progress-stalled
                #:budget-exhausted
                #:intervention-governor
                #:reset-governor-progress)
  (:export #:adaptive-policy
           #:policy-levels
           #:policy-level-index))

(in-package #:cl-harness-next/src/adaptive-policy)

(defclass adaptive-policy (control-policy)
  ((levels :initarg :levels :reader policy-levels
           :documentation "Policies ordered highest autonomy first,
e.g. (self-directed guided scripted).")
   (level-index :initform 0 :accessor policy-level-index))
  (:documentation "Spec §6.1 adaptive dial: capability-adaptive
demotion driven by governor stall interventions."))

(defun %current-level (policy)
  (elt (policy-levels policy) (policy-level-index policy)))

(defmethod decide ((policy adaptive-policy) kernel)
  (decide (%current-level policy) kernel))

(defmethod handle-intervention ((policy adaptive-policy) condition)
  (typecase condition
    (budget-exhausted :abort-run)
    (progress-stalled
     (if (< (1+ (policy-level-index policy))
            (length (policy-levels policy)))
         (progn
           (incf (policy-level-index policy))
           (alexandria:when-let
               ((governor (intervention-governor condition)))
             (reset-governor-progress governor))
           :demote-dial)
         :abort-run))
    (t :abort-run)))
