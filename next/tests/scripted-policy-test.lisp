;;;; next/tests/scripted-policy-test.lisp
;;;;
;;;; Full-loop tests for next/src/scripted-policy.lisp over a REAL
;;;; cl-mcp environment with a stateful canned transport: red until a
;;;; patch lands, then green; clean-verify drives kill/load/test.

(defpackage #:cl-harness-next/tests/scripted-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches)
  (:import-from #:cl-harness-next/src/governor
                #:governor)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:kernel-world-model
                #:run-kernel)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy))

(in-package #:cl-harness-next/tests/scripted-policy-test)

(defclass fix-transport (mcp-transport)
  ((fixable-p :initarg :fixable-p :initform t :reader fix-fixable-p
              :documentation "When NIL, patches never turn the tests
green (stall scenarios).")
   (fixed-p :initform nil :accessor fix-fixed-p)
   (kill-count :initform 0 :accessor fix-kill-count)))

(defmethod transport-send-request ((transport fix-transport) body)
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
                   ((equal tool "lisp-edit-form")
                    (when (fix-fixable-p transport)
                      (setf (fix-fixed-p transport) t))
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (fix-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        (concatenate 'string
                                     "{\"passed\":2,\"failed\":1,"
                                     "\"failed_tests\":[{\"test_name\":"
                                     "\"t-evict\",\"reason\":\"boom\"}]}")))
                   ((equal tool "pool-kill-worker")
                    (incf (fix-kill-count transport))
                    "{\"content\":[]}")
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defparameter *patch-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"src/cache.lisp\","
               "\"form_type\":\"defun\",\"form_name\":\"evict\","
               "\"operation\":\"replace\","
               "\"content\":\"(defun evict () :fixed)\"},"
               "\"thought\":\"fix ordering\"}"))

(defmacro with-fix-kernel ((kernel &key (diagnose '*patch-json*)
                                        (fixable-p t) governor
                                        transport-var)
                           &body body)
  (let ((transport (or transport-var (gensym "TRANSPORT"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,transport (make-instance 'fix-transport
                                         :fixable-p ,fixable-p))
              (log (open-event-log log-path))
              (environment (make-cl-mcp-environment
                            :client (make-mcp-client ,transport)
                            :condition :runtime-native
                            :event-log log))
              (,kernel (make-kernel
                        :environment environment
                        :event-log log
                        :governor ,governor
                        :policy (make-instance
                                 'scripted-fix-policy
                                 :system "s" :test-system "s/tests"
                                 :diagnose-fn
                                 (let ((response ,diagnose))
                                   (lambda (view)
                                     (declare (ignore view))
                                     response))))))
         (declare (ignorable ,transport))
         ,@body))))

(deftest happy-path-red-patch-green-clean
  (with-fix-kernel (kernel :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (let ((world-model (kernel-world-model kernel)))
      (ok (clean-verified-p
           (world-model-projection world-model :verification)))
      (ok (= 1 (length (patches
                        (world-model-projection world-model :changes))))))
    (ok (= 1 (fix-kill-count transport)))))

(deftest unparseable-diagnosis-gives-up
  (with-fix-kernel (kernel :diagnose "this is not json")
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "unparseable" reason)))))

(deftest model-give-up-is-respected
  (with-fix-kernel (kernel :diagnose
                           "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"stuck\"}")
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "stuck" reason)))))

(deftest non-patch-tool-is-a-policy-violation
  (with-fix-kernel
      (kernel
       :diagnose
       "{\"type\":\"tool_call\",\"tool\":\"repl-eval\",\"arguments\":{\"code\":\"1\"}}")
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "patch tools" reason)))))

(deftest governor-stops-futile-patching
  (with-fix-kernel (kernel :fixable-p nil
                           :governor (make-instance 'governor
                                                    :max-patches 1))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "governor" reason)))))
