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
                #:rank-failure-modes))

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
