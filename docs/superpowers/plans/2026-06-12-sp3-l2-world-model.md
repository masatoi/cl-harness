# SP3: L2 World Model + Context Compiler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L2 world model of the autonomous-harness redesign — in-memory projections derived from the SP1 event log (goal, exploration findings/probes with staleness, patches/source facts, verification with derived clean-verify state) — and the context compiler that turns a world model into a token-budget-bounded view.

**Architecture:** A `projection` protocol (`apply-event` / `apply-interaction`) plus four ledger projections mirroring `docs/context-management.md`'s sections: `goal-projection` (§3.1 goal + §3.7 decisions), `exploration-ledger` (§3.6 findings + runtime probes, §9 staleness, "REPL success != implemented"), `change-ledger` (§3.5 source facts + §3.8 patches), `verification-ledger` (§3.9 + §7 runtime/source/clean three-state, §8 failure active/resolved). A `world-model` aggregate pairs each `:action` with its `:observation` exactly once and feeds projections; `build-world-model` replays a log. `compile-context` (§4/§5/§6) assembles priority-ordered sections under a HARD token budget, with `:normal` and `:failure-analysis` decision points. Spec: `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md` §8.2/§8.3; requirements doc: `docs/context-management.md` (§ numbers cited below refer to it).

**Tech Stack:** SBCL, ASDF package-inferred-system, rove, alexandria, yason (only via the event modules). No new dependencies.

**Inherited lessons that bind this design** (from `docs/context-management.md` §14 / legacy Phases A–J):
- **Annotate, do not filter** staleness: render-time `[STALE]` prefixes (Phase F), the data stays.
- **"REPL success != implemented"**: findings carry a `promoted-p` flag flipped by the legacy-proven heuristic — hypothesis substring (case-folded) matched against a successful patch's content/new_text/form_name (Phase H).
- **Resolved failures are not active failures** (§6.5): rendered separately, capped at 3 newest ("regression watch", Phase J).
- **Check key presence, don't guess result shapes**: `gethash`'s second value (vocab-facts shape fix lesson).
- **Empty sections are not emitted** (Phase J: byte-identical views for empty state).
- **Derived, not duplicated**: projections are in-memory rebuilds of the log; nothing in them is persisted (spec §8.2 "projection 再構築はメモリ内のみ").
- Clean verification is **derived from event order**: a run-tests is clean iff `kill-seq < load-seq < test-seq`, no `repl-eval` since the kill, no successful patch since the load. No new event convention needed.

**Payload conventions consumed (defined by SP1/SP2, extended here):**
- `:run-start` payload may carry `"goal"` (string), `"acceptance_criteria"` (array of strings), `"non_goals"` (array of strings) — alongside SP1's pack fields.
- `:decision` payload carries `"kind"`: `"decision"` (fields `"text"`, `"rationale"`) or `"finding"` (fields `"hypothesis"`, `"probe"`, `"finding"`, `"decision"` — the §6.2 structure).
- `:action`/`:observation` payloads are SP2's `{"tool","arguments"}` / `{"tool","result"|"error"}`.
- Tool names drive classification: patch tools = `lisp-edit-form`/`lisp-patch-form`/`fs-write-file`; probe tools = `repl-eval`/`inspect-object`; read tools = `lisp-read-file`/`fs-read-file`/`clgrep-search`; plus `load-system`, `run-tests`, `pool-kill-worker`.
- `run-tests` results read cl-mcp's structured fields when present: `"passed"`, `"failed"` (integers), `"failed_tests"` (array of objects with `"test_name"`, `"reason"`).

**Conventions that bind this plan** (same as SP1/SP2): 2-space indent, ≤100 columns, blank line between top-level forms, docstrings on public functions/classes/generics, no `:local-nicknames`, third-party via qualified names, structs for internal records (à la `%pending-entry`), `%`-prefix for internals. cl-mcp tools for Lisp edits (Write for new files + `lisp-check-parens`); `mallet` before each commit; tests via cl-mcp `run-tests` `{"system": "cl-harness-next/tests"}`; re-register with `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")` after a worker restart. All new constants are NEW `alexandria:define-constant`s (no redefinition hazard this time).

---

## File Structure

```text
next/src/projection.lisp           NEW  protocol (apply-event/apply-interaction),
                                        interaction record, shared payload helpers,
                                        +patch-tool-names+
next/src/goal-projection.lisp      NEW  §3.1 goal/acceptance/non-goals + §3.7 decisions
next/src/exploration-ledger.lisp   NEW  §3.6 findings (+promotion) + probes (+staleness)
next/src/change-ledger.lisp        NEW  §3.8 patches + §3.5 source facts (+staleness)
next/src/verification-ledger.lisp  NEW  §3.9/§7 load/test state, derived clean-verify,
                                        §8 failure active/resolved
next/src/world-model.lisp          NEW  aggregate + action/observation pairing +
                                        build-world-model (replay)
next/src/context-compiler.lisp     NEW  §4/§5/§6 budget-bounded view assembly,
                                        :normal / :failure-analysis
next/src/main.lisp                 MOD  facade re-exports
next/tests/projection-test.lisp          NEW
next/tests/goal-projection-test.lisp     NEW
next/tests/exploration-ledger-test.lisp  NEW
next/tests/change-ledger-test.lisp       NEW
next/tests/verification-ledger-test.lisp NEW
next/tests/world-model-test.lisp         NEW
next/tests/context-compiler-test.lisp    NEW
next/tests/main-test.lisp                MOD  SP3 acceptance test
cl-harness-next.asd                MOD  + 7 test files
README.md                          MOD  one sentence in the next/ subsection
```

Dependency edges: ledgers → projection (+event for the two that read raw events); world-model → projection + event-log + all four ledgers; context-compiler → world-model + all four ledgers. No ledger imports another ledger.

---

### Task 1: Projection protocol and interaction record

**Files:**
- Create: `next/tests/projection-test.lisp`
- Create: `next/src/projection.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/projection-test.lisp`:

```lisp
;;;; next/tests/projection-test.lisp
;;;;
;;;; Unit tests for next/src/projection.lisp: protocol defaults,
;;;; interaction pairing, payload helpers (spec §8.2).

(defpackage #:cl-harness-next/tests/projection-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:interaction
                #:make-interaction
                #:interaction-tool
                #:interaction-arguments
                #:interaction-result
                #:interaction-error-message
                #:interaction-action-seq
                #:interaction-observation-seq
                #:interaction-ok-p
                #:argument-string
                #:result-text))

(in-package #:cl-harness-next/tests/projection-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(deftest default-methods-are-no-ops
  (let ((projection (make-instance 'projection)))
    (ok (eq projection (apply-event projection :anything)))
    (ok (eq projection (apply-interaction projection :anything)))))

(deftest interaction-pairs-two-events
  (let* ((action (make-harness-event
                  :action (%hash "tool" "repl-eval"
                                 "arguments" (%hash "code" "(+ 1 2)"))
                  :seq 4))
         (observation (make-harness-event
                       :observation (%hash "tool" "repl-eval"
                                           "result" (%hash "x" 1))
                       :seq 5))
         (interaction (make-interaction action observation)))
    (ok (equal "repl-eval" (interaction-tool interaction)))
    (ok (equal "(+ 1 2)" (argument-string interaction "code")))
    (ok (hash-table-p (interaction-result interaction)))
    (ok (= 4 (interaction-action-seq interaction)))
    (ok (= 5 (interaction-observation-seq interaction)))
    (ok (interaction-ok-p interaction))))

(deftest error-observation-is-not-ok
  (let* ((action (make-harness-event
                  :action (%hash "tool" "run-tests") :seq 1))
         (observation (make-harness-event
                       :observation (%hash "tool" "run-tests"
                                           "error" "boom")
                       :seq 2))
         (interaction (make-interaction action observation)))
    (ok (not (interaction-ok-p interaction)))
    (ok (equal "boom" (interaction-error-message interaction)))))

(deftest result-text-extracts-and-truncates
  (let ((interaction
          (make-instance 'interaction
                         :tool "repl-eval"
                         :result (%hash "content"
                                        (list (%hash "type" "text"
                                                     "text" (make-string 300
                                                                         :initial-element #\x))))
                         :action-seq 1 :observation-seq 2)))
    (let ((text (result-text interaction)))
      (ok (stringp text))
      (ok (< (length text) 300))
      (ok (search "[truncated]" text)))))

(deftest result-text-nil-on-absent-shape
  (let ((no-result (make-instance 'interaction :tool "x"
                                  :action-seq 1 :observation-seq 2))
        (no-content (make-instance 'interaction :tool "x"
                                   :result (%hash "passed" 3)
                                   :action-seq 1 :observation-seq 2)))
    (ok (null (result-text no-result)))
    (ok (null (result-text no-content)))))
```

Create `next/src/projection.lisp`:

