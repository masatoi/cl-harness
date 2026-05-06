;;;; src/explore.lisp
;;;;
;;;; v0.4 Phase 3 of the development harness extension. Read-only
;;;; exploration sub-agent: given a plan-step whose
;;;; NEEDS-EXPLORATION level is :LIGHTWEIGHT or :DEEP, run a small
;;;; LLM-driven loop with a write-tool-denied policy and capture the
;;;; LLM's findings as a single memo string. The orchestrator then
;;;; prepends that memo to the implement run-agent's issue so the
;;;; executor inherits the prior knowledge.
;;;;
;;;; Why a separate function rather than reusing RUN-AGENT: the fix
;;;; loop's terminal condition is "rove tests pass". For exploration
;;;; there's no test to grade against — the loop ends when the LLM
;;;; emits a `finish` action whose `summary` is the memo, or when the
;;;; turn budget runs out. The agent contract differs enough that
;;;; sharing code would muddy both paths; the duplication here is
;;;; small and shaped for what explore actually needs.

(defpackage #:cl-harness/src/explore
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/log
                #:log-event)
  (:import-from #:cl-harness/src/config
                #:run-config-project-root
                #:run-config-system
                #:run-config-test-system)
  (:import-from #:cl-harness/src/mcp
                #:call-tool
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message)
  (:import-from #:cl-harness/src/model
                #:complete-chat
                #:chat-response-content
                #:chat-response-total-tokens)
  (:import-from #:cl-harness/src/action
                #:parse-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-summary
                #:action-parse-error
                #:action-parse-error-message)
  (:import-from #:cl-harness/src/policy
                #:policy-allowed-tools
                #:allowed-tool-p)
  (:import-from #:cl-harness/src/planner
                #:plan-step-issue
                #:plan-step-investigation-targets
                #:plan-step-needs-exploration
                #:investigation-target-kind
                #:investigation-target-name
                #:investigation-target-intent)
  (:export #:explore-result
           #:explore-result-status
           #:explore-result-memo
           #:explore-result-turns
           #:explore-result-token-total
           #:run-explore-agent
           #:explore-system-prompt))

(in-package #:cl-harness/src/explore)

(defclass explore-result ()
  ((status :initarg :status :reader explore-result-status)
   (memo :initarg :memo :initform "" :reader explore-result-memo)
   (turns :initarg :turns :initform 0 :reader explore-result-turns)
   (token-total :initarg :token-total :initform 0
                :reader explore-result-token-total))
  (:documentation
   "Outcome of one RUN-EXPLORE-AGENT call. STATUS is :REPORTED on a
clean finish, :LIMIT-EXHAUSTED when MAX-TURNS ran out before the
agent emitted finish, :GIVE-UP when the agent itself signalled
give_up. MEMO is the summary string the LLM emitted (empty on
limit-exhausted)."))

(defun %format-targets (plan-step)
  "Render PLAN-STEP's investigation_targets as a bullet list, or NIL
when the step has no targets."
  (let ((ts (and plan-step (plan-step-investigation-targets plan-step))))
    (when ts
      (with-output-to-string (s)
        (format s "Investigation targets supplied by the planner:~%")
        (dolist (target ts)
          (format s "  - [~A] ~A — ~A~%"
                  (string-downcase
                   (symbol-name (investigation-target-kind target)))
                  (investigation-target-name target)
                  (or (investigation-target-intent target) "")))))))

(defun explore-system-prompt (policy &key plan-step)
  "Return the system prompt for RUN-EXPLORE-AGENT bound to POLICY.

Mirrors the shape of agent.lisp:SYSTEM-PROMPT but for read-only
exploration: tells the LLM the loop is observe-only, lists the
allowed tools, and instructs it to terminate with a `finish`
action whose `summary` becomes the exploration memo. PLAN-STEP,
when provided, is referenced so the prompt can mention the depth
expectation (lightweight vs deep)."
  (declare (ignorable plan-step))
  (with-output-to-string (s)
    (format s "You are cl-harness's exploration sub-agent. Your goal is to ~%")
    (format s "investigate an existing Common Lisp project and report back ~%")
    (format s "with a one-paragraph memo of what you found.~%~%")
    (format s "Respond with exactly one JSON object per turn:~%")
    (format s "  {\"type\":\"tool_call\",\"tool\":\"<name>\",\"arguments\":{...},\"thought\":\"...\"}~%")
    (format s "  {\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"<your memo>\"}~%~%")
    (format s "Workflow:~%")
    (format s "  1. INSPECT existing files / packages / runtime state with the read-only tools~%")
    (format s "     listed below.~%")
    (format s "  2. Where useful, run small repl-eval experiments. repl-eval definitions are~%")
    (format s "     TRANSIENT and will be discarded after this loop — they are scratch space,~%")
    (format s "     never the final answer.~%")
    (format s "  3. STOP and emit `finish` as soon as you have enough to write the memo. Do~%")
    (format s "     NOT exhaust the turn budget chasing exhaustive coverage.~%~%")
    (format s "The memo (the `summary` field on your finish action) should:~%")
    (format s "  - name the existing functions / classes / packages that touch this work,~%")
    (format s "  - list abstractions you ADOPT (use as-is) and ones you REJECT or DEFER,~%")
    (format s "  - call out surprises (unexpected naming, hidden dependencies, missing exports).~%~%")
    (format s "At the END of the memo, on their own lines, record each abstraction~%")
    (format s "decision in this exact shape so the harness's ledger can capture them:~%~%")
    (format s "  ADOPTED:  <name> — <one-line rationale>~%")
    (format s "  REJECTED: <name> — <one-line rationale>~%")
    (format s "  DEFERRED: <name> — <one-line rationale>~%~%")
    (format s "Use \"(none)\" as the name if a category has nothing to record (e.g.~%")
    (format s "`ADOPTED: (none)`); the harness ignores those.~%~%")
    (format s "RULES:~%")
    (format s "  - This loop is READ-ONLY. The policy below denies every write tool — do not~%")
    (format s "    propose lisp-edit-form, lisp-patch-form, or fs-write-file.~%")
    (format s "  - Keep the memo dense (3 to 6 sentences). The implement step that runs after~%")
    (format s "    you sees the memo verbatim, so trim filler.~%~%")
    (format s "Allowed tools (call them by exact name):~%")
    (dolist (tool (policy-allowed-tools policy))
      (format s "  - ~A~%" tool))))

(defun %initial-explore-user-prompt (config plan-step)
  "Build the first user-side message for the explore loop. Includes
the issue (so the explorer knows the WHY) and any planner-supplied
investigation_targets."
  (with-output-to-string (s)
    (format s "Project root: ~A~%"
            (run-config-project-root config))
    (when (run-config-system config)
      (format s "System: ~A~%" (run-config-system config)))
    (when (run-config-test-system config)
      (format s "Test system: ~A~%" (run-config-test-system config)))
    (when plan-step
      (format s "~%Issue (the implement step that follows you):~%~A~%"
              (plan-step-issue plan-step)))
    (let ((targets-text (%format-targets plan-step)))
      (when targets-text
        (format s "~%~A" targets-text)))
    (format s "~%Begin exploration. End with a finish action whose summary is the memo.~%")))

(defun %append-message (messages role content)
  (append messages
          (list (alist-hash-table
                 `(("role" . ,role) ("content" . ,content))
                 :test 'equal))))

(defun %is-error (result)
  (let ((flag (and (hash-table-p result) (gethash "isError" result))))
    (or (eq flag t) (eq flag :true))))

(defun %brief-result (result)
  "One-line summary of a tool result for the LLM history."
  (cond
    ((null result) "(no result)")
    ((not (hash-table-p result)) (format nil "~A" result))
    (t
     (let* ((content (gethash "content" result))
            (text (and content
                       (or (vectorp content) (listp content))
                       (plusp (length content))
                       (let ((first (elt content 0)))
                         (and (hash-table-p first) (gethash "text" first))))))
       (cond
         ((%is-error result)
          (format nil "ERROR: ~A"
                  (or (and text (subseq text 0 (min 200 (length text))))
                      "(no message)")))
         (text (subseq text 0 (min 600 (length text))))
         (t (with-output-to-string (s) (yason:encode result s))))))))

(defun run-explore-agent (config provider mcp-client policy logger
                          &key (max-turns 8)
                               plan-step)
  "Run a read-only exploration loop and return an EXPLORE-RESULT.

CONFIG is a RUN-CONFIG (used only for project-root / system /
test-system orientation). PROVIDER and MCP-CLIENT are the same
shapes RUN-AGENT consumes. POLICY must be a tool-policy whose mode
is :EXPLORE — passing anything else still works mechanically but
defeats the read-only invariant.

LOGGER receives :explore-start / :explore-llm-response /
:explore-tool-call / :explore-tool-result / :explore-action-error /
:explore-end events so a develop transcript captures the loop in
parallel with the implement loop's events.

PLAN-STEP, when supplied, is consulted for INVESTIGATION-TARGETS
to seed the initial user prompt, and for the issue paragraph to
explain WHY the exploration is happening.

MAX-TURNS caps the loop. The agent is asked to finish well before
that (3-6 sentence memo); MAX-TURNS just bounds the worst case."
  (check-type max-turns (integer 1))
  (log-event logger :explore-start
             (alist-hash-table
              `(("project_root" . ,(princ-to-string
                                    (run-config-project-root config)))
                ("system" . ,(or (run-config-system config) ""))
                ("needs_exploration"
                 . ,(string-downcase
                     (symbol-name
                      (or (and plan-step (plan-step-needs-exploration plan-step))
                          :none)))))
              :test 'equal))
  (let ((messages (list (alist-hash-table
                         `(("role" . "system")
                           ("content" . ,(explore-system-prompt
                                          policy :plan-step plan-step)))
                         :test 'equal)
                        (alist-hash-table
                         `(("role" . "user")
                           ("content" . ,(%initial-explore-user-prompt
                                          config plan-step)))
                         :test 'equal)))
        (token-total 0)
        (final-status :limit-exhausted)
        (final-memo "")
        (final-turn 0))
    (block run-loop
      (loop for turn from 1 to max-turns
            do (setf final-turn turn)
               (let* ((response (complete-chat provider messages))
                      (text (chat-response-content response))
                      (tt (chat-response-total-tokens response)))
                 (when tt (incf token-total tt))
                 (log-event logger :explore-llm-response
                            (alist-hash-table
                             `(("turn" . ,turn)
                               ("tokens" . ,(or tt 0))
                               ("content" . ,(or text ""))) :test 'equal))
                 (handler-case
                     (let ((action (parse-action (or text ""))))
                       (case (agent-action-type action)
                         (:finish
                          (setf final-status :reported
                                final-memo (or (agent-action-summary action) ""))
                          (return-from run-loop))
                         (:tool-call
                          (let ((tool (agent-action-tool action))
                                (args (or (agent-action-arguments action)
                                          (make-hash-table :test 'equal))))
                            (cond
                              ((not (allowed-tool-p policy tool))
                               (log-event
                                logger :explore-action-error
                                (alist-hash-table
                                 `(("turn" . ,turn)
                                   ("message"
                                    . ,(format nil "policy denied tool ~A"
                                               tool)))
                                 :test 'equal))
                               (setf messages
                                     (%append-message
                                      messages "user"
                                      (format nil
                                              "Tool ~A is not allowed in :explore policy. Try a read-only tool from the allowed list."
                                              tool))))
                              (t
                               (log-event logger :explore-tool-call
                                          (alist-hash-table
                                           `(("turn" . ,turn) ("tool" . ,tool))
                                           :test 'equal))
                               (let ((result
                                      (handler-case
                                          (call-tool mcp-client tool args)
                                        (mcp-error (c)
                                          (alist-hash-table
                                           `(("isError" . t)
                                             ("content"
                                              . ,(vector
                                                  (alist-hash-table
                                                   `(("type" . "text")
                                                     ("text"
                                                      . ,(format nil
                                                                 "MCP error ~A: ~A"
                                                                 (mcp-error-code c)
                                                                 (mcp-error-message c))))
                                                   :test 'equal))))
                                           :test 'equal)))))
                                 (log-event logger :explore-tool-result
                                            (alist-hash-table
                                             `(("turn" . ,turn)
                                               ("tool" . ,tool)
                                               ("is_error" . ,(%is-error result)))
                                             :test 'equal))
                                 (setf messages
                                       (%append-message
                                        messages "assistant" (or text "")))
                                 (setf messages
                                       (%append-message
                                        messages "user"
                                        (format nil "Tool ~A result:~%~A"
                                                tool (%brief-result result)))))))))))
                   (action-parse-error (c)
                     (log-event logger :explore-action-error
                                (alist-hash-table
                                 `(("turn" . ,turn)
                                   ("message"
                                    . ,(action-parse-error-message c)))
                                 :test 'equal))
                     (setf messages
                           (%append-message
                            messages "assistant" (or text "")))
                     (setf messages
                           (%append-message
                            messages "user"
                            (format nil
                                    "Could not parse your previous reply: ~A. Respond with one JSON object matching the schema."
                                    (action-parse-error-message c)))))))))
    (log-event logger :explore-end
               (alist-hash-table
                `(("status" . ,(string-downcase (symbol-name final-status)))
                  ("turns" . ,final-turn)
                  ("token_total" . ,token-total)
                  ("memo" . ,final-memo))
                :test 'equal))
    (make-instance 'explore-result
                   :status final-status
                   :memo final-memo
                   :turns final-turn
                   :token-total token-total)))
