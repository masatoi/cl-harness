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
   "  {\"steps\": [ {\"issue\": <string>, "
   "\"test_name\": <string>, "
   "\"test_source\": <string with a complete (deftest ...) form>, "
   "\"files_to_modify\": [<relative path>, ...] }, ... ] }"
   (string #\Newline) (string #\Newline)
   "Constraints on each step:"
   (string #\Newline)
   "1. Implementable in one contiguous edit (a few file mods, a few "
   "defun/defclass forms; budget is ~3 patches per step)."
   (string #\Newline)
   "2. Verifiable by exactly one rove test, which you author in the "
   "test_source field; the test must FAIL before the step's "
   "implementation lands and PASS after."
   (string #\Newline)
   "3. Cumulative: each step assumes earlier steps are complete."
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

(defclass plan-step ()
  ((index :initarg :index :reader plan-step-index)
   (issue :initarg :issue :reader plan-step-issue)
   (test-name :initarg :test-name :reader plan-step-test-name)
   (test-source :initarg :test-source :reader plan-step-test-source)
   (files-to-modify :initarg :files-to-modify
                    :initform nil
                    :reader plan-step-files-to-modify))
  (:documentation
   "One sub-goal in a development plan. INDEX is 0-based, in the order
emitted by the planner. ISSUE is the free-text problem statement the
executor will see. TEST-NAME and TEST-SOURCE describe the rove test
the orchestrator (Phase P2) will materialise on disk before invoking
RUN-AGENT for this step. FILES-TO-MODIFY is an informational hint
about which source files the planner expects this step to touch."))

;; --- prompt construction -------------------------------------------------

(defun %build-user-prompt (goal &key project-root system test-system)
  "Assemble the user-side message for the planner LLM call."
  (with-output-to-string (s)
    (format s "Goal: ~A~%~%" goal)
    (when project-root
      (format s "Project root: ~A~%" project-root))
    (when system
      (format s "System name: ~A~%" system))
    (when test-system
      (format s "Test system: ~A~%" test-system))
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

(defun %hash-to-step (table index)
  "Build a PLAN-STEP from the hash-table TABLE for the step at INDEX
(0-based). Validates the required fields and defaults files_to_modify
to NIL when absent."
  (unless (hash-table-p table)
    (error 'planner-error
           :message (format nil "step ~D is not a JSON object" index)
           :raw table))
  (make-instance 'plan-step
                 :index index
                 :issue (%require-string table "issue" index)
                 :test-name (%require-string table "test_name" index)
                 :test-source (%require-string table "test_source" index)
                 :files-to-modify (%parse-files
                                   (gethash "files_to_modify" table))))

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
                                   (system-prompt
                                    +default-planner-system-prompt+))
  "Decompose a high-level GOAL into an ordered list of PLAN-STEP
instances by calling PROVIDER (an OPENAI-COMPATIBLE-PROVIDER or
compatible).

PROJECT-ROOT, SYSTEM, and TEST-SYSTEM, when supplied, are appended to
the user-side prompt as orientation. They do not narrow the plan
mechanically — the planner is allowed to ignore them — but they
constrain what the LLM treats as the ambient project shape.

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
                                              :test-system test-system))))
         (response (complete-chat provider messages))
         (content (chat-response-content response)))
    (unless (and (stringp content) (plusp (length content)))
      (error 'planner-error
             :message "planner LLM returned empty content"
             :raw response))
    (%parse-plan content)))
