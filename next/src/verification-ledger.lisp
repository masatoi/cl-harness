;;;; next/src/verification-ledger.lisp
;;;;
;;;; Verification context (§3.9) with the §7 three-state separation
;;;; (runtime-observed / source-persisted / clean-verified) and the
;;;; §8 failure ledger (active vs resolved). Clean verification is
;;;; DERIVED from event order — kill < load < test, no repl-eval
;;;; since the kill, no successful patch since the load — so no new
;;;; event convention is needed (spec: 最終判定は clean runtime).

(defpackage #:cl-harness-next/src/verification-ledger
  (:use #:cl)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-interaction
                #:interaction-tool
                #:interaction-succeeded-p
                #:interaction-result
                #:interaction-error-message
                #:interaction-observation-seq
                #:result-text
                #:+patch-tool-names+)
  (:export #:verification-ledger
           #:last-load
           #:last-test
           #:load-result-ok-p
           #:load-result-summary
           #:load-result-seq
           #:test-run-passed
           #:test-run-failed
           #:test-run-clean-p
           #:test-run-seq
           #:clean-verified-p
           #:active-failures
           #:resolved-failures
           #:failure-record-test-name
           #:failure-record-reason
           #:failure-record-seq
           #:failure-record-patch-seq
           #:failure-record-resolved-seq))

(in-package #:cl-harness-next/src/verification-ledger)

(defstruct (load-result (:conc-name load-result-))
  ok-p summary seq)

(defstruct (test-run (:conc-name test-run-))
  passed failed clean-p seq)

(defstruct (failure-record (:conc-name failure-record-))
  test-name reason seq patch-seq (resolved-seq nil))

(defclass verification-ledger (projection)
  ((last-load :initform nil :accessor last-load)
   (last-test :initform nil :accessor last-test)
   (kill-seq :initform nil :accessor %kill-seq)
   (load-seq :initform nil :accessor %load-seq)
   (patch-seq :initform nil :accessor %patch-seq)
   (repl-seq :initform nil :accessor %repl-seq)
   (active-failures :initform nil :accessor active-failures
                    :documentation "FAILURE-RECORD structs, newest first.")
   (resolved-failures :initform nil :accessor resolved-failures
                      :documentation "Newest resolved first (§6.5)."))
  (:documentation "Verification state (§3.9/§7/§8)."))

(defun %clean-test-p (ledger)
  "Kill < load < (this test), no repl-eval since the kill, no
successful patch since the load."
  (let ((kill (%kill-seq ledger))
        (load (%load-seq ledger))
        (patch (%patch-seq ledger))
        (repl (%repl-seq ledger)))
    (and kill load (> load kill)
         (or (null repl) (< repl kill))
         (or (null patch) (< patch load))
         t)))

(defun %result-int (result key)
  (when (hash-table-p result)
    (multiple-value-bind (value present-p) (gethash key result)
      (when (and present-p (integerp value)) value))))

(defun %failure-reason (entry)
  "Human-readable reason from a failed_tests ENTRY. Load errors carry
an explicit \"reason\"; Rove assertion entries carry the information
in \"description\" and \"values\" instead — compose those so the view
never renders \"?\" for a structured failure."
  (let ((reason (gethash "reason" entry))
        (description (gethash "description" entry))
        (values (gethash "values" entry)))
    (or reason
        (when description
          (if (and values (plusp (length values)))
              (format nil "~A [values:~{ ~A~}]"
                      description (coerce values 'list))
              description)))))

(defun %note-failure (ledger test-name reason seq)
  "Record an active failure. An equivalent one already active — same test
name, or same reason for unnamed (unstructured) failures — is REFRESHED to
this latest sighting (seq/patch-seq/reason) rather than left untouched: a
failure re-seen after a patch is current, not stale, and the staleness check
keys off the record's seq."
  (let ((duplicate
          (if test-name
              (find test-name (active-failures ledger)
                    :key #'failure-record-test-name :test #'equal)
              (find-if (lambda (failure)
                         (and (null (failure-record-test-name failure))
                              (equal reason (failure-record-reason failure))))
                       (active-failures ledger)))))
    (if duplicate
        (setf (failure-record-seq duplicate) seq
              (failure-record-patch-seq duplicate) (%patch-seq ledger)
              (failure-record-reason duplicate) reason)
        (push (make-failure-record :test-name test-name
                                   :reason reason
                                   :seq seq
                                   :patch-seq (%patch-seq ledger))
              (active-failures ledger)))))

(defun %resolve-all-failures (ledger seq)
  (dolist (failure (active-failures ledger))
    (setf (failure-record-resolved-seq failure) seq)
    (push failure (resolved-failures ledger)))
  (setf (active-failures ledger) nil))

(defun %record-test-run (ledger interaction)
  (let* ((result (interaction-result interaction))
         (seq (interaction-observation-seq interaction))
         (passed (%result-int result "passed"))
         (failed (%result-int result "failed")))
    (setf (last-test ledger)
          (make-test-run :passed passed :failed failed
                         :clean-p (%clean-test-p ledger) :seq seq))
    (cond
      ((and failed (plusp failed))
       (let ((entries (when (hash-table-p result)
                        (gethash "failed_tests" result))))
         (if (consp entries)
             (dolist (entry entries)
               (when (hash-table-p entry)
                 (%note-failure ledger
                                (gethash "test_name" entry)
                                (%failure-reason entry)
                                seq)))
             (%note-failure ledger nil
                            (format nil "~A test(s) failed" failed)
                            seq))))
      ((eql failed 0)
       (%resolve-all-failures ledger seq)))))

(defmethod apply-interaction ((ledger verification-ledger) interaction)
  (let ((tool (interaction-tool interaction))
        (seq (interaction-observation-seq interaction))
        (ok (interaction-succeeded-p interaction)))
    (cond
      ((string= tool "pool-kill-worker")
       (when ok (setf (%kill-seq ledger) seq)))
      ((string= tool "repl-eval")
       (setf (%repl-seq ledger) seq))
      ((member tool +patch-tool-names+ :test #'string=)
       (when ok (setf (%patch-seq ledger) seq)))
      ((string= tool "load-system")
       (setf (last-load ledger)
             (make-load-result
              :ok-p ok
              :summary (or (interaction-error-message interaction)
                           (unless ok (result-text interaction)))
              :seq seq))
       (when ok (setf (%load-seq ledger) seq)))
      ((string= tool "run-tests")
       (%record-test-run ledger interaction))))
  ledger)

(defun clean-verified-p (ledger)
  "True when the LATEST test run was clean (kill→load→test order) and
fully green — the only state the spec accepts as final truth (§7)."
  (let ((run (last-test ledger)))
    (and run (test-run-clean-p run) (eql 0 (test-run-failed run)) t)))
