;;;; next/src/governor.lisp
;;;;
;;;; Governor: the progress oracle (spec §7) and its condition/restart
;;;; interventions (spec §11). It is BOTH a projection (counters are
;;;; folded from interactions, so a rebuilt world model restores them)
;;;; AND an oracle (EVALUATE reports threshold breaches). Thresholds
;;;; generalize the legacy budgets (max-patches,
;;;; max-consecutive-failed-patches, max-stalled-verify-cycles —
;;;; spec §12); wire pack budgets in via the initargs
;;;; (e.g. :max-actions (pack-budget pack :max-actions)).

(defpackage #:cl-harness-next/src/governor
  (:use #:cl)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:interaction-tool
                #:interaction-succeeded-p
                #:interaction-result
                #:+patch-tool-names+)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:export #:governor
           #:governor-action-count
           #:governor-patch-count
           #:governor-consecutive-failed-patches
           #:governor-stalled-verify-cycles
           #:governor-breaches
           #:check-governor
           #:reset-governor-progress
           #:governor-intervention
           #:progress-stalled
           #:budget-exhausted
           #:oracle-conflict
           #:intervention-governor
           #:intervention-reason))

(in-package #:cl-harness-next/src/governor)

(defclass governor (projection oracle)
  ((max-actions :initarg :max-actions :initform nil
                :reader governor-max-actions
                :documentation "Counts ALL environment actions,
including oracle consultations (a clean verify spends 3) — the only
replay-consistent semantic. Calibrate pack budgets accordingly.")
   (max-patches :initarg :max-patches :initform nil
                :reader governor-max-patches)
   (max-consecutive-failed-patches
    :initarg :max-consecutive-failed-patches :initform 3
    :reader governor-max-consecutive-failed-patches)
   (max-stalled-verify-cycles
    :initarg :max-stalled-verify-cycles :initform 3
    :reader governor-max-stalled-verify-cycles)
   (action-count :initform 0 :accessor governor-action-count)
   (patch-count :initform 0 :accessor governor-patch-count)
   (consecutive-failed-patches
    :initform 0 :accessor governor-consecutive-failed-patches)
   (stalled-verify-cycles
    :initform 0 :accessor governor-stalled-verify-cycles
    :documentation "Failing run-tests with no patch attempt since the
previous run-tests. The initial observe-phase red verify counts as the
first cycle; the default threshold (3) accounts for that.")
   (patched-since-last-verify
    :initform nil :accessor %patched-since-last-verify))
  (:documentation "Progress oracle + budget governor (spec §7/§11)."))

(defmethod oracle-name ((governor governor)) :governor)

(defun %result-int (result key)
  (when (hash-table-p result)
    (multiple-value-bind (value present-p) (gethash key result)
      (when (and present-p (integerp value)) value))))

(defmethod apply-interaction ((governor governor) interaction)
  (incf (governor-action-count governor))
  (let ((tool (interaction-tool interaction)))
    (cond
      ((member tool +patch-tool-names+ :test #'string=)
       (incf (governor-patch-count governor))
       (setf (%patched-since-last-verify governor) t)
       (if (interaction-succeeded-p interaction)
           (setf (governor-consecutive-failed-patches governor) 0)
           (incf (governor-consecutive-failed-patches governor))))
      ((string= tool "run-tests")
       (let ((failed (%result-int (interaction-result interaction)
                                  "failed")))
         (cond
           ((and failed (plusp failed))
            (if (%patched-since-last-verify governor)
                (setf (governor-stalled-verify-cycles governor) 0)
                (incf (governor-stalled-verify-cycles governor))))
           ((eql failed 0)
            (setf (governor-stalled-verify-cycles governor) 0))))
       (setf (%patched-since-last-verify governor) nil))))
  governor)

(defun governor-breaches (governor)
  "List of (category . description) threshold breaches, or NIL.
Categories: :budget (resource counts) and :progress (stall signals)."
  (let ((breaches '()))
    (flet ((breach (category limit value label)
             (when (and limit (>= value limit))
               (push (cons category
                           (format nil "~A: ~A >= ~A" label value limit))
                     breaches))))
      (breach :budget (governor-max-actions governor)
              (governor-action-count governor) "actions")
      (breach :budget (governor-max-patches governor)
              (governor-patch-count governor) "patches")
      (breach :progress (governor-max-consecutive-failed-patches governor)
              (governor-consecutive-failed-patches governor)
              "consecutive failed patches")
      (breach :progress (governor-max-stalled-verify-cycles governor)
              (governor-stalled-verify-cycles governor)
              "stalled verify cycles"))
    (nreverse breaches)))

(defmethod evaluate ((governor governor) subject)
  (declare (ignore subject))
  (let ((breaches (governor-breaches governor)))
    (if breaches
        (make-verdict :oracle :governor :pass-p nil
                      :reason (format nil "~{~A~^; ~}"
                                      (mapcar #'cdr breaches)))
        (make-verdict :oracle :governor :pass-p t :reason nil))))

(define-condition governor-intervention (condition)
  ((governor :initarg :governor :initform nil
             :reader intervention-governor)
   (reason :initarg :reason :initform "(no reason)"
           :reader intervention-reason))
  (:report (lambda (condition stream)
             (format stream "Governor intervention: ~A"
                     (intervention-reason condition))))
  (:documentation "Base for governor interventions (spec §11). Plain
CONDITION, not ERROR — unhandled signals fall through and the run
continues; handlers choose an intervention by invoking one of the
keyword-named restarts (:demote-dial :replan :park-mission :ask-human
:abort-run)."))

(define-condition progress-stalled (governor-intervention)
  ()
  (:documentation "Stall thresholds breached (oscillating patches or
verify-without-progress)."))

(define-condition budget-exhausted (governor-intervention)
  ()
  (:documentation "Resource budget thresholds breached (actions,
patches)."))

(define-condition oracle-conflict (governor-intervention)
  ()
  (:documentation "Consulted oracles disagree. Defined as part of the
spec §11 intervention vocabulary; detection wiring arrives with the
kernel (SP5), which is the first place multiple verdicts meet."))

(defun check-governor (governor)
  "Check thresholds and signal interventions (spec §11). Restart names
are KEYWORDS so cross-package handlers can simply
(invoke-restart :replan) — the project's documented restart-name
lesson. Returns the chosen intervention keyword, or :continue when
nothing breached or no handler chose a restart."
  (dolist (breach (governor-breaches governor) :continue)
    (destructuring-bind (category . reason) breach
      (let ((outcome
              (restart-case
                  (progn (signal (ecase category
                                   (:budget 'budget-exhausted)
                                   (:progress 'progress-stalled))
                                 :governor governor :reason reason)
                         :continue)
                (:demote-dial () :demote-dial)
                (:replan () :replan)
                (:park-mission () :park-mission)
                (:ask-human () :ask-human)
                (:abort-run () :abort-run))))
        (unless (eq :continue outcome)
          (return-from check-governor outcome))))))

(defun reset-governor-progress (governor)
  "Zero the stall counters — NOT the spent budgets. A dial demotion
grants the new policy a fresh stall allowance; actions and patches
already spent stay spent (spec §6.1)."
  (setf (governor-consecutive-failed-patches governor) 0
        (governor-stalled-verify-cycles governor) 0
        (%patched-since-last-verify governor) nil)
  governor)

(defmethod apply-event ((governor governor) event)
  "A logged dial demotion grants the next level a fresh stall
allowance on replay too (SP7 resume coherence). Live runs reset twice
— imperatively at demote time and again when the dial event folds —
which is idempotent."
  (let ((payload (event-payload event)))
    (when (and (eq :decision (event-type event))
               (hash-table-p payload)
               (equal "dial" (gethash "kind" payload)))
      (reset-governor-progress governor)))
  governor)
