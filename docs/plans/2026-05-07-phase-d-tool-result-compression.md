# Phase D: Tool-result compression + history compaction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bound the context-window footprint of long agent runs by (1) activating the dormant `compact-history` helper at the agent loop's LLM-call boundary when the message list grows over a configurable threshold, and (2) tightening per-tool result summarizers so individual tool outputs don't blow the budget in the first place.

**Architecture:** One precondition — add `max-context-tokens` to `run-limits` so the threshold is configurable per run. Then the activation: `step-turn` (in `src/agent.lisp`) calls `(compact-history messages)` before each `complete-chat` call when `(approximate-history-tokens messages)` exceeds the threshold. Then the per-tool tightening: a shared `%truncate-large-text` helper (head + footer pattern) applied to `fs-read-file` / `lisp-read-file` / `clgrep-search` summarizers, plus an explicit "(N more failures truncated)" footer on `summarize-run-tests` when the failed-tests vector exceeds the existing 5-entry display cap.

**Tech stack:** Common Lisp (SBCL), ASDF `:package-inferred-system`, rove tests, alexandria. Phase A/B/C patterns apply.

**Out of scope (deferred):**
- **Finding-ization beyond Phase B** — the spec's §6.2 `(hypothesis probe finding decision)` shape would require a new structured class plus an LLM-driven extraction pass. Phase B's `ADOPTED:/REJECTED:/DEFERRED:` marker parsing (via `parse-abstraction-decisions`) already covers the most-used part. Full structured findings deferred to Phase E.
- **Patch-record diff line-counting** — the JSONL `:patch` event has the full diff; `patch-record-diff-summary` truncated to 500 chars is acceptable for in-memory purposes. Structuring as `(added-lines, removed-lines, context-lines)` is a Phase E refinement.
- **Step-aware compaction** — the existing `compact-history` is turn-based (keeps head + tail, digests middle). Step-boundary digestion (e.g. "this is the summary of the failed step 0; current step is step 1") is a Phase E refinement.
- **Custom REPL-transcript finding extraction in `agent.lisp`** — explore.lisp already produces an explore-result memo with markers; the agent loop's REPL sessions are short-lived and their summarization is covered by Phase D's tool-result compaction.

**Acceptance criteria:**
1. `src/config.lisp:run-limits` gains a `max-context-tokens` slot (integer, default 50000) with a public reader. `make-default-limits` sets it.
2. `src/agent.lisp:step-turn` (or its caller) computes `(approximate-history-tokens messages)` before each `complete-chat` call and calls `(compact-history messages)` when the estimate exceeds `max-context-tokens`. The compaction is gated so it fires at most once per turn.
3. `src/agent.lisp` introduces a `%truncate-large-text` helper that takes a string and a char-cap (default 1500) and returns either the original string (when under-cap) or `<first 1500 chars>\n…\n[... truncated, total N chars …]`.
4. `summarize-tool-by-key` methods for `:fs-read-file`, `:lisp-read-file`, `:clgrep-search` apply `%truncate-large-text` to their extracted text.
5. `summarize-run-tests` adds a "(N more failures truncated)" footer when the `failed_tests` vector has more than 5 entries.
6. New `tests/agent-test.lisp` deftests cover (a) compaction trigger fires at the threshold; (b) compaction does NOT fire under-threshold; (c) truncation kicks in for an oversized tool result; (d) run-tests footer signals truncation when failures > 5.
7. New `tests/config-test.lisp` (if not present) or extension to existing config testing covers the `max-context-tokens` default and override.
8. Full `cl-harness/tests` rove suite passes via cl-mcp `run-tests` — Phase C baseline 256/0 plus the new deftests, zero regressions.
9. mallet clean on Phase D-touched files.
10. `(asdf:compile-system :cl-harness :force t)` clean.
11. `docs/context-management.md` §14 updated to mark Phase D landed; cross-references which §6 sub-sections are now fulfilled.

**Risks & mitigations:**

