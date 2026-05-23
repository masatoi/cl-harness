# max-patches-budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bump the `:max-patches` default in `make-default-limits` from 3 to 5, so per-step plans that need to add multiple forms (with the occasional tool-error) have enough budget.

**Architecture:** One-line value change in `src/config.lisp`'s `make-default-limits`, paired with the existing default-value assertion in `tests/main-test.lisp` and two PRD documentation references. No new code, no new tests, no semantic change.

**Tech Stack:** SBCL + ASDF, rove. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-23-max-patches-budget-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/config.lisp:63` | Modify (1 line) | `:max-patches 3` → `:max-patches 5` in `make-default-limits` |
| `tests/main-test.lisp:45` | Modify (1 line) | `(= 3 ...)` → `(= 5 ...)` in the `config-construction` deftest |
| `docs/cl-harness-prd.md:729` | Modify (1 line) | `max-patches = 3` → `max-patches = 5` |
| `docs/cl-harness-prd.md:871` | Modify (1 line) | `max_patches: 3` → `max_patches: 5` |

4 lines changed across 3 files. No new files.

---

## Task 1: Change the default value (source + test together)

The source and test are tightly coupled: updating one without the other breaks the suite. They land in one atomic commit. TDD-wise the "production-first" form fits a value change — we change the constant and update the assertion to match.

**Files:**
- Modify: `src/config.lisp:63`
- Modify: `tests/main-test.lisp:45`

- [ ] **Step 1: Read the current source**

Use `mcp__cl-mcp__lisp-read-file` on `src/config.lisp` with `name_pattern="^make-default-limits$"` to confirm the current shape:

```lisp
(defun make-default-limits ()
  "Return a RUN-LIMITS object populated with conservative MVP defaults."
  (make-instance 'run-limits
                 :max-turns 20
                 :max-tool-calls 80
                 :max-patches 3                 ; ← line to change
                 :max-read-files 40
                 :max-repl-evals 40
                 :max-wall-clock-seconds 600
                 :max-action-parse-errors 3
                 :max-context-tokens 50000))
```

- [ ] **Step 2: Change `:max-patches 3` to `:max-patches 5`**

Use `mcp__cl-mcp__lisp-patch-form` (text-based, no CST round-trip):

- `form_type`: `defun`
- `form_name`: `make-default-limits`
- `old_text`: `:max-patches 3`
- `new_text`: `:max-patches 5`

(The string is unique within the function body — only one occurrence of `:max-patches`.)

If `lisp-patch-form` errors on uniqueness, fall back to `Edit` tool with `old_string = "                 :max-patches 3\n"` and `new_string = "                 :max-patches 5\n"`.

- [ ] **Step 3: Run the test to see it fail**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/main-test::config-construction"
```

Expected: FAIL — the assertion `(= 3 (run-limits-max-patches (run-config-limits c)))` now sees `5`, so this `ok` call fails.

This is the RED step — the assertion is stale.

- [ ] **Step 4: Update the test assertion**

Use `mcp__cl-mcp__lisp-patch-form` on `tests/main-test.lisp`:

- `form_type`: `deftest`
- `form_name`: `config-construction`
- `old_text`: `(ok (= 3 (run-limits-max-patches (run-config-limits c))))`
- `new_text`: `(ok (= 5 (run-limits-max-patches (run-config-limits c))))`

If `lisp-patch-form` fails, use `Edit` tool with the same `old_string` / `new_string`.

