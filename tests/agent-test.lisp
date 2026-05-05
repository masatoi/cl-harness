;;;; tests/agent-test.lisp
;;;;
;;;; Phase 2 unit tests for the agent loop (PRD §8.4, §11.1, §11.2).
;;;; Both transports (MCP and LLM) are stubbed so the loop is exercised
;;;; end-to-end without touching the network.

(defpackage #:cl-harness/tests/agent-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/config
                #:make-run-config
                #:make-default-limits)
  (:import-from #:cl-harness/src/log
                #:open-run-logger
                #:close-run-logger)
  (:import-from #:cl-harness/src/mcp
                #:make-mcp-client)
  (:import-from #:cl-harness/src/model
                #:make-openai-provider)
  (:import-from #:cl-harness/src/policy
                #:make-tool-policy)
  (:import-from #:cl-harness/src/agent
                #:agent-state
                #:agent-state-status
                #:agent-state-turn
                #:agent-state-patch-count
                #:run-agent))

(in-package #:cl-harness/tests/agent-test)

(defvar *llm-responses*
  nil
  "Bound by each test to a list of canned assistant content strings.")

(defvar *mcp-handler*
  nil
  "Bound by each test to a function (BODY) -> response-body-string.")

(defun %escape-json-string (s)
  "Return S as a JSON-escaped quoted string (e.g. \"foo\" -> \"\\\"foo\\\"\")."
  (with-output-to-string (out) (yason:encode s out)))

(defun %llm-body (content)
  "Wrap CONTENT into an OpenAI-style chat completion response body."
  (format nil
          "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":~A},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
          (%escape-json-string content)))

(defun %llm-transport ()
  (lambda (url headers body)
    (declare (ignore url headers body))
    (let ((content (or (pop *llm-responses*)
                       "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"out of canned LLM responses\"}")))
      (values (%llm-body content) 200 (make-hash-table :test 'equal)))))

(defun %mcp-transport ()
  (lambda (url headers body)
    (declare (ignore url headers))
    (values (funcall *mcp-handler* body) 200 (make-hash-table :test 'equal))))

(defun %jsonrpc-id (body)
  (gethash "id" (yason:parse body)))

(defun %ok-tool-result (id &key (passed nil) (failed nil))
  (with-output-to-string (s)
    (format s
            "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"isError\":false,\"content\":[]"
            id)
    (when passed (format s ",\"passed\":~D" passed))
    (when failed (format s ",\"failed\":~D" failed))
    (format s "}}")))

(defun %make-config ()
  (make-run-config :project-root "/tmp/proj"
                   :system "demo"
                   :test-system "demo/tests"
                   :issue "stub"))

(defun %temp-log-path ()
  (merge-pathnames (format nil "cl-harness-agent-test-~A.jsonl"
                           (get-universal-time))
                   (uiop:temporary-directory)))

(defun %make-mcp-client-with-handler ()
  (make-mcp-client "http://example.test/mcp" :transport (%mcp-transport)))

(defun %make-stub-provider (&key transport)
  (make-openai-provider :base-url "http://example.test/v1"
                        :api-key "k"
                        :model "demo"
                        :temperature 0.0
                        :max-tokens 16
                        :transport (or transport (%llm-transport))))

(defun %run-agent-with-temp-logger (config provider mcp policy)
  (let ((path (%temp-log-path)))
    (unwind-protect
         (let* ((logger (open-run-logger path))
                (state (run-agent config provider mcp policy logger)))
           (close-run-logger logger)
           (values state path))
      (when (probe-file path) (delete-file path)))))

(deftest run-agent-exits-immediately-when-initial-verify-passes
  (let* ((*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body)
                 (%ok-tool-result id))
                ((search "\"load-system\"" body)
                 (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 4 :failed 0))
                ((search "\"pool-kill-worker\"" body)
                 (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider
                    :transport (lambda (u h b)
                                 (declare (ignore u h b))
                                 (error "LLM should not be called when initial verify passes"))))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (typep state 'agent-state))
    (ok (eq :passed (agent-state-status state)))
    (ok (zerop (agent-state-turn state)))))

(deftest run-agent-finishes-passed-after-patch-and-reverify
  (let* ((run-tests-count 0)
         (*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\",\"arguments\":{\"file_path\":\"src/x.lisp\",\"form_type\":\"defun\",\"form_name\":\"f\",\"old_text\":\"a\",\"new_text\":\"b\"},\"thought\":\"replace a with b\"}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body)
                 (%ok-tool-result id))
                ((search "\"load-system\"" body)
                 (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (incf run-tests-count)
                 (if (= run-tests-count 1)
                     (%ok-tool-result id :passed 0 :failed 1)
                     (%ok-tool-result id :passed 4 :failed 0)))
                ((search "\"lisp-patch-form\"" body)
                 (%ok-tool-result id))
                ((search "\"pool-kill-worker\"" body)
                 (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (eq :passed (agent-state-status state)))
    (ok (= 1 (agent-state-patch-count state)))
    (ok (= 1 (agent-state-turn state)))))

(deftest run-agent-downgrades-to-dirty-only-when-clean-verify-fails
  (let* ((run-tests-count 0)
         (*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\",\"arguments\":{\"file_path\":\"src/x.lisp\",\"form_type\":\"defun\",\"form_name\":\"f\",\"old_text\":\"a\",\"new_text\":\"b\"}}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body)
                 (%ok-tool-result id))
                ((search "\"load-system\"" body)
                 (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (incf run-tests-count)
                 (cond
                   ;; 1: initial verify fails so we enter the loop.
                   ((= run-tests-count 1)
                    (%ok-tool-result id :passed 0 :failed 1))
                   ;; 2: incremental reverify after patch passes.
                   ((= run-tests-count 2)
                    (%ok-tool-result id :passed 4 :failed 0))
                   ;; 3: clean reverify on a fresh worker fails — patch
                   ;; relied on volatile REPL state.
                   (t (%ok-tool-result id :passed 0 :failed 1))))
                ((search "\"lisp-patch-form\"" body)
                 (%ok-tool-result id))
                ((search "\"pool-kill-worker\"" body)
                 (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :runtime-native))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (eq :dirty-only (agent-state-status state)))
    (ok (= 1 (agent-state-patch-count state)))))

(deftest run-agent-records-give-up-when-llm-finishes
  (let* ((*llm-responses*
          (list "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"stuck\"}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 3))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (eq :give-up (agent-state-status state)))
    (ok (= 1 (agent-state-turn state)))))

(deftest run-agent-respects-max-turns
  (let* ((*llm-responses*
          ;; Each turn returns a no-op tool_call against a non-mutating tool;
          ;; the harness will call it but never auto-verify, so the loop
          ;; runs until max-turns is hit.
          (loop repeat 25
                collect "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"path\":\"src/x.lisp\"}}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 1))
                ((search "\"lisp-read-file\"" body) (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (limits (make-default-limits))
         (config (make-run-config :project-root "/tmp/proj"
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :issue "x"
                                  :limits limits))
         (state (%run-agent-with-temp-logger config provider mcp policy)))
    (ok (eq :max-turns (agent-state-status state)))))

(deftest run-agent-rejects-disallowed-tool-without-crashing
  (let* ((*llm-responses*
          ;; First turn: try a forbidden tool. Second turn: give up.
          (list "{\"type\":\"tool_call\",\"tool\":\"repl-eval\",\"arguments\":{\"code\":\"(+ 1 2)\"}}"
                "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"denied\"}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 1))
                ((search "\"repl-eval\"" body)
                 (error "agent must never call disallowed tool"))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (eq :give-up (agent-state-status state)))
    (ok (= 2 (agent-state-turn state)))))
