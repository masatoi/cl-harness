;;;; src/config.lisp
;;;;
;;;; PRD §10.2 run-config: a single immutable record describing one fix-task
;;;; invocation (project, system, issue, condition mode, limits).

(defpackage #:cl-harness/src/config
  (:use #:cl)
  (:export #:run-config
           #:make-run-config
           #:run-config-project-root
           #:run-config-system
           #:run-config-test-system
           #:run-config-issue
           #:run-config-condition
           #:run-config-limits
           #:run-limits
           #:make-default-limits
           #:run-limits-max-turns
           #:run-limits-max-tool-calls
           #:run-limits-max-patches
           #:run-limits-max-read-files
           #:run-limits-max-repl-evals
           #:run-limits-max-wall-clock-seconds
           #:run-limits-max-action-parse-errors
           #:run-limits-max-context-tokens
           #:run-config-log-llm-requests-p))

(in-package #:cl-harness/src/config)

(defclass run-limits ()
  ((max-turns :initarg :max-turns :reader run-limits-max-turns)
   (max-tool-calls :initarg :max-tool-calls :reader run-limits-max-tool-calls)
   (max-patches :initarg :max-patches :reader run-limits-max-patches)
   (max-read-files :initarg :max-read-files :reader run-limits-max-read-files)
   (max-repl-evals :initarg :max-repl-evals :reader run-limits-max-repl-evals)
   (max-wall-clock-seconds
    :initarg :max-wall-clock-seconds
    :reader run-limits-max-wall-clock-seconds)
   (max-action-parse-errors
    :initarg :max-action-parse-errors
    :initform 3
    :reader run-limits-max-action-parse-errors
    :documentation "Consecutive ACTION-PARSE-ERRORs tolerated before
RUN-AGENT exits :limit-exhausted with limit-hit :max-action-parse-errors.
Resets to zero on any successful PARSE-ACTION.")
   (max-context-tokens
    :initarg :max-context-tokens
    :initform 50000
    :reader run-limits-max-context-tokens
    :documentation "Approximate token budget for the agent loop's
message history. When the running estimate of APPROXIMATE-HISTORY-TOKENS over MESSAGES
exceeds this, the agent calls COMPACT-HISTORY before the next
COMPLETE-CHAT call. The threshold is approximate (chars / 4 heuristic);
fine-grained accuracy is not required because the goal is keeping the
context window from blowing, not minimising tokens."))
  (:documentation "Resource budget for a single fix run (PRD §8.4 REQ-AGENT-003)."))

(defun make-default-limits ()
  "Return a RUN-LIMITS object populated with conservative MVP defaults."
  (make-instance 'run-limits
                 :max-turns 20
                 :max-tool-calls 80
                 :max-patches 5
                 :max-read-files 40
                 :max-repl-evals 40
                 :max-wall-clock-seconds 600
                 :max-action-parse-errors 3
                 :max-context-tokens 50000))

(defclass run-config ()
  ((project-root :initarg :project-root :reader run-config-project-root)
   (system :initarg :system :reader run-config-system)
   (test-system :initarg :test-system :reader run-config-test-system)
   (issue :initarg :issue :reader run-config-issue)
   (condition :initarg :condition :reader run-config-condition)
   (limits :initarg :limits :reader run-config-limits)
   (log-llm-requests-p :initarg :log-llm-requests
                       :initform nil
                       :reader run-config-log-llm-requests-p
                       :documentation "When true, the agent loop emits a
:llm-request event before each COMPLETE-CHAT call, recording the full
chat history. Opt-in because the payload may contain sensitive context.
Default NIL."))
  (:documentation
   "Inputs to one cl-harness fix invocation. CONDITION is one of
:FILE-ONLY, :GENERIC-MCP, or :RUNTIME-NATIVE (PRD §8.5)."))

(defun make-run-config (&key project-root system test-system issue
                            (condition :runtime-native)
                            (limits (make-default-limits))
                            (log-llm-requests nil))
  "Construct a RUN-CONFIG. All keyword arguments except LIMITS/CONDITION are required."
  (check-type project-root (or string pathname))
  (check-type system string)
  (check-type test-system string)
  (check-type issue string)
  (check-type condition (member :file-only :generic-mcp :runtime-native :explore))
  (make-instance 'run-config
                 :project-root project-root
                 :system system
                 :test-system test-system
                 :issue issue
                 :condition condition
                 :limits limits
                 :log-llm-requests log-llm-requests))
