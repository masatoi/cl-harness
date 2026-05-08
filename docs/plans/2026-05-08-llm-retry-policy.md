# LLM Retry Policy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Add a minimal automatic retry to `complete-chat` so genuinely transient LLM failures (`:http-server-error`, `:rate-limited`, `:transport-timeout`) recover without bothering the caller. 1 retry, no backoff, opt-out via `:retry-p nil` on `make-openai-provider`.

**Architecture:** New `+retriable-reasons+` defparameter + new `:retry-p` boolean slot on `openai-compatible-provider` (default T). The existing `complete-chat` body (transport call → classifier → `chat-parse-response`) gets wrapped in a 2-attempt retry loop that catches `model-error` and re-tries when `provider-retry-p` is true AND the kind is in `+retriable-reasons+`. All other failure modes (auth-failed, http-client-error, malformed-response, transport-unavailable, empty-content) raise immediately as today.

**Tech Stack:** SBCL + ASDF `:package-inferred-system`, dexador, usocket, yason, alexandria, rove. Stubbed via `make-openai-provider :transport <fn>` (existing `%canned-transport` helper from Task 2).

---

## Reference design

`docs/plans/2026-05-08-llm-retry-policy-design.md`. Decisions:
- α (1 retry, no backoff, max 2 attempts)
- A (3 retriable reasons: `:http-server-error`, `:rate-limited`, `:transport-timeout`)
- (b) (in `complete-chat`, with `:retry-p` boolean kwarg)

## Surface delta

- `src/model.lisp`: + 1 defparameter, + 1 slot, + 1 kwarg, + 1 export, + retry loop wrapping existing `complete-chat` body.
- `tests/transport-test.lisp`: + 6 deftests + small introspection helper for `%canned-transport`.

CI count: 391 → **397** (+6).

---

## Task 1: `+retriable-reasons+` defparameter + retry loop in `complete-chat` (TDD)

**Files:**
- Modify: `src/model.lisp` — add defparameter, add `retry-p` slot to `openai-compatible-provider`, wire `:retry-p` kwarg in `make-openai-provider`, wrap `complete-chat` body in retry loop, export `provider-retry-p` reader.
- Modify: `tests/transport-test.lisp` — add 6 deftests + 1 helper.

### Step 1: Helper for transport call-count introspection

