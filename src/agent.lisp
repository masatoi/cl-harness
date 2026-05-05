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
                #:run-limits-max-turns
                #:run-limits-max-tool-calls
                #:run-limits-max-patches
                #:run-limits-max-read-files
                #:run-limits-max-repl-evals
                #:run-limits-max-wall-clock-seconds
                #:run-limits-max-action-parse-errors)
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
                #:action-parse-error
                #:action-parse-error-message)
  (:import-from #:cl-harness/src/policy
                #:policy-mode
                #:policy-allowed-tools
                #:allowed-tool-p)
  (:import-from #:cl-harness/src/verify
                #:verify-result-status
                #:verify-result-passed
                #:verify-result-failed
                #:verify-result-test
                #:verify-result-load
                #:verify-result-success-p
                #:verify-task
                #:clean-verify-task)
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
           #:run-agent
           #:format-final-report
           #:summarize-tool-result
           #:+source-mutating-tools+))

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

(defparameter +read-file-tools+
  '("fs-read-file"
    "lisp-read-file"
    "fs-list-directory"
    "clgrep-search")
  "Tools whose successful invocation counts toward MAX-READ-FILES.
LLM-driven inspection of the project surface; bounded so a runaway
'read everything' loop is caught.")

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
   (limit-hit :initform nil :accessor agent-state-limit-hit
              :documentation "When STATUS is :LIMIT-EXHAUSTED, names the
LIMIT slot keyword that was exceeded (:MAX-TURNS / :MAX-TOOL-CALLS /
:MAX-PATCHES / :MAX-READ-FILES / :MAX-REPL-EVALS / :MAX-WALL-CLOCK)."))
  (:documentation "Live state of one fix-loop run (PRD §10.2 agent-state)."))

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
      (format s "      ONE top-level form (e.g. the full \"(defun ...)\" wrapper).~%"))
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
      (format s "      contents — fs-write-file is not a patching tool.~%"))
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
       (format s "     a stale REPL state cannot fake success.~%~%"))
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

