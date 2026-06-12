;;;; next/tests/mission-runner-test.lisp
;;;;
;;;; Tests for next/src/mission-runner.lisp (spec §9): run to done,
;;;; park with a queued human request on budget exhaustion, resume
;;;; from the log with a raised envelope.

(defpackage #:cl-harness-next/tests/mission-runner-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/governor
                #:governor)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-status
                #:mission-queue
                #:enqueue-mission
                #:pending-human-requests
                #:resolve-human-request
                #:human-request-mission
                #:human-request-reason)
  (:import-from #:cl-harness-next/src/mission-runner
                #:run-mission))

(in-package #:cl-harness-next/tests/mission-runner-test)

(defclass runner-fix-transport (mcp-transport)
  ((fixed-p :initform nil :accessor runner-fixed-p)))

(defmethod transport-send-request ((transport runner-fix-transport)
                                   body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id
               (concatenate 'string
                            "\"result\":{\"tools\":["
                            "{\"name\":\"pool-kill-worker\"},"
                            "{\"name\":\"load-system\"},"
                            "{\"name\":\"run-tests\"},"
                            "{\"name\":\"lisp-edit-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ((equal tool "lisp-edit-form")
                    (setf (runner-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (runner-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defparameter *patch-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"content\":\"fix\"}}"))

(defun %environment-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment
   :client (make-mcp-client (make-instance 'runner-fix-transport))
   :condition :runtime-native
   :event-log log))

(defun %policy-factory (mission)
  (declare (ignore mission))
  (make-instance 'scripted-fix-policy
                 :system "s" :test-system "s/tests"
                 :diagnose-fn (lambda (view)
                                (declare (ignore view))
                                *patch-json*)))

(defun %governor-factory (max-actions)
  (lambda (mission)
    (declare (ignore mission))
    (make-instance 'governor :max-actions max-actions)))

(defmacro with-mission ((mission queue) &body body)
  `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
     (uiop:delete-file-if-exists log-path)
     (let ((,mission (make-instance 'mission :id "m1"
                                    :goal "fix evict"
                                    :acceptance-criteria (list "green")
                                    :log-path log-path))
           (,queue (make-instance 'mission-queue)))
       (enqueue-mission ,queue ,mission)
       ,@body)))

(deftest mission-runs-to-done
  (with-mission (mission queue)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'%environment-factory
                     :policy-factory #'%policy-factory)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (eq :done (mission-status mission)))
    (let ((events (read-events log-path)))
      (ok (= 1 (count :run-start (mapcar #'event-type events))))
      (let ((start (find :run-start events :key #'event-type)))
        (ok (equal "fix evict" (gethash "goal" (event-payload start))))
        (ok (equal '("green")
                   (gethash "acceptance_criteria"
                            (event-payload start))))))))

(deftest budget-exhaustion-parks-and-asks-the-human
  (with-mission (mission queue)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'%environment-factory
                     :policy-factory #'%policy-factory
                     :governor-factory (%governor-factory 2))
      (ok (eq :parked status))
      (ok (search "PARK-MISSION" reason)))
    (ok (eq :parked (mission-status mission)))
    (let ((requests (pending-human-requests queue)))
      (ok (= 1 (length requests)))
      (ok (eq mission (human-request-mission (first requests))))
      (ok (search "actions" (human-request-reason (first requests)))))))

(deftest resume-completes-with-a-raised-envelope
  (with-mission (mission queue)
    (run-mission mission queue
                 :environment-factory #'%environment-factory
                 :policy-factory #'%policy-factory
                 :governor-factory (%governor-factory 2))
    (ok (eq :parked (mission-status mission)))
    (resolve-human-request queue
                           (first (pending-human-requests queue))
                           :response "raise to 50")
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'%environment-factory
                     :policy-factory #'%policy-factory
                     :governor-factory (%governor-factory 50))
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (eq :done (mission-status mission)))
    ;; Resume did not re-emit run-start.
    (ok (= 1 (count :run-start (mapcar #'event-type
                                       (read-events log-path)))))))

(deftest terminal-missions-refuse-to-run
  (with-mission (mission queue)
    (run-mission mission queue
                 :environment-factory #'%environment-factory
                 :policy-factory #'%policy-factory)
    (ok (eq :done (mission-status mission)))
    (ok (handler-case
            (progn (run-mission mission queue
                                :environment-factory
                                #'%environment-factory
                                :policy-factory #'%policy-factory)
                   nil)
          (error () t)))))
