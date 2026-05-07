# Phase H — REPL Finding Ledger Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Capture exploration findings as **structured `(hypothesis probe finding decision)` records** on `develop-state`, distinguished from source mutations and from natural-language `ADOPTED:`/`REJECTED:`/`DEFERRED:` markers. The ledger surfaces in `:exploration` and `:implementation` views so the LLM can see what's been tried, what worked, and — critically — **whether REPL-confirmed behaviour has been promoted to source** ("REPL success ≠ implemented", §3.6).

**Architecture:**
- **New module** `src/repl-finding.lisp`: a record class `repl-finding` with four required text fields (`hypothesis`, `probe`, `finding`, `decision`) plus optional `promoted-to-source-p` / `linked-patch` / `linked-source-fact` references and the standard `:related-step-index` / `:recorded-at` metadata.
- **New slot** `repl-findings` on `develop-state`. Recorder + reader follow the `source-fact` / `patch-record` / `runtime-vocab-fact` shape.
- **Recording is explicit**, not inferred. The explore agent emits structured findings (a `finding` action variant alongside `finish` / `give_up` / tool calls) which the explore loop persists; the orchestrator can also append findings post-hoc when promoting an exploration outcome to a source patch.
- **Promotion linkage:** when a patch lands that implements an idea recorded as a finding, the orchestrator (or a small helper in `agent.lisp`) sets `promoted-to-source-p` / `linked-patch` on the matching finding. Best-effort by `:hypothesis` text equality with case folding; **no fuzzy matching** in the MVP.
- **`:exploration` view** lists findings in observation order, with a `[PROMOTED]` annotation when `promoted-to-source-p` is T. **`:implementation` view** lists only findings that are **not yet promoted** (so the agent sees "things to actually implement").

**Tech Stack:** SBCL / ASDF `:package-inferred-system` / Rove tests / alexandria / `:import-from` + `:export` only (no `:local-nicknames`).

---

## Why this phase

`docs/context-management.md` §3.6 and §6.2 describe a deliberate REPL transcript → finding compression with the rule **"REPL success != implemented"**. Phase B's `parse-abstraction-decisions` (`src/abstraction.lisp`) catches `ADOPTED:` / `REJECTED:` / `DEFERRED:` markers from explore memos but treats them as flat naming decisions, not the four-tuple §6.2 prescribes. The result is that:

1. Hypotheses and probes are **lost** the moment the explore step closes — only the decision survives.
2. The `:implementation` view has **no way to distinguish** "we proved this works in the REPL" from "we shipped this to source".
3. There's no place for findings produced **outside the explore loop** (the agent loop itself sometimes uses `repl-eval` to verify an idea before patching).

Phase H adds the structured ledger and threads it through the same view machinery Phase C built. The new record is a peer to `source-fact` / `patch-record` / `runtime-vocab-fact`, not a replacement for `abstraction-decision` — `abstraction-decision` continues to track ADOPTED/REJECTED/DEFERRED naming choices; `repl-finding` tracks the hypothesis-probe-finding-decision narrative behind them.

---

## Design contract (do not deviate without confirming)

