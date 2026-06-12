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
           #:failure-report-error-samples
           #:failure-report-error-argument-samples
           #:failure-report-give-up-reason
           #:rank-failure-modes
           #:summarize-failure-evidence))

(in-package #:cl-harness-next/src/miner)

(defstruct (failure-report (:conc-name failure-report-))
  log-path total-actions failed-patches tool-errors
  stalled-cycles dial-demotions clean-verified-p
  ;; v2 (diagnose-layer vocabulary): what the tool failures actually
  ;; said, what arguments produced them, and why the run gave up.
  error-samples error-argument-samples give-up-reason)

(defconstant +evidence-error-limit+ 5
  "Max distinct tool-error texts rendered by SUMMARIZE-FAILURE-EVIDENCE.")

(defconstant +evidence-sample-limit+ 3
  "Max offending-argument samples and give-up reasons collected per
report and rendered by SUMMARIZE-FAILURE-EVIDENCE.")

(defun %first-content-text (result)
  "First content text of a tool RESULT hash-table, or NIL."
  (let ((content (gethash "content" result)))
    (when (and content (plusp (length content)))
      (let ((entry (elt content 0)))
        (when (hash-table-p entry)
          (gethash "text" entry))))))

(defun %observation-error-text (event)
  "Failure text of a failed :observation — the transport-level
\"error\" string, or the first content text of an isError result.
NIL for successful observations and other event types."
  (when (eq :observation (event-type event))
    (let ((payload (event-payload event)))
      (when (hash-table-p payload)
        (multiple-value-bind (error-value error-present-p)
            (gethash "error" payload)
          (if error-present-p
              (or error-value "(transport error)")
              (let ((result (gethash "result" payload)))
                (when (and (hash-table-p result)
                           (multiple-value-bind (value present-p)
                               (gethash "isError" result)
                             (and present-p value)))
                  (or (%first-content-text result)
                      "(tool reported isError)")))))))))

(defun %tool-error-event-p (event)
  "An :observation whose tool failed — transport error key OR an
isError result (both are tool failures)."
  (and (%observation-error-text event) t))

(defun %error-samples (events)
  "Alist of distinct failure texts with counts, most frequent first
(stable within ties: first-seen order)."
  (let ((counts '()))
    (dolist (event events)
      (let ((text (%observation-error-text event)))
        (when text
          (let ((cell (assoc text counts :test #'equal)))
            (if cell
                (incf (cdr cell))
                (push (cons text 1) counts))))))
    (stable-sort (nreverse counts) #'> :key #'cdr)))

(defun %encode-json (object)
  (with-output-to-string (out)
    (yason:encode object out)))

(defun %error-argument-samples (events)
  "JSON renderings (up to +EVIDENCE-SAMPLE-LIMIT+, distinct, in log
order) of the arguments whose action's observation failed — the
\"what the model actually produced\" evidence."
  (let ((samples '())
        (previous nil))
    (dolist (event events)
      (when (and (%observation-error-text event)
                 previous
                 (eq :action (event-type previous)))
        (let* ((payload (event-payload previous))
               (arguments (and (hash-table-p payload)
                               (gethash "arguments" payload))))
          (when arguments
            (pushnew (%encode-json arguments) samples :test #'equal))))
      (setf previous event))
    (let ((ordered (nreverse samples)))
      (subseq ordered 0 (min +evidence-sample-limit+ (length ordered))))))

(defun %give-up-reason (events)
  "Reason text of the LAST give-up decision, or NIL. Mirrors the
kernel's decision rendering: a :decision event whose text is
\"give-up — <reason>\"."
  (let ((reason nil))
    (dolist (event events reason)
      (when (eq :decision (event-type event))
        (let* ((payload (event-payload event))
               (text (and (hash-table-p payload)
                          (gethash "text" payload))))
          (when (and (stringp text)
                     (<= 7 (length text))
                     (string= "give-up" text :end2 7))
            (let ((separator (search " — " text)))
              (setf reason
                      (if separator
                          (subseq text (+ separator 3))
                          text)))))))))

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
     :clean-verified-p (clean-verified-p verification)
     :error-samples (%error-samples events)
     :error-argument-samples (%error-argument-samples events)
     :give-up-reason (%give-up-reason events))))

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
                        (total #'failure-report-dial-demotions))
                  (cons :give-ups
                        (count-if #'failure-report-give-up-reason
                                  reports)))))
      (sort (remove 0 totals :key #'cdr) #'> :key #'cdr))))

(defun %take (n list)
  (subseq list 0 (min n (length list))))

(defun summarize-failure-evidence (reports)
  "Render the diagnose-layer evidence across REPORTS for the variant
proposer (spec §10.2 stage 3): distinct tool-error texts with counts,
sample offending arguments (JSON), and give-up reasons. Returns NIL
when the transcripts carry none, so callers can omit the section."
  (let ((errors '())
        (arguments '())
        (reasons '()))
    (dolist (report reports)
      (loop for (text . count) in (failure-report-error-samples report)
            do (let ((cell (assoc text errors :test #'equal)))
                 (if cell
                     (incf (cdr cell) count)
                     (push (cons text count) errors))))
      (dolist (sample (failure-report-error-argument-samples report))
        (pushnew sample arguments :test #'equal))
      (let ((reason (failure-report-give-up-reason report)))
        (when reason
          (pushnew reason reasons :test #'equal))))
    (when (or errors arguments reasons)
      (format nil "~{- tool error (x~A): ~A~%~}~
                   ~{- offending arguments: ~A~%~}~
                   ~{- run gave up: ~A~%~}"
              (loop for (text . count)
                      in (%take +evidence-error-limit+
                                (stable-sort (nreverse errors) #'>
                                             :key #'cdr))
                    append (list count text))
              (%take +evidence-sample-limit+ (nreverse arguments))
              (%take +evidence-sample-limit+ (nreverse reasons))))))