```lisp
;;;; next/src/projection.lisp
;;;;
;;;; Projection protocol for the L2 world model (spec §8.2). A
;;;; projection is an in-memory derivation of the event log; the log
;;;; stays the only persisted truth and projections are rebuilt by
;;;; replay. Tool round-trips arrive pre-paired as INTERACTIONs — the
;;;; world model pairs an :action with its following :observation
;;;; exactly once, so projections never re-implement pairing.

(defpackage #:cl-harness-next/src/projection
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-seq
                #:event-payload)
  (:export #:projection
           #:apply-event
           #:apply-interaction
           #:interaction
           #:make-interaction
           #:interaction-tool
           #:interaction-arguments
           #:interaction-result
           #:interaction-error-message
           #:interaction-action-seq
           #:interaction-observation-seq
           #:interaction-ok-p
           #:argument-string
           #:result-text
           #:+patch-tool-names+))

(in-package #:cl-harness-next/src/projection)

(alexandria:define-constant +patch-tool-names+
    '("lisp-edit-form" "lisp-patch-form" "fs-write-file")
  :test #'equal
  :documentation
  "Tools whose successful use changes source files. Shared convention
for the ledgers (staleness, patch history, clean-verify derivation).")

(defclass projection ()
  ()
  (:documentation "Abstract base for world-model projections (spec
§8.2). Subclasses accumulate state from events and interactions; they
are in-memory only and rebuilt by replaying the event log."))

(defgeneric apply-event (projection event)
  (:documentation "Fold one raw EVENT into PROJECTION. Default no-op.
Returns PROJECTION.")
  (:method ((projection projection) event)
    (declare (ignore event))
    projection))

(defgeneric apply-interaction (projection interaction)
  (:documentation "Fold one paired tool INTERACTION into PROJECTION.
Default no-op. Returns PROJECTION.")
  (:method ((projection projection) interaction)
    (declare (ignore interaction))
    projection))

(defclass interaction ()
  ((tool :initarg :tool :reader interaction-tool)
   (arguments :initarg :arguments :initform nil
              :reader interaction-arguments
              :documentation "Hash-table or NIL.")
   (result :initarg :result :initform nil :reader interaction-result
           :documentation "tools/call result hash-table, or NIL.")
   (error-message :initarg :error-message :initform nil
                  :reader interaction-error-message)
   (action-seq :initarg :action-seq :reader interaction-action-seq)
   (observation-seq :initarg :observation-seq
                    :reader interaction-observation-seq))
  (:documentation "One paired tool round-trip: an :action event and
its matching :observation, per SP2's payload conventions."))

(defun make-interaction (action-event observation-event)
  "Pair ACTION-EVENT with OBSERVATION-EVENT into an INTERACTION,
reading SP2's payload conventions ({\"tool\",\"arguments\"} /
{\"tool\",\"result\"|\"error\"})."
  (let ((action-payload (event-payload action-event))
        (observation-payload (event-payload observation-event)))
    (make-instance 'interaction
                   :tool (gethash "tool" action-payload)
                   :arguments (gethash "arguments" action-payload)
                   :result (gethash "result" observation-payload)
                   :error-message (gethash "error" observation-payload)
                   :action-seq (event-seq action-event)
                   :observation-seq (event-seq observation-event))))

(defun interaction-ok-p (interaction)
  "True when the tool round-trip completed without an MCP error."
  (null (interaction-error-message interaction)))

(defun argument-string (interaction key)
  "Return the string argument KEY of INTERACTION, or NIL."
  (let ((arguments (interaction-arguments interaction)))
    (when (hash-table-p arguments)
      (let ((value (gethash key arguments)))
        (when (stringp value) value)))))

(defun result-text (interaction &key (limit 200))
  "Best-effort summary of INTERACTION's result: the first content
element's \"text\", truncated to LIMIT characters. Returns NIL when
the shape is absent (lesson: check key presence, never guess shapes)."
  (let ((result (interaction-result interaction)))
    (when (hash-table-p result)
      (multiple-value-bind (content present-p) (gethash "content" result)
        (when (and present-p (consp content))
          (let ((first-element (first content)))
            (when (hash-table-p first-element)
              (let ((text (gethash "text" first-element)))
                (when (stringp text)
                  (if (> (length text) limit)
                      (concatenate 'string (subseq text 0 limit)
                                   " …[truncated]")
                      text))))))))))
```

Add `"cl-harness-next/tests/projection-test"` to the tests system's
`:depends-on` in `cl-harness-next.asd` (after the environment-test entry).

- [ ] **Step 2: Run tests to verify the red state**

cl-mcp `run-tests` `{"system": "cl-harness-next/tests"}`. NOTE: because
Step 1 creates BOTH files complete, run the red check by creating the
TEST file and the `.asd` entry FIRST, run (expected: load failure —
package `cl-harness-next/src/projection` missing), THEN create the
source file. Report what you saw.

- [ ] **Step 3: Run tests to verify green**

Expected: PASS — 69 tests (64 + 5).

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/projection.lisp next/tests/projection-test.lisp
git add next/src/projection.lisp next/tests/projection-test.lisp cl-harness-next.asd
git commit -m "feat(next): projection protocol and paired interactions"
```

---

### Task 2: Goal projection (goal + decisions)

**Files:**
- Create: `next/tests/goal-projection-test.lisp`
- Create: `next/src/goal-projection.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/goal-projection-test.lisp`:

```lisp
;;;; next/tests/goal-projection-test.lisp
;;;;
;;;; Unit tests for next/src/goal-projection.lisp (§3.1 goal context,
;;;; §3.7 design decisions).

(defpackage #:cl-harness-next/tests/goal-projection-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-projection
                #:goal-text
                #:acceptance-criteria
                #:non-goals
                #:decisions
                #:decision-text
                #:decision-rationale
                #:decision-seq))

(in-package #:cl-harness-next/tests/goal-projection-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %feed (projection type seq &rest plist)
  (apply-event projection
               (make-harness-event type (when plist (apply #'%hash plist))
                                   :seq seq)))

(deftest run-start-populates-goal
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :run-start 1
           "goal" "Fix the failing test"
           "acceptance_criteria" (list "tests pass" "no warnings")
           "non_goals" (list "refactor"))
    (ok (equal "Fix the failing test" (goal-text projection)))
    (ok (equal '("tests pass" "no warnings")
               (acceptance-criteria projection)))
    (ok (equal '("refactor") (non-goals projection)))))

(deftest decision-events-accumulate
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :decision 3
           "kind" "decision" "text" "use a class" "rationale" "two impls")
    (%feed projection :decision 7
           "kind" "decision" "text" "no macro")
    (let ((decisions (decisions projection)))
      (ok (= 2 (length decisions)))
      ;; Newest first.
      (ok (equal "no macro" (decision-text (first decisions))))
      (ok (= 7 (decision-seq (first decisions))))
      (ok (equal "two impls" (decision-rationale (second decisions)))))))

(deftest non-decision-kinds-are-ignored
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :decision 1 "kind" "finding" "hypothesis" "h"
           "probe" "p" "finding" "f" "decision" "d")
    (ok (null (decisions projection)))))

(deftest malformed-payloads-are-ignored
  (let ((projection (make-instance 'goal-projection)))
    (%feed projection :run-start 1)
    (%feed projection :note 2 "goal" "not a run-start")
    (ok (null (goal-text projection)))
    (ok (null (decisions projection)))))
```

Create `next/src/goal-projection.lisp` with the package definition only:

```lisp
;;;; next/src/goal-projection.lisp
;;;;
;;;; Goal context (§3.1) and design decisions (§3.7): what the run is
;;;; for, its acceptance criteria and non-goals (from the :run-start
;;;; payload), and explicit design decisions (:decision events with
;;;; kind \"decision\").

(defpackage #:cl-harness-next/src/goal-projection
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-seq
                #:event-payload)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event)
  (:export #:goal-projection
           #:goal-text
           #:acceptance-criteria
           #:non-goals
           #:decisions
           #:decision-text
           #:decision-rationale
           #:decision-seq))

(in-package #:cl-harness-next/src/goal-projection)
```

Add `"cl-harness-next/tests/goal-projection-test"` to the tests system.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `goal-projection` class undefined; 69 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/goal-projection.lisp`:

```lisp
(defstruct (decision (:conc-name decision-))
  text rationale seq)

(defclass goal-projection (projection)
  ((goal :initform nil :accessor goal-text
         :documentation "User goal string, or NIL.")
   (acceptance :initform nil :accessor acceptance-criteria)
   (non-goals :initform nil :accessor non-goals)
   (decisions :initform nil :accessor decisions
              :documentation "DECISION structs, newest first."))
  (:documentation "Goal context (§3.1) + design decisions (§3.7)."))

(defmethod apply-event ((projection goal-projection) event)
  (let ((payload (event-payload event)))
    (when (hash-table-p payload)
      (case (event-type event)
        (:run-start
         (let ((goal (gethash "goal" payload)))
           (when (stringp goal) (setf (goal-text projection) goal)))
         (let ((acceptance (gethash "acceptance_criteria" payload)))
           (when (consp acceptance)
             (setf (acceptance-criteria projection) acceptance)))
         (let ((non-goals (gethash "non_goals" payload)))
           (when (consp non-goals)
             (setf (non-goals projection) non-goals))))
        (:decision
         (when (equal "decision" (gethash "kind" payload))
           (push (make-decision :text (gethash "text" payload)
                                :rationale (gethash "rationale" payload)
                                :seq (event-seq event))
                 (decisions projection)))))))
  projection)
```

- [ ] **Step 4: Run tests to verify green**

Expected: PASS — 73 tests (69 + 4).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/goal-projection.lisp next/tests/goal-projection-test.lisp
git add next/src/goal-projection.lisp next/tests/goal-projection-test.lisp cl-harness-next.asd
git commit -m "feat(next): goal projection (goal, acceptance, decisions)"
```

---

### Task 3: Exploration ledger (findings + probes + staleness + promotion)

**Files:**
- Create: `next/tests/exploration-ledger-test.lisp`
- Create: `next/src/exploration-ledger.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/exploration-ledger-test.lisp`:

```lisp
;;;; next/tests/exploration-ledger-test.lisp
;;;;
;;;; Unit tests for next/src/exploration-ledger.lisp (§3.6 exploration
;;;; context, §9 staleness, Phase-H promotion heuristic).

(defpackage #:cl-harness-next/tests/exploration-ledger-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:exploration-ledger
                #:findings
                #:probes
                #:finding-hypothesis
                #:finding-text
                #:finding-promoted-p
                #:probe-tool
                #:probe-code
                #:probe-summary
                #:probe-seq
                #:probe-stale-p))

(in-package #:cl-harness-next/tests/exploration-ledger-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %interaction (tool &key arguments result error
                              (action-seq 1) (observation-seq 2))
  (make-instance 'interaction
                 :tool tool
                 :arguments arguments
                 :result result
                 :error-message error
                 :action-seq action-seq
                 :observation-seq observation-seq))

(defun %finding-event (seq hypothesis)
  (make-harness-event :decision
                      (%hash "kind" "finding"
                             "hypothesis" hypothesis
                             "probe" "tried it in the REPL"
                             "finding" "it works"
                             "decision" "promote to source")
                      :seq seq))

(deftest finding-events-are-recorded
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 3 "pure function suffices"))
    (let ((finding (first (findings ledger))))
      (ok (equal "pure function suffices" (finding-hypothesis finding)))
      (ok (equal "it works" (finding-text finding)))
      (ok (not (finding-promoted-p finding))))))

(deftest probe-interactions-are-recorded
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction
     ledger
     (%interaction "repl-eval"
                   :arguments (%hash "code" "(+ 1 2)")
                   :result (%hash "content"
                                  (list (%hash "type" "text" "text" "3")))
                   :observation-seq 5))
    (let ((probe (first (probes ledger))))
      (ok (equal "repl-eval" (probe-tool probe)))
      (ok (equal "(+ 1 2)" (probe-code probe)))
      (ok (equal "3" (probe-summary probe)))
      (ok (= 5 (probe-seq probe)))
      (ok (not (probe-stale-p probe ledger))))))

(deftest patch-invalidates-earlier-probes
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 3))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "(defun f ())")
                          :observation-seq 6))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 9))
    (let ((newest (first (probes ledger)))
          (oldest (first (last (probes ledger)))))
      (ok (probe-stale-p oldest ledger))
      (ok (not (probe-stale-p newest ledger))))))

