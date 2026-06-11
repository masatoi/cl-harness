# SP5a: LLM Connectivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect `cl-harness-next` to LLMs — the OpenAI-compatible provider (adapt-copied from battle-tested legacy `src/model.lisp` with failure classification and single-retry), the action parser (adapt-copied from legacy `src/action.lisp` minus the develop-loop-specific variant), the judge bridge that closes SP4's review-oracle deferred item, and the world-model refresh helper the SP5b kernel will sync with.

**Architecture:** Two adapt-copies follow the SP2 precedent (verbatim body + precise delta list; the per-task reviewer diffs against the legacy source). `make-judge-fn` bridges a provider to the review oracle's `judge-fn` contract. `refresh-world-model` folds only events newer than the model's `last-seq` — the kernel's per-step sync, keeping the event log the single source of truth. SP5b (kernel + scripted policy) builds on all four in a separate plan. Spec: `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md` §6 (L3 needs an LLM), 原則3.

**Tech Stack:** SBCL, rove, alexandria, yason, **dexador + usocket (new top-level deps — return for HTTP LLM traffic)**.

**Conventions** (same as SP1–SP4): 2-space indent, ≤100 cols, blank lines between forms, docstrings, no `:local-nicknames`, conditions get `:initform` on every slot, `%`-internals unexported. cl-mcp tools for Lisp work; `mallet` before commits; tests via `run-tests` `{"system": "cl-harness-next/tests"}`; worker-restart recovery `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`. Unused test-file imports flagged by mallet get removed (note it). **Adapt-copy honesty valve:** if a pinned test expectation contradicts the verbatim legacy behavior you observe, do NOT weaken the code or silently adjust — report BLOCKED with the discrepancy; the controller arbitrates. Indexing into yason-parsed JSON arrays must use sequence-generic `elt`, never `first` — the cl-mcp worker sets `yason:*parse-json-arrays-as-vectors*` globally.

---

## File Structure

```text
next/src/model.lisp        NEW  adapt-copy of legacy src/model.lisp (OpenAI-compatible
                                provider, failure classification, single retry)
next/src/action.lisp       NEW  adapt-copy of legacy src/action.lisp (tool_call/finish/
                                finding; test-change-request variant DROPPED)
next/src/judge.lisp        NEW  provider → review-oracle judge-fn bridge
next/src/world-model.lisp  MOD  + refresh-world-model
next/src/main.lisp         MOD  facade re-exports
next/tests/model-test.lisp       NEW (+6)
next/tests/action-test.lisp      NEW (+7)
next/tests/judge-test.lisp       NEW (+2)
next/tests/world-model-test.lisp MOD (+2)
next/tests/main-test.lisp        MOD (+2: facade acceptance + gated real-LLM smoke)
cl-harness-next.asd        MOD  + dexador, usocket deps; + 3 test files
README.md                  MOD  one sentence
```

Test-count checkpoints: 143 → T1 149 → T2 156 → T3 158 → T4 160 → T5 162.

---

### Task 1: OpenAI-compatible provider (adapt-copy)

