;;;; next/tests/verification-oracle-test.lisp
;;;;
;;;; Tests for next/src/verification-oracle.lisp: kill→load→test driven
;;;; THROUGH the L1 environment with a tool-aware scripted transport,
;;;; including the cross-layer coherence check (the produced event
;;;; trail is what SP3 derives clean-verify from).

(defpackage #:cl-harness-next/tests/verification-oracle-test
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
                #:build-world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:consult
                #:verdict-pass-p
                #:verdict-reason
                #:verdict-oracle)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle))

(in-package #:cl-harness-next/tests/verification-oracle-test)

(defmacro with-log-path ((path) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(defclass tool-scripted-transport (mcp-transport)
  ((responses :initarg :responses :reader tool-responses
              :documentation "Alist tool-name → result JSON object text.")
   (calls :initform nil :accessor tool-calls)))

(defmethod transport-send-request ((transport tool-scripted-transport)
                                   body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"tools\":~
[~{{\"name\":\"~A\"}~^,~}]}}"
               id (mapcar #'car (tool-responses transport))))
      ((equal method "tools/call")
       (let* ((tool (gethash "name" (gethash "params" parsed)))
              (entry (assoc tool (tool-responses transport)
                            :test #'string=)))
         (push tool (tool-calls transport))
         (unless entry (error "no canned response for tool ~S" tool))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}"
                 id (cdr entry))))
      (t (error "unexpected method ~S" method)))))

(defparameter *green-responses*
  (list (cons "pool-kill-worker" "{\"content\":[]}")
        (cons "load-system" "{\"content\":[]}")
        (cons "run-tests" "{\"passed\":5,\"failed\":0}")))

(defun %env (responses &key (condition :runtime-native) event-log)
  (make-cl-mcp-environment
   :client (make-mcp-client (make-instance 'tool-scripted-transport
                                           :responses responses))
   :condition condition
   :event-log event-log))

(defun %oracle (&key (mode :clean))
  (make-instance 'verification-oracle
                 :system "s" :test-system "s/tests" :mode mode))

(deftest clean-mode-green-passes
  (let ((verdict (evaluate (%oracle) (%env *green-responses*))))
    (ok (verdict-pass-p verdict))
    (ok (eq :clean-verification (verdict-oracle verdict)))))

(deftest clean-consultation-makes-world-model-clean
  ;; The oracle drives the env, the env records events, SP3 derives
  ;; clean-verify from exactly that sequence — cross-layer coherence.
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (environment (%env *green-responses* :event-log log)))
      (ok (verdict-pass-p (consult (%oracle) environment :event-log log)))
      (let ((world-model (build-world-model path)))
        (ok (clean-verified-p
             (world-model-projection world-model :verification)))))))

(deftest failing-tests-fail-the-verdict
  (let* ((responses (list* (cons "run-tests" "{\"passed\":4,\"failed\":1}")
                           (remove "run-tests" *green-responses*
                                   :key #'car :test #'string=)))
         (verdict (evaluate (%oracle) (%env responses))))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "1/5" (verdict-reason verdict)))))

(deftest iserror-load-fails-the-verdict
  (let* ((responses
           (list* (cons "load-system"
                        (concatenate 'string
                                     "{\"isError\":true,\"content\":"
                                     "[{\"type\":\"text\",\"text\":\"compile error\"}]}"))
                  (remove "load-system" *green-responses*
                          :key #'car :test #'string=)))
         (verdict (evaluate (%oracle) (%env responses))))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "load-system failed" (verdict-reason verdict)))))

(deftest incremental-mode-does-not-kill
  (let* ((transport (make-instance 'tool-scripted-transport
                                   :responses *green-responses*))
         (environment (make-cl-mcp-environment
                       :client (make-mcp-client transport)
                       :condition :runtime-native)))
    (ok (verdict-pass-p (evaluate (%oracle :mode :incremental)
                                  environment)))
    (ok (not (member "pool-kill-worker" (tool-calls transport)
                     :test #'string=)))))

(deftest denied-action-yields-failed-verdict
  (let ((verdict (evaluate (%oracle)
                           (%env *green-responses*
                                 :condition :file-only))))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "verification error" (verdict-reason verdict)))))