(deftest load-system-invalidates-earlier-probes
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 3))
    (apply-interaction ledger (%interaction "load-system" :observation-seq 4))
    (ok (probe-stale-p (first (probes ledger)) ledger))))

(deftest promotion-matches-hypothesis-case-folded
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 2 "Pure Function"))
    (apply-interaction
     ledger
     (%interaction "lisp-patch-form"
                   :arguments (%hash "new_text" "a pure function body")
                   :observation-seq 8))
    (ok (finding-promoted-p (first (findings ledger))))))

(deftest promotion-skips-unrelated-patches-and-failures
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 2 "memoization table"))
    ;; Unrelated content.
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "(defun g ())")
                          :observation-seq 4))
    (ok (not (finding-promoted-p (first (findings ledger)))))
    ;; Matching content but the patch FAILED.
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "memoization table v2")
                          :error "form not found"
                          :observation-seq 6))
    (ok (not (finding-promoted-p (first (findings ledger)))))))
```

Create `next/src/exploration-ledger.lisp` with the package definition only:

```lisp
;;;; next/src/exploration-ledger.lisp
;;;;
;;;; Exploration context (§3.6): explicit findings (the §6.2
;;;; hypothesis/probe/finding/decision structure, with the Phase-H
;;;; promotion heuristic enforcing \"REPL success != implemented\")
;;;; and auto-recorded runtime probes with §9 staleness — probes are
;;;; invalidated by any later successful patch or reload
;;;; (annotate-not-filter: staleness is a render-time predicate).

(defpackage #:cl-harness-next/src/exploration-ledger
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-seq
                #:event-payload)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:interaction-tool
                #:interaction-ok-p
                #:interaction-observation-seq
                #:argument-string
                #:result-text
                #:+patch-tool-names+)
  (:export #:exploration-ledger
           #:findings
           #:probes
           #:finding-hypothesis
           #:finding-probe
           #:finding-text
           #:finding-decision
           #:finding-seq
           #:finding-promoted-p
           #:probe-tool
           #:probe-code
           #:probe-summary
           #:probe-seq
           #:probe-stale-p))

(in-package #:cl-harness-next/src/exploration-ledger)
```

Add `"cl-harness-next/tests/exploration-ledger-test"` to the tests system.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `exploration-ledger` undefined; 73 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/exploration-ledger.lisp`:

```lisp
(alexandria:define-constant +probe-tool-names+
    '("repl-eval" "inspect-object")
  :test #'equal
  :documentation "Tools whose successful use is a runtime probe.")

(defstruct (finding (:conc-name finding-))
  hypothesis probe text decision seq (promoted-p nil))

(defstruct (probe (:conc-name probe-))
  tool code summary seq)

(defclass exploration-ledger (projection)
  ((findings :initform nil :accessor findings
             :documentation "FINDING structs, newest first.")
   (probes :initform nil :accessor probes
           :documentation "PROBE structs, newest first.")
   (invalidation-seq :initform nil :accessor %invalidation-seq
                     :documentation "Seq of the latest successful
patch or reload; probes before it are stale (§9)."))
  (:documentation "Exploration context (§3.6) with staleness (§9)."))

(defmethod apply-event ((ledger exploration-ledger) event)
  (let ((payload (event-payload event)))
    (when (and (eq :decision (event-type event))
               (hash-table-p payload)
               (equal "finding" (gethash "kind" payload)))
      (push (make-finding :hypothesis (gethash "hypothesis" payload)
                          :probe (gethash "probe" payload)
                          :text (gethash "finding" payload)
                          :decision (gethash "decision" payload)
                          :seq (event-seq event))
            (findings ledger))))
  ledger)

(defun %patch-text-fields (interaction)
  (remove nil (list (argument-string interaction "content")
                    (argument-string interaction "new_text")
                    (argument-string interaction "form_name"))))

(defun %promote-matching-findings (ledger interaction)
  "Flip PROMOTED-P on findings whose hypothesis appears (case-folded
substring) in the patch's content/new_text/form_name — the
legacy-proven Phase-H heuristic. Idempotent."
  (let ((haystacks (mapcar #'string-downcase
                           (%patch-text-fields interaction))))
    (dolist (finding (findings ledger))
      (let ((hypothesis (finding-hypothesis finding)))
        (when (and (not (finding-promoted-p finding))
                   (stringp hypothesis)
                   (some (lambda (haystack)
                           (search (string-downcase hypothesis) haystack))
                         haystacks))
          (setf (finding-promoted-p finding) t))))))

(defmethod apply-interaction ((ledger exploration-ledger) interaction)
  (when (interaction-ok-p interaction)
    (let ((tool (interaction-tool interaction))
          (seq (interaction-observation-seq interaction)))
      (cond
        ((member tool +probe-tool-names+ :test #'string=)
         (push (make-probe :tool tool
                           :code (argument-string interaction "code")
                           :summary (result-text interaction)
                           :seq seq)
               (probes ledger)))
        ((member tool +patch-tool-names+ :test #'string=)
         (setf (%invalidation-seq ledger) seq)
         (%promote-matching-findings ledger interaction))
        ((string= tool "load-system")
         (setf (%invalidation-seq ledger) seq)))))
  ledger)

(defun probe-stale-p (probe ledger)
  "True when PROBE predates the latest successful patch or reload —
runtime observations invalidated per §9. Render-time predicate
(annotate, don't filter)."
  (let ((invalidation (%invalidation-seq ledger)))
    (and invalidation (< (probe-seq probe) invalidation) t)))
```

- [ ] **Step 4: Run tests to verify green**

Expected: PASS — 79 tests (73 + 6).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/exploration-ledger.lisp next/tests/exploration-ledger-test.lisp
git add next/src/exploration-ledger.lisp next/tests/exploration-ledger-test.lisp cl-harness-next.asd
git commit -m "feat(next): exploration ledger with staleness and finding promotion"
```

---

### Task 4: Change ledger (patches + source facts)

**Files:**
- Create: `next/tests/change-ledger-test.lisp`
- Create: `next/src/change-ledger.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/change-ledger-test.lisp`:

```lisp
;;;; next/tests/change-ledger-test.lisp
;;;;
;;;; Unit tests for next/src/change-ledger.lisp (§3.8 patch context,
;;;; §3.5 source context, §9 staleness of source facts).

(defpackage #:cl-harness-next/tests/change-ledger-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/change-ledger
                #:change-ledger
                #:patches
                #:source-facts
                #:patch-entry-file
                #:patch-entry-form-type
                #:patch-entry-form-name
                #:patch-entry-operation
                #:patch-entry-ok-p
                #:patch-entry-seq
                #:source-fact-file
                #:source-fact-detail
                #:source-fact-seq
                #:source-fact-stale-p))

(in-package #:cl-harness-next/tests/change-ledger-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %interaction (tool &key arguments error (observation-seq 2))
  (make-instance 'interaction
                 :tool tool
                 :arguments arguments
                 :error-message error
                 :action-seq (1- observation-seq)
                 :observation-seq observation-seq))

(deftest patch-entries-record-success-and-failure
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "file_path" "src/a.lisp"
                                            "form_type" "defun"
                                            "form_name" "f"
                                            "operation" "replace")
                          :observation-seq 4))
    (apply-interaction
     ledger (%interaction "lisp-patch-form"
                          :arguments (%hash "file_path" "src/a.lisp"
                                            "form_name" "g")
                          :error "no match"
                          :observation-seq 6))
    (let ((failed (first (patches ledger)))
          (succeeded (second (patches ledger))))
      (ok (= 2 (length (patches ledger))))
      (ok (not (patch-entry-ok-p failed)))
      (ok (= 6 (patch-entry-seq failed)))
      (ok (patch-entry-ok-p succeeded))
      (ok (equal "src/a.lisp" (patch-entry-file succeeded)))
      (ok (equal "defun" (patch-entry-form-type succeeded)))
      (ok (equal "f" (patch-entry-form-name succeeded)))
      (ok (equal "replace" (patch-entry-operation succeeded))))))

(deftest read-tools-create-source-facts
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/a.lisp"
                                            "name_pattern" "^f$")
                          :observation-seq 3))
    (let ((fact (first (source-facts ledger))))
      (ok (equal "src/a.lisp" (source-fact-file fact)))
      (ok (equal "^f$" (source-fact-detail fact)))
      (ok (= 3 (source-fact-seq fact))))))

