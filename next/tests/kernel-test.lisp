;;;; next/tests/kernel-test.lisp
;;;;
;;;; Tests for next/src/kernel.lisp: the L3 loop (spec §6) with a fake
;;;; environment that honors the real contract (records its
;;;; interactions into the event log) and local test policies.

(defpackage #:cl-harness-next/tests/kernel-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event
                #:read-events)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/environment
                #:environment
                #:perform-action
                #:environment-close)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:findings
                #:finding-hypothesis)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict
                #:verdict-pass-p)
  (:import-from #:cl-harness-next/src/governor
                #:governor)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:handle-intervention
                #:make-decision
                #:make-kernel
                #:kernel-world-model
                #:kernel-step-count
                #:kernel-last-verdict
                #:kernel-last-result
                #:kernel-last-action-error
                #:run-kernel))

(in-package #:cl-harness-next/tests/kernel-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defmacro with-log ((log path) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     (let ((,log (open-event-log ,path)))
       ,@body)))

(defclass fake-environment (environment)
  ((log :initarg :log :reader fake-log)
   (handlers :initarg :handlers :initform nil :accessor fake-handlers
             :documentation "List of (tool args → result hash) fns,
consumed one per action; default returns {\"ok\":true}.")
   (closed-p :initform nil :accessor fake-closed-p))
  (:documentation "Honors the real environment contract: every action
and its observation are recorded into the event log."))

(defmethod perform-action ((env fake-environment) tool arguments)
  (emit-event (fake-log env) :action
              (%hash "tool" tool "arguments" (or arguments (%hash))))
  (let ((handler (or (pop (fake-handlers env))
                     (lambda (tool arguments)
                       (declare (ignore tool arguments))
                       (%hash "ok" t)))))
    (handler-case
        (let ((result (funcall handler tool arguments)))
          (emit-event (fake-log env) :observation
                      (%hash "tool" tool "result" result))
          result)
      (error (condition)
        (emit-event (fake-log env) :observation
                    (%hash "tool" tool
                           "error" (format nil "~A" condition)))
        (error condition)))))

(defmethod environment-close ((env fake-environment))
  (setf (fake-closed-p env) t))

(defclass script-policy (control-policy)
  ((decisions :initarg :decisions :accessor script-decisions)))

(defmethod decide ((policy script-policy) kernel)
  (declare (ignore kernel))
  (pop (script-decisions policy)))

(defclass yes-oracle (oracle) ())
(defmethod oracle-name ((oracle yes-oracle)) :yes)
(defmethod evaluate ((oracle yes-oracle) subject)
  (declare (ignore subject))
  (make-verdict :oracle :yes :pass-p t :reason nil))

(deftest finish-decision-completes-the-run
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions (list (make-decision
                                              :kind :finish
                                              :reason "done"))))))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :done status))
        (ok (equal "done" reason)))
      (ok (= 1 (kernel-step-count kernel)))
      (ok (find :decision (read-events path) :key #'event-type)))))

(deftest act-performs-and-stores-result
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision :kind :act :tool "x"
                                                 :arguments (%hash "a" 1)
                                                 :reason "poke")
                                  (make-decision :kind :finish
                                                 :reason "ok"))))))
      (ok (eq :done (run-kernel kernel)))
      (ok (hash-table-p (kernel-last-result kernel)))
      (ok (= 2 (kernel-step-count kernel)))
      (let ((types (mapcar #'event-type (read-events path))))
        (ok (= 2 (count :decision types)))
        (ok (= 1 (count :action types)))
        (ok (= 1 (count :observation types)))))))

(deftest act-errors-are-captured-not-fatal
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance
                                 'fake-environment :log log
                                 :handlers (list (lambda (tool arguments)
                                                   (declare (ignore tool
                                                                    arguments))
                                                   (error "denied"))))
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision :kind :act :tool "x"
                                                 :reason "try")
                                  (make-decision :kind :finish
                                                 :reason "saw error"))))))
      (ok (eq :done (run-kernel kernel)))
      (ok (search "denied" (kernel-last-action-error kernel)))
      (ok (null (kernel-last-result kernel))))))

