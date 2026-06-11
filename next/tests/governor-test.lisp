;;;; next/tests/governor-test.lisp
;;;;
;;;; Tests for next/src/governor.lisp: progress counters folded from
;;;; interactions (legacy budgets generalized, spec §7 progress
;;;; oracle), threshold breaches, and (Task 7) condition/restart
;;;; interventions (spec §11).

(defpackage #:cl-harness-next/tests/governor-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-action-count
                #:governor-patch-count
                #:governor-consecutive-failed-patches
                #:governor-stalled-verify-cycles))

(in-package #:cl-harness-next/tests/governor-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %interaction (tool &key result error (seq 2))
  (make-instance 'interaction
                 :tool tool
                 :result result
                 :error-message error
                 :action-seq (1- seq)
                 :observation-seq seq))

(deftest counters-accumulate
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "lisp-read-file" :seq 1))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 2))
    (ok (= 2 (governor-action-count governor)))
    (ok (= 1 (governor-patch-count governor)))))

(deftest consecutive-failed-patches-track-and-reset
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 1
                                              :result (%hash "isError" t)))
    (apply-interaction governor (%interaction "lisp-patch-form" :seq 2
                                              :error "transport"))
    (ok (= 2 (governor-consecutive-failed-patches governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 3))
    (ok (zerop (governor-consecutive-failed-patches governor)))))

(deftest stalled-verify-counts-only-without-patch
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "run-tests" :seq 1
                                              :result (%hash "failed" 1)))
    (apply-interaction governor (%interaction "run-tests" :seq 2
                                              :result (%hash "failed" 1)))
    (ok (= 2 (governor-stalled-verify-cycles governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 3))
    (apply-interaction governor (%interaction "run-tests" :seq 4
                                              :result (%hash "failed" 1)))
    (ok (zerop (governor-stalled-verify-cycles governor)))))

(deftest green-run-resets-stall
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "run-tests" :seq 1
                                              :result (%hash "failed" 1)))
    (apply-interaction governor (%interaction "run-tests" :seq 2
                                              :result (%hash "failed" 0)))
    (ok (zerop (governor-stalled-verify-cycles governor)))))

(deftest evaluate-reports-breaches
  (let ((governor (make-instance 'governor
                                 :max-actions 2
                                 :max-consecutive-failed-patches 2)))
    (ok (verdict-pass-p (evaluate governor nil)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 1
                                              :result (%hash "isError" t)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 2
                                              :result (%hash "isError" t)))
    (let ((verdict (evaluate governor nil)))
      (ok (not (verdict-pass-p verdict)))
      (ok (search "actions" (verdict-reason verdict)))
      (ok (search "consecutive failed patches" (verdict-reason verdict))))))