(deftest clgrep-fact-has-pattern-without-file
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "clgrep-search"
                          :arguments (%hash "pattern" "defclass")
                          :observation-seq 3))
    (let ((fact (first (source-facts ledger))))
      (ok (null (source-fact-file fact)))
      (ok (equal "defclass" (source-fact-detail fact)))
      ;; File-less facts can never go stale by file matching.
      (ok (not (source-fact-stale-p fact ledger))))))

(deftest staleness-tracks-same-file-patches
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/a.lisp")
                          :observation-seq 3))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/b.lisp")
                          :observation-seq 4))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "file_path" "src/a.lisp")
                          :observation-seq 8))
    (let ((fact-b (first (source-facts ledger)))
          (fact-a (second (source-facts ledger))))
      (ok (source-fact-stale-p fact-a ledger))
      (ok (not (source-fact-stale-p fact-b ledger))))))
```

Create `next/src/change-ledger.lisp` with the package definition only:

```lisp
;;;; next/src/change-ledger.lisp
;;;;
;;;; Patch context (§3.8) and source context (§3.5): every patch
;;;; attempt (including failures), and which files/forms were read.
;;;; Source facts go stale when a later successful patch touches the
;;;; same file (§9, annotate-not-filter).

(defpackage #:cl-harness-next/src/change-ledger
  (:use #:cl)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-interaction
                #:interaction-tool
                #:interaction-ok-p
                #:interaction-observation-seq
                #:argument-string
                #:+patch-tool-names+)
  (:export #:change-ledger
           #:patches
           #:source-facts
           #:patch-entry-file
           #:patch-entry-form-type
           #:patch-entry-form-name
           #:patch-entry-operation
           #:patch-entry-ok-p
           #:patch-entry-seq
           #:source-fact-file
           #:source-fact-detail
           #:source-fact-seq
           #:source-fact-stale-p))

(in-package #:cl-harness-next/src/change-ledger)
```

Add `"cl-harness-next/tests/change-ledger-test"` to the tests system.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `change-ledger` undefined; 79 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/change-ledger.lisp`:

```lisp
(alexandria:define-constant +read-tool-names+
    '("lisp-read-file" "fs-read-file" "clgrep-search")
  :test #'equal
  :documentation "Tools whose successful use establishes a source fact.")

(defstruct (patch-entry (:conc-name patch-entry-))
  file form-type form-name operation ok-p seq)

(defstruct (source-fact (:conc-name source-fact-))
  file detail seq)

(defclass change-ledger (projection)
  ((patches :initform nil :accessor patches
            :documentation "PATCH-ENTRY structs, newest first. Failed
attempts are recorded too (ok-p NIL) — patch oscillation is a signal.")
   (source-facts :initform nil :accessor source-facts
                 :documentation "SOURCE-FACT structs, newest first."))
  (:documentation "Source (§3.5) + patch (§3.8) context."))

(defun %interaction-file (interaction)
  (or (argument-string interaction "file_path")
      (argument-string interaction "path")))

(defmethod apply-interaction ((ledger change-ledger) interaction)
  (let ((tool (interaction-tool interaction)))
    (cond
      ((member tool +patch-tool-names+ :test #'string=)
       (push (make-patch-entry
              :file (%interaction-file interaction)
              :form-type (argument-string interaction "form_type")
              :form-name (argument-string interaction "form_name")
              :operation (or (argument-string interaction "operation") tool)
              :ok-p (interaction-ok-p interaction)
              :seq (interaction-observation-seq interaction))
             (patches ledger)))
      ((and (interaction-ok-p interaction)
            (member tool +read-tool-names+ :test #'string=))
       (push (make-source-fact
              :file (%interaction-file interaction)
              :detail (or (argument-string interaction "name_pattern")
                          (argument-string interaction "pattern"))
              :seq (interaction-observation-seq interaction))
             (source-facts ledger)))))
  ledger)

(defun source-fact-stale-p (fact ledger)
  "True when a later successful patch touched FACT's file (§9).
Render-time predicate (annotate, don't filter)."
  (let ((file (source-fact-file fact)))
    (and file
         (some (lambda (patch)
                 (and (patch-entry-ok-p patch)
                      (equal file (patch-entry-file patch))
                      (> (patch-entry-seq patch) (source-fact-seq fact))))
               (patches ledger))
         t)))
```

- [ ] **Step 4: Run tests to verify green**

Expected: PASS — 83 tests (79 + 4).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/change-ledger.lisp next/tests/change-ledger-test.lisp
git add next/src/change-ledger.lisp next/tests/change-ledger-test.lisp cl-harness-next.asd
git commit -m "feat(next): change ledger (patches, source facts, staleness)"
```

---

### Task 5: Verification ledger (three-state + derived clean-verify + failures)

**Files:**
- Create: `next/tests/verification-ledger-test.lisp`
- Create: `next/src/verification-ledger.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/verification-ledger-test.lisp`:

```lisp
;;;; next/tests/verification-ledger-test.lisp
;;;;
;;;; Unit tests for next/src/verification-ledger.lisp (§3.9 / §7
;;;; runtime-source-verified separation, §8 failure ledger). Clean
;;;; verification is DERIVED from event order: kill < load < test,
;;;; no repl-eval since the kill, no successful patch since the load.

(defpackage #:cl-harness-next/tests/verification-ledger-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:verification-ledger
                #:last-load
                #:last-test
                #:load-result-ok-p
                #:load-result-seq
                #:test-run-passed
                #:test-run-failed
                #:test-run-clean-p
                #:test-run-seq
                #:clean-verified-p
                #:active-failures
                #:resolved-failures
                #:failure-record-test-name
                #:failure-record-reason
                #:failure-record-patch-seq
                #:failure-record-resolved-seq))

(in-package #:cl-harness-next/tests/verification-ledger-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %feed (ledger tool seq &key arguments result error)
  (apply-interaction ledger
                     (make-instance 'interaction
                                    :tool tool
                                    :arguments arguments
                                    :result result
                                    :error-message error
                                    :action-seq (1- seq)
                                    :observation-seq seq)))

(defun %tests-result (passed failed &rest failure-plists)
  (%hash "passed" passed "failed" failed
         "failed_tests" (mapcar (lambda (plist) (apply #'%hash plist))
                                failure-plists)))

(deftest load-results-are-recorded
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "load-system" 2)
    (ok (load-result-ok-p (last-load ledger)))
    (ok (= 2 (load-result-seq (last-load ledger))))
    (%feed ledger "load-system" 4 :error "compile failed")
    (ok (not (load-result-ok-p (last-load ledger))))))

(deftest dirty-run-is-not-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "load-system" 2)
    (%feed ledger "run-tests" 3 :result (%tests-result 5 0))
    (ok (not (test-run-clean-p (last-test ledger))))
    (ok (not (clean-verified-p ledger)))))

(deftest kill-load-test-is-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "load-system" 6)
    (%feed ledger "run-tests" 7 :result (%tests-result 5 0))
    (ok (test-run-clean-p (last-test ledger)))
    (ok (clean-verified-p ledger))))

(deftest repl-eval-after-kill-breaks-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "repl-eval" 6)
    (%feed ledger "load-system" 7)
    (%feed ledger "run-tests" 8 :result (%tests-result 5 0))
    (ok (not (clean-verified-p ledger)))))

