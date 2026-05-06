;;;; src/planner.lisp
;;;;
;;;; Phase P1 of the planner+orchestrator extension
;;;; (docs/notes/2026-05-06-planner-orchestrator.md).
;;;;
;;;; Single public entry point: PLAN-DEVELOPMENT. Calls an LLM with
;;;; the planner system prompt (prompts/planner.md) plus the user's
;;;; high-level goal, parses the response into a list of PLAN-STEP
;;;; instances, and returns it. Does NOT execute the plan — orchestrator
;;;; (Phase P2) and replanner (Phase P3) are separate layers.
;;;;
;;;; PLAN-STEP is a richer struct than RUN-CONFIG because it also
;;;; carries the test source the planner authored for the sub-goal;
;;;; the orchestrator (P2) is responsible for materialising those
;;;; tests on disk before invoking RUN-AGENT.

(defpackage #:cl-harness/src/planner
  (:use #:cl)
  (:import-from #:cl-harness/src/model
                #:complete-chat
                #:make-chat-message
                #:chat-response-content)
  (:export #:plan-step
           #:plan-step-index
           #:plan-step-issue
           #:plan-step-test-name
           #:plan-step-test-source
           #:plan-step-files-to-modify
           ;; v0.4 Phase 1 additions:
           #:plan-step-purpose
           #:plan-step-acceptance-criteria
           #:plan-step-investigation-targets
           #:plan-step-risks
           #:plan-step-needs-exploration
           #:plan-step-adopted-abstractions
           #:plan-step-rejected-abstractions
           #:investigation-target
           #:investigation-target-kind
           #:investigation-target-name
           #:investigation-target-intent
           #:plan-development
           #:planner-error
           #:planner-error-message
           #:+default-planner-system-prompt+))

(in-package #:cl-harness/src/planner)

(defparameter +default-planner-system-prompt+
  ;; Mirrors prompts/planner.md so the file system version is human
  ;; readable and the in-image version is what the LLM actually sees.
  ;; If you edit this string, mirror the change to prompts/planner.md
  ;; (or vice versa).
  (concatenate
   'string
   "You are the planner for cl-harness, a TDD-driven coding agent for "
   "Common Lisp + ASDF + rove. Decompose a high-level requirement into "
   "an ordered list of focused sub-goals an executor agent can drive to "
   "passing tests, one at a time."
   (string #\Newline) (string #\Newline)
   "Respond with EXACTLY ONE JSON object, no surrounding prose, no "
   "markdown fence. Schema:"
   (string #\Newline) (string #\Newline)
   "  {\"steps\": [ "
   "{\"issue\": <string>, "
   "\"test_name\": <string>, "
   "\"test_source\": <string with a complete (rove:deftest ...) form>, "
   "\"files_to_modify\": [<relative path>, ...], "
   "\"purpose\": <one-sentence rationale>, "
   "\"acceptance_criteria\": [<short check>, ...], "
   "\"investigation_targets\": [{\"kind\": <\"package\"|\"function\"|\"class\"|\"generic_function\"|\"method\"|\"macro\"|\"system\"|\"test_system\"|\"symbol\">, \"name\": <designator>, \"intent\": <short>}, ...], "
   "\"risks\": [<short risk>, ...], "
   "\"needs_exploration\": <\"none\"|\"lightweight\"|\"deep\">"
   " }, ... ] }"
   (string #\Newline) (string #\Newline)
   "Required fields per step: issue, test_name, test_source. Other "
   "fields are optional but expected for v0.4 development workflows; "
   "leave them out for trivial bug-fix style steps."
   (string #\Newline) (string #\Newline)
   "Field guidance:"
   (string #\Newline)
   "- purpose:   one sentence on why this step exists (the "
   "implementer's `why` paragraph)."
   (string #\Newline)
   "- acceptance_criteria: concrete checks beyond the rove test "
   "(e.g. \"package demo exports greet\", \"behavior preserves "
   "negative inputs\"). Max 5 items."
   (string #\Newline)
   "- investigation_targets: existing code/runtime elements the "
   "executor (or the explore phase, when needs_exploration > "
   "\"none\") should look at to avoid inventing structures that "
   "duplicate what already exists. Each entry names a kind + a "
   "designator + a one-sentence intent."
   (string #\Newline)
   "- risks: likely failure modes (one-line each, max 3). Helps the "
   "executor pre-empt them."
   (string #\Newline)
   "- needs_exploration: \"none\" when the issue is fully specified "
   "by the rove test alone; \"lightweight\" when a quick "
   "code-find / repl-eval check on existing exports is useful "
   "before implementing; \"deep\" when the design itself needs "
   "REPL-driven discovery (CLOS hierarchy, macro-vs-defun "
   "decisions, etc.)."
   (string #\Newline) (string #\Newline)
   "Constraints on each step:"
   (string #\Newline)
   "1. Implementable in one contiguous edit (a few file mods, a few "
   "defun/defclass forms; budget is ~3 patches per step)."
   (string #\Newline)
   "2. Verifiable by exactly one rove test you author in test_source. "
   "test_source MUST start with `(deftest <name>` and use rove's "
   "`testing` / `ok` macros; the orchestrator rejects any plan whose "
   "test_source does not contain a `(deftest ` form."
   (string #\Newline)
   "3. Cumulative: each step assumes earlier steps are complete."
   (string #\Newline) (string #\Newline)
   "Required test_source shape (use this template; do NOT use `defun "
   "test-...` or plain `assert` — those will be rejected):"
   (string #\Newline)
   "  (deftest <test-name>"
   (string #\Newline)
   "    (testing \"<short description of expected behaviour>\""
   (string #\Newline)
   "      (ok (<predicate that calls the function under test>))))"
   (string #\Newline) (string #\Newline)
   "Rules:"
   (string #\Newline)
   "- 3 to 7 steps is typical; refuse >12 (return one REQUIREMENT GAP step)."
   (string #\Newline)
   "- Tests only — never write the production source."
   (string #\Newline)
   "- If the goal is ambiguous, return one step whose `issue` starts "
   "with `REQUIREMENT GAP:` and lists what's missing."
   (string #\Newline)
   "- You have no MCP tools; plan from convention "
   "(package-inferred-system layout, src/ + tests/, etc.)."
   (string #\Newline)
   "- Never include trailing commentary outside the JSON object.")
  "Default planner system prompt sent on every PLAN-DEVELOPMENT call.
Mirrors prompts/planner.md.")

;; --- conditions ----------------------------------------------------------

(define-condition planner-error (error)
  ((message :initarg :message :reader planner-error-message)
   (raw :initarg :raw :initform nil :reader planner-error-raw))
  (:documentation "Signaled when the planner LLM's response cannot be
turned into a valid plan-step list.")
  (:report (lambda (c stream)
             (format stream "planner-error: ~A"
                     (planner-error-message c)))))

;; --- plan-step -----------------------------------------------------------

(defclass investigation-target ()
  ((kind :initarg :kind :reader investigation-target-kind)
   (name :initarg :name :reader investigation-target-name)
   (intent :initarg :intent :reader investigation-target-intent))
  (:documentation
   "One existing-code element the planner expects the executor (or
the explore phase) to look at before / during the step. KIND is one
of the keywords listed in +INVESTIGATION-TARGET-KINDS+
(:package, :function, :class, :generic-function, :method, :macro,
:system, :test-system, :symbol). NAME is the canonical designator
string (e.g. \"demo:greet\", \"demo/tests\"). INTENT is one short
sentence on what the planner wants confirmed."))

(defparameter +investigation-target-kinds+
  '(:package :symbol :function :generic-function :method
    :class :macro :system :test-system)
  "Allowed values of INVESTIGATION-TARGET-KIND. Planner responses
using a different `kind` string are rejected with planner-error
so a confused planner can't propagate a malformed shape into the
orchestrator.")

(defparameter +needs-exploration-levels+
  '(:none :lightweight :deep)
  "Allowed values for plan-step-needs-exploration. The orchestrator
(Phase P3, v0.4) uses this to decide whether to run an explore
sub-step before the implement sub-step.")

(defclass plan-step ()
  ((index :initarg :index :reader plan-step-index)
   (issue :initarg :issue :reader plan-step-issue)
   (test-name :initarg :test-name :reader plan-step-test-name)
   (test-source :initarg :test-source :reader plan-step-test-source)
   (files-to-modify :initarg :files-to-modify
                    :initform nil
                    :reader plan-step-files-to-modify)
   ;; v0.4 Phase 1 additions. All optional so v0.3 planner responses
   ;; continue to parse with sensible defaults.
   (purpose :initarg :purpose :initform nil
            :reader plan-step-purpose)
   (acceptance-criteria :initarg :acceptance-criteria :initform nil
                        :reader plan-step-acceptance-criteria)
   (investigation-targets :initarg :investigation-targets :initform nil
                          :reader plan-step-investigation-targets)
   (risks :initarg :risks :initform nil
          :reader plan-step-risks)
   (needs-exploration :initarg :needs-exploration :initform :none
                      :reader plan-step-needs-exploration)
   ;; Written by the orchestrator (P3 / P4) — not by the planner.
   ;; Initialised here to NIL so callers can read the slot
   ;; uniformly.
   (adopted-abstractions :initarg :adopted-abstractions :initform nil
                         :accessor plan-step-adopted-abstractions)
   (rejected-abstractions :initarg :rejected-abstractions :initform nil
                          :accessor plan-step-rejected-abstractions))
  (:documentation
   "One sub-goal in a development plan. INDEX is 0-based, in the order
emitted by the planner. ISSUE is the free-text problem statement the
executor will see. TEST-NAME and TEST-SOURCE describe the rove test
the orchestrator (Phase P2) will materialise on disk before invoking
RUN-AGENT for this step. FILES-TO-MODIFY is an informational hint.

v0.4 Phase 1 additions (see docs/notes/2026-05-06-v0.4-development-harness.md):
PURPOSE is the why-paragraph (one sentence). ACCEPTANCE-CRITERIA is
a list of strings the run is graded against. INVESTIGATION-TARGETS
is a list of INVESTIGATION-TARGET instances pointing at existing
code/runtime elements the planner wants the explore phase to
confirm. RISKS lists likely failure modes (max ~3). NEEDS-EXPLORATION
is one of +NEEDS-EXPLORATION-LEVELS+. ADOPTED-ABSTRACTIONS and
REJECTED-ABSTRACTIONS are written by the orchestrator after the
explore phase to capture which design candidates were promoted to
source and which were left as REPL-only experiments."))

;; --- prompt construction -------------------------------------------------

(defun %format-prior-plan (prior-plan)
  "Pretty-print PRIOR-PLAN (a list of PLAN-STEP) as a one-line-per-step
summary suitable for inclusion in a replan prompt."
  (with-output-to-string (s)
    (format s "Previous plan:~%")
    (loop for step in prior-plan
          for i from 0
          do (format s "  ~D. ~A (test: ~A)~%"
                     i
                     (plan-step-issue step)
                     (plan-step-test-name step)))))

(defun %build-user-prompt (goal &key project-root system test-system
                                     prior-plan failure-context
                                     project-inventory)
  "Assemble the user-side message for the planner LLM call.

PROJECT-INVENTORY (v0.4 Phase 2), when supplied, is prepended as a
read-only snapshot of the existing project's vocabulary so the
planner builds on what's already there instead of inventing parallel
structures.

PRIOR-PLAN, when supplied, is rendered as a `Previous plan:` block
above the goal. FAILURE-CONTEXT, when supplied, is rendered as a
`Failure:` paragraph. Together they're how P3's replan path tells the
planner what was tried and why it didn't work."
  (with-output-to-string (s)
    (when (and project-inventory (plusp (length project-inventory)))
      (format s "~A~%~%" project-inventory))
    (format s "Goal: ~A~%~%" goal)
    (when project-root
      (format s "Project root: ~A~%" project-root))
    (when system
      (format s "System name: ~A~%" system))
    (when test-system
      (format s "Test system: ~A~%" test-system))
    (when prior-plan
      (format s "~%~A" (%format-prior-plan prior-plan)))
    (when failure-context
      (format s "~%Failure: ~A~%" failure-context)
      (format s "Produce a REVISED plan that takes the failure into account.~%")
      (format s "Do not repeat earlier steps that already passed; pick up~%")
      (format s "from where the prior plan got stuck.~%"))
    (format s "~%Return the plan as a JSON object per the schema above.")))

;; --- response parsing ----------------------------------------------------

(defun %strip-code-fence (text)
  "If TEXT is wrapped in a ```...``` markdown fence, return its inner
payload. Otherwise return TEXT unchanged. Mirrors the shape of
`cl-harness/src/action::strip-code-fence` so chat models that habitually
fence their JSON do not break the parser."
  (let ((open (search "```" text)))
    (if (null open)
        text
        (let* ((after-open (+ open 3))
               (close (search "```" text :start2 after-open))
               (inner (if close
                          (subseq text after-open close)
                          (subseq text after-open)))
               (nl (position #\Newline inner))
               (lang (and nl (string-trim '(#\Space #\Tab)
                                          (subseq inner 0 nl)))))
          (if (and lang
                   (plusp (length lang))
                   (every #'alpha-char-p lang))
              (subseq inner (1+ nl))
              inner)))))

(defun %require-string (table key step-index)
  (let ((v (gethash key table)))
    (unless (and (stringp v) (plusp (length v)))
      (error 'planner-error
             :message (format nil
                              "step ~D missing required string field ~A"
                              step-index key)
             :raw table))
    v))

(defun %parse-files (raw)
  "Coerce a JSON value (vector, list, NIL, or absent) into a list of
strings. Anything else signals planner-error."
  (cond
    ((null raw) nil)
    ((vectorp raw)
     (loop for item across raw
           do (unless (stringp item)
                (error 'planner-error
                       :message "files_to_modify entries must be strings"
                       :raw raw))
           collect item))
    ((listp raw)
     (loop for item in raw
           do (unless (stringp item)
                (error 'planner-error
                       :message "files_to_modify entries must be strings"
                       :raw raw))
           collect item))
    (t (error 'planner-error
              :message "files_to_modify must be an array of strings"
              :raw raw))))

(defun %as-list-of-strings (raw field-name)
  "Like %PARSE-FILES but parameterised by the JSON field name so the
error message can name the offending field. Returns NIL for
absent/empty input, a list of strings otherwise."
  (cond
    ((null raw) nil)
    ((or (vectorp raw) (listp raw))
     (let ((items (if (vectorp raw) (coerce raw 'list) raw)))
       (dolist (item items)
         (unless (stringp item)
           (error 'planner-error
                  :message (format nil
                                   "~A entries must be strings"
                                   field-name)
                  :raw raw)))
       items))
    (t (error 'planner-error
              :message (format nil
                               "~A must be an array of strings"
                               field-name)
              :raw raw))))

(defun %parse-investigation-target (table step-index target-index)
  (unless (hash-table-p table)
    (error 'planner-error
           :message (format nil
                            "step ~D investigation_targets[~D] must be an object"
                            step-index target-index)
           :raw table))
  (let ((kind-raw (gethash "kind" table))
        (name-raw (gethash "name" table))
        (intent-raw (or (gethash "intent" table) "")))
    (unless (and (stringp kind-raw) (plusp (length kind-raw)))
      (error 'planner-error
             :message (format nil
                              "step ~D investigation_targets[~D] missing 'kind'"
                              step-index target-index)
             :raw table))
    (unless (and (stringp name-raw) (plusp (length name-raw)))
      (error 'planner-error
             :message (format nil
                              "step ~D investigation_targets[~D] missing 'name'"
                              step-index target-index)
             :raw table))
    (let ((kind-kw (intern (string-upcase
                            (substitute #\- #\_ kind-raw))
                           :keyword)))
      (unless (member kind-kw +investigation-target-kinds+)
        (error 'planner-error
               :message (format nil
                                "step ~D investigation_targets[~D] kind ~S is not one of ~A"
                                step-index target-index
                                kind-raw +investigation-target-kinds+)
               :raw table))
      (make-instance 'investigation-target
                     :kind kind-kw
                     :name name-raw
                     :intent intent-raw))))

(defun %parse-investigation-targets (raw step-index)
  (cond
    ((null raw) nil)
    ((or (vectorp raw) (listp raw))
     (let ((items (if (vectorp raw) (coerce raw 'list) raw)))
       (loop for item in items
             for i from 0
             collect (%parse-investigation-target item step-index i))))
    (t (error 'planner-error
              :message (format nil
                               "step ~D investigation_targets must be an array"
                               step-index)
              :raw raw))))

(defun %parse-needs-exploration (raw step-index)
  (cond
    ((null raw) :none)
    ((stringp raw)
     (let ((kw (intern (string-upcase raw) :keyword)))
       (unless (member kw +needs-exploration-levels+)
         (error 'planner-error
                :message (format nil
                                 "step ~D needs_exploration ~S is not one of ~A"
                                 step-index raw +needs-exploration-levels+)
                :raw raw))
       kw))
    (t (error 'planner-error
              :message (format nil
                               "step ~D needs_exploration must be a string"
                               step-index)
              :raw raw))))

(defun %hash-to-step (table index)
  "Build a PLAN-STEP from the hash-table TABLE for the step at INDEX
(0-based). Validates the required fields, defaults files_to_modify
to NIL when absent, and reads the v0.4 Phase 1 optional fields
(purpose / acceptance_criteria / investigation_targets / risks /
needs_exploration). Anything missing in the response defaults to
NIL or :none — old v0.3 planner outputs continue to parse."
  (unless (hash-table-p table)
    (error 'planner-error
           :message (format nil "step ~D is not a JSON object" index)
           :raw table))
  (let ((purpose-raw (gethash "purpose" table)))
    (when (and purpose-raw (not (stringp purpose-raw)))
      (error 'planner-error
             :message (format nil "step ~D purpose must be a string" index)
             :raw table))
    (make-instance
     'plan-step
     :index index
     :issue (%require-string table "issue" index)
     :test-name (%require-string table "test_name" index)
     :test-source (%require-string table "test_source" index)
     :files-to-modify (%parse-files
                       (gethash "files_to_modify" table))
     :purpose (and purpose-raw (plusp (length purpose-raw)) purpose-raw)
     :acceptance-criteria (%as-list-of-strings
                           (gethash "acceptance_criteria" table)
                           "acceptance_criteria")
     :investigation-targets (%parse-investigation-targets
                             (gethash "investigation_targets" table)
                             index)
     :risks (%as-list-of-strings (gethash "risks" table) "risks")
     :needs-exploration (%parse-needs-exploration
                         (gethash "needs_exploration" table)
                         index))))

(defun %parse-plan (text)
  "Parse a planner response TEXT (raw or fenced JSON) into a list of
PLAN-STEP instances. Signals PLANNER-ERROR on any deviation from the
schema."
  (check-type text string)
  (let* ((stripped (%strip-code-fence text))
         (parsed
          (handler-case (yason:parse stripped)
            (error (c)
              (error 'planner-error
                     :message (format nil "JSON decode failed: ~A" c)
                     :raw text)))))
    (unless (hash-table-p parsed)
      (error 'planner-error
             :message "top-level JSON value must be an object"
             :raw text))
    (let ((steps (gethash "steps" parsed)))
      (unless steps
        (error 'planner-error
               :message "response is missing required 'steps' array"
               :raw parsed))
      (unless (or (listp steps) (vectorp steps))
        (error 'planner-error
               :message "'steps' must be an array"
               :raw parsed))
      (let ((step-list (if (vectorp steps)
                           (coerce steps 'list)
                           steps)))
        (loop for s in step-list
              for i from 0
              collect (%hash-to-step s i))))))

;; --- public entry --------------------------------------------------------

(defun plan-development (goal &key project-root system test-system
                                   provider
                                   prior-plan
                                   failure-context
                                   project-inventory
                                   (system-prompt
                                    +default-planner-system-prompt+))
  "Decompose a high-level GOAL into an ordered list of PLAN-STEP
instances by calling PROVIDER (an OPENAI-COMPATIBLE-PROVIDER or
compatible).

PROJECT-ROOT, SYSTEM, and TEST-SYSTEM, when supplied, are appended to
the user-side prompt as orientation. They do not narrow the plan
mechanically — the planner is allowed to ignore them — but they
constrain what the LLM treats as the ambient project shape.

PROJECT-INVENTORY (v0.4 Phase 2), when supplied, is prepended to the
user-side prompt as the existing vocabulary the planner is expected
to build on. Typically produced by
`cl-harness/src/inventory:gather-project-inventory'. NIL means
\"plan from convention only\" (v0.3 behavior).

PRIOR-PLAN and FAILURE-CONTEXT, when supplied together, drive the
P3 replan path: the planner sees what was tried and why it failed,
and is asked to produce a revised plan that picks up from the
failure point. Pass NIL for both on the first planning round.

SYSTEM-PROMPT defaults to +DEFAULT-PLANNER-SYSTEM-PROMPT+; override
when iterating on prompt design without rebuilding the system.

Returns a list of PLAN-STEP instances in plan order. Signals
PLANNER-ERROR when the response cannot be parsed."
  (check-type goal string)
  (let* ((messages (list (make-chat-message "system" system-prompt)
                         (make-chat-message
                          "user"
                          (%build-user-prompt goal
                                              :project-root project-root
                                              :system system
                                              :test-system test-system
                                              :prior-plan prior-plan
                                              :failure-context failure-context
                                              :project-inventory project-inventory))))
         (response (complete-chat provider messages))
         (content (chat-response-content response)))
    (unless (and (stringp content) (plusp (length content)))
      (error 'planner-error
             :message "planner LLM returned empty content"
             :raw response))
    (%parse-plan content)))
