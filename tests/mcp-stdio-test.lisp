;;;; tests/mcp-stdio-test.lisp
;;;;
;;;; Phase B coverage for the stdio MCP transport
;;;; (docs/notes/2026-05-06-stdio-transport.md). Spawning a real cl-mcp
;;;; subprocess is gated on CL_HARNESS_INTEGRATION=1; the rest of the
;;;; cases drive the transport through manually-injected streams plus
;;;; %ROUTE-RESPONSE-LINE so the routing / lifecycle logic is exercised
;;;; without needing ros / cl-mcp installed at test time.

(defpackage #:cl-harness/tests/mcp-stdio-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/mcp
                #:transport-send-request
                #:transport-close
                #:initialize-mcp
                #:list-tools
                #:close-mcp-client)
  (:import-from #:cl-harness/src/mcp-stdio
                #:stdio-mcp-transport
                #:make-stdio-mcp-client
                #:stdio-mcp-error
                #:stdio-mcp-error-message
                #:%route-response-line))

(in-package #:cl-harness/tests/mcp-stdio-test)

(defun %make-test-transport (&key (timeout 2))
  "Return a STDIO-MCP-TRANSPORT bound to harmless in-memory streams.
The reader thread is NOT started; tests drive %ROUTE-RESPONSE-LINE
directly so the response delivery path is exercised under controlled
timing without needing a live subprocess."
  (make-instance 'stdio-mcp-transport
                 :request-stream (make-string-output-stream)
                 :response-stream (make-string-input-stream "")
                 :request-timeout timeout))

(deftest stdio-transport-routes-response-by-id
  ;; transport-send-request must block on a pending request id and
  ;; return the matching response line as soon as %route-response-line
  ;; delivers it. The sender runs on a worker thread so the test
  ;; (acting as the would-be reader) can deliver the response with
  ;; deterministic ordering.
  (let* ((tr (%make-test-transport))
         (out (cons nil nil))
         (sender (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (setf (car out)
                              (transport-send-request
                               tr
                               "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"foo\",\"params\":{}}"))
                      (error (c) (setf (cdr out) c))))
                  :name "stdio-test-sender")))
    ;; Give the sender a chance to register the pending entry and
    ;; settle on the condition-variable wait.
    (sleep 0.1)
    (%route-response-line
     tr
     "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"value\":42}}")
    (bordeaux-threads:join-thread sender)
    (ok (null (cdr out)) "transport-send-request did not error")
    (let* ((resp (car out))
           (parsed (yason:parse resp)))
      (ok (= 7 (gethash "id" parsed)))
      (ok (= 42 (gethash "value" (gethash "result" parsed)))))))

(deftest stdio-transport-notification-fire-and-forget
  ;; A JSON-RPC notification has no "id"; transport-send-request must
  ;; write the line and return "" immediately, never blocking on a
  ;; response. The request stream should carry exactly the bytes we
  ;; sent.
  (let* ((tr (%make-test-transport))
         (resp (transport-send-request
                tr
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))
    (ok (equal "" resp))
    (let ((written (get-output-stream-string
                    (cl-harness/src/mcp-stdio::stdio-request-stream tr))))
      (ok (search "notifications/initialized" written)))))

(deftest stdio-transport-close-wakes-pending-waiter
  ;; If the transport is closed while a request is pending, the waiter
  ;; must unblock with a stdio-mcp-error rather than hanging forever.
  (let* ((tr (%make-test-transport :timeout 5))
         (out (cons nil nil))
         (sender (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (setf (car out)
                              (transport-send-request
                               tr
                               "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"foo\"}"))
                      (stdio-mcp-error (c) (setf (cdr out) c))))
                  :name "stdio-test-close-sender")))
    (sleep 0.1)
    (transport-close tr)
    (bordeaux-threads:join-thread sender)
    (ok (typep (cdr out) 'stdio-mcp-error)
        "pending sender saw stdio-mcp-error after close")
    (ok (search "closed" (stdio-mcp-error-message (cdr out))))))

(deftest stdio-transport-close-is-idempotent
  (let ((tr (%make-test-transport)))
    (transport-close tr)
    (ok (cl-harness/src/mcp-stdio::stdio-closed-p tr))
    (transport-close tr)
    (ok (cl-harness/src/mcp-stdio::stdio-closed-p tr))))

(deftest stdio-transport-live-roundtrip
  ;; Live integration probe: spawn cl-mcp via ros, drive an
  ;; initialize + tools/list cycle, expect a non-empty tool list.
  (testing "live cl-mcp stdio probe (CL_HARNESS_INTEGRATION=1)"
    (if (uiop:getenv "CL_HARNESS_INTEGRATION")
        (let ((c (make-stdio-mcp-client)))
          (unwind-protect
               (progn
                 (initialize-mcp c
                                 :client-name "cl-harness-tests"
                                 :client-version "0")
                 (let ((tools (list-tools c)))
                   (ok (plusp (length tools)))
                   (ok (find "fs-read-file" (coerce tools 'list)
                             :key (lambda (h) (gethash "name" h))
                             :test #'equal))))
            (close-mcp-client c)))
        (skip "set CL_HARNESS_INTEGRATION=1 to enable"))))
