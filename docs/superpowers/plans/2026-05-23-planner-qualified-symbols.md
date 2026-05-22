# planner-qualified-symbols Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add soft prompt guidance to `+default-planner-system-prompt+` instructing the planner LLM to write `test_source` with package-qualified symbols (e.g. `(counter:make-counter)`), so the test file's defpackage doesn't need to import implementation symbols.

**Architecture:** One file change — insert a 14-line block (header paragraph + counter-example) between the `Required test_source shape` template and the `Rules:` section of `+default-planner-system-prompt+`. Plus one regression deftest in `tests/planner-test.lisp` asserting the guidance string stays present.

**Tech Stack:** SBCL + ASDF, `rove` for tests. No new dependencies. Purely textual change to a defparameter.

**Spec:** `docs/superpowers/specs/2026-05-23-planner-qualified-symbols-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/planner.lisp` | Modify (~L126) | Insert qualified-symbols guidance block in `+default-planner-system-prompt+` between `Required test_source shape` template and `Rules:` section |
| `tests/planner-test.lisp` | Modify | Add `default-planner-system-prompt-includes-qualified-guidance` deftest asserting guidance + example strings are present |

No other files touched.

---

## Task 1: Add the regression deftest (driving test)

**Files:**
- Modify: `tests/planner-test.lisp`

