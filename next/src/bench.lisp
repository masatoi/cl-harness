;;;; next/src/bench.lisp
;;;;
;;;; Bench scheduling and statistical judgment for the L5 loop
;;;; (spec §10.2 stages 1 and 4) — v1: paired design (the same trial
;;;; index runs both packs), and a paired sign test (net challenger
;;;; wins). Fixture execution is an injected function — real fixtures
;;;; need a full LLM + environment setup, which callers own.
;;;; Sequential early stopping is deferred (see the plan's Deferred).

(defpackage #:cl-harness-next/src/bench
  (:use #:cl)
  (:export #:trial
           #:make-trial
           #:trial-index
           #:trial-pack-fingerprint
           #:trial-success-p
           #:trial-actions
           #:trial-reason
           #:run-paired-trials
           #:judge-trials))

(in-package #:cl-harness-next/src/bench)

(defstruct (trial (:conc-name trial-))
  index pack-fingerprint success-p actions reason)

(defun run-paired-trials (trial-fn champion challenger n)
  "Run N paired trials: index i runs CHAMPION then CHALLENGER under
the same fixture conditions. TRIAL-FN is (pack index) → TRIAL; the
pack arguments are passed through opaquely (fingerprint strings or
pack objects — TRIAL-FN decides). Returns
(values champion-trials challenger-trials), index order."
  (loop for index below n
        collect (funcall trial-fn champion index) into champion-trials
        collect (funcall trial-fn challenger index) into challenger-trials
        finally (return (values champion-trials challenger-trials))))

(defun %mean-actions (trials)
  (if trials
      (/ (reduce #'+ trials :key (lambda (trial)
                                   (or (trial-actions trial) 0)))
         (length trials))
      0))

(defun judge-trials (champion-trials challenger-trials
                     &key (min-net-wins 2))
  "Paired sign test (v1, spec §10.2 stage 4): a win is an index where
the challenger succeeded and the champion failed; a loss the reverse.
Net wins ≥ MIN-NET-WINS → :promote; net < 0 → :reject; otherwise
:inconclusive (run more trials). Returns (values verdict summary);
the summary also reports mean actions (cost is informative, not yet
decisive)."
  (let ((wins 0)
        (losses 0))
    (loop for champion-trial in champion-trials
          for challenger-trial in challenger-trials
          do (cond ((and (trial-success-p challenger-trial)
                         (not (trial-success-p champion-trial)))
                    (incf wins))
                   ((and (trial-success-p champion-trial)
                         (not (trial-success-p challenger-trial)))
                    (incf losses))))
    (let* ((net (- wins losses))
           (verdict (cond ((>= net min-net-wins) :promote)
                          ((< net 0) :reject)
                          (t :inconclusive)))
           (summary (format nil
                            "wins ~A losses ~A net ~A; mean actions ~,1F → ~,1F"
                            wins losses net
                            (%mean-actions champion-trials)
                            (%mean-actions challenger-trials))))
      (values verdict summary))))
