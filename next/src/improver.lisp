;;;; next/src/improver.lisp
;;;;
;;;; The improve-once cycle (spec §10.2 stage 5): mine → propose ONE
;;;; variant → materialize the challenger pack → paired trials →
;;;; judge → promote or reject. The §10.3 authority boundary is
;;;; enforced here: :prompt/:budget wins auto-promote with an audit
;;;; event carrying both fingerprints; :code proposals never run
;;;; trials — they become human-approval dossiers.

(defpackage #:cl-harness-next/src/improver
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-fingerprint)
  (:import-from #:cl-harness-next/src/miner
                #:mine-transcript
                #:rank-failure-modes)
  (:import-from #:cl-harness-next/src/variant
                #:variant-kind
                #:variant-hypothesis
                #:apply-variant
                #:write-pack-form
                #:propose-variant)
  (:import-from #:cl-harness-next/src/bench
                #:run-paired-trials
                #:judge-trials)
  (:export #:+promotable-kinds+
           #:promotable-p
           #:record-promotion
           #:format-proposal-dossier
           #:improve-once))

(in-package #:cl-harness-next/src/improver)

(alexandria:define-constant +promotable-kinds+ '(:prompt :budget)
  :test #'equal
  :documentation "The §10.3 authority boundary: prompt/config changes
auto-promote on statistical evidence; anything else needs a human.")

(defun promotable-p (variant)
  (member (variant-kind variant) +promotable-kinds+))

(defun record-promotion (audit-log &key champion challenger summary)
  "Append the §10.4 audit event: which pack replaced which, on what
evidence."
  (emit-event audit-log :decision
              (alexandria:plist-hash-table
               (list "kind" "promotion"
                     "from" (pack-fingerprint champion)
                     "to" (pack-fingerprint challenger)
                     "summary" (or summary ""))
               :test #'equal)))

(defun format-proposal-dossier (variant failure-modes)
  "Markdown dossier for a non-promotable variant — code changes
require human approval (spec §10.3)."
  (format nil
          "# Improvement proposal (human approval required)~%~%~
A ~A-kind change cannot auto-promote — code changes require human ~
approval (spec §10.3).~%~%## Hypothesis~%~A~%~%~
## Observed failure modes~%~{- ~A: ~A~%~}"
          (string-downcase (symbol-name (variant-kind variant)))
          (variant-hypothesis variant)
          (loop for (mode . count) in failure-modes
                append (list (string-downcase (symbol-name mode))
                             count))))

(defun %challenger-path (pack-directory form)
  (merge-pathnames (format nil "~A-~A.sexp"
                           (getf form :name) (getf form :version))
                   pack-directory))

(defun improve-once (&key champion transcripts propose-fn trial-fn
                          pack-directory audit-log
                          (trials 3) (min-net-wins 2))
  "One self-improvement cycle (spec §10.2). CHAMPION is the active
pack; TRANSCRIPTS are event-log paths to mine; PROPOSE-FN is
(prompt → response); TRIAL-FN is (pack index) → TRIAL (it receives
POLICY-PACK objects); the challenger pack file is written into
PACK-DIRECTORY. Returns (values outcome detail):
:promoted + the new champion pack — with a §10.4 audit event;
:rejected / :inconclusive + the judge summary;
:proposal + a human-approval dossier (code-kind — no trials run);
:no-variant + a note (unparseable or absent proposal)."
  (let* ((reports (mapcar #'mine-transcript transcripts))
         (failure-modes (rank-failure-modes reports))
         (variant (propose-variant champion failure-modes propose-fn)))
    (cond
      ((null variant)
       (values :no-variant "proposal was absent or unparseable"))
      ((not (promotable-p variant))
       (values :proposal
               (format-proposal-dossier variant failure-modes)))
      (t
       (let* ((form (apply-variant champion variant))
              (challenger (load-policy-pack
                           (write-pack-form
                            form (%challenger-path pack-directory
                                                   form)))))
         (multiple-value-bind (champion-trials challenger-trials)
             (run-paired-trials trial-fn champion challenger trials)
           (multiple-value-bind (verdict summary)
               (judge-trials champion-trials challenger-trials
                             :min-net-wins min-net-wins)
             (ecase verdict
               (:promote
                (record-promotion audit-log :champion champion
                                            :challenger challenger
                                            :summary summary)
                (values :promoted challenger))
               (:reject (values :rejected summary))
               (:inconclusive (values :inconclusive summary))))))))))
