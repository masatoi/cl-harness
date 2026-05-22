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
                #:develop-state-patch-records
                #:develop-state-source-facts
                #:develop-state-runtime-vocabulary
                #:develop-state-current-step-index)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-path
                #:patch-record-via-tool
                #:patch-record-verify-status
                #:patch-record-related-step-index)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact-path
                #:source-fact-via-tool
                #:source-fact-related-step-index)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:runtime-vocab-fact-related-step-index)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:investigation-target)
  (:import-from #:cl-harness/src/explore
                #:run-explore-agent))

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

(defun %iserror-tool-result (text)
  "Build a hash-table mimicking an MCP tool-result with isError=true
and a single text content entry. Used by the new tool-error ring
populate tests."
  (alexandria:alist-hash-table
   `(("isError" . t)
     ("content"
      . ,(vector
          (alexandria:alist-hash-table
           `(("type" . "text") ("text" . ,text))
           :test 'equal))))
   :test 'equal))

(defun %fresh-agent-state ()
  "Construct a bare AGENT-STATE for ring-buffer tests."
  (make-instance 'cl-harness/src/agent::agent-state))

(deftest record-tool-error-pushes-and-truncates
  (let ((state (%fresh-agent-state)))
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 1)" "err A" 1)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 2)" "err B" 2)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 3)" "err C" 3)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 4)" "err D" 4)
    (let ((ring (cl-harness/src/agent:agent-state-last-tool-errors state)))
      (ok (= 3 (length ring)))
      (ok (string= "err D" (getf (first ring) :error-text))
          "head is most recent")
      (ok (string= "err B" (getf (third ring) :error-text))
          "oldest retained is the 2nd push (1st rolled off)"))))

(deftest summarize-tool-args-handles-known-tools
  (flet ((h (alist) (alexandria:alist-hash-table alist :test 'equal)))
    (ok (search "(my-parser \"abc\")"
                (cl-harness/src/agent::%summarize-tool-args
                 "repl-eval"
                 (h '(("code" . "(my-parser \"abc\")"))))))
    (ok (search "defun fibonacci"
                (cl-harness/src/agent::%summarize-tool-args
                 "lisp-edit-form"
                 (h '(("form_type" . "defun")
                      ("form_name" . "fibonacci")
                      ("operation" . "replace"))))))
    (ok (string= "fib"
                 (cl-harness/src/agent::%summarize-tool-args
                  "load-system" (h '(("system" . "fib"))))))
    (ok (search "fib/tests"
                (cl-harness/src/agent::%summarize-tool-args
                 "run-tests" (h '(("system" . "fib/tests"))))))))

(deftest summarize-tool-args-falls-back-to-json-dump
  (let* ((args (alexandria:alist-hash-table '(("foo" . "bar") ("n" . 42))
                                            :test 'equal))
         (out (cl-harness/src/agent::%summarize-tool-args
               "unknown-tool" args)))
    (ok (search "foo" out))
    (ok (<= (length out) 200))))

(deftest summarize-tool-args-flattens-newlines
  (let* ((args (alexandria:alist-hash-table
                '(("code" . "(progn
  (foo)
  (bar))"))
                :test 'equal))
         (out (cl-harness/src/agent::%summarize-tool-args
               "repl-eval" args)))
    (ok (not (find #\Newline out)) "no embedded newlines")
    (ok (search "(progn" out))))

(deftest step-turn-records-tool-error-when-iserror-true
  (let ((state (%fresh-agent-state)))
    (cl-harness/src/agent::%maybe-record-tool-error
     state "repl-eval"
     (alexandria:alist-hash-table '(("code" . "(boom)")) :test 'equal)
     (%iserror-tool-result "The variable INPUT is unbound.")
     7)
    (let ((ring (cl-harness/src/agent:agent-state-last-tool-errors state)))
      (ok (= 1 (length ring)))
      (ok (string= "repl-eval" (getf (first ring) :tool-name)))
      (ok (search "INPUT is unbound" (getf (first ring) :error-text)))
      (ok (= 7 (getf (first ring) :turn))))))

(deftest step-turn-skips-recording-on-success
  (let ((state (%fresh-agent-state))
        (ok-result (alexandria:alist-hash-table
                    `(("isError" . :false)
                      ("content" . ,(vector
                                     (alexandria:alist-hash-table
                                      '(("type" . "text") ("text" . "ok"))
                                      :test 'equal))))
                    :test 'equal)))
    (cl-harness/src/agent::%maybe-record-tool-error
     state "repl-eval"
     (alexandria:alist-hash-table '(("code" . "(:ok)")) :test 'equal)
     ok-result
     1)
    (ok (null (cl-harness/src/agent:agent-state-last-tool-errors state)))))

(deftest run-agent-persists-final-verify-on-give-up
  ;; C-1 regression: when the agent gives up after a failed
  ;; post-patch verify, agent-state-final-verify must hold the LAST
  ;; verify-result (not NIL), so the orchestrator's %FAILURE-CONTEXT
  ;; can extract its load-system / run-tests error text for the
  ;; replanner.
  ;;
  ;; This drives the bug observed in fib EXPORT name-conflict :STUCK
  ;; sessions where verify-error never reached the planner.
  (let* ((load-fail-result
          (alexandria:alist-hash-table
           `(("isError" . t)
             ("content"
              . ,(vector
                  (alexandria:alist-hash-table
                   '(("type" . "text")
                     ("text" . "EXPORT FIB::FIBONACCI causes name-conflicts ..."))
                   :test 'equal))))
           :test 'equal))
         (vr (make-instance 'cl-harness/src/verify:verify-result
                            :status :load-failed
                            :load-result load-fail-result))
         (state (make-instance 'cl-harness/src/agent::agent-state)))
    ;; Simulate the post-patch verify branch storing the latest
    ;; verify-result onto agent-state.
    (cl-harness/src/agent::%record-failed-verify state vr)
    (ok (eq vr (cl-harness/src/agent:agent-state-final-verify state))
        "verify-result is persisted on the failed-verify path")))

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

(deftest run-agent-records-source-fact-into-develop-state
  ;; Drive run-agent with a develop-state back-ref + a stub LLM that
  ;; emits one lisp-read-file action followed by finish. Verify exactly
  ;; one source-fact lands in the ledger with the expected file path
  ;; and via-tool.
  (let ((ds (make-develop-state
             :goal "g"
             :project-root "/tmp/cl-harness-b7-test/"
             :system "demo"
             :test-system "demo/tests"))
        (*llm-responses*
         (list "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"path\":\"src/foo.lisp\",\"name_pattern\":\"^bar$\"},\"thought\":\"read foo\"}"
               "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"done\"}"))
        (*mcp-handler*
         (lambda (body)
           (let ((id (%jsonrpc-id body)))
             (cond
               ((search "\"fs-set-project-root\"" body)
                (%ok-tool-result id))
               ((search "\"load-system\"" body)
                (%ok-tool-result id))
               ((search "\"run-tests\"" body)
                (%ok-tool-result id :passed 0 :failed 1))
               ((search "\"lisp-read-file\"" body)
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
    (let ((facts (develop-state-source-facts ds)))
      (ok (= 1 (length facts)))
      (let ((f (first facts)))
        (ok (search "foo" (namestring (source-fact-path f))))
        (ok (string= "lisp-read-file" (source-fact-via-tool f)))))))

(deftest agent-records-runtime-vocab-fact-on-code-describe-success
  ;; Drive the recorder logic in isolation by feeding a hash-table
  ;; that mimics a successful code-describe tool result. Tests the
  ;; private helper directly; no live MCP client needed.
  (let* ((result (alexandria:plist-hash-table
                  (list "kind" "function"
                        "name" "foo"
                        "package" "CL-USER"
                        "summary" "(foo x) -> integer")
                  :test 'equal))
         (fact (cl-harness/src/agent::%vocab-fact-from-tool-result
                "code-describe" result :related-step-index 3)))
    (ok (typep fact 'cl-harness/src/runtime-vocabulary:runtime-vocab-fact))
    (ok (eq :function
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind fact)))
    (ok (string= "foo"
                 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-name
                  fact)))
    (ok (string= "CL-USER"
                 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-package
                  fact)))
    (ok (eql 3 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-related-step-index
                fact)))))

(deftest agent-records-runtime-vocab-fact-skips-on-isError
  (let* ((result (alexandria:plist-hash-table
                  (list "isError" t "kind" "function" "name" "foo")
                  :test 'equal))
         (fact (cl-harness/src/agent::%vocab-fact-from-tool-result
                "code-describe" result)))
    (ok (null fact))))

(deftest agent-records-runtime-vocab-fact-skips-on-missing-name
  (let* ((result (alexandria:plist-hash-table
                  (list "kind" "function") :test 'equal))
         (fact (cl-harness/src/agent::%vocab-fact-from-tool-result
                "code-describe" result)))
    (ok (null fact))))

(deftest agent-records-runtime-vocab-fact-on-code-find-list-result
  ;; code-find returns a list-shaped result with multiple entries;
  ;; the helper records one fact per entry.
  (let* ((result (alexandria:plist-hash-table
                  (list "results"
                        (list (alexandria:plist-hash-table
                               (list "kind" "function" "name" "f1"
                                     "package" "P")
                               :test 'equal)
                              (alexandria:plist-hash-table
                               (list "kind" "class" "name" "C1"
                                     "package" "P")
                               :test 'equal)))
                  :test 'equal))
         (facts (cl-harness/src/agent::%vocab-facts-from-tool-result
                 "code-find" result)))
    (ok (= 2 (length facts)))
    (ok (eq :function
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind
             (first facts))))
    (ok (eq :class
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind
             (second facts))))))

(deftest agent-records-runtime-vocab-fact-on-code-describe-via-plural-helper
  ;; %vocab-facts-from-tool-result is the plural helper called by the
  ;; agent loop's recorder integration. code-describe results have NO
  ;; "results" key, so the helper must fall back to single-fact
  ;; extraction on the outer hash. Pre-fix this returned nil because
  ;; (listp NIL) wrongly classified an absent key as an empty list.
  (let* ((result (alexandria:plist-hash-table
                  (list "kind" "function"
                        "name" "foo"
                        "package" "CL-USER")
                  :test 'equal))
         (facts (cl-harness/src/agent::%vocab-facts-from-tool-result
                 "code-describe" result)))
    (ok (= 1 (length facts)))
    (ok (eq :function
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind
             (first facts))))
    (ok (string= "foo"
                 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-name
                  (first facts))))))

(deftest agent-records-runtime-vocab-empty-results-yields-no-facts
  ;; code-find with no matches returns {"results": []}. The helper
  ;; must distinguish "key present, list empty" (iterate zero
  ;; entries, return nil) from "key absent" (fall back to outer
  ;; single-fact). With a present-but-empty results list AND no
  ;; outer kind/name, the answer is correctly the empty list — NOT
  ;; a spurious fall-through that would try to coerce the outer
  ;; hash into a fact.
  (let* ((result (alexandria:plist-hash-table
                  (list "results" '())
                  :test 'equal))
         (facts (cl-harness/src/agent::%vocab-facts-from-tool-result
                 "code-find" result)))
    (ok (null facts))))

(deftest record-source-fact-threads-current-step-index
  ;; Drive run-agent with a develop-state whose CURRENT-STEP-INDEX is
  ;; pre-set; the recorder for source-facts must persist that index on
  ;; the resulting SOURCE-FACT (instead of the previously hard-coded
  ;; NIL).
  (let ((ds (make-develop-state
             :goal "g"
             :project-root "/tmp/cl-harness-step-idx-source/"
             :system "demo"
             :test-system "demo/tests"))
        (*llm-responses*
         (list "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"path\":\"src/foo.lisp\",\"name_pattern\":\"^bar$\"},\"thought\":\"read foo\"}"
               "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"done\"}"))
        (*mcp-handler*
         (lambda (body)
           (let ((id (%jsonrpc-id body)))
             (cond
               ((search "\"fs-set-project-root\"" body)
                (%ok-tool-result id))
               ((search "\"load-system\"" body)
                (%ok-tool-result id))
               ((search "\"run-tests\"" body)
                (%ok-tool-result id :passed 0 :failed 1))
               ((search "\"lisp-read-file\"" body)
                (%ok-tool-result id))
               ((search "\"pool-kill-worker\"" body)
                (%ok-tool-result id))
               (t (error "unexpected MCP body: ~A" body))))))
        (mcp (%make-mcp-client-with-handler))
        (provider (%make-stub-provider))
        (policy (make-tool-policy :generic-mcp))
        (path (%temp-log-path)))
    (setf (develop-state-current-step-index ds) 7)
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (run-agent (%make-config) provider mcp policy logger
                      :develop-state ds)
           (close-run-logger logger))
      (when (probe-file path) (delete-file path)))
    (let ((facts (develop-state-source-facts ds)))
      (ok (= 1 (length facts)))
      (ok (eql 7 (source-fact-related-step-index (first facts)))))))

(deftest record-runtime-vocab-threads-current-step-index
  ;; Drive the runtime-vocab recorder helper directly with a hand-built
  ;; list-shaped result and a develop-state whose CURRENT-STEP-INDEX is
  ;; pre-set; the helper must persist that index on every recorded
  ;; RUNTIME-VOCAB-FACT (instead of the previously hard-coded NIL).
  (let* ((ds (make-develop-state
              :goal "g"
              :project-root "/tmp/cl-harness-step-idx-vocab/"
              :system "demo"
              :test-system "demo/tests"))
         (state (cl-harness/src/agent::%make-agent-state-for-tests
                 :develop-state ds))
         (result (alexandria:plist-hash-table
                  (list "results"
                        (list (alexandria:plist-hash-table
                               (list "kind" "function"
                                     "name" "foo"
                                     "package" "CL-USER")
                               :test 'equal)))
                  :test 'equal)))
    (setf (develop-state-current-step-index ds) 4)
    (cl-harness/src/agent::%record-runtime-vocab-from-tool-call
     "code-find" result state)
    (let ((facts (develop-state-runtime-vocabulary ds)))
      (ok (= 1 (length facts)))
      (ok (eql 4 (runtime-vocab-fact-related-step-index (first facts)))))))

(deftest record-patch-record-threads-current-step-index
  ;; Drive run-agent with a develop-state whose CURRENT-STEP-INDEX is
  ;; pre-set; the recorder for patch-records must persist that index on
  ;; the resulting PATCH-RECORD (instead of NIL).
  (let* ((ds (make-develop-state
              :goal "g"
              :project-root "/tmp/cl-harness-step-idx-patch/"
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
    (setf (develop-state-current-step-index ds) 9)
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (run-agent (%make-config) provider mcp policy logger
                      :develop-state ds)
           (close-run-logger logger))
      (when (probe-file path) (delete-file path)))
    (let ((records (develop-state-patch-records ds)))
      (ok (= 1 (length records)))
      (ok (eql 9 (patch-record-related-step-index (first records)))))))

(deftest run-explore-agent-uses-context-view-when-develop-state-supplied
  ;; Phase C.7 wiring: when :develop-state is passed, the initial user
  ;; prompt's issue + investigation-targets section is rendered via
  ;; CONTEXT-VIEW->STRING with the :exploration formatter. Capture the
  ;; HTTP body the LLM transport receives, and assert the rendered
  ;; section markers ("## Current step", "## Investigation targets")
  ;; and the investigation-target marker string both appear.
  (let* ((ds (make-develop-state
              :goal "g"
              :project-root "/tmp/cl-harness-c7-test/"
              :system "demo"
              :test-system "demo/tests"))
         (target (make-instance 'investigation-target
                                :kind :function
                                :name "[INVESTIGATION-MARKER]"
                                :intent "verify wiring"))
         (step (make-instance 'plan-step
                              :index 0
                              :issue "Add greet."
                              :test-name "greet-test"
                              :test-source "(deftest greet-test (ok t))"
                              :investigation-targets (list target)
                              :needs-exploration :lightweight))
         (captured (cons nil nil))
         (transport
          (lambda (url headers body)
            (declare (ignore url headers))
            (setf (car captured) body)
            (values
             (%llm-body
              "{\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"ok\"}")
             200
             (make-hash-table :test 'equal))))
         (provider (%make-stub-provider :transport transport))
         (mcp (%make-mcp-client-with-handler))
         (policy (make-tool-policy :explore))
         (config (%make-config))
         (path (%temp-log-path)))
    (setf (cl-harness/src/state:develop-state-current-step-index ds) 0)
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (unwind-protect
                (run-explore-agent config provider mcp policy logger
                                   :plan-step step
                                   :develop-state ds)
             (close-run-logger logger)))
      (when (probe-file path) (delete-file path)))
    (let* ((req (yason:parse (car captured)))
           (messages (gethash "messages" req))
           (user-msg (find-if (lambda (m) (equal "user" (gethash "role" m)))
                              (coerce messages 'list)))
           (content (and user-msg (gethash "content" user-msg))))
      (ok user-msg "user message present in captured request")
      (ok (and content (search "## Current step" content))
          "context-view :exploration Current step heading present")
      (ok (and content (search "## Investigation targets" content))
          "context-view :exploration Investigation targets heading present")
      (ok (and content (search "[INVESTIGATION-MARKER]" content))
          "investigation-target name appears in user prompt"))))

(deftest run-agent-uses-context-view-when-develop-state-supplied
  ;; Phase C.8 wiring: when :develop-state is passed AND develop-state
  ;; has a current-plan with a step at current-step-index, run-agent's
  ;; initial-user-prompt renders the issue/task section via
  ;; CONTEXT-VIEW->STRING with the :implementation formatter. Capture
  ;; the HTTP body the LLM transport receives, and assert the rendered
  ;; section markers ("## Current step") and the issue marker string
  ;; both appear.
  (let* ((step (make-instance 'plan-step
                              :index 0
                              :issue "[IMPLEMENTATION-MARKER]"
                              :test-name "test-marker"
                              :test-source
                              "(rove:deftest test-marker (rove:ok t))"))
         (ds (make-develop-state
              :goal "g"
              :project-root "/tmp/cl-harness-c8-test/"
              :system "demo"
              :test-system "demo/tests"))
         (captured (cons nil nil))
         (transport
          (lambda (url headers body)
            (declare (ignore url headers))
            (setf (car captured) body)
            (values
             (%llm-body
              "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"ok\"}")
             200
             (make-hash-table :test 'equal))))
         (*mcp-handler*
          (lambda (body)
            (let ((id (%jsonrpc-id body)))
              (cond
                ((search "\"fs-set-project-root\"" body)
                 (%ok-tool-result id))
                ((search "\"load-system\"" body)
                 (%ok-tool-result id))
                ((search "\"run-tests\"" body)
                 (%ok-tool-result id :passed 0 :failed 1))
                ((search "\"pool-kill-worker\"" body)
                 (%ok-tool-result id))
                (t (error "unexpected MCP body: ~A" body))))))
         (provider (%make-stub-provider :transport transport))
         (mcp (%make-mcp-client-with-handler))
         (policy (make-tool-policy :generic-mcp))
         (config (%make-config))
         (path (%temp-log-path)))
    (setf (cl-harness/src/state:develop-state-current-plan ds) (list step))
    (setf (cl-harness/src/state:develop-state-current-step-index ds) 0)
    (unwind-protect
         (let ((logger (open-run-logger path)))
           (unwind-protect
                (run-agent config provider mcp policy logger
                           :develop-state ds)
             (close-run-logger logger)))
      (when (probe-file path) (delete-file path)))
    (let* ((req (yason:parse (car captured)))
           (messages (gethash "messages" req))
           (user-msg (find-if (lambda (m) (equal "user" (gethash "role" m)))
                              (coerce messages 'list)))
           (content (and user-msg (gethash "content" user-msg))))
      (ok user-msg "user message present in captured request")
      (ok (and content (search "## Current step" content))
          "context-view :implementation Current step heading present")
      (ok (and content (search "[IMPLEMENTATION-MARKER]" content))
          "plan-step issue text appears in user prompt"))))

(deftest maybe-compact-messages-fires-over-threshold
  ;; Phase D.2: when the messages list's approximate token estimate
  ;; exceeds RUN-LIMITS-MAX-CONTEXT-TOKENS, %MAYBE-COMPACT-MESSAGES
  ;; returns the compacted form (shorter than input).
  (let* ((messages (loop for i from 0 below 200
                         collect (cl-harness/src/model:make-chat-message
                                  "user"
                                  (format nil "padding message ~A xxxxxxx" i))))
         (limits (make-instance 'cl-harness/src/config:run-limits
                                :max-turns 1
                                :max-tool-calls 1
                                :max-patches 1
                                :max-read-files 1
                                :max-repl-evals 1
                                :max-wall-clock-seconds 1
                                :max-action-parse-errors 1
                                :max-context-tokens 1000))
         (result (cl-harness/src/agent::%maybe-compact-messages
                  messages limits)))
    (ok (< (length result) (length messages)))))

(deftest maybe-compact-messages-skips-under-threshold
  ;; Phase D.2: under the threshold, %MAYBE-COMPACT-MESSAGES returns
  ;; the original list verbatim — no compaction overhead, no behavior
  ;; change for short conversations.
  (let* ((messages (loop for i from 0 below 5
                         collect (cl-harness/src/model:make-chat-message
                                  "user" (format nil "msg ~A" i))))
         (limits (make-default-limits))
         (result (cl-harness/src/agent::%maybe-compact-messages
                  messages limits)))
    (ok (eql (length result) (length messages)))
    (ok (equal messages result))))

(deftest maybe-compact-messages-handles-nil-limits
  ;; Phase D.2: a NIL run-limits (defensive guard) short-circuits the
  ;; helper and returns MESSAGES unchanged. Same identity, no copy.
  (let ((messages (loop for i from 0 below 5
                        collect (cl-harness/src/model:make-chat-message
                                 "user" (format nil "m ~A" i)))))
    (ok (eq messages
            (cl-harness/src/agent::%maybe-compact-messages messages nil)))))

(defun %make-fake-text-result (text)
  "Test helper: construct a hash-table that looks like a tools/call
success result with one text content block."
  (alexandria:alist-hash-table
   `(("content" . ,(vector
                    (alexandria:alist-hash-table
                     `(("type" . "text") ("text" . ,text))
                     :test 'equal))))
   :test 'equal))

(deftest summarize-fs-read-file-truncates-large-text
  (let* ((huge (make-string 5000 :initial-element #\a))
         (result (%make-fake-text-result huge))
         (out (cl-harness/src/agent::summarize-tool-result "fs-read-file" result)))
    (ok (< (length out) 2500))
    (ok (search "[... truncated" out))))

(deftest summarize-fs-read-file-leaves-short-text-alone
  (let* ((short "(defun foo () 1)")
         (result (%make-fake-text-result short))
         (out (cl-harness/src/agent::summarize-tool-result "fs-read-file" result)))
    (ok (search short out))
    (ok (not (search "truncated" out)))))

(deftest summarize-lisp-read-file-truncates-large-text
  (let* ((huge (make-string 5000 :initial-element #\b))
         (result (%make-fake-text-result huge))
         (out (cl-harness/src/agent::summarize-tool-result "lisp-read-file" result)))
    (ok (< (length out) 2500))
    (ok (search "[... truncated" out))))

(deftest summarize-clgrep-search-truncates-large-text
  (let* ((huge (make-string 5000 :initial-element #\c))
         (result (%make-fake-text-result huge))
         (out (cl-harness/src/agent::summarize-tool-result "clgrep-search" result)))
    (ok (< (length out) 2500))
    (ok (search "[... truncated" out))))

(deftest summarize-run-tests-signals-truncation-when-over-five-failures
  (let* ((entries (loop for i from 0 below 8
                        collect (alexandria:alist-hash-table
                                 `(("test_name" . ,(format nil "test-~D" i))
                                   ("description" . ,(format nil "test ~D failed" i))
                                   ("reason" . "x"))
                                 :test 'equal)))
         (tr (alexandria:alist-hash-table
              `(("passed" . 0)
                ("failed" . 8)
                ("failed_tests" . ,(coerce entries 'vector)))
              :test 'equal)))
    (let ((out (cl-harness/src/agent::summarize-tool-result "run-tests" tr)))
      (ok (search "3 more" out))
      (ok (or (search "test-0" out) (search "test-1" out)))
      (ok (not (search "test-7" out))))))

(deftest summarize-run-tests-no-footer-when-five-or-fewer-failures
  (let* ((entries (loop for i from 0 below 5
                        collect (alexandria:alist-hash-table
                                 `(("test_name" . ,(format nil "t~D" i))
                                   ("description" . "x") ("reason" . "y"))
                                 :test 'equal)))
         (tr (alexandria:alist-hash-table
              `(("passed" . 0) ("failed" . 5)
                ("failed_tests" . ,(coerce entries 'vector)))
              :test 'equal)))
    (let ((out (cl-harness/src/agent::summarize-tool-result "run-tests" tr)))
      (ok (not (search "more failure" out))))))

(deftest patch-on-asd-marks-project-summary-dirty
  (let ((dstate (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x"
              :test-system "x/tests"))
        (record (cl-harness/src/patch-record:make-patch-record
                 :path "foo.asd" :via-tool "fs-write-file"
                 :turn 1)))
    (cl-harness/src/state:develop-state-set-project-summary dstate sum)
    (cl-harness/src/agent::%maybe-mark-summary-dirty dstate record)
    (ok (eq t (cl-harness/src/project-summary:project-summary-dirty-p sum)))))

(deftest patch-on-defpackage-form-marks-project-summary-dirty
  (let ((dstate (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x"
              :test-system "x/tests"))
        (record (cl-harness/src/patch-record:make-patch-record
                 :path "src/foo.lisp" :via-tool "lisp-edit-form"
                 :form-type "defpackage" :form-name "my-pkg"
                 :turn 1)))
    (cl-harness/src/state:develop-state-set-project-summary dstate sum)
    (cl-harness/src/agent::%maybe-mark-summary-dirty dstate record)
    (ok (eq t (cl-harness/src/project-summary:project-summary-dirty-p sum)))))

(deftest patch-on-defun-leaves-project-summary-clean
  (let ((dstate (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x"
              :test-system "x/tests"))
        (record (cl-harness/src/patch-record:make-patch-record
                 :path "src/foo.lisp" :via-tool "lisp-edit-form"
                 :form-type "defun" :form-name "bar"
                 :turn 1)))
    (cl-harness/src/state:develop-state-set-project-summary dstate sum)
    (cl-harness/src/agent::%maybe-mark-summary-dirty dstate record)
    (ok (null (cl-harness/src/project-summary:project-summary-dirty-p sum)))))

(deftest runtime-native-system-prompt-encourages-code-introspection
  ;; Phase G prompt enrichment: the runtime-native system prompt
  ;; should explicitly call out code-find / code-describe /
  ;; code-find-references as the probe-of-choice for vocabulary
  ;; questions, so the LLM populates the runtime-vocabulary ledger
  ;; in production.
  (let* ((policy (make-tool-policy :runtime-native))
         (prompt (cl-harness/src/agent::system-prompt policy)))
    (ok (search "code-find" prompt))
    (ok (search "code-describe" prompt))
    (ok (search "code-find-references" prompt))
    (ok (search "vocabulary" prompt))))

(deftest agent-state-reason-defaults-to-nil
  ;; Phase: transport failure-mode coverage.
  ;; The new :reason slot is the failure-mode classifier surface.
  ;; Defaults NIL on the success path; the agent loop / orchestrator
  ;; sets it when status transitions to :error / :give-up with a
  ;; specific reason.
  (let ((s (cl-harness/src/agent::%make-agent-state-for-tests)))
    (ok (null (cl-harness/src/agent:agent-state-reason s)))))

(deftest step-turn-with-empty-content-yields-give-up-empty-content
  ;; Reviewer follow-up: locks the agent-loop empty-content path
  ;; (src/agent.lisp:1133-1141) end-to-end via STEP-TURN driving with
  ;; a stub provider that returns chat-completions with empty content.
  ;; Asserts:
  ;;   1. STEP-TURN's OUTCOME (second return) is :GIVE-UP.
  ;;   2. AGENT-STATE-REASON is :EMPTY-CONTENT after the turn.
  ;; The transport-test e2e covers the planner path; this test pins
  ;; the agent-loop path independently.
  (let* ((empty-body
          "{\"choices\":[{\"message\":{\"content\":\"\"}}]}")
         (canned-transport
          (lambda (url headers body)
            (declare (ignore url headers body))
            (values empty-body 200 (make-hash-table :test 'equal))))
         (provider (%make-stub-provider :transport canned-transport))
         (config (%make-config))
         (state (cl-harness/src/agent::%make-agent-state-for-tests))
         (policy (make-tool-policy :generic-mcp))
         (log-path (%temp-log-path)))
    (unwind-protect
         (let ((logger (open-run-logger log-path)))
           (unwind-protect
                (multiple-value-bind (new-messages outcome verify action)
                    (cl-harness/src/agent::step-turn
                     1 state config provider nil policy logger '())
                  (declare (ignore new-messages verify action))
                  (ok (eq :give-up outcome))
                  (ok (eq :empty-content
                          (cl-harness/src/agent:agent-state-reason state))))
             (close-run-logger logger)))
      (when (probe-file log-path) (delete-file log-path)))))

(deftest verify-failed-tests-payload-extraction
  (testing "returns NIL when verify-result has no failed tests"
    (let ((vr (make-instance 'cl-harness/src/verify:verify-result
                             :status :passed
                             :passed 3
                             :failed 0
                             :test-result nil)))
      (ok (null (cl-harness/src/agent::%verify-failed-tests-payload vr)))))
  (testing "returns NIL when test field present but failed_tests is empty"
    (let* ((tr (alexandria:plist-hash-table
                `("failed_tests" ,(vector))
                :test 'equal))
           (vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :passed
                              :passed 3
                              :failed 0
                              :test-result tr)))
      (ok (null (cl-harness/src/agent::%verify-failed-tests-payload vr)))))
  (testing "returns the failed_tests array verbatim when present"
    (let* ((ft (alexandria:plist-hash-table
                `("test_name" "demo-test"
                  "description" "demo description"
                  "reason" "got 3 instead of \"Fizz\"")
                :test 'equal))
           (tr (alexandria:plist-hash-table
                `("failed_tests" ,(vector ft))
                :test 'equal))
           (vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :test-failed
                              :passed 0
                              :failed 1
                              :test-result tr))
           (payload (cl-harness/src/agent::%verify-failed-tests-payload vr)))
      (ok payload)
      (ok (= 1 (length payload)))
      (ok (equal "demo-test" (gethash "test_name" (elt payload 0)))))))

(deftest verify-event-payload-includes-failed-tests
  (testing "passed verify has no failed_tests key"
    (let* ((vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :passed
                              :passed 3
                              :failed 0
                              :test-result nil))
           (payload (cl-harness/src/agent:verify-event-payload 6 vr)))
      (ok (not (assoc "failed_tests" payload :test #'equal)))))
  (testing "failed verify includes failed_tests array"
    (let* ((ft (alexandria:plist-hash-table
                `("test_name" "t1" "reason" "boom")
                :test 'equal))
           (tr (alexandria:plist-hash-table
                `("failed_tests" ,(vector ft))
                :test 'equal))
           (vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :test-failed
                              :passed 0
                              :failed 1
                              :test-result tr))
           (payload (cl-harness/src/agent:verify-event-payload 6 vr))
           (entry (assoc "failed_tests" payload :test #'equal)))
      (ok entry)
      (ok (= 1 (length (cdr entry))))
      (ok (equal "t1" (gethash "test_name" (elt (cdr entry) 0)))))))

(defun %capture-jsonl-events (thunk)
  "Run THUNK with a fresh logger pointing to a tmp JSONL file and
return the parsed events as a list of hash-tables."
  (let* ((path (merge-pathnames
                (format nil "agent-log-capture-~A.jsonl"
                        (get-internal-real-time))
                (uiop:temporary-directory)))
         (logger (cl-harness/src/log:open-run-logger path))
         (events (list)))
    (unwind-protect
         (progn
           (funcall thunk logger)
           (cl-harness/src/log:close-run-logger logger)
           (with-open-file (in path)
             (loop for line = (read-line in nil nil)
                   while line
                   do (push (yason:parse line) events))))
      (when (probe-file path) (delete-file path)))
    (nreverse events)))

(deftest tool-result-event-content-summary
  (testing "successful tool-result has content_summary field"
    (let* ((result (alexandria:plist-hash-table
                    `("isError" nil
                      "content" ,(vector
                                  (alexandria:plist-hash-table
                                   `("type" "text" "text" "READ-OK-CONTENT")
                                   :test 'equal)))
                    :test 'equal))
           (events
             (%capture-jsonl-events
              (lambda (logger)
                (let* ((is-error (and (gethash "isError" result) t))
                       (summary (cl-harness/src/agent:summarize-tool-result
                                 "lisp-read-file" result))
                       (payload `(("turn" . 2)
                                  ("tool" . "lisp-read-file")
                                  ("is_error" . ,is-error)
                                  ,@(unless is-error
                                      `(("content_summary" . ,summary))))))
                  (cl-harness/src/log:log-event
                   logger :tool-result payload)))))
           (event (first events)))
      (ok (= 1 (length events)))
      (ok (equal "tool-result" (gethash "type" event)))
      (ok (gethash "content_summary" event))
      (ok (search "READ-OK-CONTENT" (gethash "content_summary" event)))))
  (testing "error tool-result has error_text but no content_summary"
    (let* ((events
             (%capture-jsonl-events
              (lambda (logger)
                (cl-harness/src/log:log-event
                 logger :tool-result
                 `(("turn" . 4)
                   ("tool" . "lisp-patch-form")
                   ("is_error" . t)
                   ("error_text" . "BOOM"))))))
           (event (first events)))
      (ok (equal "lisp-patch-form" (gethash "tool" event)))
      (ok (equal t (gethash "is_error" event)))
      (ok (equal "BOOM" (gethash "error_text" event)))
      (ok (null (gethash "content_summary" event))))))