- **R1: compaction-trigger heuristic is wrong.** `approximate-history-tokens` uses chars/4 — coarse. Real LLM tokens depend on tokenizer. → MVP is "good enough" — overshooting by 20% just means we compact a turn earlier than strictly needed. Phase E may tighten with a real tokenizer (or trust the LLM provider's token-count callback).

- **R2: existing happy-path tests regress because compaction fires unexpectedly.** Default 50000 is well above any test's message-list size (Phase A/B/C tests construct a handful of messages). → Verify by running the full pre-existing suite after the change; if any test's history grows past 50000 chars, that's its own bug. Document the threshold in the slot's docstring.

- **R3: `%truncate-large-text` chops mid-form, producing unparseable output the agent might re-feed elsewhere.** → MVP doesn't try to chop on form boundaries; truncation is a presentation concern, not a parsing concern. The agent never re-parses tool-result strings as Lisp.

- **R4: `summarize-run-tests` truncation already loses failure data silently — Phase D fixes the signal but not the loss.** → That's the right scope for Phase D MVP. Lifting the 5-entry cap is a separate concern (it would balloon the message); the footer makes the loss visible to the LLM, which is the correctness fix.

- **R5: `compact-history` itself might error (e.g. on empty messages list).** → It handles the empty case; tests in `tests/compact-test.lisp` cover the happy path. Phase D's wiring just calls it — no new failure modes.

**Working agreement:**
- cl-mcp tools (`lisp-edit-form`, `lisp-patch-form`, `lisp-read-file`, `repl-eval`, `run-tests`) for Lisp source modifications. No shell `grep`/`sed`/`cat` against Lisp source.
- First action of every implementation session: cl-mcp `fs-set-project-root` on the repo root.
- Commit after each green TDD cycle. Use feature branch `phase-d-compression`.

---

## Task 1: Add `max-context-tokens` to `run-limits`

**Files:**
- Modify: `src/config.lisp`
- Modify: `tests/agent-test.lisp` or create `tests/config-test.lisp`

### Step 1.1: Survey

cl-mcp `lisp-read-file src/config.lisp` `name_pattern="run-limits"` to confirm the current slot list and `make-default-limits` defaults. The Phase A code is well-known but verify the file hasn't drifted.

cl-mcp `clgrep-search` for `make-default-limits` in `tests/` to find the existing limits-related tests (likely in `tests/agent-test.lisp` since `run-limits` is consumed by the agent).

### Step 1.2: Failing test

Find the existing limits-related test (or create one). The test asserts:
- `(run-limits-max-context-tokens (make-default-limits))` returns 50000.
- A custom-built `run-limits` with `:max-context-tokens 12345` returns 12345.

Pseudocode:
```lisp
(deftest run-limits-default-max-context-tokens
  (ok (= 50000
         (cl-harness/src/config:run-limits-max-context-tokens
          (cl-harness/src/config:make-default-limits)))))

(deftest run-limits-accepts-custom-max-context-tokens
  (let ((l (make-instance 'cl-harness/src/config:run-limits
                          :max-turns 1 :max-tool-calls 1
                          :max-patches 1 :max-read-files 1
                          :max-repl-evals 1 :max-wall-clock-seconds 1
                          :max-action-parse-errors 1
                          :max-context-tokens 12345)))
    (ok (= 12345 (cl-harness/src/config:run-limits-max-context-tokens l)))))
```

Add the symbol to the test file's defpackage `:import-from #:cl-harness/src/config` if it's not already there.

### Step 1.3: Red

cl-mcp `run-tests` `{"system": "cl-harness/tests"}`. Expected: failure on missing `run-limits-max-context-tokens` accessor.

### Step 1.4: Implement the slot

Use cl-mcp `lisp-patch-form` on `src/config.lisp`:

(a) `defpackage` `:export` adds `#:run-limits-max-context-tokens`.
(b) `run-limits` defclass adds a new slot at the end of the slot list:

```
   (max-context-tokens
    :initarg :max-context-tokens
    :initform 50000
    :reader run-limits-max-context-tokens
    :documentation "Approximate token budget for the agent loop's
message history. When the running estimate of CHAT-TOKENS in MESSAGES
exceeds this, the agent calls COMPACT-HISTORY before the next
COMPLETE-CHAT call. The threshold is approximate (chars / 4 heuristic);
fine-grained accuracy is not required because the goal is keeping the
context window from blowing, not minimising tokens.")
```

(c) `make-default-limits` accepts `:max-context-tokens 50000` in its `make-instance` call.

`dry_run: true` for each patch.

### Step 1.5: Verify green

cl-mcp `load-system` `{"system": "cl-harness", "force": true}` — clean.
cl-mcp `run-tests` for the relevant test system — both new tests pass.
Full suite — 258/0 (256 + 2).

### Step 1.6: Commit

```bash
git checkout -b phase-d-compression
git add src/config.lisp tests/agent-test.lisp  # or wherever the limits test lives
git commit -m "$(cat <<'EOF'
feat: run-limits.max-context-tokens slot (Phase D.1 precondition)

Adds a MAX-CONTEXT-TOKENS slot to RUN-LIMITS (integer, default
50000, public reader). The agent loop's COMPACT-HISTORY trigger
(Task 2) reads this to decide when to compact MESSAGES before a
COMPLETE-CHAT call.

The threshold is approximate (CHARS/4 heuristic via
APPROXIMATE-HISTORY-TOKENS in src/compact.lisp); fine-grained
accuracy is not the goal — keeping the context window from
blowing during long agent runs is.

Phase D of the context-management refactor
(docs/plans/2026-05-07-phase-d-tool-result-compression.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `compact-history` activation into the agent loop

**Files:**
- Modify: `src/agent.lisp`
- Modify: `tests/agent-test.lisp`

### Step 2.1: Survey

cl-mcp `lisp-read-file src/agent.lisp` `name_pattern="^step-turn$"` (or the `complete-chat` call site — depends on the layout). Identify:
- Where the `messages` list is passed to `complete-chat`.
- Where the agent state's `token-total` is updated.
- Where to inject the `(compact-history messages)` call — must be BEFORE `complete-chat` so the LLM sees the compacted list.

cl-mcp `lisp-read-file src/compact.lisp` to verify the `compact-history` and `approximate-history-tokens` exports.

cl-mcp `clgrep-search` for `compact-history` in `src/` — should find no production callers (it's dormant per the survey).

Confirm `cl-harness/src/compact` is NOT yet imported by `src/agent.lisp`. If not, add `:import-from #:cl-harness/src/compact #:compact-history #:approximate-history-tokens` to agent.lisp's defpackage.

### Step 2.2: Failing test

Append to `tests/agent-test.lisp`:

```lisp
(deftest step-turn-compacts-history-when-over-threshold
  ;; Construct a long messages list (over the threshold) and a stub
  ;; provider; drive one step-turn; assert the messages list seen by
  ;; complete-chat was compacted (length reduced) before the call.
  (let* ((cfg (make-run-config :project-root "/tmp/" :system "demo"
                               :test-system "demo/tests"
                               :issue "trigger compaction"
                               :limits (make-instance 'cl-harness/src/config:run-limits
                                          :max-turns 1 :max-tool-calls 1
                                          :max-patches 1 :max-read-files 1
                                          :max-repl-evals 1 :max-wall-clock-seconds 60
                                          :max-action-parse-errors 1
                                          :max-context-tokens 1000)))
         ;; 200 dummy messages of ~10 chars each = ~500 tokens (over 1000?)
         ;; Tune to actually exceed threshold; ~5000 chars / 4 = 1250 tokens.
         (long-messages (loop for i from 0 below 200
                              collect (cl-harness/src/model:make-chat-message
                                       "user"
                                       (format nil "padding message ~A" i))))
         (captured-messages nil)
         (provider (make-instance 'CANNED-PROVIDER ...)))
    ;; Drive step-turn; capture what messages the provider saw.
    ;; Assert the captured list is shorter than 200.
    ...))
```

The exact stub setup mirrors existing happy-path agent-test patterns. The implementer should look at the canonical happy-path test (e.g. `run-agent-finishes-passed-after-patch-and-reverify`) for the established stub harness.

If the stub harness in agent-test doesn't easily allow injecting a long pre-existing history, an ALTERNATIVE: write a unit-style test that calls `(compact-history messages)` directly and verifies it reduces length under the threshold-trigger condition. The integration test then becomes a smoke-test that the trigger fires for a long message list.

Add a second test for the negative case — under-threshold should NOT compact:

```lisp
(deftest step-turn-skips-compaction-when-under-threshold
  ;; Short message list, default threshold; messages should pass through
  ;; unchanged.
  ...)
```

### Step 2.3: Red

cl-mcp `run-tests` for agent-test. Expected: the new tests fail because compact-history is not yet called.

### Step 2.4: Implement the trigger

Add to `src/agent.lisp` defpackage's `:import-from`:
```
  (:import-from #:cl-harness/src/compact
                #:compact-history
                #:approximate-history-tokens)
```

Add a helper `%maybe-compact-messages` (internal, not exported):

```lisp
(defun %maybe-compact-messages (messages run-limits)
  "When the approximate token estimate of MESSAGES exceeds
RUN-LIMITS-MAX-CONTEXT-TOKENS, return the result of
COMPACT-HISTORY; otherwise return MESSAGES unchanged."
  (let ((threshold (and run-limits
                        (cl-harness/src/config:run-limits-max-context-tokens
                         run-limits))))
    (if (and threshold
             (> (approximate-history-tokens messages) threshold))
        (compact-history messages)
        messages)))
```

In `step-turn` (or the function that builds the `complete-chat` request), call `%maybe-compact-messages` on the messages list before passing it to `complete-chat`. The threshold is read from the run-config's `run-limits`. 

Actually the `step-turn`'s lambda list typically receives `state` (an `agent-state`); the run-limits live on the agent-state's run-config. Trace: `agent-state-run-config state` → `run-config-limits config` → `run-limits-max-context-tokens limits`. Or pre-compute and pass through.

The compaction must happen on the LOCAL messages list passed to `complete-chat`, NOT on a slot of `agent-state` (the state object's history-tracking is the source of truth; compaction is a presentation-time concern).

If you find the messages list lives on `agent-state` and is mutated in place, you'll need to be careful: compaction should produce a NEW list for `complete-chat` and either (a) leave the agent-state's history slot alone, OR (b) replace it. Per the dormant `compact-history`'s contract: it returns a new list, doesn't mutate in place. So branch (a) is the safe default. Verify via the survey.

### Step 2.5: Verify green

cl-mcp `load-system` clean.
cl-mcp `run-tests cl-harness/tests/agent-test` — pre-existing tests pass + new compaction tests pass.
cl-mcp `run-tests cl-harness/tests` — full suite green.

### Step 2.6: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: activate compact-history at the agent loop's LLM-call boundary (Phase D.2)

step-turn now calls %MAYBE-COMPACT-MESSAGES on the messages list
before each COMPLETE-CHAT call. When the message list's approximate
token estimate exceeds RUN-LIMITS-MAX-CONTEXT-TOKENS (default
50000, configurable via Phase D.1's slot), COMPACT-HISTORY trims
the middle of the list to a single digest message, preserving
the system prompt + initial user issue and the recent turns.

The trigger is per-turn; under-threshold runs see no behavior
change. Verified by the existing agent-test happy-path suite
continuing to pass without crossing the threshold.

Phase D of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `%truncate-large-text` helper + apply to read-style tool summarizers

**Files:**
- Modify: `src/agent.lisp`
- Modify: `tests/agent-test.lisp`

### Step 3.1: Survey

cl-mcp `lisp-read-file src/agent.lisp` `name_pattern="^summarize-tool-by-key$"` and the related summarizer methods.

The existing summarizer methods (per the Phase D survey):
- `:fs-read-file`, `:lisp-read-file`, `:clgrep-search` — currently use `extract-content-text` to get the first content text block, no truncation.

Identify the EXACT method bodies for each so the new `%truncate-large-text` wrapper inserts cleanly.

### Step 3.2: Failing tests

Append to `tests/agent-test.lisp`:

```lisp
(defun %make-fake-text-result (text)
  "Helper: construct a hash-table that looks like a tools/call success
result with one text content block."
  (alexandria:alist-hash-table
   `(("content" . ,(vector
                    (alexandria:alist-hash-table
                     `(("type" . "text") ("text" . ,text))
                     :test 'equal))))
   :test 'equal))

(deftest summarize-fs-read-file-truncates-large-text
  (let* ((huge (make-string 5000 :initial-element #\a))
         (result (%make-fake-text-result huge))
         (out (cl-harness/src/agent::summarize-tool-result "fs-read-file" result)))
    (ok (< (length out) 2500))
    (ok (search "[... truncated" out))))

(deftest summarize-fs-read-file-leaves-short-text-alone
  (let* ((short "(defun foo () 1)")
         (result (%make-fake-text-result short))
         (out (cl-harness/src/agent::summarize-tool-result "fs-read-file" result)))
    (ok (search short out))
    (ok (not (search "truncated" out)))))

(deftest summarize-lisp-read-file-truncates-large-text
  (let* ((huge (make-string 5000 :initial-element #\b))
         (result (%make-fake-text-result huge))
         (out (cl-harness/src/agent::summarize-tool-result "lisp-read-file" result)))
    (ok (< (length out) 2500))
    (ok (search "[... truncated" out))))

(deftest summarize-clgrep-search-truncates-large-text
  (let* ((huge (make-string 5000 :initial-element #\c))
         (result (%make-fake-text-result huge))
         (out (cl-harness/src/agent::summarize-tool-result "clgrep-search" result)))
    (ok (< (length out) 2500))
    (ok (search "[... truncated" out))))
```

The 2500 cap in the assertion is generous (truncation cap of 1500 + ~100 chars of prefix/suffix wrapping leaves room).

### Step 3.3: Red

cl-mcp `run-tests cl-harness/tests/agent-test` — expect failures: the truncation tests fail because the full huge string is currently passed through.

### Step 3.4: Implement

Add `%truncate-large-text` near the top of `src/agent.lisp` (in the helper section, before the summarizer methods):

```lisp
(defparameter +default-tool-result-cap+ 1500
  "Default cap (in characters) for read-style tool results in
SUMMARIZE-TOOL-BY-KEY methods. Strings longer than this are
truncated with a '[... truncated, total N chars elided ...]'
footer so the LLM can see that data was lost.")

(defun %truncate-large-text (text &optional (cap +default-tool-result-cap+))
  "If TEXT is longer than CAP, return the first CAP characters
followed by an explicit truncation footer. Otherwise return TEXT
unchanged. NIL TEXT returns NIL."
  (cond
    ((null text) nil)
    ((<= (length text) cap) text)
    (t (format nil "~A~%[... truncated, ~D chars elided ...]"
               (subseq text 0 cap)
               (- (length text) cap)))))
```

Modify each of the 3 read-style summarizer methods to wrap their result through `%truncate-large-text`. The pattern (replacing each method's body):

```lisp
(defmethod summarize-tool-by-key ((tool-key (eql :fs-read-file)) result)
  (%truncate-large-text (extract-content-text result)))

(defmethod summarize-tool-by-key ((tool-key (eql :lisp-read-file)) result)
  (%truncate-large-text (extract-content-text result)))

(defmethod summarize-tool-by-key ((tool-key (eql :clgrep-search)) result)
  (%truncate-large-text (extract-content-text result)))
```

If the existing methods are produced by a `deftext-method` macro (per the survey), update the macro to apply truncation. Otherwise, modify each method individually.

Use cl-mcp `lisp-edit-form replace` for each.

### Step 3.5: Verify green

cl-mcp `load-system` clean.
cl-mcp `run-tests cl-harness/tests/agent-test` — 4 new truncation tests pass + existing tests still pass.

### Step 3.6: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: %truncate-large-text + read-style tool summarizer caps (Phase D.3)

Adds %TRUNCATE-LARGE-TEXT helper (default cap 1500 chars,
configurable via the +DEFAULT-TOOL-RESULT-CAP+ defparameter).
Applied to SUMMARIZE-TOOL-BY-KEY methods for :fs-read-file,
:lisp-read-file, and :clgrep-search.

Long results emit a "[... truncated, N chars elided ...]" footer
so the LLM can see when data was lost. Short results pass through
unchanged. NIL results stay NIL.

The truncation is a presentation concern only — the JSONL
transcript still records the full tool result for audit /
recovery. The cap protects the agent's MESSAGES list from
ballooning when the LLM asks for collapsed=false on a 3000-line
file.

Phase D of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Improve `summarize-run-tests` to signal truncation

**Files:**
- Modify: `src/agent.lisp`
- Modify: `tests/agent-test.lisp`

### Step 4.1: Survey

cl-mcp `lisp-read-file src/agent.lisp` `name_pattern="^summarize-run-tests$"` and `name_pattern="^format-failed-tests$"`. Confirm:
- `format-failed-tests` takes a `failed-tests` array and a `:limit 5` argument; emits 5 entries.
- `summarize-run-tests` extracts `passed`, `failed`, `failed_tests` from the result hash-table and calls `format-failed-tests`.

The current behavior silently drops failures 6+ when the array has more than 5 entries. Phase D's fix: when truncating, append a "(N more failures truncated)" footer.

### Step 4.2: Failing test

Append to `tests/agent-test.lisp`:

```lisp
(deftest summarize-run-tests-signals-truncation-when-over-five-failures
  (let* ((entries (loop for i from 0 below 8
                        collect (alexandria:alist-hash-table
                                 `(("test_name" . ,(format nil "test-~D" i))
                                   ("description" . ,(format nil "test ~D failed" i))
                                   ("reason" . "x"))
                                 :test 'equal)))
         (tr (alexandria:alist-hash-table
              `(("passed" . 0)
                ("failed" . 8)
                ("failed_tests" . ,(coerce entries 'vector)))
              :test 'equal))
         (result (alexandria:alist-hash-table
                  `(("content" . ,(vector
                                   (alexandria:alist-hash-table
                                    `(("type" . "text") ("text" . "ignored"))
                                    :test 'equal))))
                  :test 'equal)))
    ;; Stash test-result on the meta hash so summarize-run-tests can find it.
    ;; (The actual result-extraction shape depends on cl-mcp's run-tests
    ;; format — check the existing summarize-run-tests body for the right
    ;; nesting; the test fixture must match.)
    ...
    (let ((out (cl-harness/src/agent::summarize-tool-result "run-tests" result)))
      (ok (search "3 more failures" out))
      ;; Existing format-failed-tests entries are still present:
      (ok (search "test-0" out))
      (ok (search "test-4" out))
      ;; Truncated entries are NOT in body:
      (ok (not (search "test-7" out))))))

(deftest summarize-run-tests-no-footer-when-five-or-fewer-failures
  ;; With exactly 5 failures, no truncation footer.
  (let* ((entries (loop for i from 0 below 5
                        collect (alexandria:alist-hash-table
                                 `(("test_name" . ,(format nil "t~D" i))
                                   ("description" . "x") ("reason" . "y"))
                                 :test 'equal)))
         (tr (alexandria:alist-hash-table
              `(("passed" . 0) ("failed" . 5)
                ("failed_tests" . ,(coerce entries 'vector)))
              :test 'equal)))
    (let ((out (cl-harness/src/agent::summarize-tool-result "run-tests" tr)))
      (ok (not (search "more failures" out))))))
```

The exact result-shape construction depends on how `summarize-run-tests` extracts the `failed_tests` array. The implementer should read the existing function body and ensure the test fixture matches.

### Step 4.3: Red

cl-mcp `run-tests cl-harness/tests/agent-test` — expect the truncation-signal test to fail (no "more failures" text in current output).

### Step 4.4: Implement

Modify `format-failed-tests` (or `summarize-run-tests`) to append the footer when the input array exceeds the limit. The cleanest place is in `summarize-run-tests` after the call to `format-failed-tests`:

```lisp
(defun summarize-run-tests (result)
  (let* ((failed-tests (gethash "failed_tests" result))
         (failed-count (and failed-tests (length failed-tests)))
         (display-limit 5))
    (with-output-to-string (s)
      ;; ... existing rendering logic unchanged ...
      (when (and failed-count (> failed-count display-limit))
        (format s "~%(~D more failure~:P truncated; see JSONL transcript for the full list)"
                (- failed-count display-limit))))))
```

Read the existing `summarize-run-tests` body to identify the right insertion point. Use cl-mcp `lisp-edit-form` `replace` if the function is small enough; otherwise use `lisp-patch-form` for surgical insertion.

### Step 4.5: Verify green

cl-mcp `run-tests cl-harness/tests/agent-test` — both new tests pass + existing tests pass.

### Step 4.6: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: summarize-run-tests signals failure-list truncation (Phase D.4)

When the failed_tests array has more than 5 entries (the existing
display limit in format-failed-tests), append a footer:
"(N more failures truncated; see JSONL transcript for the full list)"

This makes the silent loss visible to the LLM. Lifting the
display cap is a separate concern (it would balloon the message);
the footer is the correctness fix.

Phase D of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Lint + force-compile + regression sweep

Mirrors Phase A/B/C Task 9.

### Steps

1. `mallet src/agent.lisp src/config.lisp tests/agent-test.lisp` — fix any new warnings on Phase D files. Use the base-vs-head comparison (with the worktree placed OUTSIDE `~/.roswell/local-projects/` to avoid the Phase C lesson's stale-worktree trap — e.g. `/tmp/cl-harness-base-d/` works only if you `git worktree remove` AND `rm -rf` the directory before reload).
2. `(asdf:compile-system :cl-harness :force t)` via cl-mcp `repl-eval` — clean.
3. cl-mcp `run-tests` `{"system": "cl-harness/tests"}` — confirm pre-existing pass count + new Phase D tests, all passing.
4. Shell `rove cl-harness.asd` — same pre-existing 5-failure set in `develop-bench-test`, no new failures.
5. Commit only if mallet required fixes.

---

## Task 6: Docs annotation + final review + merge

### Step 6.1: Update `docs/context-management.md` §14

Mark Phase D landed; cross-reference §6 fulfilment.

```markdown
| D | tool 結果圧縮 (run-tests / fs-read-file / lisp-read-file / clgrep-search の summarizer 強化) + compact-history の agent loop 配線 | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-d-tool-result-compression.md` |
```

Update the trailing paragraph to note that §6.1 (tool 結果) and §6.3 (file content) are now (mostly) addressed; §6.2 (REPL transcript → finding) is partially covered by Phase B's ADOPTED/REJECTED parsing in `parse-abstraction-decisions`; §6.4 (completed subtasks summary) and §6.5 (resolved failures) remain for Phase E.

### Step 6.2: Final code review

`superpowers:code-reviewer` over the entire `phase-d-compression` branch (base = post-Phase-C `main` SHA; head = current branch tip). Checklist:
- Compaction trigger fires only when threshold exceeded.
- Truncation footer is visible in summarized output.
- Standalone callers (no run-limits, no develop-state) handled gracefully.
- mallet clean, force-compile clean.
- Test counts: agent-test +6-8 deftests, config-test +0-2.
- No `:local-nicknames`.
- Existing happy-path tests pass without modification.

### Step 6.3: Merge to main

`superpowers:finishing-a-development-branch`, `--no-ff` merge with summary message highlighting:
- The `compact-history` activation (one new helper + one new call site).
- The `%truncate-large-text` helper + 3 read-tool summarizer caps.
- The `summarize-run-tests` truncation footer.
- The `max-context-tokens` slot on `run-limits`.

---

## Verification checklist (before opening a PR)

- [ ] `src/config.lisp:run-limits` has `max-context-tokens` slot, default 50000
- [ ] `src/agent.lisp:step-turn` calls `compact-history` when over threshold
- [ ] `%truncate-large-text` helper applied to `:fs-read-file`, `:lisp-read-file`, `:clgrep-search` summarizers
- [ ] `summarize-run-tests` appends truncation footer when failures > 5
- [ ] No regression in pre-existing tests (full suite green)
- [ ] mallet clean on Phase D files
- [ ] `(asdf:compile-system :cl-harness :force t)` clean
- [ ] `docs/context-management.md` §14 updated

## Rollback plan

If compaction surfaces a behavioral regression that cannot be diagnosed quickly:

1. `git revert` Task 2's commit (the compact-history wiring) — leaves the run-limits slot, the truncation helper, and the run-tests footer in place; only the global compaction trigger is removed.
2. The remaining Phase D pieces (truncation, run-tests footer) are independently useful and have no external API impact.
3. Open an issue describing the regression and re-attempt the wiring with a different threshold or trigger logic.

The Task 2 (compaction trigger) is the highest-blast-radius piece; the others are local. The rollback boundary is clean — Task 2 can be reverted in isolation.
