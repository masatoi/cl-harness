;;;; next/src/exploration-ledger.lisp
;;;;
;;;; Exploration context (§3.6): explicit findings (the §6.2
;;;; hypothesis/probe/finding/decision structure, with the Phase-H
;;;; promotion heuristic enforcing "REPL success != implemented")
;;;; and auto-recorded runtime probes with §9 staleness — probes are
;;;; invalidated by any later successful patch or reload
;;;; (annotate-not-filter: staleness is a render-time predicate).

(defpackage #:cl-harness-next/src/exploration-ledger
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-seq
                #:event-payload)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:interaction-tool
                #:interaction-ok-p
                #:interaction-succeeded-p
                #:interaction-observation-seq
                #:argument-string
                #:result-text
                #:+patch-tool-names+)
  (:export #:exploration-ledger
           #:findings
           #:probes
           #:finding-hypothesis
           #:finding-probe
           #:finding-text
           #:finding-decision
           #:finding-seq
           #:finding-promoted-p
           #:probe-tool
           #:probe-code
           #:probe-summary
           #:probe-seq
           #:probe-stale-p))

(in-package #:cl-harness-next/src/exploration-ledger)

(alexandria:define-constant +probe-tool-names+
    '("repl-eval" "inspect-object")
  :test #'equal
  :documentation "Tools whose successful use is a runtime probe.")

(defstruct (finding (:conc-name finding-))
  hypothesis probe text decision seq (promoted-p nil))

(defstruct (probe (:conc-name probe-))
  tool code summary seq)

(defclass exploration-ledger (projection)
  ((findings :initform nil :accessor findings
             :documentation "FINDING structs, newest first.")
   (probes :initform nil :accessor probes
           :documentation "PROBE structs, newest first.")
   (invalidation-seq :initform nil :accessor %invalidation-seq
                     :documentation "Seq of the latest successful
patch, reload, or worker reset; probes before it are stale (§9)."))
  (:documentation "Exploration context (§3.6) with staleness (§9)."))

(defmethod apply-event ((ledger exploration-ledger) event)
  (let ((payload (event-payload event)))
    (when (and (eq :decision (event-type event))
               (hash-table-p payload)
               (equal "finding" (gethash "kind" payload)))
      (push (make-finding :hypothesis (gethash "hypothesis" payload)
                          :probe (gethash "probe" payload)
                          :text (gethash "finding" payload)
                          :decision (gethash "decision" payload)
                          :seq (event-seq event))
            (findings ledger))))
  ledger)

(defun %patch-text-fields (interaction)
  (remove nil (list (argument-string interaction "content")
                    (argument-string interaction "new_text")
                    (argument-string interaction "form_name"))))

(defun %promote-matching-findings (ledger interaction)
  "Flip PROMOTED-P on findings whose hypothesis appears (case-folded
substring) in the patch's content/new_text/form_name — the
legacy-proven Phase-H heuristic. Idempotent."
  (let ((haystacks (mapcar #'string-downcase
                           (%patch-text-fields interaction))))
    (dolist (finding (findings ledger))
      (let ((hypothesis (finding-hypothesis finding)))
        (when (and (not (finding-promoted-p finding))
                   (stringp hypothesis)
                   (some (lambda (haystack)
                           (search (string-downcase hypothesis) haystack))
                         haystacks))
          (setf (finding-promoted-p finding) t))))))

(defmethod apply-interaction ((ledger exploration-ledger) interaction)
  (let ((tool (interaction-tool interaction))
        (seq (interaction-observation-seq interaction)))
    (cond
      ((and (interaction-ok-p interaction)
            (member tool +probe-tool-names+ :test #'string=))
       (push (make-probe :tool tool
                         :code (argument-string interaction "code")
                         :summary (result-text interaction)
                         :seq seq)
             (probes ledger)))
      ((and (interaction-succeeded-p interaction)
            (member tool +patch-tool-names+ :test #'string=))
       (setf (%invalidation-seq ledger) seq)
       (%promote-matching-findings ledger interaction))
      ((and (interaction-succeeded-p interaction)
            (or (string= tool "load-system")
                (string= tool "pool-kill-worker")))
       (setf (%invalidation-seq ledger) seq))))
  ledger)

(defun probe-stale-p (probe ledger)
  "True when PROBE predates the latest successful patch, reload, or
worker reset —
runtime observations invalidated per §9. Render-time predicate
(annotate, don't filter)."
  (let ((invalidation (%invalidation-seq ledger)))
    (and invalidation (< (probe-seq probe) invalidation) t)))
