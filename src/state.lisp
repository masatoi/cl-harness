;;;; src/state.lisp
;;;;
;;;; Phase A of the context-management refactor
;;;; (docs/context-management.md). Central in-memory state for one
;;;; DEVELOP invocation. This file deliberately stays minimal: it is
;;;; a data container, nothing more. Smart helpers (failure
;;;; detection, status transitions) live in the orchestrator. Phases
;;;; B-E will extend this class with source/patch/runtime/failure
;;;; slots without changing the public shape introduced here.

(defpackage #:cl-harness/src/state
  (:use #:cl)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger
                #:make-failure-ledger
                #:record-failure)
  (:import-from #:cl-harness/src/project-summary
                #:project-summary-mark-dirty)
  (:export #:develop-state
           #:make-develop-state
           #:develop-state-goal
           #:develop-state-project-root
           #:develop-state-system
           #:develop-state-test-system
           #:develop-state-condition
           #:develop-state-run-limits
           #:develop-state-project-inventory
           #:develop-state-project-summary
           #:develop-state-set-project-summary
           #:develop-state-mark-project-summary-dirty
           #:develop-state-mode
           #:develop-state-current-plan
           #:develop-state-current-step-index
           #:develop-state-step-results
           #:develop-state-replan-count
           #:develop-state-last-failure-test-name
           #:develop-state-status
           #:develop-state-limit-hit
           #:develop-state-integration-issues
           #:develop-state-record-step-result
           #:develop-state-develop-spec
           #:develop-state-set-develop-spec
           #:develop-state-review-policy
           #:develop-state-test-revision-policy
           #:develop-state-review-replan-count
           #:develop-state-test-revision-count
           #:develop-state-review-decisions
           #:develop-state-record-review-decision
           #:develop-state-test-records
           #:develop-state-record-test-record
           #:develop-state-test-change-requests
           #:develop-state-record-test-change-request
           #:develop-state-source-facts
           #:develop-state-record-source-fact
           #:develop-state-patch-records
           #:develop-state-record-patch-record
           #:develop-state-runtime-vocabulary
           #:develop-state-record-runtime-vocab-fact
           #:develop-state-repl-findings
           #:develop-state-record-repl-finding
           #:develop-state-failure-ledger
           #:develop-state-record-failure
           #:develop-state-reason))

(in-package #:cl-harness/src/state)

(defparameter +supported-modes+ '(:top-down :bottom-up :mixed)
  "Development modes accepted by MAKE-DEVELOP-STATE. Mirrors
CL-HARNESS/SRC/PLANNER:+SUPPORTED-DEVELOPMENT-MODES+ but is
duplicated here so this file has no inbound dependency on PLANNER.
Keep them in sync.")

(defparameter +supported-conditions+
  '(:file-only :generic-mcp :runtime-native :explore)
  "Tool-policy conditions accepted by MAKE-DEVELOP-STATE. Mirrors
CL-HARNESS/SRC/CONFIG:RUN-CONFIG's CONDITION ECASE.")

(defclass develop-state ()
  ((goal :initarg :goal :reader develop-state-goal :type string
         :documentation "User goal string passed to DEVELOP.")
   (project-root :initarg :project-root
                 :reader develop-state-project-root
                 :documentation "Repository root the run targets.")
   (system :initarg :system :reader develop-state-system
           :documentation "Primary ASDF system name (string).")
   (test-system :initarg :test-system
                :reader develop-state-test-system
                :documentation "Test ASDF system name (string).")
   (condition :initarg :condition
              :reader develop-state-condition
              :initform :generic-mcp
              :documentation "Tool-policy condition keyword. One of
+SUPPORTED-CONDITIONS+.")
   (run-limits :initarg :run-limits
               :reader develop-state-run-limits
               :initform nil
               :documentation "RUN-LIMITS instance shared by every
step's RUN-CONFIG, or NIL to let the step default kick in.")
   (project-inventory :initarg :project-inventory
                      :reader develop-state-project-inventory
                      :initform nil
                      :documentation "Optional project-inventory
text block (currently produced by INVENTORY:GATHER-PROJECT-INVENTORY)
threaded into the planner. Phase B promotes this to a structured
runtime-vocabulary slot.")
   (mode :initarg :mode :reader develop-state-mode :initform :mixed
         :documentation "Development mode keyword, one of
+SUPPORTED-MODES+.")
   (current-plan :initform nil :accessor develop-state-current-plan
                 :documentation "PLAN-STEP list currently being
executed. Replaced wholesale on each replan round.")
   (current-step-index :initform nil
                       :accessor develop-state-current-step-index
                       :documentation "PLAN-STEP-INDEX of the step
the orchestrator is currently executing, or NIL when not inside a
step (e.g. before the loop starts, between steps, or after the
final step). Set by %execute-step at entry, cleared at exit. Used
by MAKE-CONTEXT-VIEW to filter ledger entries to those belonging
to the active step.")
   (step-results :initform nil :accessor %step-results
                 :documentation "Reverse-chronological list of
DEVELOP-STEP-RESULT instances. Internal; callers use
DEVELOP-STATE-STEP-RESULTS for execution order.")
   (replan-count :initform 0 :accessor develop-state-replan-count
                 :documentation "How many times the planner has been
re-invoked during this run.")
   (last-failure-test-name
    :initform nil :accessor develop-state-last-failure-test-name
    :documentation "Test name of the previous round's failing step.
Used by the orchestrator to detect a stuck loop.")
   (status :initform :unknown :accessor develop-state-status
           :documentation "Current terminal status keyword. Becomes
the final DEVELOP-RESULT status when the loop exits.")
   (limit-hit :initform nil :accessor develop-state-limit-hit
              :documentation "Which budget tripped, if any --
:MAX-REPLANS or :NO-PROGRESS or NIL.")
   (integration-issues :initform nil
                       :accessor develop-state-integration-issues
                       :documentation "INTEGRATION-ISSUE list found
by the post-success static check, or NIL when none ran.")
   (develop-spec :initform nil :accessor develop-state-develop-spec
                 :documentation "Optional DEVELOP-SPEC generated from
the user goal. When review gates are enabled, this is the source of
truth above planner-authored tests.")
   (review-policy :initarg :review-policy
                  :reader develop-state-review-policy
                  :initform :auto
                  :documentation "Review-gate policy keyword. :AUTO
uses the configured provider/reviewer, :NONE disables gates.")
   (test-revision-policy :initarg :test-revision-policy
                         :reader develop-state-test-revision-policy
                         :initform :additive-only
                         :documentation "Policy for implementer-requested
test revisions. v0.6 starts with :ADDITIVE-ONLY.")
   (review-replan-count :initform 0
                        :accessor develop-state-review-replan-count
                        :documentation "How many plan/test review
rejection replans have been consumed.")
   (test-revision-count :initform 0
                        :accessor develop-state-test-revision-count
                        :documentation "How many approved additive
test revisions have been materialized.")
   (review-decisions :initform nil :accessor %review-decisions
                     :documentation "Reverse-chronological
REVIEW-DECISION records.")
   (test-records :initform nil :accessor %test-records
                 :documentation "Reverse-chronological TEST-RECORDs
for approved generated tests.")
   (test-change-requests :initform nil :accessor %test-change-requests
                         :documentation "Reverse-chronological
TEST-CHANGE-RECORDs requested during implementation.")
   (source-facts :initform nil :accessor %source-facts
                 :documentation "Reverse-chronological list of
SOURCE-FACT instances. Internal; public reader is
DEVELOP-STATE-SOURCE-FACTS.")
   (patch-records :initform nil :accessor %patch-records
                  :documentation "Reverse-chronological list of
PATCH-RECORD instances. Internal; public reader is
DEVELOP-STATE-PATCH-RECORDS.")
   (failure-ledger :reader develop-state-failure-ledger
                   :documentation "FAILURE-LEDGER owned by this
state. Auto-initialised in INITIALIZE-INSTANCE :AFTER below; no
:initform because we don't want to share one ledger across
instances.")
   (runtime-vocabulary :initform nil :accessor %runtime-vocabulary
                       :documentation "Reverse-chronological list of
RUNTIME-VOCAB-FACT instances captured by the agent loop's runtime
introspection probes (cl-mcp code-find / code-describe /
code-find-references results). Internal; public reader is
DEVELOP-STATE-RUNTIME-VOCABULARY.")
   (repl-findings :initform nil :accessor %repl-findings
                  :documentation "Reverse-chronological list of
REPL-FINDING instances. Internal; public reader is
DEVELOP-STATE-REPL-FINDINGS.")
   (project-summary :initform nil :accessor develop-state-project-summary
                    :documentation "Optional PROJECT-SUMMARY instance
holding the structured cold-start project context (Phase I, §3.3).
Replaced wholesale via DEVELOP-STATE-SET-PROJECT-SUMMARY; mutated
in-place only via DEVELOP-STATE-MARK-PROJECT-SUMMARY-DIRTY.")
   (reason :initarg :reason :initform nil
           :accessor develop-state-reason
           :documentation "Failure-mode classification keyword (or
NIL on success). Set by the orchestrator's MODEL-ERROR catch when
a transport / HTTP / shape failure aborts the run. Mirrors
AGENT-STATE-REASON / DEVELOP-RESULT-REASON for cross-layer
visibility."))
  (:documentation
   "Central state for one DEVELOP invocation. Aggregates the goal,
project context, current plan, step outcomes across replan rounds,
and terminal status. Does not own external resources (provider,
mcp-client, logger) -- those remain function-local to the
orchestration loop. Phases B-E will extend this class with
additional slots (source-facts, patch-records, failure-ledger,
runtime-vocabulary) without touching the existing slot set."))

(defun make-develop-state (&key goal project-root system test-system
                             (condition :generic-mcp)
                             run-limits project-inventory
                             (mode :mixed)
                             (review-policy :auto)
                             (test-revision-policy :additive-only))
  "Construct a DEVELOP-STATE for one DEVELOP run. GOAL must be a
non-empty string; PROJECT-ROOT, SYSTEM, TEST-SYSTEM must be
non-NIL. MODE defaults to :MIXED and must be one of
+SUPPORTED-MODES+. CONDITION defaults to :GENERIC-MCP and must be
one of +SUPPORTED-CONDITIONS+."
  (check-type goal string)
  (assert (plusp (length goal)) (goal)
          "develop-state: :goal must be a non-empty string")
  (assert project-root (project-root)
          "develop-state: :project-root is required")
  (check-type system string)
  (check-type test-system string)
  (unless (member mode +supported-modes+)
    (error "develop-state: unsupported :mode ~S; expected one of ~S"
           mode +supported-modes+))
  (unless (member condition +supported-conditions+)
    (error "develop-state: unsupported :condition ~S; expected one of ~S"
           condition +supported-conditions+))
  (unless (member review-policy '(:auto :none))
    (error "develop-state: unsupported :review-policy ~S" review-policy))
  (unless (member test-revision-policy '(:additive-only :none))
    (error "develop-state: unsupported :test-revision-policy ~S"
           test-revision-policy))
  (make-instance 'develop-state
                 :goal goal
                 :project-root project-root
                 :system system
                 :test-system test-system
                 :condition condition
                 :run-limits run-limits
                 :project-inventory project-inventory
                 :mode mode
                 :review-policy review-policy
                 :test-revision-policy test-revision-policy))

(defun develop-state-record-step-result (state step-result)
  "Append STEP-RESULT (typically a DEVELOP-STEP-RESULT) to STATE's
internal step-results list. The slot is kept reverse-chronological
internally; DEVELOP-STATE-STEP-RESULTS reverses on read so callers
see execution order. Returns STATE."
  (push step-result (%step-results state))
  state)

(defun develop-state-step-results (state)
  "Return STATE's recorded step results in execution order
(oldest first). Mirrors DEVELOP-RESULT-STEP-RESULTS so the two
are interchangeable for downstream readers."
  (reverse (%step-results state)))

(defun develop-state-set-develop-spec (state spec)
  "Replace STATE's DEVELOP-SPEC slot with SPEC. Returns STATE."
  (setf (slot-value state 'develop-spec) spec)
  state)

(defun develop-state-record-review-decision (state decision)
  "Push DECISION onto STATE's review-decision list. Returns STATE."
  (push decision (%review-decisions state))
  state)

(defun develop-state-review-decisions (state)
  "Return STATE's review decisions in observation order."
  (reverse (%review-decisions state)))

(defun develop-state-record-test-record (state record)
  "Push generated-test RECORD onto STATE. Returns STATE."
  (push record (%test-records state))
  state)

(defun develop-state-test-records (state)
  "Return STATE's generated test records in observation order."
  (reverse (%test-records state)))

(defun develop-state-record-test-change-request (state request)
  "Push additive test-change REQUEST onto STATE. Returns STATE."
  (push request (%test-change-requests state))
  state)

(defun develop-state-test-change-requests (state)
  "Return STATE's test-change requests in observation order."
  (reverse (%test-change-requests state)))

(defmethod initialize-instance :after ((s develop-state) &key)
  "Allocate a fresh FAILURE-LEDGER for each new DEVELOP-STATE.
Using :AFTER instead of an :initform so each instance gets its
own ledger (an :initform expression evaluated at class-init time
would share one ledger between every instance)."
  (setf (slot-value s 'failure-ledger) (make-failure-ledger)))

(defun develop-state-record-source-fact (state fact)
  "Push FACT onto STATE's source-facts list. Returns STATE."
  (push fact (%source-facts state))
  state)

(defun develop-state-source-facts (state)
  "Return STATE's recorded source-facts in observation order
(oldest first)."
  (reverse (%source-facts state)))

(defun develop-state-record-patch-record (state record)
  "Push RECORD onto STATE's patch-records list. Returns STATE."
  (push record (%patch-records state))
  state)

(defun develop-state-patch-records (state)
  "Return STATE's recorded patch-records in observation order
(oldest first)."
  (reverse (%patch-records state)))

(defun develop-state-record-failure (state failure-record)
  "Append FAILURE-RECORD to STATE's failure-ledger active list.
Thin wrapper around RECORD-FAILURE on the ledger; provided so
callers don't need to know the ledger lives inside develop-state.
Returns STATE."
  (record-failure (develop-state-failure-ledger state) failure-record)
  state)

(defun develop-state-record-runtime-vocab-fact (state fact)
  "Push FACT onto STATE's runtime-vocabulary list. Returns STATE."
  (push fact (%runtime-vocabulary state))
  state)

(defun develop-state-runtime-vocabulary (state)
  "Return STATE's recorded runtime-vocab-facts in observation order
(oldest first)."
  (reverse (%runtime-vocabulary state)))

(defun develop-state-record-repl-finding (state finding)
  "Push FINDING onto STATE's repl-findings list. Returns STATE."
  (push finding (%repl-findings state))
  state)

(defun develop-state-repl-findings (state)
  "Return STATE's recorded repl-findings in observation order
(oldest first)."
  (reverse (%repl-findings state)))

(defun develop-state-set-project-summary (state summary)
  "Replace STATE's project-summary slot with SUMMARY (a
PROJECT-SUMMARY instance, or NIL to clear). Returns STATE."
  (setf (slot-value state 'project-summary) summary)
  state)

(defun develop-state-mark-project-summary-dirty (state)
  "Flip STATE's project-summary dirty flag to T. No-op when the slot
is NIL (caller hasn't gathered a summary yet). Returns STATE."
  (let ((summary (develop-state-project-summary state)))
    (when summary
      (project-summary-mark-dirty summary)))
  state)