(defun initial-user-prompt (config verify-result)
  "Return the first USER message that gives the LLM the project context
and the initial verification snapshot."
  (with-output-to-string (s)
    (format s "Project root: ~A~%" (run-config-project-root config))
    (format s "ASDF system: ~A~%" (run-config-system config))
    (format s "Test system: ~A~%" (run-config-test-system config))
    (format s "Issue: ~A~%~%" (run-config-issue config))
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
failed_tests entries when present (PRD §10.3 SUMMARIZE-TOOL-RESULT)."
  (with-output-to-string (s)
    (let ((passed (gethash "passed" result))
          (failed (gethash "failed" result))
          (failed-tests (gethash "failed_tests" result)))
      (format s "passed: ~A, failed: ~A~%"
              (or passed "?") (or failed "?"))
      (when (and failed-tests
                 (or (and (vectorp failed-tests) (plusp (length failed-tests)))
                     (and (listp failed-tests) failed-tests)))
        (format s "~A" (format-failed-tests failed-tests))))))

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

(defun summarize-tool-result (tool-name result)
  "Return a compact human-readable summary of the MCP tools/call RESULT
hash-table for TOOL-NAME (PRD §10.3 SUMMARIZE-TOOL-RESULT).

Specialized summarizers exist for the high-volume tools (run-tests,
repl-eval) and the read-only probes (code-find, code-describe,
inspect-object, lisp-read-file). Unknown tools fall through to a
generic content/isError dump."
  (cond
    ((null result) "(no result)")
    ((equal tool-name "run-tests") (summarize-run-tests result))
    ((equal tool-name "repl-eval") (summarize-repl-eval result))
    ((member tool-name
             '("code-find" "code-describe" "code-find-references"
               "inspect-object" "lisp-read-file" "clgrep-search")
             :test #'equal)
     (or (extract-content-text result) "(empty)"))
    (t (default-tool-result-summary result))))

(defun verify-event-payload (turn verify-result)
  "Return an alist describing VERIFY-RESULT for the JSONL transcript."
  `(("turn" . ,turn)
    ("status" . ,(string-downcase (symbol-name (verify-result-status verify-result))))
    ("passed" . ,(or (verify-result-passed verify-result) 0))
    ("failed" . ,(or (verify-result-failed verify-result) 0))))

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
                 ("summary" . ,(or (agent-action-summary action) ""))))))))

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
                        &key (clean-verify-p t))
  "Confirm a :PASSED outcome via CLEAN-VERIFY-TASK on a fresh worker.

When the clean reload also reports zero failures STATE's status stays
:PASSED. Otherwise the agent reports :DIRTY-ONLY so the caller knows the
incremental success did not survive a fresh image (PRD §8.9
REQ-VERIFY-002, REQ-VERIFY-003).

CLEAN-VERIFY-P NIL skips the pool-kill + reverify step, used by the
benchmark runner when the source system was registered via asdf:load-asd
into the current worker only and a worker reset would lose that binding."
  (cond
    ((not clean-verify-p)
     (finalize state :passed :verify incremental-verify :action action))
    (t
     (let ((clean (clean-verify-task mcp-client config)))
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
         (log-event logger :tool-result
                    `(("turn" . ,turn) ("tool" . ,tool)
                      ("is_error" . ,(and (gethash "isError" result) t))))
         (let ((next (append-message
                      messages "user"
                      (format nil "Tool ~A result:~%~A"
                              tool (summarize-tool-result tool result)))))
           (cond
             ((member tool +source-mutating-tools+ :test #'equal)
              (incf (agent-state-patch-attempts state))
              (cond
                ((gethash "isError" result)
                 (values next nil nil nil))
                (dry-run-p
                 (incf (agent-state-patch-count state))
                 (values next nil nil nil))
                (t
                 (incf (agent-state-patch-count state))
                 (when target
                   (let* ((after (%read-file-safely target))
                          (diff (%compute-unified-diff
                                 before after (namestring target))))
                     (log-event
                      logger :patch
                      `(("turn" . ,turn)
                        ("tool" . ,tool)
                        ("file" . ,(namestring target))
                        ("diff" . ,(or diff ""))))))
                 (let ((v (verify-task mcp-client config)))
                   (log-event logger :verify (verify-event-payload turn v))
                   (if (verify-result-success-p v)
                       (values next :passed v action)
                       (let* ((detail (verify-detail-prose v))
                              (msg (with-output-to-string (s)
                                     (format s "Verify after patch: ~A~%"
                                             (verify-summary v))
                                     (when detail (format s "~A" detail)))))
                         (values (append-message next "user" msg)
                                 nil nil nil)))))))
             (t (values next nil nil nil)))))))))

(defun step-turn (turn state config provider mcp-client policy logger messages
                  &key dry-run-p)
  "Run one turn of the agent loop.

Returns (values NEW-MESSAGES OUTCOME VERIFY ACTION). OUTCOME is NIL when
the loop should continue, otherwise a terminal status keyword
(:PASSED / :GIVE-UP)."
  (let* ((chat (complete-chat provider messages))
         (text (chat-response-content chat)))
    (incf (agent-state-token-total state)
          (or (chat-response-total-tokens chat) 0))
    (log-event logger :llm-response
               `(("turn" . ,turn)
                 ("content" . ,text)
                 ("tokens" . ,(or (chat-response-total-tokens chat) 0))))
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
                                 :dry-run-p dry-run-p)))))
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
         nil nil nil)))))

(defun run-agent (config provider mcp-client policy logger
                  &key (clean-verify-p t) dry-run-p)
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

Limits enforcement (PRD §8.4 REQ-AGENT-003): all seven RUN-LIMITS
slots are now checked at every turn boundary (max-turns / max-tool-calls
/ max-patches / max-read-files / max-repl-evals /
max-wall-clock-seconds / max-action-parse-errors). On exceeding any of
them STATE's STATUS becomes :LIMIT-EXHAUSTED and LIMIT-HIT names the
offending slot."
  (let ((state (make-instance 'agent-state)))
    (setf (agent-state-started-at state) (now))
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
                            :clean-verify-p clean-verify-p)
           logger)))
      (let ((messages (list (make-chat-message "system" (system-prompt policy))
                            (make-chat-message
                             "user" (initial-user-prompt config initial)))))
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
                                             :clean-verify-p clean-verify-p))
                           (:give-up
                            (finalize state :give-up :action action)))
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