(deftest consult-stores-verdict-and-records-event
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision :kind :consult
                                                 :oracle (make-instance
                                                          'yes-oracle)
                                                 :reason "ask")
                                  (make-decision :kind :finish
                                                 :reason "ok"))))))
      (ok (eq :done (run-kernel kernel)))
      (ok (verdict-pass-p (kernel-last-verdict kernel)))
      (ok (find :oracle-result (read-events path) :key #'event-type)))))

(deftest governor-intervention-halts-the-run
  (with-log (log path)
    (let* ((governor (make-instance 'governor :max-actions 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'script-policy
                             :decisions
                             (list (make-decision :kind :act :tool "x"
                                                  :reason "1")
                                   (make-decision :kind :act :tool "x"
                                                  :reason "2"))))))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :given-up status))
        (ok (search "governor" reason)))
      (ok (= 1 (kernel-step-count kernel))))))

(deftest max-steps-exhaustion-gives-up
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (loop repeat 10
                                  collect (make-decision :kind :act
                                                         :tool "x"
                                                         :reason "spin"))))))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 3)
        (ok (eq :given-up status))
        (ok (search "maximum steps" reason)))
      (ok (= 3 (kernel-step-count kernel)))
      ;; Every step's decision is on the record.
      (ok (= 3 (count :decision (mapcar #'event-type
                                        (read-events path))))))))

(defun %stall-interaction ()
  (make-instance 'interaction
                 :tool "run-tests"
                 :result (%hash "failed" 1)
                 :action-seq 1 :observation-seq 2))

(deftest record-decision-feeds-the-ledger
  (with-log (log path)
    (declare (ignorable path))
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision
                                   :kind :record
                                   :payload (%hash "kind" "finding"
                                                   "hypothesis" "h"
                                                   "probe" "p"
                                                   "finding" "f"
                                                   "decision" "d")
                                   :reason "note insight")
                                  (make-decision :kind :finish
                                                 :reason "ok"))))))
      (ok (eq :done (run-kernel kernel)))
      (let ((ledger (world-model-projection (kernel-world-model kernel)
                                            :exploration)))
        (ok (= 1 (length (findings ledger))))
        (ok (equal "h" (finding-hypothesis (first (findings ledger)))))))))

(defclass demoting-policy (script-policy) ())

(defmethod cl-harness-next/src/kernel:handle-intervention
    ((policy demoting-policy) condition)
  (declare (ignore condition))
  :demote-dial)

(deftest demote-intervention-continues-and-is-recorded
  (with-log (log path)
    (let* ((governor (make-instance 'governor
                                    :max-stalled-verify-cycles 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'demoting-policy
                             :decisions
                             (list (make-decision :kind :finish
                                                  :reason "after demote"))))))
      (apply-interaction governor (%stall-interaction))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :done status))
        (ok (equal "after demote" reason)))
      (ok (find-if (lambda (event)
                     (and (eq :decision (event-type event))
                          (equal "dial" (gethash "kind"
                                                 (event-payload event)))))
                   (read-events path))))))

(defclass parking-policy (script-policy) ())

(defmethod cl-harness-next/src/kernel:handle-intervention
    ((policy parking-policy) condition)
  (declare (ignore condition))
  :park-mission)

(deftest unknown-restart-choice-halts
  (with-log (log path)
    (declare (ignorable path))
    (let* ((governor (make-instance 'governor
                                    :max-stalled-verify-cycles 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'parking-policy
                             :decisions
                             (list (make-decision :kind :finish
                                                  :reason "never"))))))
      (apply-interaction governor (%stall-interaction))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :given-up status))
        (ok (search "PARK-MISSION" reason))))))
