# Phase G / H / I Prompt-Side Enrichment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Close the gap between v0.5's wired-but-unused Phase G/H/I machinery and what actually surfaces in production. Live verification with Qwen/Qwen3.6-35B-A3B (2026-05-08) showed:

- `runtime-vocabulary: 0` even under `:runtime-native` condition — the LLM never called `code-find` / `code-describe` / `code-find-references`.
- `repl-findings: 0` — the LLM never emitted the `{"type":"finding"}` action shape introduced in Phase H.
- `project-summary: NIL` — `gather-project-summary` is implemented but never called from the develop CLI.

This phase fixes all three with **prompt-only changes** for G/H and a **tiny code addition** for I.

**Architecture:** Two prompt files (`src/agent.lisp:system-prompt`, `src/explore.lisp:explore-system-prompt`) get a few lines of guidance each. `src/orchestrator.lisp:develop` calls `gather-project-summary` after constructing `develop-state` and stores the result via `develop-state-set-project-summary`. Best-effort (handler-case wrapped) so a malformed project tree doesn't crash the loop.

**Tech Stack:** SBCL / ASDF `:package-inferred-system` / Rove tests.

---

## Why this phase

The v0.5 release shipped 10 phases of context-management refactor with all the typed-record machinery in place and 357/0 unit tests covering construction-time behaviour. Live verification confirmed Phases A/B/C/E/F/J fire correctly under realistic LLM driving. But three phases require **LLM behaviour changes** to exercise:

- **Phase G** (runtime-vocabulary): the recorder triggers on cl-mcp tool results from `code-find` / `code-describe` / `code-find-references`. If the LLM doesn't call those tools, the slot stays empty. The current system prompt under `:runtime-native` says "PROBE first: use repl-eval / code-find / code-describe / inspect-object" but doesn't explain WHY `code-*` over `repl-eval` for vocabulary questions.
- **Phase H** (repl-finding): the `{"type":"finding"}` action shape was added to `src/action.lisp`'s parser, the explore loop's `:finding` case persists it, and the orchestrator's `%promote-matching-findings` flips the promotion flag — but the explore-system-prompt only documents `tool_call` and `finish` action types. The LLM has no way to know `finding` exists.
- **Phase I** (project-summary): the record class, dirty-flipper, and `:planning` view rendering all work, but no caller actually invokes `gather-project-summary` from the develop loop.

This phase is **small, mechanical, and risk-bounded**: prompt strings + 5 lines of orchestrator wiring. The unit tests already prove the underlying machinery; this just teaches the LLM to use it and threads the project-summary gather call.

---

## Design contract

1. **Prompt changes are additive**, not substitutive. Existing workflow lines for `:runtime-native` etc. stay as-is; new lines are appended.
2. **Phase H finding action is introduced ONLY in the explore prompt**, not the agent prompt. The implement run-agent's primary action is patching, not hypothesis-driven probing — let the explore sub-agent be the canonical home for findings. (If the implement loop later wants to record findings, that's a follow-up.)
3. **Phase I auto-gather is best-effort**: wrapped in `handler-case` so a missing directory or unreadable `.asd` returns NIL and the develop loop continues with the legacy `project-inventory` text path alone.
4. **No new APIs, no new exports.** All changes touch existing functions / their bodies.
5. **Smoke tests assert the prompt strings contain the expected keywords**. We do NOT live-test with an LLM in CI — that's manual verification post-merge.
6. **No `:local-nicknames`**.
7. **No new `src/main.lisp` re-exports**.

---

## Files touched

| Path | Action |
|---|---|
| `src/agent.lisp` | Modify — add a paragraph to `system-prompt` under `:runtime-native` mode encouraging `code-*` for vocabulary probes |
| `src/explore.lisp` | Modify — `explore-system-prompt` gains (a) the `finding` action variant in the schema list, (b) workflow language inviting findings, (c) explicit note encouraging `code-find` / `code-describe` use when the explore policy allows them |
| `src/orchestrator.lisp` | Modify — extend `:import-from #:cl-harness/src/state` with `develop-state-set-project-summary`; new `:import-from #:cl-harness/src/project-summary #:gather-project-summary`; insert a 5-line `handler-case` block after `make-develop-state` that gathers and attaches the summary |
| `tests/agent-test.lisp` | Modify — 1 deftest asserting the runtime-native prompt mentions `code-find` / `code-describe` / `code-find-references` by name |
| `tests/explore-test.lisp` | Modify — 2 deftests: (a) prompt schema lists `finding` action, (b) prompt mentions the 4 sub-fields |
| `tests/orchestrator-test.lisp` | Modify — 1 deftest asserting `develop-state-project-summary` is non-NIL after a `develop` call |

