;;;; next/src/goal-projection.lisp
;;;;
;;;; Goal context (§3.1) and design decisions (§3.7): what the run is
;;;; for, its acceptance criteria and non-goals (from the :run-start
;;;; payload), and explicit design decisions (:decision events with
;;;; kind "decision").

(defpackage #:cl-harness-next/src/goal-projection
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-seq
                #:event-payload)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event)
  (:export #:goal-projection
           #:goal-text
           #:acceptance-criteria
           #:non-goals
           #:decisions
           #:decision-text
           #:decision-rationale
           #:decision-seq))

(in-package #:cl-harness-next/src/goal-projection)

(defstruct (decision (:conc-name decision-))
  text rationale seq)

(defclass goal-projection (projection)
  ((goal :initform nil :accessor goal-text
         :documentation "User goal string, or NIL.")
   (acceptance :initform nil :accessor acceptance-criteria)
   (non-goals :initform nil :accessor non-goals)
   (decisions :initform nil :accessor decisions
              :documentation "DECISION structs, newest first."))
  (:documentation "Goal context (§3.1) + design decisions (§3.7)."))

(defmethod apply-event ((projection goal-projection) event)
  (let ((payload (event-payload event)))
    (when (hash-table-p payload)
      (case (event-type event)
        (:run-start
         (let ((goal (gethash "goal" payload)))
           (when (stringp goal) (setf (goal-text projection) goal)))
         (let ((acceptance (gethash "acceptance_criteria" payload)))
           (when (consp acceptance)
             (setf (acceptance-criteria projection) acceptance)))
         (let ((non-goals (gethash "non_goals" payload)))
           (when (consp non-goals)
             (setf (non-goals projection) non-goals))))
        (:decision
         (when (equal "decision" (gethash "kind" payload))
           (push (make-decision :text (gethash "text" payload)
                                :rationale (gethash "rationale" payload)
                                :seq (event-seq event))
                 (decisions projection)))))))
  projection)
