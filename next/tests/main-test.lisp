;;;; next/tests/main-test.lisp
;;;;
;;;; Facade smoke tests + cross-module integration tests for
;;;; cl-harness-next (SP1: L0 substrate).

(defpackage #:cl-harness-next/tests/main-test
  (:use #:cl #:rove))

(in-package #:cl-harness-next/tests/main-test)

(deftest facade-package-exists
  (ok (find-package '#:cl-harness-next))
  (ok (equal "0.1.0" (cl-harness-next:substrate-version))))

(deftest run-start-records-pack-fingerprint
  ;; SP1 acceptance: a run can durably record which policy pack it
  ;; used (spec 原則3「すべての実行は実験である」).
  (uiop:with-temporary-file (:pathname pack-path :type "sexp")
    (with-open-file (out pack-path :direction :output
                                   :if-exists :supersede
                                   :external-format :utf-8)
      (write-string "(:name \"default\" :version \"0.1.0\")" out))
    (uiop:with-temporary-file (:pathname log-path :type "jsonl")
      (uiop:delete-file-if-exists log-path)
      (let ((pack (cl-harness-next:load-policy-pack pack-path))
            (log (cl-harness-next:open-event-log log-path)))
        (cl-harness-next:emit-event
         log :run-start
         (alexandria:plist-hash-table
          (list "pack_name" (cl-harness-next:pack-name pack)
                "pack_fingerprint" (cl-harness-next:pack-fingerprint pack))
          :test #'equal))
        (let ((event (first (cl-harness-next:read-events log-path))))
          (ok (eq :run-start (cl-harness-next:event-type event)))
          (ok (equal (cl-harness-next:pack-fingerprint pack)
                     (gethash "pack_fingerprint"
                              (cl-harness-next:event-payload event)))))))))

(defclass %facade-scripted-transport (cl-harness-next:mcp-transport)
  ()
  (:documentation "Minimal canned transport for the facade acceptance
test; lives here because the test must only use facade symbols."))

(defmethod cl-harness-next:transport-send-request
    ((transport %facade-scripted-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}"
               id
               "\"result\":{\"tools\":[{\"name\":\"run-tests\"}]}"))
      ((equal method "tools/call")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"content\":[]}}"
               id))
      (t (error "unexpected method ~S" method)))))

(deftest facade-environment-records-events
  ;; SP2 acceptance: through the facade alone, wrap an MCP client as a
  ;; policy-restricted environment and observe the action/observation
  ;; events land in the L0 log (spec §5 + 原則3).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (cl-harness-next:open-event-log log-path))
           (env (cl-harness-next:make-cl-mcp-environment
                 :client (cl-harness-next:make-mcp-client
                          (make-instance '%facade-scripted-transport))
                 :condition :file-only
                 :event-log log)))
      (cl-harness-next:perform-action env "run-tests"
                                      (make-hash-table :test #'equal))
      (cl-harness-next:environment-close env)
      (ok (equal '(:action :observation)
                 (mapcar #'cl-harness-next:event-type
                         (cl-harness-next:read-events log-path)))))))