(deftest patch-after-load-breaks-clean
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "load-system" 6)
    (%feed ledger "lisp-edit-form" 7 :arguments (%hash "file_path" "a"))
    (%feed ledger "run-tests" 8 :result (%tests-result 5 0))
    (ok (not (clean-verified-p ledger)))))

(deftest failures-activate-then-resolve
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "lisp-edit-form" 3 :arguments (%hash "file_path" "a"))
    (%feed ledger "run-tests" 4
           :result (%tests-result 4 1 (list "test_name" "t-one"
                                            "reason" "boom")))
    (let ((failure (first (active-failures ledger))))
      (ok (= 1 (length (active-failures ledger))))
      (ok (equal "t-one" (failure-record-test-name failure)))
      (ok (equal "boom" (failure-record-reason failure)))
      (ok (= 3 (failure-record-patch-seq failure))))
    ;; Same failure again: no duplicate.
    (%feed ledger "run-tests" 6
           :result (%tests-result 4 1 (list "test_name" "t-one"
                                            "reason" "boom")))
    (ok (= 1 (length (active-failures ledger))))
    ;; Green run resolves.
    (%feed ledger "run-tests" 9 :result (%tests-result 5 0))
    (ok (null (active-failures ledger)))
    (ok (= 1 (length (resolved-failures ledger))))
    (ok (= 9 (failure-record-resolved-seq
              (first (resolved-failures ledger)))))))

(deftest graceful-without-structured-counts
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "run-tests" 3
           :result (%hash "content" (list (%hash "type" "text"
                                                 "text" "ok"))))
    (ok (last-test ledger))
    (ok (null (test-run-passed (last-test ledger))))
    (ok (null (active-failures ledger)))
    (ok (not (clean-verified-p ledger)))))
```

Create `next/src/verification-ledger.lisp` with the package definition only:

```lisp
;;;; next/src/verification-ledger.lisp
;;;;
;;;; Verification context (§3.9) with the §7 three-state separation
;;;; (runtime-observed / source-persisted / clean-verified) and the
;;;; §8 failure ledger (active vs resolved). Clean verification is
;;;; DERIVED from event order — kill < load < test, no repl-eval
;;;; since the kill, no successful patch since the load — so no new
;;;; event convention is needed (spec: 最終判定は clean runtime).

(defpackage #:cl-harness-next/src/verification-ledger
  (:use #:cl)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-interaction
                #:interaction-tool
                #:interaction-ok-p
                #:interaction-result
                #:interaction-error-message
                #:interaction-observation-seq
                #:+patch-tool-names+)
  (:export #:verification-ledger
           #:last-load
           #:last-test
           #:load-result-ok-p
           #:load-result-summary
           #:load-result-seq
           #:test-run-passed
           #:test-run-failed
           #:test-run-clean-p
           #:test-run-seq
           #:clean-verified-p
           #:active-failures
           #:resolved-failures
           #:failure-record-test-name
           #:failure-record-reason
           #:failure-record-seq
           #:failure-record-patch-seq
           #:failure-record-resolved-seq))

(in-package #:cl-harness-next/src/verification-ledger)
```

Add `"cl-harness-next/tests/verification-ledger-test"` to the tests system.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `verification-ledger` undefined; 83 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/verification-ledger.lisp`:

```lisp
(defstruct (load-result (:conc-name load-result-))
  ok-p summary seq)

(defstruct (test-run (:conc-name test-run-))
  passed failed clean-p seq)

(defstruct (failure-record (:conc-name failure-record-))
  test-name reason seq patch-seq (resolved-seq nil))

(defclass verification-ledger (projection)
  ((last-load :initform nil :accessor last-load)
   (last-test :initform nil :accessor last-test)
   (kill-seq :initform nil :accessor %kill-seq)
   (load-seq :initform nil :accessor %load-seq)
   (patch-seq :initform nil :accessor %patch-seq)
   (repl-seq :initform nil :accessor %repl-seq)
   (active-failures :initform nil :accessor active-failures
                    :documentation "FAILURE-RECORD structs, newest first.")
   (resolved-failures :initform nil :accessor resolved-failures
                      :documentation "Newest resolved first (§6.5)."))
  (:documentation "Verification state (§3.9/§7/§8)."))

(defun %clean-test-p (ledger)
  "Kill < load < (this test), no repl-eval since the kill, no
successful patch since the load."
  (let ((kill (%kill-seq ledger))
        (load (%load-seq ledger))
        (patch (%patch-seq ledger))
        (repl (%repl-seq ledger)))
    (and kill load (> load kill)
         (or (null repl) (< repl kill))
         (or (null patch) (< patch load))
         t)))

(defun %result-int (result key)
  (when (hash-table-p result)
    (multiple-value-bind (value present-p) (gethash key result)
      (when (and present-p (integerp value)) value))))

(defun %note-failure (ledger test-name reason seq)
  "Push an active failure unless the same test name is already active."
  (unless (and test-name
               (find test-name (active-failures ledger)
                     :key #'failure-record-test-name :test #'equal))
    (push (make-failure-record :test-name test-name
                               :reason reason
                               :seq seq
                               :patch-seq (%patch-seq ledger))
          (active-failures ledger))))

(defun %resolve-all-failures (ledger seq)
  (dolist (failure (active-failures ledger))
    (setf (failure-record-resolved-seq failure) seq)
    (push failure (resolved-failures ledger)))
  (setf (active-failures ledger) nil))

(defun %record-test-run (ledger interaction)
  (let* ((result (interaction-result interaction))
         (seq (interaction-observation-seq interaction))
         (passed (%result-int result "passed"))
         (failed (%result-int result "failed")))
    (setf (last-test ledger)
          (make-test-run :passed passed :failed failed
                         :clean-p (%clean-test-p ledger) :seq seq))
    (cond
      ((and failed (plusp failed))
       (let ((entries (when (hash-table-p result)
                        (gethash "failed_tests" result))))
         (if (consp entries)
             (dolist (entry entries)
               (when (hash-table-p entry)
                 (%note-failure ledger
                                (gethash "test_name" entry)
                                (gethash "reason" entry)
                                seq)))
             (%note-failure ledger nil
                            (format nil "~A test(s) failed" failed)
                            seq))))
      ((eql failed 0)
       (%resolve-all-failures ledger seq)))))

(defmethod apply-interaction ((ledger verification-ledger) interaction)
  (let ((tool (interaction-tool interaction))
        (seq (interaction-observation-seq interaction))
        (ok (interaction-ok-p interaction)))
    (cond
      ((string= tool "pool-kill-worker")
       (when ok (setf (%kill-seq ledger) seq)))
      ((string= tool "repl-eval")
       (setf (%repl-seq ledger) seq))
      ((member tool +patch-tool-names+ :test #'string=)
       (when ok (setf (%patch-seq ledger) seq)))
      ((string= tool "load-system")
       (setf (last-load ledger)
             (make-load-result
              :ok-p ok
              :summary (interaction-error-message interaction)
              :seq seq))
       (when ok (setf (%load-seq ledger) seq)))
      ((string= tool "run-tests")
       (%record-test-run ledger interaction))))
  ledger)

(defun clean-verified-p (ledger)
  "True when the LATEST test run was clean (kill→load→test order) and
fully green — the only state the spec accepts as final truth (§7)."
  (let ((run (last-test ledger)))
    (and run (test-run-clean-p run) (eql 0 (test-run-failed run)) t)))
```

- [ ] **Step 4: Run tests to verify green**

Expected: PASS — 90 tests (83 + 7).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/verification-ledger.lisp next/tests/verification-ledger-test.lisp
git add next/src/verification-ledger.lisp next/tests/verification-ledger-test.lisp cl-harness-next.asd
git commit -m "feat(next): verification ledger with derived clean-verify and failure tracking"
```

---

### Task 6: World model (pairing + replay + standard projections)

**Files:**
- Create: `next/tests/world-model-test.lisp`
- Create: `next/src/world-model.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/world-model-test.lisp`:

```lisp
;;;; next/tests/world-model-test.lisp
;;;;
;;;; Unit tests for next/src/world-model.lisp: action/observation
;;;; pairing (exactly once), standard projections, replay (spec §8.2).

(defpackage #:cl-harness-next/tests/world-model-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-text)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:probes
                #:findings)
  (:import-from #:cl-harness-next/src/world-model
                #:make-world-model
                #:make-standard-world-model
                #:world-model-projection
                #:world-model-last-seq
                #:update-world-model
                #:build-world-model))

(in-package #:cl-harness-next/tests/world-model-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defclass counting-projection (projection)
  ((events :initform 0 :accessor counted-events)
   (interactions :initform 0 :accessor counted-interactions)))

(defmethod apply-event ((projection counting-projection) event)
  (declare (ignore event))
  (incf (counted-events projection))
  projection)

(defmethod apply-interaction ((projection counting-projection) interaction)
  (declare (ignore interaction))
  (incf (counted-interactions projection))
  projection)

(deftest pairing-delivers-interaction-exactly-once
  (let* ((counter (make-instance 'counting-projection))
         (world-model (make-world-model :projections (list :count counter))))
    (update-world-model world-model
                        (make-harness-event
                         :action (%hash "tool" "repl-eval"
                                        "arguments" (%hash "code" "1"))
                         :seq 1))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "repl-eval"
                                             "result" (%hash "x" 1))
                         :seq 2))
    (ok (= 1 (counted-interactions counter)))
    (ok (= 2 (counted-events counter)))
    (ok (= 2 (world-model-last-seq world-model)))))

(deftest unmatched-observation-yields-no-interaction
  (let* ((counter (make-instance 'counting-projection))
         (world-model (make-world-model :projections (list :count counter))))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "run-tests") :seq 1))
    (update-world-model world-model
                        (make-harness-event
                         :action (%hash "tool" "repl-eval") :seq 2))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "OTHER-tool") :seq 3))
    (ok (zerop (counted-interactions counter)))
    (ok (= 3 (counted-events counter)))))

(deftest standard-world-model-has-four-projections
  (let ((world-model (make-standard-world-model)))
    (dolist (key '(:goal :exploration :changes :verification))
      (ok (world-model-projection world-model key)))
    (ok (null (world-model-projection world-model :nope)))))

(deftest build-from-log-replays-everything
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start (%hash "goal" "ship it"))
      (emit-event log :action (%hash "tool" "repl-eval"
                                     "arguments" (%hash "code" "(f)")))
      (emit-event log :observation (%hash "tool" "repl-eval"
                                          "result" (%hash "ok" t)))
      (emit-event log :decision (%hash "kind" "finding"
                                       "hypothesis" "h" "probe" "p"
                                       "finding" "f" "decision" "d")))
    (let ((world-model (build-world-model path)))
      (ok (equal "ship it"
                 (goal-text (world-model-projection world-model :goal))))
      (ok (= 1 (length (probes (world-model-projection world-model
                                                       :exploration)))))
      (ok (= 1 (length (findings (world-model-projection world-model
                                                         :exploration)))))
      (ok (= 4 (world-model-last-seq world-model))))))
