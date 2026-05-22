# postmortem-logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three JSONL transcript gaps that make postmortem analysis of failure sessions incomplete — per-test verify failures, successful tool-result content, and the missing `:llm-request` event paired with `:llm-response`.

**Architecture:** Three additive extensions to `src/agent.lisp`'s existing event emit sites, plus one new `run-config` slot for the opt-in flag, plus CLI plumbing for `--log-llm-requests`. No new files. `src/log.lisp` is untouched (the existing `log-event` is sufficient).

**Tech Stack:** SBCL + ASDF, `yason` for JSON encoding (already a dep), `rove` for tests. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-23-postmortem-logging-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/agent.lisp` | Modify | New `%verify-failed-tests-payload` helper, extend `verify-event-payload`, extend `:tool-result` emit, emit new `:llm-request` event guarded by config flag |
| `src/config.lisp` | Modify | Add `log-llm-requests-p` slot to `run-config` (default `nil`) + reader export |
| `src/main.lisp` | Modify | Re-export the new `run-config-log-llm-requests-p` reader |
| `src/cli.lisp` | Modify | Add `:log-llm-requests` kwarg to `fix` / `bench` / `develop` and thread to `make-run-config` |
| `src/cli-main.lisp` | Modify | Add `--log-llm-requests` flag to `fix-options` / `bench-options` / `develop-options`, getopt in handlers, emit one-shot stderr warning when active |
| `tests/agent-test.lisp` | Modify | 8 stub-driven deftests covering the new schemas + opt-in surface |
| `README.md` | Modify | Note the new transcript fields + `--log-llm-requests` flag in the develop / fix / bench sections |
| `docs/cl-harness-prd.md` | Modify | Update §8.10 REQ-LOG-001 with the new fields and the `:llm-request` event |

---

## Task 1: `%verify-failed-tests-payload` helper

**Files:**
- Modify: `src/agent.lisp`
- Test: `tests/agent-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/agent-test.lisp` (before the last `)` if any, otherwise as a new top-level deftest):

```lisp
(deftest verify-failed-tests-payload-extraction
  (testing "returns NIL when verify-result has no failed tests"
    (let ((vr (make-instance 'cl-harness/src/verify:verify-result
                             :status :passed
                             :passed 3
                             :failed 0
                             :test nil)))
      (ok (null (cl-harness/src/agent::%verify-failed-tests-payload vr)))))
  (testing "returns NIL when test field present but failed_tests is empty"
    (let* ((tr (alexandria:plist-hash-table
                `("failed_tests" ,(vector))
                :test 'equal))
           (vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :passed
                              :passed 3
                              :failed 0
                              :test tr)))
      (ok (null (cl-harness/src/agent::%verify-failed-tests-payload vr)))))
  (testing "returns the failed_tests array verbatim when present"
    (let* ((ft (alexandria:plist-hash-table
                `("test_name" "demo-test"
                  "description" "demo description"
                  "reason" "got 3 instead of \"Fizz\"")
                :test 'equal))
           (tr (alexandria:plist-hash-table
                `("failed_tests" ,(vector ft))
                :test 'equal))
           (vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :test-failed
                              :passed 0
                              :failed 1
                              :test tr))
           (payload (cl-harness/src/agent::%verify-failed-tests-payload vr)))
      (ok payload)
      (ok (= 1 (length payload)))
      (ok (equal "demo-test" (gethash "test_name" (elt payload 0)))))))
```

- [ ] **Step 2: Run test to verify it fails**

Via cl-mcp:
```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::verify-failed-tests-payload-extraction"
```

Expected: failure with "undefined function `%verify-failed-tests-payload`".

- [ ] **Step 3: Implement helper**

Insert into `src/agent.lisp` immediately BEFORE `verify-event-payload` (currently at L907). Use `mcp__cl-mcp__lisp-edit-form` with `operation=insert_before` on `verify-event-payload`:

```lisp
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
```

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::verify-failed-tests-payload-extraction"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes (3 testing blocks); full suite 445 (was 444 + 1).

- [ ] **Step 5: Commit**

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "logging: %verify-failed-tests-payload helper for G1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Extend `verify-event-payload` with `failed_tests`

**Files:**
- Modify: `src/agent.lisp` (`verify-event-payload` at L907-912)
- Test: `tests/agent-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/agent-test.lisp`:

```lisp
(deftest verify-event-payload-includes-failed-tests
  (testing "passed verify has no failed_tests key"
    (let* ((vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :passed
                              :passed 3
                              :failed 0
                              :test nil))
           (payload (cl-harness/src/agent:verify-event-payload 6 vr)))
      (ok (not (assoc "failed_tests" payload :test #'equal)))))
  (testing "failed verify includes failed_tests array"
    (let* ((ft (alexandria:plist-hash-table
                `("test_name" "t1" "reason" "boom")
                :test 'equal))
           (tr (alexandria:plist-hash-table
                `("failed_tests" ,(vector ft))
                :test 'equal))
           (vr (make-instance 'cl-harness/src/verify:verify-result
                              :status :test-failed
                              :passed 0
                              :failed 1
                              :test tr))
           (payload (cl-harness/src/agent:verify-event-payload 6 vr))
           (entry (assoc "failed_tests" payload :test #'equal)))
      (ok entry)
      (ok (= 1 (length (cdr entry))))
      (ok (equal "t1" (gethash "test_name" (elt (cdr entry) 0)))))))
```

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::verify-event-payload-includes-failed-tests"
```

Expected: second testing block fails — `failed_tests` key not present in payload.

- [ ] **Step 3: Extend `verify-event-payload`**

Use `mcp__cl-mcp__lisp-edit-form` with `operation=replace` on `verify-event-payload`. New body:

```lisp
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
```

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::verify-event-payload-includes-failed-tests"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes; full suite 446 (was 445 + 1).

- [ ] **Step 5: Commit**

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "logging: verify event carries failed_tests array (G1)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Extend `:tool-result` event with `content_summary`

**Files:**
- Modify: `src/agent.lisp` (tool-result log-event call around L1096-1100)
- Test: `tests/agent-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/agent-test.lisp`:

```lisp
(defun %capture-jsonl-events (thunk)
  "Run THUNK with a fresh logger pointing to a tmp JSONL file and
return the parsed events as a list of hash-tables."
  (let* ((path (merge-pathnames
                (format nil "agent-log-capture-~A.jsonl"
                        (get-internal-real-time))
                (uiop:temporary-directory)))
         (logger (cl-harness/src/log:open-run-logger path))
         (events (list)))
    (unwind-protect
         (progn
           (funcall thunk logger)
           (cl-harness/src/log:close-run-logger logger)
           (with-open-file (in path)
             (loop for line = (read-line in nil nil)
                   while line
                   do (push (yason:parse line) events))))
      (when (probe-file path) (delete-file path)))
    (nreverse events)))

(deftest tool-result-event-content-summary
  (testing "successful tool-result has content_summary field"
    (let* ((result (alexandria:plist-hash-table
                    `("isError" nil
                      "content" ,(vector
                                  (alexandria:plist-hash-table
                                   `("type" "text" "text" "READ-OK-CONTENT")
                                   :test 'equal)))
                    :test 'equal))
           (events
             (%capture-jsonl-events
              (lambda (logger)
                ;; Mimic the agent's emit path: build payload as agent.lisp
                ;; does post-Task-3 and log it.
                (let* ((is-error (and (gethash "isError" result) t))
                       (summary (cl-harness/src/agent:summarize-tool-result
                                 "lisp-read-file" result))
                       (payload `(("turn" . 2)
                                  ("tool" . "lisp-read-file")
                                  ("is_error" . ,is-error)
                                  ,@(unless is-error
                                      `(("content_summary" . ,summary))))))
                  (cl-harness/src/log:log-event
                   logger :tool-result payload)))))
           (event (first events)))
      (ok (= 1 (length events)))
      (ok (equal "tool-result" (gethash "type" event)))
      (ok (gethash "content_summary" event))
      (ok (search "READ-OK-CONTENT" (gethash "content_summary" event)))))
  (testing "error tool-result has error_text but no content_summary"
    (let* ((events
             (%capture-jsonl-events
              (lambda (logger)
                (cl-harness/src/log:log-event
                 logger :tool-result
                 `(("turn" . 4)
                   ("tool" . "lisp-patch-form")
                   ("is_error" . t)
                   ("error_text" . "BOOM")))))) ; emit what agent does on error
           (event (first events)))
      (ok (equal "lisp-patch-form" (gethash "tool" event)))
      (ok (equal t (gethash "is_error" event)))
      (ok (equal "BOOM" (gethash "error_text" event)))
      (ok (null (gethash "content_summary" event))))))
```

This test is a SCHEMA test that exercises the JSONL round-trip — it does not yet exercise the production emit site. Task 3's purpose is to UPDATE the production site so it emits the new field. The test asserts the desired shape; we'll verify the production site emits this shape by running the bench in Task 9.

- [ ] **Step 2: Run test to verify it passes (the schema is achievable already, but the production emit site doesn't use it yet — Step 3 fixes that)**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::tool-result-event-content-summary"
```

Expected: PASS already, because the test directly builds the desired payload — this confirms the SHAPE is achievable. Next we wire the production emit site.

- [ ] **Step 3: Update the production tool-result emit**

In `src/agent.lisp`, find the `(log-event logger :tool-result ...)` block currently at L1096-1100. Use `mcp__cl-mcp__lisp-edit-form` to edit the enclosing function (or `lisp-patch-form` for a surgical change). The current text is:

```lisp
           (log-event logger :tool-result
                      `(("turn" . ,turn) ("tool" . ,tool)
                        ("is_error" . ,is-error)
                        ,@(when (and error-text (plusp (length error-text)))
                            `(("error_text" . ,error-text)))))
```

Replace with:

```lisp
           (let ((tool-summary (when (not is-error)
                                 (summarize-tool-result tool result))))
             (log-event logger :tool-result
                        `(("turn" . ,turn) ("tool" . ,tool)
                          ("is_error" . ,is-error)
                          ,@(when (and error-text (plusp (length error-text)))
                              `(("error_text" . ,error-text)))
                          ,@(when (and tool-summary (plusp (length tool-summary)))
                              `(("content_summary" . ,tool-summary))))))
```

Note: the next line uses `(summarize-tool-result tool result)` again for the message append (L1112). We can leave it as-is — `summarize-tool-result` is idempotent and inexpensive. Optionally hoist the binding above both call sites to compute once, but that's a follow-up optimization, not part of this task's scope.

- [ ] **Step 4: Run test to verify it still passes + full suite**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::tool-result-event-content-summary"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 447 passed (was 446 + 1).

- [ ] **Step 5: Commit**

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "logging: tool-result event carries content_summary on success (G2)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Add `log-llm-requests-p` slot to `run-config`

**Files:**
- Modify: `src/config.lisp` (defclass run-config L69-78, add reader export at top)
- Modify: `src/main.lisp` (re-export the new reader)
- Test: `tests/main-test.lisp` or `tests/agent-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/agent-test.lisp`:

```lisp
(deftest run-config-log-llm-requests-p-slot
  (testing "default initform is NIL"
    (let ((c (cl-harness/src/config:make-run-config
              :project-root "/tmp/x" :system "demo"
              :test-system "demo/tests" :issue "x"
              :condition :generic-mcp)))
      (ok (null (cl-harness/src/config:run-config-log-llm-requests-p c)))))
  (testing "kwarg lets caller opt in"
    (let ((c (cl-harness/src/config:make-run-config
              :project-root "/tmp/x" :system "demo"
              :test-system "demo/tests" :issue "x"
              :condition :generic-mcp
              :log-llm-requests t)))
      (ok (eq t (cl-harness/src/config:run-config-log-llm-requests-p c))))))
```

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::run-config-log-llm-requests-p-slot"
```

Expected: failure — `run-config-log-llm-requests-p` undefined.

- [ ] **Step 3: Add slot to `run-config` defclass**

In `src/config.lisp`, locate the `(defclass run-config () ...)` at L69-78. Use `mcp__cl-mcp__lisp-edit-form operation=replace` to add the new slot:

```lisp
(defclass run-config ()
  ((project-root :initarg :project-root :reader run-config-project-root)
   (system :initarg :system :reader run-config-system)
   (test-system :initarg :test-system :reader run-config-test-system)
   (issue :initarg :issue :reader run-config-issue)
   (condition :initarg :condition :reader run-config-condition)
   (limits :initarg :limits :reader run-config-limits)
   (log-llm-requests-p :initarg :log-llm-requests
                       :initform nil
                       :reader run-config-log-llm-requests-p
                       :documentation "When true, the agent loop emits a
:llm-request event before each COMPLETE-CHAT call, recording the full
chat history. Opt-in because the payload may contain sensitive context.
Default NIL."))
  (:documentation
   "Inputs to one cl-harness fix invocation. CONDITION is one of
:FILE-ONLY, :GENERIC-MCP, or :RUNTIME-NATIVE (PRD §8.5)."))
```

- [ ] **Step 4: Export the reader from `src/config.lisp`**

In the same file, find the `:export` block of the defpackage (top of file around L13-25). Add `#:run-config-log-llm-requests-p` to it. Use `mcp__cl-mcp__lisp-patch-form` if a surgical edit suffices, or `lisp-edit-form` to rewrite the defpackage.

- [ ] **Step 5: Verify `make-run-config` accepts the new kwarg**

`make-run-config` is the helper that constructs run-config. Check its source via `mcp__cl-mcp__lisp-read-file` with `name_pattern="^make-run-config$"`. If `make-run-config` uses `&key` and `&allow-other-keys`, the new kwarg flows through automatically. If it explicitly enumerates kwargs, add `(log-llm-requests nil)` to its `&key` list and pass to `make-instance` via `:log-llm-requests log-llm-requests`.

- [ ] **Step 6: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::run-config-log-llm-requests-p-slot"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes; full suite 448 (was 447 + 1).

- [ ] **Step 7: Re-export from facade**

In `src/main.lisp`, find the `:import-from #:cl-harness/src/config` clause at L12-14 (lists `run-config` / `make-run-config`). Add `#:run-config-log-llm-requests-p` to the import list and to the `:export` list further down.

- [ ] **Step 8: Verify reload + test**

```
mcp__cl-mcp__load-system with system="cl-harness", force=true
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: still 448 passed.

- [ ] **Step 9: Commit**

```bash
git add src/config.lisp src/main.lisp tests/agent-test.lisp
git commit -m "logging: run-config log-llm-requests-p slot + facade export

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Emit `:llm-request` event when opted in

**Files:**
- Modify: `src/agent.lisp` (around L1244-1255 where `complete-chat` is called)
- Test: `tests/agent-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/agent-test.lisp`. This test stubs `complete-chat` via a fake provider so no LLM is contacted:

```lisp
(defclass %stub-provider () ())

(defmethod cl-harness:complete-chat ((p %stub-provider) messages
                                     &key &allow-other-keys)
  (declare (ignore messages))
  (make-instance 'cl-harness:chat-response
                 :content "{\"type\":\"finish\",\"status\":\"give-up\",\"summary\":\"stub\"}"
                 :total-tokens 1))

(deftest llm-request-event-emit-and-suppress
  (testing "opt-in true emits :llm-request before :llm-response"
    (let* ((messages (list (cl-harness:make-chat-message "system" "sys")
                           (cl-harness:make-chat-message "user" "hello")))
           (config (cl-harness/src/config:make-run-config
                    :project-root "/tmp/x" :system "demo"
                    :test-system "demo/tests" :issue "x"
                    :condition :generic-mcp
                    :log-llm-requests t))
           (state (make-instance 'cl-harness/src/agent:agent-state))
           (provider (make-instance '%stub-provider))
           (events (%capture-jsonl-events
                    (lambda (logger)
                      (cl-harness/src/agent::%complete-chat-with-logging
                       provider messages config state logger 1)))))
      (let ((types (mapcar (lambda (e) (gethash "type" e)) events)))
        (ok (member "llm-request" types :test #'equal))
        (ok (member "llm-response" types :test #'equal))
        ;; ordering: llm-request fires before llm-response
        (let ((req-pos (position "llm-request" types :test #'equal))
              (resp-pos (position "llm-response" types :test #'equal)))
          (ok (< req-pos resp-pos))))))
  (testing "opt-in false suppresses :llm-request"
    (let* ((messages (list (cl-harness:make-chat-message "system" "sys")
                           (cl-harness:make-chat-message "user" "hello")))
           (config (cl-harness/src/config:make-run-config
                    :project-root "/tmp/x" :system "demo"
                    :test-system "demo/tests" :issue "x"
                    :condition :generic-mcp))
           (state (make-instance 'cl-harness/src/agent:agent-state))
           (provider (make-instance '%stub-provider))
           (events (%capture-jsonl-events
                    (lambda (logger)
                      (cl-harness/src/agent::%complete-chat-with-logging
                       provider messages config state logger 1)))))
      (let ((types (mapcar (lambda (e) (gethash "type" e)) events)))
        (ok (not (member "llm-request" types :test #'equal)))
        (ok (member "llm-response" types :test #'equal))))))
```

This test depends on `%complete-chat-with-logging` — a helper we will EXTRACT in Step 3 to isolate the chat-call + dual logging from the surrounding agent loop. The current code inlines this logic at L1244-1255.

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::llm-request-event-emit-and-suppress"
```

Expected: failure — `%complete-chat-with-logging` undefined.

- [ ] **Step 3: Extract `%complete-chat-with-logging` + add llm-request emit**

In `src/agent.lisp`, find the inline `(let* ((effective-messages ...) (chat (complete-chat provider effective-messages)) ...))` around L1244-1255. Read the surrounding function via `mcp__cl-mcp__lisp-read-file` with `name_pattern` matching it.

Extract the chat+log logic into a helper. Use `mcp__cl-mcp__lisp-edit-form operation=insert_before` on the calling function to add:

```lisp
(defun %complete-chat-with-logging (provider messages config state logger turn)
  "Call COMPLETE-CHAT and emit a :llm-response event. When
RUN-CONFIG-LOG-LLM-REQUESTS-P is true on CONFIG, also emit a
:llm-request event BEFORE the chat call carrying the full messages
history. STATE's token-total is incremented from the response.
Returns the CHAT-RESPONSE.

Extracted from inline use in the agent loop so the dual logging
boundary is unit-testable without standing up the whole loop."
  (let ((effective-messages
         (%maybe-compact-messages messages
                                  (run-config-limits config))))
    (when (run-config-log-llm-requests-p config)
      (log-event
       logger :llm-request
       `(("turn" . ,turn)
         ("messages" . ,(coerce
                         (mapcar (lambda (m)
                                   (alexandria:alist-hash-table
                                    `(("role" . ,(cl-harness/src/model:chat-message-role m))
                                      ("content" . ,(cl-harness/src/model:chat-message-content m)))
                                    :test 'equal))
                                 effective-messages)
                         'vector))
         ("messages_count" . ,(length effective-messages)))))
    (let* ((chat (complete-chat provider effective-messages))
           (text (chat-response-content chat)))
      (incf (agent-state-token-total state)
            (or (chat-response-total-tokens chat) 0))
      (log-event logger :llm-response
                 `(("turn" . ,turn)
                   ("content" . ,text)
                   ("tokens" . ,(or (chat-response-total-tokens chat) 0))))
      chat)))
```

Then update the original call site (around L1244-1255) to use this helper:

```lisp
  (let* ((chat (%complete-chat-with-logging provider messages config state
                                            logger turn))
         (text (chat-response-content chat)))
    (cond
      ((or (null text) (zerop (length text)))
       ...))) ; remainder unchanged
```

Note: `chat-message-role` / `chat-message-content` are accessors on `chat-message` from `cl-harness/src/model`. If they have different names in the actual source (verify by reading `src/model.lisp`), substitute accordingly.

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::llm-request-event-emit-and-suppress"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes (2 testing blocks); full suite 449 (was 448 + 1).

- [ ] **Step 5: Commit**

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "logging: :llm-request event guarded by run-config flag (G3)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: One-shot stderr warning on opt-in activation

**Files:**
- Modify: `src/cli-main.lisp` (each of `fix-handler` / `bench-handler` / `develop-handler` head)
- Test: `tests/agent-test.lisp` or a new `tests/cli-main-test.lisp` (use existing `agent-test.lisp` for now; the test exercises the warning function in isolation)

- [ ] **Step 1: Write the failing test**

Append to `tests/agent-test.lisp`:

```lisp
(deftest log-llm-requests-warning-once
  (testing "warning emitted to *error-output* when flag is true"
    (let ((stderr (with-output-to-string (*error-output*)
                    (cl-harness/src/cli-main::%maybe-warn-log-llm-requests t))))
      (ok (search "WARNING:" stderr))
      (ok (search "--log-llm-requests" stderr))))
  (testing "no warning when flag is false"
    (let ((stderr (with-output-to-string (*error-output*)
                    (cl-harness/src/cli-main::%maybe-warn-log-llm-requests nil))))
      (ok (zerop (length stderr))))))
```

- [ ] **Step 2: Run test to verify it fails**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::log-llm-requests-warning-once"
```

Expected: failure — `%maybe-warn-log-llm-requests` undefined.

- [ ] **Step 3: Implement the warning helper**

In `src/cli-main.lisp`, insert near the top after the `(in-package ...)` form using `mcp__cl-mcp__lisp-edit-form operation=insert_after` on the `in-package` (or directly before the first defun):

```lisp
(defun %maybe-warn-log-llm-requests (flag)
  "Emit a one-line WARNING to *ERROR-OUTPUT* when FLAG is truthy.
Called from each CLI handler head once the opt-in source is resolved
(kwarg / --log-llm-requests / CL_HARNESS_LOG_LLM_REQUESTS)."
  (when flag
    (format *error-output*
            "WARNING: --log-llm-requests is enabled. LLM message history (including~%~
             source code, file paths, and any other context the agent reads) will be~%~
             written verbatim to the JSONL transcript. Do NOT share the transcript~%~
             without review.~%")))
```

- [ ] **Step 4: Run test to verify it passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/agent-test::log-llm-requests-warning-once"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes (2 testing blocks); full suite 450 (was 449 + 1).

- [ ] **Step 5: Commit**

```bash
git add src/cli-main.lisp tests/agent-test.lisp
git commit -m "logging: %maybe-warn-log-llm-requests stderr helper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Thread `:log-llm-requests` through CLI

**Files:**
- Modify: `src/cli.lisp` (`fix` / `bench` / `develop` defun heads, ~L100-400)
- Modify: `src/cli-main.lisp` (`fix-options` / `bench-options` / `develop-options` + handler getopt)

- [ ] **Step 1: Read each cli.lisp entry function**

Use `mcp__cl-mcp__lisp-read-file` with `name_pattern="^fix$"`, `name_pattern="^bench$"`, `name_pattern="^develop$"` on `src/cli.lisp`. Identify their `&key` lists and the `make-run-config` calls inside their bodies.

- [ ] **Step 2: Add `:log-llm-requests` kwarg to `fix`**

In `src/cli.lisp` `fix`, add `(log-llm-requests nil)` to its `&key` list (next to similar opt-in kwargs like `dry-run`). In the body, find the `make-run-config` call and add `:log-llm-requests log-llm-requests` to it. Also, in the same body, add an early call to `(%maybe-warn-log-llm-requests log-llm-requests)` — but `cli.lisp` does NOT import `%maybe-warn-log-llm-requests` by default. Either:

- (a) `:import-from #:cl-harness/src/cli-main #:%maybe-warn-log-llm-requests` in cli.lisp's defpackage, OR
- (b) Define a parallel helper in cli.lisp, OR
- (c) Skip the warning in programmatic callers — only emit in the shell CLI (cli-main.lisp's handlers)

Choose **(c)**: programmatic callers (`(cl-harness:fix :log-llm-requests t ...)`) are sophisticated users; the warning is for shell `cl-harness fix --log-llm-requests` invocations where the user types the flag manually. Skip the helper call in `cli.lisp` to avoid the import.

So `cli.lisp`'s `fix` just adds the kwarg + passes to make-run-config. No warning emission.

Use `mcp__cl-mcp__lisp-edit-form operation=replace` on `fix` to surgically update.

- [ ] **Step 3: Same change to `bench` and `develop` in `cli.lisp`**

Repeat Step 2 for `bench` and `develop`. For `develop` specifically, the kwarg flows through to `cl-harness/src/orchestrator:develop` — but orchestrator-level develop doesn't take `:log-llm-requests` (it takes provider + mcp-client + run-limits, not run-config). Trace where run-config is constructed inside `develop`'s body.

If `develop` doesn't construct a run-config directly (it might delegate via `execute-plan` which delegates to `%execute-step` which builds rc per iteration), then `:log-llm-requests` needs to be threaded through `execute-plan` → `%execute-step` → `make-run-config`. That's wider plumbing.

Actually — re-reading the orchestrator code from earlier read: `%execute-step` builds `rc` via `make-run-config` at iteration boundaries. So we need to add `:log-llm-requests` as a kwarg to `execute-plan` and `%execute-step` and `develop` (orchestrator). Then `cli.lisp:develop` accepts it and passes through.

Concretely:

- `src/orchestrator.lisp`: `%execute-step` gets new kwarg `(log-llm-requests nil)`. The `make-run-config` calls inside its body get `:log-llm-requests log-llm-requests`. Similarly `execute-plan` and `develop` (orchestrator) gain the kwarg with pass-through.
- `src/cli.lisp:develop`: gains `(log-llm-requests nil)` kwarg, passes to `cl-harness/src/orchestrator:develop`.
- `src/cli.lisp:fix` / `bench`: simpler — they call `make-run-config` directly, just add the kwarg + pass-through.

Apply each surgically with `lisp-edit-form operation=replace`.

- [ ] **Step 4: Add `--log-llm-requests` flag to clingon options**

In `src/cli-main.lisp`, find `fix-options` / `bench-options` / `develop-options`. Each is a defun returning a list of `clingon:make-option` calls. Add to EACH:

```lisp
   (clingon:make-option :flag :long-name "log-llm-requests"
                        :description "emit :llm-request JSONL events with full chat history (verbose, may contain secrets)"
                        :key :log-llm-requests)
```

- [ ] **Step 5: Update each handler to getopt + warn + pass-through**

In `src/cli-main.lisp` `fix-handler` / `bench-handler` / `develop-handler`, add at the TOP of the body (before constructing run-config or before calling the orchestrator):

```lisp
  (let ((log-llm-requests (clingon:getopt cmd :log-llm-requests)))
    (%maybe-warn-log-llm-requests log-llm-requests)
    ...) ; existing body with :log-llm-requests log-llm-requests threaded in
```

And in the inner `fix` / `bench` / `develop` call site, add `:log-llm-requests log-llm-requests`.

- [ ] **Step 6: Add a CLI-level deftest**

Append to `tests/agent-test.lisp`:

```lisp
(deftest log-llm-requests-cli-flag-parses
  (testing "develop-options includes --log-llm-requests flag"
    (let* ((cmd (cl-harness/src/cli-main::develop-command))
           (option-names
             (mapcar (lambda (o) (clingon:option-long-name o))
                     (clingon:command-options cmd))))
      (ok (member "log-llm-requests" option-names :test #'equal))))
  (testing "fix-options includes --log-llm-requests flag"
    (let* ((cmd (cl-harness/src/cli-main::fix-command))
           (option-names
             (mapcar (lambda (o) (clingon:option-long-name o))
                     (clingon:command-options cmd))))
      (ok (member "log-llm-requests" option-names :test #'equal))))
  (testing "bench-options includes --log-llm-requests flag"
    (let* ((cmd (cl-harness/src/cli-main::bench-command))
           (option-names
             (mapcar (lambda (o) (clingon:option-long-name o))
                     (clingon:command-options cmd))))
      (ok (member "log-llm-requests" option-names :test #'equal)))))
```

- [ ] **Step 7: Run all tests + reload**

```
mcp__cl-mcp__load-system with system="cl-harness", force=true
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 451 passed (was 450 + 1 new deftest). The 8th deftest is in Task 7 here; together with Tasks 1-6's 7 deftests = 8 total new = 452 if I miscounted earlier; verify and adjust the expected count.

Actually counting Task 1 (1 deftest) + Task 2 (1) + Task 3 (1) + Task 4 (1) + Task 5 (1) + Task 6 (1) + Task 7 (1) = 7 deftests added. Spec §8 said 8 — re-check by adding Task 5 to actually count "emit + suppress" as 2 testing blocks, but a single deftest. So 7 deftests, not 8. Adjust expected: 444 + 7 = 451.

- [ ] **Step 8: Commit**

```bash
git add src/cli.lisp src/cli-main.lisp src/orchestrator.lisp tests/agent-test.lisp
git commit -m "logging: --log-llm-requests CLI flag + kwarg pass-through

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: README + PRD documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/cl-harness-prd.md`

- [ ] **Step 1: Update README**

In `README.md`, find the develop section (around L266). After the existing terminal-status documentation, add a new subsection:

```markdown
### Postmortem logging

Each develop / fix / bench run writes a JSONL transcript (default
under `(uiop:temporary-directory)`; override with `--log-path`).
Events include:

- `:verify` — counts plus a `failed_tests` array per test (test_name /
  description / form / values / reason / source).
- `:tool-result` — `is_error` plus `content_summary` (the summarized
  string the agent's next user message saw, ~1500 chars).
- `:llm-request` — **opt-in** via `--log-llm-requests` flag,
  `:log-llm-requests t` kwarg, or `CL_HARNESS_LOG_LLM_REQUESTS=1`
  env. Records the full chat history sent to the LLM each turn.
  Emits a one-line stderr warning on activation because the payload
  may contain source code, file paths, and any other context the
  agent has read. Do NOT share these transcripts unreviewed.
```

- [ ] **Step 2: Update PRD §8.10 REQ-LOG-001**

In `docs/cl-harness-prd.md`, find section §8.10 REQ-LOG-001. Append a subsection documenting the new fields:

```markdown
### §8.10.1 拡張: postmortem-logging (2026-05-23)

- `:verify` event payload に `failed_tests` 配列を追加(rove framework が
  返す test_name / description / form / values / reason / source キー)。
  passed 時はキー省略。
- `:tool-result` event payload に `content_summary`(成功時、~1500 char
  まで truncate)を追加。エラー時は従来通り `error_text` のみ(排他)。
- 新規 event `:llm-request` を追加。`run-config-log-llm-requests-p` が
  truthy のときのみ `complete-chat` 直前に emit、payload は
  `messages`(role/content の配列)と `messages_count`。
- Opt-in 制御: kwarg `:log-llm-requests` / CLI flag `--log-llm-requests` /
  env `CL_HARNESS_LOG_LLM_REQUESTS`。CLI 起動時に有効化を検出すると
  stderr に一度だけ警告。
- 設計詳細: `docs/superpowers/specs/2026-05-23-postmortem-logging-design.md`
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/cl-harness-prd.md
git commit -m "docs: README + PRD §8.10.1 postmortem-logging fields

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Final integration check

**Files:**
- (verification only)

- [ ] **Step 1: Force-compile entire system**

```
mcp__cl-mcp__load-system with system="cl-harness", force=true, clear_fasls=true, timeout_seconds=240
```

Expected: success. UIOP "redefining" warnings ignored. Only flag warnings sourced from `:CL-HARNESS/SRC/AGENT`, `:CL-HARNESS/SRC/CONFIG`, `:CL-HARNESS/SRC/CLI`, `:CL-HARNESS/SRC/CLI-MAIN`, `:CL-HARNESS/SRC/MAIN`, `:CL-HARNESS/SRC/ORCHESTRATOR`, or `:CL-HARNESS/TESTS/AGENT-TEST`.

- [ ] **Step 2: Run full test suite**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests", timeout_seconds=600
```

Expected: 451 passed (444 baseline + 7 new deftests from Tasks 1-7), 0 failed.

- [ ] **Step 3: Mallet lint**

```bash
which mallet && mallet src/agent.lisp src/config.lisp src/cli.lisp src/cli-main.lisp src/main.lisp src/orchestrator.lisp tests/agent-test.lisp || echo "mallet not available — skip"
```

Fix any flagged issues. Likely candidates:
- Long `format` strings (the warning message in `%maybe-warn-log-llm-requests`)
- Missing docstring on public functions (the new helpers all have them, but verify)
- Unused parameters in deftest lambdas

- [ ] **Step 4: Smoke-test a single develop run with the new flag**

```bash
# Set up env (assuming env vars are present in the shell)
ros run -- --non-interactive \
  --eval "(require :asdf)" \
  --eval "(asdf:load-system :cl-harness)" \
  --eval '(let ((task (cl-harness/src/develop-bench:load-develop-task #P"/home/wiz/.roswell/local-projects/cl-harness/develop-benchmarks/100-greet/"))) (cl-harness:develop :goal (cl-harness/src/develop-bench:develop-task-goal task) :project-root (namestring (cl-harness/src/develop-bench:prepare-develop-task-sandbox task)) :system "greet" :test-system "greet/tests" :test-file "tests/main-test.lisp" :log-llm-requests t :max-replans 0 :log-path "/tmp/postmortem-smoke.jsonl"))' \
  2> /tmp/postmortem-smoke.stderr
```

Then verify:
```bash
grep -o '"type":"[^"]*"' /tmp/postmortem-smoke.jsonl | sort | uniq -c
```

Expected: includes `"type":"llm-request"` lines. The stderr capture should contain "WARNING: --log-llm-requests is enabled".

This smoke test is OPTIONAL — it requires the live LLM endpoint and a full develop run (~2 min). If skipping, document in the report.

- [ ] **Step 5: Verify commit count + clean state**

```bash
git status
git log --oneline main..HEAD
```

Expected: 8 commits (Tasks 1-8), `working tree clean`.

- [ ] **Step 6: If mallet or compile produced fixes, commit them**

```bash
# only if changes from Step 3:
git add <files>
git commit -m "logging: mallet + compile-warning cleanup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (verified by author)

**Spec coverage check** (every requirement in `docs/superpowers/specs/2026-05-23-postmortem-logging-design.md`):

| Spec section | Implemented in |
|---|---|
| §1 motivation / §1.1 design choice / §1.2 scope | Architecture, no task |
| §2 全体方針 | Tasks 1-7 (each gap to one task pair) |
| §3 G1 verify schema | Tasks 1, 2 |
| §4 G2 tool-result schema | Task 3 |
| §5.1 G3 schema | Task 5 |
| §5.2 opt-in 優先順位 | Task 4 (kwarg), Task 7 (CLI flag), Task 7 (env — note below) |
| §5.3 stderr warning | Task 6 (helper) + Task 7 (wired into handlers) |
| §6 データ抽出の場所 | Tasks 1-5 |
| §7 backward compat | All tasks (additive shape) |
| §8 test strategy | Tasks 1-7 each include a deftest |
| §9 ドキュメント | Task 8 |
| §10 out-of-scope | Not implemented (correct) |
| §11 risks | Task 7 (warning placement avoids constructor side-effect per §11) |
| §12 implementation order | Tasks 1-9 follow it |

**Spec §5.2 env var resolution**: the spec says `CL_HARNESS_LOG_LLM_REQUESTS=1` is one of the 3 opt-in sources, in priority order kwarg > CLI flag > env. The plan's Task 7 wires kwarg and CLI flag through. The env var resolution needs to happen somewhere; the natural place is `cli-main.lisp` handler heads:

```lisp
(let ((log-llm-requests
       (or (clingon:getopt cmd :log-llm-requests)
           (and (uiop:getenv "CL_HARNESS_LOG_LLM_REQUESTS")
                (not (member (uiop:getenv "CL_HARNESS_LOG_LLM_REQUESTS")
                             '("" "0" "false" "FALSE") :test #'equal))))))
  ...)
```

Add this line to Task 7 Step 5's getopt block. (Updating that step inline rather than as a separate task because it's a 5-line addition tightly coupled to the existing CLI handler edit.)

**Placeholder scan:** No TBD / TODO / implement-later outside the intentional "verify by reading source" hints. All test code is concrete; all production code is concrete.

**Type consistency:**
- `log-llm-requests` (kwarg name, all lowercase, with hyphens) is consistent across Tasks 4, 5, 7.
- `log-llm-requests-p` (slot accessor with `-p` predicate suffix) is consistent in Tasks 4, 5.
- `--log-llm-requests` (CLI flag long name) consistent in Task 7.
- `%maybe-warn-log-llm-requests` helper name consistent in Tasks 6, 7.
- `%verify-failed-tests-payload` helper name consistent in Tasks 1, 2.
- `%complete-chat-with-logging` helper name consistent in Task 5.
- `%capture-jsonl-events` test helper introduced in Task 3, reused in Task 5.

**Test count math:**
- Baseline 444
- +1 (Task 1) → 445
- +1 (Task 2) → 446
- +1 (Task 3) → 447
- +1 (Task 4) → 448
- +1 (Task 5) → 449
- +1 (Task 6) → 450
- +1 (Task 7) → 451

Final 451. Spec §8 listed 8 expected deftests (target 452); the discrepancy comes from collapsing the spec's tests #5 and #6 ("emitted when opt-in true" + "suppressed when opt-in false") into a single deftest with 2 testing blocks in this plan (Task 5). That's a design choice for tighter scope per task; the assertion coverage is identical. If a strict 8-deftest count is preferred, split Task 5's deftest into two.

No issues found. Plan ready.
