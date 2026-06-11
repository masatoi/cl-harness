;;;; next/tests/main-test.lisp
;;;;
;;;; Facade smoke tests + cross-module integration tests for
;;;; cl-harness-next (SP1: L0 substrate).

(defpackage #:cl-harness-next/tests/main-test
  (:use #:cl #:rove))

(in-package #:cl-harness-next/tests/main-test)

(deftest facade-package-exists
  (ok (find-package '#:cl-harness-next))
  (ok (equal "0.1.0" (cl-harness-next:substrate-version))))

(deftest run-start-records-pack-fingerprint
  ;; SP1 acceptance: a run can durably record which policy pack it
  ;; used (spec 原則3「すべての実行は実験である」).
  (uiop:with-temporary-file (:pathname pack-path :type "sexp")
    (with-open-file (out pack-path :direction :output
                                   :if-exists :supersede
                                   :external-format :utf-8)
      (write-string "(:name \"default\" :version \"0.1.0\")" out))
    (uiop:with-temporary-file (:pathname log-path :type "jsonl")
      (uiop:delete-file-if-exists log-path)
      (let ((pack (cl-harness-next:load-policy-pack pack-path))
            (log (cl-harness-next:open-event-log log-path)))
        (cl-harness-next:emit-event
         log :run-start
         (alexandria:plist-hash-table
          (list "pack_name" (cl-harness-next:pack-name pack)
                "pack_fingerprint" (cl-harness-next:pack-fingerprint pack))
          :test #'equal))
        (let ((event (first (cl-harness-next:read-events log-path))))
          (ok (eq :run-start (cl-harness-next:event-type event)))
          (ok (equal (cl-harness-next:pack-fingerprint pack)
                     (gethash "pack_fingerprint"
                              (cl-harness-next:event-payload event)))))))))

(defclass %facade-scripted-transport (cl-harness-next:mcp-transport)
  ()
  (:documentation "Minimal canned transport for the facade acceptance
test; lives here because the test must only use facade symbols."))

(defmethod cl-harness-next:transport-send-request
    ((transport %facade-scripted-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}"
               id
               "\"result\":{\"tools\":[{\"name\":\"run-tests\"}]}"))
      ((equal method "tools/call")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"content\":[]}}"
               id))
      (t (error "unexpected method ~S" method)))))

(deftest facade-environment-records-events
  ;; SP2 acceptance: through the facade alone, wrap an MCP client as a
  ;; policy-restricted environment and observe the action/observation
  ;; events land in the L0 log (spec §5 + 原則3).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (cl-harness-next:open-event-log log-path))
           (env (cl-harness-next:make-cl-mcp-environment
                 :client (cl-harness-next:make-mcp-client
                          (make-instance '%facade-scripted-transport))
                 :condition :file-only
                 :event-log log)))
      (cl-harness-next:perform-action env "run-tests"
                                      (make-hash-table :test #'equal))
      (cl-harness-next:environment-close env)
      (ok (equal '(:action :observation)
                 (mapcar #'cl-harness-next:event-type
                         (cl-harness-next:read-events log-path)))))))

(deftest world-model-and-context-from-event-log
  ;; SP3 acceptance: replaying a full synthetic run's event log yields
  ;; a world model whose compiled views are bounded and annotated
  ;; (spec §8.2/§8.3; doc §5/§7/§9).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let ((log (cl-harness-next:open-event-log log-path)))
      (flet ((emit (type &rest plist)
               (cl-harness-next:emit-event
                log type (alexandria:plist-hash-table plist :test #'equal)))
             (h (&rest plist)
               (alexandria:plist-hash-table plist :test #'equal)))
        (emit :run-start "goal" "Fix evict")
        (emit :decision "kind" "finding" "hypothesis" "ordering bug"
              "probe" "repl" "finding" "reversed" "decision" "fix it")
        (emit :action "tool" "repl-eval" "arguments" (h "code" "(evict)"))
        (emit :observation "tool" "repl-eval" "result" (h "ok" t))
        (emit :action "tool" "lisp-edit-form"
              "arguments" (h "file_path" "src/cache.lisp"
                             "content" "ordering bug fix"))
        (emit :observation "tool" "lisp-edit-form" "result" (h "ok" t))
        (emit :action "tool" "pool-kill-worker")
        (emit :observation "tool" "pool-kill-worker" "result" (h "ok" t))
        (emit :action "tool" "load-system")
        (emit :observation "tool" "load-system" "result" (h "ok" t))
        (emit :action "tool" "run-tests")
        (emit :observation "tool" "run-tests"
              "result" (h "passed" 5 "failed" 0))))
    (let* ((world-model (cl-harness-next:build-world-model log-path))
           (view (cl-harness-next:compile-context world-model))
           (small (cl-harness-next:compile-context world-model
                                                   :token-budget 50)))
      (ok (cl-harness-next:clean-verified-p
           (cl-harness-next:world-model-projection world-model
                                                   :verification)))
      (ok (search "Fix evict" view))
      (ok (search "clean-verified: YES" view))
      (ok (search "[PROMOTED]" view))
      (ok (search "[STALE]" view))
      (ok (<= (cl-harness-next:estimate-tokens small) 50)))))

(defclass %sp4-tool-transport (cl-harness-next:mcp-transport)
  ()
  (:documentation "Tool-aware canned transport for the SP4 acceptance
test (facade symbols only)."))

(defmethod cl-harness-next:transport-send-request
    ((transport %sp4-tool-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id
               (concatenate 'string
                            "\"result\":{\"tools\":["
                            "{\"name\":\"pool-kill-worker\"},"
                            "{\"name\":\"load-system\"},"
                            "{\"name\":\"run-tests\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (if (equal tool "run-tests")
                     "{\"passed\":3,\"failed\":0}"
                     "{\"content\":[]}"))))
      (t (error "unexpected method ~S" method)))))

(deftest sp4-oracles-acceptance
  ;; SP4 acceptance: clean verification through the environment, the
  ;; consultation on the record, SP3 agreeing on cleanliness, the
  ;; invariant gate rejecting a skip, and a governor intervention
  ;; round-trip — all through the facade (spec §7/§11).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (cl-harness-next:open-event-log log-path))
           (environment (cl-harness-next:make-cl-mcp-environment
                         :client (cl-harness-next:make-mcp-client
                                  (make-instance '%sp4-tool-transport))
                         :condition :runtime-native
                         :event-log log))
           (oracle (make-instance 'cl-harness-next:verification-oracle
                                  :system "s" :test-system "s/tests"
                                  :mode :clean)))
      (ok (cl-harness-next:verdict-pass-p
           (cl-harness-next:consult oracle environment :event-log log)))
      (let ((world-model (cl-harness-next:build-world-model log-path)))
        (ok (cl-harness-next:clean-verified-p
             (cl-harness-next:world-model-projection world-model
                                                     :verification))))
      (ok (find :oracle-result
                (cl-harness-next:read-events log-path)
                :key #'cl-harness-next:event-type))
      (ok (not (cl-harness-next:verdict-pass-p
                (cl-harness-next:evaluate
                 (make-instance 'cl-harness-next:invariant-oracle)
                 "(deftest a (skip \"later\"))"))))
      (let ((governor (make-instance 'cl-harness-next:governor
                                     :max-actions 2)))
        (cl-harness-next:build-world-model
         log-path
         :world-model (cl-harness-next:make-world-model
                       :projections (list :governor governor)))
        (ok (eq :ask-human
                (handler-bind ((cl-harness-next:budget-exhausted
                                 (lambda (condition)
                                   (declare (ignore condition))
                                   (invoke-restart :ask-human))))
                  (cl-harness-next:check-governor governor))))))))

(deftest sp5a-provider-to-verdict-acceptance
  ;; SP5a acceptance: a stub LLM provider drives the review oracle to
  ;; a rejection verdict through the facade alone.
  (let* ((provider (cl-harness-next:make-openai-provider
                    :base-url "http://x/v1" :api-key "k" :model "m"
                    :transport
                    (lambda (url headers body)
                      (declare (ignore url headers body))
                      (values (concatenate
                               'string
                               "{\"choices\":[{\"message\":{\"role\":"
                               "\"assistant\",\"content\":"
                               "\"REJECT: thin tests\"},"
                               "\"finish_reason\":\"stop\"}]}")
                              200 (make-hash-table :test #'equal)))))
         (judge (cl-harness-next:make-judge-fn provider))
         (verdict (cl-harness-next:evaluate
                   (make-instance 'cl-harness-next:review-oracle
                                  :profile '(:id :review-tests
                                             :strictness :strict)
                                  :judge-fn judge)
                   "the tests")))
    (ok (not (cl-harness-next:verdict-pass-p verdict)))
    (ok (search "thin tests" (cl-harness-next:verdict-reason verdict)))))

(deftest real-llm-smoke
  ;; Opt-in (costs tokens): requires CL_HARNESS_LLM_SMOKE=1 plus the
  ;; CL_HARNESS_LLM_* endpoint variables.
  (let ((smoke (uiop:getenv "CL_HARNESS_LLM_SMOKE"))
        (base-url (uiop:getenv "CL_HARNESS_LLM_BASE_URL"))
        (api-key (uiop:getenv "CL_HARNESS_LLM_API_KEY"))
        (model (uiop:getenv "CL_HARNESS_LLM_MODEL")))
    (if (and (equal smoke "1") base-url api-key model)
        (let ((response (cl-harness-next:complete-chat
                         (cl-harness-next:make-openai-provider
                          :base-url base-url :api-key api-key
                          :model model :default-max-tokens 32)
                         (list (cl-harness-next:make-chat-message
                                "user" "Reply with exactly: PONG")))))
          (ok (stringp (cl-harness-next:chat-response-content response))))
        (ok t "skipped real-LLM smoke (set CL_HARNESS_LLM_SMOKE=1 + LLM env vars)"))))
