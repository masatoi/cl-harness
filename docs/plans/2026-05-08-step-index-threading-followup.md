# Step-Index Threading Follow-up Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Thread `develop-state-current-step-index` into the agent loop's three ledger recorders (`source-fact`, `runtime-vocab-fact`, `patch-record`) so their persisted records carry a non-NIL `:related-step-index`, making them visible to Phase C/F/G/H step-filtered context views in production.

**Architecture:** All three recorders in `src/agent.lisp` currently hard-code `:related-step-index nil`. Each call site is already inside a `(when (agent-state-develop-state state) ...)` guard, so the fix is a single one-line read of `develop-state-current-step-index` per site. The orchestrator (`src/orchestrator.lisp:%execute-step`) already maintains the `current-step-index` slot — it's set to the active plan-step's index on entry and cleared on exit (Phase A). Phase H's `%record-finding-from-action` already follows this pattern; this phase aligns the older recorders.

**Tech Stack:** SBCL / ASDF `:package-inferred-system` / Rove tests.

---

## Why this phase

Phase H's final code review surfaced a bug: `repl-finding`s persisted by `%record-finding-from-action` had `:related-step-index nil`, so the `:exploration` and `:implementation` view filters (which match by step-index) silently dropped every recorded finding in production. The fix threaded `plan-step` into the helper.

The same gap exists in Phase B's source-fact and patch-record recorders and Phase G's runtime-vocab recorder — all in `src/agent.lisp`. The reason this hasn't shown up as breakage:

- `:exploration` view of source-facts: filtered by step-index → invisible in production.
- `:exploration` view of runtime-vocab: filtered → invisible.
- `:planning` view of runtime-vocab: **unfiltered** → the warm-start summary masks the gap.
- `:implementation` view of patch-records: filtered → invisible.
- Reports (Phase E `format-develop-state-report`): unfiltered → patches and source-facts surface there.

So in practice the gap is hidden anywhere the data is presented unfiltered. But every per-step view (which is the design point of Phase C/F/G/H) loses data. This follow-up fixes all three at once.

---

## Design contract