---

## Task 1: Phase G prompt — encourage runtime-introspection probes

**Files:**
- Modify: `src/agent.lisp` — `system-prompt` defun
- Modify: `tests/agent-test.lisp`

### Step 1: Failing test

In `tests/agent-test.lisp`, append:

```lisp
(deftest runtime-native-system-prompt-encourages-code-introspection
  ;; Phase G prompt enrichment: the runtime-native system prompt
  ;; should explicitly call out code-find / code-describe /
  ;; code-find-references as the probe-of-choice for vocabulary
  ;; questions, so the LLM populates the runtime-vocabulary ledger
  ;; in production.
  (let* ((policy (make-tool-policy :runtime-native))
         (prompt (cl-harness/src/agent::system-prompt policy)))
    (ok (search "code-find" prompt))
    (ok (search "code-describe" prompt))
    (ok (search "code-find-references" prompt))
    (ok (search "vocabulary" prompt))))
```

(Add `make-tool-policy` to the test file's `:import-from` if not already there.)

### Step 2: Run — expect FAIL

`run-tests` `{"system": "cl-harness/tests"}`. `code-find-references` is currently NOT in the runtime-native prompt body. The other names ARE referenced as schema hints later but the test forces the prompt to also discuss them in the workflow.

### Step 3: Implement

In `src/agent.lisp:system-prompt`, find the `:runtime-native` branch (around lines 463-474). After the existing "PROBE first / PATCH / VERIFY / FINISH" enumeration, append:

```lisp
       (format s "When you need to know whether a function / class / package /~%")
       (format s "method exists or what its signature is, prefer code-find /~%")
       (format s "code-describe / code-find-references over re-reading source~%")
       (format s "files. These tools query the LIVE Lisp runtime — they can~%")
       (format s "see definitions loaded by other systems and they reflect~%")
       (format s "the project's current vocabulary, not just what's on disk.~%")
       (format s "The harness records each successful query as a runtime-vocab~%")
       (format s "fact for later steps.~%~%")
```

Insert this block AFTER step "4. FINISH..." but BEFORE the closing `~%` of the case branch. The exact placement depends on the existing format calls — read the file first.

### Step 4: Run — expect PASS, mallet, commit

```
git add src/agent.lisp tests/agent-test.lisp
git commit -m "feat: runtime-native prompt encourages code-* introspection (Phase G enrichment)"
```

---

## Task 2: Phase H prompt — teach the explore agent the `finding` action

**Files:**
- Modify: `src/explore.lisp` — `explore-system-prompt`
- Modify: `tests/explore-test.lisp`

### Step 1: Failing tests

Append:

```lisp
(deftest explore-system-prompt-lists-finding-action
  ;; Phase H prompt enrichment: the explore prompt must list the
  ;; finding action shape alongside tool_call / finish so the LLM
  ;; can emit structured (hypothesis probe finding decision)
  ;; tuples.
  (let ((prompt (cl-harness/src/explore:explore-system-prompt
                 (cl-harness/src/policy:make-tool-policy :explore))))
    (ok (search "\"type\":\"finding\"" prompt))
    (ok (search "hypothesis" prompt))
    (ok (search "probe" prompt))
    (ok (search "decision" prompt))))

(deftest explore-system-prompt-explains-when-to-emit-finding
  ;; A weaker readability assertion: the prompt should give a hint
  ;; about WHEN to emit a finding (not just what its shape is).
  (let ((prompt (cl-harness/src/explore:explore-system-prompt
                 (cl-harness/src/policy:make-tool-policy :explore))))
    (ok (search "REPL" prompt))
    (ok (search "promote" prompt))))
```

### Step 2: Run — expect FAIL (`finding` not yet in prompt)

### Step 3: Implement

In `src/explore.lisp:explore-system-prompt` (around lines 105-148):

**a)** Extend the action-shape list. Replace the existing two-line `format` block (lines 119-121):

```lisp
(format s "  {\"type\":\"tool_call\",\"tool\":\"<name>\",\"arguments\":{...},\"thought\":\"...\"}~%")
(format s "  {\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"<your memo>\"}~%~%")
```

