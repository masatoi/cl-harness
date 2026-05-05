;;;; tests/verify-test.lisp
;;;;
;;;; Phase 2 unit tests for the verifier (PRD §8.9 REQ-VERIFY-001).
;;;; Validates both the pure result parser and the MCP-driven
;;;; orchestrator that runs load-system then run-tests via the cl-mcp
;;;; HTTP client.

(defpackage #:cl-harness/tests/verify-test
  (:use #:cl #:rove)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/config
                #:make-run-config)
  (:import-from #:cl-harness/src/mcp
                #:make-mcp-client)
  (:import-from #:cl-harness/src/verify
                #:verify-result
                #:verify-result-status
                #:verify-result-passed
                #:verify-result-failed
                #:verify-result-success-p
                #:verify-result-test
                #:parse-verify-result
                #:verify-task))

(in-package #:cl-harness/tests/verify-test)

(defun %hash (alist) (alist-hash-table alist :test 'equal))

(deftest parse-verify-result-load-error
  (let* ((load (%hash '(("isError" . t)
                        ("content" . #(("type" . "text"))))))
         (r (parse-verify-result load nil)))
    (ok (typep r 'verify-result))
    (ok (eq :load-failed (verify-result-status r)))
    (ok (not (verify-result-success-p r)))))

(deftest parse-verify-result-tests-pass
  (let* ((load (%hash '(("isError" . :false))))
         (test (%hash '(("isError" . :false)
                        ("passed" . 5)
                        ("failed" . 0))))
         (r (parse-verify-result load test)))
    (ok (eq :passed (verify-result-status r)))
    (ok (verify-result-success-p r))
    (ok (= 5 (verify-result-passed r)))
    (ok (= 0 (verify-result-failed r)))))

(deftest parse-verify-result-tests-fail
  (let* ((load (%hash '(("isError" . :false))))
         (test (%hash '(("isError" . :false)
                        ("passed" . 3)
                        ("failed" . 2))))
         (r (parse-verify-result load test)))
    (ok (eq :test-failed (verify-result-status r)))
    (ok (not (verify-result-success-p r)))
    (ok (= 3 (verify-result-passed r)))
    (ok (= 2 (verify-result-failed r)))))

(deftest parse-verify-result-missing-counts-treated-as-failure
  (let* ((load (%hash '(("isError" . :false))))
         (test (%hash '(("isError" . :false))))
         (r (parse-verify-result load test)))
    (ok (eq :test-failed (verify-result-status r)))))

(defun %canned-mcp-responder (body
                              &key load-error
                                   (passed 4) (failed 0))
  (cond
    ((search "\"load-system\"" body)
     (values
      (format nil "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"isError\":~A}}"
              (if load-error "true" "false"))
      200 (make-hash-table :test 'equal)))
    ((search "\"run-tests\"" body)
     (values
      (format nil "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"isError\":false,\"passed\":~D,\"failed\":~D}}"
              passed failed)
      200 (make-hash-table :test 'equal)))
    ((search "\"initialize\"" body)
     (values
      "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"t\",\"version\":\"0\"},\"capabilities\":{}}}"
      200
      (%hash '(("mcp-session-id" . "test-session")))))
    ((search "\"notifications/initialized\"" body)
     (values "" 202 (make-hash-table :test 'equal)))
    (t (error "unexpected request body: ~A" body))))

(deftest verify-task-runs-load-then-tests-on-mcp
  (let* ((capture (cons nil nil))
         (transport (lambda (url headers body)
                      (declare (ignore url headers))
                      (push body (car capture))
                      (%canned-mcp-responder body :passed 7 :failed 0)))
         (client (make-mcp-client "http://example.test/mcp" :transport transport))
         (config (make-run-config :project-root "/p"
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :issue "x"))
         (r (verify-task client config)))
    (testing "verify-task returns a populated verify-result"
      (ok (typep r 'verify-result))
      (ok (eq :passed (verify-result-status r)))
      (ok (= 7 (verify-result-passed r))))
    (testing "load-system was invoked before run-tests"
      (let* ((bodies (reverse (car capture)))
             (load-pos (position-if (lambda (b) (search "\"load-system\"" b))
                                    bodies))
             (test-pos (position-if (lambda (b) (search "\"run-tests\"" b))
                                    bodies)))
        (ok (and load-pos test-pos (< load-pos test-pos)))))
    (testing "load-system request carries the run-config :system name"
      (let* ((bodies (reverse (car capture)))
             (load-body (find-if (lambda (b) (search "\"load-system\"" b))
                                 bodies))
             (params (gethash "params" (yason:parse load-body)))
             (args (gethash "arguments" params)))
        (ok (equal "demo" (gethash "system" args)))))
    (testing "run-tests request carries the run-config :test-system"
      (let* ((bodies (reverse (car capture)))
             (test-body (find-if (lambda (b) (search "\"run-tests\"" b))
                                 bodies))
             (params (gethash "params" (yason:parse test-body)))
             (args (gethash "arguments" params)))
        (ok (equal "demo/tests" (gethash "system" args)))))))

(deftest verify-task-skips-run-tests-on-load-failure
  (let* ((seen-test-call (cons nil nil))
         (transport (lambda (url headers body)
                      (declare (ignore url headers))
                      (when (search "\"run-tests\"" body)
                        (setf (car seen-test-call) t))
                      (%canned-mcp-responder body :load-error t)))
         (client (make-mcp-client "http://example.test/mcp" :transport transport))
         (config (make-run-config :project-root "/p"
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :issue "x"))
         (r (verify-task client config)))
    (ok (eq :load-failed (verify-result-status r)))
    (ok (not (verify-result-success-p r)))
    (ok (null (car seen-test-call)))
    (ok (null (verify-result-test r)))))
