;;;; next/tests/environment-test.lisp
;;;;
;;;; Tests for next/src/environment.lisp using a scripted transport
;;;; (no subprocess): policy-filtered action space, action/observation
;;;; event recording, denial signaling, error-observation recording,
;;;; close propagation (spec §5 + 原則3).

(defpackage #:cl-harness-next/tests/environment-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:transport-close
                #:make-mcp-client
                #:mcp-error)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment
                #:environment-action-space
                #:perform-action
                #:environment-close
                #:action-not-allowed))

(in-package #:cl-harness-next/tests/environment-test)

(defmacro with-log-path ((path) &body body)
  "Fresh temporary .jsonl path that does not exist yet."
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(defclass scripted-transport (mcp-transport)
  ((script :initarg :script :reader scripted-script
           :documentation "Alist of (METHOD . RESULT-OR-ERROR-JSON-FRAGMENT).")
   (closed-p :initform nil :accessor scripted-closed-p))
  (:documentation "Canned-response transport: echoes the request id and
splices the scripted fragment for the request's method."))

(defmethod transport-send-request ((transport scripted-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (if (null id)
        ""
        (let ((entry (assoc method (scripted-script transport)
                            :test #'string=)))
          (unless entry
            (error "scripted-transport: no canned response for ~S" method))
          (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id (cdr entry))))))

(defmethod transport-close ((transport scripted-transport))
  (setf (scripted-closed-p transport) t))

(defparameter *base-script*
  (list (cons "initialize" "\"result\":{\"protocolVersion\":\"2025-06-18\"}")
        (cons "tools/list"
              (concatenate 'string
                           "\"result\":{\"tools\":["
                           "{\"name\":\"repl-eval\"},"
                           "{\"name\":\"fs-read-file\"},"
                           "{\"name\":\"lisp-edit-form\"},"
                           "{\"name\":\"run-tests\"}]}"))
        (cons "tools/call"
              (concatenate 'string
                           "\"result\":{\"content\":"
                           "[{\"type\":\"text\",\"text\":\"3\"}]}"))))

(defun %make-scripted-env (&key (condition :runtime-native) event-log
                                (script *base-script*))
  (make-cl-mcp-environment
   :client (make-mcp-client (make-instance 'scripted-transport
                                           :script script))
   :condition condition
   :event-log event-log))

(deftest action-space-is-policy-filtered
  (let ((env (%make-scripted-env :condition :file-only)))
    (ok (equal '("fs-read-file" "run-tests")
               (mapcar (lambda (descriptor) (gethash "name" descriptor))
                       (environment-action-space env))))))

(deftest perform-action-records-action-and-observation
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (env (%make-scripted-env :event-log log))
           (result (perform-action env "repl-eval"
                                   (alexandria:plist-hash-table
                                    (list "code" "(+ 1 2)")
                                    :test #'equal))))
      (ok (hash-table-p result))
      (let ((events (read-events path)))
        (ok (equal '(:action :observation) (mapcar #'event-type events)))
        (ok (equal "repl-eval"
                   (gethash "tool" (event-payload (first events)))))
        (ok (equal "(+ 1 2)"
                   (gethash "code"
                            (gethash "arguments"
                                     (event-payload (first events))))))
        (ok (gethash "result" (event-payload (second events))))))))

(deftest denied-action-signals-without-events
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (env (%make-scripted-env :condition :file-only :event-log log)))
      (ok (handler-case
              (progn (perform-action env "repl-eval"
                                     (make-hash-table :test #'equal))
                     nil)
            (action-not-allowed () t)))
      (ok (null (probe-file path))))))

(deftest mcp-error-is-recorded-then-resignaled
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (script (list* (cons "tools/call"
                                "\"error\":{\"code\":-32000,\"message\":\"boom\"}")
                          (remove "tools/call" *base-script*
                                  :key #'car :test #'string=)))
           (env (%make-scripted-env :event-log log :script script)))
      (ok (handler-case
              (progn (perform-action env "run-tests"
                                     (make-hash-table :test #'equal))
                     nil)
            (mcp-error () t)))
      (let ((events (read-events path)))
        (ok (= 2 (length events)))
        (ok (equal "boom"
                   (gethash "error" (event-payload (second events)))))))))

(deftest environment-close-closes-transport
  (let* ((transport (make-instance 'scripted-transport
                                   :script *base-script*))
         (env (make-cl-mcp-environment
               :client (make-mcp-client transport))))
    (environment-close env)
    (ok (scripted-closed-p transport))))

(deftest action-not-allowed-prints-without-initargs
  (ok (stringp (princ-to-string (make-condition 'action-not-allowed)))))
