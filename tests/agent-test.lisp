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
                #:agent-state-develop-state
                #:run-agent
                #:summarize-tool-result)
  (:import-from #:cl-harness/src/state
                #:make-develop-state
                #:develop-state-patch-records)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-path
                #:patch-record-via-tool
                #:patch-record-verify-status))

(in-package #:cl-harness/tests/agent-test)

(defvar *llm-responses*
  nil
  "Bound by each test to a list of canned assistant content strings.")

(defvar *mcp-handler*
  nil
  "Bound by each test to a function (BODY) -> response-body-string.")

(defvar *mcp-isolation-tap*
  nil
  "Optional fn (BODY) called when an isolation request is short-circuited
by the transport. Lets a test observe pool-kill-worker / repl-eval init
scoping bodies without forcing every test handler to special-case them.")

(defun %escape-json-string (s)
  "Return S as a JSON-escaped quoted string (e.g. \"foo\" -> \"\\\"foo\\\"\")."
  (with-output-to-string (out) (yason:encode s out)))

(defun %llm-body (content)
  "Wrap CONTENT into an OpenAI-style chat completion response body."
  (format nil
          "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":~A},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
          (%escape-json-string content)))

(defun %isolation-body-p (body)
  "T when BODY is one of the harness-internal calls run-agent emits when
ISOLATE-ASDF-P is true: the pool-kill-worker reset and the
repl-eval that runs asdf:initialize-source-registry on the new worker.
Tests bypass the per-test *mcp-handler* for these so existing handlers
do not have to special-case them."
  (or (search "\"pool-kill-worker\"" body)
      (and (search "\"repl-eval\"" body)
           (search "initialize-source-registry" body))))

(defun %llm-transport ()
  (lambda (url headers body)
    (declare (ignore url headers body))
    (let ((content (or (pop *llm-responses*)
                       "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"out of canned LLM responses\"}")))
      (values (%llm-body content) 200 (make-hash-table :test 'equal)))))

(defun %mcp-transport ()
  (lambda (url headers body)
    (declare (ignore url headers))
    (cond
      ((%isolation-body-p body)
       (when *mcp-isolation-tap* (funcall *mcp-isolation-tap* body))
       (values (%ok-tool-result (%jsonrpc-id body))
               200
               (make-hash-table :test 'equal)))
      (t
       (values (funcall *mcp-handler* body)
               200
               (make-hash-table :test 'equal))))))

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

(defun %error-tool-result (id text)
  "Build a JSON-RPC response that mirrors how cl-mcp signals a
tool-level error: isError=true with a single content[].text item
carrying the human-readable diagnostic. Used by tests that need to
exercise the JSONL `error_text' field."
  (format nil
          "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":~A}]}}"
          id (with-output-to-string (s) (yason:encode text s))))

(defun %read-jsonl-events (path)
  "Read every line from PATH and return the parsed YASON objects in file
order. Helper for tests that assert against the on-disk transcript."
  (with-open-file (in path :direction :input)
    (loop for line = (read-line in nil nil)
          while line
          collect (yason:parse line))))

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

(deftest run-agent-feeds-failed-tests-detail-on-reverify-failure
  (let* ((run-tests-count 0)
         (llm-bodies (list))
         (*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\",\"arguments\":{\"file_path\":\"src/x.lisp\",\"form_type\":\"defun\",\"form_name\":\"f\",\"old_text\":\"a\",\"new_text\":\"b\"}}"
                "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"giving up\"}"))
         (llm-transport
          (lambda (url headers body)
            (declare (ignore url headers))
            (push body llm-bodies)
            (let ((content (or (pop *llm-responses*)
                               "{\"type\":\"finish\",\"status\":\"give_up\"}")))
              (values (%llm-body content) 200
                      (make-hash-table :test 'equal)))))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (incf run-tests-count)
                 (cond
                   ((= run-tests-count 1)
                    ;; Initial verify: just summary, no failed_tests.
                    (%ok-tool-result id :passed 0 :failed 1))
                   (t
                    ;; Reverify after patch: include failed_tests array.
                    (format nil
                            "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"isError\":false,\"content\":[],\"passed\":0,\"failed\":1,\"failed_tests\":[{\"test_name\":\"sample-test\",\"description\":\"f should return 2\",\"reason\":\"got 3 instead\",\"form\":\"(= (f) 2)\"}]}}"
                            id))))
                ((search "\"lisp-patch-form\"" body) (%ok-tool-result id))
                ((search "\"pool-kill-worker\"" body) (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider :transport llm-transport))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (eq :give-up (agent-state-status state)))
    (let* ((second-call-body (second (reverse llm-bodies)))
           (parsed (yason:parse second-call-body))
           (messages (gethash "messages" parsed))
           (msg-list (coerce messages 'list))
           (last-user (find-if (lambda (m) (equal "user" (gethash "role" m)))
                               (reverse msg-list)))
           (content (and last-user (gethash "content" last-user))))
      (ok (stringp content))
      (ok (search "Verify after patch:" content))
      (ok (search "Failing tests:" content))
      (ok (search "sample-test" content))
      (ok (search "got 3 instead" content)))))

(deftest summarize-tool-result-run-tests-includes-failed-tests
  (let* ((failed (vector
                  (alexandria:alist-hash-table
                   '(("test_name" . "t1")
                     ("description" . "x should be 2")
                     ("reason" . "got 3")
                     ("form" . "(= (f) 2)"))
                   :test 'equal)))
         (result (alexandria:alist-hash-table
                  `(("isError" . nil)
                    ("passed" . 0)
                    ("failed" . 1)
                    ("failed_tests" . ,failed))
                  :test 'equal))
         (s (summarize-tool-result "run-tests" result)))
    (ok (search "passed: 0" s))
    (ok (search "failed: 1" s))
    (ok (search "t1" s))
    (ok (search "got 3" s))))

(deftest summarize-tool-result-repl-eval-extracts-content-and-error
  (let* ((content (vector (alexandria:alist-hash-table
                           '(("type" . "text") ("text" . "=> 42"))
                           :test 'equal)))
         (err (alexandria:alist-hash-table
               '(("condition_type" . "TYPE-ERROR")
                 ("message" . "expected number got string"))
               :test 'equal))
         (result (alexandria:alist-hash-table
                  `(("isError" . nil)
                    ("content" . ,content)
                    ("error_context" . ,err))
                  :test 'equal))
         (s (summarize-tool-result "repl-eval" result)))
    (ok (search "=> 42" s))
    (ok (search "TYPE-ERROR" s))
    (ok (search "expected number got string" s))))

(deftest summarize-tool-result-probe-tools-extract-content-text
  (let* ((content (vector (alexandria:alist-hash-table
                           '(("type" . "text")
                             ("text" . "(defun foo (x) ...)"))
                           :test 'equal)))
         (result (alexandria:alist-hash-table
                  `(("isError" . nil) ("content" . ,content))
                  :test 'equal)))
    (dolist (tool '("code-find" "code-describe" "code-find-references"
                    "inspect-object" "lisp-read-file" "clgrep-search"))
      (let ((s (summarize-tool-result tool result)))
        (ok (search "(defun foo (x) ...)" s))))))

(deftest summarize-tool-result-default-marks-error-flag
  (let* ((content (vector (alexandria:alist-hash-table
                           '(("type" . "text") ("text" . "boom"))
                           :test 'equal)))
         (result (alexandria:alist-hash-table
                  `(("isError" . t) ("content" . ,content))
                  :test 'equal))
         (s (summarize-tool-result "lisp-patch-form" result)))
    (ok (search "ERROR" s))
    (ok (search "boom" s))))

(deftest summarize-tool-by-key-is-extensible-via-defmethod
  ;; Tier 4 C-2: external code (or future cl-harness extensions) can
  ;; register a custom summarizer for a new MCP tool by defining an
  ;; eql-keyword method on summarize-tool-by-key. Verify the dispatch
  ;; reaches the new method without any change to summarize-tool-result.
  ;; defmethod on the same specializers is idempotent, so re-running
  ;; the suite just rebinds the same method.
  (defmethod cl-harness/src/agent:summarize-tool-by-key
      ((tool-key (eql :extensibility-probe-tool)) result)
    (declare (ignore result))
    "extensibility-probe-tool: hello from a third-party method")
  (let ((result (alexandria:alist-hash-table
                 '(("isError" . nil) ("content" . #()))
                 :test 'equal)))
    (let ((s (summarize-tool-result "extensibility-probe-tool" result)))
      (ok (search "third-party method" s)
          "the eql-method got dispatched"))))

(deftest summarize-load-failure-finds-marker-line
  (testing "first matching marker line wins"
    (let ((text (format nil "Compiling foo~%no symbol named \"BAR\" in \"PKG\"~%more output~%")))
      (let ((s (cl-harness/src/agent::summarize-load-failure text)))
        (ok (search "no symbol named" s))
        (ok (search "BAR" s)))))
  (testing "returns NIL when no marker matches"
    (ok (null (cl-harness/src/agent::summarize-load-failure
               "ordinary build output without any error"))))
  (testing "tolerates empty / non-string input"
    (ok (null (cl-harness/src/agent::summarize-load-failure "")))
    (ok (null (cl-harness/src/agent::summarize-load-failure nil)))))

(deftest compute-unified-diff-roundtrip
  (testing "differs => returns a diff with both old and new lines"
    (let ((d (cl-harness/src/agent::%compute-unified-diff
              (format nil "(defun add (x y) (- x y))~%")
              (format nil "(defun add (x y) (+ x y))~%")
              "src/add.lisp")))
      (ok (stringp d))
      (ok (search "(- x y)" d))
      (ok (search "(+ x y)" d))
      (ok (search "src/add.lisp" d))))
  (testing "identical input returns NIL (no spurious patch event)"
    (ok (null (cl-harness/src/agent::%compute-unified-diff
               "same" "same" "src/x.lisp"))))
  (testing "non-string input returns NIL"
    (ok (null (cl-harness/src/agent::%compute-unified-diff
               nil "after" "src/x.lisp")))
    (ok (null (cl-harness/src/agent::%compute-unified-diff
               "before" nil "src/x.lisp")))))

(deftest run-agent-survives-mcp-error-and-feeds-it-back
  (let* ((*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"name_pattern\":\"add\"}}"
                "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"out of ideas\"}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 1))
                ((search "\"lisp-read-file\"" body)
                 (format nil
                         "{\"jsonrpc\":\"2.0\",\"id\":~A,\"error\":{\"code\":-32602,\"message\":\"path is required\"}}"
                         id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (testing "agent does not crash on a JSON-RPC error response"
      (ok (eq :give-up (cl-harness/src/agent:agent-state-status state)))
      (ok (= 2 (cl-harness/src/agent:agent-state-turn state))))))

(deftest run-agent-skips-auto-reverify-on-failed-patch
  (let* ((run-tests-count 0)
         (*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\",\"arguments\":{\"file_path\":\"src/x.lisp\",\"form_type\":\"defun\",\"form_name\":\"f\",\"old_text\":\"a\",\"new_text\":\"b\"}}"
                "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"giving up\"}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (incf run-tests-count)
                 (%ok-tool-result id :passed 0 :failed 1))
                ((search "\"lisp-patch-form\"" body)
                 ;; Patch came back with isError=true — source was NOT modified.
                 (format nil
                         "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"form not found\"}]}}"
                         id))
                ((search "\"pool-kill-worker\"" body) (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (testing "patch attempt is counted, but successful applies stay zero"
      (ok (= 1 (cl-harness/src/agent:agent-state-patch-attempts state)))
      (ok (zerop (cl-harness/src/agent:agent-state-patch-count state))))
    (testing "run-tests is invoked only for the initial verify, not auto-reverify"
      (ok (= 1 run-tests-count)))
    (testing "agent terminates cleanly after the LLM gives up"
      (ok (eq :give-up (cl-harness/src/agent:agent-state-status state))))))

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
    (testing "limit-exhausted with limit-hit naming the slot"
      (ok (eq :limit-exhausted
              (cl-harness/src/agent:agent-state-status state)))
      (ok (member (cl-harness/src/agent:agent-state-limit-hit state)
                  '(:max-turns :max-tool-calls :max-read-files))))))

(deftest run-agent-enforces-max-tool-calls
  (let* ((*llm-responses*
          (loop repeat 10
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
         ;; 3 tool calls allowed; large max-turns so the tool-calls limit
         ;; clearly fires first.
         (limits (make-instance 'cl-harness/src/config:run-limits
                                :max-turns 50
                                :max-tool-calls 3
                                :max-patches 99
                                :max-read-files 99
                                :max-repl-evals 99
                                :max-wall-clock-seconds 600))
         (config (make-run-config :project-root "/tmp/proj"
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :issue "x"
                                  :limits limits))
         (state (%run-agent-with-temp-logger config provider mcp policy)))
    (testing "agent exits :limit-exhausted with limit-hit :max-tool-calls"
      (ok (eq :limit-exhausted
              (cl-harness/src/agent:agent-state-status state)))
      (ok (or (eq :max-tool-calls
                  (cl-harness/src/agent:agent-state-limit-hit state))
              ;; max-read-files=99 above max-tool-calls=3, so tool-calls
              ;; wins; we tolerate read-files in case ordering changes.
              (eq :max-read-files
                  (cl-harness/src/agent:agent-state-limit-hit state)))))
    (testing "tool-call counter reflects the budget actually consumed"
      (ok (>= (cl-harness/src/agent:agent-state-tool-call-count state) 3)))))

(deftest run-agent-emits-run-end-event-with-metrics
  (let ((*llm-responses*
         (list "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"smoke\"}"))
        (*mcp-handler*
         (lambda (body)
           (let ((id (%jsonrpc-id body)))
             (cond
               ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
               ((search "\"load-system\"" body) (%ok-tool-result id))
               ((search "\"run-tests\"" body)
                (%ok-tool-result id :passed 0 :failed 1))
               (t (error "unexpected MCP body: ~A" body))))))
        (mcp (%make-mcp-client-with-handler))
        (provider (%make-stub-provider))
        (policy (make-tool-policy :generic-mcp))
        (path (%temp-log-path)))
    (unwind-protect
         (let ((logger (cl-harness/src/log:open-run-logger path)))
           (cl-harness/src/agent:run-agent
            (%make-config) provider mcp policy logger)
           (cl-harness/src/log:close-run-logger logger)
           (with-open-file (in path)
             (let* ((lines (loop for l = (read-line in nil nil)
                                 while l collect l))
                    (last-line (first (last lines)))
                    (parsed (yason:parse last-line)))
               (testing "the last transcript event is :run-end"
                 (ok (equal "run-end" (gethash "type" parsed))))
               (testing "carries the full metric set required by REQ-LOG-002"
                 (ok (gethash "status" parsed))
                 (multiple-value-bind (val present)
                     (gethash "turns" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "tool_call_count" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "patch_count" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "patch_attempts" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "read_file_count" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "repl_eval_count" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "token_total" parsed) (declare (ignore val)) (ok present))
                 (multiple-value-bind (val present)
                     (gethash "elapsed_seconds" parsed) (declare (ignore val)) (ok present)))))
           t)
      (when (probe-file path) (delete-file path)))))

(deftest run-agent-aborts-on-consecutive-action-parse-errors
  (let* ((*llm-responses*
          (list "this is not json" "still nope" "neither is this"
                "fourth nope" "fifth nope"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 1))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (limits (make-instance 'cl-harness/src/config:run-limits
                                :max-turns 50
                                :max-tool-calls 99
                                :max-patches 99
                                :max-read-files 99
                                :max-repl-evals 99
                                :max-wall-clock-seconds 600
                                :max-action-parse-errors 3))
         (config (make-run-config :project-root "/tmp/proj"
                                  :system "demo"
                                  :test-system "demo/tests"
                                  :issue "x"
                                  :limits limits))
         (state (%run-agent-with-temp-logger config provider mcp policy)))
    (testing "limit-hit names :max-action-parse-errors"
      (ok (eq :limit-exhausted
              (cl-harness/src/agent:agent-state-status state)))
      (ok (eq :max-action-parse-errors
              (cl-harness/src/agent:agent-state-limit-hit state))))
    (testing "agent stops after exactly the budget"
      (ok (= 3 (cl-harness/src/agent:agent-state-parse-error-streak state))))))

(deftest run-agent-dry-run-skips-mcp-tool-calls
  (let* ((seen-patch-call (cons nil nil))
         (*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\",\"arguments\":{\"file_path\":\"src/x.lisp\",\"form_type\":\"defun\",\"form_name\":\"f\",\"old_text\":\"a\",\"new_text\":\"b\"}}"
                "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"end of dry run\"}"))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 1))
                ((search "\"lisp-patch-form\"" body)
                 (setf (car seen-patch-call) t)
                 (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (path (%temp-log-path)))
    (unwind-protect
         (let ((logger (cl-harness/src/log:open-run-logger path)))
           (cl-harness/src/agent:run-agent
            (%make-config) provider mcp policy logger
            :dry-run-p t)
           (cl-harness/src/log:close-run-logger logger)
           (testing "lisp-patch-form was NOT actually invoked"
             (ok (null (car seen-patch-call))))
           (testing ":dry-run-skip event appears in the transcript"
             (with-open-file (in path)
               (let ((found nil))
                 (loop for line = (read-line in nil nil)
                       while line
                       when (search "\"dry-run-skip\"" line)
                         do (setf found t))
                 (ok found))))
           (testing "run-start event records dry_run=true"
             (with-open-file (in path)
               (let ((parsed (yason:parse (read-line in))))
                 (ok (gethash "dry_run" parsed))))))
      (when (probe-file path) (delete-file path)))))

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

(deftest run-agent-isolate-asdf-p-default-scopes-worker-before-verify
  ;; Next Action #1 from docs/notes/2026-05-06-qwen-smoke.md: cl-harness:fix
  ;; must guarantee a clean worker + ASDF source-registry scoped to the
  ;; project-root BEFORE the initial verify-task fires, so a stale `smoke'
  ;; (or any system name) loaded from a previous run cannot answer the
  ;; verify and silently drive the agent off-target.
  (let* ((ordered '())
         (record (lambda (b) (push b ordered)))
         (*mcp-isolation-tap* record)
         (*mcp-handler*
          (lambda (body)
            (funcall record body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 4 :failed 0))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider
                    :transport (lambda (u h b)
                                 (declare (ignore u h b))
                                 (error "LLM should not be called when initial verify passes"))))
         (policy (make-tool-policy :generic-mcp))
         (state (%run-agent-with-temp-logger (%make-config) provider mcp policy)))
    (ok (eq :passed (agent-state-status state)))
    (let* ((calls (reverse ordered))
           (kill-idx (position-if
                      (lambda (b) (search "\"pool-kill-worker\"" b)) calls))
           (scope-idx (position-if
                       (lambda (b) (and (search "\"repl-eval\"" b)
                                        (search "initialize-source-registry" b)))
                       calls))
           (root-idx (position-if
                      (lambda (b) (search "\"fs-set-project-root\"" b)) calls))
           (load-idx (position-if
                      (lambda (b) (search "\"load-system\"" b)) calls)))
      (ok kill-idx "harness invoked pool-kill-worker")
      (ok scope-idx "harness invoked repl-eval with initialize-source-registry")
      (ok root-idx "harness invoked fs-set-project-root")
      (ok load-idx "harness invoked load-system")
      (when (and kill-idx scope-idx root-idx load-idx)
        (ok (< kill-idx scope-idx) "pool-kill precedes scope")
        (ok (< scope-idx root-idx) "scope precedes fs-set-project-root")
        (ok (< root-idx load-idx) "fs-set-project-root precedes load-system"))
      (when scope-idx
        (let ((scope-body (nth scope-idx calls)))
          (ok (search "/tmp/proj" scope-body)
              "scope repl-eval references project-root path")
          (ok (search "demo" scope-body)
              "scope repl-eval references the system name")
          (ok (search "demo/tests" scope-body)
              "scope repl-eval references the test-system name"))))))

(deftest run-agent-isolate-asdf-p-nil-skips-scoping
  ;; Opt-out path. With :isolate-asdf-p NIL the harness must not emit any
  ;; initialize-source-registry repl-eval, and fs-set-project-root must
  ;; precede every other recorded call.
  (let* ((ordered '())
         (saw-scope nil)
         (*mcp-isolation-tap*
          (lambda (body)
            (when (and (search "\"repl-eval\"" body)
                       (search "initialize-source-registry" body))
              (setf saw-scope t))))
         (*mcp-handler*
          (lambda (body)
            (push body ordered)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
                ((search "\"load-system\"" body) (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 4 :failed 0))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider
                    :transport (lambda (u h b)
                                 (declare (ignore u h b))
                                 (error "LLM should not be called when initial verify passes"))))
         (policy (make-tool-policy :generic-mcp))
         (path (%temp-log-path)))
    (unwind-protect
         (let* ((logger (open-run-logger path))
                (state (cl-harness/src/agent:run-agent
                        (%make-config) provider mcp policy logger
                        :isolate-asdf-p nil)))
           (cl-harness/src/log:close-run-logger logger)
           (ok (eq :passed (agent-state-status state)))
           (ok (not saw-scope)
               "harness must not scope ASDF when isolate-asdf-p is NIL")
           (let ((first-non-isolation (first (last ordered))))
             (ok (search "\"fs-set-project-root\"" first-non-isolation)
                 "first non-isolation MCP call is fs-set-project-root")))
      (when (probe-file path) (delete-file path)))))

(deftest run-agent-records-error-text-in-tool-result-event
  ;; Qwen-smoke Next Action #3: when the LLM-issued tool call returns
  ;; isError=true, the JSONL :tool-result event must carry the cl-mcp
  ;; content[].text payload as `error_text' so post-mortems do not
  ;; need a re-run with extra logging to find the cause.
  (let ((*llm-responses*
         (list "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"path\":\"/tmp/proj/x.lisp\"}}"
               "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"observed the error\"}"))
        (*mcp-handler*
         (lambda (body)
           (let ((id (%jsonrpc-id body)))
             (cond
               ((search "\"fs-set-project-root\"" body) (%ok-tool-result id))
               ((search "\"load-system\"" body) (%ok-tool-result id))
               ((search "\"run-tests\"" body)
                (%ok-tool-result id :passed 0 :failed 1))
               ((search "\"lisp-read-file\"" body)
                (%error-tool-result id "path is required"))
               (t (error "unexpected MCP body: ~A" body))))))
        (mcp (%make-mcp-client-with-handler))
        (provider (%make-stub-provider))
        (policy (make-tool-policy :generic-mcp))
        (path (%temp-log-path)))
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (run-agent (%make-config) provider mcp policy logger)
           (cl-harness/src/log:close-run-logger logger)
           (let* ((events (%read-jsonl-events path))
                  (tool-result
                   (find-if (lambda (e)
                              (and (equal "tool-result" (gethash "type" e))
                                   (equal "lisp-read-file" (gethash "tool" e))))
                            events)))
             (ok tool-result "tool-result event was logged")
             (when tool-result
               (ok (eq t (gethash "is_error" tool-result))
                   "is_error stayed truthy")
               (ok (equal "path is required"
                          (gethash "error_text" tool-result))
                   "error_text carries the cl-mcp content[].text payload"))))
      (when (probe-file path) (delete-file path)))))

(deftest run-agent-omits-error-text-when-tool-succeeded
  ;; Symmetric guarantee: a successful tool call should not carry an
  ;; error_text key (so consumers can use its presence as the signal).
  (let ((*llm-responses*
         (list "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"path\":\"/tmp/proj/x.lisp\"}}"
               "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"done\"}"))
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
        (path (%temp-log-path)))
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (run-agent (%make-config) provider mcp policy logger)
           (cl-harness/src/log:close-run-logger logger)
           (let* ((events (%read-jsonl-events path))
                  (tool-result
                   (find-if (lambda (e)
                              (and (equal "tool-result" (gethash "type" e))
                                   (equal "lisp-read-file" (gethash "tool" e))))
                            events)))
             (ok tool-result "tool-result event was logged")
             (when tool-result
               (multiple-value-bind (val present-p)
                   (gethash "error_text" tool-result)
                 (declare (ignore val))
                 (ok (not present-p)
                     "error_text key is absent on successful calls")))))
      (when (probe-file path) (delete-file path)))))

(deftest agent-state-develop-state-defaults-to-nil
  (let ((s (cl-harness/src/agent::%make-agent-state-for-tests)))
    (ok (null (agent-state-develop-state s)))))

(deftest agent-state-develop-state-accepts-back-ref
  (let* ((ds (make-develop-state
              :goal "g" :project-root "/tmp/"
              :system "s" :test-system "s/tests"))
         (s (cl-harness/src/agent::%make-agent-state-for-tests
             :develop-state ds)))
    (ok (eq ds (agent-state-develop-state s)))))

(deftest run-agent-records-patch-into-develop-state
  ;; Drive run-agent with a develop-state back-ref + a stub LLM that
  ;; emits one lisp-edit-form action followed by a successful reverify.
  ;; Verify exactly one patch-record lands in the develop-state's
  ;; ledger with the expected file path and via-tool.
  (let* ((ds (make-develop-state
              :goal "g"
              :project-root "/tmp/cl-harness-b6-test/"
              :system "demo"
              :test-system "demo/tests"))
         (run-tests-count 0)
         (*llm-responses*
          (list "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\",\"arguments\":{\"file_path\":\"src/x.lisp\",\"form_type\":\"defun\",\"form_name\":\"f\",\"operation\":\"replace\",\"content\":\"(defun f () 2)\"},\"thought\":\"replace f\"}"))
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
                ((search "\"lisp-edit-form\"" body)
                 (%ok-tool-result id))
                ((search "\"pool-kill-worker\"" body)
                 (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (mcp (%make-mcp-client-with-handler))
         (provider (%make-stub-provider))
         (policy (make-tool-policy :generic-mcp))
         (path (%temp-log-path)))
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (run-agent (%make-config) provider mcp policy logger
                      :develop-state ds)
           (close-run-logger logger))
      (when (probe-file path) (delete-file path)))
    (let ((records (develop-state-patch-records ds)))
      (ok (= 1 (length records)))
      (let ((p (first records)))
        (ok (search "x.lisp" (namestring (patch-record-path p))))
        (ok (string= "lisp-edit-form" (patch-record-via-tool p)))
        (ok (eq :pending (patch-record-verify-status p)))))))
