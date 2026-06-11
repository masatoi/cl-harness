;;;; next/src/world-model.lisp
;;;;
;;;; World model aggregate (spec §8.2): folds the event log into a
;;;; set of projections, pairing each :action with its following
;;;; :observation exactly once. In-memory only — rebuild with
;;;; BUILD-WORLD-MODEL (suspend/resume needs nothing but the log).

(defpackage #:cl-harness-next/src/world-model
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-seq
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:read-events
                #:replay-events)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event
                #:apply-interaction
                #:make-interaction)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-projection)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:exploration-ledger)
  (:import-from #:cl-harness-next/src/change-ledger
                #:change-ledger)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:verification-ledger)
  (:export #:world-model
           #:make-world-model
           #:make-standard-world-model
           #:world-model-projection
           #:world-model-last-seq
           #:update-world-model
           #:build-world-model
           #:refresh-world-model))

(in-package #:cl-harness-next/src/world-model)

(defclass world-model ()
  ((projections :initarg :projections :reader %projections
                :documentation "Plist of key → PROJECTION.")
   (pending-action :initform nil :accessor %pending-action)
   (last-seq :initform 0 :accessor world-model-last-seq))
  (:documentation "Aggregate of projections over one event log
(spec §8.2). In-memory only; rebuild with BUILD-WORLD-MODEL."))

(defun make-world-model (&key projections)
  "Build a WORLD-MODEL over PROJECTIONS (a plist of key → projection)."
  (make-instance 'world-model :projections projections))

(defun make-standard-world-model ()
  "World model with the four standard SP3 projections:
:goal, :exploration, :changes, :verification."
  (make-world-model
   :projections (list :goal (make-instance 'goal-projection)
                      :exploration (make-instance 'exploration-ledger)
                      :changes (make-instance 'change-ledger)
                      :verification (make-instance 'verification-ledger))))

(defun world-model-projection (world-model key)
  "Return the projection registered under KEY, or NIL."
  (getf (%projections world-model) key))

(defun %each-projection (world-model function)
  (loop for (key projection) on (%projections world-model) by #'cddr
        do (progn key (funcall function projection))))

(defun %payload-tool (event)
  (let ((payload (event-payload event)))
    (when (hash-table-p payload)
      (gethash "tool" payload))))

(defun update-world-model (world-model event)
  "Fold one EVENT into WORLD-MODEL. An :action is held until its
:observation (same tool) arrives; the pair is then delivered exactly
once to every projection as an INTERACTION. Every raw event is also
delivered via APPLY-EVENT. Returns WORLD-MODEL."
  (setf (world-model-last-seq world-model) (event-seq event))
  (case (event-type event)
    (:action
     (setf (%pending-action world-model) event))
    (:observation
     (let* ((pending (%pending-action world-model))
            (pending-tool (and pending (%payload-tool pending))))
       (when (and pending-tool
                  (equal pending-tool (%payload-tool event)))
         (let ((interaction (make-interaction pending event)))
           (%each-projection world-model
                             (lambda (projection)
                               (apply-interaction projection interaction)))))
       (setf (%pending-action world-model) nil))))
  (%each-projection world-model
                    (lambda (projection) (apply-event projection event)))
  world-model)

(defun build-world-model (log-path &key (world-model
                                         (make-standard-world-model)))
  "Rebuild WORLD-MODEL by replaying the event log at LOG-PATH."
  (replay-events log-path
                 (lambda (accumulator event)
                   (update-world-model accumulator event))
                 world-model))

(defun refresh-world-model (world-model log-path)
  "Fold any events at LOG-PATH newer than WORLD-MODEL's last seen seq.
This is the kernel's per-step sync: the environment writes to the log,
the world model catches up from it — the log stays the single source
of truth (spec §8.1). Returns WORLD-MODEL."
  (dolist (event (read-events log-path) world-model)
    (when (> (event-seq event) (world-model-last-seq world-model))
      (update-world-model world-model event))))