**Files:**
- Create: `next/tests/model-test.lisp`
- Create: `next/src/model.lisp` (adapt-copy of `src/model.lisp` — read it fully with `lisp-read-file` `collapsed=false`, 421 lines)
- Modify: `cl-harness-next.asd` (PRIMARY system `:depends-on` gains `"dexador"` and `"usocket"` after `"bordeaux-threads"`; tests system gains the test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/model-test.lisp`:

```lisp
;;;; next/tests/model-test.lisp
;;;;
;;;; Tests for next/src/model.lisp (adapt-copy of legacy src/model.lisp).
;;;; A recording stub transport replaces the network; pinned behaviors:
;;;; request-body shape, response parsing with usage, failure
;;;; classification (401 / 500), single retry on transient errors.

(defpackage #:cl-harness-next/tests/model-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/model
                #:make-openai-provider
                #:make-chat-message
                #:chat-build-request-body
                #:chat-parse-response
                #:complete-chat
                #:chat-response-content
                #:chat-response-role
                #:chat-response-total-tokens
                #:model-error
                #:model-error-type))

(in-package #:cl-harness-next/tests/model-test)

(defparameter *success-body*
  (concatenate 'string
               "{\"choices\":[{\"message\":{\"role\":\"assistant\","
               "\"content\":\"hi\"},\"finish_reason\":\"stop\"}],"
               "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,"
               "\"total_tokens\":3}}"))

(defun %counted-transport (responses)
  "Return (values transport-fn counter-thunk). Each call pops one
(BODY . STATUS) entry; the last entry repeats."
  (let ((remaining responses)
        (calls 0))
    (values (lambda (url headers body)
              (declare (ignore url headers body))
              (incf calls)
              (destructuring-bind (response-body . status)
                  (if (rest remaining)
                      (pop remaining)
                      (first remaining))
                (values response-body status (make-hash-table :test #'equal))))
            (lambda () calls))))

(defun %provider (responses &key (retry-p t))
  (multiple-value-bind (transport counter) (%counted-transport responses)
    (values (make-openai-provider :base-url "http://x/v1"
                                  :api-key "k" :model "m"
                                  :transport transport
                                  :retry-p retry-p)
            counter)))

(deftest request-body-shape
  (let ((parsed (yason:parse
                 (chat-build-request-body
                  "m" (list (make-chat-message "user" "hi"))
                  :temperature 0.5 :max-tokens 32))))
    (ok (equal "m" (gethash "model" parsed)))
    (ok (equal "user" (gethash "role" (elt (gethash "messages" parsed) 0))))
    (ok (equal "hi" (gethash "content" (elt (gethash "messages" parsed) 0))))
    (ok (= 32 (gethash "max_tokens" parsed)))))

(deftest parse-response-extracts-content-and-usage
  (let ((response (chat-parse-response *success-body*)))
    (ok (equal "hi" (chat-response-content response)))
    (ok (equal "assistant" (chat-response-role response)))
    (ok (= 3 (chat-response-total-tokens response)))))

(deftest complete-chat-roundtrip
  (let ((provider (%provider (list (cons *success-body* 200)))))
    (ok (equal "hi" (chat-response-content
                     (complete-chat provider
                                    (list (make-chat-message "user" "q"))))))))

(deftest auth-failure-classified-and-not-retried
  (multiple-value-bind (provider counter)
      (%provider (list (cons "{\"error\":{\"message\":\"bad key\"}}" 401)))
    (ok (handler-case
            (progn (complete-chat provider
                                  (list (make-chat-message "user" "q")))
                   nil)
          (model-error (e) (eq :auth-failed (model-error-type e)))))
    (ok (= 1 (funcall counter)))))

(deftest server-error-retried-once
  (multiple-value-bind (provider counter)
      (%provider (list (cons "{\"error\":{\"message\":\"oops\"}}" 500)))
    (ok (handler-case
            (progn (complete-chat provider
                                  (list (make-chat-message "user" "q")))
                   nil)
          (model-error (e) (eq :http-server-error (model-error-type e)))))
    (ok (= 2 (funcall counter)))))

(deftest retry-disabled-calls-once
  (multiple-value-bind (provider counter)
      (%provider (list (cons "{\"error\":{\"message\":\"oops\"}}" 500))
                 :retry-p nil)
    (ok (handler-case
            (progn (complete-chat provider
                                  (list (make-chat-message "user" "q")))
                   nil)
          (model-error () t)))
    (ok (= 1 (funcall counter)))))
```

- [ ] **Step 2: Register test in `.asd`, add deps, run for red**

Add `"dexador"` and `"usocket"` to the PRIMARY system's `:depends-on`
(after `"bordeaux-threads"`); add
`"cl-harness-next/tests/model-test"` to the tests system. Run tests —
expected red: load failure (package `cl-harness-next/src/model`
missing). If dexador/usocket are not yet loaded in the image, run
`(ql:quickload '("dexador" "usocket") :silent t)` via repl-eval once.

- [ ] **Step 3: Create `next/src/model.lisp` by adapt-copy**

Read legacy `src/model.lisp` fully (`lisp-read-file` `path:"src/model.lisp"
collapsed:false` — 421 lines, paginate with offset). Create
`next/src/model.lisp` containing the ENTIRE legacy file verbatim with
EXACTLY these deltas and no others:

1. New file header comment:

```lisp
;;;; next/src/model.lisp
;;;;
;;;; OpenAI-compatible chat client, adapt-copied from legacy
;;;; src/model.lisp (battle-tested: failure classification + single
;;;; retry on transient errors, 29 legacy transport tests). Blocking
;;;; POST /v1/chat/completions, no streaming; TRANSPORT is an
;;;; injectable function so tests never hit the network.
```

2. `defpackage` renamed to `#:cl-harness-next/src/model` (same
   `:import-from` clauses for alexandria/dexador/usocket, same export
   list).
3. `model-error`'s `message` slot gains `:initform "(no message)"`
   (print-bare hardening).
4. Drop the legacy stub-marker comment line
   (`;; ----- Stubs (replaced piecewise by lisp-edit-form) ---...`)
   if present.

Everything else — `+default-llm-read-timeout-seconds+`,
`default-llm-transport`, `+classifiable-status-codes+`,
`+retriable-reasons+`, `%classify-llm-failure`, `make-openai-provider`,
`make-chat-message`, `chat-build-request-body`, `%first-choice-message`,
`chat-parse-response`, `%join-url`, `complete-chat` generic + method —
is copied byte-for-byte. Verify with `lisp-check-parens`.

- [ ] **Step 4: Green** — expect 149 / 0. (Honesty valve: if a pinned
expectation fails against the verbatim code — e.g. a different reason
keyword — report BLOCKED with what you observed instead of changing
either side.)

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/model.lisp next/tests/model-test.lisp
git add next/src/model.lisp next/tests/model-test.lisp cl-harness-next.asd
git commit -m "feat(next): OpenAI-compatible provider adapt-copied from legacy"
```

---

### Task 2: Action parser (adapt-copy, minus test-change-request)

**Files:**
- Create: `next/tests/action-test.lisp`
- Create: `next/src/action.lisp` (adapt-copy of `src/action.lisp` — read it fully, 239 lines)
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/action-test.lisp`:

```lisp
;;;; next/tests/action-test.lisp
;;;;
;;;; Tests for next/src/action.lisp (adapt-copy of legacy
;;;; src/action.lisp): tool_call (nested + flat arguments), finish,
;;;; finding, fence stripping, parse errors. The legacy
;;;; test-change-request variant is dropped (develop-loop detail).

(defpackage #:cl-harness-next/tests/action-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-thought
                #:agent-action-hypothesis
                #:agent-action-decision
                #:action-parse-error))

(in-package #:cl-harness-next/tests/action-test)

(deftest tool-call-with-nested-arguments
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"tool_call\",\"tool\":\"run-tests\","
                              "\"arguments\":{\"system\":\"s\"},"
                              "\"thought\":\"verify\"}"))))
    (ok (eq :tool-call (agent-action-type action)))
    (ok (equal "run-tests" (agent-action-tool action)))
    (ok (equal "s" (gethash "system" (agent-action-arguments action))))
    (ok (equal "verify" (agent-action-thought action)))))

(deftest flat-arguments-are-promoted
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"tool_call\",\"tool\":\"repl-eval\","
                              "\"code\":\"(+ 1 2)\"}"))))
    (ok (equal "(+ 1 2)" (gethash "code" (agent-action-arguments action))))
    ;; Envelope keys never leak into arguments.
    (ok (null (gethash "type" (agent-action-arguments action))))))

(deftest code-fences-are-stripped
  (let ((action (parse-action
                 (format nil "```json~%{\"type\":\"finish\",~
\"status\":\"fixed\",\"summary\":\"done\"}~%```"))))
    (ok (eq :finish (agent-action-type action)))
    (ok (eq :fixed (agent-action-status action)))
    (ok (equal "done" (agent-action-summary action)))))

(deftest finish-statuses
  (ok (eq :give-up
          (agent-action-status
           (parse-action "{\"type\":\"finish\",\"status\":\"give_up\"}"))))
  (ok (handler-case
          (progn (parse-action "{\"type\":\"finish\",\"status\":\"meh\"}")
                 nil)
        (action-parse-error () t))))

(deftest finding-roundtrip
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"finding\",\"hypothesis\":\"h\","
                              "\"probe\":\"p\",\"finding\":\"f\","
                              "\"decision\":\"d\"}"))))
    (ok (eq :finding (agent-action-type action)))
    (ok (equal "h" (agent-action-hypothesis action)))
    (ok (equal "d" (agent-action-decision action)))))

