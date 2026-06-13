;;;; next/src/context-compiler.lisp
;;;;
;;;; Context compiler (spec §8.3, doc §4/§5/§6): a pure function of
;;;; the world model producing a token-budget-bounded markdown view.
;;;; The budget is a HARD guarantee — every addition is admitted only
;;;; if the whole view still fits. Empty sections are elided (Phase J
;;;; lesson); staleness/promotion are render-time annotations
;;;; (Phase F/H lessons: annotate, don't filter — except the
;;;; failure-analysis view, which shows fresh probes only).

(defpackage #:cl-harness-next/src/context-compiler
  (:use #:cl)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-text
                #:acceptance-criteria
                #:non-goals
                #:decisions
                #:decision-text
                #:decision-rationale)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:findings
                #:probes
                #:finding-hypothesis
                #:finding-text
                #:finding-decision
                #:finding-promoted-p
                #:probe-tool
                #:probe-code
                #:probe-summary
                #:probe-seq
                #:probe-stale-p)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches
                #:source-facts
                #:patch-entry-file
                #:patch-entry-form-type
                #:patch-entry-form-name
                #:patch-entry-operation
                #:patch-entry-ok-p
                #:patch-entry-seq
                #:source-fact-file
                #:source-fact-detail
                #:source-fact-content
                #:source-fact-stale-p)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:last-load
                #:last-test
                #:load-result-ok-p
                #:load-result-summary
                #:test-run-passed
                #:test-run-failed
                #:test-run-clean-p
                #:clean-verified-p
                #:active-failures
                #:resolved-failures
                #:failure-record-test-name
                #:failure-record-reason
                #:failure-record-seq
                #:failure-record-patch-seq
                #:failure-record-resolved-seq)
  (:export #:compile-context
           #:estimate-tokens))

(in-package #:cl-harness-next/src/context-compiler)

(defconstant +recent-limit+ 5
  "Max items rendered for recent-history sections.")

(defconstant +resolved-limit+ 3
  "Max resolved failures rendered (legacy regression-watch default).")

(defun estimate-tokens (string)
  "Crude token estimate: ceiling(characters / 4)."
  (ceiling (length string) 4))

(defun %take (n list)
  (subseq list 0 (min n (length list))))

;; --- Section line builders ------------------------------------------------

(defun %goal-lines (goal)
  (when goal
    (let ((lines '()))
      (when (goal-text goal) (push (goal-text goal) lines))
      (dolist (criterion (acceptance-criteria goal))
        (push (format nil "- accept: ~A" criterion) lines))
      (dolist (non-goal (non-goals goal))
        (push (format nil "- non-goal: ~A" non-goal) lines))
      (nreverse lines))))

(defun %verification-lines (verification)
  (when verification
    (let ((lines '()))
      (let ((load (last-load verification)))
        (when load
          (push (format nil "load-system: ~A~@[ (~A)~]"
                        (if (load-result-ok-p load) "OK" "FAILED")
                        (load-result-summary load))
                lines)))
      (let ((run (last-test verification)))
        (when run
          (push (format nil "run-tests: passed ~A, failed ~A (~A)"
                        (or (test-run-passed run) "?")
                        (or (test-run-failed run) "?")
                        (if (test-run-clean-p run)
                            "clean image"
                            "runtime state only"))
                lines)))
      (push (format nil "clean-verified: ~A"
                    (if (clean-verified-p verification) "YES" "NO"))
            lines)
      (nreverse lines))))

(defun %active-failure-lines (verification)
  (when verification
    (mapcar (lambda (failure)
              (format nil "- ~A: ~A (seq ~A~@[, after patch seq ~A~])"
                      (or (failure-record-test-name failure) "(unnamed)")
                      (or (failure-record-reason failure) "?")
                      (failure-record-seq failure)
                      (failure-record-patch-seq failure)))
            (active-failures verification))))

(defun %decision-lines (goal)
  (when goal
    (mapcar (lambda (decision)
              (format nil "- ~A~@[ — ~A~]"
                      (decision-text decision)
                      (decision-rationale decision)))
            (reverse (decisions goal)))))

(defun %finding-lines (exploration)
  (when exploration
    (mapcar (lambda (finding)
              (format nil "- ~A ~A → ~A (decision: ~A)"
                      (if (finding-promoted-p finding)
                          "[PROMOTED]"
                          "[NOT SHIPPED]")
                      (finding-hypothesis finding)
                      (finding-text finding)
                      (finding-decision finding)))
            (reverse (findings exploration)))))

(defun %patch-lines (changes)
  (when changes
    (mapcar (lambda (patch)
              (format nil "- seq ~A ~A ~@[~A ~]~@[~A ~]in ~A~@[ [FAILED]~]"
                      (patch-entry-seq patch)
                      (patch-entry-operation patch)
                      (patch-entry-form-type patch)
                      (patch-entry-form-name patch)
                      (or (patch-entry-file patch) "?")
                      (not (patch-entry-ok-p patch))))
            (%take +recent-limit+ (patches changes)))))

(defun %probe-lines (exploration &key fresh-only)
  (when exploration
    (let ((selected (if fresh-only
                        (remove-if (lambda (probe)
                                     (probe-stale-p probe exploration))
                                   (probes exploration))
                        (probes exploration))))
      (mapcar (lambda (probe)
                (format nil "- ~@[~A ~]seq ~A ~A: ~A => ~A"
                        (when (probe-stale-p probe exploration) "[STALE]")
                        (probe-seq probe)
                        (probe-tool probe)
                        (or (probe-code probe) "?")
                        (or (probe-summary probe) "?")))
              (%take +recent-limit+ selected)))))

(defun %source-fact-lines (changes)
  "Recent source facts WITH their content excerpts — the agent must
see what a read returned, not just that it happened (guided live run,
2026-06-13). Identical repeated reads render once."
  (when changes
    (let ((facts (remove-duplicates
                  (%take +recent-limit+ (source-facts changes))
                  :key (lambda (fact)
                         (list (source-fact-file fact)
                               (source-fact-detail fact)
                               (source-fact-content fact)))
                  :test #'equal
                  :from-end t)))
      (loop for fact in facts
            append
            (let ((stale-p (source-fact-stale-p fact changes)))
              (cons (format nil "- ~@[~A ~]~A~@[ (~A)~]"
                            (when stale-p "[STALE]")
                            (or (source-fact-file fact) "(search)")
                            (source-fact-detail fact))
                    (cond
                      ;; A stale excerpt actively misleads (the guided
                      ;; rerun kept re-patching against pre-patch
                      ;; source) — withhold it, keep the entry.
                      ((and stale-p (source-fact-content fact))
                       (list (concatenate
                              'string
                              "    (content withheld — file patched"
                              " since this read; re-read to refresh)")))
                      ((source-fact-content fact)
                       (mapcar (lambda (line)
                                 (concatenate 'string "    " line))
                               (uiop:split-string
                                (source-fact-content fact)
                                :separator '(#\Newline)))))))))))

(defun %resolved-lines (verification)
  (when verification
    (mapcar (lambda (failure)
              (format nil "- ~A (resolved seq ~A)"
                      (or (failure-record-test-name failure) "(unnamed)")
                      (failure-record-resolved-seq failure)))
            (%take +resolved-limit+ (resolved-failures verification)))))

;; --- Section selection per decision point ----------------------------------

(defun %normal-sections (world-model)
  (let ((goal (world-model-projection world-model :goal))
        (exploration (world-model-projection world-model :exploration))
        (changes (world-model-projection world-model :changes))
        (verification (world-model-projection world-model :verification)))
    (list (cons "Goal" (%goal-lines goal))
          (cons "Verification" (%verification-lines verification))
          (cons "Active failures" (%active-failure-lines verification))
          (cons "Decisions" (%decision-lines goal))
          (cons "Findings" (%finding-lines exploration))
          (cons "Recent patches" (%patch-lines changes))
          (cons "Runtime probes" (%probe-lines exploration))
          (cons "Source facts" (%source-fact-lines changes))
          (cons "Recently resolved failures (regression watch)"
                (%resolved-lines verification)))))

(defun %failure-sections (world-model)
  "Failure-analysis view (§8): failures first, linked to recent
patches; fresh probes only; explicit next-step guidance."
  (let ((goal (world-model-projection world-model :goal))
        (exploration (world-model-projection world-model :exploration))
        (changes (world-model-projection world-model :changes))
        (verification (world-model-projection world-model :verification)))
    (list (cons "Goal" (%take 1 (%goal-lines goal)))
          (cons "Active failures" (%active-failure-lines verification))
          (cons "Recent patches" (%patch-lines changes))
          (cons "Verification" (%verification-lines verification))
          (cons "Fresh runtime probes"
                (%probe-lines exploration :fresh-only t))
          (cons "Findings" (%finding-lines exploration))
          (cons "Next step"
                (list (concatenate 'string
                                   "Link the failure to the most recent"
                                   " patches, form one hypothesis, and"
                                   " probe it in the REPL before"
                                   " patching again."))))))

;; --- Budgeted assembly ------------------------------------------------------

(defun %try-add (current addition token-budget)
  "Return CURRENT with ADDITION appended (newline-separated) when the
result stays within TOKEN-BUDGET, else NIL."
  (let ((candidate (if (zerop (length current))
                       addition
                       (concatenate 'string current (string #\Newline)
                                    addition))))
    (when (<= (estimate-tokens candidate) token-budget)
      candidate)))

(defun %add-section (view title lines token-budget)
  "Append section TITLE/LINES to VIEW within TOKEN-BUDGET. Lines that
do not fit are dropped with an omission marker. Returns
(values new-view included-p)."
  (let ((with-title (%try-add view (format nil "## ~A" title)
                              token-budget)))
    (if (null with-title)
        (values view nil)
        (let ((current with-title)
              (included 0))
          (dolist (line lines)
            (let ((next (%try-add current line token-budget)))
              (if next
                  (progn (setf current next) (incf included))
                  (return))))
          (when (< included (length lines))
            (let ((next (%try-add current
                                  (format nil "(~D more omitted)"
                                          (- (length lines) included))
                                  token-budget)))
              (when next (setf current next))))
          (if (zerop included)
              (values view nil)
              (values current t))))))

(defun compile-context (world-model &key (decision-point :normal)
                                         (token-budget 8000)
                                         role dial)
  "Compile a bounded markdown context view from WORLD-MODEL (spec
§8.3): a pure function of the world model. DECISION-POINT is :normal
or :failure-analysis. ROLE and DIAL complete the spec'd signature;
their selection profiles arrive with the control policies (SP5/SP6)
and are currently unused. The result is guaranteed to estimate at
most TOKEN-BUDGET tokens."
  (declare (ignore role dial))
  (let ((sections (ecase decision-point
                    (:normal (%normal-sections world-model))
                    (:failure-analysis (%failure-sections world-model))))
        (view "")
        (omitted '()))
    (loop for (title . lines) in sections
          when lines
            do (multiple-value-bind (next included-p)
                   (%add-section view title lines token-budget)
                 (if included-p
                     (setf view next)
                     (push title omitted))))
    (when omitted
      (let ((next (%try-add view
                            (format nil "(omitted for budget: ~{~A~^, ~})"
                                    (nreverse omitted))
                            token-budget)))
        (when next (setf view next))))
    view))