- [ ] **Step 5: Run tests to verify GREEN**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/main-test::config-construction"
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: target passes; full suite 452 passed, 0 failed (no count change — we updated an existing assertion, didn't add a new deftest).

If other tests fail unexpectedly, look for places that assert against the old default value. The spec's audit suggested only `tests/main-test.lisp:45` was such a place — verify.

- [ ] **Step 6: Commit**

```bash
git add src/config.lisp tests/main-test.lisp
git commit -m "config: bump max-patches default 3 → 5

Per spec docs/superpowers/specs/2026-05-23-max-patches-budget-design.md.
Motivation: bench6 (planner-qualified-symbols verification) showed
104-cache-simple step needed 2 form additions but tool-error 1 ate the
3-attempt budget. 5 covers '2 forms + 2 tool-errors' or '3 forms + 1
tool-error'.

Backward compatible — callers passing :max-patches N explicitly keep
N. Only the default-value receivers see the bump.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Update PRD documentation

**Files:**
- Modify: `docs/cl-harness-prd.md` (2 lines)

- [ ] **Step 1: Update L729 — REQ-AGENT-003 default list**

Find the line containing `max-patches = 3` in section §8.4 REQ-AGENT-003. Currently:

```text
デフォルト:

​```text
max-patches = 3
​```
```

(The backticks above are escaped for this plan; in the actual file they're literal markdown code fences.)

Use the `Edit` tool:
- `old_string`: `max-patches = 3`
- `new_string`: `max-patches = 5`

- [ ] **Step 2: Update L871 — REQ-BENCH-001 sample task spec**

Find the line containing `max_patches: 3` in section §8 REQ-BENCH-001 (a YAML-like sample task spec). Currently:

```yaml
limits:
  max_turns: 20
  max_tool_calls: 80
  max_patches: 3
```

Use the `Edit` tool:
- `old_string`: `max_patches: 3`
- `new_string`: `max_patches: 5`

- [ ] **Step 3: Verify no other PRD mention exists**

```bash
grep -n "max-patches\|max_patches" /home/wiz/.roswell/local-projects/cl-harness/docs/cl-harness-prd.md
```

Expected: 3 hits (line 493 mentions `max-patches` in passing, lines 729 and 871 with the new value `5`). If line 493 is a value mention (not just the field name), update it too.

- [ ] **Step 4: Commit**

```bash
git add docs/cl-harness-prd.md
git commit -m "docs: PRD max-patches default 3 → 5

Match the bumped default in src/config.lisp:make-default-limits.
Two mentions updated: §8.4 REQ-AGENT-003 default list, and the
REQ-BENCH-001 sample task spec YAML.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Final integration check

**Files:**
- (verification only)

- [ ] **Step 1: Force-compile**

```
mcp__cl-mcp__pool-kill-worker reset=true
mcp__cl-mcp__load-system with system="cl-harness", force=true, clear_fasls=true, timeout_seconds=240
```

Expected: success, no new style-warnings from `:CL-HARNESS/SRC/CONFIG`.

- [ ] **Step 2: Full test suite**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests", timeout_seconds=600
```

Expected: 452 passed, 0 failed (no count change vs baseline).

- [ ] **Step 3: Mallet lint**

```bash
which mallet && mallet src/config.lisp tests/main-test.lisp || echo "mallet not available — skip"
```

Expected: no issues — the change is a single character (`3` → `5`).

- [ ] **Step 4: Confirm commit log**

```bash
git log --oneline main..HEAD
```

Expected: 2 commits (Tasks 1 and 2). No cleanup needed since this is a trivial value change.

- [ ] **Step 5: Spot-check the change end-to-end via REPL**

```
mcp__cl-mcp__repl-eval with code="(cl-harness/src/config:run-limits-max-patches (cl-harness/src/config:make-default-limits))"
```

Expected output: `5`

This confirms the default is wired through.

---

## Self-Review (verified by author)

**Spec coverage check** (every requirement in `docs/superpowers/specs/2026-05-23-max-patches-budget-design.md`):

| Spec section | Implemented in |
|---|---|
| §2.1 source 1-line change | Task 1 |
| §2.2 test assertion update | Task 1 |
| §2.3 PRD two-spot update | Task 2 |
| §3 test strategy (existing assertion regression-detects) | Task 1 |
| §4 backward compat (no kwarg shape change) | Architecture; no new code paths |
| §5 risks (pass-rate variation, token cost) | Bench-time concern, not test-time |
| §6 out of scope (option B, option D, retroactive bench updates) | Not implemented (correct) |
| §7 implementation order | Tasks 1, 2, 3 follow it |
| §8 verification (bench re-run) | Out of scope per spec; tracked as a follow-up |

**Placeholder scan:** No TBD/TODO. The PRD updates contain `max_patches: 3` etc. that are the literal old text we are replacing — not placeholders, but precise edit targets.

**Type consistency:**
- The value `5` appears identically in Task 1 Step 2 (`:max-patches 5`), Task 1 Step 4 (`(= 5 ...)`), Task 2 Step 1 (`max-patches = 5`), Task 2 Step 2 (`max_patches: 5`), and Task 3 Step 5 (`5` as REPL output expectation).
- Function name `make-default-limits` used consistently.
- Accessor name `run-limits-max-patches` used consistently.

**Test count:** 452 → 452 (no new tests). ✓

No issues. Plan ready.
