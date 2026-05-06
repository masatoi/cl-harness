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
  (:export #:develop-state
           #:make-develop-state
           #:develop-state-goal
           #:develop-state-project-root
           #:develop-state-system
           #:develop-state-test-system
           #:develop-state-condition
           #:develop-state-run-limits
           #:develop-state-project-inventory
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
           #:develop-state-source-facts
           #:develop-state-record-source-fact
           #:develop-state-patch-records
           #:develop-state-record-patch-record
           #:develop-state-failure-ledger
           #:develop-state-record-failure))

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
instances."))
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
                             (mode :mixed))
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
  (make-instance 'develop-state
                 :goal goal
                 :project-root project-root
                 :system system
                 :test-system test-system
                 :condition condition
                 :run-limits run-limits
                 :project-inventory project-inventory
                 :mode mode))

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