We write the test FIRST. It will fail (the strings aren't in the prompt yet), confirming the assertion is well-formed. Task 2 inserts the prompt content to make it pass.

- [ ] **Step 1: Write the failing test**

Append to `tests/planner-test.lisp` (as a new top-level deftest, after existing deftests, before any final closing form):

```lisp
(deftest default-planner-system-prompt-includes-qualified-guidance
  (testing "system prompt mentions package-qualified test references"
    (ok (search "package-qualified"
                cl-harness/src/planner::+default-planner-system-prompt+)))
  (testing "system prompt includes the counter:make-counter example"
    (ok (search "counter:make-counter"
                cl-harness/src/planner::+default-planner-system-prompt+))))
```

`cl-harness/src/planner::+default-planner-system-prompt+` uses double-colon (internal symbol access) because the constant is defined in the planner package and may or may not be exported. Double-colon works regardless of export status.

- [ ] **Step 2: Run the test to verify it fails**

Via cl-mcp:
```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/planner-test::default-planner-system-prompt-includes-qualified-guidance"
```

Expected: BOTH testing blocks fail because neither `"package-qualified"` nor `"counter:make-counter"` is currently in the prompt.

Sanity check the full suite hasn't moved unexpectedly:
```
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 452 passed, 0 failed (was 451 baseline + 1 new failing deftest counted via... wait — failing deftests aren't counted as passed. So the count stays at 451 with 1 new failure).

Actually re-check: rove counts a deftest as either passed or failed. A deftest where 2 testing blocks fail is 1 failed deftest. So the suite shows **451 passed / 1 failed**.

- [ ] **Step 3: Commit the failing test**

This is unusual — committing a failing test is fine in TDD when we want a clean RED → GREEN history. The next task makes it pass.

```bash
git add tests/planner-test.lisp
git commit -m "test: regression deftest for qualified-symbols prompt guidance (RED)

Asserts that +default-planner-system-prompt+ contains the new
'package-qualified' guidance text and the counter:make-counter example.
Currently fails; Task 2's prompt insertion turns it GREEN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Note: if the team strongly prefers not to have a failing-test-only commit in history, you can SKIP committing here and combine Tasks 1+2 into a single commit. The RED/GREEN split is the explicit TDD-honest approach; the merged approach is also acceptable. Either way, do NOT skip writing the test before the prompt change.

---

## Task 2: Insert the qualified-symbols guidance block

**Files:**
- Modify: `src/planner.lisp` (`+default-planner-system-prompt+` at L50+)

- [ ] **Step 1: Read the current prompt structure**

Use `mcp__cl-mcp__lisp-read-file` with `name_pattern="^\\+default-planner-system-prompt\\+$"` on `src/planner.lisp` to see the current constant. The insertion anchor is between the `Required test_source shape` template (currently ending around L126 with `"      (ok (<predicate that calls the function under test>))))"`) and the `Rules:` section starting at L127.

Specifically, between these two lines:

```lisp
   "      (ok (<predicate that calls the function under test>))))"
   (string #\Newline) (string #\Newline)
   "Rules:"
```

The insertion point is RIGHT BEFORE `(string #\Newline) (string #\Newline)" Rules:"`. The new block needs to terminate with `(string #\Newline) (string #\Newline)` so the `Rules:` section is properly separated.

- [ ] **Step 2: Apply the insertion via `lisp-patch-form`**

**WARNING:** Do NOT use `lisp-edit-form` on this defparameter — the postmortem-logging branch already documented that `lisp-edit-form`'s CST round-trip corrupts backquote forms. The constant uses `(string #\Newline)` not backquote, so `lisp-edit-form` MIGHT work; but `lisp-patch-form` (text-based) is safer for this kind of in-string addition.

Use `mcp__cl-mcp__lisp-patch-form` with:
- `form_type`: `defparameter`
- `form_name`: `+default-planner-system-prompt+`
- `old_text`: (verify exact text by reading first; the snippet below assumes current spelling)
  ```
     "      (ok (<predicate that calls the function under test>))))"
     (string #\Newline) (string #\Newline)
     "Rules:"
  ```
- `new_text`:
  ```
     "      (ok (<predicate that calls the function under test>))))"
     (string #\Newline) (string #\Newline)
     "IMPORTANT: planner-authored test_source is appended to an existing "
     "test file whose defpackage is `<system>/tests/main-test (:use :cl "
     ":rove)`. This package does NOT import symbols from the implementation "
     "package automatically. Always reference target symbols with their "
     "package-qualified form so the test reads correctly without any "
     "defpackage edits."
     (string #\Newline) (string #\Newline)
     "Example (assuming `:system \"counter\"`):"
     (string #\Newline)
     "  (deftest test-make-counter"
     (string #\Newline)
     "    (testing \"default initial value\""
     (string #\Newline)
     "      (ok (eql 0 (counter:counter-value (counter:make-counter))))))"
     (string #\Newline) (string #\Newline)
     "NOT:"
     (string #\Newline)
     "  (deftest test-make-counter"
     (string #\Newline)
     "    (testing \"default initial value\""
     (string #\Newline)
     "      (ok (eql 0 (counter-value (make-counter))))))  ; will error: "
     "COUNTER/TESTS/MAIN-TEST::MAKE-COUNTER is undefined."
     (string #\Newline) (string #\Newline)
     "Rules:"
  ```

If `lisp-patch-form` fails due to whitespace mismatch (the snippet may include leading spaces from the existing indentation that vary by your read), fall back to:

1. Read the file with `Read` tool.
2. Use the `Edit` tool with `old_string` containing the exact text from the read (including leading whitespace).
3. Use `new_string` containing the insertion above.

- [ ] **Step 3: Run the regression test to verify it now passes**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests" test="cl-harness/tests/planner-test::default-planner-system-prompt-includes-qualified-guidance"
```

Expected: BOTH testing blocks pass (`"package-qualified"` and `"counter:make-counter"` are now in the prompt).

Full suite check:
```
mcp__cl-mcp__run-tests with system="cl-harness/tests"
```

Expected: 452 passed, 0 failed.

If any pre-existing planner-test deftest broke, it likely means the prompt text was scanned for a specific substring that we accidentally disrupted. Inspect the failure and adjust the insertion (most likely fix: ensure your insertion doesn't sit BETWEEN two strings that the existing code was concatenating without a separator).

- [ ] **Step 4: Commit**

```bash
git add src/planner.lisp
git commit -m "planner: prompt guidance for package-qualified test_source (GREEN)

Insert a paragraph + counter:make-counter example into
+default-planner-system-prompt+ instructing the LLM to write
test_source with package-qualified references (e.g.
(counter:make-counter)) so the test file's defpackage doesn't
need to import the implementation's symbols. Soft guidance only —
no validation gate added.

Spec: docs/superpowers/specs/2026-05-23-planner-qualified-symbols-design.md
Motivation: docs/benchmarks/results-2026-05-23-postmortem-logging-findings.md
(improvement #1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Final integration check

**Files:**
- (verification only)

- [ ] **Step 1: Force-compile entire system**

```
mcp__cl-mcp__pool-kill-worker reset=true
mcp__cl-mcp__load-system with system="cl-harness", force=true, clear_fasls=true, timeout_seconds=240
```

Expected: success. UIOP "redefining" warnings are harmless and pre-existing. Only flag warnings sourced from `:CL-HARNESS/SRC/PLANNER` or `:CL-HARNESS/TESTS/PLANNER-TEST`.

- [ ] **Step 2: Run full test suite**

```
mcp__cl-mcp__run-tests with system="cl-harness/tests", timeout_seconds=600
```

Expected: 452 passed, 0 failed (451 baseline + 1 new deftest).

- [ ] **Step 3: Mallet lint**

```bash
which mallet && mallet src/planner.lisp tests/planner-test.lisp || echo "mallet not available — skip"
```

If mallet flags issues (e.g., line >100 chars in the new string concatenation), fix in place. The inserted strings should be wrapped per the existing `concatenate 'string` pattern — each line of in-string text on its own `"..."` literal, joined by `(string #\Newline)`.

- [ ] **Step 4: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected: 2 or 3 commits depending on whether Tasks 1 and 2 were merged or kept separate:
- Task 1 commit (RED) — if separate
- Task 2 commit (GREEN)
- Optional cleanup commit (if Step 3 required fixes)

- [ ] **Step 5: If mallet or compile produced fixes, commit them**

```bash
git status
# if changes:
git add src/planner.lisp tests/planner-test.lisp
git commit -m "planner: mallet + compile-warning cleanup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (verified by author)

**Spec coverage check** (every requirement in `docs/superpowers/specs/2026-05-23-planner-qualified-symbols-design.md`):

| Spec section | Implemented in |
|---|---|
| §1 motivation | (no task — context) |
| §2 soft approach decision | Architecture |
| §3 prompt change content | Task 2 |
| §4 regression deftest | Task 1 |
| §5 backward compatibility | Task 2 (additive only; validate-test-source untouched) |
| §6 risk mitigation | Architecture (soft only) |
| §7 out of scope | Not implemented (correct) |
| §8 implementation order | Tasks 1, 2, 3 follow it |
| §9 verification (bench re-run) | Out of scope per spec; tracked as a follow-up |

**Placeholder scan:** No TBD/TODO/implement-later. The phrase "TODO: short description" mentioned in §3 of the design spec was a reference to a *different* spec (the scaffold spec's emitted .asd content); the prompt text itself contains no placeholders.

**Type consistency:**
- `+default-planner-system-prompt+` referenced consistently in Tasks 1, 2 (double-colon in tests, plain reference in source).
- Test name `default-planner-system-prompt-includes-qualified-guidance` used consistently in Task 1 (creation) and Task 2 Step 3 (re-run).
- Prompt strings `"package-qualified"` and `"counter:make-counter"` appear in both Task 1 (test assertions) and Task 2 (prompt insertion).

**Test count:** 451 → 452. ✓

No issues. Plan ready.
