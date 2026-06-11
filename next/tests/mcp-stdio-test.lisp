;;;; next/tests/mcp-stdio-test.lisp
;;;;
;;;; Tests for next/src/mcp-stdio.lisp. Spawning a real cl-mcp
;;;; subprocess is gated on CL_HARNESS_INTEGRATION=1; everything else
;;;; drives the transport through injected in-memory streams plus
;;;; %ROUTE-RESPONSE-LINE so routing/lifecycle logic is exercised
;;;; without needing ros/cl-mcp at test time (legacy-proven pattern).

(defpackage #:cl-harness-next/tests/mcp-stdio-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:transport-send-request
                #:transport-close
                #:initialize-mcp
                #:list-tools
                #:close-mcp-client)
  (:import-from #:cl-harness-next/src/mcp-stdio
                #:stdio-mcp-transport
                #:make-stdio-mcp-client
                #:stdio-mcp-error
                #:stdio-request-stream
                #:%route-response-line))

(in-package #:cl-harness-next/tests/mcp-stdio-test)

(defun %make-test-transport (&key (timeout 2))
  "STDIO-MCP-TRANSPORT bound to harmless in-memory streams. The reader
thread is NOT started; tests deliver responses via %ROUTE-RESPONSE-LINE
directly, so delivery runs under controlled timing without a live
subprocess."
  (make-instance 'stdio-mcp-transport
                 :request-stream (make-string-output-stream)
                 :response-stream (make-string-input-stream "")
                 :request-timeout timeout))

(deftest routes-response-by-id
  (let* ((transport (%make-test-transport))
         (out (cons nil nil))
         (sender (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (setf (car out)
                              (transport-send-request
                               transport
                               "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"foo\",\"params\":{}}"))
                      (error (c) (setf (cdr out) c))))
                  :name "stdio-test-sender")))
    (sleep 0.1)
    (%route-response-line
     transport "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"value\":42}}")
    (bordeaux-threads:join-thread sender)
    (ok (null (cdr out)))
    (ok (search "\"value\":42" (car out)))))

(deftest request-times-out
  (let ((transport (%make-test-transport :timeout 1))
        (outcome nil))
    (let ((sender (bordeaux-threads:make-thread
                   (lambda ()
                     (handler-case
                         (progn (transport-send-request
                                 transport
                                 "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}")
                                (setf outcome :returned))
                       (stdio-mcp-error () (setf outcome :timeout)))))))
      (bordeaux-threads:join-thread sender)
      (ok (eq :timeout outcome)))))

(deftest notification-writes-and-returns-empty
  (let ((transport (%make-test-transport)))
    (ok (equal "" (transport-send-request
                   transport
                   "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))
    (ok (search "notifications/initialized"
                (get-output-stream-string
                 (stdio-request-stream transport))))))

(deftest closed-transport-rejects-send
  (let ((transport (%make-test-transport)))
    (transport-close transport)
    (ok (handler-case
            (progn (transport-send-request
                    transport "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"x\"}")
                   nil)
          (stdio-mcp-error () t)))))

(deftest close-wakes-blocked-sender
  (let* ((transport (%make-test-transport :timeout 30))
         (outcome nil)
         (sender (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (progn (transport-send-request
                                transport
                                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"x\"}")
                               (setf outcome :returned))
                      (stdio-mcp-error () (setf outcome :error)))))))
    (sleep 0.1)
    (transport-close transport)
    (bordeaux-threads:join-thread sender)
    (ok (eq :error outcome))))

(deftest stdio-error-prints-without-initargs
  (ok (stringp (princ-to-string (make-condition 'stdio-mcp-error)))))

(deftest stdio-integration-against-real-cl-mcp
  (if (equal "1" (uiop:getenv "CL_HARNESS_INTEGRATION"))
      (let ((client (make-stdio-mcp-client :request-timeout 120)))
        (unwind-protect
             (progn
               (initialize-mcp client)
               (ok (plusp (length (coerce (list-tools client) 'list)))))
          (close-mcp-client client)))
      (ok t "skipped real-subprocess test (set CL_HARNESS_INTEGRATION=1)")))
