;;;; next/src/miner.lisp
;;;;
;;;; Transcript miner (spec §10.2 stage 2): replay an event log into
;;;; the standard world model plus a governor and read the ledgers —
;;;; deterministic failure-mode extraction, no LLM. The ranked output
;;;; is the machine version of docs/improvement-backlog.md.

(defpackage #:cl-harness-next/src/miner
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:build-world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches
                #:patch-entry-ok-p)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-action-count
                #:governor-stalled-verify-cycles)
  (:export #:failure-report
           #:mine-transcript
           #:failure-report-log-path
           #:failure-report-total-actions
           #:failure-report-failed-patches
           #:failure-report-tool-errors
           #:failure-report-stalled-cycles
           #:failure-report-dial-demotions
           #:failure-report-clean-verified-p
           #:rank-failure-modes))

(in-package #:cl-harness-next/src/miner)

(defstruct (failure-report (:conc-name failure-report-))
  log-path total-actions failed-patches tool-errors
  stalled-cycles dial-demotions clean-verified-p)

(defun %tool-error-event-p (event)
  "An :observation whose tool failed — transport error key OR an
isError result (both are tool failures)."
  (and (eq :observation (event-type event))
       (let ((payload (event-payload event)))
         (and (hash-table-p payload)
              (or (nth-value 1 (gethash "error" payload))
                  (let ((result (gethash "result" payload)))
                    (and (hash-table-p result)
                         (multiple-value-bind (value present-p)
                             (gethash "isError" result)
                           (and present-p value t)))))))))

(defun %dial-event-p (event)
  (and (eq :decision (event-type event))
       (let ((payload (event-payload event)))
         (and (hash-table-p payload)
              (equal "dial" (gethash "kind" payload))))))

(defun mine-transcript (log-path)
  "Replay LOG-PATH into the standard world model + a fresh governor
and distill a FAILURE-REPORT (deterministic; spec §10.2 stage 2)."
  (let* ((governor (make-instance 'governor))
         (world-model (build-world-model
                       log-path
                       :world-model (make-standard-world-model
                                     :extra-projections
                                     (list :governor governor))))
         (changes (world-model-projection world-model :changes))
         (verification (world-model-projection world-model
                                               :verification))
         (events (read-events log-path)))
    (make-failure-report
     :log-path log-path
     :total-actions (governor-action-count governor)
     :failed-patches (count-if-not #'patch-entry-ok-p
                                   (patches changes))
     :tool-errors (count-if #'%tool-error-event-p events)
     :stalled-cycles (governor-stalled-verify-cycles governor)
     :dial-demotions (count-if #'%dial-event-p events)
     :clean-verified-p (clean-verified-p verification))))

(defun rank-failure-modes (reports)
  "Aggregate failure counts across REPORTS, descending; zero modes
omitted. Returns an alist of (mode-keyword . total)."
  (flet ((total (key) (reduce #'+ reports :key key)))
    (let ((totals
            (list (cons :failed-patches
                        (total #'failure-report-failed-patches))
                  (cons :tool-errors
                        (total #'failure-report-tool-errors))
                  (cons :stalled-verify-cycles
                        (total #'failure-report-stalled-cycles))
                  (cons :dial-demotions
                        (total #'failure-report-dial-demotions)))))
      (sort (remove 0 totals :key #'cdr) #'> :key #'cdr))))
