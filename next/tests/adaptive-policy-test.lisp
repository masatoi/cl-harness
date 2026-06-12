;;;; next/tests/adaptive-policy-test.lisp
;;;;
;;;; Tests for next/src/adaptive-policy.lisp (spec §6.1): demote one
;;;; dial level on progress stalls — same kernel, same world model —
;;;; with the governor's stall counters reset; budgets stay spent.

(defpackage #:cl-harness-next/tests/adaptive-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-consecutive-failed-patches
                #:progress-stalled
                #:budget-exhausted)
  (:import-from #:cl-harness-next/src/kernel
                #:handle-intervention
                #:make-kernel
                #:kernel-world-model
                #:run-kernel)
  (:import-from #:cl-harness-next/src/llm-policies
                #:self-directed-policy)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy)
  (:import-from #:cl-harness-next/src/adaptive-policy
                #:adaptive-policy
                #:policy-level-index))

(in-package #:cl-harness-next/tests/adaptive-policy-test)

;; The dial-transport and canned JSON live in llm-policies-test;
;; tests here import that package's package-qualified symbols would
;; couple test files, so the transport is duplicated minimally.
(defclass stall-transport (cl-harness-next/src/mcp-client:mcp-transport)
  ((fixed-p :initform nil :accessor stall-fixed-p)))

(defmethod cl-harness-next/src/mcp-client:transport-send-request
    ((transport stall-transport) body)
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
                            "{\"name\":\"lisp-edit-form\"},"
                            "{\"name\":\"lisp-patch-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ;; lisp-edit-form is broken in this world; only
                   ;; lisp-patch-form fixes.
                   ((equal tool "lisp-edit-form")
                    (concatenate 'string
                                 "{\"isError\":true,\"content\":"
                                 "[{\"type\":\"text\","
                                 "\"text\":\"form not found\"}]}"))
                   ((equal tool "lisp-patch-form")
                    (setf (stall-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (stall-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defparameter *edit-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"form_type\":\"defun\",\"form_name\":\"f\","
               "\"operation\":\"replace\",\"content\":\"x\"}}"))

(defparameter *patch-form-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"form_name\":\"f\",\"old_text\":\"a\","
               "\"new_text\":\"b\"}}"))

(defun %levels (&rest policies) policies)

(deftest stall-demotes-and-resets-the-governor
  (let ((governor (make-instance 'governor))
        (adaptive (make-instance
                   'adaptive-policy
                   :levels (%levels :level-a :level-b))))
    (setf (governor-consecutive-failed-patches governor) 3)
    (ok (eq :demote-dial
            (handle-intervention adaptive
                                 (make-condition 'progress-stalled
                                                 :governor governor))))
    (ok (= 1 (policy-level-index adaptive)))
    (ok (zerop (governor-consecutive-failed-patches governor)))))

(deftest stall-at-the-last-level-aborts
  (let ((adaptive (make-instance 'adaptive-policy
                                 :levels (%levels :only))))
    (ok (eq :abort-run
            (handle-intervention adaptive
                                 (make-condition 'progress-stalled))))
    (ok (zerop (policy-level-index adaptive)))))

(deftest budget-exhaustion-always-aborts
  (let ((adaptive (make-instance 'adaptive-policy
                                 :levels (%levels :level-a :level-b))))
    (ok (eq :abort-run
            (handle-intervention adaptive
                                 (make-condition 'budget-exhausted))))
    (ok (zerop (policy-level-index adaptive)))))

(deftest stalled-self-directed-demotes-to-scripted-and-finishes
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (open-event-log log-path))
           (environment (make-cl-mcp-environment
                         :client (make-mcp-client
                                  (make-instance 'stall-transport))
                         :condition :runtime-native
                         :event-log log))
           (self-directed (make-instance
                           'self-directed-policy
                           :system "s" :test-system "s/tests"
                           :step-fn (lambda (prompt)
                                      (declare (ignore prompt))
                                      *edit-json*)))
           (scripted (make-instance
                      'scripted-fix-policy
                      :system "s" :test-system "s/tests"
                      :diagnose-fn (lambda (view)
                                     (declare (ignore view))
                                     *patch-form-json*)))
           (kernel (make-kernel
                    :environment environment
                    :event-log log
                    :governor (make-instance
                               'governor
                               :max-consecutive-failed-patches 2)
                    :policy (make-instance
                             'adaptive-policy
                             :levels (list self-directed scripted)))))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :done status))
        (ok (search "clean" reason)))
      (ok (clean-verified-p
           (world-model-projection (kernel-world-model kernel)
                                   :verification)))
      (ok (find-if (lambda (event)
                     (and (eq :decision (event-type event))
                          (equal "dial" (gethash "kind"
                                                 (event-payload event)))))
                   (read-events log-path))))))
