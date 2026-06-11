;;;; next/src/mcp-client.lisp
;;;;
;;;; JSON-RPC 2.0 client core for cl-mcp, adapted from legacy
;;;; src/mcp.lisp with the HTTP transport removed (SP2 decision:
;;;; stdio-only — the redesign's isolation model is one cl-mcp
;;;; subprocess per run, spec §5). The transport is an abstract CLOS
;;;; object; the stdio implementation lives in next/src/mcp-stdio.lisp.

(defpackage #:cl-harness-next/src/mcp-client
  (:use #:cl)
  (:export #:+mcp-protocol-version+
           #:mcp-error
           #:mcp-error-code
           #:mcp-error-message
           #:mcp-error-data
           #:mcp-transport
           #:transport-send-request
           #:transport-close
           #:mcp-client
           #:make-mcp-client
           #:mcp-client-transport
           #:mcp-client-protocol-version
           #:mcp-build-request
           #:mcp-build-notification
           #:mcp-parse-response
           #:initialize-mcp
           #:list-tools
           #:call-tool
           #:close-mcp-client))

(in-package #:cl-harness-next/src/mcp-client)

(defparameter +mcp-protocol-version+ "2025-06-18"
  "MCP protocol version this client negotiates with the server.")

(define-condition mcp-error (error)
  ((code :initarg :code :initform nil :reader mcp-error-code)
   (message :initarg :message :initform "(no message)"
            :reader mcp-error-message)
   (data :initarg :data :initform nil :reader mcp-error-data))
  (:report (lambda (condition stream)
             (format stream "MCP error ~A: ~A"
                     (mcp-error-code condition)
                     (mcp-error-message condition))))
  (:documentation "JSON-RPC error envelope returned by an MCP server."))

(defclass mcp-transport ()
  ()
  (:documentation
   "Abstract base for an MCP wire transport. Concrete subclasses
implement TRANSPORT-SEND-REQUEST and (optionally) TRANSPORT-CLOSE."))

(defgeneric transport-send-request (transport body)
  (:documentation
   "Send BODY (a JSON-RPC request or notification string) over TRANSPORT
and return the response body as a string. For notifications the returned
string is empty; the caller discards it."))

(defgeneric transport-close (transport)
  (:documentation
   "Release any resources held by TRANSPORT. Default is a no-op.")
  (:method ((transport mcp-transport)) nil))

(defclass mcp-client ()
  ((transport :initarg :transport :reader mcp-client-transport)
   (protocol-version :initarg :protocol-version
                     :initform +mcp-protocol-version+
                     :reader mcp-client-protocol-version)
   (next-id :initform 0 :accessor %mcp-next-id))
  (:documentation
   "JSON-RPC 2.0 client for cl-mcp. The wire-level details live in
TRANSPORT; the client owns only the request-id counter and the
protocol-version handshake state."))

(defun make-mcp-client (transport &key (protocol-version +mcp-protocol-version+))
  "Construct an MCP-CLIENT over TRANSPORT (an MCP-TRANSPORT instance)."
  (check-type transport mcp-transport)
  (check-type protocol-version string)
  (make-instance 'mcp-client
                 :transport transport
                 :protocol-version protocol-version))

(defun close-mcp-client (client)
  "Release the transport's resources. Safe to call multiple times."
  (transport-close (mcp-client-transport client)))

(defun mcp-build-request (id method &key params)
  "Build a JSON-RPC 2.0 request string with ID, METHOD, and optional
PARAMS. PARAMS, when supplied, must already be a hash-table that yason
can encode."
  (check-type id integer)
  (check-type method string)
  (let ((table (alexandria:alist-hash-table
                `(("jsonrpc" . "2.0")
                  ("id" . ,id)
                  ("method" . ,method))
                :test #'equal)))
    (when params
      (setf (gethash "params" table) params))
    (with-output-to-string (out) (yason:encode table out))))

(defun mcp-build-notification (method &key params)
  "Build a JSON-RPC 2.0 notification (no id) for METHOD."
  (check-type method string)
  (let ((table (alexandria:alist-hash-table
                `(("jsonrpc" . "2.0")
                  ("method" . ,method))
                :test #'equal)))
    (when params
      (setf (gethash "params" table) params))
    (with-output-to-string (out) (yason:encode table out))))

(defun mcp-parse-response (json-string)
  "Parse a JSON-RPC 2.0 response string and return its RESULT object.
Signals MCP-ERROR if the response carries an error envelope."
  (check-type json-string string)
  (let ((parsed (yason:parse json-string)))
    (let ((err (gethash "error" parsed)))
      (when err
        (error 'mcp-error
               :code (gethash "code" err)
               :message (gethash "message" err)
               :data (gethash "data" err))))
    (gethash "result" parsed)))

(defun %send (client body)
  "Forward BODY to CLIENT's transport and return the response body string."
  (transport-send-request (mcp-client-transport client) body))

(defun initialize-mcp (client &key (client-name "cl-harness-next")
                                   (client-version "0.1.0"))
  "Run the MCP initialize handshake and send notifications/initialized.
Returns the server's INITIALIZE result hash-table."
  (let* ((id (incf (%mcp-next-id client)))
         (params (alexandria:alist-hash-table
                  `(("protocolVersion" . ,(mcp-client-protocol-version client))
                    ("capabilities" . ,(make-hash-table :test #'equal))
                    ("clientInfo" . ,(alexandria:alist-hash-table
                                      `(("name" . ,client-name)
                                        ("version" . ,client-version))
                                      :test #'equal)))
                  :test #'equal))
         (request (mcp-build-request id "initialize" :params params))
         (response (%send client request))
         (result (mcp-parse-response response)))
    (%send client (mcp-build-notification "notifications/initialized"))
    result))

(defgeneric list-tools (client)
  (:documentation
   "Return the tool descriptors from CLIENT's tools/list (a list or
vector of hash-tables, per yason's array decoding)."))

(defmethod list-tools ((client mcp-client))
  (let* ((id (incf (%mcp-next-id client)))
         (request (mcp-build-request id "tools/list"))
         (response (%send client request))
         (result (mcp-parse-response response)))
    (gethash "tools" result)))

(defgeneric call-tool (client tool-name arguments)
  (:documentation
   "Invoke TOOL-NAME with ARGUMENTS hash-table on CLIENT. Returns the
tools/call RESULT hash-table."))

(defmethod call-tool ((client mcp-client) tool-name (arguments hash-table))
  (check-type tool-name string)
  (let* ((id (incf (%mcp-next-id client)))
         (params (alexandria:alist-hash-table
                  `(("name" . ,tool-name)
                    ("arguments" . ,arguments))
                  :test #'equal))
         (request (mcp-build-request id "tools/call" :params params))
         (response (%send client request)))
    (mcp-parse-response response)))