(deftest finding-requires-all-four-fields
  (ok (handler-case
          (progn (parse-action
                  "{\"type\":\"finding\",\"hypothesis\":\"h\"}")
                 nil)
        (action-parse-error () t))))

(deftest invalid-inputs-signal-parse-errors
  (dolist (bad '("not json" "[1,2]" "{\"type\":\"warp\"}"
                 "{\"type\":\"test_change_request\",\"test_source\":\"x\"}"))
    (ok (handler-case (progn (parse-action bad) nil)
          (action-parse-error () t))
        (format nil "~S should not parse" bad))))
```

- [ ] **Step 2: Register in `.asd`, run for red** — load failure
(missing package).

- [ ] **Step 3: Create `next/src/action.lisp` by adapt-copy**

Read legacy `src/action.lisp` fully (239 lines). Create
`next/src/action.lisp` with the legacy content verbatim, EXACTLY these
deltas:

1. New header comment:

```lisp
;;;; next/src/action.lisp
;;;;
;;;; LLM action parser, adapt-copied from legacy src/action.lisp.
;;;; Schema: {"type":"tool_call","tool":...,"arguments":{...}} /
;;;; {"type":"finish","status":"fixed"|"give_up"} /
;;;; {"type":"finding",...} — with markdown-fence stripping and the
;;;; flat-arguments fallback (Qwen-class models emit it). The legacy
;;;; test-change-request variant is dropped (develop-loop detail;
;;;; returns with a scripted develop policy if ever needed).
```

2. `defpackage` renamed to `#:cl-harness-next/src/action`; REMOVE
   `#:agent-action-criteria`, `#:agent-action-rationale`,
   `#:agent-action-test-source` from the export list.
