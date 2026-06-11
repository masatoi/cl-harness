;;;; next/tests/oracle-test.lisp
;;;;
;;;; Unit tests for next/src/oracle.lisp: protocol + CONSULT recording
;;;; verdicts as :oracle-result events (spec §7 — oracle consultations
;;;; are observations in the world model).

(defpackage #:cl-harness-next/tests/oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:consult
                #:make-verdict
                #:verdict-pass-p
                #:verdict-reason
                #:verdict-oracle))

(in-package #:cl-harness-next/tests/oracle-test)

(defmacro with-log-path ((path) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(defclass yes-oracle (oracle) ())

(defmethod oracle-name ((oracle yes-oracle)) :yes)

(defmethod evaluate ((oracle yes-oracle) subject)
  (make-verdict :oracle :yes :pass-p t
                :reason (format nil "subject=~A" subject)))

(deftest consult-returns-the-verdict
  (let ((verdict (consult (make-instance 'yes-oracle) 42)))
    (ok (verdict-pass-p verdict))
    (ok (equal "subject=42" (verdict-reason verdict)))
    (ok (eq :yes (verdict-oracle verdict)))))

(deftest consult-records-oracle-result-event
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (consult (make-instance 'yes-oracle) 1 :event-log log)
      (let ((event (first (read-events path))))
        (ok (eq :oracle-result (event-type event)))
        (ok (equal "yes" (gethash "oracle" (event-payload event))))
        (ok (eq t (gethash "pass" (event-payload event))))))))

(deftest consult-without-log-records-nothing
  (ok (verdict-pass-p (consult (make-instance 'yes-oracle) 1))))
