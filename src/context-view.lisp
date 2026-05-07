;;;; src/context-view.lisp
;;;;
;;;; Phase C of the context-management refactor
;;;; (docs/context-management.md §4-§5). Generates phase-specific
;;;; CONTEXT-VIEW snapshots from a DEVELOP-STATE: the structured
;;;; form callers can either inspect directly or render via
;;;; CONTEXT-VIEW->STRING for splicing into LLM prompts.
;;;;
;;;; Phase C MVP: data layer + 3 phase formatters (:PLANNING,
;;;; :EXPLORATION, :IMPLEMENTATION). Testing-phase view is folded
;;;; into :IMPLEMENTATION (cl-harness's run-agent loop runs both).
;;;; Integration-phase view is deferred to Phase E.

(defpackage #:cl-harness/src/context-view
  (:use #:cl)
  (:import-from #:cl-harness/src/state
                #:develop-state-goal
                #:develop-state-project-inventory
                #:develop-state-current-plan
                #:develop-state-current-step-index
                #:develop-state-source-facts
                #:develop-state-patch-records
                #:develop-state-failure-ledger
                #:develop-state-runtime-vocabulary
                #:develop-state-repl-findings
                #:develop-state-project-summary)
  (:import-from #:cl-harness/src/project-summary
                #:project-summary-asd-files
                #:project-summary-source-files
                #:project-summary-test-files
                #:project-summary-dirty-p)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:runtime-vocab-fact-kind
                #:runtime-vocab-fact-name
                #:runtime-vocab-fact-package
                #:runtime-vocab-fact-related-step-index
                #:runtime-vocab-fact-stale-p)
  (:import-from #:cl-harness/src/repl-finding
                #:repl-finding-hypothesis
                #:repl-finding-decision
                #:repl-finding-promoted-to-source-p
                #:repl-finding-related-step-index)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact-related-step-index
                #:source-fact-path
                #:source-fact-form-type
                #:source-fact-form-name
                #:source-fact-stale-p)
  (:import-from #:cl-harness/src/planner
                #:plan-step-issue
                #:plan-step-investigation-targets
                #:investigation-target-kind
                #:investigation-target-name
                #:investigation-target-intent)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-related-step-index
                #:patch-record-path
                #:patch-record-via-tool
                #:patch-record-form-type
                #:patch-record-form-name)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger-active
                #:failure-record-test-name
                #:failure-record-description
                #:failure-record-reason)
  (:export #:context-view
           #:make-context-view
           #:context-view-phase
           #:context-view-goal
           #:context-view-current-step
           #:context-view-current-plan
           #:context-view-relevant-source-facts
           #:context-view-relevant-runtime-vocab
           #:context-view-runtime-vocab
           #:context-view-relevant-repl-findings
           #:context-view-relevant-unpromoted-findings
           #:context-view-relevant-patch-records
           #:context-view-active-failures
           #:context-view-prior-plan
           #:context-view-failure-context
           #:context-view-project-inventory
           #:context-view-project-summary
           #:context-view->string
           #:+supported-phases+))

(in-package #:cl-harness/src/context-view)

(defparameter +supported-phases+
  '(:planning :exploration :implementation)
  "Phases for which MAKE-CONTEXT-VIEW and CONTEXT-VIEW->STRING are
defined. Mirrors a subset of docs/context-management.md §4.2:
testing folds into implementation (cl-harness's run-agent runs
both); integration is deferred to Phase E.")

(defclass context-view ()
  ((phase :initarg :phase :reader context-view-phase
          :documentation "One of +SUPPORTED-PHASES+.")
   (goal :initarg :goal :initform nil :reader context-view-goal
         :documentation "Current GOAL string (always populated).")
   (project-inventory :initarg :project-inventory :initform nil
                      :reader context-view-project-inventory
                      :documentation "Snapshot of develop-state's
project-inventory (text block today; Phase B's runtime-vocabulary
will replace this slot's data source). Populated for :PLANNING.")
   (current-plan :initarg :current-plan :initform nil
                 :reader context-view-current-plan
                 :documentation "List of PLAN-STEP. Populated for
:PLANNING (in replan mode) and :IMPLEMENTATION (for context).")
   (current-step :initarg :current-step :initform nil
                 :reader context-view-current-step
                 :documentation "Active PLAN-STEP, or NIL when
between steps (e.g. :PLANNING). Populated for :EXPLORATION and
:IMPLEMENTATION.")
   (relevant-source-facts :initarg :relevant-source-facts
                          :initform nil
                          :reader context-view-relevant-source-facts
                          :documentation "SOURCE-FACTs filtered to
those bound to the current step. Populated for :EXPLORATION and
:IMPLEMENTATION.")
   (relevant-patch-records :initarg :relevant-patch-records
                           :initform nil
                           :reader context-view-relevant-patch-records
                           :documentation "PATCH-RECORDs filtered
to the current step. Populated for :IMPLEMENTATION.")
   (active-failures :initarg :active-failures :initform nil
                    :reader context-view-active-failures
                    :documentation "Currently-active FAILURE-RECORDs
from the failure-ledger. Populated for :IMPLEMENTATION (so the
agent loop sees what's still broken).")
   (prior-plan :initarg :prior-plan :initform nil
               :reader context-view-prior-plan
               :documentation "PLAN-STEP list from the failed prior
round, or NIL on initial planning. Populated for :PLANNING in replan
mode (caller passes :prior-plan).")
   (failure-context :initarg :failure-context :initform nil
                    :reader context-view-failure-context
                    :documentation "Human-readable failure summary
from the failed prior round, or NIL on initial planning. Populated
for :PLANNING in replan mode (caller passes :failure-context).")
   (relevant-runtime-vocab :initarg :relevant-runtime-vocab :initform nil
                           :reader context-view-relevant-runtime-vocab
                           :documentation "RUNTIME-VOCAB-FACTs filtered
to the current step. Populated for :EXPLORATION.")
   (runtime-vocab :initarg :runtime-vocab :initform nil
                  :reader context-view-runtime-vocab
                  :documentation "Full RUNTIME-VOCAB-FACT list — all
observations across the run, oldest-first. Populated for :PLANNING
so the planner sees what the agent has already probed (warm-start
context). NIL when the develop-state has no runtime-vocabulary.")
   (relevant-repl-findings :initarg :relevant-repl-findings :initform nil
                           :reader context-view-relevant-repl-findings
                           :documentation "REPL-FINDINGs filtered to
the current step. Populated for :EXPLORATION (lists all findings,
including promoted ones — promotion is annotated in the formatter).")
   (relevant-unpromoted-findings :initarg :relevant-unpromoted-findings
                                 :initform nil
                                 :reader context-view-relevant-unpromoted-findings
                                 :documentation "REPL-FINDINGs filtered
to the current step AND not yet promoted to source. Populated for
:IMPLEMENTATION so the agent sees the work that's still pending.
Promotion is filtered at construction time (not render time): the
LLM should never see promoted findings in the implementation view.")
   (project-summary :initarg :project-summary :initform nil
                    :reader context-view-project-summary
                    :documentation "PROJECT-SUMMARY snapshot from
DEVELOP-STATE for the :PLANNING view, or NIL when the develop-state
has no summary yet. Phase I (§3.3): structured cold-start project
context with a dirty flag for staleness annotation. The formatter
calls PROJECT-SUMMARY-DIRTY-P at render time to decide whether to
prefix the section header with [STALE]; MAKE-CONTEXT-VIEW does not
read the flag (Phase F render-time contract)."))
  (:documentation
   "A snapshot of DEVELOP-STATE filtered for one phase. Pure data;
no behaviour beyond construction and the CONTEXT-VIEW->STRING
formatter dispatch."))

(defun %related-to-step-p (item step-index getter)
  "Return T when ITEM's GETTER (a related-step-index reader) equals
STEP-INDEX. Used to filter ledger lists. Returns NIL when STEP-INDEX
is NIL (no current step, no items match)."
  (and step-index
       (eql step-index (funcall getter item))))

(defun %filter-source-facts (state step-index)
  (and step-index
       (remove-if-not
        (lambda (f) (%related-to-step-p f step-index
                                        #'source-fact-related-step-index))
        (develop-state-source-facts state))))

(defun %filter-patch-records (state step-index)
  (and step-index
       (remove-if-not
        (lambda (p) (%related-to-step-p p step-index
                                        #'patch-record-related-step-index))
        (develop-state-patch-records state))))

(defun %filter-runtime-vocab (state step-index)
  (and step-index
       (remove-if-not
        (lambda (f) (%related-to-step-p
                     f step-index #'runtime-vocab-fact-related-step-index))
        (develop-state-runtime-vocabulary state))))

(defun %filter-repl-findings (state step-index)
  (and step-index
       (remove-if-not
        (lambda (f) (%related-to-step-p
                     f step-index #'repl-finding-related-step-index))
        (develop-state-repl-findings state))))

(defun %filter-unpromoted-findings (state step-index)
  (remove-if #'repl-finding-promoted-to-source-p
             (%filter-repl-findings state step-index)))

(defun %active-failures (state)
  (let ((ledger (develop-state-failure-ledger state)))
    (and ledger (failure-ledger-active ledger))))

(defun make-context-view (state &key phase step prior-plan failure-context)
  "Build a CONTEXT-VIEW snapshot from STATE for PHASE. STEP is the
active PLAN-STEP (required for :EXPLORATION and :IMPLEMENTATION;
ignored for :PLANNING). PRIOR-PLAN and FAILURE-CONTEXT are
:PLANNING-only kwargs for the replan path.

The returned view is independent of STATE -- subsequent state
mutations do not propagate."
  (unless (member phase +supported-phases+)
    (error "make-context-view: unsupported :phase ~S; expected one of ~S"
           phase +supported-phases+))
  (let ((step-index (and state (develop-state-current-step-index state))))
    (case phase
      (:planning
       (make-instance 'context-view
                      :phase :planning
                      :goal (and state (develop-state-goal state))
                      :project-inventory (and state
                                              (develop-state-project-inventory
                                               state))
                      :project-summary (and state
                                            (develop-state-project-summary
                                             state))
                      :current-plan (and state
                                         (develop-state-current-plan state))
                      :prior-plan prior-plan
                      :failure-context failure-context
                      :runtime-vocab (and state
                                          (develop-state-runtime-vocabulary
                                           state))))
      (:exploration
       (make-instance 'context-view
                      :phase :exploration
                      :goal (and state (develop-state-goal state))
                      :current-step step
                      :relevant-source-facts (%filter-source-facts
                                              state step-index)
                      :relevant-runtime-vocab (%filter-runtime-vocab
                                               state step-index)
                      :relevant-repl-findings (%filter-repl-findings
                                               state step-index)))
      (:implementation
       (make-instance 'context-view
                      :phase :implementation
                      :goal (and state (develop-state-goal state))
                      :current-plan (and state
                                         (develop-state-current-plan state))
                      :current-step step
                      :relevant-source-facts (%filter-source-facts
                                              state step-index)
                      :relevant-patch-records (%filter-patch-records
                                               state step-index)
                      :active-failures (%active-failures state)
                      :relevant-unpromoted-findings
                      (%filter-unpromoted-findings state step-index))))))

(defgeneric context-view->string (view phase)
  (:documentation
   "Render VIEW as a phase-appropriate markdown-ish string suitable
for splicing into an LLM prompt's context section. The string is
self-contained: a caller can either use it as the entire context
block or splice it into a larger scaffold. PHASE must match
VIEW's phase slot -- it's a parameter for dispatch convenience.
Phase C MVP supports :PLANNING, :EXPLORATION, :IMPLEMENTATION."))

;; Default fallback -- unsupported phase raises; methods land in Tasks 3-5.
(defmethod context-view->string ((view context-view) phase)
  (declare (ignore view))
  (error "context-view->string: no method for phase ~S" phase))

(defmethod context-view->string ((view context-view) (phase (eql :planning)))
  "Planning-phase view: goal, project inventory, prior-plan + failure
context (replan only). The output is a multi-section markdown block
that the planner's user-prompt builder can splice in place of its
current ad-hoc inventory + goal + replan block."
  (with-output-to-string (s)
    (let ((sum (context-view-project-summary view)))
      (when sum
        (format s "## ~AProject summary~%"
                (if (project-summary-dirty-p sum) "[STALE] " ""))
        (format s "ASD systems: ~A~%"
                (or (and (project-summary-asd-files sum)
                         (format nil "~{~A~^, ~}"
                                 (project-summary-asd-files sum)))
                    "(none)"))
        (format s "Source files: ~A~%"
                (or (and (project-summary-source-files sum)
                         (format nil "~{~A~^, ~}"
                                 (project-summary-source-files sum)))
                    "(none)"))
        (format s "Test files: ~A~%~%"
                (or (and (project-summary-test-files sum)
                         (format nil "~{~A~^, ~}"
                                 (project-summary-test-files sum)))
                    "(none)"))))
    (when (context-view-project-inventory view)
      (format s "## Project inventory~%~A~%~%"
              (context-view-project-inventory view)))
    (format s "## Goal~%~A~%"
            (or (context-view-goal view) ""))
    (when (context-view-prior-plan view)
      (format s "~%## Prior plan (failed last round)~%~S~%"
              (context-view-prior-plan view)))
    (when (context-view-failure-context view)
      (format s "~%## Prior failure context~%~A~%"
              (context-view-failure-context view)))
    (let ((vocab (context-view-runtime-vocab view)))
      (when vocab
        (format s "~%## Runtime vocabulary observed so far~%")
        (dolist (fact vocab)
          (format s "- [~(~A~)] ~A~A~%"
                  (runtime-vocab-fact-kind fact)
                  (if (runtime-vocab-fact-package fact)
                      (format nil "~A:" (runtime-vocab-fact-package fact))
                      "")
                  (runtime-vocab-fact-name fact)))))))

(defmethod context-view->string ((view context-view)
                                  (phase (eql :exploration)))
  "Exploration-phase view: current step's issue, investigation
targets (if any), and a one-line summary of relevant source-facts
(which files have been read in this step). Defensive: when no
:STEP was passed, emit a placeholder so the formatter never errors."
  (with-output-to-string (s)
    (let ((step (context-view-current-step view)))
      (cond
        ((null step)
         (format s "## Current step~%(no current step)~%"))
        (t
         (format s "## Current step~%~A~%"
                 (plan-step-issue step))
         (let ((targets (plan-step-investigation-targets step)))
           (when targets
             (format s "~%## Investigation targets~%")
             (dolist (target targets)
               (format s "- [~A] ~A — ~A~%"
                       (string-downcase
                        (symbol-name (investigation-target-kind target)))
                       (investigation-target-name target)
                       (investigation-target-intent target))))))))
    (let ((facts (context-view-relevant-source-facts view)))
      (when facts
        (format s "~%## Source already read in this step~%")
        (dolist (fact facts)
          (format s "- ~A~A~A~%"
                  (if (source-fact-stale-p fact) "[STALE] " "")
                  (namestring (source-fact-path fact))
                  (if (source-fact-form-name fact)
                      (format nil " :: ~A ~A"
                              (or (source-fact-form-type fact) "")
                              (source-fact-form-name fact))
                      "")))))
    (let ((vocab (context-view-relevant-runtime-vocab view)))
      (when vocab
        (format s "~%## Runtime vocabulary probed in this step~%")
        (dolist (fact vocab)
          (format s "- ~A[~(~A~)] ~A~A~%"
                  (if (runtime-vocab-fact-stale-p fact) "[STALE] " "")
                  (runtime-vocab-fact-kind fact)
                  (if (runtime-vocab-fact-package fact)
                      (format nil "~A:" (runtime-vocab-fact-package fact))
                      "")
                  (runtime-vocab-fact-name fact)))))
    (let ((findings (context-view-relevant-repl-findings view)))
      (when findings
        (format s "~%## Findings observed in this step~%")
        (dolist (f findings)
          (format s "- ~A~A => ~A~%"
                  (if (repl-finding-promoted-to-source-p f) "[PROMOTED] " "")
                  (repl-finding-hypothesis f)
                  (repl-finding-decision f)))))))

(defmethod context-view->string ((view context-view)
                                  (phase (eql :implementation)))
  "Implementation-phase view: current step's issue, a short
summary of relevant patch-records (what's been changed in this
step), and the active failure list (what's still broken). Source
facts are not enumerated -- the agent's own tool calls are the
authoritative read log; the source-fact slot is reserved for
later phases that need it."
  (with-output-to-string (s)
    (let ((step (context-view-current-step view)))
      (cond
        ((null step)
         (format s "## Current step~%(no current step)~%"))
        (t
         (format s "## Current step~%~A~%" (plan-step-issue step)))))
    (let ((patches (context-view-relevant-patch-records view)))
      (when patches
        (format s "~%## Patches applied in this step~%")
        (dolist (p patches)
          (format s "- ~A (~A~A)~%"
                  (namestring (patch-record-path p))
                  (patch-record-via-tool p)
                  (if (patch-record-form-name p)
                      (format nil " on ~A ~A"
                              (or (patch-record-form-type p) "")
                              (patch-record-form-name p))
                      "")))))
    (let ((failures (context-view-active-failures view)))
      (when failures
        (format s "~%## Active failures~%")
        (dolist (f failures)
          (format s "- ~A: ~A~A~%"
                  (or (failure-record-test-name f) "(unnamed)")
                  (failure-record-description f)
                  (if (failure-record-reason f)
                      (format nil " (~A)" (failure-record-reason f))
                      "")))))
    (let ((findings (context-view-relevant-unpromoted-findings view)))
      (when findings
        (format s "~%## Findings to implement (REPL-confirmed, not yet shipped)~%")
        (dolist (f findings)
          (format s "- ~A => ~A~%"
                  (repl-finding-hypothesis f)
                  (repl-finding-decision f)))))))
