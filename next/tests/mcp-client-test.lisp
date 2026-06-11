;;;; next/tests/mcp-client-test.lisp
;;;;
;;;; Unit tests for next/src/mcp-client.lisp: JSON-RPC wire format,
;;;; error envelope decoding, client construction. Transport mechanics
;;;; are covered in mcp-stdio-test; the handshake/list/call flow is
;;;; covered end-to-end in environment-test via a scripted transport.

(defpackage #:cl-harness-next/tests/mcp-client-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-build-request
                #:mcp-build-notification
                #:mcp-parse-response
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message
                #:mcp-transport
                #:mcp-client
                #:make-mcp-client))

(in-package #:cl-harness-next/tests/mcp-client-test)

(deftest build-request-shape
  (let ((parsed (yason:parse
                 (mcp-build-request 7 "tools/call"
                                    :params (alexandria:plist-hash-table
                                             (list "name" "run-tests")
                                             :test #'equal)))))
    (ok (equal "2.0" (gethash "jsonrpc" parsed)))
    (ok (= 7 (gethash "id" parsed)))
    (ok (equal "tools/call" (gethash "method" parsed)))
    (ok (equal "run-tests" (gethash "name" (gethash "params" parsed))))))

(deftest build-notification-has-no-id
  (let ((parsed (yason:parse
                 (mcp-build-notification "notifications/initialized"))))
    (ok (equal "2.0" (gethash "jsonrpc" parsed)))
    (ok (null (gethash "id" parsed)))
    (ok (equal "notifications/initialized" (gethash "method" parsed)))))

(deftest parse-response-returns-result
  (let ((result (mcp-parse-response
                 "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":42}}")))
    (ok (= 42 (gethash "value" result)))))

(deftest parse-response-signals-mcp-error
  (ok (handler-case
          (progn (mcp-parse-response
                  (concatenate 'string
                               "{\"jsonrpc\":\"2.0\",\"id\":1,"
                               "\"error\":{\"code\":-32000,\"message\":\"boom\"}}"))
                 nil)
        (mcp-error (e)
          (and (= -32000 (mcp-error-code e))
               (equal "boom" (mcp-error-message e)))))))

(deftest mcp-error-prints-without-initargs
  (ok (stringp (princ-to-string (make-condition 'mcp-error)))))

(deftest make-mcp-client-requires-transport
  (ok (handler-case (progn (make-mcp-client 42) nil)
        (error () t)))
  (ok (typep (make-mcp-client (make-instance 'mcp-transport)) 'mcp-client)))