Append to `tests/transport-test.lisp` (top of the test file's helper block, alongside the existing `%canned-transport`):

```lisp
;; --- retry policy: introspectable transport stub ---------------

(defun %counted-canned-transport (responses)
  "Like %CANNED-TRANSPORT but ALSO returns a thunk reporting how
many entries are still un-consumed. Returns (values transport-fn
remaining-thunk).

Used by tests that need to assert COMPLETE-CHAT did or did not
retry. After the call: when retry didn't fire, the second canned
entry remains in the queue."
  (let ((remaining responses))
    (values
     (lambda (url headers body)
       (declare (ignore url headers body))
       (let ((next (or (pop remaining)
                       (error "stub transport exhausted"))))
         (cond
           ((typep next 'condition) (error next))
           ((listp next)
            (values (first next) (second next)
                    (or (third next) (make-hash-table :test 'equal))))
           (t (error "bad stub response: ~S" next)))))
     (lambda () (length remaining)))))
```

### Step 2: Failing tests — append 6 deftests

Append at the end of `tests/transport-test.lisp`:

```lisp
;; --- retry policy ----------------------------------------------

(defun %success-body (content)
  (format nil
          "{\"choices\":[{\"message\":{\"content\":\"~A\",\"role\":\"assistant\"},\"finish_reason\":\"stop\"}]}"
          content))

(defun %error-body (message)
  (format nil "{\"error\":{\"message\":\"~A\"}}" message))

(deftest complete-chat-retries-once-on-http-server-error-and-succeeds
  (multiple-value-bind (transport remaining)
      (%counted-canned-transport
       (list (list (%error-body "internal") 500 nil)
             (list (%success-body "ok") 200 nil)))
    (let* ((provider (%make-stub-provider transport))
           (response (cl-harness/src/model:complete-chat
                      provider
                      (list (cl-harness/src/model:make-chat-message
                             "user" "hi")))))
      (ok (typep response 'cl-harness/src/model:chat-response))
      (ok (string= "ok"
                   (cl-harness/src/model:chat-response-content response)))
      (ok (zerop (funcall remaining))
          "both canned entries consumed by initial+retry"))))

(deftest complete-chat-retries-once-on-rate-limited-and-succeeds
  (multiple-value-bind (transport remaining)
      (%counted-canned-transport
       (list (list (%error-body "slow down") 429 nil)
             (list (%success-body "ok") 200 nil)))
    (let* ((provider (%make-stub-provider transport))
           (response (cl-harness/src/model:complete-chat
                      provider
                      (list (cl-harness/src/model:make-chat-message
                             "user" "hi")))))
      (ok (string= "ok"
                   (cl-harness/src/model:chat-response-content response)))
      (ok (zerop (funcall remaining))))))

(deftest complete-chat-retries-once-on-timeout-and-succeeds
  (multiple-value-bind (transport remaining)
      (%counted-canned-transport
       (list (make-condition 'usocket:timeout-error :socket nil)
             (list (%success-body "ok") 200 nil)))
    (let* ((provider (%make-stub-provider transport))
           (response (cl-harness/src/model:complete-chat
                      provider
                      (list (cl-harness/src/model:make-chat-message
                             "user" "hi")))))
      (ok (string= "ok"
                   (cl-harness/src/model:chat-response-content response)))
      (ok (zerop (funcall remaining))))))

(deftest complete-chat-raises-after-retry-exhausted
  (multiple-value-bind (transport remaining)
      (%counted-canned-transport
       (list (list (%error-body "down") 500 nil)
             (list (%error-body "still down") 500 nil)))
    (let ((provider (%make-stub-provider transport)))
      (ok (handler-case
              (progn
                (cl-harness/src/model:complete-chat
                 provider
                 (list (cl-harness/src/model:make-chat-message
                        "user" "hi")))
                nil)
            (cl-harness/src/model:model-error (c)
              (eq :http-server-error
                  (cl-harness/src/model:model-error-type c)))))
      (ok (zerop (funcall remaining))
          "both attempts consumed; second still failed"))))

(deftest complete-chat-does-not-retry-non-retriable-reasons
  (multiple-value-bind (transport remaining)
      (%counted-canned-transport
       (list (list (%error-body "bad key") 401 nil)
             ;; second entry should remain un-consumed
             (list (%success-body "ok") 200 nil)))
    (let ((provider (%make-stub-provider transport)))
      (ok (handler-case
              (progn (cl-harness/src/model:complete-chat
                      provider
                      (list (cl-harness/src/model:make-chat-message
                             "user" "hi")))
                     nil)
            (cl-harness/src/model:model-error (c)
              (eq :auth-failed
                  (cl-harness/src/model:model-error-type c)))))
      (ok (= 1 (funcall remaining))
          "no retry on :auth-failed; second entry left in queue"))))

(deftest complete-chat-retry-p-nil-disables-retry
  (multiple-value-bind (transport remaining)
      (%counted-canned-transport
       (list (list (%error-body "down") 500 nil)
             (list (%success-body "ok") 200 nil)))
    (let ((provider (cl-harness/src/model:make-openai-provider
                     :base-url "http://stub.invalid/v1"
                     :api-key "k" :model "demo"
                     :retry-p nil
                     :transport transport)))
      (ok (handler-case
              (progn (cl-harness/src/model:complete-chat
                      provider
                      (list (cl-harness/src/model:make-chat-message
                             "user" "hi")))
                     nil)
            (cl-harness/src/model:model-error (c)
              (eq :http-server-error
                  (cl-harness/src/model:model-error-type c)))))
      (ok (= 1 (funcall remaining))
          "retry-p=nil suppresses retry; second entry left in queue"))))
```

### Step 3: Run — expect FAIL

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: 6 new deftests fail (no retry logic; `:retry-p` slot doesn't exist on provider).

Symptoms include:
- `complete-chat-retries-once-on-http-server-error-and-succeeds` raises `:http-server-error` instead of returning a chat-response.
- `complete-chat-retry-p-nil-disables-retry` errors on `:retry-p` unknown initarg to `make-openai-provider`.

### Step 4: Add `+retriable-reasons+` defparameter

In `src/model.lisp`, near the existing `+classifiable-status-codes+` defparameter (around lines 136+ post-Task-1 of failure-mode-coverage), add:

```lisp
(defparameter +retriable-reasons+
  '(:http-server-error :rate-limited :transport-timeout)
  "MODEL-ERROR :KIND values that COMPLETE-CHAT retries once when the
provider's RETRY-P slot is true. The other reasons are deliberately
NOT retried: :AUTH-FAILED and :HTTP-CLIENT-ERROR are caller-side
issues; :MALFORMED-RESPONSE and :TRANSPORT-UNAVAILABLE are
borderline-transient and excluded until production data shows
otherwise; :EMPTY-CONTENT is already mapped to :GIVE-UP upstream
and never surfaces from COMPLETE-CHAT directly.")
```

### Step 5: Add `retry-p` slot to `openai-compatible-provider`

Find the `defclass openai-compatible-provider` (around line 70 of `src/model.lisp`). Append a new slot at the end of the slot list, before the closing `)` and any `(:documentation ...)` clause. Mirror the `transport` slot's style:

```lisp
(retry-p :initarg :retry-p :initform t :reader provider-retry-p
         :documentation "When non-NIL (default), COMPLETE-CHAT
retries once on transient MODEL-ERRORs (those whose :KIND is in
+RETRIABLE-REASONS+). NIL disables retry entirely — used by
chaos-probe runs and tests that intentionally trigger failures
to keep the run time bounded.")
```

### Step 6: Add `:retry-p` kwarg to `make-openai-provider`

Find `defun make-openai-provider` (around line 180). Add `:retry-p t` to the kwarg list and `:retry-p retry-p` to the `make-instance` call:

```lisp
(defun make-openai-provider (&key base-url api-key model
                                  temperature max-tokens
                                  reasoning-effort extra-body
                                  transport
                                  (retry-p t))           ; NEW
  "Construct an OPENAI-COMPATIBLE-PROVIDER (PRD §10.2)."
  ;; ... existing body ...
  (make-instance 'openai-compatible-provider
                 :base-url base-url :api-key api-key :model model
                 :default-temperature temperature
                 :default-max-tokens max-tokens
                 :default-reasoning-effort reasoning-effort
                 :default-extra-body extra-body
                 :retry-p retry-p                         ; NEW
                 :transport (or transport #'default-llm-transport)))
```

### Step 7: Export `provider-retry-p`

In `src/model.lisp`'s `defpackage` `:export` list, add `#:provider-retry-p` near the existing `#:provider-transport` export.

### Step 8: Wrap `complete-chat`'s body in a retry loop

`complete-chat` defmethod (around line 288 of `src/model.lisp` post-Task-2 of failure-mode-coverage). Read the current body via `lisp-read-file` first. The shape is:

```lisp
(defmethod complete-chat ((provider openai-compatible-provider) messages
                          &key ...)
  (let ((url ...) (headers ...) (body ...))
    (multiple-value-bind (resp-body status resp-headers)
        (handler-case (funcall (provider-transport provider) url headers body)
          (timeout-error () (error 'model-error :kind :transport-timeout ...))
          (connection-refused-error () (error 'model-error :kind :transport-unavailable ...))
          (socket-error () (error 'model-error :kind :transport-unavailable ...)))
      (declare (ignore resp-headers))
      (let ((reason (%classify-llm-failure status resp-body)))
        (when reason
          (error 'model-error :kind reason ...)))
      (chat-parse-response resp-body))))
```

Wrap the entire `multiple-value-bind ...` form in a retry loop. The cleanest shape is a `loop` with `return` on success and `error c` on non-retriable-or-exhausted. Replace the body so the new shape is:

```lisp
(defmethod complete-chat ((provider openai-compatible-provider) messages
                          &key (temperature nil temperature-supplied-p)
                               (max-tokens nil max-tokens-supplied-p)
                               (reasoning-effort nil reasoning-effort-supplied-p)
                               (extra-body nil extra-body-supplied-p))
  (let ((url (%join-url (provider-base-url provider) "/chat/completions"))
        (headers (alist-hash-table
                  `(("Content-Type" . "application/json")
                    ("Authorization"
                     . ,(concatenate 'string "Bearer "
                                     (provider-api-key provider))))
                  :test 'equal))
        (body (chat-build-request-body
               (provider-model provider) messages
               :temperature (if temperature-supplied-p
                                temperature
                                (provider-default-temperature provider))
               :max-tokens (if max-tokens-supplied-p
                               max-tokens
                               (provider-default-max-tokens provider))
               :reasoning-effort (if reasoning-effort-supplied-p
                                     reasoning-effort
                                     (provider-default-reasoning-effort provider))
               :extra-body (if extra-body-supplied-p
                               extra-body
                               (provider-default-extra-body provider)))))
    (let ((attempt 0)
          (max-attempts 2))
      (loop
        (handler-case
            (return
              (multiple-value-bind (resp-body status resp-headers)
                  (handler-case
                      (funcall (provider-transport provider) url headers body)
                    (timeout-error ()
                      (error 'model-error
                             :kind :transport-timeout
                             :message "LLM transport timed out reading the response"))
                    (connection-refused-error ()
                      (error 'model-error
                             :kind :transport-unavailable
                             :message "LLM endpoint refused connection"))
                    (socket-error ()
                      (error 'model-error
                             :kind :transport-unavailable
                             :message "LLM endpoint unreachable (socket-level error)")))
                (declare (ignore resp-headers))
                (let ((reason (%classify-llm-failure status resp-body)))
                  (when reason
                    (error 'model-error
                           :kind reason
                           :message (format nil
                                            "LLM transport failure: ~A (status=~A)"
                                            reason status)
                           :raw resp-body)))
                (chat-parse-response resp-body)))
          (model-error (c)
            (cond
              ((and (provider-retry-p provider)
                    (< attempt (1- max-attempts))
                    (member (model-error-type c) +retriable-reasons+))
               (incf attempt))
              (t (error c)))))))))