with:

```lisp
(format s "  {\"type\":\"tool_call\",\"tool\":\"<name>\",\"arguments\":{...},\"thought\":\"...\"}~%")
(format s "  {\"type\":\"finding\",\"hypothesis\":\"<conjecture>\",\"probe\":\"<what you tried>\",\"finding\":\"<what you observed>\",\"decision\":\"<what to do about it>\"}~%")
(format s "  {\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"<your memo>\"}~%~%")
```

**b)** Add a paragraph between Workflow rule 2 (repl-eval is transient) and rule 3 (STOP and emit `finish`). Insert after line 127:

```lisp
(format s "  When you confirm a hypothesis with a probe (a code-find result, a~%")
(format s "  repl-eval check, an inspect-object response), record it via the~%")
(format s "  `finding` action above. Each finding becomes a typed record on~%")
(format s "  develop-state's repl-findings ledger; the implement step that~%")
(format s "  follows you sees it. The orchestrator later auto-promotes a~%")
(format s "  finding when a patch's diff matches the hypothesis text — that~%")
(format s "  way \"REPL success\" graduates to \"shipped behaviour\".~%~%")
```

### Step 4: Run — expect PASS, mallet, commit

```
git add src/explore.lisp tests/explore-test.lisp
git commit -m "feat: explore prompt teaches finding action shape (Phase H enrichment)"
```

---

## Task 3: Phase I auto-gather — orchestrator calls `gather-project-summary`

**Files:**
- Modify: `src/orchestrator.lisp`
- Modify: `tests/orchestrator-test.lisp`

### Step 1: Failing test

Append to `tests/orchestrator-test.lisp` (near other `develop-*` integration tests, after `develop-threads-develop-state-into-planner-fn`):

```lisp
(deftest develop-auto-gathers-project-summary
  ;; Phase I auto-gather: cl-harness:develop should populate
  ;; develop-state-project-summary by calling gather-project-summary
  ;; against the live project-root, so the :planning view sees the
  ;; structured summary alongside the existing project-inventory text.
  (let* ((project-root (uiop:temporary-directory))
         (test-file (merge-pathnames
                     (format nil "cl-harness-orch-tf-~A.lisp"
                             (get-universal-time))
                     project-root))
         (log-path (%tmp-path "develop-i-gather"))
         (plan-1 (list (%make-step :index 0 :test-name "alpha"
                                   :test-source "(deftest alpha (ok t))")))
         (planner-fn (%canned-planner (list plan-1)))
         (outcomes (cons (list :passed) nil))
         (runner (%fake-runner (cons '() nil) outcomes)))
    (unwind-protect
         (progn
           (%make-test-file test-file)
           (let* ((result (develop "auto-gather smoke"
                                   :project-root (namestring project-root)
                                   :system "demo"
                                   :test-system "demo/tests"
                                   :test-file test-file
                                   :log-path log-path
                                   :planner-fn planner-fn
                                   :run-fn runner))
                  (state (cl-harness/src/orchestrator:develop-result-develop-state
                          result)))
             (ok (cl-harness/src/state:develop-state-project-summary state)
                 "develop populated project-summary slot via gather-project-summary")))
      (when (probe-file test-file) (delete-file test-file))
      (when (probe-file log-path) (delete-file log-path)))))
```

(`develop-result-develop-state` may already be exported. If the existing test file's `:import-from` doesn't include it, add to that clause or use the package-qualified form as shown.)

### Step 2: Run — expect FAIL (slot is NIL today)

### Step 3: Implement

In `src/orchestrator.lisp`:

**a)** Extend `:import-from #:cl-harness/src/state` to add `#:develop-state-set-project-summary`.

**b)** Add a NEW clause:

```lisp
(:import-from #:cl-harness/src/project-summary
              #:gather-project-summary)
```

**c)** In `develop` (around line 713), after the `(let ((state (make-develop-state ...))))` form, BEFORE `(setf (develop-state-current-plan state) ...)`, insert:

```lisp
    ;; Phase I auto-gather: populate the structured project-summary
    ;; slot from disk so the :planning view sees it alongside the
    ;; legacy project-inventory text. Best-effort — a malformed
    ;; project tree returns NIL and the develop loop continues with
    ;; the inventory text alone.
    (handler-case
        (develop-state-set-project-summary
         state
         (gather-project-summary :project-root project-root
                                 :system system
                                 :test-system test-system))
      (error () nil))
```

