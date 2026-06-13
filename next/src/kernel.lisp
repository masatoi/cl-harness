;;;; next/src/kernel.lisp
;;;;
;;;; The L3 agent kernel (spec §6): the minimal observe → decide →
;;;; act → record loop. DECIDE is owned by a CONTROL-POLICY — the
;;;; autonomy dial swaps policies, never the kernel. The kernel's
;;;; governor stance is the strictest default (any intervention
;;;; aborts); mission-layer restart handlers arrive in SP7.

(defpackage #:cl-harness-next/src/kernel
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:event-log-path
                #:emit-event)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:refresh-world-model)
  (:import-from #:cl-harness-next/src/environment
                #:perform-action)
  (:import-from #:cl-harness-next/src/oracle
                #:consult)
  (:import-from #:cl-harness-next/src/governor
                #:governor-intervention
                #:intervention-reason
                #:check-governor)
  (:export #:control-policy
           #:decide
           #:handle-intervention
           #:decision
           #:make-decision
           #:decision-kind
           #:decision-tool
           #:decision-arguments
           #:decision-oracle
           #:decision-subject
           #:decision-payload
           #:decision-reason
           #:kernel
           #:make-kernel
           #:kernel-environment
           #:kernel-event-log
           #:kernel-world-model
           #:kernel-policy
           #:kernel-governor
           #:kernel-status
           #:kernel-reason
           #:kernel-step-count
           #:kernel-last-verdict
           #:kernel-last-result
           #:kernel-last-action-error
           #:kernel-step
           #:run-kernel))

(in-package #:cl-harness-next/src/kernel)

(defclass control-policy ()
  ()
  (:documentation "Abstract owner of DECIDE (spec §6). The dial levels
(scripted / guided / self-directed) are concrete subclasses; the
kernel never branches on which one it runs."))

(defgeneric decide (policy kernel)
  (:documentation "Return the next DECISION for KERNEL. Policies read
kernel state (world model, last verdict/result/error) and keep their
own internal state."))

(defgeneric handle-intervention (policy condition)
  (:documentation "Choose the restart keyword for a governor
intervention (spec §11). The CONTROL-POLICY default is the strictest
stance — abort the run. The adaptive dial overrides this to demote on
progress stalls.")
  (:method ((policy control-policy) condition)
    (declare (ignore condition))
    :abort-run))

(defstruct (decision (:conc-name decision-))
  kind        ; :act | :consult | :record | :finish | :give-up
  tool        ; for :act — cl-mcp tool name string
  arguments   ; for :act — hash-table or NIL
  oracle      ; for :consult — an oracle instance
  subject     ; for :consult — defaults to the kernel's environment
  payload     ; for :record — hash-table for the :decision event
  reason)     ; human-readable rationale (reason on finish/give-up)

(defclass kernel ()
  ((environment :initarg :environment :reader kernel-environment)
   (event-log :initarg :event-log :reader kernel-event-log)
   (world-model :initarg :world-model :reader kernel-world-model)
   (policy :initarg :policy :reader kernel-policy)
   (governor :initarg :governor :initform nil :reader kernel-governor)
   (status :initform :running :accessor kernel-status)
   (reason :initform nil :accessor kernel-reason)
   (step-count :initform 0 :accessor kernel-step-count)
   (last-verdict :initform nil :accessor kernel-last-verdict)
   (last-result :initform nil :accessor kernel-last-result)
   (last-action-error :initform nil :accessor kernel-last-action-error))
  (:documentation "One run's loop state (spec §6). All durable truth
lives in the event log; the kernel holds only loop bookkeeping."))

(defun make-kernel (&key environment event-log policy governor
                         world-model)
  "Build a KERNEL. WORLD-MODEL defaults to the standard projections,
with GOVERNOR folded in as the :governor projection when supplied (its
counters then rebuild from the same log on resume)."
  (make-instance 'kernel
                 :environment environment
                 :event-log event-log
                 :policy policy
                 :governor governor
                 :world-model
                 (or world-model
                     (make-standard-world-model
                      :extra-projections
                      (when governor (list :governor governor))))))

(defun %refresh (kernel)
  (let ((path (event-log-path (kernel-event-log kernel))))
    (when (probe-file path)
      (refresh-world-model (kernel-world-model kernel) path))))

(defun %emit-decision (kernel decision)
  (emit-event (kernel-event-log kernel) :decision
              (alexandria:plist-hash-table
               (list "kind" "step"
                     "text" (format nil "~A~@[ ~A~]~@[ — ~A~]"
                                    (string-downcase
                                     (symbol-name
                                      (decision-kind decision)))
                                    (decision-tool decision)
                                    (decision-reason decision)))
               :test #'equal)))

(defun %result-error-text (result)
  "Failure text of an isError tool RESULT, or NIL for success. A
tool-level failure must reach the policy's next prompt like a
transport error does (guided live run 6: an invisible failed read sent
the model into a thinking runaway)."
  (when (and (hash-table-p result)
             (multiple-value-bind (value present-p)
                 (gethash "isError" result)
               (and present-p value)))
    (let ((content (gethash "content" result)))
      (or (when (and content (plusp (length content)))
            (let ((entry (elt content 0)))
              (when (hash-table-p entry)
                (gethash "text" entry))))
          "tool reported an error"))))

(defun %governor-gate (kernel)
  "Run CHECK-GOVERNOR, letting the policy choose the restart via
HANDLE-INTERVENTION. :continue → proceed; :demote-dial → record a dial
event and proceed; anything else records a terminal decision event
(\"park — …\" / \"give-up — …\", carrying the breach detail) and
halts. True when halted."
  (let ((governor (kernel-governor kernel)))
    (when governor
      (let* ((intervention nil)
             (outcome
               (handler-bind ((governor-intervention
                                (lambda (condition)
                                  (setf intervention condition)
                                  (invoke-restart
                                   (handle-intervention
                                    (kernel-policy kernel)
                                    condition)))))
                 (check-governor governor))))
        (flet ((%reason ()
                 (format nil "governor intervention: ~A~@[ (~A)~]"
                         outcome
                         (and intervention
                              (intervention-reason intervention))))
               (%record-terminal (prefix text)
                 (emit-event (kernel-event-log kernel) :decision
                             (alexandria:plist-hash-table
                              (list "kind" "step"
                                    "text" (format nil "~A — ~A"
                                                   prefix text))
                              :test #'equal))))
          (case outcome
            (:continue nil)
            (:demote-dial
             (emit-event (kernel-event-log kernel) :decision
                         (alexandria:plist-hash-table
                          (list "kind" "dial"
                                "text" "demoted one dial level")
                          :test #'equal))
             nil)
            ((:park-mission :ask-human)
             (let ((reason (%reason)))
               (%record-terminal "park" reason)
               (setf (kernel-status kernel) :parked
                     (kernel-reason kernel) reason))
             t)
            (t
             (let ((reason (%reason)))
               (%record-terminal "give-up" reason)
               (setf (kernel-status kernel) :given-up
                     (kernel-reason kernel) reason))
             t)))))))

(defun kernel-step (kernel)
  "One observe → decide → act → record iteration. Returns the status."
  (%refresh kernel)
  (when (%governor-gate kernel)
    (return-from kernel-step (kernel-status kernel)))
  (let ((decision (decide (kernel-policy kernel) kernel)))
    (if (eq :record (decision-kind decision))
        (emit-event (kernel-event-log kernel) :decision
                    (decision-payload decision))
        (progn
          (%emit-decision kernel decision)
          (ecase (decision-kind decision)
            (:act
             (setf (kernel-last-action-error kernel) nil)
             (handler-case
                 (let ((result
                         (perform-action (kernel-environment kernel)
                                         (decision-tool decision)
                                         (or (decision-arguments decision)
                                             (make-hash-table :test #'equal)))))
                   (setf (kernel-last-result kernel) result
                         (kernel-last-action-error kernel)
                         (%result-error-text result)))
               (error (condition)
                 (setf (kernel-last-result kernel) nil
                       (kernel-last-action-error kernel)
                       (format nil "~A" condition)))))
            (:consult
             (setf (kernel-last-verdict kernel)
                   (consult (decision-oracle decision)
                            (or (decision-subject decision)
                                (kernel-environment kernel))
                            :event-log (kernel-event-log kernel))))
            (:finish
             (setf (kernel-status kernel) :done
                   (kernel-reason kernel) (decision-reason decision)))
            (:give-up
             (setf (kernel-status kernel) :given-up
                   (kernel-reason kernel) (decision-reason decision)))))))
  (incf (kernel-step-count kernel))
  (%refresh kernel)
  (kernel-status kernel))

(defun run-kernel (kernel &key (max-steps 50))
  "Drive KERNEL until the policy finishes or gives up, the governor
intervenes (parking on :park-mission/:ask-human), or MAX-STEPS is
exhausted. Returns (values status reason); status is :done, :parked,
or :given-up."
  (loop while (and (eq :running (kernel-status kernel))
                   (< (kernel-step-count kernel) max-steps))
        do (kernel-step kernel))
  (when (eq :running (kernel-status kernel))
    (setf (kernel-status kernel) :given-up
          (kernel-reason kernel)
          (format nil "maximum steps (~A) exhausted" max-steps)))
  (values (kernel-status kernel) (kernel-reason kernel)))