```

Key points:
- `attempt` starts at 0; `max-attempts = 2` means at most 1 retry (initial + 1 retry).
- `(< attempt (1- max-attempts))` means "we still have a retry left". On the second `model-error`, `attempt = 1`, `(1- max-attempts) = 1`, condition is false, raise.
- The inner `handler-case` for usocket conditions stays unchanged; it converts socket failures to `model-error` which the outer `handler-case` then sees.
- No sleep / backoff (per α decision).

### Step 9: Run tests — expect PASS

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **397 / 0** (391 baseline + 6 new). All 6 retry-policy deftests green; pre-existing 391 still pass.

### Step 10: mallet

```bash
mallet src/model.lisp tests/transport-test.lisp
```

Expected: `✓ No problems found.`

### Step 11: Self-review

- The retry loop is inside the let-binding for `url` / `headers` / `body` so they are computed once; only the transport call + classifier + parse re-runs on retry. (Different from re-running the whole method, which would rebuild the request body on each attempt — wasted work.)
- `+retriable-reasons+` is internal (not exported). Tests reference it inline (none of the new deftests need to read the parameter directly; they construct stub responses to trigger each kind).
- `provider-retry-p` is exported.
- `:retry-p` kwarg defaults to T (preserves existing behaviour for callers that previously got no retry — they now silently gain one retry on transient failures, which is the intended improvement).
- `chaos-probe.lisp` continues to work; its scenarios that intentionally trigger transient failures may now take 2× as long. A separate follow-up task can opt-out via `:retry-p nil` when constructing the provider.
- No `:local-nicknames`.
- No `src/main.lisp` re-exports added.

### Step 12: Commit

```bash
git add src/model.lisp tests/transport-test.lisp
git commit -m "feat: minimal retry policy in complete-chat (1 retry, transient reasons only)"
```

---

## Task 2: chaos-probe opts out of retry to keep failure-mode probe times bounded

**Files:**
- Modify: `tools/chaos-probe.lisp` — pass `:retry-p nil` to `cl-harness:develop` (which threads to `make-openai-provider`).

### Step 1: Read the current chaos-probe scenarios

Use `lisp-read-file` to inspect `tools/chaos-probe.lisp`. Each scenario calls `cl-harness:develop` with kwargs like `:max-tokens`, `:base-url`, `:api-key`. Add `:retry-p nil` to each scenario so the deliberately-broken inputs don't double their wait time on retry.

### Step 2: Confirm `cl-harness:develop` exposes `:retry-p`

This kwarg must propagate from `cl-harness:develop` (in `src/cli.lisp`) → `make-openai-provider`. If the CLI's `develop` function doesn't currently accept `:retry-p`, add it.

In `src/cli.lisp`, find the `defun develop` (around line 313). Its kwarg list includes `:base-url`, `:api-key`, `:model`, etc. Add `:retry-p t` (default T to match the provider default). Thread it into the `make-openai-provider` call inside `develop`.

```lisp
(defun develop (&key goal project-root system test-system
                  ...existing kwargs...
                  base-url api-key model
                  reasoning-effort extra-body max-tokens temperature
                  (retry-p t)                   ; NEW
                  ...rest...)
  ...
  (let ((provider (make-openai-provider
                   :base-url effective-base-url
                   :api-key effective-api-key
                   :model effective-model
                   :temperature temperature
                   :max-tokens max-tokens
                   :reasoning-effort reasoning-effort
                   :extra-body extra-body
                   :retry-p retry-p)))            ; NEW
    ...))
