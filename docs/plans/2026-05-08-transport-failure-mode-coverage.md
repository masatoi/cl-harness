# Transport Failure-Mode Coverage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Add deterministic CI tests for ~10 transport / response-shape / content failure modes (HTTP 401/429/4xx/5xx, read-timeout, connect refused, empty content, length truncation, malformed body, missing choices) plus a manual chaos-probe runner against a real LLM endpoint, surfaced from the v0.5.1 live verification with Qwen/Qwen3.6-35B-A3B.

**Architecture:** New `%classify-llm-failure` helper in `src/model.lisp` maps (HTTP status, body) → reason keyword. `complete-chat` catches `usocket` transport conditions and re-raises a typed `model-error`. Orchestrator catches that and finalises `develop-result :status :error :reason <kw>`. Empty content triggers `:give-up :empty-content` (no re-prompt). New `:reason` slot on `agent-state` / `develop-state` / `develop-result` is opt-in (NIL on success path), kept compatible with existing status keyword consumers. Tests live in new `tests/transport-test.lisp` with stubbed `:transport` injection (no HTTP server). Manual chaos probe at `tools/chaos-probe.lisp`.

**Tech Stack:** SBCL + ASDF `:package-inferred-system`, dexador, usocket, yason, alexandria, rove. Stubbed via `make-openai-provider :transport <fn>`.

---

## Reference design

See `docs/plans/2026-05-08-transport-failure-mode-coverage-design.md` for the full design (background / non-goals / architecture / acceptance criteria).

## Quick reference: failure-mode policy table

| # | Mode | reason keyword | exit status |
|---|---|---|---|
| T1 | HTTP 5xx | `:http-server-error` | `:error` |
| T2 | HTTP 401 | `:auth-failed` | `:error` |
| T3 | HTTP 429 | `:rate-limited` | `:error` |
| T4 | HTTP 4xx other | `:http-client-error` | `:error` |
| T5 | read-timeout (`usocket:timeout-error`) | `:transport-timeout` | `:error` |
| T6 | connect refused (`usocket:connection-refused-error`) | `:transport-unavailable` | `:error` |
| C2 | content NIL/empty | `:empty-content` | `:give-up` |
| C3 | finish_reason length, content non-empty | NIL (forward to parser) | `:passed` or normal flow |
| B1 | body not JSON | `:malformed-response` | `:error` |
| B2 | choices missing or `[]` | `:malformed-response` | `:error` |

---

## Task 1: `%classify-llm-failure` helper + `tests/transport-test.lisp` scaffold

**Files:**
- Modify: `src/model.lisp` — add helper + export
- Create: `tests/transport-test.lisp`
- Modify: `cl-harness.asd` — register the new test system

### Step 1: Add the test scaffold

Create `tests/transport-test.lisp`:

```lisp
;;;; tests/transport-test.lisp
;;;;
;;;; Failure-mode coverage for the LLM transport layer
;;;; (docs/plans/2026-05-08-transport-failure-mode-coverage-design.md).
;;;; Stubs the :transport injection point on MAKE-OPENAI-PROVIDER so
;;;; tests are deterministic and require no real HTTP endpoint.

(defpackage #:cl-harness/tests/transport-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/model
                #:%classify-llm-failure))

(in-package #:cl-harness/tests/transport-test)

(deftest classify-llm-failure-401-is-auth-failed
  (ok (eq :auth-failed (%classify-llm-failure 401 "{}"))))

(deftest classify-llm-failure-429-is-rate-limited
  (ok (eq :rate-limited (%classify-llm-failure 429 "{}"))))

(deftest classify-llm-failure-500-is-http-server-error
  (ok (eq :http-server-error (%classify-llm-failure 500 "{}")))
  (ok (eq :http-server-error (%classify-llm-failure 503 "{}"))))

(deftest classify-llm-failure-404-is-http-client-error
  (ok (eq :http-client-error (%classify-llm-failure 404 "{}")))
  (ok (eq :http-client-error (%classify-llm-failure 400 "{}"))))

(deftest classify-llm-failure-non-json-body-is-malformed-response
  (ok (eq :malformed-response (%classify-llm-failure 200 "not-json"))))

(deftest classify-llm-failure-missing-choices-is-malformed-response
  (ok (eq :malformed-response (%classify-llm-failure 200 "{\"x\":1}"))))

(deftest classify-llm-failure-empty-choices-is-malformed-response
  (ok (eq :malformed-response (%classify-llm-failure 200 "{\"choices\":[]}"))))

(deftest classify-llm-failure-success-shape-returns-nil
  (ok (null (%classify-llm-failure
             200
             "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"))))
```

### Step 2: Register the test system

Read `cl-harness.asd` first via `lisp-read-file`. Add `"cl-harness/tests/transport-test"` to the `cl-harness/tests` `:depends-on` list (alphabetical placement near other test systems is fine).

### Step 3: Run tests — expect FAIL (helper undefined)

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: load failure for the new test package because `%classify-llm-failure` is not yet defined / exported.

### Step 4: Implement the helper

