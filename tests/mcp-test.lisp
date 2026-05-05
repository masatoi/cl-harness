;;;; tests/mcp-test.lisp
;;;;
;;;; Phase 1 unit tests for the cl-mcp HTTP client (PRD §8.3, §10.2, §10.3).
;;;; Pure logic (request builder, response parser) plus integration-style
;;;; tests that inject a stub transport so we can exercise the JSON-RPC
;;;; lifecycle without hitting the network.
;;;;
;;;; A live cl-mcp HTTP transport probe is gated behind the
;;;; CL_HARNESS_INTEGRATION environment variable.

(defpackage #:cl-harness/tests/mcp-test
  (:use #:cl #:rove)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/mcp
                #:mcp-client
                #:make-mcp-client
                #:mcp-client-url
                #:mcp-client-session-id
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message
                #:mcp-build-request
                #:mcp-build-notification
                #:mcp-parse-response
                #:initialize-mcp
                #:list-tools
                #:call-tool))

(in-package #:cl-harness/tests/mcp-test)

(defun %hash (alist)
  (alist-hash-table alist :test 'equal))

(deftest mcp-build-request-encodes-jsonrpc-call
  (testing "minimal jsonrpc 2.0 envelope"
    (let* ((s (mcp-build-request 7 "tools/list"))
           (parsed (yason:parse s)))
      (ok (equal "2.0" (gethash "jsonrpc" parsed)))
      (ok (= 7 (gethash "id" parsed)))
      (ok (equal "tools/list" (gethash "method" parsed)))
      (multiple-value-bind (val present) (gethash "params" parsed)
        (declare (ignore val))
        (ok (not present)))))
  (testing "embeds nested params hash-table"
    (let* ((args (%hash '(("a" . 1))))
           (params (%hash `(("name" . "foo") ("arguments" . ,args))))
           (parsed (yason:parse (mcp-build-request 9 "tools/call" :params params))))
      (ok (equal "tools/call" (gethash "method" parsed)))
      (ok (equal "foo" (gethash "name" (gethash "params" parsed))))
      (ok (= 1 (gethash "a"
                        (gethash "arguments" (gethash "params" parsed))))))))

(deftest mcp-build-notification-omits-id
  (let* ((s (mcp-build-notification "notifications/initialized"))
         (parsed (yason:parse s)))
    (ok (equal "2.0" (gethash "jsonrpc" parsed)))
    (ok (equal "notifications/initialized" (gethash "method" parsed)))
    (multiple-value-bind (val present) (gethash "id" parsed)
      (declare (ignore val))
      (ok (not present)))))

(deftest mcp-parse-response-success-and-error
  (testing "happy path returns parsed result"
    (let ((result (mcp-parse-response
                   "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[{\"name\":\"a\"}]}}")))
      (let ((tools (gethash "tools" result)))
        (ok (= 1 (length tools)))
        (ok (equal "a" (gethash "name" (elt tools 0)))))))
  (testing "error envelope signals mcp-error with code and message"
    (ok (handler-case
            (progn
              (mcp-parse-response
               "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"oops\"}}")
              nil)
          (mcp-error (c)
            (and (= -32601 (mcp-error-code c))
                 (equal "oops" (mcp-error-message c))))))))

(defun %make-recording-transport (responder)
  "Return (values TRANSPORT CAPTURE) where TRANSPORT is a function suitable for
:TRANSPORT and CAPTURE is a list (latest-first) of plists describing each call.
RESPONDER receives the request body and returns (values BODY STATUS HEADERS)."
  (let ((capture (list)))
    (values
     (lambda (url headers body)
       (push (list :url url :headers headers :body body) capture)
       (funcall responder body))
     capture)))

(defun %canned-responder (body)
  (cond
    ((search "\"initialize\"" body)
     (values
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"test\",\"version\":\"0\"},\"capabilities\":{}}}"
      200
      (%hash '(("content-type" . "application/json")
               ("mcp-session-id" . "fake-session-xyz")))))
    ((search "\"notifications/initialized\"" body)
     (values "" 202 (make-hash-table :test 'equal)))
    ((search "\"tools/list\"" body)
     (values
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"alpha\"},{\"name\":\"beta\"}]}}"
      200
      (make-hash-table :test 'equal)))
    ((search "\"tools/call\"" body)
     (values
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}"
      200
      (make-hash-table :test 'equal)))
    (t (error "unexpected request body: ~A" body))))

(deftest mcp-client-lifecycle-with-stub-transport
  (let* ((capture (cons nil nil))                     ; box so closure can mutate
         (transport (lambda (url headers body)
                      (push (list :url url :headers headers :body body)
                            (car capture))
                      (%canned-responder body)))
         (c (make-mcp-client "http://example.test/mcp" :transport transport)))
    (testing "client construction stores url"
      (ok (typep c 'mcp-client))
      (ok (equal "http://example.test/mcp" (mcp-client-url c)))
      (ok (null (mcp-client-session-id c))))
    (testing "initialize captures session-id and sends initialized notification"
      (initialize-mcp c :client-name "test" :client-version "0")
      (ok (equal "fake-session-xyz" (mcp-client-session-id c)))
      (ok (find-if (lambda (e)
                     (search "notifications/initialized" (getf e :body)))
                   (car capture))))
    (testing "list-tools returns the parsed tool array"
      (let ((tools (list-tools c)))
        (ok (= 2 (length tools)))
        (ok (equal "alpha" (gethash "name" (elt tools 0))))
        (ok (equal "beta" (gethash "name" (elt tools 1))))))
    (testing "subsequent calls forward the captured Mcp-Session-Id header"
      (let* ((req (find-if (lambda (e) (search "tools/list" (getf e :body)))
                           (car capture)))
             (hdrs (getf req :headers)))
        (ok (equal "fake-session-xyz" (gethash "Mcp-Session-Id" hdrs)))))
    (testing "call-tool serializes name and arguments under params"
      (let* ((args (%hash '(("x" . 42))))
             (result (call-tool c "alpha" args)))
        (ok (equal "hello"
                   (gethash "text" (elt (gethash "content" result) 0))))
        (let* ((req (find-if (lambda (e) (search "tools/call" (getf e :body)))
                             (car capture)))
               (parsed (yason:parse (getf req :body)))
               (params (gethash "params" parsed)))
          (ok (equal "alpha" (gethash "name" params)))
          (ok (= 42 (gethash "x" (gethash "arguments" params)))))))))

(deftest mcp-live-transport-roundtrip
  (testing "live cl-mcp HTTP probe (CL_HARNESS_INTEGRATION=1)"
    (if (uiop:getenv "CL_HARNESS_INTEGRATION")
        (let ((c (make-mcp-client "http://127.0.0.1:3001/mcp")))
          (initialize-mcp c :client-name "cl-harness-tests" :client-version "0")
          (ok (stringp (mcp-client-session-id c)))
          (let ((tools (list-tools c)))
            (ok (plusp (length tools)))
            (ok (find "fs-read-file" (coerce tools 'list)
                      :key (lambda (h) (gethash "name" h))
                      :test #'equal))))
        (skip "set CL_HARNESS_INTEGRATION=1 to enable"))))