```

Same treatment for `cl-harness:fix` and `cl-harness:bench` if they construct their own providers — for parity. Read the file before editing to confirm exact positions.

### Step 3: Update chaos-probe scenarios

In `tools/chaos-probe.lisp`, each `(cl-harness:develop ...)` call gets `:retry-p nil` added:

```lisp
;; %p1-empty-content
(cl-harness:develop ...
                    :max-tokens 1
                    :retry-p nil)              ; NEW

;; %p3-transport-unavailable
(cl-harness:develop ...
                    :base-url "http://127.0.0.1:9999/v1"
                    :retry-p nil)              ; NEW

;; %p4-auth-failed
(cl-harness:develop ...
                    :api-key "definitely-not-a-real-key"
                    :retry-p nil)              ; NEW
```

### Step 4: Verify chaos-probe still loads

Run `sbcl --noinform --non-interactive --load tools/chaos-probe.lisp` (with no env vars). Expect: same behaviour as before (3 scenarios FAIL with missing-env errors, exit 1). Just confirming no new syntax / undefined-function errors.

### Step 5: mallet

```bash
mallet src/cli.lisp tools/chaos-probe.lisp
```

Expected: clean.

### Step 6: Run the full test sweep

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **397 / 0** unchanged. The CLI changes don't affect any deftests since none directly construct providers via `cl-harness:develop`.

### Step 7: Commit

```bash
git add src/cli.lisp tools/chaos-probe.lisp
git commit -m "feat: chaos-probe disables retry via :retry-p nil to bound probe time"
```

---

## Task 3: Lint + force-compile + docs §14 + final review + merge

### Step 1: mallet sweep

```bash
mallet src/model.lisp src/cli.lisp tests/transport-test.lisp tools/chaos-probe.lisp
```

Expected: `✓ No problems found.`

### Step 2: Force-compile

```bash
cd /tmp && timeout 60 sbcl --noinform --non-interactive \
  --eval '(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness.asd")' \
  --eval '(asdf:compile-system :cl-harness :force t)' \
  --eval '(quit)' 2>&1 | grep -E "WARNING|ERROR" | head