1. **Single record class.** Four required string fields + four optional metadata fields. No subclassing per finding "kind" — that's a `decision`-text concern, not a class concern.
2. **Promotion is a pure flag, not a workflow.** `promoted-to-source-p` is a slot accessor (no setf — use a single helper `repl-finding-mark-promoted`) and an optional `linked-patch` pointer. The orchestrator decides when to flip it; the record class doesn't enforce a state machine.
3. **No automatic finding extraction from raw REPL transcripts.** Phase H requires the agent to emit a `finding` action explicitly (extending `src/action.lisp`'s parser). Inferring four-tuples from natural language is out of scope.
4. **Record validation is structural only.** Each of `hypothesis` / `probe` / `finding` / `decision` must be a non-empty string. We do NOT police content (length, language, sensibility) — that's an LLM-prompt concern.
5. **`:implementation` view filters by promotion**, `:exploration` view does not. Both list findings in observation order.
6. **No re-export from `src/main`** until at least one external caller asks for it. Keep symbols internal.
7. **Record sites are deliberate.** Phase H wires the explore loop and the orchestrator's post-step hook. The agent loop's `repl-eval` recorder is **deferred** (Phase H follow-up if needed).

---

## Files touched

| Path | Action |
|---|---|
| `src/repl-finding.lisp` | **Create** — record class, constructor, promotion helper |
| `src/state.lisp` | Modify — `repl-findings` slot + recorder + reader |
| `src/action.lisp` | Modify — extend parser to recognise `finding` action shape |
| `src/explore.lisp` | Modify — explore loop persists `finding` actions to develop-state |
| `src/orchestrator.lisp` | Modify — post-step hook flips `promoted-to-source-p` when a patch lands matching a finding's hypothesis |
| `src/context-view.lisp` | Modify — view slot + filter; `:exploration` and `:implementation` formatters |
| `cl-harness.asd` | Modify — add `cl-harness/tests/repl-finding-test` to test deps |
| `tests/repl-finding-test.lisp` | **Create** — unit tests for the new module |
| `tests/state-test.lisp` | Modify — slot + recorder tests |
| `tests/action-test.lisp` | Modify — parser tests for `finding` action |
| `tests/context-view-test.lisp` | Modify — `:exploration` and `:implementation` rendering tests |

---

## Task 1: `repl-finding` data module

**Files:**
- Create: `src/repl-finding.lisp`
- Create: `tests/repl-finding-test.lisp`
- Modify: `cl-harness.asd`

### Step 1: Failing tests

Create `tests/repl-finding-test.lisp`:

```lisp
;;;; tests/repl-finding-test.lisp

(defpackage #:cl-harness/tests/repl-finding-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/repl-finding
                #:repl-finding
                #:make-repl-finding
                #:repl-finding-hypothesis
                #:repl-finding-probe
                #:repl-finding-finding
                #:repl-finding-decision
                #:repl-finding-promoted-to-source-p
                #:repl-finding-linked-patch
                #:repl-finding-linked-source-fact
                #:repl-finding-related-step-index
                #:repl-finding-recorded-at
                #:repl-finding-mark-promoted))

(in-package #:cl-harness/tests/repl-finding-test)

(deftest make-repl-finding-records-required-fields
  (let ((f (make-repl-finding
            :hypothesis "aggregation as pure function suffices"
            :probe "(reduce #'+ '(1 2 3)) -> 6"
            :finding "pure function works for current scope"
            :decision "promote ordinary function, not macro")))
    (ok (typep f 'repl-finding))
    (ok (string= "aggregation as pure function suffices"
                 (repl-finding-hypothesis f)))
    (ok (string= "(reduce #'+ '(1 2 3)) -> 6"
                 (repl-finding-probe f)))
    (ok (string= "pure function works for current scope"
                 (repl-finding-finding f)))
    (ok (string= "promote ordinary function, not macro"
                 (repl-finding-decision f)))
    (ok (null (repl-finding-promoted-to-source-p f)))
    (ok (integerp (repl-finding-recorded-at f)))))

(deftest make-repl-finding-rejects-empty-hypothesis
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "" :probe "p"
                               :finding "f" :decision "d")
            nil)
        (error () t))))

(deftest make-repl-finding-rejects-empty-probe
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "h" :probe ""
                               :finding "f" :decision "d")
            nil)
        (error () t))))

(deftest make-repl-finding-rejects-empty-finding
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "h" :probe "p"
                               :finding "" :decision "d")
            nil)
        (error () t))))

(deftest make-repl-finding-rejects-empty-decision
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "h" :probe "p"
                               :finding "f" :decision "")
            nil)
        (error () t))))

(deftest mark-promoted-flips-flag-and-stores-patch
  (let ((f (make-repl-finding :hypothesis "h" :probe "p"
                              :finding "f" :decision "d")))
    (ok (null (repl-finding-promoted-to-source-p f)))
    (repl-finding-mark-promoted f :linked-patch :sentinel-patch)
    (ok (eq t (repl-finding-promoted-to-source-p f)))
    (ok (eq :sentinel-patch (repl-finding-linked-patch f)))))

(deftest mark-promoted-is-idempotent
  (let ((f (make-repl-finding :hypothesis "h" :probe "p"
                              :finding "f" :decision "d")))
    (repl-finding-mark-promoted f :linked-patch :patch1)
    (repl-finding-mark-promoted f :linked-patch :patch2)
    ;; The first call wins; second is a no-op.
    (ok (eq :patch1 (repl-finding-linked-patch f)))))
```

Update `cl-harness.asd` test deps to add `"cl-harness/tests/repl-finding-test"`.

### Step 2: Run — expect FAIL on package not found

### Step 3: Implement `src/repl-finding.lisp`

```lisp
;;;; src/repl-finding.lisp
;;;;
;;;; Phase H of the context-management refactor
;;;; (docs/context-management.md §3.6 + §6.2). One repl-finding
;;;; captures the structured (hypothesis probe finding decision)
;;;; tuple from one exploration episode, plus a "promoted to source"
;;;; flag distinguishing REPL success from shipped behaviour.
;;;;
;;;; Phase H only RECORDS findings. Phase C-style context-view
;;;; consumption surfaces them in :exploration / :implementation
;;;; views; promotion linkage is set by the orchestrator when a
;;;; patch lands matching a recorded hypothesis.

(defpackage #:cl-harness/src/repl-finding
  (:use #:cl)
  (:export #:repl-finding
           #:make-repl-finding
           #:repl-finding-hypothesis
           #:repl-finding-probe
           #:repl-finding-finding
           #:repl-finding-decision
           #:repl-finding-promoted-to-source-p
           #:repl-finding-linked-patch
           #:repl-finding-linked-source-fact
           #:repl-finding-related-step-index
           #:repl-finding-recorded-at
           #:repl-finding-mark-promoted))

(in-package #:cl-harness/src/repl-finding)

(defclass repl-finding ()
  ((hypothesis :initarg :hypothesis :reader repl-finding-hypothesis
               :documentation "The conjecture under test, as a
non-empty string.")
   (probe :initarg :probe :reader repl-finding-probe
          :documentation "Short description of the REPL probe used
to test the hypothesis (the action the agent took, not the raw
transcript).")
   (finding :initarg :finding :reader repl-finding-finding
            :documentation "The observed result of the probe — what
was learned. Non-empty.")
   (decision :initarg :decision :reader repl-finding-decision
             :documentation "The design decision the finding drives:
'promote ordinary function', 'reject macro approach', etc.
Non-empty.")
   (promoted-to-source-p :initform nil
                         :reader repl-finding-promoted-to-source-p
                         :documentation "T after a patch implementing
this finding has landed; NIL while the finding remains REPL-only.
Set via REPL-FINDING-MARK-PROMOTED.")
   (linked-patch :initform nil
                 :reader repl-finding-linked-patch
                 :documentation "PATCH-RECORD attributed for the
promotion, or NIL when no clear-cut attribution.")
   (linked-source-fact :initform nil
                       :reader repl-finding-linked-source-fact
                       :documentation "SOURCE-FACT attributed for
the promotion, or NIL.")
   (related-step-index :initarg :related-step-index
                       :reader repl-finding-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the active
step, or NIL outside a develop run.")
   (recorded-at :initarg :recorded-at :reader repl-finding-recorded-at
                :documentation "GET-UNIVERSAL-TIME at record time."))
  (:documentation
   "One structured exploration episode: a hypothesis, the probe used
to test it, the finding observed, and the decision that follows.
Promotion linkage tracks whether the decision has been shipped to
source."))

(defun %require-non-empty-string (name value)
  (unless (and (stringp value) (plusp (length value)))
    (error "repl-finding: :~A must be a non-empty string, got ~S"
           name value)))

(defun make-repl-finding (&key hypothesis probe finding decision
                            related-step-index
                            (recorded-at (get-universal-time)))
  "Construct a REPL-FINDING. All four text fields are required and
must be non-empty strings."
  (%require-non-empty-string "hypothesis" hypothesis)
  (%require-non-empty-string "probe" probe)
  (%require-non-empty-string "finding" finding)
  (%require-non-empty-string "decision" decision)
  (when related-step-index (check-type related-step-index integer))
  (make-instance 'repl-finding
                 :hypothesis hypothesis
                 :probe probe
                 :finding finding
                 :decision decision
                 :related-step-index related-step-index
                 :recorded-at recorded-at))

(defun repl-finding-mark-promoted (finding &key linked-patch
                                             linked-source-fact)
  "Flip FINDING's promoted-to-source-p flag and attach the patch /
source-fact reference. Idempotent: a second call on a finding whose
flag is already T is a no-op (existing linkage is preserved).
Returns FINDING."
  (when (repl-finding-promoted-to-source-p finding)
    (return-from repl-finding-mark-promoted finding))
  (setf (slot-value finding 'promoted-to-source-p) t
        (slot-value finding 'linked-patch) linked-patch
        (slot-value finding 'linked-source-fact) linked-source-fact)
  finding)
```

### Step 4: Run — expect PASS on the 7 new deftests

### Step 5: Commit

```
git add src/repl-finding.lisp tests/repl-finding-test.lisp cl-harness.asd
git commit -m "feat: repl-finding record class (Phase H)"
```

---

## Task 2: `repl-findings` slot on `develop-state`

**Files:**
- Modify: `src/state.lisp`
- Modify: `tests/state-test.lisp`

Add tests that exercise `develop-state-record-repl-finding` / `develop-state-repl-findings` in the same shape as the source-fact / patch-record tests already in `tests/state-test.lisp`:

```lisp
(deftest develop-state-records-repl-findings-in-order
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (f1 (cl-harness/src/repl-finding:make-repl-finding
             :hypothesis "h1" :probe "p1" :finding "fnd1" :decision "d1"))
        (f2 (cl-harness/src/repl-finding:make-repl-finding
             :hypothesis "h2" :probe "p2" :finding "fnd2" :decision "d2")))
    (cl-harness/src/state:develop-state-record-repl-finding s f1)
    (cl-harness/src/state:develop-state-record-repl-finding s f2)
    (let ((findings (cl-harness/src/state:develop-state-repl-findings s)))
      (ok (= 2 (length findings)))
      (ok (string= "h1" (cl-harness/src/repl-finding:repl-finding-hypothesis
                         (first findings))))
      (ok (string= "h2" (cl-harness/src/repl-finding:repl-finding-hypothesis
                         (second findings)))))))

(deftest develop-state-repl-findings-defaults-to-empty
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests")))
    (ok (null (cl-harness/src/state:develop-state-repl-findings s)))))
```

In `src/state.lisp`:
- Append `#:develop-state-repl-findings` and `#:develop-state-record-repl-finding` to the `:export` list.
- Add a `repl-findings` slot to `develop-state`:

```lisp
(repl-findings :initform nil :accessor %repl-findings
               :documentation "Reverse-chronological list of
REPL-FINDING instances. Internal; public reader is
DEVELOP-STATE-REPL-FINDINGS.")
```

- Add the recorder + reader (mirror `develop-state-record-source-fact`):

```lisp
(defun develop-state-record-repl-finding (state finding)
  "Push FINDING onto STATE's repl-findings list. Returns STATE."
  (push finding (%repl-findings state))
  state)

(defun develop-state-repl-findings (state)
  "Return STATE's recorded repl-findings in observation order
(oldest first)."
  (reverse (%repl-findings state)))
```

Run tests, confirm green, commit:

```
git add src/state.lisp tests/state-test.lisp
git commit -m "feat: develop-state repl-findings slot (Phase H)"
```

---

## Task 3: `finding` action shape in the parser

**Files:**
- Modify: `src/action.lisp`
- Modify: `tests/action-test.lisp`

The agent / explore loop's input is parsed by `parse-action`. Today it recognises `tool_call`, `finish`, `give_up`, `dry_run` (or whatever shape `src/action.lisp` defines — read it before editing). Add a `finding` action whose payload carries the four required strings.

### Step 1: Read the current parser to understand action shape

`lisp-read-file` on `src/action.lisp`. Confirm:
- The action class shape (`agent-action`).
- The dispatcher key (likely a string `"type"` field in the LLM's JSON output).
- How existing action types branch.

### Step 2: Add failing parser tests

In `tests/action-test.lisp`:

```lisp
(deftest parse-action-recognises-finding-shape
  (let ((parsed (cl-harness/src/action:parse-action
                 (yason:parse "{\"type\":\"finding\",\"hypothesis\":\"h\",\"probe\":\"p\",\"finding\":\"f\",\"decision\":\"d\"}"))))
    (ok (typep parsed 'cl-harness/src/action:agent-action))
    (ok (eq :finding (cl-harness/src/action:agent-action-type parsed)))))

(deftest parse-action-rejects-finding-with-missing-fields
  (ok (handler-case
          (progn
            (cl-harness/src/action:parse-action
             (yason:parse "{\"type\":\"finding\",\"hypothesis\":\"h\"}"))
            nil)
        (cl-harness/src/action:action-parse-error () t))))
```

(Adjust import list in the test file: `cl-harness/src/action` already has `agent-action-type` exported per `src/main.lisp:241-244`. Add accessor exports for the four finding fields if this is the first action shape that needs sub-fields.)

### Step 3: Extend the parser

In `src/action.lisp`:
- Add accessors for the four finding fields (`agent-action-hypothesis`, `agent-action-probe`, `agent-action-finding-text`, `agent-action-decision`). Use distinct names from the slot to avoid `:reader` collisions with `agent-action-finding` (which would clash with the type itself). The `-text` suffix on `finding` disambiguates.
- Extend the dispatcher to recognise `"type": "finding"` and require all four sub-fields. Raise `action-parse-error` when any is missing or empty.

The exact code shape depends on how `parse-action` is currently structured; treat the read-first step as authoritative.

### Step 4: Run — expect PASS, commit

```
git add src/action.lisp tests/action-test.lisp
git commit -m "feat: action parser recognises 'finding' shape (Phase H)"
```

---

## Task 4: Explore loop persists findings

**Files:**
- Modify: `src/explore.lisp`
- Modify: `tests/explore-test.lisp` (if it exists; otherwise add coverage in an existing explore-related test file)

### Step 1: Read the explore loop

`lisp-read-file` on `src/explore.lisp`. Identify where actions are parsed and dispatched. Today the loop branches on `agent-action-type` for `tool_call` / `finish` / `give_up`.

### Step 2: Add a `:finding` branch

When the parsed action is a `:finding`, the loop should:
1. Construct a `repl-finding` from the four sub-fields.
2. If a `develop-state` is threaded into the explore call, record the finding via `develop-state-record-repl-finding`.
3. Continue the loop (do not terminate; finding actions are not terminal).

### Step 3: Tests

Add (or extend) explore tests that simulate a `finding` action arriving and assert the develop-state slot grows by one. The test shape mirrors how Phase B tested explore's existing memo flow.

### Step 4: Commit

```
git add src/explore.lisp tests/explore-test.lisp
git commit -m "feat: explore loop persists structured findings (Phase H)"
```

---

## Task 5: Promotion linkage from the orchestrator

**Files:**
- Modify: `src/orchestrator.lisp`
- Modify: `tests/orchestrator-test.lisp`

The orchestrator's `%execute-step` (or its post-step section — read the file to find the exact site) sees both the step's patch-records and the develop-state's repl-findings. After a step finishes successfully and at least one patch landed, walk the not-yet-promoted findings and flip the flag for any whose `:hypothesis` text is a substring of any landed patch's `:diff-summary` (case-folded). This is intentionally simple — the LLM is responsible for keeping hypothesis text recognisable.

### Step 1: Tests

```lisp
(deftest orchestrator-marks-finding-promoted-when-patch-matches-hypothesis
  ;; A finding with hypothesis "implement greet helper" should be
  ;; marked promoted when a patch whose diff-summary contains
  ;; "implement greet helper" lands in the same step.
  ;; ...assemble develop-state, finding, patch-record, call the
  ;; helper, assert promoted-to-source-p is T and linked-patch is
  ;; set.
  )

(deftest orchestrator-leaves-finding-unpromoted-when-no-patch-matches
  ;; ...inverse: hypothesis not in any patch's diff-summary -> still NIL.
  )
```

(Use the patterns already established in `tests/orchestrator-test.lisp` for fixture assembly.)

### Step 2: Implement

Add a helper `%promote-matching-findings (state)` near the existing `%execute-step` epilogue. Walk `(develop-state-repl-findings state)`, skip already-promoted, for each remaining find a matching patch by substring search over `(develop-state-patch-records state)`'s `:diff-summary`, and call `repl-finding-mark-promoted` with `:linked-patch <the-patch>`.

Wire `%promote-matching-findings` into the post-step path (the same place that already runs `mark-resolved-by` for failures).

### Step 3: Commit

```
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "feat: orchestrator promotes findings when matching patch lands (Phase H)"
```

---

## Task 6: Context-view consumes findings

**Files:**
- Modify: `src/context-view.lisp`
- Modify: `tests/context-view-test.lisp`

### Step 1: Failing tests

```lisp
(deftest exploration-formatter-renders-findings
  ;; assemble develop-state, record one finding, build :exploration
  ;; view, assert "## Findings observed in this step" header and
  ;; bullet "- hypothesis: <h> -> decision: <d>" appear.
  )

(deftest exploration-formatter-marks-promoted-findings
  ;; record a finding, mark it promoted, assert "[PROMOTED]" prefix
  ;; appears in :exploration view.
  )

(deftest implementation-formatter-lists-only-unpromoted-findings
  ;; record two findings, mark one promoted, build :implementation
  ;; view, assert the unpromoted hypothesis appears and the
  ;; promoted one does not.
  )
```

### Step 2: Implement view changes

In `src/context-view.lisp`:
- Add `:import-from #:cl-harness/src/state #:develop-state-repl-findings` and `:import-from #:cl-harness/src/repl-finding ...` lines.
- Add `relevant-repl-findings` slot to `context-view`. Populated for `:exploration` (filtered by `related-step-index`) and `:implementation` (filtered by step-index AND `(not promoted-to-source-p)`).
- Add `%filter-repl-findings` helper (analogous to `%filter-source-facts`).
- In `make-context-view`, populate the new slot for `:exploration` and `:implementation`.
- Add bullets to both formatters. Use `[PROMOTED] ` prefix in `:exploration` when applicable.

### Step 3: Commit

```
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "feat: repl-findings in :exploration / :implementation context views (Phase H)"
```

---

## Task 7: Lint + force-compile + regression sweep

```bash
mallet src/repl-finding.lisp src/state.lisp src/action.lisp src/explore.lisp \
       src/orchestrator.lisp src/context-view.lisp \
       tests/repl-finding-test.lisp tests/state-test.lisp tests/action-test.lisp \
       tests/explore-test.lisp tests/orchestrator-test.lisp \
       tests/context-view-test.lisp
```

Address `needless-let*` and any other warnings at the root.

`(asdf:compile-system :cl-harness :force t)` — clean.

`run-tests cl-harness/tests` — count grows by ~15 (7 + 2 + 2 + 1 + 2 + 3 ≈ 17 new), unchanged baseline failures (pre-existing develop-bench-test) only.

Commit lint fixups separately:

```
git commit -m "style: address mallet feedback on Phase H files"
```

---

## Task 8: Docs annotation + final review + merge

### Step 1: Update §14

Append:

```markdown
| H | structured `repl-finding` ledger (`(hypothesis probe finding decision)` + promotion linkage) wired into `:exploration` (all findings) and `:implementation` (unpromoted only) views; orchestrator flips `promoted-to-source-p` when patches match | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-h-repl-finding-ledger.md` |
```

Update trailing prose: §3.6 (Exploration) and §6.2 (REPL → finding) are now addressed for explicit `finding` actions; passive transcript mining remains future work. The "REPL success != implemented" rule (§3.6) is now enforced by the `:implementation` view's promotion filter.

### Step 2: Final review + merge

`superpowers:code-reviewer` over the branch. Checklist:
- All four required text fields validated as non-empty.
- `repl-finding-mark-promoted` is idempotent.
- Action parser accepts `finding` shape and rejects malformed payloads.
- Orchestrator promotion is best-effort substring match, not fuzzy.
- `:implementation` view filters by promotion; `:exploration` view does not.
- mallet clean, force-compile clean.
- No `:local-nicknames`, no new `src/main` re-exports.

Then `superpowers:finishing-a-development-branch` → `--no-ff` merge.

---

## Verification checklist

- [ ] `make-repl-finding` requires non-empty hypothesis/probe/finding/decision.
- [ ] `repl-finding-mark-promoted` is idempotent and stores linked-patch.
- [ ] `develop-state-repl-findings` returns oldest-first.
- [ ] Action parser recognises `"type": "finding"` and rejects missing sub-fields.
- [ ] Explore loop persists `finding` actions to develop-state.
- [ ] Orchestrator post-step promotes findings whose hypothesis appears in a patch's diff-summary.
- [ ] `:exploration` view lists all findings, prefixing promoted ones with `[PROMOTED] `.
- [ ] `:implementation` view lists only unpromoted findings.
- [ ] No regression in pre-Phase-H test count.
- [ ] mallet clean, force-compile clean.
- [ ] No new `:local-nicknames` or `src/main` re-exports.
- [ ] §14 docs updated.

---

## Acceptance criteria

Phase H is complete when:

1. `repl-finding` record + recorder + slot land.
2. The action parser accepts `finding` actions.
3. The explore loop persists them.
4. The orchestrator flips `promoted-to-source-p` when patches match.
5. Both `:exploration` and `:implementation` views render findings with the correct promotion semantics.
6. Test count grows by ~15-17 with no pre-existing failures introduced.
7. mallet and force-compile are clean.
8. §14 marks Phase H landed.
