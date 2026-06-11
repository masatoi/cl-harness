;;;; next/src/environment.lisp
;;;;
;;;; L1 environment (spec §5): wraps a cl-mcp client as an
;;;; observation/action space. The action space is restricted by an
;;;; ACTION-SPACE allow-list, and every action and its observation are
;;;; recorded into the attached L0 event log (原則3「すべての実行は
;;;; 実験である」).

(defpackage #:cl-harness-next/src/environment
  (:use #:cl)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-error
                #:mcp-error-message
                #:initialize-mcp
                #:list-tools
                #:call-tool
                #:close-mcp-client)
  (:import-from #:cl-harness-next/src/mcp-stdio
                #:make-stdio-mcp-client)
  (:import-from #:cl-harness-next/src/action-space
                #:make-action-space
                #:action-allowed-p
                #:action-space-mode)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:export #:action-not-allowed
           #:action-not-allowed-tool
           #:action-not-allowed-mode
           #:environment
           #:environment-action-space
           #:perform-action
           #:environment-close
           #:cl-mcp-environment
           #:make-cl-mcp-environment
           #:environment-event-log))

(in-package #:cl-harness-next/src/environment)

(define-condition action-not-allowed (error)
  ((tool :initarg :tool :initform nil :reader action-not-allowed-tool)
   (mode :initarg :mode :initform nil :reader action-not-allowed-mode))
  (:report (lambda (condition stream)
             (format stream "Action ~A is outside the ~A action space."
                     (action-not-allowed-tool condition)
                     (action-not-allowed-mode condition))))
  (:documentation "Signaled by PERFORM-ACTION for a policy-denied tool."))

(defclass environment ()
  ()
  (:documentation "Abstract L1 environment protocol (spec §5)."))

(defgeneric environment-action-space (env)
  (:documentation
   "Return the tool descriptors (hash-tables from tools/list) the agent
may invoke — the policy-filtered action space."))

(defgeneric perform-action (env tool-name arguments)
  (:documentation
   "Invoke TOOL-NAME with ARGUMENTS (a hash-table) in ENV and return
the tools/call result hash-table. Signals ACTION-NOT-ALLOWED when the
action space denies TOOL-NAME. Records :action and :observation events
when ENV carries an event log."))

(defgeneric environment-close (env)
  (:documentation "Release ENV's resources (subprocess, streams)."))

(defclass cl-mcp-environment (environment)
  ((client :initarg :client :reader environment-client)
   (space :initarg :space :reader environment-space)
   (tools :initarg :tools :initform nil :reader environment-tools
          :documentation "Cached tools/list descriptors (list).")
   (event-log :initarg :event-log :initform nil
              :reader environment-event-log))
  (:documentation "L1 environment over a live cl-mcp client."))

(defun %tool-descriptor-name (descriptor)
  (gethash "name" descriptor))

(defun make-cl-mcp-environment (&key client command
                                     (condition :runtime-native)
                                     rules event-log
                                     (request-timeout 60))
  "Build a CL-MCP-ENVIRONMENT.

CLIENT, when supplied, is an already-constructed MCP-CLIENT (tests
inject a scripted transport this way); otherwise a cl-mcp subprocess is
spawned over stdio with COMMAND / REQUEST-TIMEOUT. Runs the MCP
initialize handshake and tools/list, then restricts the action space to
CONDITION's built-in rules — or explicit RULES, e.g. a policy pack's
:tool-policies entry. EVENT-LOG, when supplied, receives
:action/:observation events for every PERFORM-ACTION."
  (let ((client (or client (make-stdio-mcp-client
                            :command command
                            :request-timeout request-timeout))))
    (initialize-mcp client)
    (let* ((tools (coerce (list-tools client) 'list))
           (space (make-action-space
                   condition
                   :rules rules
                   :available-tools (mapcar #'%tool-descriptor-name tools))))
      (make-instance 'cl-mcp-environment
                     :client client
                     :space space
                     :tools tools
                     :event-log event-log))))

(defmethod environment-action-space ((env cl-mcp-environment))
  (remove-if-not (lambda (descriptor)
                   (action-allowed-p (environment-space env)
                                     (%tool-descriptor-name descriptor)))
                 (environment-tools env)))

(defun %emit (env type payload)
  (let ((log (environment-event-log env)))
    (when log (emit-event log type payload))))

(defmethod perform-action ((env cl-mcp-environment) tool-name arguments)
  (check-type tool-name string)
  (check-type arguments hash-table)
  (let ((space (environment-space env)))
    (unless (action-allowed-p space tool-name)
      (error 'action-not-allowed
             :tool tool-name
             :mode (action-space-mode space))))
  (%emit env :action (alexandria:plist-hash-table
                      (list "tool" tool-name "arguments" arguments)
                      :test #'equal))
  (handler-case
      (let ((result (call-tool (environment-client env)
                               tool-name arguments)))
        (%emit env :observation (alexandria:plist-hash-table
                                 (list "tool" tool-name "result" result)
                                 :test #'equal))
        result)
    (mcp-error (e)
      (%emit env :observation (alexandria:plist-hash-table
                               (list "tool" tool-name
                                     "error" (mcp-error-message e))
                               :test #'equal))
      (error e))))

(defmethod environment-close ((env cl-mcp-environment))
  (close-mcp-client (environment-client env)))
