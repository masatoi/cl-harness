;;;; next/src/oracle.lisp
;;;;
;;;; Oracle protocol (spec §7): an oracle is a consultable judge.
;;;; EVALUATE is the pure judgment; CONSULT additionally records the
;;;; verdict as an :oracle-result event, so consultations become
;;;; observations in the world model — the structural fix for
;;;; review-feedback routing problems (spec §7, backlog #3 lineage).

(defpackage #:cl-harness-next/src/oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:export #:oracle
           #:oracle-name
           #:evaluate
           #:consult
           #:verdict
           #:make-verdict
           #:verdict-oracle
           #:verdict-pass-p
           #:verdict-reason))

(in-package #:cl-harness-next/src/oracle)

(defstruct (verdict (:conc-name verdict-))
  oracle pass-p reason)

(defclass oracle ()
  ()
  (:documentation "Abstract base for L2 oracles (spec §7): consultable
judges over verification, invariants, reviews, and progress."))

(defgeneric oracle-name (oracle)
  (:documentation "Keyword identifying ORACLE in events and reports."))

(defgeneric evaluate (oracle subject)
  (:documentation "Judge SUBJECT and return a VERDICT. Pure judgment —
no event recording (that is CONSULT's job)."))

(defun consult (oracle subject &key event-log)
  "Evaluate ORACLE on SUBJECT; when EVENT-LOG is supplied, record the
verdict as an :oracle-result event. Returns the VERDICT."
  (let ((verdict (evaluate oracle subject)))
    (when event-log
      (emit-event event-log :oracle-result
                  (alexandria:plist-hash-table
                   (list "oracle" (string-downcase
                                   (symbol-name (oracle-name oracle)))
                         "pass" (and (verdict-pass-p verdict) t)
                         "reason" (or (verdict-reason verdict) ""))
                   :test #'equal)))
    verdict))
