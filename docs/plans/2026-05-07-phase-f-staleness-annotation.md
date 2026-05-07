# Phase F: Staleness annotation in `:exploration` context-view Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wire Phase E's `source-fact-stale-p` predicate into the context-view's `:exploration` formatter so source-facts whose underlying file has been modified since the read are rendered with a `[STALE]` prefix, giving the LLM a clear signal that cached read content may be outdated.

**Architecture:** A small surgical change to `context-view->string :exploration` (`src/context-view.lisp`): the existing per-fact bullet renderer gets a 1-line `(when (source-fact-stale-p fact) ...)` prefix. The constructor (`make-context-view`) is UNCHANGED — the staleness check happens at render time, not at construction time, so the same `relevant-source-facts` slot can be inspected by both the renderer (for annotation) and the structured report (Phase E's `format-develop-state-report`'s aggregate stale-count, already in place). `:implementation` formatter is intentionally NOT touched (per Phase C: the agent's tool calls are the authoritative read log there). The standalone `cl-harness:fix` path is unaffected; the change is local to one defmethod and one rendered section.

**Tech stack:** Common Lisp (SBCL), ASDF `:package-inferred-system`, rove tests. Phase A-E patterns apply: cl-mcp tools for Lisp source modifications; `:import-from` only; docstrings on public symbols; tests assert on substring presence (not exact byte sequences).

**Out of scope (deferred):**
- **Filtering stale facts** (the design choice was annotate rather than exclude — see plan rationale below).
- **Annotating stale facts in `:implementation` formatter** — Phase C deliberately omits source-facts from `:implementation` (the agent's own tool calls are the read log). Don't change that.
- **Patch-record-aware staleness** — `source-fact-stale-p` already returns T after a patch lands on the same file (the patch bumps the file's mtime, and the predicate compares mtime-at-read vs current mtime). No additional patch-record cross-reference is needed.
- **Runtime-vocabulary staleness** — Phase B' (separate plan); the runtime-vocabulary ledger doesn't exist yet, so there's nothing to invalidate.
- **Caching `file-write-date` results** — Phase F's MVP performs ~1 syscall per source-fact per `make-context-view` call. With `make-context-view` invoked ~10 times per run and ~20 facts each call, that's ~200 syscalls per run — negligible. Phase G can add caching if profiling surfaces it.
- **`:planning` view** — Phase E's `:planning` formatter doesn't render source-facts (it shows project inventory and the plan); no staleness work applies.

**Acceptance criteria:**
1. The `:exploration` formatter emits `[STALE] <path> ...` (with bracketed prefix) for any rendered source-fact whose `source-fact-stale-p` returns T. Fresh facts continue to render exactly as before — no prefix.
2. The constructor `make-context-view` is unchanged. The staleness check is render-time.
3. `tests/context-view-test.lisp` gains 3-4 deftests covering: (a) fresh fact has no `[STALE]` prefix, (b) stale fact has `[STALE]` prefix, (c) mixed fresh+stale rendering preserves both behaviors per fact.
4. Full `cl-harness/tests` rove suite passes via cl-mcp `run-tests` — Phase E baseline 283/0 plus the new tests, zero regressions.
5. `:implementation` formatter is untouched (per Phase C design).
6. mallet clean on Phase F-touched files.
7. `(asdf:compile-system :cl-harness :force t)` clean.
8. `docs/context-management.md` §14 updated to mark Phase F landed; §9 (Staleness) marked addressed for source-facts in `:exploration` views.

**Risks & mitigations:**

- **R1: The `[STALE]` prefix changes the prompt text the LLM sees.** Existing happy-path agent tests stub the LLM, so they don't observe the prompt; tests should still pass. But a real model run would see new tokens. → The signal is intentional; `[STALE]` is a clear, terse marker. Agent tests pass empirically (verified during Phase F.1's TDD cycle).
- **R2: `source-fact-stale-p` calls `file-write-date` per fact, per render.** ~200 syscalls per run; negligible. → MVP doesn't add caching; Phase G refines if needed.
- **R3: Test files written by deftests for staleness verification need cleanup.** Phase E's pattern uses `unwind-protect` + `delete-file`. → Mirror that pattern.
- **R4: A stale fact renders `[STALE]` even when the file's mtime change was unrelated to actual content (e.g. `touch` without modification).** Acceptable — the predicate's contract is "mtime moved forward"; that's a useful signal even if not strictly correlated with content change. Phase G could refine via content hashing if needed.

**Working agreement:**
- cl-mcp tools (`lisp-edit-form`, `lisp-patch-form`, `lisp-read-file`, `repl-eval`, `run-tests`) for Lisp source modifications.
- First action of every implementation session: cl-mcp `fs-set-project-root` on the repo root.
- Commit after each green TDD cycle. Use feature branch `phase-f-staleness-annotation`.

---

## Task 1: Annotate stale source-facts with `[STALE]` prefix in `:exploration` formatter

**Files:**
- Modify: `src/context-view.lisp` — add 1 `:import-from #:cl-harness/src/source-fact #:source-fact-stale-p` symbol; modify the `:exploration` method's per-fact rendering.
- Modify: `tests/context-view-test.lisp` — add 3-4 deftests.

### Step 1.1: Survey

cl-mcp `lisp-read-file src/context-view.lisp` `name_pattern="^context-view->string$"` (or read collapsed=false to see the file). Identify:
- The exact line where the `:exploration` method renders source-facts. Per the Phase F survey it's around lines 247-253:
  ```lisp
  (let ((facts (context-view-relevant-source-facts view)))
    (when facts
      (format s "~%## Source already read in this step~%")
      (dolist (fact facts)
        (format s "- ~A~A~%"
                (namestring (source-fact-path fact))
                (if (source-fact-form-name fact)
                    (format nil " :: ~A ~A"
                            (or (source-fact-form-type fact) "")
                            (source-fact-form-name fact))
                    "")))))
  ```
- The existing `:import-from #:cl-harness/src/source-fact` clause in the defpackage. Per Phase E it imports `source-fact-related-step-index`, `source-fact-path`, `source-fact-form-type`, `source-fact-form-name`. Phase F adds `source-fact-stale-p`.

### Step 1.2: Failing tests

Append to `tests/context-view-test.lisp` (after the last existing deftest). Update the `:import-from #:cl-harness/src/source-fact` clause if the test file has one (verify via reading); if not, the tests can use the package-qualified form `cl-harness/src/source-fact:make-source-fact` (already present per Phase E patterns).

```lisp
(deftest exploration-formatter-renders-stale-prefix-on-stale-fact
  ;; Construct a temp file, record a source-fact with an OLDER baseline
  ;; mtime, then generate the :exploration view and verify the bullet
  ;; for that fact has the [STALE] prefix.
  (let* ((path #P"/tmp/cl-harness-cv-stale-test.lisp")
         (s (%state)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (progn
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path path
               :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read 100))
           (let* ((v (make-context-view s :phase :exploration
                                          :step (%step :index 0)))
                  (out-str (context-view->string v :exploration)))
             (ok (search "[STALE]" out-str))
             (ok (search (namestring path) out-str))))
      (when (probe-file path) (delete-file path)))))

(deftest exploration-formatter-omits-stale-prefix-on-fresh-fact
  ;; Construct a temp file, record a source-fact whose mtime-at-read
  ;; equals the current file mtime (fresh); verify [STALE] is absent.
  (let* ((path #P"/tmp/cl-harness-cv-fresh-test.lisp")
         (s (%state)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (progn
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path path
               :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read (file-write-date path)))
           (let* ((v (make-context-view s :phase :exploration
                                          :step (%step :index 0)))
                  (out-str (context-view->string v :exploration)))
             (ok (search (namestring path) out-str))
             (ok (not (search "[STALE]" out-str)))))
      (when (probe-file path) (delete-file path)))))

(deftest exploration-formatter-renders-mixed-stale-and-fresh
  ;; Two facts on different files: one stale, one fresh. Both render,
  ;; but only the stale one has the [STALE] prefix.
  (let* ((stale-path #P"/tmp/cl-harness-cv-mix-stale.lisp")
         (fresh-path #P"/tmp/cl-harness-cv-mix-fresh.lisp")
         (s (%state)))
    (with-open-file (out stale-path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
      (write-string "(defun a () 1)" out))
    (with-open-file (out fresh-path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
      (write-string "(defun b () 2)" out))
    (unwind-protect
         (progn
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path stale-path :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read 100))
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path fresh-path :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read (file-write-date fresh-path)))
           (let* ((v (make-context-view s :phase :exploration
                                          :step (%step :index 0)))
                  (out-str (context-view->string v :exploration)))
             ;; Stale fact gets the prefix; fresh fact does not.
             (ok (search (format nil "[STALE] ~A" (namestring stale-path))
                         out-str))
             (ok (search (namestring fresh-path) out-str))
             ;; Find the bullet line for the fresh path and verify
             ;; [STALE] is NOT immediately preceding it.
             (let ((fresh-pos (search (namestring fresh-path) out-str)))
               (ok (or (not fresh-pos)
                       (not (search "[STALE]"
                                    (subseq out-str
                                            (max 0 (- fresh-pos 10))
                                            fresh-pos))))))))
      (when (probe-file stale-path) (delete-file stale-path))
      (when (probe-file fresh-path) (delete-file fresh-path)))))
```

The tests use the existing `%state` helper (defined in Phase E.2) and `%step` helper (defined in Phase C Task 4). Verify both exist via `clgrep-search` in `tests/context-view-test.lisp`; they should.

### Step 1.3: Red

cl-mcp `run-tests cl-harness/tests/context-view-test`. Expected: 3 new tests fail because `[STALE]` prefix isn't in the output yet.

### Step 1.4: Implement

Use cl-mcp `lisp-patch-form` on `src/context-view.lisp`'s defpackage to add `#:source-fact-stale-p` to the existing `:import-from #:cl-harness/src/source-fact` clause:

- `path`: `src/context-view.lisp`
- `form_type`: `defpackage`
- `form_name`: `#:cl-harness/src/context-view`
- `old_text`: `#:source-fact-form-name)` (the closing of the source-fact import clause)
- `new_text`: `#:source-fact-form-name\n                #:source-fact-stale-p)`

`dry_run: true` first. (Verify the exact form of the existing closing — the implementer should read the defpackage first to confirm the source-fact `:import-from` clause's last symbol is `#:source-fact-form-name`.)

Then use cl-mcp `lisp-edit-form` (or `lisp-patch-form`) on the `:exploration` method's per-fact bullet to add the staleness prefix. The current rendering line is approximately:

```lisp
        (dolist (fact facts)
          (format s "- ~A~A~%"
                  (namestring (source-fact-path fact))
                  (if (source-fact-form-name fact)
                      (format nil " :: ~A ~A"
                              (or (source-fact-form-type fact) "")
                              (source-fact-form-name fact))
                      "")))
```

Change to:

```lisp
        (dolist (fact facts)
          (format s "- ~A~A~A~%"
                  (if (source-fact-stale-p fact) "[STALE] " "")
                  (namestring (source-fact-path fact))
                  (if (source-fact-form-name fact)
                      (format nil " :: ~A ~A"
                              (or (source-fact-form-type fact) "")
                              (source-fact-form-name fact))
                      "")))
```

The change adds:
- A new `~A` placeholder at position 1 (before the path).
- A new `(if (source-fact-stale-p fact) "[STALE] " "")` argument that emits `"[STALE] "` (with trailing space) when stale, empty string otherwise.

Use `lisp-patch-form` with the exact `dolist` form as `old_text` and the new version as `new_text`. `dry_run: true` first; verify the match is unique.

If `lisp-patch-form` is too brittle (e.g. the surrounding form has multiple `dolist` clauses), use `lisp-edit-form replace` on the entire `(eql :exploration)` defmethod with the full replacement body.

### Step 1.5: Verify green

cl-mcp `lisp-check-parens` on `src/context-view.lisp`.
cl-mcp `load-system` `{"system": "cl-harness", "force": true}` — clean.
cl-mcp `run-tests cl-harness/tests/context-view-test` — expect prior 21 deftests + 3 new = 24/0.
cl-mcp `run-tests cl-harness/tests` — expect 286/0 (was 283, +3).

If any pre-existing context-view-test deftest regresses, **STOP and diagnose**. Likely cause: the existing `exploration-formatter-summarises-relevant-source-facts` test (Phase C.4) might have been asserting a substring match like `"- /tmp/cv-test/src/greet.lisp"` that no longer matches because the new `~A` adds an empty prefix `""` (no change for fresh facts, so should be unaffected) OR the format directive ordering changed. Verify by reading the existing test.

### Step 1.6: Commit

```bash
git checkout -b phase-f-staleness-annotation
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "$(cat <<'EOF'
feat: annotate stale source-facts with [STALE] prefix in :exploration view (Phase F)

The :exploration formatter now consults SOURCE-FACT-STALE-P
(introduced in Phase E.1) for each rendered source-fact and
prefixes "[STALE] " on the bullet when the file's on-disk mtime
has advanced beyond MTIME-AT-READ. Fresh facts render exactly as
before — no prefix.

The check is render-time (not constructor-time), so MAKE-CONTEXT-
VIEW is unchanged and Phase E's structured report continues to
consume the same RELEVANT-SOURCE-FACTS slot for its aggregate
stale-count line.

Three new deftests in tests/context-view-test.lisp cover the
stale, fresh, and mixed cases. Test fixtures use unwind-protect
+ delete-file for cleanup, mirroring Phase E's pattern.

The :implementation formatter is intentionally untouched — per
Phase C design, the agent's own tool calls are the authoritative
read log there; staleness is irrelevant.

Phase F of the context-management refactor
(docs/plans/2026-05-07-phase-f-staleness-annotation.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Lint + force-compile + regression sweep

Mirrors Phase A-E lint-sweep tasks.

### Steps

1. `mallet src/context-view.lisp tests/context-view-test.lisp` — fix any new warnings on Phase F files. Use Option A (no worktree) per Phase C/D lessons, OR place worktree OUTSIDE `~/.roswell/local-projects/`.
2. `(asdf:compile-system :cl-harness :force t)` via cl-mcp `repl-eval` — clean.
3. cl-mcp `run-tests` `{"system": "cl-harness/tests"}` — confirm pre-existing pass count + new Phase F tests, all passing (286/0 expected).
4. Shell `rove cl-harness.asd` — same pre-existing 5-failure set in `develop-bench-test`, no new failures.
5. Commit only if mallet required fixes.

---

## Task 3: Docs annotation + final review + merge

### Step 3.1: Update `docs/context-management.md` §14

Mark Phase F landed; §9 (Staleness) addressed for source-facts in `:exploration` views.

The §14 table currently has Phase E as the last entry. Append:

```markdown
| F | `source-fact-stale-p` の context-view 配線 (`:exploration` formatter で `[STALE]` prefix を render-time 付与) | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-f-staleness-annotation.md` |
```

Update the trailing paragraph to note that §9 is now addressed for source-fact staleness in `:exploration` views; runtime-vocabulary staleness remains for Phase B' / G.

### Step 3.2: Final code review

`superpowers:code-reviewer` over the entire `phase-f-staleness-annotation` branch. Checklist:
- The `:exploration` method's diff is minimal — one new `:import-from` symbol + one extra `~A` placeholder + one extra format argument.
- `:implementation` formatter is untouched.
- `make-context-view` constructor is untouched.
- Pre-existing context-view tests still pass.
- mallet clean, force-compile clean.
- No `:local-nicknames`.
- Test fixtures clean up temp files via `unwind-protect`.

### Step 3.3: Merge to main

`superpowers:finishing-a-development-branch`, `--no-ff` merge with summary highlighting:
- The `[STALE]` prefix annotation in `:exploration` views.
- Render-time check (no constructor change).
- `:implementation` deliberately untouched.
- §9 now addressed for source-facts.
- Phase G can extend the same pattern when runtime-vocabulary lands.

---

## Verification checklist (before opening a PR)

- [ ] `:exploration` formatter renders `[STALE] <path>` for stale facts
- [ ] Fresh facts render without prefix (existing behavior preserved)
- [ ] `make-context-view` constructor unchanged
- [ ] `:implementation` formatter unchanged
- [ ] 3 new deftests in `tests/context-view-test.lisp` pass
- [ ] No regression in pre-existing context-view-test (24/0 vs prior 21/0 = +3)
- [ ] mallet clean on Phase F files
- [ ] `(asdf:compile-system :cl-harness :force t)` clean
- [ ] Full `cl-harness/tests` rove suite green (286/0)
- [ ] `docs/context-management.md` §14 updated

## Rollback plan

If any regression surfaces:

1. Phase F is a single ~3-line change to one defmethod. `git revert` on the Task 1 commit restores the prior `:exploration` rendering exactly.
2. The new tests are independent additions; they can be left in place (they'll fail until the impl returns), or reverted alongside.
3. The `source-fact-stale-p` predicate (Phase E.1) is unaffected; the structured report's aggregate stale-count continues to work.

The single-file, single-method change makes Phase F the lowest-risk phase in the series.

## Beyond Phase F

Outstanding items for future plans:

- **Phase G (runtime-vocabulary)**: Phase B' deferred work; structured packages/exports/classes/generics ledger via `repl-eval` introspection. Phase F's staleness pattern can mirror onto runtime state once that ledger exists.
- **Phase H (orchestrator → planner-fn full wiring)**: Phase C's deferred FIXME; thread `:develop-state` into `funcall planner-fn` calls. Validate ordering deviation against a real model first.
- **Replacing `format-final-report`**: agent-loop reporter for `cl-harness:fix` could be replaced with a state-derived equivalent; today it reads agent-state counters directly.
- **`:patch` event linkage**: future enhancement could expose a `find-source-facts-for-path` helper for use cases beyond staleness (e.g. patch-record cross-references in reports).

These items are independent of Phase F and can ship in any order.