```

Create `next/src/world-model.lisp` with the package definition only:

```lisp
;;;; next/src/world-model.lisp
;;;;
;;;; World model aggregate (spec §8.2): folds the event log into a
;;;; set of projections, pairing each :action with its following
;;;; :observation exactly once. In-memory only — rebuild with
;;;; BUILD-WORLD-MODEL (suspend/resume needs nothing but the log).

(defpackage #:cl-harness-next/src/world-model
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-seq
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:replay-events)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event
                #:apply-interaction
                #:make-interaction)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-projection)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:exploration-ledger)
  (:import-from #:cl-harness-next/src/change-ledger
                #:change-ledger)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:verification-ledger)
  (:export #:world-model
           #:make-world-model
           #:make-standard-world-model
           #:world-model-projection
           #:world-model-last-seq
           #:update-world-model
           #:build-world-model))

(in-package #:cl-harness-next/src/world-model)
```

Add `"cl-harness-next/tests/world-model-test"` to the tests system.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `make-world-model` undefined; 90 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/world-model.lisp`:

```lisp
(defclass world-model ()
  ((projections :initarg :projections :reader %projections
                :documentation "Plist of key → PROJECTION.")
   (pending-action :initform nil :accessor %pending-action)
   (last-seq :initform 0 :accessor world-model-last-seq))
  (:documentation "Aggregate of projections over one event log
(spec §8.2). In-memory only; rebuild with BUILD-WORLD-MODEL."))

(defun make-world-model (&key projections)
  "Build a WORLD-MODEL over PROJECTIONS (a plist of key → projection)."
  (make-instance 'world-model :projections projections))

(defun make-standard-world-model ()
  "World model with the four standard SP3 projections:
:goal, :exploration, :changes, :verification."
  (make-world-model
   :projections (list :goal (make-instance 'goal-projection)
                      :exploration (make-instance 'exploration-ledger)
                      :changes (make-instance 'change-ledger)
                      :verification (make-instance 'verification-ledger))))

(defun world-model-projection (world-model key)
  "Return the projection registered under KEY, or NIL."
  (getf (%projections world-model) key))

(defun %each-projection (world-model function)
  (loop for (key projection) on (%projections world-model) by #'cddr
        do (progn key (funcall function projection))))

(defun %payload-tool (event)
  (let ((payload (event-payload event)))
    (when (hash-table-p payload)
      (gethash "tool" payload))))

(defun update-world-model (world-model event)
  "Fold one EVENT into WORLD-MODEL. An :action is held until its
:observation (same tool) arrives; the pair is then delivered exactly
once to every projection as an INTERACTION. Every raw event is also
delivered via APPLY-EVENT. Returns WORLD-MODEL."
  (setf (world-model-last-seq world-model) (event-seq event))
  (case (event-type event)
    (:action
     (setf (%pending-action world-model) event))
    (:observation
     (let* ((pending (%pending-action world-model))
            (pending-tool (and pending (%payload-tool pending))))
       (when (and pending-tool
                  (equal pending-tool (%payload-tool event)))
         (let ((interaction (make-interaction pending event)))
           (%each-projection world-model
                             (lambda (projection)
                               (apply-interaction projection interaction))))
         (setf (%pending-action world-model) nil)))))
  (%each-projection world-model
                    (lambda (projection) (apply-event projection event)))
  world-model)

(defun build-world-model (log-path &key (world-model
                                         (make-standard-world-model)))
  "Rebuild WORLD-MODEL by replaying the event log at LOG-PATH."
  (replay-events log-path
                 (lambda (accumulator event)
                   (update-world-model accumulator event))
                 world-model))
```

- [ ] **Step 4: Run tests to verify green**

Expected: PASS — 94 tests (90 + 4).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/world-model.lisp next/tests/world-model-test.lisp
git add next/src/world-model.lisp next/tests/world-model-test.lisp cl-harness-next.asd
git commit -m "feat(next): world model with exactly-once interaction pairing"
```

---

### Task 7: Context compiler (budget-bounded views)

**Files:**
- Create: `next/tests/context-compiler-test.lisp`
- Create: `next/src/context-compiler.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/context-compiler-test.lisp`:

```lisp
;;;; next/tests/context-compiler-test.lisp
;;;;
;;;; Unit tests for next/src/context-compiler.lisp (spec §8.3, doc
;;;; §4/§5/§6): hard token budget, empty-section elision, staleness
;;;; and promotion annotations, failure-analysis prioritisation.

(defpackage #:cl-harness-next/tests/context-compiler-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:update-world-model)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context
                #:estimate-tokens))

(in-package #:cl-harness-next/tests/context-compiler-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defvar *seq* 0)

(defun %feed (world-model type &rest plist)
  (update-world-model world-model
                      (make-harness-event
                       type (when plist (apply #'%hash plist))
                       :seq (incf *seq*))))

(defun %feed-interaction (world-model tool &key arguments result error)
  (%feed world-model :action "tool" tool "arguments" arguments)
  (if error
      (%feed world-model :observation "tool" tool "error" error)
      (%feed world-model :observation "tool" tool
             "result" (or result (%hash "ok" t)))))

(defun %sample-world-model ()
  "A world model with content in every section."
  (let ((*seq* 0)
        (world-model (make-standard-world-model)))
    (%feed world-model :run-start
           "goal" "Fix the cache eviction bug"
           "acceptance_criteria" (list "tests pass"))
    (%feed world-model :decision
           "kind" "decision" "text" "no macro" "rationale" "one call site")
    (%feed world-model :decision
           "kind" "finding" "hypothesis" "lru list ordering"
           "probe" "repl" "finding" "reversed" "decision" "fix compare")
    (%feed-interaction world-model "lisp-read-file"
                       :arguments (%hash "path" "src/cache.lisp"))
    (%feed-interaction world-model "repl-eval"
                       :arguments (%hash "code" "(evict)")
                       :result (%hash "content"
                                      (list (%hash "type" "text"
                                                   "text" "NIL"))))
    (%feed-interaction world-model "lisp-edit-form"
                       :arguments (%hash "file_path" "src/cache.lisp"
                                         "form_type" "defun"
                                         "form_name" "evict"
                                         "operation" "replace"
                                         "content" "lru list ordering fix"))
    (%feed-interaction world-model "run-tests"
                       :result (%hash "passed" 4 "failed" 1
                                      "failed_tests"
                                      (list (%hash "test_name" "evict-test"
                                                   "reason" "boom"))))
    world-model))

(defun %green-world-model ()
  "Sample world model driven to a clean green finish."
  (let ((world-model (%sample-world-model)))
    (let ((*seq* 20))
      (%feed-interaction world-model "pool-kill-worker")
      (%feed-interaction world-model "load-system")
      (%feed-interaction world-model "run-tests"
                         :result (%hash "passed" 5 "failed" 0)))
    world-model))

(deftest estimate-tokens-is-ceiling-of-quarter
  (ok (= 1 (estimate-tokens "abc")))
  (ok (= 1 (estimate-tokens "abcd")))
  (ok (= 2 (estimate-tokens "abcde")))
  (ok (= 0 (estimate-tokens ""))))

(deftest generous-budget-includes-all-sections
  (let ((view (compile-context (%sample-world-model))))
    (ok (search "Fix the cache eviction bug" view))
    (ok (search "## Verification" view))
    (ok (search "evict-test" view))
    (ok (search "no macro" view))
    (ok (search "## Recent patches" view))
    (ok (search "## Runtime probes" view))
    (ok (search "src/cache.lisp" view))))

(deftest empty-sections-are-elided
  (let ((view (compile-context (make-standard-world-model))))
    (ok (not (search "## Decisions" view)))
    (ok (not (search "## Recent patches" view)))
    (ok (not (search "## Findings" view)))))

(deftest tiny-budget-is-hard-bounded
  (let* ((budget 60)
         (view (compile-context (%sample-world-model)
                                :token-budget budget)))
    (ok (<= (estimate-tokens view) budget))
    (ok (search "Fix the cache eviction bug" view))
    (ok (search "omitted" view))))

(deftest annotations-are-rendered
  (let ((view (compile-context (%green-world-model))))
    ;; The probe predates the patch → [STALE]; the patch content
    ;; contains the finding hypothesis → [PROMOTED].
    (ok (search "[STALE]" view))
    (ok (search "[PROMOTED]" view))
    (ok (search "clean-verified: YES" view))
    (ok (search "regression watch" view))
    (ok (search "evict-test" view))))

(deftest failure-analysis-prioritises-failures
  (let ((view (compile-context (%sample-world-model)
                               :decision-point :failure-analysis)))
    (let ((failures-at (search "## Active failures" view))
          (patches-at (search "## Recent patches" view)))
      (ok failures-at)
      (ok patches-at)
      (ok (< failures-at patches-at)))
    (ok (search "## Next step" view))
    ;; Stale probes are filtered out of failure analysis (fresh only).
    (ok (not (search "[STALE]" view)))))
```

Create `next/src/context-compiler.lisp` with the package definition only:

```lisp
;;;; next/src/context-compiler.lisp
;;;;
;;;; Context compiler (spec §8.3, doc §4/§5/§6): a pure function of
;;;; the world model producing a token-budget-bounded markdown view.
;;;; The budget is a HARD guarantee — every addition is admitted only
;;;; if the whole view still fits. Empty sections are elided (Phase J
;;;; lesson); staleness/promotion are render-time annotations
;;;; (Phase F/H lessons: annotate, don't filter — except the
;;;; failure-analysis view, which shows fresh probes only).

(defpackage #:cl-harness-next/src/context-compiler
  (:use #:cl)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-text
                #:acceptance-criteria
                #:non-goals
                #:decisions
                #:decision-text
                #:decision-rationale)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:findings
                #:probes
                #:finding-hypothesis
                #:finding-text
                #:finding-decision
                #:finding-promoted-p
                #:probe-tool
                #:probe-code
                #:probe-summary
                #:probe-seq
                #:probe-stale-p)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches
                #:source-facts
                #:patch-entry-file
                #:patch-entry-form-type
                #:patch-entry-form-name
                #:patch-entry-operation
                #:patch-entry-ok-p
                #:patch-entry-seq
                #:source-fact-file
                #:source-fact-detail
                #:source-fact-seq
                #:source-fact-stale-p)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:last-load
                #:last-test
                #:load-result-ok-p
                #:load-result-summary
                #:test-run-passed
                #:test-run-failed
                #:test-run-clean-p
                #:clean-verified-p
                #:active-failures
                #:resolved-failures
                #:failure-record-test-name
                #:failure-record-reason
                #:failure-record-seq
                #:failure-record-patch-seq
                #:failure-record-resolved-seq)
  (:export #:compile-context
           #:estimate-tokens))

(in-package #:cl-harness-next/src/context-compiler)
```

Add `"cl-harness-next/tests/context-compiler-test"` to the tests system.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `compile-context` undefined; 94 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/context-compiler.lisp`:

```lisp
(defconstant +recent-limit+ 5
  "Max items rendered for recent-history sections.")

(defconstant +resolved-limit+ 3
  "Max resolved failures rendered (legacy regression-watch default).")

(defun estimate-tokens (string)
  "Crude token estimate: ceiling(characters / 4)."
  (ceiling (length string) 4))

(defun %take (n list)
  (subseq list 0 (min n (length list))))

;; --- Section line builders ------------------------------------------------

(defun %goal-lines (goal)
  (when goal
    (let ((lines '()))
      (when (goal-text goal) (push (goal-text goal) lines))
      (dolist (criterion (acceptance-criteria goal))
        (push (format nil "- accept: ~A" criterion) lines))
      (dolist (non-goal (non-goals goal))
        (push (format nil "- non-goal: ~A" non-goal) lines))
      (nreverse lines))))

(defun %verification-lines (verification)
  (when verification
    (let ((lines '()))
      (let ((load (last-load verification)))
        (when load
          (push (format nil "load-system: ~A~@[ (~A)~]"
                        (if (load-result-ok-p load) "OK" "FAILED")
                        (load-result-summary load))
                lines)))
      (let ((run (last-test verification)))
        (when run
          (push (format nil "run-tests: passed ~A, failed ~A (~A)"
                        (or (test-run-passed run) "?")
                        (or (test-run-failed run) "?")
                        (if (test-run-clean-p run)
                            "clean image"
                            "runtime state only"))
                lines)))
      (push (format nil "clean-verified: ~A"
                    (if (clean-verified-p verification) "YES" "NO"))
            lines)
      (nreverse lines))))

(defun %active-failure-lines (verification)
  (when verification
    (mapcar (lambda (failure)
              (format nil "- ~A: ~A (seq ~A~@[, after patch seq ~A~])"
                      (or (failure-record-test-name failure) "(unnamed)")
                      (or (failure-record-reason failure) "?")
                      (failure-record-seq failure)
                      (failure-record-patch-seq failure)))
            (active-failures verification))))

(defun %decision-lines (goal)
  (when goal
    (mapcar (lambda (decision)
              (format nil "- ~A~@[ — ~A~]"
                      (decision-text decision)
                      (decision-rationale decision)))
            (reverse (decisions goal)))))

(defun %finding-lines (exploration)
  (when exploration
    (mapcar (lambda (finding)
              (format nil "- ~A ~A → ~A (decision: ~A)"
                      (if (finding-promoted-p finding)
                          "[PROMOTED]"
                          "[NOT SHIPPED]")
                      (finding-hypothesis finding)
                      (finding-text finding)
                      (finding-decision finding)))
            (reverse (findings exploration)))))

(defun %patch-lines (changes)
  (when changes
    (mapcar (lambda (patch)
              (format nil "- seq ~A ~A ~@[~A ~]~@[~A ~]in ~A~@[ [FAILED]~]"
                      (patch-entry-seq patch)
                      (patch-entry-operation patch)
                      (patch-entry-form-type patch)
                      (patch-entry-form-name patch)
                      (or (patch-entry-file patch) "?")
                      (not (patch-entry-ok-p patch))))
            (%take +recent-limit+ (patches changes)))))

(defun %probe-lines (exploration &key fresh-only)
  (when exploration
    (let ((selected (if fresh-only
                        (remove-if (lambda (probe)
                                     (probe-stale-p probe exploration))
                                   (probes exploration))
                        (probes exploration))))
      (mapcar (lambda (probe)
                (format nil "- ~@[~A ~]seq ~A ~A: ~A => ~A"
                        (when (probe-stale-p probe exploration) "[STALE]")
                        (probe-seq probe)
                        (probe-tool probe)
                        (or (probe-code probe) "?")
                        (or (probe-summary probe) "?")))
              (%take +recent-limit+ selected)))))

(defun %source-fact-lines (changes)
  (when changes
    (mapcar (lambda (fact)
              (format nil "- ~@[~A ~]~A~@[ (~A)~]"
                      (when (source-fact-stale-p fact changes) "[STALE]")
                      (or (source-fact-file fact) "(search)")
                      (source-fact-detail fact)))
            (%take +recent-limit+ (source-facts changes)))))

(defun %resolved-lines (verification)
  (when verification
    (mapcar (lambda (failure)
              (format nil "- ~A (resolved seq ~A)"
                      (or (failure-record-test-name failure) "(unnamed)")
                      (failure-record-resolved-seq failure)))
            (%take +resolved-limit+ (resolved-failures verification)))))

;; --- Section selection per decision point ----------------------------------

(defun %normal-sections (world-model)
  (let ((goal (world-model-projection world-model :goal))
        (exploration (world-model-projection world-model :exploration))
        (changes (world-model-projection world-model :changes))
        (verification (world-model-projection world-model :verification)))
    (list (cons "Goal" (%goal-lines goal))
          (cons "Verification" (%verification-lines verification))
          (cons "Active failures" (%active-failure-lines verification))
          (cons "Decisions" (%decision-lines goal))
          (cons "Findings" (%finding-lines exploration))
          (cons "Recent patches" (%patch-lines changes))
          (cons "Runtime probes" (%probe-lines exploration))
          (cons "Source facts" (%source-fact-lines changes))
          (cons "Recently resolved failures (regression watch)"
                (%resolved-lines verification)))))

(defun %failure-sections (world-model)
  "Failure-analysis view (§8): failures first, linked to recent
patches; fresh probes only; explicit next-step guidance."
  (let ((goal (world-model-projection world-model :goal))
        (exploration (world-model-projection world-model :exploration))
        (changes (world-model-projection world-model :changes))
        (verification (world-model-projection world-model :verification)))
    (list (cons "Goal" (%take 1 (%goal-lines goal)))
          (cons "Active failures" (%active-failure-lines verification))
          (cons "Recent patches" (%patch-lines changes))
          (cons "Verification" (%verification-lines verification))
          (cons "Fresh runtime probes"
                (%probe-lines exploration :fresh-only t))
          (cons "Findings" (%finding-lines exploration))
          (cons "Next step"
                (list (concatenate 'string
                                   "Link the failure to the most recent"
                                   " patches, form one hypothesis, and"
                                   " probe it in the REPL before"
                                   " patching again."))))))

;; --- Budgeted assembly ------------------------------------------------------

(defun %try-add (current addition token-budget)
  "Return CURRENT with ADDITION appended (newline-separated) when the
result stays within TOKEN-BUDGET, else NIL."
  (let ((candidate (if (zerop (length current))
                       addition
                       (concatenate 'string current (string #\Newline)
                                    addition))))
    (when (<= (estimate-tokens candidate) token-budget)
      candidate)))

(defun %add-section (view title lines token-budget)
  "Append section TITLE/LINES to VIEW within TOKEN-BUDGET. Lines that
do not fit are dropped with an omission marker. Returns
(values new-view included-p)."
  (let ((with-title (%try-add view (format nil "## ~A" title)
                              token-budget)))
    (if (null with-title)
        (values view nil)
        (let ((current with-title)
              (included 0))
          (dolist (line lines)
            (let ((next (%try-add current line token-budget)))
              (if next
                  (progn (setf current next) (incf included))
                  (return))))
          (when (< included (length lines))
            (let ((next (%try-add current
                                  (format nil "(~D more omitted)"
                                          (- (length lines) included))
                                  token-budget)))
              (when next (setf current next))))
          (if (zerop included)
              (values view nil)
              (values current t))))))

(defun compile-context (world-model &key (decision-point :normal)
                                         (token-budget 8000)
                                         role dial)
  "Compile a bounded markdown context view from WORLD-MODEL (spec
§8.3): a pure function of the world model. DECISION-POINT is :normal
or :failure-analysis. ROLE and DIAL complete the spec'd signature;
their selection profiles arrive with the control policies (SP5/SP6)
and are currently unused. The result is guaranteed to estimate at
most TOKEN-BUDGET tokens."
  (declare (ignore role dial))
  (let ((sections (ecase decision-point
                    (:normal (%normal-sections world-model))
                    (:failure-analysis (%failure-sections world-model))))
        (view "")
        (omitted '()))
    (loop for (title . lines) in sections
          when lines
            do (multiple-value-bind (next included-p)
                   (%add-section view title lines token-budget)
                 (if included-p
                     (setf view next)
                     (push title omitted))))
    (when omitted
      (let ((next (%try-add view
                            (format nil "(omitted for budget: ~{~A~^, ~})"
                                    (nreverse omitted))
                            token-budget)))
        (when next (setf view next))))
    view))
```

- [ ] **Step 4: Run tests to verify green**

Expected: PASS — 100 tests (94 + 6).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/context-compiler.lisp next/tests/context-compiler-test.lisp
git add next/src/context-compiler.lisp next/tests/context-compiler-test.lisp cl-harness-next.asd
git commit -m "feat(next): context compiler with hard token budget"
```

---

### Task 8: Facade, acceptance test, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`

- [ ] **Step 1: Write the failing acceptance test**

Append to `next/tests/main-test.lisp` (facade symbols only):

```lisp
(deftest world-model-and-context-from-event-log
  ;; SP3 acceptance: replaying a full synthetic run's event log yields
  ;; a world model whose compiled views are bounded and annotated
  ;; (spec §8.2/§8.3; doc §5/§7/§9).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let ((log (cl-harness-next:open-event-log log-path)))
      (flet ((emit (type &rest plist)
               (cl-harness-next:emit-event
                log type (alexandria:plist-hash-table plist :test #'equal)))
             (h (&rest plist)
               (alexandria:plist-hash-table plist :test #'equal)))
        (emit :run-start "goal" "Fix evict")
        (emit :decision "kind" "finding" "hypothesis" "ordering bug"
              "probe" "repl" "finding" "reversed" "decision" "fix it")
        (emit :action "tool" "repl-eval" "arguments" (h "code" "(evict)"))
        (emit :observation "tool" "repl-eval" "result" (h "ok" t))
        (emit :action "tool" "lisp-edit-form"
              "arguments" (h "file_path" "src/cache.lisp"
                             "content" "ordering bug fix"))
        (emit :observation "tool" "lisp-edit-form" "result" (h "ok" t))
        (emit :action "tool" "pool-kill-worker")
        (emit :observation "tool" "pool-kill-worker" "result" (h "ok" t))
        (emit :action "tool" "load-system")
        (emit :observation "tool" "load-system" "result" (h "ok" t))
        (emit :action "tool" "run-tests")
        (emit :observation "tool" "run-tests"
              "result" (h "passed" 5 "failed" 0))))
    (let* ((world-model (cl-harness-next:build-world-model log-path))
           (view (cl-harness-next:compile-context world-model))
           (small (cl-harness-next:compile-context world-model
                                                   :token-budget 50)))
      (ok (cl-harness-next:clean-verified-p
           (cl-harness-next:world-model-projection world-model
                                                   :verification)))
      (ok (search "Fix evict" view))
      (ok (search "clean-verified: YES" view))
      (ok (search "[PROMOTED]" view))
      (ok (search "[STALE]" view))
      (ok (<= (cl-harness-next:estimate-tokens small) 50)))))
```

- [ ] **Step 2: Run tests to verify it fails**

Expected: FAIL at load — `cl-harness-next:build-world-model` not
exported from the facade yet.

- [ ] **Step 3: Extend the facade**

In `next/src/main.lisp`'s `defpackage` (lisp-edit-form `replace`,
preserving every existing clause):

Add these `:import-from` clauses after the environment one:

```lisp
  (:import-from #:cl-harness-next/src/world-model
                #:world-model
                #:make-world-model
                #:make-standard-world-model
                #:world-model-projection
                #:world-model-last-seq
                #:update-world-model
                #:build-world-model)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context
                #:estimate-tokens)
```

Add to the `:export` list:

```lisp
           ;; world-model
           #:world-model
           #:make-world-model
           #:make-standard-world-model
           #:world-model-projection
           #:world-model-last-seq
           #:update-world-model
           #:build-world-model
           #:clean-verified-p
           ;; context-compiler
           #:compile-context
           #:estimate-tokens
```

- [ ] **Step 4: Run tests — expect green**

Expected: PASS — 101 tests / 0 failures.

- [ ] **Step 5: Full force-compile**

repl-eval `(asdf:compile-system :cl-harness-next :force t)`.
Expected: no warnings from `next/` sources (infra redefinition notes
acceptable). Check columns: `awk 'length > 100 {print FILENAME": "FNR}' next/src/*.lisp next/tests/*.lisp` — expect no output.

- [ ] **Step 6: Document**

In `README.md`'s next/ subsection, change the SP1/SP2 sentence to:

```markdown
SP1 ships the L0 event log (JSONL event sourcing) and policy pack
(versioned, fingerprinted prompt/config bundles); SP2 adds the L1
environment — cl-mcp wrapped as a policy-restricted observation/action
space (stdio subprocess per run) whose actions and observations are
recorded into the event log; SP3 adds the L2 world model (projections
with staleness and derived clean-verify state) and the token-budgeted
context compiler. It does not affect the `cl-harness` CLI.
```

- [ ] **Step 7: Lint everything and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP3 world-model/context acceptance test"
```

---

## Verification checklist (whole sub-project)

- Clean image: `pool-kill-worker` → `load-asd` → `load-system
  cl-harness-next` (no warnings from next/ sources) → `run-tests
  cl-harness-next/tests` 101/0.
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (later sub-projects — do NOT build now)

- Runtime-vocabulary projection (legacy Phase G) — needs the
  tool-result-shape parsing that belongs with a real consumer (SP5
  kernel); the probe ledger covers exploration context v1.
- Cross-run memory (project/harness tiers, spec §8.4) — meaningful
  only once missions exist (SP7).
- Structured final reports from the world model (doc §10) — consumer
  arrives with the kernel/mission layers.
- Role/dial-specific context view profiles — SP5/SP6, as policy-pack
  data per 原則4.
- Agenda/plan projection — there are no plan events until the control
  policies (SP5) emit them.
- Unresolved-risk ledger (spec §8.2 lists it) — same reason: no
  emitter exists until the control policies; add a :decision kind
  "risk" convention when SP5 needs it.
- Live incremental wiring of environment → world model (the kernel's
  loop, SP5) — SP3 ships `update-world-model` for it.
- Findings/Decisions render oldest-first and uncapped, so budget
  pressure drops the NEWEST entries first (final review Minor #3) —
  revisit with the role/dial view profiles (SP5/SP6).
- Within one green run, resolved failures keep active-list order
  (newest-resolved-first only holds across runs) — cosmetic.
- Patch entries carry no 変更理由/diff要約 (doc §3.8 fields); add a
  payload convention (e.g. patch arguments "reason") when SP5's
  policies start emitting one.