In `src/model.lisp`, add `%classify-llm-failure` near the existing helpers (e.g., after `default-llm-transport`, before `make-openai-provider`):

```lisp
(defparameter +classifiable-status-codes+
  '((401 . :auth-failed)
    (429 . :rate-limited))
  "Direct mapping from a few HTTP status codes to specific reason
keywords. Other statuses fall through to range checks
(:http-server-error / :http-client-error) in %CLASSIFY-LLM-FAILURE.")

(defun %classify-llm-failure (status body)
  "Map (HTTP STATUS, response BODY) into a reason keyword for
MODEL-ERROR. Returns one of:

  :auth-failed         -- HTTP 401
  :rate-limited        -- HTTP 429
  :http-server-error   -- HTTP 500-599
  :http-client-error   -- other HTTP 4xx
  :malformed-response  -- body is not JSON, or shape is wrong
  NIL                  -- response is shaped like a successful chat
                          completion (caller proceeds to parse)

BODY is the raw response string. STATUS may be NIL when the
underlying transport raised before producing a status."
  (cond
    ((and (integerp status)
          (cdr (assoc status +classifiable-status-codes+))))
    ((and (integerp status) (<= 500 status 599))
     :http-server-error)
    ((and (integerp status) (<= 400 status 499))
     :http-client-error)
    ((not (stringp body))
     :malformed-response)
    (t
     (handler-case
         (let* ((parsed (yason:parse body))
                (choices (and (hash-table-p parsed)
                              (gethash "choices" parsed))))
           (cond
             ((not (hash-table-p parsed)) :malformed-response)
             ((or (null choices)
                  (and (listp choices) (null choices))
                  (and (vectorp choices) (zerop (length choices))))
              :malformed-response)
             (t nil)))
       (error () :malformed-response)))))
```

Add `#:%classify-llm-failure` to `src/model.lisp`'s `:export` list (yes, technically internal but exporting lets tests use it without `::`).

### Step 5: Run tests — expect PASS

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: 8 new deftests pass; pre-existing 361 still pass → **369 / 0**.

### Step 6: mallet

```bash
mallet src/model.lisp tests/transport-test.lisp
```

Expected: `✓ No problems found.`

### Step 7: Commit

```bash
git add src/model.lisp tests/transport-test.lisp cl-harness.asd
git commit -m "feat: %classify-llm-failure helper + transport-test scaffold"
```

---

## Task 2: `complete-chat` raises typed `model-error` on transport failure

**Files:**
- Modify: `src/model.lisp` — wrap `default-llm-transport` call inside `complete-chat` with a `handler-case` that maps usocket conditions to typed `model-error`. Also classify on (status, body) before parsing.
- Modify: `tests/transport-test.lisp` — add 6 deftests asserting `complete-chat` signals the right `model-error :kind` for transport / status failures.

### Step 1: Read current `complete-chat`

Use `lisp-read-file` to expand `complete-chat` in `src/model.lisp` (around line 240-280). Note:

- It calls `default-llm-transport` which returns `(values resp-body status resp-headers)` — `default-llm-transport` already catches `http-request-failed` from dexador and absorbs it into the return values (no re-raise).
- After getting the response, it calls `chat-parse-response` on the body.
- `usocket:timeout-error` and `usocket:connection-refused-error` raised by dexador are NOT caught — they propagate.

### Step 2: Add failing transport-error tests

Append to `tests/transport-test.lisp`:

```lisp
;; --- complete-chat error wrapping --------------------------------

(defun %make-stub-provider (transport-fn &key (model "stub"))
  "Build an OPENAI-COMPATIBLE-PROVIDER whose transport is replaced
by TRANSPORT-FN, a 3-arg function (URL HEADERS BODY) returning
(values response-body status response-headers) or raising a
condition."
  (cl-harness/src/model:make-openai-provider
   :base-url "http://stub.invalid/v1"
   :api-key "stub-key"
   :model model
   :transport transport-fn))

(defun %canned-transport (responses)
  "Sequence-of-responses transport. Each call pops one entry. Entry
is either (BODY STATUS HEADERS) tuple or a CONDITION instance to
SIGNAL. Trailing condition entries persist after the list is
exhausted."
  (let ((remaining responses))
    (lambda (url headers body)
      (declare (ignore url headers body))
      (let ((next (or (pop remaining)
                      (error "stub transport exhausted"))))
        (cond
          ((typep next 'condition) (error next))
          ((listp next) (values (first next) (second next)
                                (or (third next) (make-hash-table :test 'equal))))
          (t (error "bad stub response: ~S" next)))))))

(deftest complete-chat-401-signals-auth-failed
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "{\"error\":{\"message\":\"bad key\"}}"
                                401 nil))))))
    (ok (handler-case
            (progn
              (cl-harness/src/model:complete-chat
               provider
               (list (cl-harness/src/model:make-chat-message "user" "hi")))
              nil)
          (cl-harness/src/model:model-error (c)
            (eq :auth-failed (cl-harness/src/model:model-error-type c)))))))

(deftest complete-chat-500-signals-http-server-error
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "{\"error\":{\"message\":\"internal\"}}"
                                500 nil))))))
    (ok (handler-case
            (progn (cl-harness/src/model:complete-chat
                    provider (list (cl-harness/src/model:make-chat-message "user" "hi")))
                   nil)
          (cl-harness/src/model:model-error (c)
            (eq :http-server-error (cl-harness/src/model:model-error-type c)))))))

(deftest complete-chat-429-signals-rate-limited
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "{\"error\":{\"message\":\"slow down\"}}"
                                429 nil))))))
    (ok (handler-case
            (progn (cl-harness/src/model:complete-chat
                    provider (list (cl-harness/src/model:make-chat-message "user" "hi")))
                   nil)
          (cl-harness/src/model:model-error (c)
            (eq :rate-limited (cl-harness/src/model:model-error-type c)))))))

(deftest complete-chat-malformed-body-signals-malformed-response
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (list "<html>oops</html>" 200 nil))))))
    (ok (handler-case
            (progn (cl-harness/src/model:complete-chat
                    provider (list (cl-harness/src/model:make-chat-message "user" "hi")))
                   nil)
          (cl-harness/src/model:model-error (c)
            (eq :malformed-response (cl-harness/src/model:model-error-type c)))))))

(deftest complete-chat-timeout-signals-transport-timeout
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (make-condition 'usocket:timeout-error :socket nil))))))
    (ok (handler-case
            (progn (cl-harness/src/model:complete-chat
                    provider (list (cl-harness/src/model:make-chat-message "user" "hi")))
                   nil)
          (cl-harness/src/model:model-error (c)
            (eq :transport-timeout (cl-harness/src/model:model-error-type c)))))))

(deftest complete-chat-connection-refused-signals-transport-unavailable
  (let ((provider (%make-stub-provider
                   (%canned-transport
                    (list (make-condition 'usocket:connection-refused-error :socket nil))))))
    (ok (handler-case
            (progn (cl-harness/src/model:complete-chat
                    provider (list (cl-harness/src/model:make-chat-message "user" "hi")))
                   nil)
          (cl-harness/src/model:model-error (c)
            (eq :transport-unavailable (cl-harness/src/model:model-error-type c)))))))
```

Add to test file's `:import-from`: `make-chat-message`, `model-error`, `model-error-type`, `complete-chat`, `make-openai-provider`. Or use full package qualifications inline (the deftests above use full qualifications for clarity).

### Step 3: Run tests — expect FAIL

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: 6 new deftests fail (no transport classification yet; complete-chat doesn't catch usocket conditions).

### Step 4: Wrap `complete-chat` with classifier

Modify `complete-chat` in `src/model.lisp` so it:

1. Wraps the `default-llm-transport` call in `handler-case` for `usocket:timeout-error` and `usocket:connection-refused-error`, raising `model-error` with `:kind :transport-timeout` / `:transport-unavailable`.
2. After receiving (body, status), calls `(%classify-llm-failure status body)`. If non-NIL, raises `model-error` with `:kind <reason>` and `:message` derived from the body.
3. Otherwise proceeds to `chat-parse-response` as before.

Also add `:import-from #:usocket #:timeout-error #:connection-refused-error` to `src/model.lisp`'s defpackage. (The system depends transitively on usocket via dexador, so this should resolve at compile time. If usocket isn't directly in `cl-harness/src/model`'s deps, add it to `cl-harness.asd`'s `:depends-on` list — verify by reading the asd first.)