The `handler-case` with `(error () nil)` makes this best-effort: any UIOP / file-system error returns NIL and develop continues unaffected.

### Step 4: Run — expect PASS, mallet, commit

```
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "feat: orchestrator auto-gathers project-summary on develop entry (Phase I enrichment)"
```

---

## Task 4: Lint + force-compile + docs + final review + merge

### Step 1: mallet sweep

```bash
mallet src/agent.lisp src/explore.lisp src/orchestrator.lisp \
       tests/agent-test.lisp tests/explore-test.lisp tests/orchestrator-test.lisp
```

Address `needless-let*` etc.

### Step 2: Force-compile

`(asdf:compile-system :cl-harness :force t)` — clean.

### Step 3: Test sweep

`run-tests` `{"system": "cl-harness/tests"}`. Pre-baseline: 357. Post: **361** (+4 deftests). No regressions.

### Step 4: Docs §14 trailing prose

In `docs/context-management.md` §14, append a new paragraph documenting this enrichment phase as a follow-up:

```markdown
Phase G/H/I prompt enrichment follow-up (landed 2026-05-08):
v0.5.0 のライブ verification (Qwen/Qwen3.6-35B-A3B) で発覚した
3 つの「machinery は実装済だが production で exercise されない」
ギャップを解消した。
- Phase G: agent system prompt の `:runtime-native` mode に
  `code-find` / `code-describe` / `code-find-references` を
  vocabulary probe の第一選択として推奨する段落を追記。
- Phase H: explore system prompt の action schema に
  `{"type":"finding", ...}` shape を追加し、いつ emit すべきか
  (probe で hypothesis を確認した時点) を Workflow に明記。
- Phase I: `cl-harness/src/orchestrator:develop` が
  `make-develop-state` 直後に `gather-project-summary` を best-
  effort 呼び出し、`develop-state-set-project-summary` で
  slot を populate する。これで `:planning` view が legacy
  inventory text と structured summary を併記する。
```

### Step 5: Live verification (manual, post-merge)

After merging to main, run the same Qwen3.6 smoke from
`docs/release-notes/v0.5.0.md` — expect:

- `runtime-vocabulary` non-zero when condition is `:runtime-native` and the
  task involves enough complexity to motivate probes (greenfield 100-greet
  may STILL show 0 — that fixture has nothing to probe; the test is
  whether the prompt makes it MORE likely on real tasks).
- `repl-findings` non-zero when `--mode bottom-up` triggers the explore
  sub-agent and the LLM successfully emits a `finding` action.
- `project-summary` non-NIL on every develop run (deterministic).

Document live counts in `docs/notes/2026-05-08-prompt-enrichment-live-verify.md` (new file, post-merge).

### Step 6: Final review + merge

`superpowers:code-reviewer` over the branch. Checklist:
- All 3 prompt / wiring changes are additive — no removed functionality.
- Phase I's `handler-case` is broad enough (any error → NIL, no re-raise).
- Tests assert observable behaviour, not implementation details.
- mallet clean, force-compile clean.
- No `:local-nicknames`, no new `src/main.lisp` re-exports.

`superpowers:finishing-a-development-branch` → `--no-ff` merge to main → push.

---

## Verification checklist

- [ ] `system-prompt` under `:runtime-native` mentions `code-find`, `code-describe`, `code-find-references`, `vocabulary`.
- [ ] `explore-system-prompt` lists `finding` action with all 4 sub-fields.
- [ ] `explore-system-prompt` explains WHEN to emit a finding.
- [ ] `develop` populates `develop-state-project-summary` on every successful run.
- [ ] Phase I's auto-gather is wrapped in `handler-case` and degrades gracefully on error.
- [ ] No regression in pre-Phase-enrichment test count.
- [ ] mallet clean, force-compile clean.
- [ ] §14 docs updated.

---

## Acceptance criteria

The phase is complete when:

1. The 3 prompt / wiring changes land.
2. 4 new deftests assert the prompt / slot contracts (357 → 361).
3. mallet and force-compile clean across all 6 touched files.
4. §14 docs prose mentions the follow-up.
5. Manual Qwen3.6 verification post-merge: `develop-state-project-summary`
   is non-NIL on every run; `runtime-vocabulary` and `repl-findings` populate
   on tasks that warrant them (no hard count target — qualitative
   confirmation that the LLM now USES the new action shape and the
   introspection tools when appropriate).