3. `agent-action` class: DELETE the `criteria`, `rationale`, and
   `test-source` slots; update the class docstring's TYPE enumeration
   to ":TOOL-CALL, :FINISH, or :FINDING".
4. `+envelope-keys+`: REMOVE `"criteria"`, `"rationale"`,
   `"test_source"` (keep the rest, including the four finding fields);
   trim the docstring's Phase-H sentence if it references the removed
   keys.
5. `parse-action`: DELETE the entire `((equal type
   "test_change_request") ...)` clause (read lines 190–239 of the
   legacy file to see its extent); KEEP the final unknown-type error
   clause so `test_change_request` now signals `action-parse-error`.
6. `action-parse-error`'s `message` slot gains
   `:initform "(no message)"`.
7. Drop the legacy `;; --- Stubs ---...` comment block if present.

Everything else (`strip-code-fence`, `%extract-flat-arguments`, the
tool_call / finish / finding clauses) byte-for-byte. Verify with
`lisp-check-parens`.

- [ ] **Step 4: Green** — expect 156 / 0 (honesty valve applies).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/action.lisp next/tests/action-test.lisp
git add next/src/action.lisp next/tests/action-test.lisp cl-harness-next.asd
git commit -m "feat(next): LLM action parser adapt-copied, minus test-change-request"
```

---

### Task 3: Judge bridge (provider → review oracle)

**Files:**
- Create: `next/tests/judge-test.lisp`
- Create: `next/src/judge.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/judge-test.lisp`:

```lisp
;;;; next/tests/judge-test.lisp
;;;;
;;;; Tests for next/src/judge.lisp — the bridge closing SP4's deferred
;;;; item: an LLM provider becomes the review oracle's judge-fn.

