;;;; src/step-result.lisp
;;;;
;;;; Extracted from src/orchestrator.lisp so callers that need the
;;;; DEVELOP-STEP-RESULT class + readers (notably src/subtask-summary
;;;; for Phase J) can :import-from this module without pulling
;;;; orchestrator's full dependency surface.
;;;;
;;;; The orchestrator module continues to re-export every symbol
;;;; defined here via :import-from + :export, so external callers
;;;; that wrote `cl-harness/src/orchestrator:develop-step-result-X'
;;;; before this extraction keep working unchanged (`:import-from'
;;;; shares symbol identity, so the orchestrator-qualified name and
;;;; the step-result-qualified name reference the same symbol).
;;;;
;;;; Why this lives here, not orchestrator.lisp: subtask-summary used
;;;; to read these slots via FIND-SYMBOL + SLOT-VALUE at runtime to
;;;; break a load-time cycle (orchestrator -> explore -> context-view
;;;; -> subtask-summary -> orchestrator). Hoisting the class into its
;;;; own minimal-dependency module breaks the cycle structurally and
;;;; lets subtask-summary :import-from this file at compile time.

(defpackage #:cl-harness/src/step-result
  (:use #:cl)
  (:export #:develop-step-result
           #:develop-step-result-step-index
           #:develop-step-result-test-name
           #:develop-step-result-run-config
           #:develop-step-result-status
           #:develop-step-result-run-agent-state
           #:develop-step-result-transcript-path
           #:develop-step-result-explore-result
           #:develop-step-result-abstraction-decisions))

(in-package #:cl-harness/src/step-result)

(defclass develop-step-result ()
  ((step-index :initarg :step-index :reader develop-step-result-step-index)
   (test-name :initarg :test-name :reader develop-step-result-test-name)
   (run-config :initarg :run-config :reader develop-step-result-run-config)
   (status :initarg :status :reader develop-step-result-status)
   (run-agent-state :initarg :run-agent-state
                    :initform nil
                    :reader develop-step-result-run-agent-state)
   (transcript-path :initarg :transcript-path
                    :initform nil
                    :reader develop-step-result-transcript-path)
   (explore-result :initarg :explore-result :initform nil
                   :reader develop-step-result-explore-result)
   (abstraction-decisions :initarg :abstraction-decisions :initform nil
                          :reader develop-step-result-abstraction-decisions))
  (:documentation
   "One step's outcome inside an EXECUTE-PLAN run. STATUS mirrors the
RUN-AGENT terminal status (:PASSED, :GIVE-UP, :LIMIT-EXHAUSTED,
:DIRTY-ONLY, :ERROR). RUN-AGENT-STATE is the underlying AGENT-STATE
the executor returned; the orchestrator stays agnostic about its
exact shape so tests can inject a stand-in. EXPLORE-RESULT (v0.4
Phase 3) is the EXPLORE-RESULT object from the explore sub-agent
when needs-exploration was non-:NONE; NIL otherwise.
ABSTRACTION-DECISIONS (v0.4 Phase 4) is the list of
ABSTRACTION-DECISION instances PARSE-ABSTRACTION-DECISIONS extracted
from the explore memo (NIL when no explore ran or no markers found)."))
