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
                          :model model :max-tokens 32)
                         (list (cl-harness-next:make-chat-message
                                "user" "Reply with exactly: PONG")))))
          (ok (stringp (cl-harness-next:chat-response-content response))))
        (ok t "skipped real-LLM smoke (set CL_HARNESS_LLM_SMOKE=1 + LLM env vars)"))))

(defclass %sp5b-fix-transport (cl-harness-next:mcp-transport)
  ((fixed-p :initform nil :accessor %sp5b-fixed-p)))

(defmethod cl-harness-next:transport-send-request
    ((transport %sp5b-fix-transport) body)
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
                            "{\"name\":\"run-tests\"},"
                            "{\"name\":\"lisp-edit-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ((equal tool "lisp-edit-form")
                    (setf (%sp5b-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (%sp5b-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(deftest sp5b-scripted-loop-acceptance
  ;; SP5 capstone: a (stub) LLM provider drives the scripted policy
  ;; through the kernel over a real environment — red, one patch,
  ;; green, clean-verified — entirely through the facade.
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((patch-json
             (concatenate 'string
                          "{\"type\":\"tool_call\","
                          "\"tool\":\"lisp-edit-form\","
                          "\"arguments\":{\"file_path\":\"a.lisp\","
                          "\"content\":\"(defun f () 1)\"}}"))
           (provider
             (cl-harness-next:make-openai-provider
              :base-url "http://x/v1" :api-key "k" :model "m"
              :transport
              (lambda (url headers body)
                (declare (ignore url headers body))
                (values (with-output-to-string (out)
                          (yason:encode
                           (alexandria:plist-hash-table
                            (list "choices"
                                  (list (alexandria:plist-hash-table
                                         (list "message"
                                               (alexandria:plist-hash-table
                                                (list "role" "assistant"
                                                      "content" patch-json)
                                                :test #'equal)
                                               "finish_reason" "stop")
                                         :test #'equal)))
                            :test #'equal)
                           out))
                        200 (make-hash-table :test #'equal)))))
           (log (cl-harness-next:open-event-log log-path))
           (environment (cl-harness-next:make-cl-mcp-environment
                         :client (cl-harness-next:make-mcp-client
                                  (make-instance '%sp5b-fix-transport))
                         :condition :runtime-native
                         :event-log log))
           (kernel (cl-harness-next:make-kernel
                    :environment environment
                    :event-log log
                    :policy (make-instance
                             'cl-harness-next:scripted-fix-policy
                             :system "s" :test-system "s/tests"
                             :diagnose-fn
                             (cl-harness-next:make-judge-fn
                              provider
                              :system-prompt
                              cl-harness-next:+scripted-fix-system-prompt+)))))
      (multiple-value-bind (status reason)
          (cl-harness-next:run-kernel kernel)
        (ok (eq :done status))
        (ok (search "clean" reason)))
      (ok (cl-harness-next:clean-verified-p
           (cl-harness-next:world-model-projection
            (cl-harness-next:kernel-world-model kernel)
            :verification))))))

(defclass %sp6-stall-transport (cl-harness-next:mcp-transport)
  ((fixed-p :initform nil :accessor %sp6-fixed-p)))

(defmethod cl-harness-next:transport-send-request
    ((transport %sp6-stall-transport) body)
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
                            "{\"name\":\"run-tests\"},"
                            "{\"name\":\"lisp-edit-form\"},"
                            "{\"name\":\"lisp-patch-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ((equal tool "lisp-edit-form")
                    "{\"isError\":true,\"content\":[]}")
                   ((equal tool "lisp-patch-form")
                    (setf (%sp6-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (%sp6-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(deftest sp6-adaptive-dial-acceptance
  ;; SP6 capstone: a self-directed level stalls on failing patches,
  ;; the adaptive dial demotes to scripted (same world model), which
  ;; fixes and clean-verifies — entirely through the facade.
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((edit-json
             (concatenate 'string
                          "{\"type\":\"tool_call\","
                          "\"tool\":\"lisp-edit-form\","
                          "\"arguments\":{\"file_path\":\"a.lisp\","
                          "\"content\":\"x\"}}"))
           (patch-json
             (concatenate 'string
                          "{\"type\":\"tool_call\","
                          "\"tool\":\"lisp-patch-form\","
                          "\"arguments\":{\"file_path\":\"a.lisp\","
                          "\"old_text\":\"a\",\"new_text\":\"b\"}}"))
           (log (cl-harness-next:open-event-log log-path))
           (environment (cl-harness-next:make-cl-mcp-environment
                         :client (cl-harness-next:make-mcp-client
                                  (make-instance '%sp6-stall-transport))
                         :condition :runtime-native
                         :event-log log))
           (kernel (cl-harness-next:make-kernel
                    :environment environment
                    :event-log log
                    :governor (make-instance
                               'cl-harness-next:governor
                               :max-consecutive-failed-patches 2)
                    :policy (make-instance
                             'cl-harness-next:adaptive-policy
                             :levels
                             (list (make-instance
                                    'cl-harness-next:self-directed-policy
                                    :system "s" :test-system "s/tests"
                                    :step-fn (lambda (prompt)
                                               (declare (ignore prompt))
                                               edit-json))
                                   (make-instance
                                    'cl-harness-next:scripted-fix-policy
                                    :system "s" :test-system "s/tests"
                                    :diagnose-fn
                                    (lambda (view)
                                      (declare (ignore view))
                                      patch-json)))))))
      (multiple-value-bind (status reason)
          (cl-harness-next:run-kernel kernel)
        (ok (eq :done status))
        (ok (search "clean" reason)))
      (ok (cl-harness-next:clean-verified-p
           (cl-harness-next:world-model-projection
            (cl-harness-next:kernel-world-model kernel)
            :verification))))))

(deftest sp7-mission-queue-acceptance
  ;; SP7 capstone: two missions in a queue — one completes, one parks
  ;; on budget exhaustion with a human request; the human resolves and
  ;; resumes it with a raised envelope; both end :done. All through
  ;; the facade; resume rebuilds everything from the mission's log.
  (uiop:with-temporary-file (:pathname log-1 :type "jsonl")
    (uiop:with-temporary-file (:pathname log-2 :type "jsonl")
      (uiop:delete-file-if-exists log-1)
      (uiop:delete-file-if-exists log-2)
      (let* ((patch-json
               (concatenate 'string
                            "{\"type\":\"tool_call\","
                            "\"tool\":\"lisp-edit-form\","
                            "\"arguments\":{\"file_path\":\"a.lisp\","
                            "\"content\":\"fix\"}}"))
             (environment-factory
               (lambda (mission log)
                 (declare (ignore mission))
                 (cl-harness-next:make-cl-mcp-environment
                  :client (cl-harness-next:make-mcp-client
                           (make-instance '%sp5b-fix-transport))
                  :condition :runtime-native
                  :event-log log)))
             (policy-factory
               (lambda (mission)
                 (declare (ignore mission))
                 (make-instance 'cl-harness-next:scripted-fix-policy
                                :system "s" :test-system "s/tests"
                                :diagnose-fn (lambda (view)
                                               (declare (ignore view))
                                               patch-json))))
             (queue (make-instance 'cl-harness-next:mission-queue))
             (m1 (make-instance 'cl-harness-next:mission
                                :id "m1" :goal "fix one"
                                :log-path log-1))
             (m2 (make-instance 'cl-harness-next:mission
                                :id "m2" :goal "fix two"
                                :log-path log-2)))
        (cl-harness-next:enqueue-mission queue m1)
        (cl-harness-next:enqueue-mission queue m2)
        (ok (eq :done (cl-harness-next:run-mission
                       m1 queue
                       :environment-factory environment-factory
                       :policy-factory policy-factory)))
        (ok (eq :parked (cl-harness-next:run-mission
                         m2 queue
                         :environment-factory environment-factory
                         :policy-factory policy-factory
                         :governor-factory
                         (lambda (mission)
                           (declare (ignore mission))
                           (make-instance 'cl-harness-next:governor
                                          :max-actions 2)))))
        (let ((request (first (cl-harness-next:pending-human-requests
                               queue))))
          (ok request)
          (cl-harness-next:resolve-human-request queue request
                                                 :response "raise"))
        (ok (eq :done (cl-harness-next:run-mission
                       m2 queue
                       :environment-factory environment-factory
                       :policy-factory policy-factory
                       :governor-factory
                       (lambda (mission)
                         (declare (ignore mission))
                         (make-instance 'cl-harness-next:governor
                                        :max-actions 50)))))
        (ok (eq :done (cl-harness-next:mission-status m2)))
        (ok (null (cl-harness-next:pending-human-requests queue)))))))

(deftest sp8-self-improvement-acceptance
  ;; SP8 capstone: one full improve-once cycle through the facade —
  ;; mine a real transcript, accept a (canned) LLM budget variant,
  ;; win the paired trials, promote with an audit event.
  (uiop:with-temporary-file (:pathname pack-path :type "sexp")
    (uiop:with-temporary-file (:pathname transcript-path :type "jsonl")
      (uiop:with-temporary-file (:pathname audit-path :type "jsonl")
        (uiop:delete-file-if-exists transcript-path)
        (uiop:delete-file-if-exists audit-path)
        (with-open-file (out pack-path :direction :output
                                       :if-exists :supersede
                                       :external-format :utf-8)
          (write-string
           "(:name \"active\" :version \"1.0.0\"
             :budgets ((:id :max-actions :value 10)))"
           out))
        (let ((log (cl-harness-next:open-event-log transcript-path))
              (champion (cl-harness-next:load-policy-pack pack-path)))
          (cl-harness-next:emit-event
           log :action (alexandria:plist-hash-table
                        (list "tool" "lisp-edit-form") :test #'equal))
          (cl-harness-next:emit-event
           log :observation
           (alexandria:plist-hash-table
            (list "tool" "lisp-edit-form"
                  "error" "form not found")
            :test #'equal))
          (multiple-value-bind (outcome challenger)
              (cl-harness-next:improve-once
               :champion champion
               :transcripts (list transcript-path)
               :propose-fn
               (lambda (prompt)
                 (declare (ignore prompt))
                 (concatenate 'string
                              "{\"kind\":\"budget\","
                              "\"target\":\"max-actions\","
                              "\"value\":30,"
                              "\"hypothesis\":\"verify costs 3\"}"))
               :trial-fn
               (lambda (pack index)
                 (cl-harness-next/src/bench:make-trial
                  :index index
                  :pack-fingerprint
                  (cl-harness-next:pack-fingerprint pack)
                  :success-p (= 30 (cl-harness-next:pack-budget
                                    pack :max-actions))
                  :actions 9))
               :pack-directory (uiop:pathname-directory-pathname
                                pack-path)
               :audit-log (cl-harness-next:open-event-log audit-path)
               :trials 3)
            (ok (eq :promoted outcome))
            (ok (= 30 (cl-harness-next:pack-budget challenger
                                                   :max-actions)))
            (ok (find-if
                 (lambda (event)
                   (and (eq :decision (cl-harness-next:event-type
                                       event))
                        (equal "promotion"
                               (gethash "kind"
                                        (cl-harness-next:event-payload
                                         event)))))
                 (cl-harness-next:read-events audit-path)))))))))
