;;;; next/src/mcp-stdio.lisp
;;;;
;;;; Stdio MCP transport, adapted from legacy src/mcp-stdio.lisp.
;;;; Spawns a cl-mcp subprocess, talks JSON-RPC 2.0 over its
;;;; stdin/stdout, drains its stderr to *ERROR-OUTPUT*, and exposes
;;;; the result as an MCP-TRANSPORT so MCP-CLIENT never branches on
;;;; transport. One subprocess per environment is the redesign's
;;;; isolation model (spec §5).

(defpackage #:cl-harness-next/src/mcp-stdio
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:transport-close
                #:make-mcp-client
                #:+mcp-protocol-version+)
  (:export #:stdio-mcp-transport
           #:make-stdio-mcp-transport
           #:make-stdio-mcp-client
           #:stdio-mcp-error
           #:stdio-mcp-error-message
           #:*default-stdio-command*
           ;; Internal but public for tests:
           #:stdio-request-stream
           #:%route-response-line))

(in-package #:cl-harness-next/src/mcp-stdio)

(defparameter *default-stdio-command*
  '("ros" "run" "-s" "cl-mcp"
    "-e" "(cl-mcp:run :transport :stdio)")
  "Default argv list for spawning cl-mcp in stdio mode via Roswell.
Override with :COMMAND on MAKE-STDIO-MCP-TRANSPORT when cl-mcp is
installed differently or a prebuilt binary is on $PATH.")

(define-condition stdio-mcp-error (error)
  ((message :initarg :message :initform "(no message)"
            :reader stdio-mcp-error-message))
  (:report (lambda (condition stream)
             (format stream "stdio-mcp error: ~A"
                     (stdio-mcp-error-message condition))))
  (:documentation "Wire-level failure of the stdio MCP transport."))

(defstruct (%pending-entry (:conc-name %pending-))
  (cv (make-condition-variable))
  (result nil)
  (done-p nil))

(defclass stdio-mcp-transport (mcp-transport)
  ((process-info :initarg :process-info :initform nil
                 :reader stdio-process-info)
   (request-stream :initarg :request-stream :reader stdio-request-stream)
   (response-stream :initarg :response-stream :reader stdio-response-stream)
   (lock :initform (make-lock "stdio-mcp-lock") :reader stdio-lock)
   (pending :initform (make-hash-table :test 'eql) :reader stdio-pending)
   (reader-thread :initform nil :accessor stdio-reader-thread)
   (stderr-stream :initarg :stderr-stream :initform nil
                  :reader stdio-stderr-stream)
   (stderr-thread :initform nil :accessor stdio-stderr-thread)
   (closed-p :initform nil :accessor stdio-closed-p)
   (request-timeout :initarg :request-timeout :initform 60
                    :reader stdio-request-timeout))
  (:documentation
   "MCP transport over a subprocess's stdin/stdout (newline-delimited
JSON-RPC). PROCESS-INFO is the UIOP launch handle (NIL when a stream
pair was injected directly, e.g. by tests). PENDING maps a JSON-RPC
request id to a %PENDING-ENTRY whose CV is signalled when the matching
response line arrives."))

(defun %parse-id-from-body (body)
  "Return the JSON-RPC \"id\" field from a request BODY string, or NIL
when BODY is a notification."
  (let ((parsed (yason:parse body)))
    (and (hash-table-p parsed) (gethash "id" parsed))))

(defun %route-response-line (transport line)
  "Parse LINE as a JSON-RPC response and deliver it to the pending entry
matching its id. Lines without an id and unmatched ids are dropped.
Parse errors are logged on *ERROR-OUTPUT* and tolerated, so one
malformed line does not break the reader thread."
  (handler-case
      (let* ((parsed (yason:parse line))
             (id (and (hash-table-p parsed) (gethash "id" parsed))))
        (when id
          (with-lock-held ((stdio-lock transport))
            (let ((entry (gethash id (stdio-pending transport))))
              (when entry
                (setf (%pending-result entry) line
                      (%pending-done-p entry) t)
                (condition-notify (%pending-cv entry)))))))
    (error (c)
      (format *error-output* "[stdio-mcp parse error] ~A line=~S~%" c line))))

(defun %wake-all-pending (transport reason)
  "Mark every outstanding pending entry done with REASON in the result
slot and signal its CV so any waiter unblocks. Used on EOF/close."
  (with-lock-held ((stdio-lock transport))
    (maphash (lambda (id entry)
               (declare (ignore id))
               (unless (%pending-done-p entry)
                 (setf (%pending-result entry) reason
                       (%pending-done-p entry) :stream-closed)
                 (condition-notify (%pending-cv entry))))
             (stdio-pending transport))))

(defun %read-loop (transport)
  "Reader-thread body: read newline-delimited JSON from the transport's
RESPONSE-STREAM and route each line into the pending table."
  (let ((stream (stdio-response-stream transport)))
    (handler-case
        (loop
          (let ((line (read-line stream nil nil)))
            (when (null line) (return))
            (unless (zerop (length line))
              (%route-response-line transport line))))
      (error (c)
        (format *error-output* "[stdio-mcp reader] ~A~%" c)))
    (%wake-all-pending transport "stdio response stream closed")))

(defun %drain-stderr (stream)
  "Drain the cl-mcp subprocess's stderr to *ERROR-OUTPUT*, prefixed.
Runs on its own thread so the subprocess's pipe never fills up."
  (handler-case
      (loop for line = (read-line stream nil nil)
            while line
            do (format *error-output* "[cl-mcp stderr] ~A~%" line)
               (force-output *error-output*))
    (error () nil)))

(defgeneric start-reader-threads (transport)
  (:documentation
   "Spawn the reader (and stderr drain, if applicable) threads bound to
TRANSPORT. Idempotent: a second call does nothing.")
  (:method ((transport stdio-mcp-transport))
    (unless (stdio-reader-thread transport)
      (setf (stdio-reader-thread transport)
            (make-thread (lambda () (%read-loop transport))
                         :name "stdio-mcp-reader")))
    (when (and (stdio-stderr-stream transport)
               (not (stdio-stderr-thread transport)))
      (setf (stdio-stderr-thread transport)
            (make-thread (lambda ()
                           (%drain-stderr (stdio-stderr-stream transport)))
                         :name "stdio-mcp-stderr")))))

(defun make-stdio-mcp-transport (&key command (request-timeout 60))
  "Spawn a cl-mcp subprocess (COMMAND, default *DEFAULT-STDIO-COMMAND*)
and return a STDIO-MCP-TRANSPORT bound to its pipes. Reader and stderr
drain threads start immediately. Caller is responsible for invoking
TRANSPORT-CLOSE (or CLOSE-MCP-CLIENT) to terminate the subprocess."
  (let* ((cmd (or command *default-stdio-command*))
         (process-info (uiop:launch-program
                        cmd
                        :input :stream
                        :output :stream
                        :error-output :stream
                        :element-type 'character))
         (transport (make-instance
                     'stdio-mcp-transport
                     :process-info process-info
                     :request-stream (uiop:process-info-input process-info)
                     :response-stream (uiop:process-info-output process-info)
                     :stderr-stream (uiop:process-info-error-output process-info)
                     :request-timeout request-timeout)))
    (start-reader-threads transport)
    transport))

(defmethod transport-send-request ((tr stdio-mcp-transport) body)
  (when (stdio-closed-p tr)
    (error 'stdio-mcp-error
           :message "stdio-mcp-transport is closed"))
  (let ((id (%parse-id-from-body body))
        (out (stdio-request-stream tr)))
    (cond
      ((null id)
       ;; Notification: write & forget.
       (write-line body out)
       (force-output out)
       "")
      (t
       (let ((entry (make-%pending-entry)))
         (with-lock-held ((stdio-lock tr))
           (setf (gethash id (stdio-pending tr)) entry))
         (write-line body out)
         (force-output out)
         (with-lock-held ((stdio-lock tr))
           (unless (%pending-done-p entry)
             (condition-wait (%pending-cv entry) (stdio-lock tr)
                             :timeout (stdio-request-timeout tr)))
           (let ((done (%pending-done-p entry))
                 (result (%pending-result entry)))
             (remhash id (stdio-pending tr))
             (cond
               ((eq done :stream-closed)
                (error 'stdio-mcp-error
                       :message (or result "stdio response stream closed")))
               ((null done)
                (error 'stdio-mcp-error
                       :message
                       (format nil
                               "stdio-mcp request id=~A timed out after ~A s"
                               id (stdio-request-timeout tr))))
               (t result)))))))))

(defmethod transport-close ((tr stdio-mcp-transport))
  (unless (stdio-closed-p tr)
    (setf (stdio-closed-p tr) t)
    (let ((proc (stdio-process-info tr)))
      (when proc
        (handler-case (uiop:terminate-process proc :urgent t) (error () nil))
        (handler-case (uiop:wait-process proc) (error () nil))))
    ;; Closing the subprocess lets the reader thread see EOF and exit;
    ;; with injected test streams the caller owns the streams.
    (let ((reader (stdio-reader-thread tr)))
      (when reader
        (handler-case (join-thread reader) (error () nil))))
    (let ((stderr (stdio-stderr-thread tr)))
      (when stderr
        (handler-case (join-thread stderr) (error () nil))))
    ;; Anyone still waiting (possible with injected streams) must be
    ;; woken explicitly so they do not block forever.
    (%wake-all-pending tr "stdio-mcp-transport closed")))

(defun make-stdio-mcp-client (&key command (request-timeout 60)
                                   protocol-version)
  "Convenience: build an MCP-CLIENT against a fresh STDIO-MCP-TRANSPORT."
  (make-mcp-client (make-stdio-mcp-transport
                    :command command
                    :request-timeout request-timeout)
                   :protocol-version (or protocol-version
                                         +mcp-protocol-version+)))