Concrete shape (replace the body of `complete-chat`'s transport call site):

```lisp
;; Inside the existing complete-chat method:
(multiple-value-bind (resp-body status resp-headers)
    (handler-case
        (funcall (or (provider-transport provider) #'default-llm-transport)
                 url headers body)
      (timeout-error ()
        (error 'model-error
               :kind :transport-timeout
               :message "LLM transport timed out reading the response"))
      (connection-refused-error ()
        (error 'model-error
               :kind :transport-unavailable
               :message "LLM endpoint refused connection")))
  (declare (ignore resp-headers))
  (let ((reason (%classify-llm-failure status resp-body)))
    (when reason
      (error 'model-error
             :kind reason
             :message (format nil "LLM transport failure: ~A (status=~A)"
                              reason status)
             :raw resp-body)))
  (chat-parse-response resp-body))
```

(The exact structure depends on how `complete-chat` currently composes its request and dispatches transport. Read it first; the patch should be minimal — just wrap the existing transport call site.)

### Step 5: Run tests — expect PASS

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **375 / 0** (369 from Task 1 + 6 new).

### Step 6: mallet + commit

```bash
mallet src/model.lisp tests/transport-test.lisp
git add src/model.lisp tests/transport-test.lisp
git commit -m "feat: complete-chat raises typed model-error on transport / HTTP failure"
```

---

## Task 3: `:reason` slot on agent-state / develop-state / develop-result

**Files:**
- Modify: `src/agent.lisp` — add `:reason` slot + reader to `agent-state`.
- Modify: `src/state.lisp` — add `:reason` slot + reader + setter to `develop-state`.
- Modify: `src/orchestrator.lisp` — add `:reason` slot + reader to `develop-result`.
- Modify: `src/main.lisp` — re-export the three readers.
- Modify: `tests/agent-test.lisp` — 1 deftest asserting `agent-state-reason` defaults to NIL.
- Modify: `tests/state-test.lisp` — 1 deftest asserting `develop-state-reason` defaults to NIL.
- Modify: `tests/orchestrator-test.lisp` — 1 deftest asserting `develop-result-reason` defaults to NIL.

### Step 1: Failing tests

Append to each test file (3 deftests total):

```lisp
;; tests/agent-test.lisp
(deftest agent-state-reason-defaults-to-nil
  (let ((s (cl-harness/src/agent:make-agent-state-for-tests)))
    (ok (null (cl-harness/src/agent:agent-state-reason s)))))

;; tests/state-test.lisp
(deftest develop-state-reason-defaults-to-nil
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests")))
    (ok (null (cl-harness/src/state:develop-state-reason s)))))

;; tests/orchestrator-test.lisp
(deftest develop-result-reason-defaults-to-nil
  (let ((r (make-instance 'cl-harness/src/orchestrator:develop-result
                          :status :passed
                          :final-plan nil
                          :step-results nil
                          :replan-count 0
                          :limit-hit nil
                          :abstraction-ledger nil
                          :integration-issues nil
                          :develop-state nil)))
    (ok (null (cl-harness/src/orchestrator:develop-result-reason r)))))
```

(Adjust the `make-instance` call's keyword args to match the actual `develop-result` defclass — read `src/orchestrator.lisp` to confirm the slot names. The constructor pattern may differ.)

### Step 2: Run — expect FAIL (readers undefined)

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: 3 new deftests fail (or load-fail) on undefined `agent-state-reason` / `develop-state-reason` / `develop-result-reason`.

### Step 3: Add the slots

In each defclass, add:

```lisp
(reason :initarg :reason :initform nil :reader <prefix>-reason
        :documentation "Failure-mode classification keyword (one of
:auth-failed, :rate-limited, :http-server-error, :http-client-error,
:transport-timeout, :transport-unavailable, :malformed-response,
:empty-content), or NIL on the success path. Set by the orchestrator
when STATUS is :error or :give-up.")
```

Where `<prefix>` is `agent-state` / `develop-state` / `develop-result` respectively.

For `develop-state`, also add a setter `(defun develop-state-set-reason (state reason) ...)` and a public `(setf develop-state-reason)` so the orchestrator can mutate it.

For `agent-state`, expose an `:accessor` so the agent loop can `setf` it. (Same pattern as `agent-state-status`.)

For `develop-result`, the slot is set at construction time only.

### Step 4: Update `:export` lists

- `src/agent.lisp` defpackage: `#:agent-state-reason`
- `src/state.lisp` defpackage: `#:develop-state-reason`, `#:develop-state-set-reason` (if you add the function)
- `src/orchestrator.lisp` defpackage: `#:develop-result-reason`
- `src/main.lisp` defpackage: re-export the three readers via `:import-from` + `:export` (mirror how other readers are re-exported there).

### Step 5: Run tests — expect PASS

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **378 / 0** (375 from Task 2 + 3 new).

### Step 6: mallet + commit

```bash
mallet src/agent.lisp src/state.lisp src/orchestrator.lisp src/main.lisp \
       tests/agent-test.lisp tests/state-test.lisp tests/orchestrator-test.lisp
git add -A
git commit -m "feat: :reason slot on agent-state / develop-state / develop-result"
```

---

## Task 4: Orchestrator catches `model-error` → `develop-result-reason`

**Files:**
- Modify: `src/orchestrator.lisp` — wrap the planner-fn call AND the run-agent invocation with `handler-case` for `model-error`. On catch, set `develop-state-status :error`, `develop-state-reason (model-error-type c)`, and exit the loop. Also extend `develop-result` construction to read `develop-state-reason`.
- Modify: `tests/transport-test.lisp` — add 4 end-to-end deftests asserting `develop-result-reason` for T1 (5xx), T2 (401), T3 (429), B1 (malformed).

### Step 1: Read orchestrator's `develop` function

`lisp-read-file src/orchestrator.lisp` with `name_pattern="^develop$"`. Note where:
- `planner-fn` is called (around lines 740, 800).
- `execute-plan` invokes `run-agent`.
- `develop-result` is constructed.

### Step 2: Failing transport-test deftests (end-to-end)

Append to `tests/transport-test.lisp`:

```lisp
;; --- end-to-end develop with stub transport ---------------------

(defun %make-stub-runner (canned-statuses)
  "Stub run-fn for cl-harness:develop that returns STATUS keywords
in sequence. Bypasses any agent-state introspection."
  (let ((remaining (cons canned-statuses nil)))
    (lambda (config logger &key &allow-other-keys)
      (declare (ignore config logger))
      (let ((status (or (pop (car remaining))
                        :give-up)))
        (cl-harness/src/agent:make-agent-state-for-tests :status status)))))

(deftest develop-with-401-transport-yields-error-auth-failed
  ;; The first planner-fn call hits HTTP 401 via the stubbed
  ;; provider; develop should terminate :error :auth-failed.
  (let* ((project-root (uiop:temporary-directory))
         (provider (%make-stub-provider
                    (%canned-transport
                     (list (list "{\"error\":{\"message\":\"bad key\"}}"
                                 401 nil)))))
         (result (cl-harness:develop
                  :goal "test" :project-root (namestring project-root)
                  :system "demo" :test-system "demo/tests"
                  :provider provider)))
    (ok (eq :error (cl-harness:develop-result-status result)))
    (ok (eq :auth-failed (cl-harness:develop-result-reason result)))))

(deftest develop-with-500-transport-yields-error-http-server-error
  ;; (similar shape, status 500)
  ...)

(deftest develop-with-429-transport-yields-error-rate-limited ...)

(deftest develop-with-malformed-body-yields-error-malformed-response ...)
```

(Fill in the omitted bodies by analogy to the 401 case. The `cl-harness:develop` entry point is the public CLI helper; if its signature requires more kwargs or doesn't accept `:provider`, use `cl-harness/src/orchestrator:develop` directly with `:provider` and a `:planner-fn` that calls `complete-chat` against the stubbed provider.)

If `cl-harness:develop` (the CLI wrapper) is hard to drive end-to-end without an `mcp-client`, drive `cl-harness/src/orchestrator:develop` directly — that's lower-level and accepts `:provider`, `:mcp-client`, `:planner-fn`, `:run-fn` kwargs. For these tests:
- `:planner-fn` can be the real `cl-harness/src/planner:plan-development` (which calls `complete-chat`) OR a thin shim that calls `complete-chat` against the stub provider.
- `:run-fn` and `:explore-fn` can be no-op stubs that won't be reached because the planner call fails first.
- `:mcp-client` can be a placeholder that's never used.

### Step 3: Run — expect FAIL

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: 4 new deftests fail because the orchestrator doesn't yet catch `model-error`.

### Step 4: Wrap orchestrator's planner call

In `src/orchestrator.lisp:develop`, wrap each `(funcall planner-fn …)` site with:

```lisp
(handler-case
    (funcall planner-fn ...)
  (cl-harness/src/model:model-error (c)
    (setf (develop-state-status state) :error
          (slot-value state 'reason)
          (cl-harness/src/model:model-error-type c))
    (return-from develop
      (make-instance 'develop-result
                     :status :error
                     :reason (cl-harness/src/model:model-error-type c)
                     :final-plan nil
                     :step-results (develop-state-step-results state)
                     :replan-count (develop-state-replan-count state)
                     :limit-hit nil
                     :abstraction-ledger nil
                     :integration-issues nil
                     :develop-state state))))
```

(Adjust slot names / `develop-result` ctor args to match the actual class shape. Use the existing helper if one exists for "construct develop-result from state".)

Also wrap the run-agent invocation site inside `execute-plan`'s loop (or at `%execute-step`'s call site) so a `model-error` raised inside an LLM call from the implement loop also lands in `:error :reason`.

### Step 5: Update `develop-result` constructor

`develop-result` needs to accept `:reason` at construction. If the existing class already exposes `:reason` slot from Task 3, this is just adding `:reason (develop-state-reason state)` (or the catched reason) at the construction site(s).

### Step 6: Run tests — expect PASS

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **382 / 0** (378 + 4 new).

### Step 7: mallet + commit

```bash
mallet src/orchestrator.lisp tests/transport-test.lisp
git add src/orchestrator.lisp tests/transport-test.lisp
git commit -m "feat: orchestrator catches model-error -> develop-result-reason"
```

---

## Task 5: T5 / T6 transport-condition end-to-end + C2 empty-content

**Files:**
- Modify: `src/agent.lisp` — when `complete-chat` returns a `chat-response` with empty/NIL content, set `agent-state-status :give-up` and `agent-state-reason :empty-content`. Exit the loop without further LLM calls.
- Modify: `tests/transport-test.lisp` — 3 deftests: T5, T6, C2.

### Step 1: Failing tests

```lisp
(deftest develop-with-timeout-yields-error-transport-timeout
  (let* ((project-root (uiop:temporary-directory))
         (provider (%make-stub-provider
                    (%canned-transport
                     (list (make-condition 'usocket:timeout-error
                                           :socket nil)))))
         (result (cl-harness:develop ...)))
    (ok (eq :error (cl-harness:develop-result-status result)))
    (ok (eq :transport-timeout (cl-harness:develop-result-reason result)))))

(deftest develop-with-connection-refused-yields-error-transport-unavailable
  ...)

(deftest develop-with-empty-content-yields-give-up-empty-content
  ;; Stub provider returns 200 with valid shape but content=NIL.
  ;; The planner call should succeed transport-wise, but agent loop
  ;; (or planner) detects empty content and sets :give-up.
  ;; Since the planner reads content directly, this surfaces there:
  ;; cl-harness:develop's planner-fn raises planner-error; orchestrator
  ;; should map planner-error-on-empty into :give-up :empty-content too.
  ;;
  ;; Alternative if test scoping is awkward: drive run-agent directly
  ;; with stub provider returning empty content and assert the loop
  ;; exits :give-up :empty-content.
  ...)
```

The C2 test may need to drive `run-agent` directly (not full `develop`) because the planner-side behavior on empty content is a different code path than the agent-loop side. If the test gets too tangled, split C2 into:
- C2a: planner sees empty content → planner-error path → orchestrator maps to `:give-up :empty-content` OR `:error :empty-content`.
- C2b: agent-loop sees empty content → `:give-up :empty-content`.

Pick one path per the design's intent (immediate `:give-up :empty-content`). Document the choice in the deftest comment.

### Step 2: Run — expect FAIL

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: 3 new deftests fail (no empty-content handling yet).

### Step 3: Add empty-content handling in agent loop

In `src/agent.lisp`'s `step-turn` (or wherever `complete-chat`'s return value is consumed), check:

```lisp
(let ((response (complete-chat ...)))
  (let ((content (cl-harness/src/model:chat-response-content response)))
    (when (or (null content) (zerop (length content)))
      (setf (agent-state-status state) :give-up
            (agent-state-reason state) :empty-content)
      (return-from step-turn state))
    ;; ...continue with parse-action on content...))
```

For the planner side, a similar guard in `src/planner.lisp`'s `plan-development` raises `planner-error` (or a new `planner-empty-content-error`) when content is empty. The orchestrator's existing `model-error` catch from Task 4 doesn't catch `planner-error`, so add a new handler-case branch:

```lisp
(planner-error (c)
  (cond
    ((search "empty content" (planner-error-message c))
     (setf (develop-state-status state) :give-up
           (slot-value state 'reason) :empty-content)
     ...)
    (t (return-from develop ... :error :reason :planner-failed ...))))
```

(Or a cleaner approach: have `plan-development` raise `model-error :kind :empty-content` directly so the existing handler catches it.)

### Step 4: Run tests — expect PASS

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **385 / 0** (382 + 3 new).

### Step 5: mallet + commit

```bash
mallet src/agent.lisp src/planner.lisp src/orchestrator.lisp tests/transport-test.lisp
git add -A
git commit -m "feat: T5 + T6 + C2 empty-content -> :give-up :empty-content"
```

---

## Task 6: C3 length-truncation deftest + report formatters render `:reason`

**Files:**
- Modify: `tests/transport-test.lisp` — 1 deftest: C3 (finish_reason length, content non-empty → forwarded to parser, runs to completion or normal flow).
- Modify: `src/cli.lisp` — `format-develop-report` shows `:reason` next to status when non-NIL.
- Modify: `src/report.lisp` — `format-develop-state-report` shows `:reason` in its Goal section header or Status row.
- Modify: `tests/agent-test.lisp` or `tests/orchestrator-test.lisp` — 1 deftest asserting the formatter output contains the reason when set.

### Step 1: Failing tests

C3 deftest:

```lisp
(deftest develop-with-length-truncation-forwards-content
  ;; Stub returns content="partial..." with finish_reason="length".
  ;; The agent loop should NOT fast-path :give-up — content is
  ;; forwarded to parse-action. Whether parse-action succeeds or
  ;; fails is a separate concern; the test asserts the reason slot
  ;; is NOT set to :empty-content (i.e. truncation alone doesn't
  ;; trigger the empty-content path).
  ...)
```

Formatter test:

```lisp
(deftest format-develop-report-renders-reason-when-set
  (let ((result (make-instance 'cl-harness/src/orchestrator:develop-result
                               :status :error
                               :reason :auth-failed
                               ...)))
    (let ((text (cl-harness:format-develop-report result)))
      (ok (search "auth-failed" text)))))
```

### Step 2: Run — expect FAIL

Expected: formatters don't render reason; C3 deftest may pass already if no fast-path exists (verify by reading the agent loop).

### Step 3: Implement formatter changes

In `src/cli.lisp:format-develop-report`, find the line that prints `Status: ...` and append the reason when present:

```lisp
(format s "Status:           ~A~@[ (reason: ~A)~]~%"
        (develop-result-status result)
        (develop-result-reason result))
```

In `src/report.lisp:format-develop-state-report`, similar treatment for the Goal / Status header.

For C3: confirm by reading the agent loop that empty-content guard checks `(zerop (length content))` (so non-empty truncated content slips through unchanged). If a length-specific guard exists that skips parse-action on truncation, remove it.

### Step 4: Run tests — expect PASS

Expected: **387 / 0** (385 + 2 new).

### Step 5: mallet + commit

```bash
mallet src/cli.lisp src/report.lisp tests/transport-test.lisp \
       tests/agent-test.lisp tests/orchestrator-test.lisp
git add -A
git commit -m "feat: report formatters render :reason; C3 length truncation forwards content"
```

---

## Task 7: `tools/chaos-probe.lisp` runner

**Files:**
- Create: `tools/chaos-probe.lisp`

### Step 1: Author the script

```lisp
;;;; tools/chaos-probe.lisp
;;;;
;;;; Manual end-to-end failure-mode probe against a real LLM endpoint.
;;;; Verifies that cl-harness:develop terminates with the expected
;;;; :error/:reason for each of four deliberately-broken scenarios.
;;;;
;;;; Usage:
;;;;   CL_HARNESS_LLM_BASE_URL=...    \
;;;;   CL_HARNESS_LLM_API_KEY=...     \
;;;;   CL_HARNESS_LLM_MODEL=...       \
;;;;   sbcl --noinform --non-interactive --load tools/chaos-probe.lisp

(asdf:load-asd
 (merge-pathnames "../cl-harness.asd"
                  (make-pathname :defaults *load-pathname* :name nil :type nil)))
(ql:quickload :cl-harness :silent t)

(defun %scenario-pass-p (label expected-reason result)
  (let ((status (cl-harness:develop-result-status result))
        (reason (cl-harness:develop-result-reason result)))
    (let ((pass (and (eq :error status)
                     (eq expected-reason reason))))
      (format t "[~:[FAIL~;PASS~]] ~A: status=~A reason=~A (expected ~A)~%"
              pass label status reason expected-reason)
      pass)))

(defun %p1-empty-content ()
  ;; max-tokens=1 forces content=null on most models
  (let ((sandbox (uiop:tmpize-pathname
                  (merge-pathnames "chaos-probe-p1/"
                                   (uiop:default-temporary-directory)))))
    (uiop:ensure-all-directories-exist (list sandbox))
    (let ((result (cl-harness:develop
                   :goal "Add a greet function under package greet."
                   :project-root (namestring sandbox)
                   :system "greet" :test-system "greet/tests"
                   :test-file (namestring (merge-pathnames "main-test.lisp" sandbox))
                   :max-tokens 1)))
      (%scenario-pass-p "P1 empty-content" :empty-content result))))

(defun %p3-transport-unavailable ()
  (let ((result (cl-harness:develop
                 :goal "anything"
                 :project-root (namestring (uiop:default-temporary-directory))
                 :system "x" :test-system "x/tests"
                 :test-file "/tmp/chaos-probe-p3.lisp"
                 :base-url "http://127.0.0.1:9999/v1")))
    (%scenario-pass-p "P3 transport-unavailable" :transport-unavailable result)))

(defun %p4-auth-failed ()
  (let ((result (cl-harness:develop
                 :goal "anything"
                 :project-root (namestring (uiop:default-temporary-directory))
                 :system "x" :test-system "x/tests"
                 :test-file "/tmp/chaos-probe-p4.lisp"
                 :api-key "definitely-not-a-real-key")))
    (%scenario-pass-p "P4 auth-failed" :auth-failed result)))

(let ((pass-p1 (handler-case (%p1-empty-content) (error () nil)))
      ;; P2 (length truncation) is hard to make deterministic across
      ;; models — skip in the default chaos probe; document for manual
      ;; ad-hoc verification.
      (pass-p3 (handler-case (%p3-transport-unavailable) (error () nil)))
      (pass-p4 (handler-case (%p4-auth-failed) (error () nil))))
  (let ((all (and pass-p1 pass-p3 pass-p4)))
    (format t "~%[chaos-probe] overall ~:[FAIL~;PASS~]~%" all)
    (uiop:quit (if all 0 1))))
```

### Step 2: Verify the script loads

```bash
sbcl --noinform --non-interactive --load tools/chaos-probe.lisp
```

(May fail because no real LLM is configured — that's fine for now. The script's own load-time errors are what we want to catch in this step.)

### Step 3: Commit

```bash
git add tools/chaos-probe.lisp
git commit -m "feat: tools/chaos-probe.lisp — manual real-LLM failure-mode runner"
```

---

## Task 8: Lint + force-compile + docs + final review + merge

### Step 1: Mallet sweep

```bash
mallet src/model.lisp src/agent.lisp src/state.lisp src/orchestrator.lisp \
       src/cli.lisp src/report.lisp src/main.lisp \
       tests/transport-test.lisp tests/agent-test.lisp \
       tests/state-test.lisp tests/orchestrator-test.lisp \
       tools/chaos-probe.lisp
```

Expected: `✓ No problems found.`

### Step 2: Force-compile

```bash
sbcl --noinform --non-interactive \
  --eval '(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness.asd")' \
  --eval '(asdf:compile-system :cl-harness :force t)' \
  --eval '(quit)' 2>&1 | grep -E "WARNING|ERROR" | head
```

Expected: empty (no new warnings beyond pre-existing ASDF `perform` redefinition).

### Step 3: Full test sweep

```bash
sbcl --noinform --non-interactive \
  --eval '(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness.asd")' \
  --eval '(asdf:test-system :cl-harness)' \
  --eval '(quit)' 2>&1 | tail -10
```

Expected: ~387 / 0 (361 baseline + ~26 new transport + reason + formatter tests, depending on exact splits; design says ~371, plan adds a few extra targeted tests). Same 4 pre-existing develop-bench-test failures under shell rove.

### Step 4: Docs §14 footnote

Append to `docs/context-management.md` §14 trailing prose, after the existing Phase G/H/I follow-up paragraph:

```markdown
Transport failure-mode coverage follow-up (landed YYYY-MM-DD):
v0.5.1 のライブ verification で発覚した dexador 10s timeout バグの
ような transport-layer 故障モードを CI で網羅できるよう、新ファイル
`tests/transport-test.lisp` に 26+ deftests を追加。`%classify-llm-
failure` (model.lisp) が HTTP 401/429/4xx/5xx と response shape 異常
を reason keyword に分類し、`complete-chat` は usocket transport
condition (timeout / connection-refused) を typed `model-error` に
wrap する。orchestrator は `model-error` を catch して
`develop-result :reason` に伝播。`agent-state` / `develop-state` /
`develop-result` に opt-in `:reason` slot を追加 (NIL on success path、
classification keyword on :error/:give-up)。empty-content は即
`:give-up :empty-content` で安定停止。`tools/chaos-probe.lisp` は
4 シナリオ (max-tokens=1 / unreachable URL / bad API key) を
real LLM endpoint に投げる手動 runner。
```

### Step 5: Release notes

Decide whether this warrants v0.5.2 or rides into a future release.
This plan adds:
- New public reader `develop-result-reason` (and friends).
- New status reason keywords surfaced in reports.
- Behavioural change: empty content now exits `:give-up :empty-content`
  instead of `:error` from a downstream parse failure.

If you want a v0.5.2 tag now: write `docs/release-notes/v0.5.2.md`,
bump `cl-harness.asd` `:version`, commit, tag, push, `gh release
create`. Otherwise the work rides into the next minor release.

### Step 6: Final review

Dispatch `superpowers:code-reviewer` over the whole branch:
`git diff <base>..HEAD`. Checklist:

- `:reason` slot is opt-in (NIL on success path); no existing test
  changed expectations.
- `model-error :kind` keyword set is exhaustive and matches the
  design table.
- `complete-chat`'s `handler-case` covers timeout + connection-
  refused at minimum; document any other usocket conditions caught.
- `tests/transport-test.lisp` covers all 10 design failure modes
  end-to-end (or via direct provider/agent calls when full develop
  is impractical).
- `tools/chaos-probe.lisp` exits 0 on all-pass, 1 on any-fail; no
  external state side-effects.
- mallet clean; force-compile clean.

### Step 7: Merge

`superpowers:finishing-a-development-branch` → `--no-ff` merge to
main. Push. (Optionally tag v0.5.2.)

---

## Verification checklist

- [ ] `%classify-llm-failure` returns `nil` on a well-formed 200 body
      and the right keyword for each of the 6 design rows.
- [ ] `complete-chat` raises `model-error :kind …` for each transport
      / HTTP / shape failure under stub `:transport`.
- [ ] `develop-result-reason`, `agent-state-reason`,
      `develop-state-reason` are NIL on `:passed` runs and non-NIL on
      `:error` / `:give-up :empty-content` runs.
- [ ] `tests/transport-test.lisp` covers T1-T6, C2, C3, B1, B2 with
      end-to-end stubs through `develop` (or smaller drivers where
      `develop` is impractical).
- [ ] Empty content fast-paths to `:give-up :empty-content` without
      raising.
- [ ] Length truncation with non-empty content forwards to
      `parse-action`; the reason slot stays NIL when parse succeeds.
- [ ] `format-develop-report` and `format-develop-state-report`
      surface `:reason` next to status when set.
- [ ] `tools/chaos-probe.lisp` runs to completion without uncaught
      conditions (manual run; passes against Qwen3.6 SGLang for at
      least P3 + P4; P1 may behave differently per model).
- [ ] mallet clean, force-compile clean.
- [ ] No regression in pre-existing 361 tests.
- [ ] §14 docs updated; release notes drafted (or deferred).

---

## Acceptance criteria

The phase is complete when:

1. ~26 new deftests land in `tests/transport-test.lisp` (and the
   per-task targeted tests in agent / state / orchestrator / cli /
   report files); total CI count 361 → ~387.
2. `model-error :kind` covers the 8 reason keywords end-to-end
   (`:auth-failed`, `:rate-limited`, `:http-server-error`,
   `:http-client-error`, `:transport-timeout`,
   `:transport-unavailable`, `:malformed-response`,
   `:empty-content`).
3. `develop-result-reason` is non-NIL on `:error` / `:give-up
   :empty-content` runs and NIL on `:passed`.
4. mallet and force-compile clean across all touched files.
5. `tools/chaos-probe.lisp` runs to completion against a real LLM
   endpoint and emits `[PASS]` / `[FAIL]` per scenario.
6. The dexador timeout regression case (T5) now has automated
   coverage that would have caught the v0.5.0 bug.
7. README / docs note the new public reader (or `:reason` is left
   internal for now if the team prefers not to widen the public
   surface — design says re-export, so default to that).
