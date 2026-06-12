;;;; next/src/verification-oracle.lisp
;;;;
;;;; Deterministic verification oracle (spec §7): runs load/test —
;;;; optionally from a fresh worker (:clean) — THROUGH the L1
;;;; environment, so the kill→load→test event trail it produces is the
;;;; same one the SP3 verification-ledger independently derives
;;;; clean-verify from. Clean verification is the only final truth all
;;;; dial levels must pass (spec §7).

(defpackage #:cl-harness-next/src/verification-oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:import-from #:cl-harness-next/src/environment
                #:perform-action)
  (:export #:verification-oracle
           #:oracle-system
           #:oracle-test-system
           #:oracle-mode
           #:oracle-clear-fasls-p))

(in-package #:cl-harness-next/src/verification-oracle)

(defclass verification-oracle (oracle)
  ((system :initarg :system :reader oracle-system)
   (test-system :initarg :test-system :reader oracle-test-system)
   (mode :initarg :mode :initform :incremental :reader oracle-mode
         :documentation ":incremental (load+test) or :clean
(kill+load+test). The subject of EVALUATE is an L1 environment whose
action space must permit these tools (:runtime-native).")
   (clear-fasls-p :initarg :clear-fasls :initform nil
                  :reader oracle-clear-fasls-p
                  :documentation "When true, load-system is asked to
recompile from source (clear_fasls). Defeats the second-granularity
file-write-date comparison that lets a same-second source rewrite
reuse a stale fasl — paired bench trials and zero-latency canned
policies both hit it. Costs a full recompile per verify; keep it off
for big systems unless trials demand it."))
  (:documentation "Load/test verification through the L1 environment."))

(defmethod oracle-name ((oracle verification-oracle))
  (if (eq :clean (oracle-mode oracle))
      :clean-verification
      :verification))

(defun %args (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %result-error-p (result)
  (and (hash-table-p result)
       (multiple-value-bind (value present-p) (gethash "isError" result)
         (and present-p value t))))

(defun %result-int (result key)
  (when (hash-table-p result)
    (multiple-value-bind (value present-p) (gethash key result)
      (when (and present-p (integerp value)) value))))

(defun %result-text (result)
  (when (hash-table-p result)
    (multiple-value-bind (content present-p) (gethash "content" result)
      (when (and present-p (consp content))
        (let ((first-element (first content)))
          (when (hash-table-p first-element)
            (gethash "text" first-element)))))))

(defmethod evaluate ((oracle verification-oracle) environment)
  (handler-case
      (progn
        (when (eq :clean (oracle-mode oracle))
          (let ((kill-result
                  (perform-action environment "pool-kill-worker" (%args))))
            (when (%result-error-p kill-result)
              (return-from evaluate
                (make-verdict :oracle (oracle-name oracle) :pass-p nil
                              :reason (format nil
                                              "pool-kill-worker failed: ~A"
                                              (or (%result-text kill-result)
                                                  "(no detail)")))))))
        (let ((load-result
                (perform-action environment "load-system"
                                (apply #'%args "system" (oracle-system oracle)
                                       (when (oracle-clear-fasls-p oracle)
                                         (list "clear_fasls" t))))))
          (when (%result-error-p load-result)
            (return-from evaluate
              (make-verdict :oracle (oracle-name oracle) :pass-p nil
                            :reason (format nil "load-system failed: ~A"
                                            (or (%result-text load-result)
                                                "(no detail)"))))))
        (let* ((test-result
                 (perform-action environment "run-tests"
                                 (%args "system"
                                        (oracle-test-system oracle))))
               (failed (%result-int test-result "failed"))
               (passed (%result-int test-result "passed")))
          (cond
            ((%result-error-p test-result)
             (make-verdict :oracle (oracle-name oracle) :pass-p nil
                           :reason (format nil "run-tests failed: ~A"
                                           (or (%result-text test-result)
                                               "(no detail)"))))
            ((and failed (plusp failed))
             (make-verdict :oracle (oracle-name oracle) :pass-p nil
                           :reason (format nil "~A/~A tests failed"
                                           failed
                                           (+ failed (or passed 0)))))
            ((eql failed 0)
             (make-verdict :oracle (oracle-name oracle) :pass-p t
                           :reason (format nil "~A tests passed~@[ (clean image)~]"
                                           (or passed "?")
                                           (eq :clean (oracle-mode oracle)))))
            (t
             (make-verdict :oracle (oracle-name oracle) :pass-p nil
                           :reason "run-tests returned no structured counts")))))
    (error (condition)
      (make-verdict :oracle (oracle-name oracle) :pass-p nil
                    :reason (format nil "verification error: ~A"
                                    condition)))))
