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
                #:planner-error-message
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
                #:+supported-review-policies+
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
                #:develop-state-set-project-summary
                #:develop-state-project-root)
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

(defun %deftest-symbol-p (sym)
  "True when SYM names rove's deftest macro (unqualified or
package-qualified `rove:deftest'). Symbol equality uses string-equal
because the reader returns interned symbols from arbitrary packages
and we want to recognise the deftest semantics regardless of which
package the symbol was read into."
  (and (symbolp sym)
       (string-equal "DEFTEST" (symbol-name sym))))

(defun %skip-form-p (form)
  "True when FORM is a function call to rove's SKIP macro (unqualified
or package-qualified). Used by VALIDATE-TEST-SOURCE to reject
test_source bodies that would short-circuit assertions — that's a
test-weakening pattern Finding 1 explicitly forbids."
  (and (consp form)
       (symbolp (car form))
       (string-equal "SKIP" (symbol-name (car form)))))

(defun %tree-contains-skip-p (tree)
  "Recursively walk TREE for any %SKIP-FORM-P node. Used by
VALIDATE-TEST-SOURCE to reject any (skip ...) anywhere in the
deftest body, not just at the top level."
  (cond
    ((atom tree) nil)
    ((%skip-form-p tree) t)
    (t (some #'%tree-contains-skip-p (cdr tree)))))

(defun %pre-create-referenced-packages (source)
  "Scan SOURCE for package-qualifier prefixes (NAME: or NAME::) and
ensure each NAME has at least an empty package, plus that the
symbol referenced after the colon(s) is interned (and, for single-
colon NAME:SYM, exported) so the reader can resolve qualified
symbols without package-error.

Used by %READ-SINGLE-FORM-FROM-STRING so the validator can inspect
test_source forms that legitimately reference packages not yet
loaded — most importantly the new system's package that the
planner is about to create (e.g. `(deftest fizz-buzz::sample
(ok (= 1 (fizz-buzz:fizz-buzz 1))))`). Without this step every
greenfield develop run dies in plan validation with `Package
FIZZ-BUZZ does not exist.` or `Symbol FIZZ-BUZZ not found in
the FIZZ-BUZZ package.` (regression discovered 2026-05-27
bench-cycle).

Created packages are bare (:USE nil) and the interned symbols
have no values / functions / classes attached — they exist only
to satisfy the reader. Side-effect on the worker image is
bounded: develop runs use ephemeral sandbox workers, so leaked
empty packages don't outlive the bench run.

Scanner is conservative: it skips strings and line comments to
avoid hallucinating package names from inside literal data."
  (let ((i 0) (len (length source)))
    (labels ((symbol-char-p (c)
               (or (alphanumericp c)
                   (member c '(#\- #\_ #\/ #\* #\+
                               #\! #\? #\< #\> #\=))))
             (scan-name ()
               (let ((start i))
                 (loop while (and (< i len)
                                  (symbol-char-p (char source i)))
                       do (incf i))
                 (when (> i start)
                   (subseq source start i)))))
      (loop while (< i len) do
        (let ((c (char source i)))
          (cond
            ((char= c #\")
             (incf i)
             (loop while (and (< i len) (char/= (char source i) #\"))
                   do (when (and (char= (char source i) #\\)
                                 (< (1+ i) len))
                        (incf i))
                      (incf i))
             (when (< i len) (incf i)))
            ((char= c #\;)
             (loop while (and (< i len) (char/= (char source i) #\Newline))
                   do (incf i)))
            ((or (alpha-char-p c) (symbol-char-p c))
             (let ((pkg-name (scan-name)))
               (when (and pkg-name (< i len)
                          (char= (char source i) #\:))
                 (let* ((upcased (string-upcase pkg-name))
                        (pkg
                         (or (find-package upcased)
                             (handler-case
                                 (make-package upcased :use nil)
                               (error () nil)))))
                   (incf i)
                   (let ((external-only-p t))
                     (when (and (< i len)
                                (char= (char source i) #\:))
                       (incf i)
                       (setf external-only-p nil))
                     (let ((sym-name (scan-name)))
                       (when (and pkg sym-name (plusp (length sym-name)))
                         (handler-case
                             (let ((upsym (string-upcase sym-name)))
                               (multiple-value-bind (sym status)
                                   (intern upsym pkg)
                                 (when (and external-only-p
                                            (not (eq status :external)))
                                   (export sym pkg))))
                           (error () nil)))))))))
            (t (incf i))))))))

(defun %read-single-form-from-string (source)
  "Read a single Lisp form from SOURCE and confirm no trailing forms
follow. Returns (VALUES FORM TRAILING-P), where TRAILING-P is T when
non-whitespace material remains after the first form. Signals
PLANNER-ERROR on read errors so callers can wrap with their step-
index context. Returns NIL form when SOURCE is whitespace-only."
  ;; Use a permissive readtable: bind *read-eval* to NIL so #. cannot
  ;; execute code, and disable *read-suppress* to surface structural
  ;; problems. Pre-create any referenced packages so qualified
  ;; symbols pointing at the new (not-yet-loaded) system package
  ;; don't trip the reader (regression 2026-05-27).
  (%pre-create-referenced-packages source)
  (let ((*read-eval* nil)
        (*read-suppress* nil))
    (with-input-from-string (in source)
      (let* ((first
              (handler-case (read in nil :eof)
                (error (c)
                  (error 'planner-error
                         :message (format nil "test_source parse error: ~A" c)
                         :raw source))))
             (second
              (handler-case (read in nil :eof)
                (error (c)
                  (error 'planner-error
                         :message (format nil "test_source parse error: ~A" c)
                         :raw source)))))
        (values (and (not (eq first :eof)) first)
                (not (eq second :eof)))))))

(defun validate-test-source (source step-index)
  "Signal PLANNER-ERROR unless SOURCE is exactly one (deftest ...)
top-level form with no embedded skip / weakening patterns. Step-index
0-based, used in error messages.

Returns (VALUES SOURCE TEST-NAME-STRING) on success, where
TEST-NAME-STRING is the upcased symbol-name of deftest's first
argument (suitable for STRING-EQUAL comparison against existing
deftest names). Older callers that only inspected the primary value
are unaffected. (Implementation review Finding H1, 2026-05-27.)

Backlog Finding 1 (design review 2026-05-27): the legacy check was
\"contains the substring `(deftest `\", which an LLM reviewer could
trivially bypass with a malicious payload that smuggled extra forms
(`(deftest foo ...) (defun sneaky () nil)`), wrapped the deftest in
another form (`(progn (deftest foo ...))`), or short-circuited
assertions with `(rove:skip)`. This version reads the source as Lisp
data and enforces the contract structurally so the safety property is
not contingent on LLM reviewer judgment.

Rejects:
- Empty / non-string source
- Source that does not READ as Lisp (unbalanced parens, dotted-pair
  garbage, or package-qualified symbols whose package is not loaded)
- Sources with more than one top-level form
- Top-level form whose CAR is not a deftest symbol
- Any `(skip ...)` / `(rove:skip ...)` node anywhere in the form

Accepts unqualified `(deftest ...)`. Package-qualified
`(rove:deftest ...)` is environment-dependent: it passes only when
the qualifier's package is currently loaded; otherwise READ itself
fails and the source is rejected as unparseable. Planners SHOULD
emit unqualified forms (the test file's defpackage imports / uses
rove already)."
  (unless (and (stringp source) (plusp (length source)))
    (error 'planner-error
           :message (format nil
                            "step ~D test_source must be a non-empty string"
                            step-index)
           :raw source))
  (multiple-value-bind (form trailing-p)
      (%read-single-form-from-string source)
    (unless form
      (error 'planner-error
             :message (format nil
                              "step ~D test_source must contain a (deftest ...) form (got whitespace / empty)"
                              step-index)
             :raw source))
    (when trailing-p
      (error 'planner-error
             :message (format nil
                              "step ~D test_source must contain exactly one top-level form, got additional trailing form(s)"
                              step-index)
             :raw source))
    (unless (and (consp form)
                 (%deftest-symbol-p (car form)))
      (error 'planner-error
             :message (format nil
                              "step ~D test_source top-level form must be a deftest (got: ~A...)"
                              step-index
                              (subseq source 0 (min 80 (length source))))
             :raw source))
    (when (%tree-contains-skip-p (cdr form))
      (error 'planner-error
             :message (format nil
                              "step ~D test_source contains a (skip ...) form, which would short-circuit assertions (additive-only rule, Finding 1)"
                              step-index)
             :raw source))
    (let ((name-form (and (consp (cdr form)) (cadr form))))
      (values source
              (when (symbolp name-form)
                (string-upcase (symbol-name name-form)))))))

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

(defun %extract-deftest-names-from-file (path)
  "Return a list of upcased deftest-name strings extracted from PATH.

Used by %MAYBE-HANDLE-TEST-CHANGE-REQUEST to enforce the
\"no name collision\" invariant of the additive-only contract
(Implementation review Finding H1, 2026-05-27): if the agent's
test_change_request would introduce a deftest whose name already
exists in the file, the request is rejected before MATERIALIZE-
TEST-SOURCE silently overwrites by appending.

Strategy: read PATH form by form with *PACKAGE* bound to :CL so
symbols intern into a safe default and qualified references to
packages that don't happen to be loaded in this image don't blow
up the scan. (IN-PACKAGE ...) forms shift *PACKAGE* when the named
package exists; otherwise the scan stays on :CL. Read errors on
any single form abort the scan and return what we have so far —
this is best-effort, not exhaustive. The collision check is a
defense in depth: a false negative (missed collision) is still
covered by the L2 LLM review.

Returns NIL when PATH is NIL, does not exist, or yields no
deftest forms."
  (unless (and path (probe-file path))
    (return-from %extract-deftest-names-from-file nil))
  (let ((names '()))
    (block scan
      (with-open-file (in path :direction :input)
        (let ((*read-eval* nil)
              (*package* (find-package :cl)))
          (loop
            (let ((form
                    (handler-case (read in nil :eof)
                      (error ()
                        (return-from scan)))))
              (cond
                ((eq form :eof) (return-from scan))
                ((and (consp form)
                      (consp (cdr form))
                      (symbolp (car form))
                      (string-equal "IN-PACKAGE"
                                    (symbol-name (car form))))
                 (let* ((named (cadr form))
                        (pkg
                         (cond
                           ((stringp named) (find-package named))
                           ((symbolp named) (find-package (symbol-name named)))
                           (t nil))))
                   (when pkg (setf *package* pkg))))
                ((and (consp form)
                      (consp (cdr form))
                      (%deftest-symbol-p (car form))
                      (symbolp (cadr form)))
                 (push (string-upcase (symbol-name (cadr form))) names))))))))
    (nreverse names)))

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

(defun %enriched-issue (step memo &key review-feedback test-change-feedback)
  "Return the issue string fed to the implement step.

Sections are rendered in priority order (newest / most-specific first),
each as a labeled block; the original task body is shown last under
`## Task'. Empty / NIL sections are omitted.

  1. `## Prior test-change review feedback' (Finding 5, design review
     2026-05-27): the agent's most recent test_change_request was
     rejected; this block carries the reviewer's reasoning so the
     agent can retry with corrected criteria or fall back to direct
     implementation.
  2. `## Prior implementation review feedback': impl-review rejected
     the last patch; the agent should incorporate the feedback.
  3. `## Prior exploration (read-only)': memo from the explore phase
     (when needs_exploration was lightweight / deep).
  4. `## Task': the original plan-step issue text."
  (let ((tcf (and test-change-feedback
                  (plusp (length test-change-feedback))
                  test-change-feedback))
        (fb (and review-feedback (plusp (length review-feedback))
                 review-feedback))
        (mm (and memo (plusp (length memo)) memo)))
    (cond
      ((and (null tcf) (null fb) (null mm))
       (plan-step-issue step))
      (t
       (with-output-to-string (s)
         (when tcf
           (format s "## Prior test-change review feedback~%~A~%~%" tcf))
         (when fb
           (format s "## Prior implementation review feedback~%~A~%~%" fb))
         (when mm
           (format s "## Prior exploration (read-only)~%~A~%~%" mm))
         (format s "## Task~%~A" (plan-step-issue step)))))))

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

(defun %plan-tests-review-enabled-p (develop-state)
  "Return T when the plan-review and tests-review LLM gates should
run. Currently true only for review-policy :AUTO.

Backlog #31: :LIGHT review-policy skips plan-review and tests-review
(the two review LLM calls that compare planner output against the
develop-spec) but keeps spec generation and impl-review intact —
the spec is also fed to impl-review, and impl-review without a spec
defaults to strict-reject behavior observed in the 103-fizz-buzz
bench. Use %REVIEW-ENABLED-P (still T for :LIGHT) for spec
generation, impl-review and test-change-request gates."
  (and develop-state
       (eq :auto (develop-state-review-policy develop-state))))

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
  (if (not (%plan-tests-review-enabled-p develop-state))
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

(defun %maybe-handle-test-change-request
       (step state test-file review-fn provider develop-state)
  "Process a TEST_CHANGE_REQUEST emitted by the agent.

Returns (VALUES OUTCOME FEEDBACK) where OUTCOME is one of:
  :APPROVED — the request was reviewed, structurally validated,
              collision-checked against existing deftest names,
              and materialized to the test file. Caller should
              rerun the same step. FEEDBACK is NIL on this path.
  :REJECTED — the request was rejected. Three rejection paths:
              (1) L2 LLM review rejected it (Finding 5 of the
                  2026-05-27 design review).
              (2) L1 deterministic validator rejected it
                  (malformed source / multiple top-level forms /
                  embedded skip / non-deftest top-level form;
                  Implementation review Finding M2).
              (3) Name collision with an existing deftest in the
                  test file (Implementation review Finding H1).
              In all three cases the develop-state's
              test-revision-count IS incremented because the
              attempt consumed budget, and FEEDBACK (a string) is
              fed back to the agent via %ENRICHED-ISSUE so it can
              retry with a corrected request or switch to direct
              implementation. Empty L2 feedback falls back to a
              generic message so the agent still sees a signal.
  NIL       — not applicable: review is disabled, the policy isn't
              additive-only, or the agent's terminal status isn't
              :test-change-request. FEEDBACK is NIL.

Two-layer defense (DR-2026-05-27 + Implementation review):
  L2 (LLM strict review) runs first and gates entry into
  validation. If L2 approves, L1 (deterministic structural gate +
  collision check) runs inside HANDLER-CASE so any PLANNER-ERROR
  it signals is converted to :REJECTED with the structural error
  message embedded in the feedback. This guarantees that a
  malformed-but-LLM-approved payload still surfaces actionable
  feedback to the agent instead of bubbling the planner-error up
  the call stack and bypassing the retry loop."
  (when
      (and (%review-enabled-p develop-state)
           (eq :additive-only
               (develop-state-test-revision-policy develop-state))
           (eq :test-change-request (%state-status-from-agent-state state)))
    (let* ((action (agent-state-final-action state))
           (source (and action (agent-action-test-source action)))
           (request
            (make-test-change-record
             :step-index (plan-step-index step)
             :criteria (and action (agent-action-criteria action))
             :rationale (and action (agent-action-rationale action))
             :test-source source))
           (decision
            (%call-review review-fn :test-change
                          :develop-state develop-state
                          :provider provider
                          :step step
                          :test-change-action request)))
      (develop-state-record-test-change-request develop-state request)
      (cond
        ((and (review-decision-approved-p decision) (stringp source))
         (handler-case
             (multiple-value-bind (validated new-name)
                 (validate-test-source source (plan-step-index step))
               (declare (ignore validated))
               (let* ((path (%resolve-test-file-path
                             (develop-state-project-root develop-state)
                             test-file))
                      (existing (%extract-deftest-names-from-file path)))
                 (when (and new-name
                            (member new-name existing :test #'string-equal))
                   (error 'planner-error
                          :message
                          (format nil
                                  "test_change_request rejected: a deftest named ~A already exists in the test file. Additive-only requires a distinct name."
                                  new-name)
                          :raw source))
                 (materialize-test-source path source)
                 (incf (develop-state-test-revision-count develop-state))
                 (values :approved nil)))
           (planner-error (c)
             (incf (develop-state-test-revision-count develop-state))
             (values :rejected
                     (format nil
                             "test_change_request rejected by structural validator: ~A Either fix the test_source to comply with the additive-only contract (a single unqualified (deftest NAME ...) form with a distinct name and no skip / weakening), or omit test_change_request and proceed with implementation against the existing tests."
                             (planner-error-message c))))))
        (t
         (incf (develop-state-test-revision-count develop-state))
         (let* ((raw (review-decision-feedback decision))
                (text
                 (if (and (stringp raw) (plusp (length raw)))
                     raw
                     "test_change_request rejected (no specific feedback). Either revise the request to comply with the additive-only contract (a single new (deftest ...) form with a distinct name and no skip / weakening) or proceed with the implementation against the existing tests.")))
           (values :rejected text)))))))

(defun %review-implementation (step state review-fn provider develop-state)
  "Return (VALUES APPROVED-P FEEDBACK) for the implementation review of
STEP. When review is disabled or STATE is not :passed, returns
(VALUES T NIL) (the no-op approve)."
  (if (or (not (%review-enabled-p develop-state))
          (not (eq :passed (%read-status-from-state state))))
      (values t nil)
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
        (values (review-decision-approved-p decision)
                (review-decision-feedback decision)))))

(defun %truncate-feedback (text cap)
  "Truncate TEXT to at most CAP chars, appending an elision footer.
Returns NIL when TEXT is NIL."
  (cond
    ((null text) nil)
    ((<= (length text) cap) text)
    (t (format nil "~A~%[... truncated, ~D chars elided ...]"
               (subseq text 0 cap) (- (length text) cap)))))

(defun %fresh-source-surface-p (project-root)
  "Return T when <PROJECT-ROOT>/src/ EXISTS but contains no substantive
Lisp definitions yet — i.e., src/*.lisp either is empty or only
contains in-package / defpackage forms, comments, and whitespace.
This is a conservative heuristic used by %EXECUTE-STEP to downgrade
the planner's :LIGHTWEIGHT / :DEEP NEEDS-EXPLORATION to :NONE.

When src/ does NOT exist at all (project uses a non-standard layout
or this is a test fixture with no project skeleton), we return NIL
so the planner's choice is respected and existing test setups that
use a bare temp directory as project-root keep their behavior. The
downgrade signal is intentionally tied to the conventional
`<project-root>/src/<file>.lisp' layout used by
package-inferred-system fixtures.

Detection grep is conservative: matches `(def` followed by any
common defining macro name. False negatives (treating a project
with code as fresh) would re-introduce the wasted explore phase,
not break correctness; false positives (treating fresh as not
fresh) keep the planner's choice and burn explore budget — also
not a correctness issue. The heuristic only changes performance."
  (let* ((src-dir (merge-pathnames
                   "src/"
                   (uiop:ensure-directory-pathname project-root))))
    (when (uiop:directory-exists-p src-dir)
      (let ((files (directory (merge-pathnames "*.lisp" src-dir))))
        (if (null files)
            t
            (every
             (lambda (file)
               (let ((content (handler-case (uiop:read-file-string file)
                                (error () ""))))
                 (not (cl-ppcre:scan
                       "(?m)^\\s*\\(def(un|class|method|generic|macro|struct|var|parameter|constant)\\b"
                       content))))
             files))))))

(defun %execute-step (step run-fn project-root system test-system
                      condition test-file logger
                      provider mcp-client run-limits explore-fn
                      &key develop-state
                           (review-fn #'review-development-artifact)
                           (max-test-revisions 3)
                           (max-impl-review-revisions 2)
                           (log-llm-requests nil))
  "Materialize the step's test, optionally run an exploration sub-agent,
build a RUN-CONFIG (with the explore memo prepended to the issue
when present), call RUN-FN, return a DEVELOP-STEP-RESULT.

The body contains two cooperative retry mechanisms inside the
RUN-STEP loop:

1. Test-change-request loop: when RUN-AGENT returns a
   :TEST-CHANGE-REQUEST action, REVIEW-FN reviews and (on approval)
   MATERIALIZE-TEST-SOURCE appends the new deftest. The loop then
   re-runs RUN-AGENT against the augmented test file.

2. Implementation-review loop: when verification passes but
   REVIEW-FN rejects the implementation, the loop re-runs RUN-AGENT
   with the rejection feedback prepended to the issue string,
   bounded by MAX-IMPL-REVIEW-REVISIONS. On budget exhaustion the
   final status is overwritten to :REVIEW-REJECTED for the outer
   develop loop.

When PLAN-STEP's needs-exploration is :LIGHTWEIGHT or :DEEP and
EXPLORE-FN is non-nil, an explore loop runs FIRST against the same
provider/mcp-client with policy :EXPLORE (read-only). The memo
returned from that loop is captured in the develop-step-result
and prepended to the implement issue.

When DEVELOP-STATE is non-nil, the step's PLAN-STEP-INDEX is written
to its CURRENT-STEP-INDEX slot on entry and cleared (set to NIL) on
exit via UNWIND-PROTECT."
  (validate-test-source (plan-step-test-source step) (plan-step-index step))
  (materialize-test-source (%resolve-test-file-path project-root test-file)
                           (plan-step-test-source step))
  (when develop-state
    (setf (develop-state-current-step-index develop-state)
          (plan-step-index step)))
  (unwind-protect
       (let* ((raw-needs (plan-step-needs-exploration step))
              (downgrade-explore-p
               (and raw-needs
                    (not (eq :none raw-needs))
                    (%fresh-source-surface-p project-root)))
              (needs (if downgrade-explore-p :none raw-needs))
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
         (when downgrade-explore-p
           (%log-develop-event
            logger :explore-downgrade
            (alist-hash-table
             `(("step_index" . ,(plan-step-index step))
               ("from" . ,(string-downcase (symbol-name raw-needs)))
               ("to" . "none")
               ("reason" . "fresh-source-surface"))
             :test 'equal)))
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
                (policy (make-tool-policy condition))
                (impl-retry-count 0)
                (review-feedback nil)
                (test-change-feedback nil)
                (impl-review-passed-p nil)
                (state
                 (unwind-protect
                      (block run-step
                        (loop
                          for issue = (%enriched-issue
                                       step memo
                                       :review-feedback review-feedback
                                       :test-change-feedback test-change-feedback)
                          for rc = (make-run-config
                                    :project-root project-root
                                    :system system
                                    :test-system test-system
                                    :issue issue
                                    :condition condition
                                    :limits (or run-limits
                                                (cl-harness/src/config:make-default-limits))
                                    :log-llm-requests log-llm-requests)
                          for state = (funcall run-fn rc provider mcp-client
                                               policy step-logger
                                               :develop-state develop-state)
                          do (cond
                               ;; 1) test-change-request takes priority
                               ((and develop-state
                                     (< (develop-state-test-revision-count
                                         develop-state)
                                        max-test-revisions)
                                     (eq :test-change-request
                                         (%state-status-from-agent-state state)))
                                (multiple-value-bind (tc-outcome tc-feedback)
                                    (%maybe-handle-test-change-request
                                     step state test-file review-fn provider
                                     develop-state)
                                  (case tc-outcome
                                    (:approved
                                     (setf test-change-feedback nil)
                                     (%log-develop-event
                                      logger :test-change-applied
                                      (alist-hash-table
                                       `(("step_index" . ,(plan-step-index step)))
                                       :test 'equal)))
                                    (:rejected
                                     ;; Finding 5: feed rejection feedback
                                     ;; back into the next attempt instead of
                                     ;; terminating the step. The
                                     ;; max-test-revisions counter was already
                                     ;; incremented by
                                     ;; %maybe-handle-test-change-request, so
                                     ;; the WHILE clause above will exit the
                                     ;; loop once the budget is gone.
                                     (setf test-change-feedback tc-feedback)
                                     (%log-develop-event
                                      logger :test-change-rejected
                                      (alist-hash-table
                                       `(("step_index" . ,(plan-step-index step))
                                         ("feedback"
                                          . ,(%truncate-feedback tc-feedback 1500)))
                                       :test 'equal)))
                                    (t
                                     ;; nil outcome: review disabled / wrong
                                     ;; policy / not actually a test change.
                                     ;; Fall through and exit the step with
                                     ;; the agent's terminal status.
                                     (return-from run-step state)))))
                               ;; 2) verify :passed -> implementation review
                               ((eq :passed (%read-status-from-state state))
                                (multiple-value-bind (approved-p feedback)
                                    (%review-implementation
                                     step state review-fn provider develop-state)
                                  (cond
                                    (approved-p
                                     (setf impl-review-passed-p t)
                                     (return-from run-step state))
                                    ((>= impl-retry-count max-impl-review-revisions)
                                     (return-from run-step state))
                                    (t
                                     (incf impl-retry-count)
                                     (setf review-feedback feedback)
                                     (%log-develop-event
                                      logger :impl-review-retry
                                      (alist-hash-table
                                       `(("step_index"
                                          . ,(plan-step-index step))
                                         ("retry_count"
                                          . ,impl-retry-count)
                                         ("feedback"
                                          . ,(%truncate-feedback
                                              feedback 1500)))
                                       :test 'equal))))))
                               ;; 3) verify failed or other terminal status
                               (t (return-from run-step state)))))
                   (close-run-logger step-logger)))
                (status (let ((raw (%read-status-from-state state)))
                          (cond
                            ((and (eq :passed raw)
                                  (%review-enabled-p develop-state)
                                  (not impl-review-passed-p))
                             :review-rejected)
                            (t raw))))
                (result (make-instance
                         'develop-step-result
                         :step-index (plan-step-index step)
                         :test-name (plan-step-test-name step)
                         :run-config (make-run-config
                                      :project-root project-root
                                      :system system
                                      :test-system test-system
                                      :issue (plan-step-issue step)
                                      :condition condition
                                      :limits (or run-limits
                                                  (cl-harness/src/config:make-default-limits)))
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
                             `(("kind"
                                . ,(string-downcase
                                    (symbol-name
                                     (cl-harness/src/abstraction:abstraction-decision-kind
                                      d))))
                               ("name"
                                . ,(cl-harness/src/abstraction:abstraction-decision-name
                                    d))
                               ("rationale"
                                . ,(cl-harness/src/abstraction:abstraction-decision-rationale
                                    d)))
                             :test 'equal))
                          abstraction-decisions)))
               :test 'equal)))
           (%log-develop-event
            logger :step-end
            (alist-hash-table
             `(("step_index" . ,(plan-step-index step))
               ("test_name" . ,(plan-step-test-name step))
               ("status" . ,(string-downcase (symbol-name status)))
               ("review_retries" . ,impl-retry-count)
               ("review_final_outcome"
                . ,(cond
                     ((not (%review-enabled-p develop-state)) "n-a")
                     ((not (eq :passed (%read-status-from-state state)))
                      "n-a")
                     (impl-review-passed-p
                      (if (zerop impl-retry-count)
                          "passed-first-try"
                          "passed-after-retry"))
                     (t "exhausted"))))
             :test 'equal))
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
                          (max-test-revisions 3)
                          (max-impl-review-revisions 2)
                          (log-llm-requests nil))
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
  :step-end      { step_index, test_name, status, review_retries, review_final_outcome }
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
                                            max-test-revisions
                                            :max-impl-review-revisions
                                            max-impl-review-revisions
                                            :log-llm-requests
                                            log-llm-requests)))
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

(defun %validate-plan-test-sources (plan)
  "Run VALIDATE-TEST-SOURCE on each PLAN-STEP's test_source. Return
(VALUES OK-P FEEDBACK). When OK-P is NIL, FEEDBACK is a string
listing every step that failed plus the structural reason, suitable
to drop into a planner failure-context for replan.

Implementation review followup Finding 6 (2026-05-27 N=10 sweep
on 104-cache-simple): Qwen's token-budget exhaustion occasionally
truncates a deftest mid-form, producing planner output like
`(deftest foo (ok t` (unbalanced parens). EXECUTE-PLAN runs
validate-test-source on every step right at entry and bubbles up
the planner-error, killing the whole develop run because the
develop loop's outer HANDLER-CASE only catches MODEL-ERROR. By
running L1 validation here (after PLANNER-FN returns, before
EXECUTE-PLAN), the develop loop can treat structural failures as
\"reject this plan, ask the planner for a fresh one\" — the same
shape as a plan/test review rejection."
  (let ((failures '()))
    (dolist (step plan)
      (handler-case
          (validate-test-source (plan-step-test-source step)
                                (plan-step-index step))
        (planner-error (c)
          (push (format nil "step ~D (test_name=~A): ~A"
                        (plan-step-index step)
                        (plan-step-test-name step)
                        (planner-error-message c))
                failures))))
    (if failures
        (values nil
                (format nil
                        "Plan structural validation rejected ~D step(s). Re-emit a plan where every step's test_source is exactly one unqualified (deftest NAME ...) form, read as valid Lisp, with no embedded skip / weakening, and a distinct test_name. Failures:~%~{- ~A~%~}"
                        (length failures)
                        (nreverse failures)))
        (values t ""))))

(defun %plan-with-review
       (goal planner-fn review-fn provider state mode project-root system
        test-system project-inventory prior-plan failure-context
        max-review-replans)
  "Call PLANNER-FN until plan/test review approves or review budget
is exhausted. Returns NIL after stamping STATE on budget exhaustion.

Each planner output passes through three failure paths before being
accepted:
  P0 (planner-fn itself): PLANNER-ERROR raised inside PLANNER-FN
      (yason JSON decode failure on truncated Qwen output, schema
      violation, etc.) is converted to a replan request with the
      planner-error-message as failure-context. Without this the
      planner-error escapes to develop's outer HANDLER-CASE — which
      only catches MODEL-ERROR — and kills the whole develop run.
      Implementation review followup Finding 7 (2026-05-27 N=10
      sweep on 104-cache-simple).
  L1 (deterministic): every step's test_source is structurally
      valid (single deftest form, no embedded skip, readable Lisp).
      Failures convert to a replan request — same shape as a LLM
      review rejection — instead of bubbling planner-error out of
      EXECUTE-PLAN and killing the develop run. Implementation
      review followup Finding 6 (2026-05-27 N=10 sweep on
      104-cache-simple).
  L2 (LLM):  plan-review and tests-review when enabled by policy."
  (loop
    (let* ((failed-feedback nil)
           (plan
            (handler-case
                (%apply-mode-to-plan
                 (funcall planner-fn goal :project-root project-root :system
                          system :test-system test-system :provider provider
                          :project-inventory project-inventory :mode mode
                          :prior-plan prior-plan :failure-context
                          failure-context :develop-state state)
                 mode)
              (planner-error (c)
                (setf failed-feedback
                        (format nil
                                "Planner LLM output could not be parsed: ~A. Re-emit a valid plan that satisfies the JSON schema."
                                (planner-error-message c)))
                nil))))
      (cond
        (failed-feedback
         (when (>= (develop-state-review-replan-count state) max-review-replans)
           (setf (develop-state-status state) :limit-exhausted
                 (develop-state-limit-hit state) :max-review-replans)
           (return nil))
         (incf (develop-state-review-replan-count state))
         (setf prior-plan nil
               failure-context failed-feedback))
        (t
         (multiple-value-bind (struct-ok-p struct-feedback)
             (%validate-plan-test-sources plan)
           (cond
             ((not struct-ok-p)
              (when (>= (develop-state-review-replan-count state)
                        max-review-replans)
                (setf (develop-state-status state) :limit-exhausted
                      (develop-state-limit-hit state) :max-review-replans)
                (return nil))
              (incf (develop-state-review-replan-count state))
              (setf prior-plan plan
                    failure-context
                    (format nil
                            "Plan structural validation rejected the previous output: ~A"
                            struct-feedback)))
             (t
              (multiple-value-bind (approved-p feedback)
                  (%review-plan-and-tests plan review-fn provider state)
                (when approved-p (return plan))
                (when
                    (>= (develop-state-review-replan-count state)
                        max-review-replans)
                  (setf (develop-state-status state) :limit-exhausted
                        (develop-state-limit-hit state) :max-review-replans)
                  (return nil))
                (incf (develop-state-review-replan-count state))
                (setf prior-plan plan
                      failure-context
                      (format nil
                              "Plan/test review rejected the previous output: ~A"
                              feedback)))))))))))

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
                     (max-impl-review-revisions 2)
                     predefined-plan
                     (spec-fn #'generate-develop-spec)
                     (review-fn #'review-development-artifact)
                     (planner-fn #'plan-development)
                     (run-fn #'run-agent)
                     (explore-fn #'run-explore-agent)
                     (log-llm-requests nil))
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

REVIEW-POLICY default is :NONE here (programmatic / test-stub friendly:
no LLM calls for review). The CLI facade `cl-harness:develop' overrides
to :AUTO so user-facing runs get plan / test / implementation review
gates. Pass :AUTO explicitly when invoking this function from a script
that wants the same defaults as the CLI (design review finding 3,
2026-05-27).

MAX-TEST-REVISIONS is a RUN-WIDE budget, not per-step. The agent's
`test_change_request' protocol increments the same counter across all
steps in a develop run, so a step that exhausts the budget leaves none
for later steps. This is intentional cost-bounding (caps the total
test-mutation LLM calls), but means scenarios where many steps each
legitimately want one additive test will starve the later steps. If
empirical data shows per-step semantics are more useful, redesign
RUN-LIMITS-MAX-TEST-REVISIONS-PER-STEP and reset the counter at step
boundaries (design review finding 4, 2026-05-27).

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
            ;; Note: spec generation runs in BOTH :auto and :light.
            ;; impl-review relies on develop-spec for its acceptance
            ;; criteria; without it the reviewer LLM defaults to
            ;; strict-mode reject (observed in 103-fizz-buzz benc h
            ;; with the original #31 design). Skipping only the
            ;; plan/tests review (which compares plan against spec)
            ;; is enough to deliver the wall-clock savings #31 aimed
            ;; for without breaking impl-review.
            (develop-state-set-develop-spec
             state
             (funcall spec-fn goal
                      :provider provider
                      :develop-state state
                      :project-root project-root
                      :system system
                      :test-system test-system)))
          (setf (develop-state-current-plan state)
                (if predefined-plan
                    ;; backlog #46: fixed-plan paired bench infrastructure.
                    ;; A non-NIL :predefined-plan replaces the initial
                    ;; LLM planner call so consecutive runs against the
                    ;; same fixture see the same plan structure (used to
                    ;; isolate agent-prompt effects from planner-output
                    ;; variance). Replans still go through planner-fn so
                    ;; the loop can recover from failures; pass
                    ;; :max-replans 0 to forbid replans entirely.
                    predefined-plan
                    (%plan-with-review
                     goal planner-fn review-fn provider state mode
                     project-root system test-system project-inventory
                     nil nil max-review-replans)))
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
                                   :max-test-revisions max-test-revisions
                                   :max-impl-review-revisions max-impl-review-revisions
                                   :log-llm-requests log-llm-requests))
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
