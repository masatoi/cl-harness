;;;; next/tests/miner-test.lisp
;;;;
;;;; Tests for next/src/miner.lisp (spec §10.2 stage 2): deterministic
;;;; failure-mode mining by replaying event logs into the world model.

(defpackage #:cl-harness-next/tests/miner-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/miner
                #:mine-transcript
                #:failure-report-total-actions
                #:failure-report-failed-patches
                #:failure-report-tool-errors
                #:failure-report-dial-demotions
                #:failure-report-clean-verified-p
                #:failure-report-error-samples
                #:failure-report-error-argument-samples
                #:failure-report-give-up-reason
                #:rank-failure-modes
                #:summarize-failure-evidence))

(in-package #:cl-harness-next/tests/miner-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %emit-interaction (log tool &key result error arguments)
  (emit-event log :action (%hash "tool" tool
                                 "arguments" (or arguments (%hash))))
  (if error
      (emit-event log :observation (%hash "tool" tool "error" error))
      (emit-event log :observation
                  (%hash "tool" tool "result" (or result (%hash))))))

(defmacro with-mined-log ((report) &body emissions)
  `(uiop:with-temporary-file (:pathname path :type "jsonl")
     (uiop:delete-file-if-exists path)
     (let ((log (open-event-log path)))
       ,@emissions
       (let ((,report (mine-transcript path)))
         ,report))))

(deftest mine-counts-failure-modes
  (let ((report
          (with-mined-log (report)
            ;; A failed patch (tool-level isError).
            (%emit-interaction log "lisp-edit-form"
                               :arguments (%hash "file_path" "a.lisp")
                               :result (%hash "isError" t))
            ;; A transport-level tool error.
            (%emit-interaction log "repl-eval" :error "boom")
            ;; A dial demotion.
            (emit-event log :decision (%hash "kind" "dial"
                                             "text" "demoted"))
            ;; A red run, never fixed.
            (%emit-interaction log "run-tests"
                               :result (%hash "passed" 1 "failed" 1)))))
    (ok (= 3 (failure-report-total-actions report)))
    (ok (= 1 (failure-report-failed-patches report)))
    ;; Tool errors count BOTH transport errors and isError results, so
    ;; the failed patch contributes here too (intentional overlap).
    (ok (= 2 (failure-report-tool-errors report)))
    (ok (= 1 (failure-report-dial-demotions report)))
    (ok (not (failure-report-clean-verified-p report)))))

(deftest mine-recognizes-clean-success
  (let ((report
          (with-mined-log (report)
            (%emit-interaction log "pool-kill-worker")
            (%emit-interaction log "load-system")
            (%emit-interaction log "run-tests"
                               :result (%hash "passed" 3 "failed" 0)))))
    (ok (failure-report-clean-verified-p report))
    (ok (zerop (failure-report-failed-patches report)))))

(deftest rank-aggregates-and-orders
  (let* ((red (with-mined-log (report)
                (%emit-interaction log "lisp-edit-form"
                                   :result (%hash "isError" t))
                (%emit-interaction log "lisp-patch-form"
                                   :result (%hash "isError" t))
                (%emit-interaction log "repl-eval" :error "boom")))
         (modes (rank-failure-modes (list red red))))
    ;; 4 failed patches > 2 tool errors... but failed patches ALSO
    ;; carry the isError observation, counting as tool errors too —
    ;; ranked totals: tool-errors 6, failed-patches 4.
    (ok (equal :tool-errors (car (first modes))))
    (ok (= 6 (cdr (first modes))))
    (ok (equal :failed-patches (car (second modes))))
    (ok (= 4 (cdr (second modes))))
    ;; Zero-count modes are omitted.
    (ok (null (assoc :dial-demotions modes)))))

(deftest mine-collects-diagnose-layer-evidence
  (let ((report
          (with-mined-log (report)
            ;; Two wrong-args failures sharing one error text, one
            ;; distinct transport error, then the kernel's give-up line.
            (%emit-interaction log "lisp-patch-form"
                               :arguments (%hash "file" "src/main.lisp"
                                                 "patch" "(+ a b)")
                               :error "file_path is required")
            (%emit-interaction log "lisp-patch-form"
                               :arguments (%hash "path" "src/main.lisp")
                               :error "file_path is required")
            (%emit-interaction log "repl-eval" :error "boom")
            (emit-event log :decision
                        (%hash "kind" "step"
                               "text" "give-up — diagnose call failed: empty content")))))
    (ok (equal '(("file_path is required" . 2) ("boom" . 1))
               (failure-report-error-samples report)))
    ;; Argument samples capture what the model actually produced.
    (let ((samples (failure-report-error-argument-samples report)))
      (ok (= 3 (length samples)))
      (ok (some (lambda (sample) (search "\"file\"" sample)) samples))
      (ok (some (lambda (sample) (search "\"path\"" sample)) samples)))
    (ok (equal "diagnose call failed: empty content"
               (failure-report-give-up-reason report)))
    ;; Give-ups surface as a ranked failure mode.
    (ok (= 1 (cdr (assoc :give-ups
                         (rank-failure-modes (list report))))))))

(deftest summarize-failure-evidence-renders-and-stays-silent
  (let ((failing
          (with-mined-log (report)
            (%emit-interaction log "lisp-patch-form"
                               :arguments (%hash "file" "src/main.lisp")
                               :error "file_path is required")
            (emit-event log :decision
                        (%hash "kind" "step"
                               "text" "give-up — diagnose call failed: empty content"))))
        (clean
          (with-mined-log (report)
            (%emit-interaction log "pool-kill-worker")
            (%emit-interaction log "load-system")
            (%emit-interaction log "run-tests"
                               :result (%hash "passed" 1 "failed" 0)))))
    (let ((text (summarize-failure-evidence (list failing clean))))
      (ok (search "file_path is required" text))
      (ok (search "diagnose call failed: empty content" text))
      ;; The offending arguments appear as JSON.
      (ok (search "\"file\"" text)))
    ;; No evidence → NIL, so callers can skip the prompt section.
    (ok (null (summarize-failure-evidence (list clean))))))
