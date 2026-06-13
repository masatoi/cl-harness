;;;; next/tests/verification-ledger-test.lisp
;;;;
;;;; Unit tests for next/src/verification-ledger.lisp (§3.9 / §7
;;;; runtime-source-verified separation, §8 failure ledger). Clean
;;;; verification is DERIVED from event order: kill < load < test,
;;;; no repl-eval since the kill, no successful patch since the load.

(defpackage #:cl-harness-next/tests/verification-ledger-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:verification-ledger
                #:last-load
                #:last-test
                #:load-result-ok-p
                #:load-result-seq
                #:test-run-passed
                #:test-run-clean-p
                #:clean-verified-p
                #:active-failures
                #:resolved-failures
                #:failure-record-test-name
                #:failure-record-reason
                #:failure-record-seq
                #:failure-record-patch-seq
                #:failure-record-resolved-seq))

(in-package #:cl-harness-next/tests/verification-ledger-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %feed (ledger tool seq &key arguments result error)
  (apply-interaction ledger
                     (make-instance 'interaction
                                    :tool tool
                                    :arguments arguments
                                    :result result
                                    :error-message error
                                    :action-seq (1- seq)
                                    :observation-seq seq)))

(defun %tests-result (passed failed &rest failure-plists)
  (%hash "passed" passed "failed" failed
         "failed_tests" (mapcar (lambda (plist) (apply #'%hash plist))
                                failure-plists)))

(deftest load-results-are-recorded
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "load-system" 2)
    (ok (load-result-ok-p (last-load ledger)))
    (ok (= 2 (load-result-seq (last-load ledger))))
    (%feed ledger "load-system" 4 :error "compile failed")
    (ok (not (load-result-ok-p (last-load ledger))))))

(deftest dirty-run-is-not-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "load-system" 2)
    (%feed ledger "run-tests" 3 :result (%tests-result 5 0))
    (ok (not (test-run-clean-p (last-test ledger))))
    (ok (not (clean-verified-p ledger)))))

(deftest kill-load-test-is-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "load-system" 6)
    (%feed ledger "run-tests" 7 :result (%tests-result 5 0))
    (ok (test-run-clean-p (last-test ledger)))
    (ok (clean-verified-p ledger))))

(deftest assertion-failures-compose-reason-from-description-and-values
  ;; Rove assertion entries carry no "reason" key — the information
  ;; lives in description/values. The guided live run showed the cost
  ;; of dropping it: the view rendered "ADD-ADDS: ?" and the agent had
  ;; nothing to reason from.
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "run-tests" 3
           :result (%tests-result
                    0 1
                    (list "test_name" "ADD-ADDS"
                          "description" "Expect (= 5 (ADD 2 3)) to be true."
                          "values" (list "5" "2" "3" "-1"))))
    (let ((failure (first (active-failures ledger))))
      (ok (equal "ADD-ADDS" (failure-record-test-name failure)))
      (ok (equal "Expect (= 5 (ADD 2 3)) to be true. [values: 5 2 3 -1]"
                 (failure-record-reason failure))))))

(deftest repl-eval-after-kill-breaks-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "repl-eval" 6)
    (%feed ledger "load-system" 7)
    (%feed ledger "run-tests" 8 :result (%tests-result 5 0))
    (ok (not (clean-verified-p ledger)))))

(deftest patch-after-load-breaks-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "load-system" 6)
    (%feed ledger "lisp-edit-form" 7 :arguments (%hash "file_path" "a"))
    (%feed ledger "run-tests" 8 :result (%tests-result 5 0))
    (ok (not (clean-verified-p ledger)))))

(deftest failures-activate-then-resolve
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "lisp-edit-form" 3 :arguments (%hash "file_path" "a"))
    (%feed ledger "run-tests" 4
           :result (%tests-result 4 1 (list "test_name" "t-one"
                                            "reason" "boom")))
    (let ((failure (first (active-failures ledger))))
      (ok (= 1 (length (active-failures ledger))))
      (ok (equal "t-one" (failure-record-test-name failure)))
      (ok (equal "boom" (failure-record-reason failure)))
      (ok (= 3 (failure-record-patch-seq failure))))
    ;; Same failure again: no duplicate.
    (%feed ledger "run-tests" 6
           :result (%tests-result 4 1 (list "test_name" "t-one"
                                            "reason" "boom")))
    (ok (= 1 (length (active-failures ledger))))
    ;; Green run resolves.
    (%feed ledger "run-tests" 9 :result (%tests-result 5 0))
    (ok (null (active-failures ledger)))
    (ok (= 1 (length (resolved-failures ledger))))
    (ok (= 9 (failure-record-resolved-seq
              (first (resolved-failures ledger)))))))

(deftest graceful-without-structured-counts
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "run-tests" 3
           :result (%hash "content" (list (%hash "type" "text"
                                                 "text" "ok"))))
    (ok (last-test ledger))
    (ok (null (test-run-passed (last-test ledger))))
    (ok (null (active-failures ledger)))
    (ok (not (clean-verified-p ledger)))))

(deftest unnamed-failures-deduplicate-by-reason
  ;; Final-review fix: consecutive unstructured red runs must not
  ;; accumulate one record each.
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "run-tests" 3 :result (%hash "passed" 4 "failed" 2))
    (%feed ledger "run-tests" 5 :result (%hash "passed" 4 "failed" 2))
    (ok (= 1 (length (active-failures ledger))))))

(deftest recurring-failure-refreshes-its-sequence
  ;; A failure re-observed after a later patch is CURRENT, not stale. The
  ;; dedup must REFRESH the record's seq/patch-seq to the latest sighting,
  ;; else the pre-patch staleness check (context-compiler) mislabels a
  ;; still-red-after-patch failure as predating the patch and tells the model
  ;; to re-run tests it just ran.
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "lisp-edit-form" 3 :arguments (%hash "file_path" "a"))
    (%feed ledger "run-tests" 4
           :result (%tests-result 4 1 (list "test_name" "t-one"
                                            "reason" "boom")))
    (let ((failure (first (active-failures ledger))))
      (ok (= 4 (failure-record-seq failure)))
      (ok (= 3 (failure-record-patch-seq failure))))
    ;; A later patch, then the SAME test fails again — still red afterwards.
    (%feed ledger "lisp-edit-form" 6 :arguments (%hash "file_path" "a"))
    (%feed ledger "run-tests" 8
           :result (%tests-result 4 1 (list "test_name" "t-one"
                                            "reason" "boom")))
    (ok (= 1 (length (active-failures ledger))))
    (let ((failure (first (active-failures ledger))))
      ;; refreshed to the post-patch observation, not the stale pre-patch seq
      (ok (= 8 (failure-record-seq failure)))
      (ok (= 6 (failure-record-patch-seq failure))))))

(deftest iserror-load-is-not-ok
  ;; SP4 coherence fix: cl-mcp reports tool failure via result isError,
  ;; not a transport error. A failed load must not enable clean-verify.
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "load-system" 6 :result (%hash "isError" t))
    (ok (not (load-result-ok-p (last-load ledger))))
    (%feed ledger "run-tests" 7 :result (%tests-result 5 0))
    (ok (not (clean-verified-p ledger)))))
