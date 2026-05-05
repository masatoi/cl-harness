;;;; src/agent.lisp
;;;;
;;;; PRD §8.4, §11.1, §11.2 — turn-based agent loop wiring together the
;;;; LLM provider, MCP client, tool policy, verifier, and JSONL logger
;;;; for the Phase 2 basic fix loop.
;;;;
;;;; The loop:
;;;;   1. set project root
;;;;   2. initial verify (load + run-tests)
;;;;   3. if already passing, return :passed without calling the LLM
;;;;   4. otherwise loop up to max-turns:
;;;;      a. ask LLM for next action
;;;;      b. parse JSON action; on parse error, feed error back to LLM
;;;;      c. on :finish, return :passed (fixed) or :give-up
;;;;      d. on :tool-call, gate by policy; invoke via MCP; on a
;;;;         source-mutating tool, auto-reverify; on success, return
;;;;         :passed early.
;;;;   5. when the budget runs out, return :max-turns.

(defpackage #:cl-harness/src/agent
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/config
                #:run-config-project-root
                #:run-config-system
                #:run-config-test-system
                #:run-config-issue
                #:run-config-limits
                #:run-limits-max-turns)
  (:import-from #:cl-harness/src/log
                #:log-event)
  (:import-from #:cl-harness/src/mcp
                #:call-tool)
  (:import-from #:cl-harness/src/model
                #:complete-chat
                #:make-chat-message
                #:chat-response-content
                #:chat-response-total-tokens)
  (:import-from #:cl-harness/src/action
                #:parse-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:action-parse-error
                #:action-parse-error-message)
  (:import-from #:cl-harness/src/policy
                #:policy-mode
                #:policy-allowed-tools
                #:allowed-tool-p)
  (:import-from #:cl-harness/src/verify
                #:verify-result-status
                #:verify-result-passed
                #:verify-result-failed
                #:verify-result-test
                #:verify-result-load
                #:verify-result-success-p
                #:verify-task
                #:clean-verify-task)
  (:export #:agent-state
           #:agent-state-turn
           #:agent-state-status
           #:agent-state-final-verify
           #:agent-state-final-action
           #:agent-state-token-total
           #:agent-state-patch-count
           #:run-agent
           #:format-final-report
           #:+source-mutating-tools+))

(in-package #:cl-harness/src/agent)

(defparameter +source-mutating-tools+
  '("lisp-patch-form" "lisp-edit-form")
  "Tools whose successful invocation should trigger an automatic verify.")

(defclass agent-state ()
  ((turn :initform 0 :accessor agent-state-turn)
   (status :initform :running :accessor agent-state-status)
   (final-verify :initform nil :accessor agent-state-final-verify)
   (final-action :initform nil :accessor agent-state-final-action)
   (token-total :initform 0 :accessor agent-state-token-total)
   (patch-count :initform 0 :accessor agent-state-patch-count))
  (:documentation "Live state of one fix-loop run (PRD §10.2 agent-state)."))

;; --- Stub ---------------------------------------------------------------

(defun system-prompt (policy)
  "Return the per-mode system prompt naming the JSON action schema, the
expected workflow, and the cl-mcp tools POLICY currently permits."
  (with-output-to-string (s)
    (format s "You are cl-harness, a coding agent fixing failing Common Lisp ~
tests by editing source files via cl-mcp tools.~%~%")
    (format s "Respond with exactly one JSON object per turn:~%")
    (format s "  {\"type\":\"tool_call\",\"tool\":\"<name>\",\"arguments\":{...}, \"thought\":\"...\"}~%")
    (format s "  {\"type\":\"finish\",\"status\":\"fixed\"|\"give_up\",\"summary\":\"...\"}~%~%")
    (format s "Workflow:~%")
    (case (policy-mode policy)
      (:runtime-native
       (format s "  1. PROBE first: use repl-eval / code-find / code-describe / inspect-object~%")
       (format s "     to understand the failing code before editing.~%")
       (format s "  2. PATCH: persist fixes via lisp-patch-form (small, scoped) or~%")
       (format s "     lisp-edit-form (whole-form replace/insert).~%")
       (format s "     IMPORTANT: repl-eval definitions are TRANSIENT — they vanish on worker~%")
       (format s "     restart. Always persist via lisp-{patch,edit}-form.~%")
       (format s "  3. VERIFY: source mutations auto-trigger load-system + run-tests; the verify~%")
       (format s "     summary is appended to the next user turn.~%")
       (format s "  4. FINISH: emit {\"type\":\"finish\",\"status\":\"fixed\"} only when run-tests~%")
       (format s "     reports zero failures. The harness then re-verifies on a fresh worker;~%")
       (format s "     a stale REPL state cannot fake success.~%~%"))
      (:generic-mcp
       (format s "  1. READ: use lisp-read-file (collapsed=true with name_pattern) to locate~%")
       (format s "     the failing definition.~%")
       (format s "  2. PATCH: persist fixes via lisp-patch-form (small, scoped) or~%")
       (format s "     lisp-edit-form (whole-form replace/insert).~%")
       (format s "  3. VERIFY: source mutations auto-trigger load-system + run-tests; the~%")
       (format s "     verify summary is appended to the next user turn.~%")
       (format s "  4. FINISH: emit {\"type\":\"finish\",\"status\":\"fixed\"} only when~%")
       (format s "     run-tests reports zero failures.~%~%"))
      (t
       (format s "  Use only the tools listed below; emit a finish action when done.~%~%")))
    (format s "Allowed tools (call them by exact name):~%")
    (dolist (tool (policy-allowed-tools policy))
      (format s "  - ~A~%" tool))))

(defun verify-summary (verify-result)
  "Return a short human-readable summary of VERIFY-RESULT."
  (with-output-to-string (s)
    (format s "status: ~A" (verify-result-status verify-result))
    (when (verify-result-passed verify-result)
      (format s ", passed: ~A" (verify-result-passed verify-result)))
    (when (verify-result-failed verify-result)
      (format s ", failed: ~A" (verify-result-failed verify-result)))))

(defun format-failed-tests (failed-tests &key (limit 5))
  "Render up to LIMIT failed-test descriptors as a human-readable list.

FAILED-TESTS may be a vector or list (yason's choice depends on its
*PARSE-JSON-ARRAYS-AS-VECTORS* flag). Each entry is a hash-table with
test_name / description / form / values / reason / source keys produced
by cl-mcp's run-tests tool."
  (with-output-to-string (s)
    (let ((seen 0))
      (block dump
        (map nil
             (lambda (ft)
               (when (>= seen limit)
                 (format s "  ... (output truncated)~%")
                 (return-from dump))
               (format s "  - ~A~@[: ~A~]~%"
                       (gethash "test_name" ft)
                       (gethash "description" ft))
               (let ((reason (gethash "reason" ft)))
                 (when (and (stringp reason) (plusp (length reason)))
                   (format s "    reason: ~A~%" reason)))
               (let ((form (gethash "form" ft)))
                 (when (and (stringp form) (plusp (length form)))
                   (format s "    form:   ~A~%" form)))
               (incf seen))
             failed-tests)))))

(defun initial-user-prompt (config verify-result)
  "Return the first USER message that gives the LLM the project context
and the initial verification snapshot."
  (with-output-to-string (s)
    (format s "Project root: ~A~%" (run-config-project-root config))
    (format s "ASDF system: ~A~%" (run-config-system config))
    (format s "Test system: ~A~%" (run-config-test-system config))
    (format s "Issue: ~A~%~%" (run-config-issue config))
    (format s "Initial verification: ~A~%" (verify-summary verify-result))
    (let* ((tr (verify-result-test verify-result))
           (failed (and tr (gethash "failed_tests" tr))))
      (when (and failed (or (and (vectorp failed) (plusp (length failed)))
                            (and (listp failed) failed)))
        (format s "~%Failing tests:~%~A"
                (format-failed-tests failed))))
    (when (eq :load-failed (verify-result-status verify-result))
      (let* ((lr (verify-result-load verify-result))
             (content (and lr (gethash "content" lr))))
        (format s "~%Load failure detail:~%~A~%"
                (or (when (and content (or (vectorp content) (listp content))
                               (plusp (length content)))
                      (let ((first (elt content 0)))
                        (and (hash-table-p first)
                             (gethash "text" first))))
                    "(no detail)"))))))

(defun tool-result-as-json (result)
  "Encode an MCP tools/call RESULT hash-table as a JSON string for the LLM."
  (with-output-to-string (s)
    (yason:encode (or result (make-hash-table :test 'equal)) s)))

(defun verify-event-payload (turn verify-result)
  "Return an alist describing VERIFY-RESULT for the JSONL transcript."
  `(("turn" . ,turn)
    ("status" . ,(string-downcase (symbol-name (verify-result-status verify-result))))
    ("passed" . ,(or (verify-result-passed verify-result) 0))
    ("failed" . ,(or (verify-result-failed verify-result) 0))))

(defun action-event-payload (turn action)
  "Return an alist describing ACTION for the JSONL transcript."
  (let ((base `(("turn" . ,turn)
                ("type" . ,(string-downcase
                            (symbol-name (agent-action-type action)))))))
    (case (agent-action-type action)
      (:tool-call
       (append base `(("tool" . ,(agent-action-tool action)))))
      (:finish
       (append base
               `(("status" . ,(string-downcase
                               (symbol-name (agent-action-status action))))
                 ("summary" . ,(or (agent-action-summary action) ""))))))))

(defun finalize (state status &key verify action)
  "Stamp STATE's terminal fields and return STATE."
  (setf (agent-state-status state) status)
  (when verify (setf (agent-state-final-verify state) verify))
  (when action (setf (agent-state-final-action state) action))
  state)

(defun finalize-passed (state mcp-client config logger
                        incremental-verify action)
  "Confirm a :PASSED outcome via CLEAN-VERIFY-TASK on a fresh worker.

When the clean reload also reports zero failures STATE's status stays
:PASSED. Otherwise the agent reports :DIRTY-ONLY so the caller knows the
incremental success did not survive a fresh image (PRD §8.9
REQ-VERIFY-002, REQ-VERIFY-003)."
  (let ((clean (clean-verify-task mcp-client config)))
    (log-event logger :clean-verify (verify-event-payload -1 clean))
    (cond
      ((verify-result-success-p clean)
       (finalize state :passed :verify clean :action action))
      (t
       (log-event logger :dirty-only
                  `(("incremental_status"
                     . ,(string-downcase
                         (symbol-name
                          (verify-result-status incremental-verify))))
                    ("clean_status"
                     . ,(string-downcase
                         (symbol-name (verify-result-status clean))))))
       (finalize state :dirty-only :verify clean :action action)))))

(defun append-message (messages role content)
  "Return MESSAGES with a freshly constructed MESSAGE appended."
  (append messages (list (make-chat-message role content))))

(defun handle-finish-action (action)
  "Map a :FINISH ACTION to the agent's terminal status keyword."
  (case (agent-action-status action)
    (:fixed :passed)
    (:give-up :give-up)))

(defun handle-tool-call (turn state config mcp-client policy logger
                         messages action)
  "Dispatch a :TOOL-CALL ACTION via MCP-CLIENT, optionally auto-verifying.
Returns (values NEW-MESSAGES OUTCOME VERIFY ACTION). OUTCOME is NIL when
the loop should continue, or a terminal status keyword."
  (let ((tool (agent-action-tool action)))
    (cond
      ((not (allowed-tool-p policy tool))
       (log-event logger :denied
                  `(("turn" . ,turn) ("tool" . ,tool)
                    ("policy" . ,(string-downcase
                                  (symbol-name (policy-mode policy))))))
       (values
        (append-message messages "user"
                        (format nil "Tool ~A is not permitted in mode ~A. Choose another tool."
                                tool (policy-mode policy)))
        nil nil nil))
      (t
       (let ((result (call-tool mcp-client tool
                                (or (agent-action-arguments action)
                                    (make-hash-table :test 'equal)))))
         (log-event logger :tool-result
                    `(("turn" . ,turn) ("tool" . ,tool)
                      ("is_error" . ,(and (gethash "isError" result) t))))
         (let ((next (append-message
                      messages "user"
                      (format nil "Tool ~A result:~%~A"
                              tool (tool-result-as-json result)))))
           (cond
             ((member tool +source-mutating-tools+ :test #'equal)
              (incf (agent-state-patch-count state))
              (let ((v (verify-task mcp-client config)))
                (log-event logger :verify (verify-event-payload turn v))
                (if (verify-result-success-p v)
                    (values next :passed v action)
                    (values (append-message
                             next "user"
                             (format nil "Verify after patch: ~A"
                                     (verify-summary v)))
                            nil nil nil))))
             (t (values next nil nil nil)))))))))

(defun step-turn (turn state config provider mcp-client policy logger messages)
  "Run one turn of the agent loop.

Returns (values NEW-MESSAGES OUTCOME VERIFY ACTION). OUTCOME is NIL when
the loop should continue, otherwise a terminal status keyword
(:PASSED / :GIVE-UP)."
  (let* ((chat (complete-chat provider messages))
         (text (chat-response-content chat)))
    (incf (agent-state-token-total state)
          (or (chat-response-total-tokens chat) 0))
    (log-event logger :llm-response
               `(("turn" . ,turn) ("content" . ,text)))
    (handler-case
        (let ((action (parse-action text)))
          (log-event logger :action (action-event-payload turn action))
          (let ((with-assistant (append-message messages "assistant" text)))
            (case (agent-action-type action)
              (:finish
               (values with-assistant
                       (handle-finish-action action)
                       nil action))
              (:tool-call
               (handle-tool-call turn state config mcp-client policy logger
                                 with-assistant action)))))
      (action-parse-error (c)
        (log-event logger :action-error
                   `(("turn" . ,turn)
                     ("message" . ,(action-parse-error-message c))))
        (values
         (append-message
          (append-message messages "assistant" text)
          "user"
          (format nil "Could not parse your previous reply: ~A. Respond with one JSON object matching the schema."
                  (action-parse-error-message c)))
         nil nil nil)))))

(defun run-agent (config provider mcp-client policy logger)
  "Execute the basic Phase 2 fix loop with a Phase 3 clean-verify safety net.

CONFIG is a RUN-CONFIG. PROVIDER is an OPENAI-COMPATIBLE-PROVIDER (or any
class with a COMPLETE-CHAT method). MCP-CLIENT must already be
initialize-mcp'd. POLICY is the TOOL-POLICY restricting tool calls.
LOGGER is an open RUN-LOGGER.

Every :PASSED outcome (initial verify, auto-reverify after a patch, or
LLM :finish :fixed) is reconfirmed via CLEAN-VERIFY-TASK on a fresh
worker; failure of the clean reload downgrades the run to :DIRTY-ONLY."
  (let ((state (make-instance 'agent-state)))
    (call-tool mcp-client "fs-set-project-root"
               (alist-hash-table
                `(("path" . ,(princ-to-string
                              (run-config-project-root config))))
                :test 'equal))
    (log-event logger :run-start
               `(("project_root" . ,(princ-to-string
                                     (run-config-project-root config)))
                 ("system" . ,(run-config-system config))
                 ("test_system" . ,(run-config-test-system config))
                 ("issue" . ,(run-config-issue config))
                 ("policy" . ,(string-downcase
                               (symbol-name (policy-mode policy))))))
    (let ((initial (verify-task mcp-client config)))
      (log-event logger :verify (verify-event-payload 0 initial))
      (when (verify-result-success-p initial)
        (return-from run-agent
          (finalize-passed state mcp-client config logger initial nil)))
      (let ((messages (list (make-chat-message "system" (system-prompt policy))
                            (make-chat-message
                             "user" (initial-user-prompt config initial)))))
        (loop with max-turns = (run-limits-max-turns
                                (run-config-limits config))
              for turn from 1 to max-turns
              do (setf (agent-state-turn state) turn)
                 (multiple-value-bind (next-messages outcome verify action)
                     (step-turn turn state config provider mcp-client
                                policy logger messages)
                   (cond
                     (outcome
                      (return-from run-agent
                        (case outcome
                          (:passed
                           (finalize-passed state mcp-client config logger
                                            verify action))
                          (:give-up
                           (finalize state :give-up :action action)))))
                     (t (setf messages next-messages))))
              finally (return (finalize state :max-turns)))))))

(defun format-final-report (state &key log-path)
  "Return a one-paragraph human-readable summary of STATE.

Surfaces the terminal status, turns consumed, patches applied, total
chat tokens, the final verify snapshot, and (optionally) the JSONL
transcript path. Used by the CLI to print a closing report."
  (with-output-to-string (s)
    (format s "== cl-harness fix report ==~%")
    (format s "Status:           ~S~%" (agent-state-status state))
    (format s "Turns:            ~D~%" (agent-state-turn state))
    (format s "Patches applied:  ~D~%" (agent-state-patch-count state))
    (format s "Chat tokens:      ~D~%" (agent-state-token-total state))
    (let ((v (agent-state-final-verify state)))
      (if v
          (format s "Final verify:     status ~S, passed ~A, failed ~A~%"
                  (verify-result-status v)
                  (or (verify-result-passed v) "?")
                  (or (verify-result-failed v) "?"))
          (format s "Final verify:     (none)~%")))
    (when log-path
      (format s "Transcript:       ~A~%" log-path))))
