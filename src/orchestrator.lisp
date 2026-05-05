;;;; src/orchestrator.lisp
;;;;
;;;; Phase P2 of the planner+orchestrator extension
;;;; (docs/notes/2026-05-06-planner-orchestrator.md). Drives a static
;;;; PLAN (a list of PLAN-STEP) end to end:
;;;;
;;;;   for each step:
;;;;     1. validate test_source is shaped like a (deftest ...)
;;;;     2. append the step's test_source to TEST-FILE on disk
;;;;     3. build a RUN-CONFIG from the step + the caller's project context
;;;;     4. call RUN-AGENT (or an injected stub for tests)
;;;;     5. record the outcome
;;;;     6. stop on the first non-:passed outcome
;;;;
;;;; A develop-level JSONL transcript at LOG-PATH receives, in order:
;;;;   develop-start, plan, (step-start, step-end)+, develop-end
;;;; Per-step run-agent transcripts continue to be written by RUN-AGENT
;;;; itself; the develop log links them by transcript-path.
;;;;
;;;; No replanning yet — that lands in Phase P3. RUN-AGENT itself is
;;;; unchanged; the orchestrator is purely the layer above it.

(defpackage #:cl-harness/src/orchestrator
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/log
                #:open-run-logger
                #:close-run-logger
                #:log-event)
  (:import-from #:cl-harness/src/config
                #:make-run-config)
  (:import-from #:cl-harness/src/policy
                #:make-tool-policy)
  (:import-from #:cl-harness/src/planner
                #:plan-step-index
                #:plan-step-issue
                #:plan-step-test-name
                #:plan-step-test-source
                #:plan-step-files-to-modify
                #:planner-error)
  (:import-from #:cl-harness/src/agent
                #:run-agent)
  (:export #:develop-step-result
           #:develop-step-result-status
           #:develop-step-result-step-index
           #:develop-step-result-run-config
           #:develop-step-result-run-agent-state
           #:develop-step-result-test-name
           #:validate-test-source
           #:materialize-test-source
           #:plan-step->run-config
           #:execute-plan))

(in-package #:cl-harness/src/orchestrator)

;; --- result ---------------------------------------------------------------

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
                    :reader develop-step-result-transcript-path))
  (:documentation
   "One step's outcome inside an EXECUTE-PLAN run. STATUS mirrors the
RUN-AGENT terminal status (:PASSED, :GIVE-UP, :LIMIT-EXHAUSTED,
:DIRTY-ONLY, :ERROR). RUN-AGENT-STATE is the underlying AGENT-STATE
the executor returned; the orchestrator stays agnostic about its
exact shape so tests can inject a stand-in."))

;; --- helpers --------------------------------------------------------------

(defun validate-test-source (source step-index)
  "Signal PLANNER-ERROR unless SOURCE looks like a rove (deftest ...)
form. Step-index 0-based, used in the error message so the user can
see which step the bad test_source lives in. Address the test-fidelity
risk #1 from docs/notes/2026-05-06-planner-orchestrator.md: the LLM
sometimes emits (defun test-foo ...) instead, which never wires into
rove and would let the executor's verify pass on an irrelevant
green signal."
  (unless (and (stringp source) (plusp (length source)))
    (error 'planner-error
           :message (format nil
                            "step ~D test_source must be a non-empty string"
                            step-index)
           :raw source))
  (unless (search "(deftest " source)
    (error 'planner-error
           :message (format nil
                            "step ~D test_source must contain a (deftest ...) form (got: ~A)"
                            step-index
                            (subseq source 0 (min 80 (length source))))
           :raw source))
  source)

(defun materialize-test-source (path source)
  "Append SOURCE to PATH on disk, creating PATH if it does not exist.
A leading newline is inserted so successive deftest forms remain on
their own lines. The directory is created if necessary."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :append
                            :if-does-not-exist :create
                            :element-type 'character)
    (terpri out)
    (write-string source out)
    (terpri out)
    (finish-output out))
  (values))

(defun plan-step->run-config (step
                              &key project-root system test-system
                                   (condition :generic-mcp)
                                   limits)
  "Build a RUN-CONFIG from PLAN-STEP plus a per-execute-plan template.
PROJECT-ROOT / SYSTEM / TEST-SYSTEM / CONDITION are shared across all
steps in a plan. LIMITS, when supplied, overrides the run-config
default."
  (declare (ignore limits)) ;; reserved for callers that want custom limits
  (make-run-config :project-root project-root
                   :system system
                   :test-system test-system
                   :issue (plan-step-issue step)
                   :condition condition))

;; --- develop-level logging ------------------------------------------------

(defun %ensure-develop-logger (log-path)
  (when log-path (open-run-logger log-path)))

(defun %close-develop-logger (logger)
  (when logger (close-run-logger logger)))

(defun %log-develop-event (logger event-type payload)
  (when logger (log-event logger event-type payload)))

(defun %plan-event-payload (steps)
  "Serialize the static plan as a JSON-friendly array for the :plan event."
  (alist-hash-table
   `(("steps" . ,(map 'vector
                      (lambda (step)
                        (alist-hash-table
                         `(("index" . ,(plan-step-index step))
                           ("test_name" . ,(plan-step-test-name step))
                           ("issue" . ,(plan-step-issue step))
                           ("files_to_modify"
                            . ,(coerce (plan-step-files-to-modify step)
                                       'vector)))
                         :test 'equal))
                      steps)))
   :test 'equal))

;; --- main loop ------------------------------------------------------------

(defun %symbol-status (s)
  "Return STATUS as a JSON-friendly string."
  (cond
    ((null s) nil)
    ((stringp s) s)
    ((symbolp s) (string-downcase (symbol-name s)))
    (t (format nil "~A" s))))

(defun %read-status-from-state (state)
  "Best-effort STATUS extraction from the value RUN-AGENT (or its
stand-in) returned. Real AGENT-STATE has STATUS as a slot; the test
stub passes a hash-table with a 'status' key. Anything we can't
recognize is reported as :unknown."
  (cond
    ((and (typep state 'standard-object)
          (find-method (function cl-harness/src/agent:agent-state-status)
                       '() (list (find-class 'standard-object)) nil))
     (handler-case (cl-harness/src/agent:agent-state-status state)
       (error () :unknown)))
    ((hash-table-p state)
     (or (gethash "status" state) :unknown))
    (t :unknown)))

(defun %step-event-payload (step result)
  (alist-hash-table
   `(("step_index" . ,(plan-step-index step))
     ("test_name" . ,(plan-step-test-name step))
     ("status" . ,(%symbol-status (develop-step-result-status result))))
   :test 'equal))

(defun %execute-step (step run-fn project-root system test-system
                      condition test-file logger
                      provider mcp-client)
  "Materialize the step's test, build a RUN-CONFIG, call RUN-FN, return
a DEVELOP-STEP-RESULT. The RUN-AGENT's own JSONL is written under
RUN-AGENT's normal logger; we do not interleave events with it here."
  (validate-test-source (plan-step-test-source step) (plan-step-index step))
  (materialize-test-source test-file (plan-step-test-source step))
  (let ((rc (plan-step->run-config
             step
             :project-root project-root
             :system system
             :test-system test-system
             :condition condition))
        (policy (make-tool-policy condition))
        (run-logger-path
         (merge-pathnames
          (format nil "develop-step-~D-~A-~A.jsonl"
                  (plan-step-index step)
                  (plan-step-test-name step)
                  (get-internal-real-time))
          (uiop:temporary-directory))))
    (%log-develop-event
     logger :step-start
     (alist-hash-table
      `(("step_index" . ,(plan-step-index step))
        ("test_name" . ,(plan-step-test-name step))
        ("issue" . ,(plan-step-issue step))
        ("transcript_path" . ,(namestring run-logger-path)))
      :test 'equal))
    (let* ((step-logger (open-run-logger run-logger-path))
           (state (unwind-protect
                       (funcall run-fn rc provider mcp-client policy step-logger)
                    (close-run-logger step-logger)))
           (status (%read-status-from-state state))
           (result (make-instance
                    'develop-step-result
                    :step-index (plan-step-index step)
                    :test-name (plan-step-test-name step)
                    :run-config rc
                    :status status
                    :run-agent-state state
                    :transcript-path run-logger-path)))
      (%log-develop-event logger :step-end
                          (%step-event-payload step result))
      result)))

(defun execute-plan (plan
                     &key project-root system test-system test-file
                          (condition :generic-mcp)
                          provider
                          mcp-client
                          log-path
                          (run-fn #'run-agent))
  "Run PLAN (list of PLAN-STEP) sequentially, stopping at the first
non-:passed outcome.

PROJECT-ROOT / SYSTEM / TEST-SYSTEM are the project context shared by
every step's RUN-CONFIG. TEST-FILE is the absolute path to the rove
file the planner-authored deftest forms get appended to; the
orchestrator does not own its lifecycle (caller creates and disposes).

PROVIDER and MCP-CLIENT are forwarded verbatim to the executor; the
orchestrator does not build them. Callers who want the harness's
default LLM + cl-mcp setup should use the higher-level wrapper that
will land alongside the P3 work; for P2 the recipe is to build them
from `cl-harness:fix`-style kwargs at the call site.

LOG-PATH, when supplied, is the develop-level JSONL transcript. The
events emitted are:
  :develop-start { project_root, system, test_system, plan_size }
  :plan          { steps: [...] }
  :step-start    { step_index, test_name, issue, transcript_path }
  :step-end      { step_index, test_name, status }
  :develop-end   { status, completed_steps, total_steps }

RUN-FN, when overridden, replaces RUN-AGENT for the duration. Tests
inject a stub here.

Returns a list of DEVELOP-STEP-RESULT in execution order."
  (check-type plan list)
  ;; Validate every step's test_source up-front so we never partially
  ;; materialize a broken plan.
  (dolist (step plan)
    (validate-test-source (plan-step-test-source step)
                          (plan-step-index step)))
  (let ((logger (%ensure-develop-logger log-path)))
    (unwind-protect
         (let ((results '()))
           (%log-develop-event
            logger :develop-start
            (alist-hash-table
             `(("project_root" . ,(princ-to-string (or project-root "")))
               ("system" . ,(or system ""))
               ("test_system" . ,(or test-system ""))
               ("plan_size" . ,(length plan)))
             :test 'equal))
           (%log-develop-event logger :plan (%plan-event-payload plan))
           (block run-loop
             (dolist (step plan)
               (let ((result (%execute-step step run-fn
                                            project-root system test-system
                                            condition test-file logger
                                            provider mcp-client)))
                 (push result results)
                 (unless (eq :passed (develop-step-result-status result))
                   (return-from run-loop)))))
           (let* ((reversed (nreverse results))
                  (final-status
                   (cond
                     ((null reversed) :empty)
                     ((every (lambda (r)
                               (eq :passed
                                   (develop-step-result-status r)))
                             reversed)
                      :passed)
                     (t (develop-step-result-status (car (last reversed)))))))
             (%log-develop-event
              logger :develop-end
              (alist-hash-table
               `(("status" . ,(%symbol-status final-status))
                 ("completed_steps" . ,(length reversed))
                 ("total_steps" . ,(length plan)))
               :test 'equal))
             reversed))
      (%close-develop-logger logger))))
