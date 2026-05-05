;;;; src/mcp.lisp
;;;;
;;;; PRD §8.3, §10.2, §10.3 — JSON-RPC 2.0 over HTTP client for cl-mcp.
;;;; Streamable HTTP transport (single POST per call) is the only flavour
;;;; required for MVP. The TRANSPORT slot is an injectable function so tests
;;;; can replace dexador with a recording stub.

(defpackage #:cl-harness/src/mcp
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table
                #:when-let)
  (:import-from #:dexador
                #:http-request-failed
                #:response-status
                #:response-body)
  (:export #:mcp-client
           #:make-mcp-client
           #:mcp-client-url
           #:mcp-client-session-id
           #:mcp-client-protocol-version
           #:mcp-error
           #:mcp-error-code
           #:mcp-error-message
           #:mcp-error-data
           #:mcp-build-request
           #:mcp-build-notification
           #:mcp-parse-response
           #:initialize-mcp
           #:list-tools
           #:call-tool
           #:+mcp-protocol-version+))

(in-package #:cl-harness/src/mcp)

(defparameter +mcp-protocol-version+ "2025-06-18"
  "MCP protocol version this client negotiates with the server.")

(define-condition mcp-error (error)
  ((code :initarg :code :reader mcp-error-code)
   (message :initarg :message :reader mcp-error-message)
   (data :initarg :data :initform nil :reader mcp-error-data))
  (:documentation "JSON-RPC error envelope returned by an MCP server.")
  (:report (lambda (c stream)
             (format stream "MCP error ~A: ~A"
                     (mcp-error-code c) (mcp-error-message c)))))

(defclass mcp-client ()
  ((url :initarg :url :reader mcp-client-url)
   (transport :initarg :transport :reader mcp-client-transport)
   (protocol-version :initarg :protocol-version
                     :initform +mcp-protocol-version+
                     :reader mcp-client-protocol-version)
   (session-id :initform nil :accessor mcp-client-session-id)
   (next-id :initform 0 :accessor %mcp-next-id))
  (:documentation
   "JSON-RPC 2.0 over HTTP client for cl-mcp (PRD §10.2 mcp-client).
TRANSPORT is a function of (URL HEADERS BODY) returning
(values RESPONSE-BODY STATUS RESPONSE-HEADERS); tests inject a stub."))

;; --- Stubs ---------------------------------------------------------------
;; These are intentionally wrong return values so the failing tests will
;; surface assertion failures (not just load errors). The real
;; implementation replaces every body below.

(defun default-http-transport (url headers body)
  "POST BODY to URL with HEADERS hash-table using dexador.

Returns (values RESPONSE-BODY STATUS RESPONSE-HEADERS). Non-2xx HTTP
responses are surfaced as their captured body, status, and an empty
header table — the caller is responsible for propagating MCP-level
errors via MCP-PARSE-RESPONSE.

Connection reuse (keep-alive) is disabled so repeated calls against an
MCP server that closes idle sockets do not surface stale streams."
  (let ((header-list (let ((acc '()))
                       (maphash (lambda (k v) (push (cons k v) acc)) headers)
                       (nreverse acc))))
    (handler-case
        (multiple-value-bind (resp-body status resp-headers)
            (dexador:post url :headers header-list :content body
                              :keep-alive nil)
          (values resp-body status resp-headers))
      (http-request-failed (c)
        (values (response-body c)
                (response-status c)
                (make-hash-table :test 'equal))))))

(defun make-mcp-client (url &key transport (protocol-version +mcp-protocol-version+))
  "Construct an MCP-CLIENT against URL.

TRANSPORT defaults to a dexador-backed POST. PROTOCOL-VERSION pins the version
sent during initialize."
  (check-type url string)
  (check-type protocol-version string)
  (make-instance 'mcp-client
                 :url url
                 :transport (or transport #'default-http-transport)
                 :protocol-version protocol-version))

(defun mcp-build-request (id method &key params)
  "Build a JSON-RPC 2.0 request string with ID, METHOD, and optional PARAMS.

PARAMS, when supplied, must already be a hash-table that yason can encode."
  (check-type id integer)
  (check-type method string)
  (let ((tbl (alist-hash-table `(("jsonrpc" . "2.0")
                                 ("id" . ,id)
                                 ("method" . ,method))
                               :test 'equal)))
    (when params
      (setf (gethash "params" tbl) params))
    (with-output-to-string (s) (yason:encode tbl s))))

(defun mcp-build-notification (method &key params)
  "Build a JSON-RPC 2.0 notification (no id) for METHOD."
  (check-type method string)
  (let ((tbl (alist-hash-table `(("jsonrpc" . "2.0")
                                 ("method" . ,method))
                               :test 'equal)))
    (when params
      (setf (gethash "params" tbl) params))
    (with-output-to-string (s) (yason:encode tbl s))))

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

(defun %request-headers (client)
  "Build the per-request header table for CLIENT, including the captured
session-id once the initialize handshake has assigned one."
  (let ((hdrs (alist-hash-table
               '(("Content-Type" . "application/json")
                 ("Accept" . "application/json, text/event-stream"))
               :test 'equal)))
    (when-let ((sid (mcp-client-session-id client)))
      (setf (gethash "Mcp-Session-Id" hdrs) sid))
    hdrs))

(defun %extract-session-id (response-headers)
  "Return the MCP session id from RESPONSE-HEADERS or NIL.

Server implementations spell the header inconsistently across casings, so
check both lowercase and the canonical mixed-case spelling."
  (when (hash-table-p response-headers)
    (or (gethash "mcp-session-id" response-headers)
        (gethash "Mcp-Session-Id" response-headers))))

(defun %send (client body)
  "POST BODY using CLIENT's transport, capturing a session-id when one is
returned. Returns the response body string."
  (let ((headers (%request-headers client)))
    (multiple-value-bind (resp-body status resp-headers)
        (funcall (mcp-client-transport client)
                 (mcp-client-url client) headers body)
      (declare (ignore status))
      (when-let ((sid (%extract-session-id resp-headers)))
        (unless (mcp-client-session-id client)
          (setf (mcp-client-session-id client) sid)))
      resp-body)))

(defun initialize-mcp (client &key (client-name "cl-harness")
                                   (client-version "0.0.1"))
  "Run the MCP initialize handshake and send notifications/initialized.

Updates CLIENT's session-id from the response headers and returns the
server's INITIALIZE result hash-table (PRD §8.3 REQ-MCP-001)."
  (let* ((id (incf (%mcp-next-id client)))
         (params (alist-hash-table
                  `(("protocolVersion" . ,(mcp-client-protocol-version client))
                    ("capabilities" . ,(make-hash-table :test 'equal))
                    ("clientInfo" . ,(alist-hash-table
                                      `(("name" . ,client-name)
                                        ("version" . ,client-version))
                                      :test 'equal)))
                  :test 'equal))
         (req (mcp-build-request id "initialize" :params params))
         (resp (%send client req))
         (result (mcp-parse-response resp)))
    (%send client (mcp-build-notification "notifications/initialized"))
    result))

(defgeneric list-tools (client)
  (:documentation "Return the vector of tool descriptors from CLIENT (PRD §10.3)."))

(defmethod list-tools ((client mcp-client))
  (let* ((id (incf (%mcp-next-id client)))
         (req (mcp-build-request id "tools/list"))
         (resp (%send client req))
         (result (mcp-parse-response resp)))
    (gethash "tools" result)))

(defgeneric call-tool (client tool-name arguments)
  (:documentation "Invoke TOOL-NAME with ARGUMENTS hash-table on CLIENT.
Returns the tools/call RESULT hash-table (PRD §10.3)."))

(defmethod call-tool ((client mcp-client) tool-name (arguments hash-table))
  (check-type tool-name string)
  (let* ((id (incf (%mcp-next-id client)))
         (params (alist-hash-table
                  `(("name" . ,tool-name)
                    ("arguments" . ,arguments))
                  :test 'equal))
         (req (mcp-build-request id "tools/call" :params params))
         (resp (%send client req)))
    (mcp-parse-response resp)))
