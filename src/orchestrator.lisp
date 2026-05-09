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
                #:plan-step-needs-exploration
                #:plan-development
                #:planner-error
                #:+supported-development-modes+)
  (:import-from #:cl-harness/src/explore
                #:run-explore-agent
                #:explore-result
                #:explore-result-memo)
  (:import-from #:cl-harness/src/abstraction
                #:parse-abstraction-decisions)
  (:import-from #:cl-harness/src/state
                #:make-develop-state
                #:develop-state-record-step-result
                #:develop-state-current-plan
                #:develop-state-current-step-index
                #:develop-state-replan-count
                #:develop-state-last-failure-test-name
                #:develop-state-status
                #:develop-state-limit-hit
                #:develop-state-integration-issues
                #:develop-state-step-results
                #:develop-state-reason
                #:develop-state-develop-spec
                #:develop-state-set-develop-spec
                #:develop-state-review-policy
                #:develop-state-test-revision-policy
                #:develop-state-review-replan-count
                #:develop-state-test-revision-count
                #:develop-state-record-review-decision
                #:develop-state-record-test-record
                #:develop-state-record-test-change-request
                #:develop-state-record-failure
                #:develop-state-failure-ledger
                #:develop-state-patch-records
                #:develop-state-repl-findings
                #:develop-state-set-project-summary)
  (:import-from #:cl-harness/src/project-summary
                #:gather-project-summary)
  (:import-from #:cl-harness/src/failure-ledger
                #:parse-failure-records-from-test-result
                #:failure-ledger-active
                #:mark-resolved-by
                #:failure-record-test-name
                #:failure-record-source-file)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record-path
                #:patch-record-diff-summary)
  (:import-from #:cl-harness/src/repl-finding
                #:repl-finding-hypothesis
                #:repl-finding-promoted-to-source-p
                #:repl-finding-mark-promoted)
  (:import-from #:cl-harness/src/step-result
                #:develop-step-result
                #:develop-step-result-step-index
                #:develop-step-result-test-name
                #:develop-step-result-run-config
                #:develop-step-result-status
                #:develop-step-result-run-agent-state
                #:develop-step-result-transcript-path
                #:develop-step-result-explore-result
                #:develop-step-result-abstraction-decisions)
  (:import-from #:cl-harness/src/verify
                #:verify-result-load
                #:verify-result-test)
  (:import-from #:cl-harness/src/integration
                #:gather-package-graph
                #:find-integration-issues
                #:integration-issue-kind
                #:integration-issue-package
                #:integration-issue-file
                #:integration-issue-description)
  (:import-from #:cl-harness/src/agent
                #:run-agent
                #:agent-state
                #:agent-state-final-verify
                #:agent-state-final-action
                #:agent-state-last-tool-errors)
  (:import-from #:cl-harness/src/action
                #:agent-action-criteria
                #:agent-action-rationale
                #:agent-action-test-source)
  (:import-from #:cl-harness/src/review
                #:generate-develop-spec
                #:review-development-artifact
                #:review-decision-approved-p
                #:review-decision-feedback
                #:make-test-record
                #:make-test-change-record)
  (:import-from #:cl-harness/src/model
                #:model-error
                #:model-error-type)
  (:export #:develop-step-result
           #:develop-step-result-status
           #:develop-step-result-step-index
           #:develop-step-result-run-config
           #:develop-step-result-run-agent-state
           #:develop-step-result-test-name
           #:develop-step-result-transcript-path
           #:develop-step-result-explore-result
           #:develop-step-result-abstraction-decisions
           #:develop-result
           #:develop-result-status
           #:develop-result-final-plan
           #:develop-result-step-results
           #:develop-result-replan-count
           #:develop-result-limit-hit
           #:develop-result-develop-state
           #:develop-result-abstraction-ledger
           #:develop-result-integration-issues
           #:develop-result-reason
           #:validate-test-source
           #:materialize-test-source
           #:plan-step->run-config
           #:execute-plan
           #:develop
           #:+supported-development-modes+))

(in-package #:cl-harness/src/orchestrator)

;; --- result ---------------------------------------------------------------
;;
;; DEVELOP-STEP-RESULT lives in CL-HARNESS/SRC/STEP-RESULT (extracted
;; so callers that need the class without pulling orchestrator's
;; dependency surface — notably SUBTASK-SUMMARY — can :import-from
;; that module). The orchestrator's :import-from + :export above
;; preserves the prior public spelling: external callers that wrote
;; CL-HARNESS/SRC/ORCHESTRATOR:DEVELOP-STEP-RESULT-X keep working,
;; because :import-from shares symbol identity.

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
their own lines. The directory is created if necessary.

Also invalidates the corresponding cached FASL via
ASDF:APPLY-OUTPUT-TRANSLATIONS — without this step, asdf:load-system
:force t in the executor's verify path can reuse a stale FASL that
predates the append (it only propagates :force to the named system,
not to package-inferred subsystems). Symptom observed during
develop-benchmarks 100-greet live verification: the second deftest
the planner authored never showed up in run-tests output even
though it was on disk."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :append
                            :if-does-not-exist :create
                            :element-type 'character)
    (terpri out)
    (write-string source out)
    (terpri out)
    (finish-output out))
  (let ((fasl (handler-case
                  (asdf:apply-output-translations
                   (compile-file-pathname (pathname path)))
                (error () nil))))
    (when (and fasl (probe-file fasl))
      (handler-case (delete-file fasl) (error () nil))))
  (values))

(defun %resolve-test-file-path (project-root test-file)
  "Resolve TEST-FILE relative to PROJECT-ROOT when it is not absolute."
  (let ((path (pathname test-file)))
    (if (uiop:absolute-pathname-p path)
        path
        (merge-pathnames path (uiop:ensure-directory-pathname project-root)))))

(defun plan-step->run-config (step
                              &key project-root system test-system
                                   (condition :generic-mcp)
                                   limits)
  "Build a RUN-CONFIG from PLAN-STEP plus a per-execute-plan template.
PROJECT-ROOT / SYSTEM / TEST-SYSTEM / CONDITION are shared across all
steps in a plan. LIMITS, when supplied, replaces the make-run-config
default (typically used by callers that need a higher max-patches /
max-turns budget than the conservative MVP defaults — greenfield
develop runs do)."
  (apply #'make-run-config
         :project-root project-root
         :system system
         :test-system test-system
         :issue (plan-step-issue step)
         :condition condition
         (when limits (list :limits limits))))

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
    ((typep state 'cl-harness/src/agent:agent-state)
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

(defun %enriched-issue (step memo)
  "Return the issue string fed to the implement step. When MEMO is
non-empty, prepend it as a `Prior exploration:` block so the
executor inherits the explore findings as plain text in the
initial user prompt."
  (if (and memo (plusp (length memo)))
      (format nil "## Prior exploration (read-only)~%~A~%~%## Task~%~A"
              memo (plan-step-issue step))
      (plan-step-issue step)))

(defun %most-recent-patch-on-file (state path)
  "Return the most recent PATCH-RECORD on PATH from STATE's patch-records,
or NIL when none. Walks newest-first. STATE may be NIL (returns NIL);
PATH may be NIL or a pathname/string."
  (when (and state path)
    (let ((target (pathname path)))
      (find-if (lambda (p)
                 (let ((pp (patch-record-path p)))
                   (and pp (equal (namestring pp)
                                  (namestring target)))))
               (reverse (develop-state-patch-records state))))))

(defun %record-and-resolve-failures (develop-state state step)
  "When DEVELOP-STATE and STATE (an AGENT-STATE) supply a verify-result
with a test-result hash-table, parse the failed_tests into
FAILURE-RECORDs and append them to DEVELOP-STATE's failure-ledger.
Any prior-active failure whose test-name is no longer present is
moved to :RESOLVED via MARK-RESOLVED-BY, attributed to the most
recent patch-record on the same source file (or NIL when no patch
matches). No-op when develop-state is NIL, when state is not an
AGENT-STATE (test stubs may pass hash-tables), or when the verify
slot is empty."
  (when (and develop-state (typep state 'agent-state))
    (let* ((vr (agent-state-final-verify state))
           (test-result (and vr (verify-result-test vr))))
      (when test-result
        (let* ((ledger (develop-state-failure-ledger develop-state))
               (prior-active (copy-list (failure-ledger-active ledger)))
               (new-records
                (parse-failure-records-from-test-result
                 test-result
                 :verify-source :incremental
                 :related-step-index (plan-step-index step)))
               (new-test-names (mapcar #'failure-record-test-name
                                       new-records)))
          (dolist (prior prior-active)
            (unless (member (failure-record-test-name prior) new-test-names
                            :test #'equal)
              (mark-resolved-by
               ledger prior
               :patch (%most-recent-patch-on-file
                       develop-state
                       (failure-record-source-file prior)))))
          (dolist (rec new-records)
            (develop-state-record-failure develop-state rec)))))))

(defun %hypothesis-in-diff-p (hypothesis diff-summary)
  "Case-folded substring match of HYPOTHESIS within DIFF-SUMMARY.
Returns T when DIFF-SUMMARY non-NIL and HYPOTHESIS appears (any case)
within it. Defensive: NIL inputs yield NIL."
  (and (stringp hypothesis) (plusp (length hypothesis))
       (stringp diff-summary) (plusp (length diff-summary))
       (search (string-downcase hypothesis)
               (string-downcase diff-summary))))

(defun %find-matching-patch (hypothesis develop-state)
  "Walk DEVELOP-STATE's patch-records (oldest first) and return the
first PATCH-RECORD whose diff-summary contains HYPOTHESIS (case-fold
substring). Returns NIL when no patch matches."
  (find-if (lambda (p)
             (%hypothesis-in-diff-p hypothesis
                                    (patch-record-diff-summary p)))
           (develop-state-patch-records develop-state)))

(defun %promote-matching-findings (develop-state)
  "Walk DEVELOP-STATE's not-yet-promoted REPL-FINDINGs; for each whose
hypothesis appears (case-fold substring) in any patch-record's
diff-summary, flip the promoted-to-source-p flag via
REPL-FINDING-MARK-PROMOTED with :linked-patch <matching-patch>.
Already-promoted findings are skipped; NIL DEVELOP-STATE is a no-op
(returns NIL). Best-effort: never raises. Returns DEVELOP-STATE."
  (when develop-state
    (dolist (finding (develop-state-repl-findings develop-state))
      (unless (repl-finding-promoted-to-source-p finding)
        (let ((patch (%find-matching-patch
                      (repl-finding-hypothesis finding)
                      develop-state)))
          (when patch
            (repl-finding-mark-promoted finding :linked-patch patch))))))
  develop-state)

;; --- review gates --------------------------------------------------------

(defun %review-enabled-p (develop-state)
  (and develop-state
       (not (eq :none (develop-state-review-policy develop-state)))))

(defun %call-review (review-fn kind
                     &key develop-state provider plan step test-change-action
                          implementation-summary)
  "Run REVIEW-FN and record the decision on DEVELOP-STATE.
Provider-less/stub paths are handled by REVIEW-FN's default
implementation."
  (let ((decision
          (funcall review-fn kind
                   :provider provider
                   :develop-spec (and develop-state
                                      (develop-state-develop-spec develop-state))
                   :develop-state develop-state
                   :plan plan
                   :step step
                   :test-change-action test-change-action
                   :implementation-summary implementation-summary)))
    (when develop-state
      (develop-state-record-review-decision develop-state decision))
    decision))

(defun %record-plan-tests (develop-state plan)
  "Record approved generated tests on DEVELOP-STATE."
  (when develop-state
    (dolist (step plan)
      (develop-state-record-test-record
       develop-state
       (make-test-record
        :step-index (plan-step-index step)
        :test-name (plan-step-test-name step)
        :source (plan-step-test-source step)
        :criteria (cl-harness/src/planner:plan-step-acceptance-criteria
                   step))))))

(defun %review-plan-and-tests (plan review-fn provider develop-state)
  "Return (VALUES APPROVED-P FEEDBACK). Runs plan then test review."
  (if (not (%review-enabled-p develop-state))
      (progn (%record-plan-tests develop-state plan)
             (values t ""))
      (let ((plan-decision (%call-review
                            review-fn :plan
                            :develop-state develop-state
                            :provider provider
                            :plan plan)))
        (if (not (review-decision-approved-p plan-decision))
            (values nil (review-decision-feedback plan-decision))
            (let ((test-decision (%call-review
                                  review-fn :tests
                                  :develop-state develop-state
                                  :provider provider
                                  :plan plan)))
              (if (review-decision-approved-p test-decision)
                  (progn (%record-plan-tests develop-state plan)
                         (values t ""))
                  (values nil (review-decision-feedback test-decision))))))))

(defun %state-status-from-agent-state (state)
  (and (typep state 'agent-state)
       (cl-harness/src/agent:agent-state-status state)))

(defun %maybe-handle-test-change-request (step state test-file review-fn
                                          provider develop-state)
  "Approve and materialize an additive TEST_CHANGE_REQUEST.
Returns true when a request was approved and the caller should rerun
the same step."
  (when (and (%review-enabled-p develop-state)
             (eq :additive-only
                 (develop-state-test-revision-policy develop-state))
             (eq :test-change-request (%state-status-from-agent-state state)))
    (let* ((action (agent-state-final-action state))
           (source (and action (agent-action-test-source action)))
           (request (make-test-change-record
                     :step-index (plan-step-index step)
                     :criteria (and action (agent-action-criteria action))
                     :rationale (and action (agent-action-rationale action))
                     :test-source source))
           (decision (%call-review
                      review-fn :test-change
                      :develop-state develop-state
                      :provider provider
                      :step step
                      :test-change-action request)))
      (develop-state-record-test-change-request develop-state request)
      (when (and (review-decision-approved-p decision)
                 (stringp source)
                 (search "(deftest " source))
        (validate-test-source source (plan-step-index step))
        (materialize-test-source (%resolve-test-file-path
                                  (develop-state-project-root develop-state)
                                  test-file)
                                 source)
        (incf (develop-state-test-revision-count develop-state))
        t))))

(defun %review-implementation (step state review-fn provider develop-state)
  "Return true when implementation review approves STATE."
  (if (or (not (%review-enabled-p develop-state))
          (not (eq :passed (%read-status-from-state state))))
      t
      (let ((decision
              (%call-review
               review-fn :implementation
               :develop-state develop-state
               :provider provider
               :step step
               :implementation-summary
               (format nil "Step ~D (~A) passed verification."
                       (plan-step-index step)
                       (plan-step-test-name step)))))
        (review-decision-approved-p decision))))

(defun %execute-step (step run-fn project-root system test-system
                      condition test-file logger
                      provider mcp-client run-limits explore-fn
                      &key develop-state
                           (review-fn #'review-development-artifact)
                           (max-test-revisions 3))
  "Materialize the step's test, optionally run an exploration sub-agent,
build a RUN-CONFIG (with the explore memo prepended to the issue
when present), call RUN-FN, return a DEVELOP-STEP-RESULT. The
RUN-AGENT's own JSONL is written under RUN-AGENT's normal logger;
we do not interleave events with it here.

When PLAN-STEP's needs-exploration is :LIGHTWEIGHT or :DEEP and
EXPLORE-FN is non-nil, an explore loop runs FIRST against the same
provider/mcp-client with policy :EXPLORE (read-only). The memo
returned from that loop is captured in the develop-step-result
and prepended to the implement issue.

When DEVELOP-STATE is non-nil, the step's PLAN-STEP-INDEX is written
to its CURRENT-STEP-INDEX slot on entry and cleared (set to NIL) on
exit via UNWIND-PROTECT. Used by MAKE-CONTEXT-VIEW (Phase C) to
filter ledger entries to those bound to the active step. Inert when
DEVELOP-STATE is NIL (e.g. test stubs that exercise %execute-step
without a develop-state)."
  (validate-test-source (plan-step-test-source step) (plan-step-index step))
  (materialize-test-source (%resolve-test-file-path project-root test-file)
                           (plan-step-test-source step))
  (when develop-state
    (setf (develop-state-current-step-index develop-state)
          (plan-step-index step)))
  (unwind-protect
       (let* ((needs (plan-step-needs-exploration step))
              (do-explore (and explore-fn
                               needs
                               (not (eq :none needs))))
              (explore-policy (when do-explore (make-tool-policy :explore)))
              (run-logger-path
               (merge-pathnames
                (format nil "develop-step-~D-~A-~A.jsonl"
                        (plan-step-index step)
                        (plan-step-test-name step)
                        (get-internal-real-time))
                (uiop:temporary-directory)))
              (explore-orient-config
               (when do-explore
                 (make-run-config :project-root project-root
                                  :system system
                                  :test-system test-system
                                  :issue (plan-step-issue step)
                                  :condition :explore))))
         (%log-develop-event
          logger :step-start
          (alist-hash-table
           `(("step_index" . ,(plan-step-index step))
             ("test_name" . ,(plan-step-test-name step))
             ("issue" . ,(plan-step-issue step))
             ("needs_exploration" . ,(string-downcase
                                      (symbol-name (or needs :none))))
             ("transcript_path" . ,(namestring run-logger-path)))
           :test 'equal))
         (let* ((step-logger (open-run-logger run-logger-path))
                (explore-result
                 (when do-explore
                   (handler-case
                       (funcall explore-fn
                                explore-orient-config provider mcp-client
                                explore-policy step-logger
                                :plan-step step
                                :develop-state develop-state)
                     (error (c)
                       (%log-develop-event
                        logger :explore-aborted
                        (alist-hash-table
                         `(("step_index" . ,(plan-step-index step))
                           ("message" . ,(princ-to-string c)))
                         :test 'equal))
                       nil))))
                (memo (when explore-result (explore-result-memo explore-result)))
                (abstraction-decisions
                 (when memo
                   (parse-abstraction-decisions memo
                                                :step-index (plan-step-index step))))
                (rc (make-run-config :project-root project-root
                                     :system system
                                     :test-system test-system
                                     :issue (%enriched-issue step memo)
                                     :condition condition
                                     :limits (or run-limits
                                                 (cl-harness/src/config:make-default-limits))))
                (policy (make-tool-policy condition))
                (state
                 (unwind-protect
                      (block run-step
                        (loop
                          for state = (funcall run-fn rc provider mcp-client
                                               policy step-logger
                                               :develop-state develop-state)
                          do (if (and develop-state
                                      (< (develop-state-test-revision-count
                                          develop-state)
                                          max-test-revisions)
                                      (%maybe-handle-test-change-request
                                       step state test-file review-fn provider
                                       develop-state))
                                 (progn
                                   (%log-develop-event
                                    logger :test-change-applied
                                    (alist-hash-table
                                     `(("step_index" . ,(plan-step-index step)))
                                     :test 'equal)))
                                 (return-from run-step state))))
                   (close-run-logger step-logger)))
                (status (let ((raw (%read-status-from-state state)))
                          (if (and (eq :passed raw)
                                   (not (%review-implementation
                                         step state review-fn provider
                                         develop-state)))
                              :review-rejected
                              raw)))
                (result (make-instance
                         'develop-step-result
                         :step-index (plan-step-index step)
                         :test-name (plan-step-test-name step)
                         :run-config rc
                         :status status
                         :run-agent-state state
                         :transcript-path run-logger-path
                         :explore-result explore-result
                         :abstraction-decisions abstraction-decisions)))
           (%record-and-resolve-failures develop-state state step)
           (%promote-matching-findings develop-state)
           (when abstraction-decisions
             (%log-develop-event
              logger :abstraction-decision
              (alist-hash-table
               `(("step_index" . ,(plan-step-index step))
                 ("decisions"
                  . ,(map 'vector
                          (lambda (d)
                            (alist-hash-table
                             `(("kind" . ,(string-downcase
                                           (symbol-name
                                            (cl-harness/src/abstraction:abstraction-decision-kind d))))
                               ("name" . ,(cl-harness/src/abstraction:abstraction-decision-name d))
                               ("rationale" . ,(cl-harness/src/abstraction:abstraction-decision-rationale d)))
                             :test 'equal))
                          abstraction-decisions)))
               :test 'equal)))
           (%log-develop-event logger :step-end
                               (%step-event-payload step result))
           result))
    (when develop-state
      (setf (develop-state-current-step-index develop-state) nil))))

(defun execute-plan (plan
                     &key project-root system test-system test-file
                          (condition :generic-mcp)
                          provider
                          mcp-client
                          run-limits
                          log-path
                          (run-fn #'run-agent)
                          (explore-fn #'run-explore-agent)
                          develop-state
                          (review-fn #'review-development-artifact)
                          (max-test-revisions 3))
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
                                            provider mcp-client run-limits
                                            explore-fn
                                            :develop-state develop-state
                                            :review-fn review-fn
                                            :max-test-revisions
                                            max-test-revisions)))
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

;; --- develop (P3): plan + execute + replan loop -------------------------

(defclass develop-result ()
  ((status :initarg :status :reader develop-result-status)
   (final-plan :initarg :final-plan :reader develop-result-final-plan)
   (step-results :initarg :step-results
                 :reader develop-result-step-results)
   (replan-count :initarg :replan-count
                 :initform 0
                 :reader develop-result-replan-count)
   (limit-hit :initarg :limit-hit
              :initform nil
              :reader develop-result-limit-hit)
   (integration-issues :initarg :integration-issues
                       :initform nil
                       :reader develop-result-integration-issues)
   (develop-state :initarg :develop-state
                  :initform nil
                  :reader develop-result-develop-state
                  :documentation "Optional back-reference to the
DEVELOP-STATE that produced this result. Populated by the
orchestrator's DEVELOP function for downstream consumers
(structured reporting via FORMAT-DEVELOP-STATE-REPORT, etc.).
NIL when the develop-result was constructed by something other
than the orchestrator (e.g. unit-test stubs).")
   (reason :initarg :reason
           :initform nil
           :reader develop-result-reason
           :documentation "Failure-mode classification keyword set
by the orchestrator when STATUS is :ERROR or :GIVE-UP with a
specific reason. NIL on the success path."))
  (:documentation
   "Outcome of a DEVELOP run.
STATUS is :PASSED on a fully-passing plan, :STUCK when the
replanner returned the same failing step a second time, and either
:LIMIT-EXHAUSTED or the underlying step's terminal status when an
intermediate plan failed without recovery. STEP-RESULTS is the flat
list of every step run across every replan round, in execution
order. FINAL-PLAN is the plan currently active at the moment the
run terminated. INTEGRATION-ISSUES (v0.4 Phase 5) is the list of
INTEGRATION-ISSUE structures the static check found after all
steps :PASSED; NIL when no run reached :PASSED or the project is
clean."))

(defun develop-result-abstraction-ledger (result)
  "Return the flat list of every ABSTRACTION-DECISION captured across
RESULT's step-results, preserving step order. v0.4 Phase 4."
  (loop for sr in (develop-result-step-results result)
        append (develop-step-result-abstraction-decisions sr)))

(defun %apply-mode-to-plan (plan mode)
  "Mutate PLAN in place to enforce the development MODE (v0.4 Phase 6).
:TOP-DOWN  → every step's needs-exploration becomes :NONE (skip the
             explore sub-agent regardless of what the planner asked for).
:BOTTOM-UP → :NONE / NIL get promoted to :LIGHTWEIGHT so each step
             gets at least a quick read-only look at the existing
             surface before implementing.
:MIXED     → leave the planner's choice untouched.
The mutation is the orchestrator's mechanical enforcement layer.
The planner already sees a Mode: ... line in its user prompt
(plan-development), so a well-behaved LLM produces a plan matching
the mode and this layer is a no-op; misaligned plans get corrected."
  (dolist (step plan)
    (let ((current (plan-step-needs-exploration step)))
      (case mode
        (:top-down
         (setf (plan-step-needs-exploration step) :none))
        (:bottom-up
         (when (or (null current) (eq current :none))
           (setf (plan-step-needs-exploration step) :lightweight)))
        ;; :mixed (and the default) — leave alone.
        (t nil))))
  plan)

(defun %first-test-name (plan)
  "Return the test_name of PLAN's first PLAN-STEP, or NIL when PLAN is
empty. Used for stuck detection."
  (and (consp plan) (plan-step-test-name (car plan))))

(defun %extract-isError-text (result)
  "Return the first content[].text from RESULT (a tool-result hash)
truncated to 800 chars; NIL when RESULT is NIL or has no text. Used
to extract the user-visible error text from a verify-task load-result
or similar."
  (when (hash-table-p result)
    (let ((content (gethash "content" result)))
      (when (and content (vectorp content) (plusp (length content)))
        (let ((text (gethash "text" (aref content 0))))
          (when (and (stringp text) (plusp (length text)))
            (let ((flat (substitute #\Space #\Newline text)))
              (if (> (length flat) 800)
                  (subseq flat 0 800)
                  flat))))))))

(defun %render-tool-error-entry (idx entry)
  "Format one tool-error ring entry for the failure-context block.
IDX is 1-based for display ordering."
  (format nil "~D. [turn ~A] ~A ~A → ~A"
          idx
          (getf entry :turn)
          (getf entry :tool-name)
          (getf entry :args-summary)
          (getf entry :error-text)))

(defun %render-failed-tests-summary (test-result)
  "Emit a short human-readable summary of failed_tests from a
run-tests RESULT hash. Returns NIL when no failed tests were
recorded; otherwise a multi-line string with up to 3 entries."
  (when (hash-table-p test-result)
    (let ((failed (gethash "failed_tests" test-result)))
      (when (and failed (or (listp failed) (vectorp failed)))
        (let* ((seq (if (vectorp failed) (coerce failed 'list) failed))
               (capped (subseq seq 0 (min 3 (length seq)))))
          (when capped
            (with-output-to-string (s)
              (dolist (rec capped)
                (let ((name (or (and (hash-table-p rec)
                                     (gethash "test_name" rec))
                                "(unknown)"))
                      (desc (or (and (hash-table-p rec)
                                     (gethash "description" rec))
                                "")))
                  (format s "- ~A: ~A~%" name desc))))))))))

(defun %failure-context (failed-step-result)
  "Build the multi-paragraph failure-context block fed back to the
planner on a replan round. Sections with empty data are omitted.
Reads:
  - the step-result's status / index / test-name (always present)
  - run-agent-state's final-verify load-result and test-result
  - run-agent-state's last-tool-errors ring (most recent first)"
  (let* ((state (develop-step-result-run-agent-state failed-step-result))
         (vr (and state (typep state 'agent-state)
                  (agent-state-final-verify state)))
         (load-text (and vr (%extract-isError-text (verify-result-load vr))))
         (test-summary (and vr (%render-failed-tests-summary
                                (verify-result-test vr))))
         (ring (and state (typep state 'agent-state)
                    (agent-state-last-tool-errors state))))
    (with-output-to-string (s)
      (format s "step ~A (test_name=~A) terminated with status :~A."
              (develop-step-result-step-index failed-step-result)
              (develop-step-result-test-name failed-step-result)
              (%symbol-status (develop-step-result-status failed-step-result)))
      (when load-text
        (format s "~%~%### Last verify error (load-system)~%~A" load-text))
      (when test-summary
        (format s "~%~%### Last verify error (run-tests)~%~A" test-summary))
      (when ring
        (format s "~%~%### Recent tool errors (most recent first; agent-LLM-issued only)~%")
        (loop for entry in ring
              for idx from 1
              do (format s "~A~%" (%render-tool-error-entry idx entry)))))))

(defun %plan-with-review (goal planner-fn review-fn provider state mode
                          project-root system test-system project-inventory
                          prior-plan failure-context max-review-replans)
  "Call PLANNER-FN until plan/test review approves or review budget
is exhausted. Returns NIL after stamping STATE on budget exhaustion."
  (loop
    for plan = (%apply-mode-to-plan
                (funcall planner-fn goal
                         :project-root project-root
                         :system system
                         :test-system test-system
                         :provider provider
                         :project-inventory project-inventory
                         :mode mode
                         :prior-plan prior-plan
                         :failure-context failure-context
                         :develop-state state)
                mode)
    do (multiple-value-bind (approved-p feedback)
           (%review-plan-and-tests plan review-fn provider state)
         (when approved-p
           (return plan))
         (when (>= (develop-state-review-replan-count state)
                   max-review-replans)
           (setf (develop-state-status state) :limit-exhausted
                 (develop-state-limit-hit state) :max-review-replans)
           (return nil))
         (incf (develop-state-review-replan-count state))
         (setf prior-plan plan
               failure-context
               (format nil "Plan/test review rejected the previous output: ~A"
                       feedback)))))

(defun develop (goal
                &key project-root system test-system test-file
                     provider mcp-client
                     (condition :generic-mcp)
                     run-limits
                     project-inventory
                     (mode :mixed)
                     log-path
                     (max-replans 3)
                     (review-policy :none)
                     (test-revision-policy :additive-only)
                     (max-review-replans 2)
                     (max-test-revisions 3)
                     (spec-fn #'generate-develop-spec)
                     (review-fn #'review-development-artifact)
                     (planner-fn #'plan-development)
                     (run-fn #'run-agent)
                     (explore-fn #'run-explore-agent))
  "Plan, execute, and replan-on-failure end-to-end.

Workflow:
  1. Call PLANNER-FN(GOAL, ...) to obtain the initial plan.
  2. EXECUTE-PLAN the result; record outcomes on STATE.
  3. If the last step :PASSED -> success.
  4. Otherwise, if MAX-REPLANS is exhausted -> :LIMIT-EXHAUSTED.
  5. Otherwise, call PLANNER-FN with PRIOR-PLAN and FAILURE-CONTEXT
     populated to ask for a revised plan.
  6. If the revised plan's first step has the same TEST-NAME as the
     failed step -> :STUCK (no progress).
  7. Otherwise, EXECUTE-PLAN the revised plan and loop.

Returns a DEVELOP-RESULT capturing the final status, the final
plan, every step result across every round, the replan count, and
which budget (if any) tripped.

Internally the loop drives a DEVELOP-STATE (Phase A of the
context-management refactor); the DEVELOP-RESULT is built from
that state at the end. Callers do not see the state object --
DEVELOP's keyword arguments and return type are unchanged.

The orchestrator does not own PROVIDER or MCP-CLIENT; callers build
them per cl-harness:fix conventions and pass them through. PLANNER-FN
and RUN-FN are injection points for tests; defaults are
PLAN-DEVELOPMENT and RUN-AGENT respectively.

LOG-PATH, when supplied, is the develop-level JSONL path. EXECUTE-PLAN
appends per-round events; DEVELOP wraps them with replan-trigger
events so a single transcript shows the full multi-round history.
(EXECUTE-PLAN's own develop-start / develop-end events are emitted
once per round; readers should disambiguate by replan-index, which
is added to the payload here.)

MODE (v0.4 Phase 6) selects the development style:
:TOP-DOWN  -- implement-first; every plan-step's needs-exploration is
              coerced to :NONE before execution.
:BOTTOM-UP -- explore-first; :NONE / NIL needs-exploration is promoted
              to :LIGHTWEIGHT.
:MIXED     -- let the planner decide per step (default).

A typed MODEL-ERROR raised by the LLM transport layer (auth /
HTTP / shape failure inside complete-chat) is caught at the top
of the planner+execute body. The run terminates with status
:ERROR and reason set to the model-error's :KIND keyword. The
post-success integration-check is skipped on the error path
(its existing :PASSED guard already handles this), and the
final DEVELOP-RESULT carries the reason through to callers."
  (check-type goal string)
  (check-type max-replans (integer 0))
  (unless (member mode +supported-development-modes+)
    (error "develop: unsupported :mode ~S; expected one of ~S"
           mode +supported-development-modes+))
  (let ((state (make-develop-state :goal goal
                                   :project-root project-root
                                   :system system
                                   :test-system test-system
                                   :condition condition
                                   :run-limits run-limits
                                   :project-inventory project-inventory
                                   :mode mode
                                   :review-policy review-policy
                                   :test-revision-policy
                                   test-revision-policy)))
    ;; Phase I auto-gather: populate the structured project-summary
    ;; slot from disk so the :planning view sees it alongside the
    ;; legacy project-inventory text. Best-effort -- a malformed
    ;; project tree returns NIL and the develop loop continues with
    ;; the inventory text alone.
    (handler-case
        (develop-state-set-project-summary
         state
         (gather-project-summary :project-root project-root
                                 :system system
                                 :test-system test-system))
      (error () nil))
    ;; LLM-bearing body: planner-fn (initial + replan) and execute-plan
    ;; both reach complete-chat. A typed MODEL-ERROR raised by the
    ;; transport layer is caught here, recorded on STATE as
    ;; :STATUS :ERROR with :REASON set to the model-error's :KIND, and
    ;; control falls through to the integration-check guard (which
    ;; skips on non-:PASSED status) and the final develop-result
    ;; construction below.
    (handler-case
        (progn
          (when (%review-enabled-p state)
            (develop-state-set-develop-spec
             state
             (funcall spec-fn goal
                      :provider provider
                      :develop-state state
                      :project-root project-root
                      :system system
                      :test-system test-system)))
          (setf (develop-state-current-plan state)
                (%plan-with-review
                 goal planner-fn review-fn provider state mode
                 project-root system test-system project-inventory
                 nil nil max-review-replans))
          (when (null (develop-state-current-plan state))
            (return-from develop
              (make-instance 'develop-result
                             :status (develop-state-status state)
                             :reason (develop-state-reason state)
                             :final-plan nil
                             :step-results nil
                             :replan-count (develop-state-replan-count state)
                             :limit-hit (develop-state-limit-hit state)
                             :develop-state state)))
          (loop
            (let* ((round-results (execute-plan
                                   (develop-state-current-plan state)
                                   :project-root project-root
                                   :system system
                                   :test-system test-system
                                   :test-file test-file
                                   :condition condition
                                   :provider provider
                                   :mcp-client mcp-client
                                   :run-limits run-limits
                                   :log-path log-path
                                   :run-fn run-fn
                                   :explore-fn explore-fn
                                   :develop-state state
                                   :review-fn review-fn
                                   :max-test-revisions max-test-revisions))
                   (last-result (car (last round-results))))
              (dolist (r round-results)
                (develop-state-record-step-result state r))
              (cond
                ((null last-result)
                 (setf (develop-state-status state) :empty)
                 (return))
                ((eq :passed (develop-step-result-status last-result))
                 (setf (develop-state-status state) :passed)
                 (return))
                ((>= (develop-state-replan-count state) max-replans)
                 (setf (develop-state-status state) :limit-exhausted
                       (develop-state-limit-hit state) :max-replans)
                 (return))
                (t
                 (let ((this-failure (develop-step-result-test-name last-result)))
                   (when (and (develop-state-last-failure-test-name state)
                              (equal (develop-state-last-failure-test-name state)
                                     this-failure))
                     (setf (develop-state-status state) :stuck
                           (develop-state-limit-hit state) :no-progress)
                     (return))
                   (setf (develop-state-last-failure-test-name state)
                         this-failure))
                 (incf (develop-state-replan-count state))
                 (let ((new-plan (%plan-with-review
                                  goal planner-fn review-fn provider state mode
                                  project-root system test-system
                                  project-inventory
                                  (develop-state-current-plan state)
                                  (%failure-context last-result)
                                  max-review-replans)))
                   (when (null new-plan)
                     (return))
                   (when (equal (%first-test-name new-plan)
                                (develop-state-last-failure-test-name state))
                     (setf (develop-state-status state) :stuck
                           (develop-state-limit-hit state) :no-progress)
                     (return))
                   (setf (develop-state-current-plan state) new-plan)))))))
      (model-error (c)
        (let ((kind (model-error-type c)))
          (setf (develop-state-status state)
                (if (eq kind :empty-content) :give-up :error)
                (develop-state-reason state) kind))))
    (when (and (eq (develop-state-status state) :passed) project-root)
      (handler-case
          (let ((issues (find-integration-issues
                         (gather-package-graph project-root))))
            (when log-path
              (let ((logger (open-run-logger log-path)))
                (unwind-protect
                     (log-event
                      logger :integration-check
                      (alist-hash-table
                       `(("issue_count" . ,(length issues))
                         ("issues"
                          . ,(map 'vector
                                  (lambda (i)
                                    (alist-hash-table
                                     `(("kind"
                                        . ,(string-downcase
                                            (symbol-name
                                             (integration-issue-kind i))))
                                       ("package"
                                        . ,(integration-issue-package i))
                                       ("file"
                                        . ,(let ((f (integration-issue-file i)))
                                             (if f (namestring f) "")))
                                       ("description"
                                        . ,(integration-issue-description i)))
                                     :test 'equal))
                                  issues)))
                       :test 'equal))
                  (close-run-logger logger))))
            (setf (develop-state-integration-issues state) issues))
        (error () nil)))
    (make-instance 'develop-result
                   :status (develop-state-status state)
                   :reason (develop-state-reason state)
                   :final-plan (develop-state-current-plan state)
                   :step-results (develop-state-step-results state)
                   :replan-count (develop-state-replan-count state)
                   :limit-hit (develop-state-limit-hit state)
                   :integration-issues
                   (develop-state-integration-issues state)
                   :develop-state state)))
