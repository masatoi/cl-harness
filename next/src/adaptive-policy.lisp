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
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:handle-intervention
                #:decision-kind
                #:kernel-governor
                #:kernel-event-log)
  (:import-from #:cl-harness-next/src/governor
                #:progress-stalled
                #:budget-exhausted
                #:intervention-governor
                #:reset-governor-progress)
  (:export #:adaptive-policy
           #:policy-levels
           #:policy-level-index))

(in-package #:cl-harness-next/src/adaptive-policy)

(defclass adaptive-policy (control-policy projection)
  ((levels :initarg :levels :reader policy-levels
           :documentation "Policies ordered highest autonomy first,
e.g. (self-directed guided scripted).")
   (level-index :initform 0 :accessor policy-level-index)
   (dial-events-seen :initform 0 :accessor %dial-events-seen
                     :documentation "Logged dial demotions folded so
far; LEVEL-INDEX is derived absolutely from this count, so the
imperative demote-time update and the fold agree, and a cold replay
restores the level (SP7 resume coherence)."))
  (:documentation "Spec §6.1 adaptive dial: capability-adaptive
demotion driven by governor stall interventions. Also a projection —
include it in the world model's :extra-projections so resume rebuilds
the dial level from the log."))

(defun %current-level (policy)
  (elt (policy-levels policy) (policy-level-index policy)))

(defun %demote-on-give-up (policy kernel)
  "Bump to the next level, reset the governor's stall allowance, and log a
dial event (so a cold replay re-derives the level). Mirrors the
progress-stalled demotion, but driven by a sub-level :give-up."
  (setf (policy-level-index policy)
        (min (1+ (policy-level-index policy))
             (1- (length (policy-levels policy)))))
  (alexandria:when-let ((governor (kernel-governor kernel)))
    (reset-governor-progress governor))
  (emit-event (kernel-event-log kernel) :decision
              (alexandria:plist-hash-table
               (list "kind" "dial" "text" "demoted one dial level (give-up)")
               :test #'equal)))

(defmethod decide ((policy adaptive-policy) kernel)
  (let ((decision (decide (%current-level policy) kernel)))
    ;; A sub-level :give-up terminates the kernel before any governor pass
    ;; (kernel-step's :give-up branch), so progress-stalled never fires.
    ;; Intercept it: while a lower rung remains, demote and re-decide with
    ;; it THIS step. :give-up only escapes once the bottom rung gives up.
    (if (and (eq :give-up (decision-kind decision))
             (< (1+ (policy-level-index policy))
                (length (policy-levels policy))))
        ;; Re-enter THIS policy's decide (not the sub-level's directly) so a
        ;; chained give-up keeps demoting until a rung produces a non-give-up
        ;; decision or the bottom rung itself gives up.
        (progn (%demote-on-give-up policy kernel)
               (decide policy kernel))
        decision)))

(defmethod handle-intervention ((policy adaptive-policy) condition)
  (typecase condition
    (budget-exhausted :abort-run)
    (progress-stalled
     (if (< (1+ (policy-level-index policy))
            (length (policy-levels policy)))
         (progn
           ;; Immediate (the kernel decides with the new level this
           ;; very step); the logged dial event re-derives the same
           ;; value when it folds.
           (setf (policy-level-index policy)
                 (min (1+ (policy-level-index policy))
                      (1- (length (policy-levels policy)))))
           (alexandria:when-let
               ((governor (intervention-governor condition)))
             (reset-governor-progress governor))
           :demote-dial)
         :abort-run))
    (t :abort-run)))

(defmethod apply-event ((policy adaptive-policy) event)
  "Derive the dial level from the logged demotions (absolute, not
incremental relative to the imperative update — the two agree)."
  (let ((payload (event-payload event)))
    (when (and (eq :decision (event-type event))
               (hash-table-p payload)
               (equal "dial" (gethash "kind" payload)))
      (incf (%dial-events-seen policy))
      (setf (policy-level-index policy)
            (min (%dial-events-seen policy)
                 (1- (length (policy-levels policy)))))))
  policy)
