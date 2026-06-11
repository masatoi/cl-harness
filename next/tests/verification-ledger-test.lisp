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
