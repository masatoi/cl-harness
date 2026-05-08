# Planner Failure-Context Enrichment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Surface verify-task errors, agent-LLM-issued tool errors (last N=3), and active-failure-ledger entries to the replanner so transient Lisp-specific failures (EXPORT name-conflict, unbound variable in `repl-eval`, etc.) reach the planner instead of being collapsed to a 1-line generic status string.

**Architecture:** Add `last-tool-errors` ring (N=3) to `agent-state` populated only by LLM-issued tool calls in `step-turn` when `isError=true`. Rewrite `%failure-context` in orchestrator to read `final-verify.load-result`, `final-verify.test-result`, and the new ring, returning a multi-paragraph string. Extend the `:PLANNING` view's `make-context-view` branch to populate `:active-failures` (mirroring `:IMPLEMENTATION`) and add a `## Active failures` render block.

**Tech Stack:** SBCL + ASDF `:package-inferred-system`, alexandria, yason, rove. No new dependency. No public API change.

---

## Reference design

`docs/plans/2026-05-09-planner-failure-context-enrichment-design.md`. Decisions:

- (b'-β): verify-error + last N=3 tool-error ring + `:PLANNING` view active-failures
- (ii) entry shape: `(:tool-name :args-summary :error-text :turn)`
- (A) hybrid render: multi-paragraph string from `%failure-context` + dedicated `## Active failures` view block
- (P) populate trigger: agent-LLM-issued tool calls only

## Surface delta

| Path | Action |
|---|---|
| `src/agent.lisp` | + `last-tool-errors` slot (initform NIL), + `agent-state-last-tool-errors` accessor export, + `+tool-error-ring-size+` defparameter, + `record-tool-error` defun, + `%summarize-tool-args` defun, + populate hook in `handle-tool-call` after the existing `:tool-result` log |
| `src/orchestrator.lisp` | rewrite `%failure-context` to multi-paragraph; new imports for `verify-result-load` / `verify-result-test` / `agent-state-final-verify` / `agent-state-last-tool-errors` |
| `src/context-view.lisp` | populate `:active-failures` in `:planning` branch of `make-context-view`; add `## Active failures (test-level)` render block in the planning formatter |
| `tests/agent-test.lisp` | + 6 deftests + small helpers |
| `tests/orchestrator-test.lisp` | + 3 deftests |
| `tests/context-view-test.lisp` | + 1 deftest |

CI count: 397 → **407** (+10).

No `cl-harness.asd` change. No `src/main.lisp` change. No `cli.lisp` / `cli-main.lisp` / `tools/chaos-probe.lisp` change.

---

## Task 1: agent-state ring buffer + populate hook (TDD)

**Files:**
- Modify: `src/agent.lisp` — slot, defparameter, `record-tool-error`, `%summarize-tool-args`, populate hook in `handle-tool-call`, export `agent-state-last-tool-errors`.
- Modify: `tests/agent-test.lisp` — append 6 deftests + 1 helper.

### Step 1: Read the current agent.lisp shape

Use `lisp-read-file` with `name_pattern="^(handle-tool-call|step-turn|agent-state)$"` to confirm:

- `agent-state` defclass at line ~301
- `handle-tool-call` at line 917
- `is-error` / `error-text` already computed at lines 992-993
- `extract-content-text` helper at line 659

### Step 2: Append failing deftest helper to `tests/agent-test.lisp`

Append before the existing deftest block (after the existing `%error-tool-result` helper at line 121):

```lisp
;; --- failure-context-enrichment helpers ---------------------------

(defun %iserror-tool-result (text)
  "Build a hash-table mimicking an MCP tool-result with isError=true
and a single text content entry. Used by the new tool-error ring
populate tests."
  (alist-hash-table
   `(("isError" . t)
     ("content"
      . ,(vector
          (alist-hash-table
           `(("type" . "text") ("text" . ,text))
           :test 'equal))))
   :test 'equal))

(defun %fresh-agent-state ()
  "Construct a bare AGENT-STATE for ring-buffer tests."
  (make-instance 'cl-harness/src/agent::agent-state))
```

### Step 3: Append 6 failing deftests to `tests/agent-test.lisp`

```lisp
;; --- failure-context-enrichment: ring buffer ---------------------

(deftest record-tool-error-pushes-and-truncates
  (let ((state (%fresh-agent-state)))
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 1)" "err A" 1)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 2)" "err B" 2)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 3)" "err C" 3)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(foo 4)" "err D" 4)
    (let ((ring (cl-harness/src/agent:agent-state-last-tool-errors state)))
      (ok (= 3 (length ring)))
      (ok (string= "err D" (getf (first ring) :error-text))
          "head is most recent")
      (ok (string= "err B" (getf (third ring) :error-text))
          "oldest retained is the 2nd push (1st rolled off)"))))

(deftest summarize-tool-args-handles-known-tools
  (flet ((h (alist) (alist-hash-table alist :test 'equal)))
    (ok (search "(my-parser \"abc\")"
                (cl-harness/src/agent::%summarize-tool-args
                 "repl-eval"
                 (h '(("code" . "(my-parser \"abc\")"))))))
    (ok (search "defun fibonacci"
                (cl-harness/src/agent::%summarize-tool-args
                 "lisp-edit-form"
                 (h '(("form_type" . "defun")
                      ("form_name" . "fibonacci")
                      ("operation" . "replace"))))))
    (ok (string= "fib"
                 (cl-harness/src/agent::%summarize-tool-args
                  "load-system" (h '(("system" . "fib"))))))
    (ok (search "fib/tests"
                (cl-harness/src/agent::%summarize-tool-args
                 "run-tests" (h '(("system" . "fib/tests"))))))))

(deftest summarize-tool-args-falls-back-to-json-dump
  (let* ((args (alist-hash-table '(("foo" . "bar") ("n" . 42))
                                 :test 'equal))
         (out (cl-harness/src/agent::%summarize-tool-args
               "unknown-tool" args)))
    (ok (search "foo" out))
    (ok (<= (length out) 200))))

(deftest summarize-tool-args-flattens-newlines
  (let* ((args (alist-hash-table
                '(("code" . "(progn
  (foo)
  (bar))"))
                :test 'equal))
         (out (cl-harness/src/agent::%summarize-tool-args
               "repl-eval" args)))
    (ok (not (find #\Newline out)) "no embedded newlines")
    (ok (search "(progn" out))))

(deftest step-turn-records-tool-error-when-iserror-true
  (let ((state (%fresh-agent-state)))
    (cl-harness/src/agent::%maybe-record-tool-error
     state "repl-eval"
     (alist-hash-table '(("code" . "(boom)")) :test 'equal)
     (%iserror-tool-result "The variable INPUT is unbound.")
     7)
    (let ((ring (cl-harness/src/agent:agent-state-last-tool-errors state)))
      (ok (= 1 (length ring)))
      (ok (string= "repl-eval" (getf (first ring) :tool-name)))
      (ok (search "INPUT is unbound" (getf (first ring) :error-text)))
      (ok (= 7 (getf (first ring) :turn))))))

(deftest step-turn-skips-recording-on-success
  (let ((state (%fresh-agent-state))
        (ok-result (alist-hash-table
                    `(("isError" . :false)
                      ("content" . ,(vector
                                     (alist-hash-table
                                      '(("type" . "text") ("text" . "ok"))
                                      :test 'equal))))
                    :test 'equal)))
    (cl-harness/src/agent::%maybe-record-tool-error
     state "repl-eval"
     (alist-hash-table '(("code" . "(:ok)")) :test 'equal)
     ok-result
     1)
    (ok (null (cl-harness/src/agent:agent-state-last-tool-errors state)))))
```

### Step 4: Run tests — expect FAIL

Run via `run-tests` MCP tool: `{"system": "cl-harness/tests"}`
Expected: 6 new tests fail with "Symbol AGENT-STATE-LAST-TOOL-ERRORS not external" / "RECORD-TOOL-ERROR is undefined" / etc. The existing 397 must still pass.

### Step 5: Add `last-tool-errors` slot + reader export

Edit `src/agent.lisp` `defclass agent-state` (around line 301-353). Append a new slot before `(:documentation ...)`:

```lisp
(last-tool-errors :initform nil
                  :accessor agent-state-last-tool-errors
                  :documentation "Ring of up to +TOOL-ERROR-RING-SIZE+
plist entries for the most-recent agent-LLM-issued tool calls that
returned isError=true. Each entry: (:TOOL-NAME string :ARGS-SUMMARY
string :ERROR-TEXT string :TURN integer). Head is most recent.
Populated only by RECORD-TOOL-ERROR; per-step naturally because
agent-state is created fresh per RUN-AGENT.")
```

In the `defpackage` `:export` list, add `#:agent-state-last-tool-errors` near the existing `#:agent-state-reason`.

### Step 6: Add `+tool-error-ring-size+` and `record-tool-error`

Add near the top of `src/agent.lisp`'s definition section (after the package definition and other defparameters; around line 200 area, or pick a sensible place near other `+...+` defparameters):

```lisp
(defparameter +tool-error-ring-size+ 3
  "Maximum number of recent agent-LLM-issued tool errors retained on
AGENT-STATE.LAST-TOOL-ERRORS. Internal — not exported.")

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
```

### Step 7: Add `%summarize-tool-args` with dispatch table

Add right after `record-tool-error`:

```lisp
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
```

### Step 8: Add `%maybe-record-tool-error` glue + populate hook

Add `%maybe-record-tool-error` right after `%summarize-tool-args`:

```lisp
(defun %maybe-record-tool-error (state tool-name arguments result turn)
  "When RESULT carries isError=true, record a tool-error entry on
STATE. Internal helper called from HANDLE-TOOL-CALL only on
LLM-issued tool calls. ARGUMENTS may be NIL or a hash-table."
  (when (and (hash-table-p result) (gethash "isError" result))
    (let ((args (or arguments (make-hash-table :test 'equal))))
      (record-tool-error
       state
       tool-name
       (%summarize-tool-args tool-name args)
       (%trunc-200 (extract-content-text result))
       turn))))
```

Wire it into `handle-tool-call` (around line 992-998 — after the existing `is-error`/`error-text` `let*` and `:tool-result` log). Insert a new line:

```lisp
         (let* ((is-error (and (gethash "isError" result) t))
                (error-text (and is-error (extract-content-text result))))
           (log-event logger :tool-result
                      `(("turn" . ,turn) ("tool" . ,tool)
                        ("is_error" . ,is-error)
                        ,@(when (and error-text (plusp (length error-text)))
                            `(("error_text" . ,error-text)))))
           ;; NEW — populate the per-step tool-error ring on isError=true.
           ;; Q4 (P): only LLM-issued tool calls land here (HANDLE-TOOL-CALL
           ;; is on that path); harness-internal calls (verify-task setup,
           ;; pool-kill-worker) do not pass through this function.
           (%maybe-record-tool-error
            state tool
            (or (agent-action-arguments action) (make-hash-table :test 'equal))
            result turn))
```

(Note: the closing `)` of the `let*` was originally followed by `(let ((next ...)) ...)`. The new `%maybe-record-tool-error` call goes between them, inside the same outer scope — match the existing `let*` body structure. Read the file before editing to confirm the exact bracketing.)

### Step 9: Run tests — expect PASS

Run via `run-tests` MCP tool: `{"system": "cl-harness/tests"}`
Expected: **403 / 0** (397 baseline + 6 new). All 6 new deftests green.

### Step 10: mallet

```bash
mallet src/agent.lisp tests/agent-test.lisp
```

Expected: `✓ No problems found.`

### Step 11: Self-review

- New slot defaults to NIL (no allocation cost when ring stays empty).
- `+tool-error-ring-size+` is internal (not exported); name follows the project's existing constant convention (`+...+`).
- `%summarize-tool-args` dispatch is order-independent — each branch is a pure equality check on tool-name string.
- `%trunc-200` flattens newlines BEFORE truncating, so a multi-line `code` value renders as one line within 200 chars.
- `%maybe-record-tool-error` is the only new code path that touches the ring outside of `record-tool-error` itself; called from exactly one place in `handle-tool-call`.
- No `:local-nicknames`. No `src/main.lisp` re-export added. No new ASDF dependency.
- `agent-state-last-tool-errors` is exported but not re-exported from the `cl-harness` facade — internal-feeling API, only consumed by `%failure-context` in the next task.

### Step 12: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "feat: agent-state last-tool-errors ring (N=3) populated by step-turn on isError=true"
```

---

## Task 2: %failure-context multi-paragraph rewrite (TDD)

**Files:**
- Modify: `src/orchestrator.lisp` — rewrite `%failure-context`, add imports.
- Modify: `tests/orchestrator-test.lisp` — append 3 deftests.

### Step 1: Read the current orchestrator.lisp shape

Use `lisp-read-file` with `name_pattern="^%failure-context$"` to confirm the function is at lines 659-668. Also read the package's `:import-from` block to know which imports to add.

### Step 2: Append failing deftest helper to `tests/orchestrator-test.lisp`

Append near the existing helpers (find a spot after the file's prelude before the first deftest):

```lisp
;; --- failure-context-enrichment helpers --------------------------

(defun %make-stub-step-result-with-state (&key (step-index 0)
                                               (test-name "demo")
                                               (status :give-up)
                                               agent-state)
  "Build a develop-step-result whose run-agent-state slot points to
the supplied AGENT-STATE. Used to drive the new %FAILURE-CONTEXT
multi-paragraph branches without spinning up a real run-agent."
  (make-instance 'cl-harness/src/step-result:develop-step-result
                 :step-index step-index
                 :test-name test-name
                 :status status
                 :run-agent-state agent-state))
```

### Step 3: Append 3 failing deftests

```lisp
(deftest failure-context-omits-empty-sections
  ;; Stub agent-state with NIL final-verify and empty ring; output
  ;; should be the single-paragraph form (no subheaders).
  (let* ((state (make-instance 'cl-harness/src/agent::agent-state))
         (sr (%make-stub-step-result-with-state
              :step-index 1 :test-name "foo" :status :give-up
              :agent-state state))
         (out (cl-harness/src/orchestrator::%failure-context sr)))
    (ok (search "step 1" out))
    (ok (search "foo" out))
    (ok (search ":give-up" out))
    (ok (not (search "### " out))
        "no subheaders emitted when no enrichment data available")))

(deftest failure-context-includes-tool-errors-when-ring-non-empty
  ;; Push 2 tool-error entries onto agent-state's ring; verify both
  ;; show up in the rendered string in newest-first order.
  (let ((state (make-instance 'cl-harness/src/agent::agent-state)))
    (cl-harness/src/agent::record-tool-error
     state "lisp-edit-form" "defun foo (replace)" "form-name not unique" 5)
    (cl-harness/src/agent::record-tool-error
     state "repl-eval" "(boom)" "INPUT unbound" 6)
    (let* ((sr (%make-stub-step-result-with-state
                :step-index 0 :test-name "x" :status :give-up
                :agent-state state))
           (out (cl-harness/src/orchestrator::%failure-context sr)))
      (ok (search "### Recent tool errors" out))
      (ok (search "repl-eval" out))
      (ok (search "INPUT unbound" out))
      (ok (search "lisp-edit-form" out))
      (ok (search "form-name not unique" out))
      (ok (< (search "INPUT unbound" out)
             (search "form-name not unique" out))
          "newest entry rendered first"))))

(deftest failure-context-includes-load-error-when-final-verify-load-failed
  ;; Stub final-verify slot with a verify-result whose load-result
  ;; carries an EXPORT name-conflict isError=true text.
  (let* ((load-fail
          (alist-hash-table
           `(("isError" . t)
             ("content"
              . ,(vector
                  (alist-hash-table
                   '(("type" . "text")
                     ("text"
                      . "EXPORT FIB::FIBONACCI causes name-conflicts in #<PACKAGE \"FIB/TESTS/MAIN\"> between the following symbols: FIB::FIBONACCI, FIB/TESTS/MAIN::FIBONACCI"))
                   :test 'equal))))
           :test 'equal))
         (vr (make-instance 'cl-harness/src/verify:verify-result
                            :status :load-failed
                            :load-result load-fail))
         (state (make-instance 'cl-harness/src/agent::agent-state)))
    (setf (cl-harness/src/agent:agent-state-final-verify state) vr)
    (let* ((sr (%make-stub-step-result-with-state
                :step-index 0 :test-name "y" :status :give-up
                :agent-state state))
           (out (cl-harness/src/orchestrator::%failure-context sr)))
      (ok (search "### Last verify error (load-system)" out))
      (ok (search "EXPORT FIB::FIBONACCI" out))
      (ok (search "name-conflicts" out)))))
```

### Step 4: Run tests — expect FAIL

Run: `{"system": "cl-harness/tests"}`
Expected: 3 new tests fail with mismatch in `search` calls (current `%failure-context` always returns the single-line form).

### Step 5: Add imports to `src/orchestrator.lisp`

In the `:import-from #:cl-harness/src/agent` block, add `agent-state-final-verify` and `agent-state-last-tool-errors`. In the `:import-from #:cl-harness/src/verify` block (add the block if it doesn't exist), import `verify-result-load` and `verify-result-test`. Read the current `defpackage` block to find the exact insertion points.

### Step 6: Helpers for the new `%failure-context`

Add right above the existing `%failure-context` (around line 659):

```lisp
(defun %extract-isError-text (result)
  "Return the first content[].text from RESULT (a tool-result hash)
truncated to 800 chars; NIL when RESULT is NIL or has no text. Used
to extract the user-visible error text from a verify-task load-result
or similar."
  (when (hash-table-p result)
    (let ((content (gethash "content" result)))
      (when (and content (vectorp content) (plusp (length content)))
        (let ((text (gethash "text" (aref content 0))))
          (when (stringp text)
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
```

### Step 7: Rewrite `%failure-context`

Replace the existing 8-line body with the multi-paragraph version:

```lisp
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
      (format s "step ~A (test_name=~A) terminated with status ~A."
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
```

Note: the function depends on the symbol `agent-state` being importable for `typep`. If the existing `:import-from #:cl-harness/src/agent` block does not yet name the class symbol, add `#:agent-state` to it.

### Step 8: Run tests — expect PASS

Run: `{"system": "cl-harness/tests"}`
Expected: **406 / 0** (397 baseline + 6 from Task 1 + 3 from Task 2).

### Step 9: mallet

```bash
mallet src/orchestrator.lisp tests/orchestrator-test.lisp
```

Expected: `✓ No problems found.`

### Step 10: Self-review

- The multi-paragraph string is built with `with-output-to-string`; each `format` runs only when its data source is non-empty, so no empty subheaders are emitted.
- `%extract-isError-text` returns NIL not "" when the result hash is missing or empty — the caller's `(when load-text ...)` correctly omits the section.
- `%render-failed-tests-summary` caps at 3 entries (matching `:exploration` view's failure-record cap convention).
- 800-char cap on load-error text balances actionable signal vs context budget; one long stack frame fits, multiple won't.
- `typep ... agent-state` guards against test stubs that pass plain hash-tables instead of a real `agent-state` (some legacy tests do this — confirmed by reading `tests/orchestrator-test.lisp` for stub usage).
- No regression in `%symbol-status` semantics or `develop-step-result-*` slot reads.

### Step 11: Commit

```bash
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "feat: %failure-context multi-paragraph (verify-error + tool-error ring)"
```

---

## Task 3: :PLANNING view active-failures + lint + docs + final review

**Files:**
- Modify: `src/context-view.lisp` — populate `:active-failures` in `:planning` branch + add `## Active failures` render block.
- Modify: `tests/context-view-test.lisp` — append 1 deftest.
- Modify: `docs/context-management.md` — §14 footnote.

### Step 1: Append failing deftest

Append to `tests/context-view-test.lisp`:

```lisp
(deftest planning-view-renders-active-failures
  (let* ((state (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "p" :test-system "p/tests"))
         (rec (cl-harness/src/failure-ledger:make-failure-record
               :test-name "p/tests::demo-fails"
               :description "expected 1 got 2"
               :reason "assertion failed"
               :source-file "src/main.lisp")))
    (cl-harness/src/state:develop-state-record-failure state rec)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  state :phase :planning))
           (out (cl-harness/src/context-view:context-view->string view)))
      (ok (search "## Active failures" out))
      (ok (search "demo-fails" out))
      (ok (search "expected 1 got 2" out)))))
```

(Replace the make-failure-record kwargs with the actual ones — read `src/failure-ledger.lisp` to confirm the slot names; some are likely positional or constructor args. Adjust if needed.)

### Step 2: Run tests — expect FAIL

Expected: deftest fails because `:planning` view does not currently populate or render `active-failures`.

### Step 3: Populate `active-failures` in `:planning` branch

In `src/context-view.lisp` `make-context-view` `:planning` branch (around line 288-304), add `:active-failures (%active-failures state)` to the `make-instance` form. Mirror the `:implementation` branch (line 327).

### Step 4: Add the render block to the planning formatter

Find the planning render function (the body that emits `## Goal`, `## Prior plan`, `## Prior failure context` etc., around lines 360-400). Right after the existing failure-context section (line 384), insert:

```lisp
    (let ((failures (context-view-active-failures view)))
      (when failures
        (format s "~%## Active failures (test-level)~%")
        (dolist (rec failures)
          (format s "- ~A: ~A~@[~%  reason: ~A~]~%"
                  (failure-record-test-name rec)
                  (failure-record-description rec)
                  (failure-record-reason rec)))))
```

The needed imports (`failure-record-test-name` etc.) are already in the package — confirmed by lines 64-67 of `context-view.lisp`.

### Step 5: Run tests — expect PASS

Run: `{"system": "cl-harness/tests"}`
Expected: **407 / 0** (397 baseline + 10 new).

### Step 6: mallet

```bash
mallet src/context-view.lisp tests/context-view-test.lisp
```

Expected: `✓ No problems found.`

### Step 7: Force-compile sweep

```bash
cd /tmp && timeout 60 sbcl --noinform --non-interactive \
  --eval '(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness.asd")' \
  --eval '(asdf:compile-system :cl-harness :force t)' \
  --eval '(quit)' 2>&1 | grep -E "WARNING|ERROR" | head
```

Expected: empty (no new warnings beyond the pre-existing harmless ASDF `perform` redefinition).

### Step 8: Append §14 footnote to `docs/context-management.md`

After the "LLM retry policy follow-up" paragraph (line 975 area), append:

```markdown
Planner failure-context enrichment follow-up (landed 2026-05-09):
fib プロジェクトの EXPORT name-conflict が :STUCK / :NO-PROGRESS で
固まる事例から浮上した v0.5 の replan-feedback 漏れを塞いだ。
`%failure-context` が `agent-state-final-verify` の load-system error /
run-tests failures、および新設の `agent-state-last-tool-errors` ring
(N=3、agent-LLM 起源の isError=true 結果のみ) を多段落形式で planner に
届けるようになった。`:PLANNING` view も `## Active failures` ブロックを
レンダリングし、`:IMPLEMENTATION` view との renderer 共有を再活用する。
+10 deftests (397 → 407)。当初設計 `(c'-β)` の prompt-side recovery
recipe は別 phase に温存。
```

### Step 9: Commit docs change

```bash
git add docs/context-management.md
git commit -m "docs: §14 footnote for planner failure-context enrichment"
```

### Step 10: Final review (handled by controller)

The controller dispatches `superpowers:code-reviewer` over the branch diff. Skip in this task.

### Step 11: Merge (handled by controller)

`superpowers:finishing-a-development-branch` → `--no-ff` merge to main. Skip in this task.

---

## Verification checklist

- [ ] `agent-state-last-tool-errors` slot exists, defaults NIL, exported.
- [ ] `+tool-error-ring-size+` defparameter = 3, internal.
- [ ] `record-tool-error` pushes to head, truncates at +1 over capacity.
- [ ] `%summarize-tool-args` handles repl-eval / lisp-edit-form / lisp-patch-form / run-tests / load-system / fs-write-file / lisp-read-file / code-find / code-describe / code-find-references; falls back to JSON dump for unknown tools.
- [ ] `%trunc-200` flattens newlines and caps at 200 chars.
- [ ] `handle-tool-call` calls `%maybe-record-tool-error` after the tool-result log; harness-internal calls (verify-task) bypass this path.
- [ ] `%failure-context` returns multi-paragraph string with subheaders only when underlying data is non-empty.
- [ ] `:PLANNING` view populates `:active-failures` and renders `## Active failures (test-level)` block.
- [ ] CI count grows by 10 (397 → 407).
- [ ] mallet clean across `src/agent.lisp`, `src/orchestrator.lisp`, `src/context-view.lisp`, `tests/agent-test.lisp`, `tests/orchestrator-test.lisp`, `tests/context-view-test.lisp`.
- [ ] Force-compile clean.
- [ ] No regression in pre-existing 397 deftests.
- [ ] §14 docs updated.
- [ ] No public-API change: `cl-harness:fix` / `bench` / `develop` kwargs unchanged; `cli.lisp`, `cli-main.lisp`, `tools/chaos-probe.lisp`, `roswell/cl-harness.ros`, `cl-harness.asd` untouched.

---

## Acceptance criteria

The phase is complete when:

1. 6 new deftests in `tests/agent-test.lisp` pass (ring + summarizer + populate hook).
2. 3 new deftests in `tests/orchestrator-test.lisp` pass (multi-paragraph rendering).
3. 1 new deftest in `tests/context-view-test.lisp` passes (`:PLANNING` active-failures block).
4. CI count 397 → 407.
5. The replanner now sees verify-load errors, run-tests failures, last 3 LLM-issued tool errors, and active-failure-ledger entries when each is non-empty.
6. mallet and force-compile clean across all touched files.
7. `docs/context-management.md` §14 trailing prose mentions the follow-up.

## Out of scope (deferred)

- Planner system prompt: Lisp-typical recovery recipes (`(c'-β)`).
- Agent-side automatic recovery for known transient runtime errors.
- Tool-error ledger on `develop-state` (replacing the per-step ring).
- repl-eval stack-frame structured parsing.
- Positive-context "what worked" ring.
- Non-test-level failures in `failure-ledger`.
