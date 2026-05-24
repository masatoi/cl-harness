;;;; src/agent.lisp
;;;;
;;;; PRD §8.4, §11.1, §11.2 — turn-based agent loop wiring together the
;;;; LLM provider, MCP client, tool policy, verifier, and JSONL logger
;;;; for the Phase 2 basic fix loop.
;;;;
;;;; The loop:
;;;;   1. set project root
;;;;   2. initial verify (load + run-tests)
;;;;   3. if already passing, return :passed without calling the LLM
;;;;   4. otherwise loop up to max-turns:
;;;;      a. ask LLM for next action
;;;;      b. parse JSON action; on parse error, feed error back to LLM
;;;;      c. on :finish, return :passed (fixed) or :give-up
;;;;      d. on :tool-call, gate by policy; invoke via MCP; on a
;;;;         source-mutating tool, auto-reverify; on success, return
;;;;         :passed early.
;;;;   5. when the budget runs out, return :max-turns.

(defpackage #:cl-harness/src/agent
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/config
                #:run-config-project-root
                #:run-config-system
                #:run-config-test-system
                #:run-config-issue
                #:run-config-limits
                #:run-config-log-llm-requests-p
                #:run-limits-max-turns
                #:run-limits-max-tool-calls
                #:run-limits-max-patches
                #:run-limits-max-read-files
                #:run-limits-max-repl-evals
                #:run-limits-max-wall-clock-seconds
                #:run-limits-max-action-parse-errors
                #:run-limits-max-consecutive-failed-patches
                #:run-limits-max-context-tokens)
  (:import-from #:cl-harness/src/compact
                #:compact-history
                #:approximate-history-tokens)
  (:import-from #:local-time
                #:now
                #:timestamp-difference)
  (:import-from #:cl-harness/src/log
                #:log-event)
  (:import-from #:cl-harness/src/mcp
                #:call-tool
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message)
  (:import-from #:cl-harness/src/model
                #:complete-chat
                #:make-chat-message
                #:chat-response-content
                #:chat-response-total-tokens)
  (:import-from #:cl-harness/src/action
                #:parse-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-rationale
                #:agent-action-test-source
                #:action-parse-error
                #:action-parse-error-message)
  (:import-from #:cl-harness/src/policy
                #:policy-mode
                #:policy-allowed-tools
                #:allowed-tool-p)
  (:import-from #:cl-harness/src/state
                #:develop-state-record-patch-record
                #:develop-state-record-source-fact
                #:develop-state-record-runtime-vocab-fact
                #:develop-state-current-plan
                #:develop-state-current-step-index
                #:develop-state-mark-project-summary-dirty)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:make-runtime-vocab-fact
                #:+supported-runtime-vocab-kinds+)
  (:import-from #:cl-harness/src/context-view
                #:make-context-view
                #:context-view->string)
  (:import-from #:cl-harness/src/patch-record
                #:make-patch-record)
  (:import-from #:cl-harness/src/source-fact
                #:make-source-fact)
  (:import-from #:cl-harness/src/verify
                #:verify-result-status
                #:verify-result-passed
                #:verify-result-failed
                #:verify-result-test
                #:verify-result-load
                #:verify-result-success-p
                #:verify-task
                #:clean-verify-task
                #:scope-asdf-to-project)
  (:export #:agent-state
           #:agent-state-turn
           #:agent-state-status
           #:agent-state-final-verify
           #:agent-state-final-action
           #:agent-state-token-total
           #:agent-state-patch-count
           #:agent-state-patch-attempts
           #:agent-state-tool-call-count
           #:agent-state-read-file-count
           #:agent-state-repl-eval-count
           #:agent-state-started-at
           #:agent-state-limit-hit
           #:agent-state-parse-error-streak
           #:agent-state-consecutive-failed-patches
           #:agent-state-develop-state
           #:agent-state-reason
           #:agent-state-last-tool-errors
           #:run-agent
           #:format-final-report
           #:summarize-tool-result
           #:summarize-tool-by-key
           #:+source-mutating-tools+
           #:verify-event-payload
           #:%complete-chat-with-logging))

(in-package #:cl-harness/src/agent)

(defparameter +source-mutating-tools+
  '("lisp-patch-form" "lisp-edit-form" "fs-write-file")
  "Tools whose successful invocation should trigger an automatic verify.
fs-write-file is included so the file-only baseline condition still
auto-verifies after each file rewrite, matching the lisp-* paths.")

(defun %resolve-patch-target (config arguments tool)
  "Return the absolute pathname the source-mutating TOOL is targeting,
or NIL when ARGUMENTS does not name a file. The lisp-* tools use a
\"file_path\" key, fs-write-file uses \"path\". Relative paths are
resolved against CONFIG's project-root."
  (let ((key (cond ((member tool '("lisp-patch-form" "lisp-edit-form")
                            :test #'equal)
                    "file_path")
                   ((equal tool "fs-write-file")
                    "path"))))
    (when key
      (let ((p (and (hash-table-p arguments) (gethash key arguments))))
        (when (and (stringp p) (plusp (length p)))
          (let ((path (pathname p)))
            (if (uiop:absolute-pathname-p path)
                path
                (merge-pathnames
                 path
                 (uiop:ensure-directory-pathname
                  (run-config-project-root config))))))))))

(defun %read-file-safely (path)
  "Read PATH as a string, returning NIL on any error. Used by the patch
diff logger so a missing or unreadable target degrades to no-diff
instead of aborting the agent loop."
  (when (and path (probe-file path))
    (handler-case (uiop:read-file-string path)
      (error () nil))))

(defun %compute-unified-diff (before after label)
  "Return a unified-diff string (`diff -u`) between BEFORE and AFTER
content strings, or NIL when they are equal / inputs are unusable / the
external `diff` binary is unavailable. LABEL is used as the file label
on both sides of the diff header."
  (when (and (stringp before) (stringp after) (string/= before after))
    (handler-case
        (uiop:with-temporary-file (:pathname bp :stream sb
                                   :direction :output)
          (write-string before sb)
          (finish-output sb)
          (uiop:with-temporary-file (:pathname ap :stream sa
                                     :direction :output)
            (write-string after sa)
            (finish-output sa)
            (uiop:run-program (list "diff" "-u"
                                    "--label" (format nil "~A (before)" label)
                                    "--label" (format nil "~A (after)" label)
                                    (namestring bp)
                                    (namestring ap))
                              :output :string
                              :ignore-error-status t)))
      (error () nil))))

(defun %vocab-kind-from-string (kind-string)
  "Coerce a string like \"function\" into a keyword from
+SUPPORTED-RUNTIME-VOCAB-KINDS+, or NIL when the string isn't a
recognised kind. Uses FIND-SYMBOL (not INTERN) so unknown kinds do
not pollute the keyword package — cl-mcp results are external input
and the project style guide forbids runtime INTERN of untrusted
strings."
  (when (stringp kind-string)
    (let ((normalized (find-symbol (string-upcase
                                    (substitute #\- #\_ kind-string))
                                   :keyword)))
      (when (and normalized
                 (member normalized +supported-runtime-vocab-kinds+))
        normalized))))

(defun %vocab-fact-from-tool-result (tool result &key related-step-index)
  "Try to extract a single RUNTIME-VOCAB-FACT from a tool RESULT
hash-table (cl-mcp's structured output). Returns NIL when the result
shape doesn't match (missing name, error flag set, unknown kind).
Best-effort: never raises."
  (when (and (hash-table-p result)
             (not (gethash "isError" result)))
    (let ((kind-string (gethash "kind" result))
          (name (gethash "name" result))
          (package (gethash "package" result))
          (source-file (gethash "source_file" result))
          (summary (gethash "summary" result)))
      (let ((kind (%vocab-kind-from-string kind-string)))
        (when (and kind (stringp name) (plusp (length name)))
          (handler-case
              (make-runtime-vocab-fact
               :kind kind
               :name name
               :package (and (stringp package) package)
               :source-file (and (stringp source-file) source-file)
               :summary (and (stringp summary) summary)
               :via-tool tool
               :related-step-index related-step-index)
            (error () nil)))))))

(defun %vocab-facts-from-tool-result (tool result &key related-step-index)
  "Plural variant. CODE-FIND returns a {\"results\": [...]} shape;
CODE-DESCRIBE returns a flat hash-table with no \"results\" key.
Returns a list of facts (possibly empty); never raises.

Detects shape via the second return value of GETHASH so that an
ABSENT \"results\" key falls through to single-fact extraction on
the outer hash (CODE-DESCRIBE path), while a PRESENT \"results\"
key with an empty list iterates zero entries (CODE-FIND on no
matches)."
  (when (and (hash-table-p result)
             (not (gethash "isError" result)))
    (multiple-value-bind (entries present-p) (gethash "results" result)
      (cond
        (present-p
         (when (listp entries)
           (loop for entry in entries
                 for fact = (and (hash-table-p entry)
                                 (%vocab-fact-from-tool-result
                                  tool entry
                                  :related-step-index related-step-index))
                 when fact collect fact)))
        (t
         (let ((single (%vocab-fact-from-tool-result
                        tool result
                        :related-step-index related-step-index)))
           (and single (list single))))))))

(defun %record-runtime-vocab-from-tool-call (tool result state)
  "If STATE has a develop-state and the tool call returned a non-error
result on a runtime-introspection tool, persist any
RUNTIME-VOCAB-FACTs extracted from RESULT bound to the develop-state's
current step-index. Returns the list of persisted facts (possibly
NIL)."
  (let ((develop-state (agent-state-develop-state state)))
    (when (and develop-state
               (not (and (gethash "isError" result) t))
               (member tool '("code-describe" "code-find"
                              "code-find-references")
                       :test #'string=))
      (let ((facts (%vocab-facts-from-tool-result
                    tool result
                    :related-step-index
                    (develop-state-current-step-index develop-state))))
        (dolist (fact facts)
          (develop-state-record-runtime-vocab-fact develop-state fact))
        facts))))

(defun %asd-path-p (path)
  "Case-insensitive check for paths ending in '.asd'. Accepts
strings or pathnames; NIL inputs return NIL."
  (let ((ns (and path (cond
                        ((pathnamep path) (namestring path))
                        ((stringp path) path)))))
    (and ns
         (>= (length ns) 4)
         (string-equal ns ".asd" :start1 (- (length ns) 4)))))

(defun %maybe-mark-summary-dirty (develop-state patch-record)
  "Flip DEVELOP-STATE's project-summary dirty flag when PATCH-RECORD
targets a .asd file or a defpackage form. Best-effort: no-op when
DEVELOP-STATE is NIL or the project-summary slot is NIL.
Returns DEVELOP-STATE."
  (when (and develop-state patch-record
             (or (%asd-path-p (cl-harness/src/patch-record:patch-record-path
                               patch-record))
                 (let ((ft (cl-harness/src/patch-record:patch-record-form-type
                            patch-record)))
                   (and (stringp ft)
                        (string-equal ft "defpackage")))))
    (develop-state-mark-project-summary-dirty develop-state))
  develop-state)

(defparameter +read-file-tools+
  '("fs-read-file"
    "lisp-read-file"
    "fs-list-directory"
    "clgrep-search")
  "Tools whose successful invocation counts toward MAX-READ-FILES.
LLM-driven inspection of the project surface; bounded so a runaway
'read everything' loop is caught.")

(defparameter +tool-error-ring-size+ 3
  "Maximum number of recent agent-LLM-issued tool errors retained on
AGENT-STATE.LAST-TOOL-ERRORS. Internal — not exported.")

(defclass agent-state ()
  ((turn :initform 0 :accessor agent-state-turn)
   (status :initform :running :accessor agent-state-status)
   (final-verify :initform nil :accessor agent-state-final-verify)
   (final-action :initform nil :accessor agent-state-final-action)
   (token-total :initform 0 :accessor agent-state-token-total)
   (patch-count :initform 0 :accessor agent-state-patch-count
                :documentation "Source-mutating tool calls that returned
isError=false (i.e. patches actually applied).")
   (patch-attempts :initform 0 :accessor agent-state-patch-attempts
                   :documentation "Source-mutating tool calls including
failures, so the metric distinguishes \"tried\" from \"applied\".")
   (tool-call-count :initform 0 :accessor agent-state-tool-call-count
                    :documentation "Total successful agent-driven tool
invocations (LLM-proposed, dispatched via call-tool). Excludes
harness-internal calls such as fs-set-project-root setup or verify-task
plumbing.")
   (read-file-count :initform 0 :accessor agent-state-read-file-count
                    :documentation "Count of read-only file lookups
(fs-read-file, lisp-read-file, fs-list-directory, clgrep-search).")
   (repl-eval-count :initform 0 :accessor agent-state-repl-eval-count
                    :documentation "Count of repl-eval invocations.")
   (started-at :initform nil :accessor agent-state-started-at
               :documentation "LOCAL-TIME timestamp captured at the top
of RUN-AGENT, used to compute wall-clock elapsed for limit enforcement
and metrics.")
   (parse-error-streak :initform 0 :accessor agent-state-parse-error-streak
                       :documentation "Consecutive ACTION-PARSE-ERROR
count. Resets to zero on any successful PARSE-ACTION; when it reaches
RUN-LIMITS-MAX-ACTION-PARSE-ERRORS the loop exits :limit-exhausted with
limit-hit :max-action-parse-errors so a malformed-output streak cannot
silently consume the whole turn budget.")
   (consecutive-failed-patches
    :initform 0
    :accessor agent-state-consecutive-failed-patches
    :documentation "Consecutive source-mutating tool calls that returned
isError=true (e.g. lisp-edit-form / lisp-patch-form structural rejection
from parinfer auto-repair or token-match failure). Resets to zero on any
successful source-mutating call. When it reaches
RUN-LIMITS-MAX-CONSECUTIVE-FAILED-PATCHES the loop exits :limit-exhausted
with limit-hit :max-consecutive-failed-patches (backlog #45). The
non-streak counterpart is PATCH-ATTEMPTS which never resets.")
   (limit-hit :initform nil :accessor agent-state-limit-hit
              :documentation "When STATUS is :LIMIT-EXHAUSTED, names the
LIMIT slot keyword that was exceeded (:MAX-TURNS / :MAX-TOOL-CALLS /
:MAX-PATCHES / :MAX-READ-FILES / :MAX-REPL-EVALS / :MAX-WALL-CLOCK).")
   (develop-state :initarg :develop-state
                  :reader agent-state-develop-state
                  :initform nil
                  :documentation "When this agent loop is being driven
from inside a DEVELOP run, the back-reference to the caller's
DEVELOP-STATE so RUN-AGENT can record source-facts, patch-records, and
failures into the develop-level ledgers. NIL when run-agent is invoked
standalone (cl-harness:fix path).")
   (reason :initarg :reason
           :initform nil
           :accessor agent-state-reason
           :documentation "Failure-mode classification keyword set
when STATUS transitions to :ERROR or :GIVE-UP with a specific
reason (one of :auth-failed, :rate-limited, :http-server-error,
:http-client-error, :transport-timeout, :transport-unavailable,
:malformed-response, :empty-content). NIL on the success path.")
   (last-tool-errors :initform nil
                     :accessor agent-state-last-tool-errors
                     :documentation "Ring of up to +TOOL-ERROR-RING-SIZE+
plist entries for the most-recent agent-LLM-issued tool calls that
returned isError=true. Each entry: (:TOOL-NAME string :ARGS-SUMMARY
string :ERROR-TEXT string :TURN integer). Head is most recent.
Populated only by RECORD-TOOL-ERROR; per-step naturally because
agent-state is created fresh per RUN-AGENT."))
  (:documentation "Live state of one fix-loop run (PRD §10.2 agent-state)."))

(defun %make-agent-state-for-tests (&rest initargs &key &allow-other-keys)
  "Test-only helper: constructs an AGENT-STATE with sensible defaults
for slots whose presence is not what the test cares about. Forwards
INITARGS to MAKE-INSTANCE so tests can override any field. Not
exported; intended for use only by cl-harness/tests/*-test."
  (apply #'make-instance 'agent-state initargs))

(defun record-tool-error (state tool-name args-summary error-text turn)
  "Push a new tool-error entry to STATE's last-tool-errors ring;
truncate to +TOOL-ERROR-RING-SIZE+. Internal — called from
HANDLE-TOOL-CALL when an LLM-issued tool call returns isError=true."
  (let ((entry (list :tool-name tool-name
                     :args-summary args-summary
                     :error-text error-text
                     :turn turn)))
    (setf (agent-state-last-tool-errors state)
          (let ((updated (cons entry (agent-state-last-tool-errors state))))
            (if (> (length updated) +tool-error-ring-size+)
                (subseq updated 0 +tool-error-ring-size+)
                updated)))))

(defun %trunc-200 (s)
  "Return S truncated to 200 chars; flatten embedded newlines to spaces.
NIL/empty input returns the empty string."
  (let* ((str (if (stringp s) s ""))
         (flat (substitute #\Space #\Newline str))
         (trimmed (string-trim '(#\Space #\Tab) flat)))
    (if (> (length trimmed) 200)
        (subseq trimmed 0 200)
        trimmed)))

(defun %summarize-tool-args (tool-name args)
  "Return a one-line ≤200-char human-readable summary of TOOL-NAME's
ARGS hash-table. Dispatch table picks the salient key per tool; falls
back to a JSON dump for unknown tools. Internal — not exported."
  (flet ((g (k) (or (and (hash-table-p args) (gethash k args)) "")))
    (let ((s (cond
               ((string= tool-name "repl-eval")
                (%trunc-200 (g "code")))
               ((string= tool-name "lisp-edit-form")
                (format nil "~A ~A (~A)"
                        (g "form_type") (g "form_name") (g "operation")))
               ((string= tool-name "lisp-patch-form")
                (format nil "~A ~A" (g "form_type") (g "form_name")))
               ((string= tool-name "run-tests")
                (let ((sys (g "system")) (test (g "test")))
                  (if (and (stringp test) (plusp (length test)))
                      (format nil "~A::~A" sys test)
                      sys)))
               ((string= tool-name "load-system")
                (g "system"))
               ((string= tool-name "fs-write-file")
                (g "path"))
               ((string= tool-name "lisp-read-file")
                (let ((path (g "path")) (pat (g "name_pattern")))
                  (if (and (stringp pat) (plusp (length pat)))
                      (format nil "~A [pattern: ~A]" path pat)
                      path)))
               ((or (string= tool-name "code-find")
                    (string= tool-name "code-describe")
                    (string= tool-name "code-find-references"))
                (let ((name (g "name")) (kind (g "kind")))
                  (if (and (stringp kind) (plusp (length kind)))
                      (format nil "~A [~A]" name kind)
                      name)))
               (t
                (handler-case
                    (with-output-to-string (out)
                      (yason:encode args out))
                  (error () "(unrenderable args)"))))))
      (let ((trimmed (%trunc-200 s)))
        (if (zerop (length trimmed)) "(no args)" trimmed)))))

(defun %maybe-record-tool-error (state tool-name arguments result turn)
  "When RESULT carries isError=true, record a tool-error entry on
STATE. Internal helper called from HANDLE-TOOL-CALL only on
LLM-issued tool calls. ARGUMENTS may be NIL or a hash-table."
  (when (and (hash-table-p result)
             (let ((v (gethash "isError" result)))
               (and v (not (eq v :false)))))
    (let ((args (or arguments (make-hash-table :test 'equal))))
      (record-tool-error
       state
       tool-name
       (%summarize-tool-args tool-name args)
       (%trunc-200 (extract-content-text result))
       turn))))

(defun check-limits (state limits)
  "Compare STATE's counters against LIMITS and return the keyword for
the first exceeded limit, or NIL when the run is still within budget.

Limit keywords mirror the LIMIT slot names so the caller can stamp
AGENT-STATE-LIMIT-HIT verbatim. Order matters only for tie-breaking;
the agent loop calls this once per turn boundary so at most one
limit can fire on any given check."
  (cond
    ((>= (agent-state-turn state) (run-limits-max-turns limits))
     :max-turns)
    ((>= (agent-state-tool-call-count state)
         (run-limits-max-tool-calls limits))
     :max-tool-calls)
    ((>= (agent-state-patch-attempts state)
         (run-limits-max-patches limits))
     :max-patches)
    ((>= (agent-state-read-file-count state)
         (run-limits-max-read-files limits))
     :max-read-files)
    ((>= (agent-state-repl-eval-count state)
         (run-limits-max-repl-evals limits))
     :max-repl-evals)
    ((let ((started (agent-state-started-at state)))
       (and started
            (>= (timestamp-difference (now) started)
                (run-limits-max-wall-clock-seconds limits))))
     :max-wall-clock)
    ((>= (agent-state-parse-error-streak state)
         (run-limits-max-action-parse-errors limits))
     :max-action-parse-errors)
    ((>= (agent-state-consecutive-failed-patches state)
         (run-limits-max-consecutive-failed-patches limits))
     :max-consecutive-failed-patches)
    (t nil)))

;; --- Stub ---------------------------------------------------------------

(defun tool-schema-hints (policy)
  "Return tool argument hints for the high-pain tools POLICY permits.

The first real-LLM smoke run (transcript 2026-05-05) burned 12 turns
on argument-shape guessing for lisp-patch-form / lisp-edit-form. These
hints surface the required keys and the FORM_TYPE-vs-English-word trap
inline in the system prompt so the LLM can compose correct calls on
turn 1."
  (with-output-to-string (s)
    (when (or (allowed-tool-p policy "lisp-patch-form")
              (allowed-tool-p policy "lisp-edit-form")
              (allowed-tool-p policy "fs-write-file"))
      (format s "~%Tool argument schemas (required ⊕ optional keys):~%"))
    (when (allowed-tool-p policy "lisp-patch-form")
      (format s "  - lisp-patch-form: file_path, form_type, form_name, old_text, new_text.~%")
      (format s "      form_type uses Lisp form names like \"defun\", \"defmacro\",~%")
      (format s "      \"defmethod\", \"defclass\" — NOT generic English words like \"function\".~%")
      (format s "      For defmethod, include specializers in form_name,~%")
      (format s "      e.g. \"my-method ((obj my-class))\". old_text must match the form exactly once.~%"))
    (when (allowed-tool-p policy "lisp-edit-form")
      (format s "  - lisp-edit-form: file_path, form_type, form_name, operation ⊕ content.~%")
      (format s "      operation ∈ {\"replace\", \"insert_before\", \"insert_after\", \"delete\"}.~%")
      (format s "      For replace and insert_*, content is required and must contain exactly~%")
      (format s "      ONE top-level form (e.g. the full \"(defun ...)\" wrapper).~%")
      (format s "      form_name is the form's IDENTITY (the symbol or designator the form~%")
      (format s "      defines / refers to), NOT the form_type keyword. Examples:~%")
      (format s "        (defpackage #:demo/src/main ...)  → form_type \"defpackage\",~%")
      (format s "                                            form_name \"demo/src/main\"~%")
      (format s "        (in-package #:demo/src/main)      → form_type \"in-package\",~%")
      (format s "                                            form_name \"demo/src/main\"~%")
      (format s "        (defun greet (name) ...)          → form_type \"defun\",~%")
      (format s "                                            form_name \"greet\"~%")
      (format s "        (defmethod print-object ((o foo) s) ...)~%")
      (format s "                                          → form_type \"defmethod\",~%")
      (format s "                                            form_name \"print-object ((o foo) s)\"~%")
      (format s "      To add a brand-new defun to a file that has only a defpackage and an~%")
      (format s "      in-package, use insert_after with the in-package form (form_type~%")
      (format s "      \"in-package\", form_name = the package designator, e.g.~%")
      (format s "      \"demo/src/main\"). content = the complete \"(defun ...)\" wrapper.~%")
      (format s "      If two consecutive lisp-edit-form calls fail with \"form not found\"~%")
      (format s "      on the same form_name, the form_name is wrong — read the file with~%")
      (format s "      lisp-read-file collapsed=true to see the actual identifiers, or fall~%")
      (format s "      back to fs-write-file with the COMPLETE updated file contents.~%"))
    (when (allowed-tool-p policy "lisp-read-file")
      (format s "  - lisp-read-file: path ⊕ collapsed (default true), name_pattern, content_pattern.~%")
      (format s "      Prefer collapsed=true with name_pattern=\"^my-fn$\" for targeted reads.~%"))
    (when (allowed-tool-p policy "lisp-check-parens")
      (format s "  - lisp-check-parens: path or code (mutually exclusive).~%"))
    (when (or (allowed-tool-p policy "fs-read-file")
              (allowed-tool-p policy "fs-list-directory"))
      (format s "  - fs-read-file / fs-list-directory: path (absolute, inside project root).~%"))
    (when (allowed-tool-p policy "fs-write-file")
      (format s "  - fs-write-file: path (relative to project root) ⊕ content.~%")
      (format s "      OVERWRITES the file. Read the file first, then write the COMPLETE updated~%")
      (format s "      contents — fs-write-file is not a patching tool.~%")
      (format s "      Backlog #48: fs-write-file REFUSES to overwrite existing .lisp / .asd files.~%")
      (format s "      For source files that already exist (even when they contain only an~%")
      (format s "      in-package form), call lisp-edit-form with operation \"insert_after\"~%")
      (format s "      anchored on the in-package form instead. Reserve fs-write-file for~%")
      (format s "      brand-new files (e.g. a fresh tests/ helper). Symptom of misuse:~%")
      (format s "      tool-error \"Cannot overwrite existing .lisp/.asd with fs-write-file;~%")
      (format s "      use lisp-edit-form.\"~%"))
    (when (or (allowed-tool-p policy "load-system")
              (allowed-tool-p policy "run-tests"))
      (format s "  - load-system / run-tests: system (ASDF system name string,~%")
      (format s "      e.g. \"my-project\" or \"my-project/tests\").~%"))
    (when (allowed-tool-p policy "repl-eval")
      (format s "  - repl-eval: code (string of one or more forms) ⊕ package, timeout_seconds.~%"))
    (when (allowed-tool-p policy "clgrep-search")
      (format s "  - clgrep-search: pattern ⊕ path, form_types, include_form, limit.~%"))))

(defun system-prompt (policy)
  "Return the per-mode system prompt naming the JSON action schema, the
expected workflow, and the cl-mcp tools POLICY currently permits."
  (with-output-to-string (s)
    (format s "You are cl-harness, a coding agent fixing failing Common Lisp ~
tests by editing source files via cl-mcp tools.~%~%")
    (format s "Respond with exactly one JSON object per turn:~%")
    (format s "  {\"type\":\"tool_call\",\"tool\":\"<name>\",\"arguments\":{...}, \"thought\":\"...\"}~%")
    (format s "  {\"type\":\"finish\",\"status\":\"fixed\"|\"give_up\",\"summary\":\"...\"}~%~%")
    (format s "  {\"type\":\"test_change_request\",\"criteria\":[\"AC-...\"],\"rationale\":\"...\",\"test_source\":\"(deftest ...)\"}~%~%")
    (format s "Use test_change_request only when the generated test is insufficient for the goal. It must be additive-only: add coverage, never weaken or delete tests.~%~%")
    (format s "Workflow:~%")
    (case (policy-mode policy)
      (:runtime-native
       (format s "  1. PROBE first: use repl-eval / code-find / code-describe / inspect-object~%")
       (format s "     to understand the failing code before editing.~%")
       (format s "  2. PATCH: persist fixes via lisp-patch-form (small, scoped) or~%")
       (format s "     lisp-edit-form (whole-form replace/insert).~%")
       (format s "     IMPORTANT: repl-eval definitions are TRANSIENT — they vanish on worker~%")
       (format s "     restart. Always persist via lisp-{patch,edit}-form.~%")
       (format s "  3. VERIFY: source mutations auto-trigger load-system + run-tests; the verify~%")
       (format s "     summary is appended to the next user turn.~%")
       (format s "  4. FINISH: emit {\"type\":\"finish\",\"status\":\"fixed\"} only when run-tests~%")
       (format s "     reports zero failures. The harness then re-verifies on a fresh worker;~%")
       (format s "     a stale REPL state cannot fake success.~%~%")
       (format s "When you need to know whether a function / class / package /~%")
       (format s "method exists or what its signature is, prefer code-find /~%")
       (format s "code-describe / code-find-references over re-reading source~%")
       (format s "files. These tools query the LIVE Lisp runtime — they can~%")
       (format s "see definitions loaded by other systems and they reflect~%")
       (format s "the project's current vocabulary, not just what's on disk.~%")
       (format s "The harness records each successful query as a runtime-vocab~%")
       (format s "fact for later steps.~%~%"))
      (:generic-mcp
       (format s "  1. READ: use lisp-read-file (collapsed=true with name_pattern) to locate~%")
       (format s "     the failing definition.~%")
       (format s "  2. PATCH: persist fixes via lisp-patch-form (small, scoped) or~%")
       (format s "     lisp-edit-form (whole-form replace/insert).~%")
       (format s "  3. VERIFY: source mutations auto-trigger load-system + run-tests; the~%")
       (format s "     verify summary is appended to the next user turn.~%")
       (format s "  4. FINISH: emit {\"type\":\"finish\",\"status\":\"fixed\"} only when~%")
       (format s "     run-tests reports zero failures.~%~%"))
      (:file-only
       (format s "  1. READ: use fs-list-directory and fs-read-file to find and inspect~%")
       (format s "     the failing source.~%")
       (format s "  2. WRITE: rewrite the entire file with fs-write-file. There is no~%")
       (format s "     scoped patcher in this mode; you must produce the complete~%")
       (format s "     updated file content yourself.~%")
       (format s "  3. VERIFY: source mutations auto-trigger load-system + run-tests;~%")
       (format s "     the verify summary is appended to the next user turn.~%")
       (format s "  4. FINISH: emit {\"type\":\"finish\",\"status\":\"fixed\"} only when~%")
       (format s "     run-tests reports zero failures.~%~%"))
      (t
       (format s "  Use only the tools listed below; emit a finish action when done.~%~%")))
    (format s "Allowed tools (call them by exact name):~%")
    (dolist (tool (policy-allowed-tools policy))
      (format s "  - ~A~%" tool))
    (format s "~A" (tool-schema-hints policy))))

(defun verify-summary (verify-result)
  "Return a short human-readable summary of VERIFY-RESULT."
  (with-output-to-string (s)
    (format s "status: ~A" (verify-result-status verify-result))
    (when (verify-result-passed verify-result)
      (format s ", passed: ~A" (verify-result-passed verify-result)))
    (when (verify-result-failed verify-result)
      (format s ", failed: ~A" (verify-result-failed verify-result)))))

(defun format-failed-tests (failed-tests &key (limit 5))
  "Render up to LIMIT failed-test descriptors as a human-readable list.

FAILED-TESTS may be a vector or list (yason's choice depends on its
*PARSE-JSON-ARRAYS-AS-VECTORS* flag). Each entry is a hash-table with
test_name / description / form / values / reason / source keys produced
by cl-mcp's run-tests tool."
  (with-output-to-string (s)
    (let ((seen 0))
      (block dump
        (map nil
             (lambda (ft)
               (when (>= seen limit)
                 (format s "  ... (output truncated)~%")
                 (return-from dump))
               (format s "  - ~A~@[: ~A~]~%"
                       (gethash "test_name" ft)
                       (gethash "description" ft))
               (let ((reason (gethash "reason" ft)))
                 (when (and (stringp reason) (plusp (length reason)))
                   (format s "    reason: ~A~%" reason)))
               (let ((form (gethash "form" ft)))
                 (when (and (stringp form) (plusp (length form)))
                   (format s "    form:   ~A~%" form)))
               (incf seen))
             failed-tests)))))

(defparameter +load-failure-markers+
  '("no symbol named"
    "Package error"
    "package error"
    "undefined function"
    "unbound variable"
    "invalid initialization argument"
    "is not of type"
    "no applicable method"
    "Could not load")
  "Substrings inside a load-failure content block that almost always
identify the root cause (\"no symbol named X in PKG\", etc.). Used by
SUMMARIZE-LOAD-FAILURE to surface the precise diagnosis above the
verbose content dump.")

(defun summarize-load-failure (text)
  "Return the first non-empty line of TEXT that contains a known
load-failure marker, or NIL when no marker matches. Used to surface
the precise root-cause line (e.g. \"no symbol named X in PKG\")
above the full content dump in the system prompt."
  (when (and (stringp text) (plusp (length text)))
    (let ((lines (uiop:split-string text :separator #(#\Newline))))
      (find-if (lambda (line)
                 (let ((trimmed (string-trim
                                 '(#\Space #\Tab #\Return)
                                 line)))
                   (and (plusp (length trimmed))
                        (some (lambda (m) (search m trimmed :test #'char-equal))
                              +load-failure-markers+))))
               lines))))

(defun verify-detail-prose (verify-result)
  "Return a string detailing failed_tests and/or load failure text from
VERIFY-RESULT, or NIL when no such detail is available. Shared between
the initial-user-prompt and post-patch verify-fail message so the LLM
sees the same level of detail in both.

For load failures the precise root-cause line (when matched by
SUMMARIZE-LOAD-FAILURE) is hoisted above the verbose content dump as
a `Likely cause:` lead, since 003-missing-import in Phase 5.0 showed
the LLM scanning src/ files for the missing function while the actual
typo was in the tests/ :IMPORT-FROM clause."
  (let* ((tr (verify-result-test verify-result))
         (failed (and tr (gethash "failed_tests" tr)))
         (has-failed (and failed
                          (or (and (vectorp failed) (plusp (length failed)))
                              (and (listp failed) failed))))
         (lr (and (eq :load-failed (verify-result-status verify-result))
                  (verify-result-load verify-result)))
         (content (and lr (gethash "content" lr)))
         (load-text
          (when (and content (or (vectorp content) (listp content))
                     (plusp (length content)))
            (let ((first (elt content 0)))
              (and (hash-table-p first) (gethash "text" first)))))
         (diagnosis (and load-text (summarize-load-failure load-text))))
    (when (or has-failed load-text)
      (with-output-to-string (s)
        (when has-failed
          (format s "Failing tests:~%~A" (format-failed-tests failed)))
        (when diagnosis
          (format s "Likely cause: ~A~%"
                  (string-trim '(#\Space #\Tab #\Return) diagnosis)))
        (when load-text
          (format s "Load failure detail:~%~A~%" load-text))))))

(defun initial-user-prompt (config verify-result &key develop-state)
  "Return the first USER message that gives the LLM the project context
and the initial verification snapshot.

DEVELOP-STATE (v0.4 Phase C) is an opt-in wiring kwarg. When non-NIL
AND develop-state has a current-step-index set (i.e. the orchestrator
is mid-step), the issue line is replaced with the
`cl-harness/src/context-view:context-view->string' :implementation
rendering of the active plan-step. The project-root / system /
test-system orientation block, the verify-summary, and the
verify-detail-prose section remain byte-identical so the legacy path
(standalone cl-harness:fix callers, test stubs without develop-state,
develop-state without an active step) is preserved verbatim."
  (with-output-to-string (s)
    (format s "Project root: ~A~%" (run-config-project-root config))
    (format s "ASDF system: ~A~%" (run-config-system config))
    (format s "Test system: ~A~%" (run-config-test-system config))
    (let ((step-index (and develop-state
                           (develop-state-current-step-index develop-state))))
      (cond
        (step-index
         ;; Phase C.8 wiring: render the current step via the
         ;; :implementation formatter.
         (let* ((plan (develop-state-current-plan develop-state))
                (step (and plan (elt plan step-index))))
           (format s "~%~A~%"
                   (context-view->string
                    (make-context-view develop-state
                                       :phase :implementation
                                       :step step)
                    :implementation))))
        (t
         ;; Legacy path: preserved unchanged for standalone callers.
         (format s "Issue: ~A~%~%" (run-config-issue config)))))
    (format s "Initial verification: ~A~%" (verify-summary verify-result))
    (let ((detail (verify-detail-prose verify-result)))
      (when detail
        (format s "~%~A" detail)))))

(defun extract-content-text (result)
  "Pull the first text content block out of an MCP tools/call RESULT.
Returns the text or NIL when none is present."
  (let ((content (and (hash-table-p result) (gethash "content" result))))
    (when (and content (or (vectorp content) (listp content))
               (plusp (length content)))
      (let ((first (elt content 0)))
        (and (hash-table-p first) (gethash "text" first))))))

(defun summarize-run-tests (result)
  "Compact summary of a run-tests tools/call RESULT, including up to a few
failed_tests entries when present (PRD §10.3 SUMMARIZE-TOOL-RESULT).

When the failed_tests array exceeds the display limit (5), append a
single-line footer announcing how many failures were truncated so the
LLM is aware of the silent loss; the full list remains in the JSONL
transcript."
  (with-output-to-string (s)
    (let ((passed (gethash "passed" result))
          (failed (gethash "failed" result))
          (failed-tests (gethash "failed_tests" result))
          (display-limit 5))
      (format s "passed: ~A, failed: ~A~%" (or passed "?") (or failed "?"))
      (when
          (and failed-tests
               (or (and (vectorp failed-tests) (plusp (length failed-tests)))
                   (and (listp failed-tests) failed-tests)))
        (format s "~A" (format-failed-tests failed-tests :limit display-limit)))
      (let ((failed-count (cond ((vectorp failed-tests) (length failed-tests))
                                ((listp failed-tests) (length failed-tests))
                                (t 0))))
        (when (> failed-count display-limit)
          (format s "(~D more failure~:P truncated; see JSONL transcript for the full list)~%"
                  (- failed-count display-limit)))))))

(defun summarize-repl-eval (result)
  "Compact summary of a repl-eval tools/call RESULT.
Pulls the human-readable content text and the first error_context message
when present, ignoring large stack-frame payloads by default."
  (with-output-to-string (s)
    (let ((text (extract-content-text result))
          (err (gethash "error_context" result)))
      (when (and text (plusp (length text)))
        (format s "~A~%" text))
      (when (hash-table-p err)
        (format s "error: ~A: ~A~%"
                (or (gethash "condition_type" err) "<unknown>")
                (or (gethash "message" err) ""))))))

(defun default-tool-result-summary (result)
  "Fallback summary when no tool-specific summarizer is registered.
Surfaces the isError flag plus the first content text block; falls back
to a JSON dump only when no content text is present."
  (with-output-to-string (s)
    (when (and (hash-table-p result) (gethash "isError" result))
      (format s "ERROR. "))
    (let ((text (extract-content-text result)))
      (cond
        ((and text (plusp (length text)))
         (format s "~A" text))
        (t (yason:encode (or result (make-hash-table :test 'equal)) s))))))

(defun %tool-name-to-key (tool-name)
  "Coerce a tool-name string into its dispatch keyword.
\"run-tests\" → :RUN-TESTS, etc. Strings that already are keywords
or symbols pass through unchanged."
  (etypecase tool-name
    (keyword tool-name)
    (symbol (intern (symbol-name tool-name) :keyword))
    (string (intern (string-upcase tool-name) :keyword))))

(defparameter +default-tool-result-cap+ 1500
  "Default cap (in characters) for read-style tool results in
SUMMARIZE-TOOL-BY-KEY methods. Strings longer than this are
truncated with a '[... truncated, N chars elided ...]'
footer so the LLM can see that data was lost. The JSONL transcript
records the full tool result for audit / recovery.")

(defun %truncate-large-text (text &optional (cap +default-tool-result-cap+))
  "If TEXT is longer than CAP characters, return the first CAP
characters followed by an explicit truncation footer noting the
elided byte count. Otherwise return TEXT unchanged. NIL TEXT
returns NIL."
  (cond
    ((null text) nil)
    ((<= (length text) cap) text)
    (t (format nil "~A~%[... truncated, ~D chars elided ...]"
               (subseq text 0 cap)
               (- (length text) cap)))))

(defgeneric summarize-tool-by-key (tool-key result)
  (:documentation
   "Per-tool summarizer dispatched on a keyword TOOL-KEY (e.g.
:RUN-TESTS). Specialize with an eql method to register a custom
summarizer for a new MCP tool — the default method falls through to
DEFAULT-TOOL-RESULT-SUMMARY, which surfaces isError + content text or
JSON-dumps the result.

Tier 4 C-2 refactor (was a cond inside SUMMARIZE-TOOL-RESULT). The
SUMMARIZE-TOOL-RESULT public entry handles the (null result) guard
and the string→keyword conversion, then dispatches here."))

(defmethod summarize-tool-by-key (tool-key result)
  (declare (ignore tool-key))
  (default-tool-result-summary result))

(defmethod summarize-tool-by-key ((tool-key (eql :run-tests)) result)
  (summarize-run-tests result))

(defmethod summarize-tool-by-key ((tool-key (eql :repl-eval)) result)
  (summarize-repl-eval result))

(macrolet ((deftext-method (key)
             `(defmethod summarize-tool-by-key ((tool-key (eql ,key)) result)
                (or (%truncate-large-text (extract-content-text result))
                    "(empty)"))))
  ;; Read-only probes whose useful payload is just the first content
  ;; text block. Adding a new probe? Drop another deftext-method here
  ;; or define your own (defmethod summarize-tool-by-key ...).
  ;;
  ;; Phase D.3: results are passed through %TRUNCATE-LARGE-TEXT so
  ;; long file/grep payloads can't balloon the agent's MESSAGES list.
  ;; Full results are still recorded in the JSONL transcript.
  (deftext-method :code-find)
  (deftext-method :code-describe)
  (deftext-method :code-find-references)
  (deftext-method :inspect-object)
  (deftext-method :lisp-read-file)
  (deftext-method :clgrep-search))

(defmethod summarize-tool-by-key ((tool-key (eql :fs-read-file)) result)
  ;; Phase D.3: cap fs-read-file output the same way the macro caps
  ;; the lisp-read-file / clgrep-search family. Falls back to the
  ;; default summarizer when no content text is present so the
  ;; isError flag and JSON dump still reach the caller.
  (or (%truncate-large-text (extract-content-text result))
      (default-tool-result-summary result)))

(defun summarize-tool-result (tool-name result)
  "Return a compact human-readable summary of the MCP tools/call RESULT
hash-table for TOOL-NAME (PRD §10.3 SUMMARIZE-TOOL-RESULT).

Dispatch is via SUMMARIZE-TOOL-BY-KEY's keyword-eql methods; specialize
that generic to register a new tool's summarizer. The default method
calls DEFAULT-TOOL-RESULT-SUMMARY, which surfaces isError + content
text or JSON-dumps the result."
  (cond
    ((null result) "(no result)")
    (t (summarize-tool-by-key (%tool-name-to-key tool-name) result))))

(defun %verify-failed-tests-payload (verify-result)
  "Extract the failed_tests array from VERIFY-RESULT for JSONL emission.
Returns NIL when none failed (so the caller can omit the field).

VERIFY-RESULT's TEST slot is the hash-table that run-tests tool
returned; its \"failed_tests\" entry is a vector of per-test
hash-tables with keys test_name / description / form / values /
reason / source. Pass-through as-is so future fields on
test-runner-core ride along automatically."
  (let* ((tr (verify-result-test verify-result))
         (failed (and tr (gethash "failed_tests" tr))))
    (cond
      ((null failed) nil)
      ((and (vectorp failed) (zerop (length failed))) nil)
      ((and (listp failed) (null failed)) nil)
      (t failed))))

(defun verify-event-payload (turn verify-result)
  "Return an alist describing VERIFY-RESULT for the JSONL transcript.
When VERIFY-RESULT has failed tests, the alist also carries a
\"failed_tests\" entry (vector of per-test hash-tables, see
%VERIFY-FAILED-TESTS-PAYLOAD). On pass the field is omitted."
  (let ((base `(("turn" . ,turn)
                ("status" . ,(string-downcase
                              (symbol-name (verify-result-status verify-result))))
                ("passed" . ,(or (verify-result-passed verify-result) 0))
                ("failed" . ,(or (verify-result-failed verify-result) 0))))
        (failed (%verify-failed-tests-payload verify-result)))
    (if failed
        (append base `(("failed_tests" . ,failed)))
        base)))

(defun action-event-payload (turn action)
  "Return an alist describing ACTION for the JSONL transcript."
  (let ((base `(("turn" . ,turn)
                ("type" . ,(string-downcase
                            (symbol-name (agent-action-type action)))))))
    (case (agent-action-type action)
      (:tool-call
       (append base `(("tool" . ,(agent-action-tool action)))))
      (:finish
       (append base
               `(("status" . ,(string-downcase
                               (symbol-name (agent-action-status action))))
                 ("summary" . ,(or (agent-action-summary action) "")))))
      (:test-change-request
       (append base
               `(("rationale" . ,(or (agent-action-rationale action) ""))
                 ("test_source" . ,(or (agent-action-test-source action) ""))))))))

(defun finalize (state status &key verify action limit-hit)
  "Stamp STATE's terminal fields and return STATE."
  (setf (agent-state-status state) status)
  (when verify (setf (agent-state-final-verify state) verify))
  (when action (setf (agent-state-final-action state) action))
  (when limit-hit (setf (agent-state-limit-hit state) limit-hit))
  state)

(defun run-end-event-payload (state)
  "Return the alist used as the JSONL :RUN-END event body. Captures
the full PRD §8.10 REQ-LOG-002 metric set (turn count, tool-call
count, patch counts, read-file count, repl-eval count, token total,
elapsed wall clock) plus terminal status / limit-hit."
  (let ((started (agent-state-started-at state)))
    (append
     `(("status" . ,(string-downcase
                     (symbol-name (agent-state-status state)))))
     (when (agent-state-limit-hit state)
       `(("limit_hit"
          . ,(string-downcase
              (symbol-name (agent-state-limit-hit state))))))
     `(("turns" . ,(agent-state-turn state))
       ("tool_call_count" . ,(agent-state-tool-call-count state))
       ("patch_count" . ,(agent-state-patch-count state))
       ("patch_attempts" . ,(agent-state-patch-attempts state))
       ("read_file_count" . ,(agent-state-read-file-count state))
       ("repl_eval_count" . ,(agent-state-repl-eval-count state))
       ("token_total" . ,(agent-state-token-total state)))
     (when started
       `(("elapsed_seconds"
          . ,(coerce (timestamp-difference (now) started) 'double-float)))))))

(defun emit-run-end (state logger)
  "Log the :RUN-END event for STATE and return STATE. Keeps every
RUN-AGENT exit path uniform so post-mortem analysis only has to look
at the last event in the transcript."
  (log-event logger :run-end (run-end-event-payload state))
  state)

(defun finalize-passed (state mcp-client config logger
                        incremental-verify action
                        &key (clean-verify-p t)
                             before-clean-verify-fn)
  "Confirm a :PASSED outcome via CLEAN-VERIFY-TASK on a fresh worker.

When the clean reload also reports zero failures STATE's status stays
:PASSED. Otherwise the agent reports :DIRTY-ONLY so the caller knows the
incremental success did not survive a fresh image (PRD §8.9
REQ-VERIFY-002, REQ-VERIFY-003).

CLEAN-VERIFY-P NIL skips the pool-kill + reverify step entirely.

BEFORE-CLEAN-VERIFY-FN is forwarded to CLEAN-VERIFY-TASK so callers
that registered ephemeral ASDF state into the previous worker (e.g.
the benchmark runner's source-registry override) can re-apply it to
the freshly spawned worker before the verify-task LOAD-SYSTEM call."
  (cond
    ((not clean-verify-p)
     (finalize state :passed :verify incremental-verify :action action))
    (t
     (let ((clean (clean-verify-task mcp-client config
                                     :before-load-fn before-clean-verify-fn)))
       (log-event logger :clean-verify (verify-event-payload -1 clean))
       (cond
         ((verify-result-success-p clean)
          (finalize state :passed :verify clean :action action))
         (t
          (log-event logger :dirty-only
                     `(("incremental_status"
                        . ,(string-downcase
                            (symbol-name
                             (verify-result-status incremental-verify))))
                       ("clean_status"
                        . ,(string-downcase
                            (symbol-name (verify-result-status clean))))))
          (finalize state :dirty-only :verify clean :action action)))))))

(defun append-message (messages role content)
  "Return MESSAGES with a freshly constructed MESSAGE appended."
  (append messages (list (make-chat-message role content))))

(defun handle-finish-action (action)
  "Map a :FINISH ACTION to the agent's terminal status keyword."
  (case (agent-action-status action)
    (:fixed :passed)
    (:give-up :give-up)))

(defun handle-tool-call (turn state config mcp-client policy logger
                         messages action
                         &key dry-run-p)
  "Dispatch a :TOOL-CALL ACTION via MCP-CLIENT, optionally auto-verifying.
Returns (values NEW-MESSAGES OUTCOME VERIFY ACTION). OUTCOME is NIL when
the loop should continue, or a terminal status keyword.

When DRY-RUN-P is non-NIL the call is intercepted before reaching MCP:
a :dry-run-skip event is logged and the LLM receives a synthetic empty
success result. Source-mutating tools additionally skip the auto-reverify
step since no real patch was applied."
  (let ((tool (agent-action-tool action)))
    (cond
      ((not (allowed-tool-p policy tool))
       (log-event logger :denied
                  `(("turn" . ,turn) ("tool" . ,tool)
                    ("policy" . ,(string-downcase
                                  (symbol-name (policy-mode policy))))))
       (values
        (append-message messages "user"
                        (format nil "Tool ~A is not permitted in mode ~A. Choose another tool."
                                tool (policy-mode policy)))
        nil nil nil))
      (t
       (incf (agent-state-tool-call-count state))
       (cond
         ((member tool +read-file-tools+ :test #'equal)
          (incf (agent-state-read-file-count state)))
         ((equal tool "repl-eval")
          (incf (agent-state-repl-eval-count state))))
       (let* ((target (when (member tool +source-mutating-tools+
                                    :test #'equal)
                        (%resolve-patch-target
                         config
                         (or (agent-action-arguments action)
                             (make-hash-table :test 'equal))
                         tool)))
              (before (and target (not dry-run-p)
                           (%read-file-safely target)))
              (result
               (cond
                 (dry-run-p
                  (log-event logger :dry-run-skip
                             `(("turn" . ,turn) ("tool" . ,tool)))
                  (alist-hash-table
                   `(("isError" . :false)
                     ("content"
                      . ,(vector
                          (alist-hash-table
                           `(("type" . "text")
                             ("text" . "[dry-run: tool not executed]"))
                           :test 'equal))))
                   :test 'equal))
                 (t
                  (handler-case
                      (call-tool mcp-client tool
                                 (or (agent-action-arguments action)
                                     (make-hash-table :test 'equal)))
                    (mcp-error (c)
                      (log-event logger :tool-error
                                 `(("turn" . ,turn) ("tool" . ,tool)
                                   ("code" . ,(mcp-error-code c))
                                   ("message" . ,(mcp-error-message c))))
                      (alist-hash-table
                       `(("isError" . t)
                         ("content"
                          . ,(vector
                              (alist-hash-table
                               `(("type" . "text")
                                 ("text"
                                  . ,(format nil "MCP error ~A: ~A"
                                             (mcp-error-code c)
                                             (mcp-error-message c))))
                               :test 'equal))))
                       :test 'equal)))))))
         (let* ((is-error (and (gethash "isError" result) t))
                (error-text (and is-error (extract-content-text result))))
           (let ((tool-summary (when (not is-error)
                                 (summarize-tool-result tool result))))
             (log-event logger :tool-result
                        `(("turn" . ,turn) ("tool" . ,tool)
                          ("is_error" . ,is-error)
                          ,@(when (and error-text (plusp (length error-text)))
                              `(("error_text" . ,error-text)))
                          ,@(when (and tool-summary (plusp (length tool-summary)))
                              `(("content_summary" . ,tool-summary))))))
           ;; Populate the per-step tool-error ring on isError=true. Only
           ;; LLM-issued tool calls land here (HANDLE-TOOL-CALL is on that
           ;; path); harness-internal calls (verify-task setup,
           ;; pool-kill-worker) do not pass through this function.
           (%maybe-record-tool-error
            state tool
            (or (agent-action-arguments action) (make-hash-table :test 'equal))
            result turn))
         (let ((next (append-message
                      messages "user"
                      (format nil "Tool ~A result:~%~A"
                              tool (summarize-tool-result tool result)))))
           ;; Record a SOURCE-FACT on the develop-level ledger for any
           ;; successful read-style tool call. The fact carries the
           ;; develop-state's current step-index so per-step context
           ;; views (Phase C/F) can filter to facts read in the active
           ;; step.
           (when (and (agent-state-develop-state state)
                      (not (and (gethash "isError" result) t))
                      (member tool '("lisp-read-file" "fs-read-file"
                                     "clgrep-search")
                              :test #'string=))
             (let* ((arguments (or (agent-action-arguments action)
                                   (make-hash-table :test 'equal)))
                    (target-path (and (hash-table-p arguments)
                                      (gethash "path" arguments))))
               (when (and (stringp target-path) (plusp (length target-path)))
                 (develop-state-record-source-fact
                  (agent-state-develop-state state)
                  (make-source-fact
                   :path target-path
                   :via-tool tool
                   :form-type (and (hash-table-p arguments)
                                   (gethash "form_type" arguments))
                   :form-name (and (hash-table-p arguments)
                                   (gethash "form_name" arguments))
                   :related-step-index
                   (develop-state-current-step-index
                    (agent-state-develop-state state)))))))
           ;; Record runtime-vocab-facts on the develop-level ledger
           ;; for any successful runtime-introspection tool call. The
           ;; recorded facts carry the develop-state's current
           ;; step-index so per-step context views can find them.
           (%record-runtime-vocab-from-tool-call tool result state)
           (cond
             ((member tool +source-mutating-tools+ :test #'equal)
              (incf (agent-state-patch-attempts state))
              (cond
                ((gethash "isError" result)
                 (incf (agent-state-consecutive-failed-patches state))
                 (values next nil nil nil))
                (dry-run-p
                 (incf (agent-state-patch-count state))
                 (setf (agent-state-consecutive-failed-patches state) 0)
                 (values next nil nil nil))
                (t
                 (incf (agent-state-patch-count state))
                 (setf (agent-state-consecutive-failed-patches state) 0)
                 (when target
                   (let* ((after (%read-file-safely target))
                          (diff (%compute-unified-diff
                                 before after (namestring target))))
                     (log-event
                      logger :patch
                      `(("turn" . ,turn)
                        ("tool" . ,tool)
                        ("file" . ,(namestring target))
                        ("diff" . ,(or diff ""))))
                     (when (agent-state-develop-state state)
                       (let* ((arguments (or (agent-action-arguments action)
                                             (make-hash-table :test 'equal)))
                              (record
                               (make-patch-record
                                :path target
                                :via-tool tool
                                :form-type (and (hash-table-p arguments)
                                                (gethash "form_type" arguments))
                                :form-name (and (hash-table-p arguments)
                                                (gethash "form_name" arguments))
                                :operation (and (hash-table-p arguments)
                                                (gethash "operation" arguments))
                                :diff-summary
                                (when (and diff (plusp (length diff)))
                                  (subseq diff 0 (min 500 (length diff))))
                                :related-step-index
                                (develop-state-current-step-index
                                 (agent-state-develop-state state))
                                :turn turn)))
                         (develop-state-record-patch-record
                          (agent-state-develop-state state)
                          record)
                         (%maybe-mark-summary-dirty
                          (agent-state-develop-state state)
                          record)))))
                 (let ((v (verify-task mcp-client config)))
                   (log-event logger :verify (verify-event-payload turn v))
                   (if (verify-result-success-p v)
                       (values next :passed v action)
                       (progn
                         (%record-failed-verify state v)
                         (let* ((detail (verify-detail-prose v))
                                (msg (with-output-to-string (s)
                                       (format s "Verify after patch: ~A~%"
                                               (verify-summary v))
                                       (when detail (format s "~A" detail)))))
                           (values (append-message next "user" msg)
                                   nil nil nil))))))))
             (t (values next nil nil nil)))))))))

(defun %maybe-compact-messages (messages run-limits)
  "When the approximate token estimate of MESSAGES exceeds
RUN-LIMITS-MAX-CONTEXT-TOKENS, return the result of COMPACT-HISTORY;
otherwise return MESSAGES unchanged. Returns MESSAGES unchanged when
RUN-LIMITS is NIL.

Returns (VALUES EFFECTIVE-MESSAGES INFO) where INFO is NIL when no
compaction was applied, otherwise a plist with :THRESHOLD, :MESSAGES-IN,
:MESSAGES-OUT, :TOKENS-ESTIMATE-IN, :TOKENS-ESTIMATE-OUT so callers can
emit a :compact JSONL event for post-hoc visibility (backlog H, 2026-05-25
context-mgmt code review).

The threshold is approximate (chars/4 heuristic via
APPROXIMATE-HISTORY-TOKENS); fine-grained accuracy is not the goal —
keeping the context window from blowing during long agent runs is.

The compaction is per-call and does not mutate MESSAGES. Callers pass
the compacted result to COMPLETE-CHAT; the agent loop's own message
threading is left alone so the JSONL transcript still records the full
conversation."
  (let ((threshold (and run-limits
                        (run-limits-max-context-tokens run-limits))))
    (cond
      ((not (and threshold
                 (> (approximate-history-tokens messages) threshold)))
       (values messages nil))
      (t
       (let* ((tokens-in (approximate-history-tokens messages))
              (compacted (compact-history messages))
              (tokens-out (approximate-history-tokens compacted)))
         (values compacted
                 (list :threshold threshold
                       :messages-in (length messages)
                       :messages-out (length compacted)
                       :tokens-estimate-in tokens-in
                       :tokens-estimate-out tokens-out)))))))

(defun %record-failed-verify (state verify)
  "Persist VERIFY (a VERIFY-RESULT, even on failure) onto STATE so
%FAILURE-CONTEXT can read VERIFY-RESULT-LOAD / VERIFY-RESULT-TEST
when the agent loop later terminates with :GIVE-UP /
:LIMIT-EXHAUSTED. Without this, agent-state-final-verify only
captures the :PASSED success path. Internal — called from
HANDLE-TOOL-CALL's post-patch verify branch."
  (when verify
    (setf (agent-state-final-verify state) verify)))

(defun %complete-chat-with-logging (provider messages config state logger turn)
  "Call COMPLETE-CHAT and emit a :llm-response event. When
RUN-CONFIG-LOG-LLM-REQUESTS-P is true on CONFIG, also emit a
:llm-request event BEFORE the chat call carrying the full messages
history. STATE's token-total is incremented from the response.
Returns the CHAT-RESPONSE.

Extracted from inline use in the agent loop so the dual logging
boundary is unit-testable without standing up the whole loop."
  (multiple-value-bind (effective-messages compact-info)
      (%maybe-compact-messages messages (run-config-limits config))
    (when compact-info
      ;; Backlog H (2026-05-25): emit visibility event whenever
      ;; compact-history was invoked so post-hoc bench analysis can see
      ;; how often and how aggressively the threshold fires.
      (log-event
       logger :compact
       `(("turn" . ,turn)
         ("threshold" . ,(getf compact-info :threshold))
         ("messages_in" . ,(getf compact-info :messages-in))
         ("messages_out" . ,(getf compact-info :messages-out))
         ("tokens_estimate_in" . ,(getf compact-info :tokens-estimate-in))
         ("tokens_estimate_out" . ,(getf compact-info :tokens-estimate-out)))))
    (let ((effective-tokens (approximate-history-tokens effective-messages)))
      (when (run-config-log-llm-requests-p config)
        (log-event
         logger :llm-request
         `(("turn" . ,turn)
           ("messages" . ,(coerce
                           (mapcar (lambda (m)
                                     (alist-hash-table
                                      `(("role" . ,(gethash "role" m))
                                        ("content" . ,(gethash "content" m)))
                                      :test 'equal))
                                   effective-messages)
                           'vector))
           ("messages_count" . ,(length effective-messages))
           ("messages_tokens_estimate" . ,effective-tokens))))
      (let* ((chat (complete-chat provider effective-messages))
             (text (chat-response-content chat)))
        (incf (agent-state-token-total state)
              (or (chat-response-total-tokens chat) 0))
        (log-event logger :llm-response
                   `(("turn" . ,turn)
                     ("content" . ,text)
                     ("tokens" . ,(or (chat-response-total-tokens chat) 0))
                     ;; Backlog H: surface prompt-side token estimate on
                     ;; every LLM call (always, regardless of
                     ;; log-llm-requests-p) so analysis can see how close
                     ;; runs come to max-context-tokens without dumping
                     ;; full message content.
                     ("messages_count" . ,(length effective-messages))
                     ("messages_tokens_estimate" . ,effective-tokens)))
        chat))))

(defun step-turn (turn state config provider mcp-client policy logger messages
                  &key dry-run-p)
  "Run one turn of the agent loop.

Returns (values NEW-MESSAGES OUTCOME VERIFY ACTION). OUTCOME is NIL when
the loop should continue, otherwise a terminal status keyword
(:PASSED / :GIVE-UP)."
  (let* ((chat (%complete-chat-with-logging provider messages config state
                                            logger turn))
         (text (chat-response-content chat)))
    (cond
      ((or (null text) (zerop (length text)))
       ;; C2 empty-content path: immediate :give-up :empty-content,
       ;; no re-prompt. A degenerate empty reply otherwise triggers
       ;; an action-parse-error churn that cannot recover -- the
       ;; provider just returned nothing for the LLM to amend.
       (setf (agent-state-reason state) :empty-content)
       (values messages :give-up nil nil))
      (t
       (handler-case
           (let ((action (parse-action text)))
             (setf (agent-state-parse-error-streak state) 0)
             (log-event logger :action (action-event-payload turn action))
             (let ((with-assistant (append-message messages "assistant" text)))
               (case (agent-action-type action)
                 (:finish
                  (values with-assistant
                          (handle-finish-action action)
                          nil action))
                 (:tool-call
                  (handle-tool-call turn state config mcp-client policy logger
                                    with-assistant action
                                    :dry-run-p dry-run-p))
                 (:test-change-request
                  (values with-assistant :test-change-request nil action)))))
         (action-parse-error (c)
           (incf (agent-state-parse-error-streak state))
           (log-event logger :action-error
                      `(("turn" . ,turn)
                        ("streak" . ,(agent-state-parse-error-streak state))
                        ("message" . ,(action-parse-error-message c))))
           (values
            (append-message
             (append-message messages "assistant" text)
             "user"
             (format nil "Could not parse your previous reply: ~A. Respond with one JSON object matching the schema."
                     (action-parse-error-message c)))
            nil nil nil)))))))

(defun run-agent (config provider mcp-client policy logger
                  &key (clean-verify-p t)
                       dry-run-p
                       before-clean-verify-fn
                       (isolate-asdf-p t)
                       develop-state)
  "Execute the basic Phase 2 fix loop with a Phase 3 clean-verify safety net.

CONFIG is a RUN-CONFIG. PROVIDER is an OPENAI-COMPATIBLE-PROVIDER (or any
class with a COMPLETE-CHAT method). MCP-CLIENT must already be
initialize-mcp'd. POLICY is the TOOL-POLICY restricting tool calls.
LOGGER is an open RUN-LOGGER.

Every :PASSED outcome (initial verify, auto-reverify after a patch, or
LLM :finish :fixed) is reconfirmed via CLEAN-VERIFY-TASK on a fresh
worker; failure of the clean reload downgrades the run to :DIRTY-ONLY.

CLEAN-VERIFY-P NIL skips the clean-verify step. The benchmark runner
sets this when it has registered a sandbox system via asdf:load-asd in
the agent's current worker, since a worker reset would lose the
registration.

DRY-RUN-P (PRD §8.1 REQ-CLI-003) routes every LLM-proposed
source-mutating tool call through a synthetic success result instead of
invoking call-tool, so the loop exercises the LLM and prompt without
ever touching the project. Auto-reverify after a stubbed patch is also
skipped (no real change to verify). Useful for prompt iteration without
burning MCP turnaround.

ISOLATE-ASDF-P (default T) is the clean-room switch. When true, on entry
RUN-AGENT (1) calls pool-kill-worker :reset t to discard any state left
over from a previous run, (2) restricts the new worker's ASDF
source-registry to the project-root via SCOPE-ASDF-TO-PROJECT, and (3)
re-applies the same scope inside the clean-verify pool-kill (composing
with any user-supplied BEFORE-CLEAN-VERIFY-FN). Required for
`cl-harness:fix' to be honest when the worker has previously loaded a
same-named system from a different directory; benchmark callers get the
same guarantee for free.

DEVELOP-STATE, when non-NIL, is the caller DEVELOP-STATE this agent
loop is being driven from. Stashed on the constructed AGENT-STATE so
that the patch instrumentation can record patch-records onto the
develop-level ledger. NIL for standalone cl-harness:fix runs.

Limits enforcement (PRD §8.4 REQ-AGENT-003): all seven RUN-LIMITS
slots are now checked at every turn boundary (max-turns / max-tool-calls
/ max-patches / max-read-files / max-repl-evals /
max-wall-clock-seconds / max-action-parse-errors). On exceeding any of
them STATE's STATUS becomes :LIMIT-EXHAUSTED and LIMIT-HIT names the
offending slot."
  (let ((state (make-instance 'agent-state :develop-state develop-state))
        (effective-before-clean-verify-fn before-clean-verify-fn))
    (setf (agent-state-started-at state) (now))
    (when isolate-asdf-p
      ;; Clean-room the worker before the initial verify-task fires:
      ;; (1) discard any leftover REPL/system state from a prior run,
      ;; (2) restrict the worker's ASDF source-registry to PROJECT-ROOT.
      ;; Without this `(asdf:find-system "<system>")' may resolve to a
      ;; same-named .asd elsewhere in ~/.roswell/local-projects/ — a copy
      ;; the agent's patches will never reach.
      (call-tool mcp-client "pool-kill-worker"
                 (alist-hash-table '(("reset" . t)) :test 'equal))
      (scope-asdf-to-project mcp-client
                             (run-config-project-root config)
                             (run-config-system config)
                             (run-config-test-system config))
      ;; Clean-verify spawns a fresh worker that loses the scope above,
      ;; so re-apply it (composing with any caller-supplied callback).
      (let ((user-fn before-clean-verify-fn))
        (setf effective-before-clean-verify-fn
              (lambda (client)
                (scope-asdf-to-project client
                                       (run-config-project-root config)
                                       (run-config-system config)
                                       (run-config-test-system config))
                (when user-fn (funcall user-fn client))))))
    (call-tool mcp-client "fs-set-project-root"
               (alist-hash-table
                `(("path" . ,(princ-to-string
                              (run-config-project-root config))))
                :test 'equal))
    (log-event logger :run-start
               `(("project_root" . ,(princ-to-string
                                     (run-config-project-root config)))
                 ("system" . ,(run-config-system config))
                 ("test_system" . ,(run-config-test-system config))
                 ("issue" . ,(run-config-issue config))
                 ("policy" . ,(string-downcase
                               (symbol-name (policy-mode policy))))
                 ("dry_run" . ,(and dry-run-p t))))
    (let ((initial (verify-task mcp-client config))
          (limits (run-config-limits config)))
      (log-event logger :verify (verify-event-payload 0 initial))
      (when (verify-result-success-p initial)
        (return-from run-agent
          (emit-run-end
           (finalize-passed state mcp-client config logger initial nil
                            :clean-verify-p clean-verify-p
                            :before-clean-verify-fn effective-before-clean-verify-fn)
           logger)))
      (let ((messages (list (make-chat-message "system" (system-prompt policy))
                            (make-chat-message
                             "user" (initial-user-prompt
                                     config initial
                                     :develop-state develop-state)))))
        (loop for turn from 1
              do (setf (agent-state-turn state) turn)
                 (multiple-value-bind (next-messages outcome verify action)
                     (step-turn turn state config provider mcp-client
                                policy logger messages
                                :dry-run-p dry-run-p)
                   (cond
                     (outcome
                      (return-from run-agent
                        (emit-run-end
                         (case outcome
                           (:passed
                            (finalize-passed state mcp-client config logger
                                             verify action
                                             :clean-verify-p clean-verify-p
                                             :before-clean-verify-fn effective-before-clean-verify-fn))
                           (:give-up
                            (finalize state :give-up :action action))
                           (:test-change-request
                            (finalize state :test-change-request
                                      :action action)))
                         logger)))
                     (t (setf messages next-messages))))
                 (let ((limit-hit (check-limits state limits)))
                   (when limit-hit
                     (log-event logger :limit-exhausted
                                `(("limit"
                                   . ,(string-downcase
                                       (symbol-name limit-hit)))
                                  ("turn" . ,(agent-state-turn state))))
                     (return-from run-agent
                       (emit-run-end
                        (finalize state :limit-exhausted
                                  :limit-hit limit-hit)
                        logger)))))))))

(defun format-final-report (state &key log-path)
  "Return a one-paragraph human-readable summary of STATE.

Surfaces the terminal status, turns consumed, patches applied, total
chat tokens, the final verify snapshot, and (optionally) the JSONL
transcript path. Used by the CLI to print a closing report."
  (with-output-to-string (s)
    (format s "== cl-harness fix report ==~%")
    (format s "Status:           ~S~@[ (limit: ~S)~]~%"
            (agent-state-status state)
            (agent-state-limit-hit state))
    (format s "Turns:            ~D~%" (agent-state-turn state))
    (format s "Tool calls:       ~D~%" (agent-state-tool-call-count state))
    (format s "Patches applied:  ~D (attempted ~D)~%"
            (agent-state-patch-count state)
            (agent-state-patch-attempts state))
    (format s "File reads:       ~D~%" (agent-state-read-file-count state))
    (format s "REPL evals:       ~D~%" (agent-state-repl-eval-count state))
    (format s "Chat tokens:      ~D~%" (agent-state-token-total state))
    (let ((started (agent-state-started-at state)))
      (when started
        (format s "Wall clock:       ~,1Fs~%"
                (timestamp-difference (now) started))))
    (let ((v (agent-state-final-verify state)))
      (if v
          (format s "Final verify:     status ~S, passed ~A, failed ~A~%"
                  (verify-result-status v)
                  (or (verify-result-passed v) "?")
                  (or (verify-result-failed v) "?"))
          (format s "Final verify:     (none)~%")))
    (when log-path
      (format s "Transcript:       ~A~%" log-path))))
