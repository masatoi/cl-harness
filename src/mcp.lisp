;;;; src/mcp.lisp
;;;;
;;;; PRD §8.3, §10.2, §10.3 — JSON-RPC 2.0 client for cl-mcp.
;;;;
;;;; The transport is now an object (HTTP-MCP-TRANSPORT for the original
;;;; HTTP path; STDIO-MCP-TRANSPORT lands in Phase B per
;;;; docs/notes/2026-05-06-stdio-transport.md). MCP-CLIENT delegates the
;;;; wire-level send/receive to TRANSPORT-SEND-REQUEST so the rest of the
;;;; code never branches on transport.
;;;;
;;;; Tests still inject a (URL HEADERS BODY) closure as :transport;
;;;; MAKE-MCP-CLIENT wraps that closure into an HTTP-MCP-TRANSPORT
;;;; transparently, so existing call sites do not need to know the
;;;; refactor happened.

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
           #:mcp-client-transport
           #:mcp-transport
           #:http-mcp-transport
           #:transport-send-request
           #:transport-close
           #:default-http-transport
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
           #:close-mcp-client
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

;; --- Transport -----------------------------------------------------------

(defclass mcp-transport ()
  ()
  (:documentation
   "Abstract base for an MCP wire transport. Concrete subclasses
implement TRANSPORT-SEND-REQUEST and (optionally) TRANSPORT-CLOSE. The
HTTP transport is in this file; the stdio transport lands in Phase B."))

(defgeneric transport-send-request (transport body)
  (:documentation
   "Send BODY (a JSON-RPC request or notification string) over TRANSPORT
and return the response body as a string. For notifications the returned
string is empty (HTTP 202) or NIL (stdio); the caller discards it."))

(defgeneric transport-close (transport)
  (:documentation
   "Release any resources held by TRANSPORT. Default is a no-op so HTTP
transports (which own no resources beyond keep-alive disabled sockets)
do nothing.")
  (:method ((transport mcp-transport)) nil))

;; --- HTTP transport ------------------------------------------------------

(defclass http-mcp-transport (mcp-transport)
  ((url :initarg :url :reader http-transport-url)
   (raw-fn :initarg :raw-fn :reader http-transport-raw-fn)
   (session-id :initform nil :accessor http-transport-session-id))
  (:documentation
   "JSON-RPC over HTTP transport for cl-mcp. RAW-FN is a function of
(URL HEADERS BODY) returning (values RESPONSE-BODY STATUS HEADERS); tests
inject a stub here. SESSION-ID is captured from the first response that
carries an Mcp-Session-Id header and forwarded on subsequent calls."))

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

(defun %extract-session-id (response-headers)
  "Return the MCP session id from RESPONSE-HEADERS or NIL.

Server implementations spell the header inconsistently across casings, so
check both lowercase and the canonical mixed-case spelling."
  (when (hash-table-p response-headers)
    (or (gethash "mcp-session-id" response-headers)
        (gethash "Mcp-Session-Id" response-headers))))

(defun %http-request-headers (transport)
  "Build the per-request header table for TRANSPORT, including the
captured session-id once the initialize handshake has assigned one."
  (let ((hdrs (alist-hash-table
               '(("Content-Type" . "application/json")
                 ("Accept" . "application/json, text/event-stream"))
               :test 'equal)))
    (when-let ((sid (http-transport-session-id transport)))
      (setf (gethash "Mcp-Session-Id" hdrs) sid))
    hdrs))

(defmethod transport-send-request ((transport http-mcp-transport) body)
  (let ((headers (%http-request-headers transport)))
    (multiple-value-bind (resp-body status resp-headers)
        (funcall (http-transport-raw-fn transport)
                 (http-transport-url transport) headers body)
      (declare (ignore status))
      (when-let ((sid (%extract-session-id resp-headers)))
        (unless (http-transport-session-id transport)
          (setf (http-transport-session-id transport) sid)))
      resp-body)))

;; --- Client --------------------------------------------------------------

(defclass mcp-client ()
  ((transport :initarg :transport :reader mcp-client-transport)
   (protocol-version :initarg :protocol-version
                     :initform +mcp-protocol-version+
                     :reader mcp-client-protocol-version)
   (next-id :initform 0 :accessor %mcp-next-id))
  (:documentation
   "JSON-RPC 2.0 client for cl-mcp (PRD §10.2). The wire-level details
live in TRANSPORT; the client owns only the request-id counter and the
protocol-version handshake state."))

(defgeneric mcp-client-url (client)
  (:documentation
   "Backward-compat reader: the URL of the underlying HTTP transport, or
NIL when the client uses a non-HTTP transport.")
  (:method ((client mcp-client))
    (let ((tr (mcp-client-transport client)))
      (when (typep tr 'http-mcp-transport)
        (http-transport-url tr)))))

(defgeneric mcp-client-session-id (client)
  (:documentation
   "Backward-compat reader: the HTTP session-id captured during
INITIALIZE-MCP, or NIL for non-HTTP transports.")
  (:method ((client mcp-client))
    (let ((tr (mcp-client-transport client)))
      (when (typep tr 'http-mcp-transport)
        (http-transport-session-id tr)))))

(defun %coerce-transport (transport url)
  "Return an MCP-TRANSPORT instance for TRANSPORT, lifting legacy
function-shaped transports into an HTTP-MCP-TRANSPORT against URL.

- TRANSPORT NIL ⇒ HTTP transport using DEFAULT-HTTP-TRANSPORT against URL.
- TRANSPORT a function ⇒ HTTP transport using that function as RAW-FN
  (the legacy test contract: (URL HEADERS BODY) → (values BODY STATUS HEADERS)).
- TRANSPORT an MCP-TRANSPORT instance ⇒ used as-is; URL is ignored."
  (cond
    ((typep transport 'mcp-transport) transport)
    ((or (functionp transport) (null transport))
     (unless url
       (error "make-mcp-client: URL is required for an HTTP transport"))
     (make-instance 'http-mcp-transport
                    :url url
                    :raw-fn (or transport #'default-http-transport)))
    (t (error "make-mcp-client: unsupported :transport value ~A" transport))))

(defun make-mcp-client (url &key transport
                                 (protocol-version +mcp-protocol-version+))
  "Construct an MCP-CLIENT.

URL is the HTTP endpoint when TRANSPORT is nil or a closure, and is
ignored when TRANSPORT is an MCP-TRANSPORT instance.

TRANSPORT may be:
- NIL — default HTTP transport via DEFAULT-HTTP-TRANSPORT against URL.
- a function (URL HEADERS BODY) → (values BODY STATUS HEADERS) — wrapped
  into an HTTP-MCP-TRANSPORT with that function as the raw send. Tests
  inject a stub here.
- an MCP-TRANSPORT instance — used directly. Stdio transports plug in
  this way (Phase B)."
  (check-type url (or string null))
  (check-type protocol-version string)
  (make-instance 'mcp-client
                 :transport (%coerce-transport transport url)
                 :protocol-version protocol-version))

(defun close-mcp-client (client)
  "Release the transport's resources. Safe to call multiple times."
  (transport-close (mcp-client-transport client)))

;; --- Wire helpers --------------------------------------------------------

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

(defun %send (client body)
  "Forward BODY to CLIENT's transport and return the response body string."
  (transport-send-request (mcp-client-transport client) body))

;; --- Public API ----------------------------------------------------------

(defun initialize-mcp (client &key (client-name "cl-harness")
                                   (client-version "0.0.1"))
  "Run the MCP initialize handshake and send notifications/initialized.

For HTTP transports the response's Mcp-Session-Id header is captured and
forwarded on subsequent calls. Returns the server's INITIALIZE result
hash-table (PRD §8.3 REQ-MCP-001)."
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