```

Expected: empty (no new warnings beyond pre-existing ASDF `perform` redefinition).

### Step 3: Full test sweep

Run: `run-tests` `{"system": "cl-harness/tests"}`
Expected: **397 / 0**.

### Step 4: Docs §14 footnote

Append to `docs/context-management.md` §14 trailing prose, AFTER the "Transport failure-mode coverage follow-up" paragraph:

```markdown
LLM retry policy follow-up (landed YYYY-MM-DD):
v0.5.2 のレビューで指摘された 3 件目の reviewer follow-up を着地。
`complete-chat` が transient な MODEL-ERROR (:http-server-error /
:rate-limited / :transport-timeout) で **1 回だけ自動 retry** する
ようになった。`make-openai-provider :retry-p nil` で完全無効化可能。
backoff なし、リトライ回数固定 1 — 最小サーフェスでの保険。
:malformed-response / :transport-unavailable は当面対象外
(production データを見て後続 phase で広げる)。`tools/chaos-probe.lisp`
は `:retry-p nil` を渡して意図的失敗の probe 時間を倍化させない。
+6 deftests (391 → 397)。
```

### Step 5: Live verification (optional)

Re-run chaos-probe against Qwen3.6 with `:retry-p nil` in the
scenarios to confirm probe time is bounded:

```bash
export CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1
export CL_HARNESS_LLM_API_KEY=foo
export CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B
sbcl --noinform --non-interactive --load tools/chaos-probe.lisp
```

P1 (max-tokens=1) should still PASS with `:give-up :empty-content`.
P3 / P4 will produce the same endpoint-specific reasons as before.

### Step 6: Final review

Dispatch `superpowers:code-reviewer` over the branch:
`git diff <base>..HEAD`. Checklist:

- `+retriable-reasons+` matches the 3 spec'd reasons exactly.
- `provider-retry-p` defaults T; `:retry-p nil` opt-out works.
- `complete-chat`'s retry loop performs at most 2 attempts.
- The retry loop catches `model-error`, not generic `error` (so unrelated
  conditions still propagate uncaught — preserves crash-loud
  semantics).
- Non-retriable reasons (`:auth-failed`, `:http-client-error`,
  `:malformed-response`, `:transport-unavailable`) are not retried —
  verified by deftest 5 (does-not-retry-non-retriable-reasons).
- `:retry-p nil` deftest passes.
- chaos-probe scenarios all pass `:retry-p nil`.
- `cl-harness:develop` (cli.lisp) accepts `:retry-p` kwarg and threads
  it correctly. Same for `cl-harness:fix` / `cl-harness:bench` if
  they were also updated.
- No `:local-nicknames`, no `src/main.lisp` re-exports.
- mallet clean; force-compile clean.

### Step 7: Merge

`superpowers:finishing-a-development-branch` → `--no-ff` merge to
main. Push. (Optionally tag v0.5.3 if rolling a patch release.)

---

## Verification checklist

- [ ] `+retriable-reasons+` defined with exactly `(:http-server-error :rate-limited :transport-timeout)`.
- [ ] `provider-retry-p` slot defaults T; reader exported.
- [ ] `make-openai-provider :retry-p t/nil` threads correctly to the slot.
- [ ] `complete-chat` retries once on each retriable kind, returns the second attempt's chat-response on success.
- [ ] `complete-chat` raises after the 2nd attempt fails on the same retriable kind.
- [ ] `complete-chat` does NOT retry `:auth-failed` (or any non-retriable reason).
- [ ] `:retry-p nil` disables retry entirely — verified with the `%counted-canned-transport` introspection.
- [ ] `cl-harness:develop` accepts `:retry-p` kwarg.
- [ ] `tools/chaos-probe.lisp` passes `:retry-p nil` in all 3 scenarios.
- [ ] `tests/transport-test.lisp` count grows by 6 (391 → 397).
- [ ] mallet clean.
- [ ] force-compile clean.
- [ ] No regression in pre-existing 391 tests.
- [ ] §14 docs updated.

---

## Acceptance criteria

The phase is complete when:

1. 6 new deftests in `tests/transport-test.lisp` pass; CI count 391 → 397.
2. The retry loop in `complete-chat` performs at most 2 attempts, retries only on `+retriable-reasons+` membership AND `provider-retry-p` true.
3. `provider-retry-p` is exposed via reader and `:retry-p` kwarg on `make-openai-provider`.
4. `cl-harness:develop` (and `fix` / `bench` if updated) accept `:retry-p` and thread it to provider construction.
5. `tools/chaos-probe.lisp` passes `:retry-p nil` so its scenario times don't double.
6. mallet and force-compile clean across all touched files.
7. `docs/context-management.md` §14 trailing prose mentions the follow-up.
