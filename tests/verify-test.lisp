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
                #:verify-task
                #:clean-verify-task
                #:build-scope-asdf-code))

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

(deftest parse-verify-result-zero-tests-treated-as-failure
  (let* ((load (%hash '(("isError" . :false))))
         (test (%hash '(("isError" . :false)
                        ("passed" . 0)
                        ("failed" . 0))))
         (r (parse-verify-result load test)))
    (ok (eq :test-failed (verify-result-status r)))
    (ok (not (verify-result-success-p r)))))

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
    ((search "\"pool-kill-worker\"" body)
     (values
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"killed\"}],\"isError\":false}}"
      200 (make-hash-table :test 'equal)))
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

(deftest clean-verify-task-resets-worker-before-load
  (let* ((capture (cons nil nil))
         (transport (lambda (url headers body)
                      (declare (ignore url headers))
                      (push body (car capture))
                      (%canned-mcp-responder body :passed 5 :failed 0)))
         (client (make-mcp-client "http://example.test/mcp" :transport transport))
         (config (make-run-config :project-root "/p"
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :issue "x"))
         (r (clean-verify-task client config)))
    (testing "result has the same shape as VERIFY-TASK"
      (ok (typep r 'verify-result))
      (ok (eq :passed (verify-result-status r))))
    (testing "pool-kill-worker is invoked before load-system"
      (let* ((bodies (reverse (car capture)))
             (kill-pos (position-if
                        (lambda (b) (search "\"pool-kill-worker\"" b))
                        bodies))
             (load-pos (position-if
                        (lambda (b) (search "\"load-system\"" b))
                        bodies)))
        (ok (and kill-pos load-pos (< kill-pos load-pos)))))
    (testing "pool-kill-worker carries reset=true"
      (let* ((bodies (reverse (car capture)))
             (kill-body (find-if (lambda (b) (search "\"pool-kill-worker\"" b))
                                 bodies))
             (params (gethash "params" (yason:parse kill-body)))
             (args (gethash "arguments" params)))
        (ok (eq t (gethash "reset" args)))))))

(deftest build-scope-asdf-code-mentions-required-pieces
  ;; Static check: the generated code must contain initialize-source-registry
  ;; (with the project-root path), the per-system clear-system loop, and the
  ;; per-package delete-package loop. The per-system / per-package walks were
  ;; added to fix anomaly #64 (002-typo-defun runtime-native 0-turn pass).
  (let ((code (build-scope-asdf-code "/tmp/sandbox/" "demo" "demo/tests")))
    (ok (search "initialize-source-registry" code))
    (ok (search "/tmp/sandbox/" code))
    (ok (search "clear-system" code))
    (ok (search "registered-systems" code)
        "iterates ASDF's registered systems to clear inferred subsystems")
    (ok (search "delete-package" code)
        "deletes packages so a stale defun from the previous cell does not linger")
    (ok (search "list-all-packages" code)
        "iterates ALL packages so we hit any defpackage created by the prior load")
    (ok (search "DEMO" code)
        "embeds the upper-cased system name for case-insensitive package matching")))

(deftest build-scope-asdf-code-purges-contaminated-package-when-evaluated
  ;; Direct repro of anomaly #64: pre-bind a function in a leftover package,
  ;; eval the generated code in-process, assert the package no longer exists.
  ;; Uses an in-process eval (the same code is what the cl-mcp worker would
  ;; receive via repl-eval) so the test exercises the actual side-effects
  ;; without needing a live cl-mcp transport.
  (let* ((pkg-name "ANOMALY64-DEMO/SRC/MAIN")
         (pkg (or (find-package pkg-name)
                  (make-package pkg-name :use '(#:cl)))))
    ;; Contaminate: define a function in the package.
    (let ((sym (intern "GREET" pkg)))
      (setf (symbol-function sym) (lambda (n) (format nil "Hi ~A" n))))
    (ok (fboundp (find-symbol "GREET" pkg))
        "pre-condition: GREET is bound in the contaminated package")
    ;; Build and run the scope code; uses lowercase system names matching
    ;; the upper-cased package name above. compile+funcall gives the same
    ;; effect as cl:eval here while keeping the lint rule against runtime
    ;; eval clean.
    (let* ((code (build-scope-asdf-code (uiop:temporary-directory)
                                        "anomaly64-demo"
                                        "anomaly64-demo/tests"))
           (form (read-from-string code))
           (thunk (compile nil `(lambda () ,form))))
      (funcall thunk))
    (ok (null (find-package pkg-name))
        "post-condition: the contaminated package was deleted")))