(defpackage #:cl-harness-next/tests/judge-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/model
                #:make-openai-provider)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle)
  (:import-from #:cl-harness-next/src/judge
                #:make-judge-fn))

(in-package #:cl-harness-next/tests/judge-test)

(defun %canned-provider (content &optional captured-bodies)
  "Provider whose transport always returns CONTENT; request bodies are
pushed onto the CAPTURED-BODIES list head when supplied."
  (make-openai-provider
   :base-url "http://x/v1" :api-key "k" :model "m"
   :transport
   (lambda (url headers body)
     (declare (ignore url headers))
     (when captured-bodies (push body (car captured-bodies)))
     (values (with-output-to-string (out)
               (yason:encode
                (alexandria:plist-hash-table
                 (list "choices"
                       (list (alexandria:plist-hash-table
                              (list "message"
                                    (alexandria:plist-hash-table
                                     (list "role" "assistant"
                                           "content" content)
                                     :test #'equal)
                                    "finish_reason" "stop")
                              :test #'equal)))
                 :test #'equal)
                out))
             200 (make-hash-table :test #'equal)))))

(deftest judge-fn-returns-content
  (let ((judge (make-judge-fn (%canned-provider "APPROVE fine"))))
    (ok (equal "APPROVE fine" (funcall judge "prompt")))))

(deftest provider-drives-review-oracle-end-to-end
  (let* ((captured (list nil))
         (judge (make-judge-fn (%canned-provider "REJECT: too vague"
                                                 captured)
                               :system-prompt "Be terse."))
         (verdict (evaluate (make-instance 'review-oracle
                                           :profile '(:id :review-plan
                                                      :strictness :strict)
                                           :judge-fn judge)
                            "the plan")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "too vague" (verdict-reason verdict)))
    ;; The system prompt rode along in the request body.
    (ok (search "Be terse." (first (car captured))))))
```

- [ ] **Step 2: Register in `.asd`, run for red** — load failure.

- [ ] **Step 3: Create `next/src/judge.lisp`**

```lisp
;;;; next/src/judge.lisp
;;;;
;;;; Bridge from an LLM provider to the review oracle's judge-fn
;;;; contract (closes SP4's deferred item): the oracle stays
;;;; provider-agnostic, the provider stays oracle-agnostic.

(defpackage #:cl-harness-next/src/judge
  (:use #:cl)
  (:import-from #:cl-harness-next/src/model
                #:complete-chat
                #:make-chat-message
                #:chat-response-content)
  (:export #:make-judge-fn))

(in-package #:cl-harness-next/src/judge)

(defun make-judge-fn (provider &key system-prompt)
  "Return a judge function (prompt-string → response-string) backed by
PROVIDER. SYSTEM-PROMPT, when supplied, is prepended as a system
message. MODEL-ERRORs propagate — the review oracle's evaluate already
fails closed on judge errors."
  (lambda (prompt)
    (let ((messages (append (when system-prompt
                              (list (make-chat-message "system"
                                                       system-prompt)))
                            (list (make-chat-message "user" prompt)))))
      (chat-response-content (complete-chat provider messages)))))
```

- [ ] **Step 4: Green** — expect 158 / 0.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/judge.lisp next/tests/judge-test.lisp
git add next/src/judge.lisp next/tests/judge-test.lisp cl-harness-next.asd
git commit -m "feat(next): judge bridge from provider to review oracle"
```

---

### Task 4: `refresh-world-model` (kernel's per-step sync)

**Files:**
- Modify: `next/src/world-model.lisp`
- Modify: `next/tests/world-model-test.lisp`

- [ ] **Step 1: Write the failing tests**

Extend the world-model test package's world-model `:import-from` with
`#:refresh-world-model`, append:

```lisp
(deftest refresh-applies-only-new-events
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path))
          (counter (make-instance 'counting-projection)))
      (emit-event log :note nil)
      (emit-event log :note nil)
      (let ((world-model (build-world-model
                          path
                          :world-model (make-world-model
                                        :projections (list :count counter)))))
        (ok (= 2 (counted-events counter)))
        (emit-event log :note nil)
        (refresh-world-model world-model path)
        (ok (= 3 (counted-events counter)))
        ;; Idempotent: nothing new → nothing re-applied.
        (refresh-world-model world-model path)
        (ok (= 3 (counted-events counter)))))))

(deftest refresh-from-scratch-equals-build
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path))
          (counter (make-instance 'counting-projection)))
      (emit-event log :note nil)
      (let ((world-model (make-world-model
                          :projections (list :count counter))))
        (refresh-world-model world-model path)
        (ok (= 1 (counted-events counter)))))))
```

- [ ] **Step 2: Red** — `refresh-world-model` undefined.

- [ ] **Step 3: Implement**

Append to `next/src/world-model.lisp` (and add `#:refresh-world-model`
to its `:export`):

```lisp
(defun refresh-world-model (world-model log-path)
  "Fold any events at LOG-PATH newer than WORLD-MODEL's last seen seq.
This is the kernel's per-step sync: the environment writes to the log,
the world model catches up from it — the log stays the single source
of truth (spec §8.1). Returns WORLD-MODEL."
  (dolist (event (read-events log-path) world-model)
    (when (> (event-seq event) (world-model-last-seq world-model))
      (update-world-model world-model event))))
```

- [ ] **Step 4: Green** — expect 160 / 0.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/world-model.lisp next/tests/world-model-test.lisp
git add next/src/world-model.lisp next/tests/world-model-test.lisp
git commit -m "feat(next): refresh-world-model incremental sync from the log"
```

---

### Task 5: Facade, acceptance, gated real-LLM smoke, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`

- [ ] **Step 1: Write the failing tests**

Append to `next/tests/main-test.lisp` (facade symbols only):

```lisp
(deftest sp5a-provider-to-verdict-acceptance
  ;; SP5a acceptance: a stub LLM provider drives the review oracle to
  ;; a rejection verdict through the facade alone.
  (let* ((provider (cl-harness-next:make-openai-provider
                    :base-url "http://x/v1" :api-key "k" :model "m"
                    :transport
                    (lambda (url headers body)
                      (declare (ignore url headers body))
                      (values (concatenate
                               'string
                               "{\"choices\":[{\"message\":{\"role\":"
                               "\"assistant\",\"content\":"
                               "\"REJECT: thin tests\"},"
                               "\"finish_reason\":\"stop\"}]}")
                              200 (make-hash-table :test #'equal)))))
         (judge (cl-harness-next:make-judge-fn provider))
         (verdict (cl-harness-next:evaluate
                   (make-instance 'cl-harness-next:review-oracle
                                  :profile '(:id :review-tests
                                             :strictness :strict)
                                  :judge-fn judge)
                   "the tests")))
    (ok (not (cl-harness-next:verdict-pass-p verdict)))
    (ok (search "thin tests" (cl-harness-next:verdict-reason verdict)))))

(deftest real-llm-smoke
  ;; Opt-in (costs tokens): requires CL_HARNESS_LLM_SMOKE=1 plus the
  ;; CL_HARNESS_LLM_* endpoint variables.
  (let ((smoke (uiop:getenv "CL_HARNESS_LLM_SMOKE"))
        (base-url (uiop:getenv "CL_HARNESS_LLM_BASE_URL"))
        (api-key (uiop:getenv "CL_HARNESS_LLM_API_KEY"))
        (model (uiop:getenv "CL_HARNESS_LLM_MODEL")))
    (if (and (equal smoke "1") base-url api-key model)
        (let ((response (cl-harness-next:complete-chat
                         (cl-harness-next:make-openai-provider
                          :base-url base-url :api-key api-key
                          :model model :default-max-tokens 32)
                         (list (cl-harness-next:make-chat-message
                                "user" "Reply with exactly: PONG")))))
          (ok (stringp (cl-harness-next:chat-response-content response))))
        (ok t "skipped real-LLM smoke (set CL_HARNESS_LLM_SMOKE=1 + LLM env vars)"))))
```

- [ ] **Step 2: Red** — facade exports missing.

- [ ] **Step 3: Extend the facade**

Add `:import-from` clauses (after the governor one), preserving all
existing clauses:

```lisp
  (:import-from #:cl-harness-next/src/model
                #:model-provider
                #:openai-compatible-provider
                #:make-openai-provider
                #:make-chat-message
                #:complete-chat
                #:chat-response
                #:chat-response-content
                #:chat-response-role
                #:chat-response-finish-reason
                #:chat-response-prompt-tokens
                #:chat-response-completion-tokens
                #:chat-response-total-tokens
                #:model-error
                #:model-error-message
                #:model-error-type)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:agent-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-thought
                #:action-parse-error
                #:action-parse-error-message)
  (:import-from #:cl-harness-next/src/judge
                #:make-judge-fn)
```

Extend the world-model `:import-from` clause with
`#:refresh-world-model`. Add all of the above plus
`#:refresh-world-model` to `:export` (grouped `;; model`,
`;; action`, `;; judge` comments, refresh under the world-model group).

- [ ] **Step 4: Green** — expect 162 / 0.

- [ ] **Step 5: Force-compile + columns** — `(asdf:compile-system
:cl-harness-next :force t)`, no warnings from next/ sources;
`awk 'length > 100 {print FILENAME": "FNR}' next/src/*.lisp next/tests/*.lisp` — no output.

- [ ] **Step 6: Document** — extend the README next/ subsection's SP
sentence: after "...governor with condition/restart interventions"
insert "; SP5a adds LLM connectivity (OpenAI-compatible provider,
action parser, judge bridge)" before ". It does not affect".

- [ ] **Step 7: Lint and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP5a LLM-connectivity acceptance"
```

---

## Verification checklist (whole sub-project)

- Clean image: fresh worker → load-asd → `run-tests
  cl-harness-next/tests` 162/0 (dexador/usocket may need one
  `ql:quickload` in a fresh image).
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean.

## Deferred (SP5b and later — do NOT build now)

- The kernel loop + control-policy protocol + scripted fix policy
  (SP5b, separate plan).
- Streaming, native Anthropic/Gemini providers (PRD out-of-scope).
- Token-usage budget wiring into the governor (needs kernel
  accounting, SP5b+).
- The legacy test-change-request action variant (returns only if a
  scripted develop policy needs it).