1. **No new APIs.** This is a 3-line behaviour change plus tests. No exports change, no new helpers, no new files.
2. **Threading via `develop-state-current-step-index`.** Don't introduce a new threading mechanism — the orchestrator already maintains this slot.
3. **NIL-safe.** When the recorder runs outside an active step (e.g. during run-agent's startup or shutdown), `develop-state-current-step-index` may be NIL. That's the correct value to record — it means "not associated with a specific step", which is semantically distinct from "step 0".
4. **No `:local-nicknames`.**
5. **Tests assert end-to-end visibility.** The new tests must build a real `develop-state` with `:current-step-index` set, run the recorder code path, and assert the persisted record carries the expected step-index. Phase H Task 4's `record-finding-from-action-threads-step-index-from-plan-step` is the precedent.

---

## Files touched

| Path | Action |
|---|---|
| `src/agent.lisp` | Modify — 3 lines change (one per recorder), adjust `%vocab-facts-from-tool-result` call to pass current step-index |
| `tests/agent-test.lisp` | Modify — add 3 deftests asserting threading |

No other files touched. No new test system, no docs change beyond the eventual §14 prose update.

---

## Task 1: thread step-index in all 3 recorders + tests

**Files:**
- Modify: `src/agent.lisp`
- Modify: `tests/agent-test.lisp`

### Step 1: Failing tests

In `tests/agent-test.lisp`, near the existing `agent-records-source-fact-...` / `agent-records-runtime-vocab-fact-...` tests, append three new deftests. The shape mirrors the existing helper-style tests but builds a `develop-state` with `:current-step-index` set, calls the recorder helper or simulates the integration block, and asserts the persisted record's `:related-step-index`.

For source-fact and patch-record, the agent loop's recording is inline in `%execute-action` (no extracted helper). The cleanest test approach is to construct an `agent-state` with a `develop-state` whose `current-step-index` is non-NIL, then directly call the integration block's behaviour by exercising the helper-equivalent: call `make-source-fact` / `make-patch-record` with `:related-step-index (develop-state-current-step-index ...)` and verify the resulting record. **But that just tests the standard library — it doesn't exercise the new code path.**

Better: assert the new behaviour at the call site. There are two test strategies:

**Strategy A — full agent-loop integration**: build a stub provider + stub mcp-client that returns a successful `lisp-read-file` result, run a turn of `run-agent`, and assert the persisted source-fact's step-index. This is heavyweight; existing agent tests do something similar.

**Strategy B — extract small helpers and unit-test them**: factor the inline recording blocks into private helpers (e.g. `%record-source-fact-from-tool-call`), then unit-test those. This mirrors the Phase H Task 4 helper-extraction pattern.

**Recommended: Strategy B.** Same reasoning as Phase H Task 4: cleaner unit tests, helper-extraction makes the recorder explicit and easier to reuse, and matches the precedent set by `%vocab-fact-from-tool-result` (Phase G) and `%record-finding-from-action` (Phase H).

If Strategy B is chosen, define three helpers in `src/agent.lisp` near the existing `%vocab-fact-from-tool-result` block:

```lisp
(defun %record-source-fact-from-tool-call (tool action result state)
  "If STATE has a develop-state and the tool call returned a non-error
result on a read-shaped tool, persist a SOURCE-FACT bound to the
develop-state's current step-index. Returns the persisted fact or
NIL when no recording happened."
  (let ((develop-state (agent-state-develop-state state)))
    (when (and develop-state
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
           develop-state
           (make-source-fact
            :path target-path
            :via-tool tool
            :form-type (and (hash-table-p arguments)
                            (gethash "form_type" arguments))
            :form-name (and (hash-table-p arguments)
                            (gethash "form_name" arguments))
            :related-step-index
            (develop-state-current-step-index develop-state))))))))

(defun %record-runtime-vocab-from-tool-call (tool result state)
  "..."
  ;; Similar: extracts %vocab-facts-from-tool-result with step-index.
  )

(defun %record-patch-record-from-tool-call (tool action target diff turn state)
  "..."
  ;; Similar: builds patch-record with step-index from develop-state.
  )
```

Then replace the inline blocks at lines 943-957 (source-fact), 960-973 (runtime-vocab), and 990-1010 (patch-record) with single calls to the new helpers.

If extracting all 3 helpers feels like too much surface change, **Strategy A is also acceptable** — the simpler approach is just changing 3 `nil` literals to `(develop-state-current-step-index develop-state)` calls and adding lighter integration tests. Pick whichever produces a cleaner diff in your hands.

The unit tests (Strategy B):

```lisp
(deftest record-source-fact-threads-step-index-from-develop-state
  (let* ((dstate (cl-harness/src/state:make-develop-state
                  :goal "g" :project-root "/tmp/p"
                  :system "x" :test-system "x/tests"))
         (state (cl-harness/src/agent:make-agent-state
                 :develop-state dstate))
         ;; <build agent-action and tool-result hash-tables>
         )
    (setf (cl-harness/src/state:develop-state-current-step-index dstate) 5)
    (cl-harness/src/agent::%record-source-fact-from-tool-call
     "lisp-read-file" action result state)
    (let ((fact (first (cl-harness/src/state:develop-state-source-facts dstate))))
      (ok (eql 5 (cl-harness/src/source-fact:source-fact-related-step-index fact))))))

(deftest record-runtime-vocab-threads-step-index-from-develop-state
  ...)  ; same shape with code-describe result

(deftest record-patch-record-threads-step-index-from-develop-state
  ...)  ; same shape with lisp-edit-form action
```

If Strategy A is chosen, write deftests that build a stubbed `agent-state` and exercise the inline recorder code path via a helper extracted from `%execute-action` — or use the existing `agent-state` pathway with a faked tool-result.

### Step 2: Run — expect FAIL

Either the new helpers don't exist (Strategy B) or the tests assert non-NIL step-index but recorders still pass `nil` (Strategy A). Either way, RED.

### Step 3: Implement

**Strategy A (simpler diff)**:

1. **Source-fact recorder** at `src/agent.lisp:947-956`: change
   ```lisp
   :related-step-index nil
   ```
   to
   ```lisp
   :related-step-index (develop-state-current-step-index
                        (agent-state-develop-state state))
   ```

2. **Runtime-vocab recorder** at `src/agent.lisp:965-967`: the call to `%vocab-facts-from-tool-result` passes `:related-step-index nil`. Change to `(develop-state-current-step-index (agent-state-develop-state state))`.

3. **Patch-record recorder** at `src/agent.lisp:993-1009`: change `:related-step-index nil` to the same `(develop-state-current-step-index ...)` form.

All three sites are inside `(when (agent-state-develop-state state) ...)` blocks, so `(agent-state-develop-state state)` is already known non-NIL. `develop-state-current-step-index` may itself be NIL (recorder fires outside an active step), which is the correct value to persist.

**Strategy B (helper extraction)**: refactor first into 3 helpers, then change them. See Step 1 for the helper signatures.

### Step 4: Run — expect PASS

`run-tests` `{"system": "cl-harness/tests"}`. Pre-follow-up baseline: 328 (post-Phase-H). Post: **331** (3 new deftests). No regressions.

### Step 5: mallet on touched files

`mallet src/agent.lisp tests/agent-test.lisp`. Address warnings.

### Step 6: Self-review

- All three recorders read from `develop-state-current-step-index` — no new threading mechanism introduced.
- Tests build a `develop-state`, set `current-step-index`, exercise the recorder, assert.
- No `:local-nicknames`.
- The orchestrator's existing setf/clear of `current-step-index` (Phase A) is unchanged — this phase is purely a consumer-side fix.

### Step 7: Commit

```
git add src/agent.lisp tests/agent-test.lisp
git commit -m "fix: thread current-step-index into source-fact / patch-record / runtime-vocab recorders"
```

---

## Task 2: Final review + merge

### Step 1: Final review

Dispatch `superpowers:code-reviewer` over the branch. Checklist:
- All three recorders read from `develop-state-current-step-index`.
- No regression in pre-existing tests (the 18 Phase G + 24 Phase H deftests must all stay green).
- No `:local-nicknames`.
- No new exports from `src/main.lisp`.
- mallet clean, force-compile clean.

### Step 2: Optional docs note

`docs/context-management.md` doesn't strictly need a §14 row for this — it's a follow-up fix, not a new phase. But a one-line note in §14's trailing prose helps future readers understand why Phase B/G facts didn't surface in views before this commit. The note can be appended to the Phase H paragraph (since H's final review is what surfaced the gap). Optional — implementer's call.

### Step 3: Merge to main

`superpowers:finishing-a-development-branch`, `--no-ff` merge with summary highlighting:
- 3 recorders fixed: source-fact, runtime-vocab, patch-record.
- Visibility: per-step views (Phase C/F/G/H) now show real production data, not just hand-built test fixtures.
- No new APIs / no contract change.

---

## Verification checklist (before opening a PR)

- [ ] All three recorders thread `develop-state-current-step-index`.
- [ ] 3 new deftests assert step-index threading.
- [ ] Pre-existing test count unchanged (no regression).
- [ ] mallet clean.
- [ ] force-compile clean.
- [ ] No new `:local-nicknames`.
- [ ] No new `src/main.lisp` re-exports.

---

## Acceptance criteria

The follow-up is complete when:

1. All three recorders in `src/agent.lisp` pass `(develop-state-current-step-index ...)` instead of `nil`.
2. 3 new deftests verify the threading at the recorder integration layer.
3. mallet and force-compile clean.
4. Test count grows by 3 (328 → 331).
