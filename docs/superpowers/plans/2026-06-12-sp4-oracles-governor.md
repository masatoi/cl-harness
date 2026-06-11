# SP4: L2 Oracles + Governor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L2 oracle layer of the autonomous-harness redesign — a consultable oracle protocol whose verdicts are recorded as `:oracle-result` events, four oracles (verification via the L1 environment, invariant AST checks, LLM review via injected judge, progress governor), and condition/restart-based governor interventions.

**Architecture:** An `oracle` protocol (`oracle-name` / `evaluate` → `verdict`; `consult` = evaluate + `:oracle-result` event — spec §7's "oracle consultations are observations"). `verification-oracle` drives kill→load→test THROUGH the L1 environment, so the very event trail it produces is what SP3's verification-ledger independently derives clean-verify from. `invariant-oracle` generalizes legacy `validate-test-source` (hardened scratch-package reader, configurable invariant set). `review-oracle` takes an injected `judge-fn` (the LLM provider arrives in SP5) and consumes policy-pack `:oracle-profiles` for stage-aware strictness (PRD §19's soft/strict/strictest table as data). `governor` is BOTH a projection and an oracle (counters folded from interactions; thresholds from pack budgets) with keyword-named restarts (`:demote-dial` `:replan` `:park-mission` `:ask-human` `:abort-run` — keyword names per the project's own documented cross-package restart lesson). Task 1 first fixes a cross-SP coherence gap: MCP tool failures arrive as result `isError`, which SP3's transport-level `interaction-ok-p` misses. Spec: `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md` §7/§11/§12.

**Tech Stack:** SBCL, ASDF package-inferred-system, rove, alexandria, yason. No new dependencies.

**Conventions that bind this plan** (same as SP1–SP3): 2-space indent, ≤100 columns, blank line between top-level forms, docstrings on public functions/classes/generics, no `:local-nicknames`, third-party via qualified names, structs for internal records, `%`-prefix internals, conditions get `:initform` on every slot (print-bare hardening). cl-mcp tools for Lisp edits (Write for new files + `lisp-check-parens`; `lisp-patch-form`/`lisp-edit-form` for existing — re-read the target form first; restore conventional layout if lisp-edit-form reformats `define-condition`). `mallet` before each commit; tests via cl-mcp `run-tests` `{"system": "cl-harness-next/tests"}`; after a worker restart `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`. If mallet flags an unused import in a TEST file, remove it and note it (established precedent). All new constants are NEW — no `define-constant` redefinition hazard.

---

## File Structure

```text
next/src/projection.lisp           MOD  + result-error-p, interaction-succeeded-p
next/src/exploration-ledger.lisp   MOD  succeeded-p for invalidation/promotion
next/src/change-ledger.lisp        MOD  succeeded-p for patch ok-p / source facts
next/src/verification-ledger.lisp  MOD  succeeded-p for kill/patch/load; isError load summary
next/src/oracle.lisp               NEW  protocol + verdict + consult (:oracle-result events)
next/src/invariant-oracle.lisp     NEW  hardened reader + configurable AST invariants
next/src/verification-oracle.lisp  NEW  kill→load→test through the L1 environment
next/src/review-oracle.lisp        NEW  judge-fn + pack profile + APPROVE/REJECT parse
next/src/governor.lisp             NEW  progress projection+oracle, conditions, restarts
next/src/main.lisp                 MOD  facade re-exports
next/tests/projection-test.lisp          MOD (+2)
next/tests/exploration-ledger-test.lisp  MOD (+1)
next/tests/change-ledger-test.lisp       MOD (+1, helper gains :result)
next/tests/verification-ledger-test.lisp MOD (+1)
next/tests/oracle-test.lisp              NEW (+3)
next/tests/invariant-oracle-test.lisp    NEW (+7)
next/tests/verification-oracle-test.lisp NEW (+6)
next/tests/review-oracle-test.lisp       NEW (+6)
next/tests/governor-test.lisp            NEW (+5 in Task 6, +5 in Task 7)
next/tests/main-test.lisp                MOD (+1 acceptance)
cl-harness-next.asd                MOD  + 5 test files
README.md                          MOD  one sentence
```

Test-count checkpoints: 104 → T1 109 → T2 112 → T3 119 → T4 125 → T5 131 → T6 136 → T7 141 → T8 142.

---

### Task 1: isError coherence (`interaction-succeeded-p`)

cl-mcp (like MCP generally) reports TOOL failures inside the result
(`"isError": true` + content), not as JSON-RPC errors. SP3's
`interaction-ok-p` is transport-level only, so a failed `load-system`
currently counts as ok — which could fake a clean-verify. Fix before
building the verification oracle on top.

**Files:**
- Modify: `next/src/projection.lisp`, `next/src/exploration-ledger.lisp`, `next/src/change-ledger.lisp`, `next/src/verification-ledger.lisp`
- Modify: `next/tests/projection-test.lisp`, `next/tests/exploration-ledger-test.lisp`, `next/tests/change-ledger-test.lisp`, `next/tests/verification-ledger-test.lisp`

- [ ] **Step 1: Write the failing tests**

`next/tests/projection-test.lisp` — extend `:import-from` with
`#:result-error-p #:interaction-succeeded-p`, append:

```lisp
(deftest result-error-p-reads-iserror
  (let ((errorful (make-instance 'interaction :tool "x"
                                 :result (%hash "isError" t)
                                 :action-seq 1 :observation-seq 2))
        (fine (make-instance 'interaction :tool "x"
                             :result (%hash "isError" nil)
                             :action-seq 1 :observation-seq 2))
        (absent (make-instance 'interaction :tool "x"
                               :result (%hash "passed" 3)
                               :action-seq 1 :observation-seq 2)))
    (ok (result-error-p errorful))
    (ok (not (result-error-p fine)))
    (ok (not (result-error-p absent)))))

(deftest succeeded-requires-transport-and-tool-success
  (let ((tool-failed (make-instance 'interaction :tool "x"
                                    :result (%hash "isError" t)
                                    :action-seq 1 :observation-seq 2))
        (transport-failed (make-instance 'interaction :tool "x"
                                         :error-message "boom"
                                         :action-seq 1 :observation-seq 2))
        (fine (make-instance 'interaction :tool "x"
                             :result (%hash "ok" t)
                             :action-seq 1 :observation-seq 2)))
    (ok (not (interaction-succeeded-p tool-failed)))
    (ok (not (interaction-succeeded-p transport-failed)))
    (ok (interaction-succeeded-p fine))))
```

`next/tests/verification-ledger-test.lisp` — append:

```lisp
(deftest iserror-load-is-not-ok
  ;; SP4 coherence fix: cl-mcp reports tool failure via result isError,
  ;; not a transport error. A failed load must not enable clean-verify.
  (let ((ledger (make-instance 'verification-ledger)))
    (%feed ledger "pool-kill-worker" 5)
    (%feed ledger "load-system" 6 :result (%hash "isError" t))
    (ok (not (load-result-ok-p (last-load ledger))))
    (%feed ledger "run-tests" 7 :result (%tests-result 5 0))
    (ok (not (clean-verified-p ledger)))))
```

`next/tests/change-ledger-test.lisp` — extend the `%interaction` helper
to accept `:result` (replace the helper defun):

```lisp
(defun %interaction (tool &key arguments result error (observation-seq 2))
  (make-instance 'interaction
                 :tool tool
                 :arguments arguments
                 :result result
                 :error-message error
                 :action-seq (1- observation-seq)
                 :observation-seq observation-seq))
```

then append:

```lisp
(deftest iserror-patch-is-not-ok
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/a.lisp")
                          :observation-seq 3))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "file_path" "src/a.lisp")
                          :result (%hash "isError" t)
                          :observation-seq 5))
    (ok (not (patch-entry-ok-p (first (patches ledger)))))
    (ok (not (source-fact-stale-p (first (source-facts ledger)) ledger)))))
```

`next/tests/exploration-ledger-test.lisp` — append:

```lisp
(deftest iserror-patch-neither-promotes-nor-invalidates
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 2 "ordering bug"))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 3))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "ordering bug fix")
                          :result (%hash "isError" t)
                          :observation-seq 5))
    (ok (not (finding-promoted-p (first (findings ledger)))))
    (ok (not (probe-stale-p (first (probes ledger)) ledger)))))
```

- [ ] **Step 2: Run tests to verify red** — expect the 4 new tests
failing (`result-error-p` undefined; the ledger tests fail because
isError currently counts as ok); 104 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/projection.lisp` (and add `#:result-error-p`
`#:interaction-succeeded-p` to its `:export`):

```lisp
(defun result-error-p (interaction)
  "True when the TOOL itself reported failure (MCP result \"isError\")
— distinct from transport-level failure (INTERACTION-OK-P)."
  (let ((result (interaction-result interaction)))
    (and (hash-table-p result)
         (multiple-value-bind (value present-p) (gethash "isError" result)
           (and present-p value t)))))

(defun interaction-succeeded-p (interaction)
  "True when the round-trip completed AND the tool reported success."
  (and (interaction-ok-p interaction)
       (not (result-error-p interaction))))
```

`next/src/exploration-ledger.lisp` — add `#:interaction-succeeded-p` to
its projection `:import-from`; replace the `apply-interaction`
defmethod with (probes still record on transport-ok — a failed probe is
still an observation; invalidation/promotion require tool success):

```lisp
(defmethod apply-interaction ((ledger exploration-ledger) interaction)
  (let ((tool (interaction-tool interaction))
        (seq (interaction-observation-seq interaction)))
    (cond
      ((and (interaction-ok-p interaction)
            (member tool +probe-tool-names+ :test #'string=))
       (push (make-probe :tool tool
                         :code (argument-string interaction "code")
                         :summary (result-text interaction)
                         :seq seq)
             (probes ledger)))
      ((and (interaction-succeeded-p interaction)
            (member tool +patch-tool-names+ :test #'string=))
       (setf (%invalidation-seq ledger) seq)
       (%promote-matching-findings ledger interaction))
      ((and (interaction-succeeded-p interaction)
            (or (string= tool "load-system")
                (string= tool "pool-kill-worker")))
       (setf (%invalidation-seq ledger) seq))))
  ledger)
```

`next/src/change-ledger.lisp` — add `#:interaction-succeeded-p` to its
projection `:import-from`; in `apply-interaction`, change the
patch-entry's `:ok-p (interaction-ok-p interaction)` to
`:ok-p (interaction-succeeded-p interaction)` and the source-fact
guard's `(interaction-ok-p interaction)` to
`(interaction-succeeded-p interaction)` (use `lisp-patch-form`).

`next/src/verification-ledger.lisp` — add `#:interaction-succeeded-p`
and `#:result-text` to its projection `:import-from`; replace the
`apply-interaction` defmethod with:

```lisp
(defmethod apply-interaction ((ledger verification-ledger) interaction)
  (let ((tool (interaction-tool interaction))
        (seq (interaction-observation-seq interaction))
        (ok (interaction-succeeded-p interaction)))
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
              :summary (or (interaction-error-message interaction)
                           (unless ok (result-text interaction)))
              :seq seq))
       (when ok (setf (%load-seq ledger) seq)))
      ((string= tool "run-tests")
       (%record-test-run ledger interaction))))
  ledger)
```

- [ ] **Step 4: Run tests to verify green** — expect 109 / 0.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/projection.lisp next/src/exploration-ledger.lisp next/src/change-ledger.lisp next/src/verification-ledger.lisp next/tests/projection-test.lisp next/tests/exploration-ledger-test.lisp next/tests/change-ledger-test.lisp next/tests/verification-ledger-test.lisp
git add next/src/projection.lisp next/src/exploration-ledger.lisp next/src/change-ledger.lisp next/src/verification-ledger.lisp next/tests/projection-test.lisp next/tests/exploration-ledger-test.lisp next/tests/change-ledger-test.lisp next/tests/verification-ledger-test.lisp
git commit -m "fix(next): tool-level isError counts as failure across ledgers"
```

---

### Task 2: Oracle protocol

**Files:**
- Create: `next/tests/oracle-test.lisp`
- Create: `next/src/oracle.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/oracle-test.lisp`:

```lisp
;;;; next/tests/oracle-test.lisp
;;;;
;;;; Unit tests for next/src/oracle.lisp: protocol + CONSULT recording
;;;; verdicts as :oracle-result events (spec §7 — oracle consultations
;;;; are observations in the world model).

(defpackage #:cl-harness-next/tests/oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:consult
                #:make-verdict
                #:verdict-pass-p
                #:verdict-reason
                #:verdict-oracle))

(in-package #:cl-harness-next/tests/oracle-test)

(defmacro with-log-path ((path) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(defclass yes-oracle (oracle) ())

(defmethod oracle-name ((oracle yes-oracle)) :yes)

(defmethod evaluate ((oracle yes-oracle) subject)
  (make-verdict :oracle :yes :pass-p t
                :reason (format nil "subject=~A" subject)))

(deftest consult-returns-the-verdict
  (let ((verdict (consult (make-instance 'yes-oracle) 42)))
    (ok (verdict-pass-p verdict))
    (ok (equal "subject=42" (verdict-reason verdict)))
    (ok (eq :yes (verdict-oracle verdict)))))

(deftest consult-records-oracle-result-event
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (consult (make-instance 'yes-oracle) 1 :event-log log)
      (let ((event (first (read-events path))))
        (ok (eq :oracle-result (event-type event)))
        (ok (equal "yes" (gethash "oracle" (event-payload event))))
        (ok (eq t (gethash "pass" (event-payload event))))))))

(deftest consult-without-log-records-nothing
  (ok (verdict-pass-p (consult (make-instance 'yes-oracle) 1))))
```

Create `next/src/oracle.lisp`:

```lisp
;;;; next/src/oracle.lisp
;;;;
;;;; Oracle protocol (spec §7): an oracle is a consultable judge.
;;;; EVALUATE is the pure judgment; CONSULT additionally records the
;;;; verdict as an :oracle-result event, so consultations become
;;;; observations in the world model — the structural fix for
;;;; review-feedback routing problems (spec §7, backlog #3 lineage).

(defpackage #:cl-harness-next/src/oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:export #:oracle
           #:oracle-name
           #:evaluate
           #:consult
           #:verdict
           #:make-verdict
           #:verdict-oracle
           #:verdict-pass-p
           #:verdict-reason))

(in-package #:cl-harness-next/src/oracle)

(defstruct (verdict (:conc-name verdict-))
  oracle pass-p reason)

(defclass oracle ()
  ()
  (:documentation "Abstract base for L2 oracles (spec §7): consultable
judges over verification, invariants, reviews, and progress."))

(defgeneric oracle-name (oracle)
  (:documentation "Keyword identifying ORACLE in events and reports."))

(defgeneric evaluate (oracle subject)
  (:documentation "Judge SUBJECT and return a VERDICT. Pure judgment —
no event recording (that is CONSULT's job)."))

(defun consult (oracle subject &key event-log)
  "Evaluate ORACLE on SUBJECT; when EVENT-LOG is supplied, record the
verdict as an :oracle-result event. Returns the VERDICT."
  (let ((verdict (evaluate oracle subject)))
    (when event-log
      (emit-event event-log :oracle-result
                  (alexandria:plist-hash-table
                   (list "oracle" (string-downcase
                                   (symbol-name (oracle-name oracle)))
                         "pass" (and (verdict-pass-p verdict) t)
                         "reason" (or (verdict-reason verdict) ""))
                   :test #'equal)))
    verdict))
```

Add `"cl-harness-next/tests/oracle-test"` to the tests system.

- [ ] **Step 2: Red** — load failure (missing package). Then implement
order: test file + `.asd` first, source second (as in SP3 Task 1).

- [ ] **Step 3: Green** — expect 112 / 0.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/oracle.lisp next/tests/oracle-test.lisp
git add next/src/oracle.lisp next/tests/oracle-test.lisp cl-harness-next.asd
git commit -m "feat(next): oracle protocol with recorded consultations"
```

---

### Task 3: Invariant oracle

**Files:**
- Create: `next/tests/invariant-oracle-test.lisp`
- Create: `next/src/invariant-oracle.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/invariant-oracle-test.lisp`:

```lisp
;;;; next/tests/invariant-oracle-test.lisp
;;;;
;;;; Unit tests for next/src/invariant-oracle.lisp — the deterministic
;;;; AST gate generalizing legacy validate-test-source (spec §7
;;;; invariant oracle, §12 test-change L1 defense).

(defpackage #:cl-harness-next/tests/invariant-oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/invariant-oracle
                #:invariant-oracle))

(in-package #:cl-harness-next/tests/invariant-oracle-test)

(defparameter *good-test-source*
  "(in-package :foo)

(deftest my-test
  (ok (= 1 1)))")

(deftest clean-single-deftest-passes
  (ok (verdict-pass-p
       (evaluate (make-instance 'invariant-oracle) *good-test-source*))))

(deftest skip-anywhere-fails
  (let ((verdict (evaluate (make-instance 'invariant-oracle)
                           "(deftest t1 (if x (skip \"later\") (ok t)))")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "skip" (verdict-reason verdict)))))

(deftest deftest-count-must-be-one
  (ok (not (verdict-pass-p
            (evaluate (make-instance 'invariant-oracle)
                      "(deftest a (ok t)) (deftest b (ok t))"))))
  (ok (not (verdict-pass-p
            (evaluate (make-instance 'invariant-oracle)
                      "(defun helper () 1)")))))

(deftest unreadable-source-fails
  (let ((verdict (evaluate (make-instance 'invariant-oracle)
                           "(deftest a (ok t)")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "unreadable" (verdict-reason verdict)))))

(deftest read-eval-is-rejected-by-reader
  (ok (not (verdict-pass-p
            (evaluate (make-instance 'invariant-oracle)
                      "(deftest a (ok #.(+ 1 2)))")))))

(deftest invariants-are-configurable
  (let ((oracle (make-instance 'invariant-oracle :invariants '(:no-skip))))
    (ok (verdict-pass-p
         (evaluate oracle "(deftest a (ok t)) (deftest b (ok t))")))))

(deftest package-qualified-deftest-counts
  (ok (verdict-pass-p
       (evaluate (make-instance 'invariant-oracle)
                 "(rove:deftest a (ok t))"))))
```

Create `next/src/invariant-oracle.lisp`:

```lisp
;;;; next/src/invariant-oracle.lisp
;;;;
;;;; Deterministic AST-level invariant oracle (spec §7), generalizing
;;;; the legacy validate-test-source L1 defense (spec §12): exactly one
;;;; deftest, no (skip ...), valid Lisp. Source is read with a hardened
;;;; reader — *READ-EVAL* nil, symbols interned into a throwaway
;;;; scratch package (package-qualified symbols still resolve against
;;;; their named package; an unknown package is a read error and the
;;;; verdict is \"unreadable\").

(defpackage #:cl-harness-next/src/invariant-oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:export #:invariant-oracle
           #:oracle-invariants))

(in-package #:cl-harness-next/src/invariant-oracle)

(defclass invariant-oracle (oracle)
  ((invariants :initarg :invariants
               :initform '(:valid-lisp :no-skip :single-deftest)
               :reader oracle-invariants
               :documentation "Subset of (:valid-lisp :no-skip
:single-deftest) to enforce."))
  (:documentation "Configurable deterministic source-invariant gate."))

(defmethod oracle-name ((oracle invariant-oracle)) :invariant)

(defun %read-forms-safely (source)
  "Read all top-level forms of SOURCE with *READ-EVAL* disabled and a
throwaway scratch package. Returns (values forms error-message)."
  (let ((scratch (make-package (string (gensym "INVARIANT-SCRATCH"))
                               :use '())))
    (unwind-protect
         (handler-case
             (with-standard-io-syntax
               (let ((*read-eval* nil)
                     (*package* scratch)
                     (eof (list nil)))
                 (with-input-from-string (in source)
                   (values (loop for form = (read in nil eof)
                                 until (eq form eof)
                                 collect form)
                           nil))))
           (error (condition)
             (values nil (format nil "~A" condition))))
      (delete-package scratch))))

(defun %symbol-named-p (object name)
  (and (symbolp object) (string= (symbol-name object) name)))

(defun %deftest-form-p (form)
  (and (consp form) (%symbol-named-p (first form) "DEFTEST")))

(defun %contains-skip-p (form)
  "Tree walk: any sub-form whose operator is a symbol named SKIP.
Safe on dotted lists."
  (cond ((not (consp form)) nil)
        ((%symbol-named-p (car form) "SKIP") t)
        (t (loop for rest = form then (cdr rest)
                 while (consp rest)
                 thereis (%contains-skip-p (car rest))))))

(defmethod evaluate ((oracle invariant-oracle) (source string))
  (multiple-value-bind (forms read-error) (%read-forms-safely source)
    (if read-error
        (make-verdict :oracle :invariant :pass-p nil
                      :reason (format nil "unreadable source: ~A"
                                      read-error))
        (let ((violations '()))
          (dolist (invariant (oracle-invariants oracle))
            (ecase invariant
              (:valid-lisp nil)   ; established by the successful read
              (:no-skip
               (when (some #'%contains-skip-p forms)
                 (push "contains (skip ...)" violations)))
              (:single-deftest
               (let ((count (count-if #'%deftest-form-p forms)))
                 (unless (= 1 count)
                   (push (format nil
                                 "expected exactly one deftest, found ~D"
                                 count)
                         violations))))))
          (if violations
              (make-verdict :oracle :invariant :pass-p nil
                            :reason (format nil "~{~A~^; ~}"
                                            (nreverse violations)))
              (make-verdict :oracle :invariant :pass-p t :reason nil))))))
```

Add `"cl-harness-next/tests/invariant-oracle-test"` to the tests system.

- [ ] **Step 2: Red** (missing package) → **Step 3: Green** — expect
119 / 0.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/invariant-oracle.lisp next/tests/invariant-oracle-test.lisp
git add next/src/invariant-oracle.lisp next/tests/invariant-oracle-test.lisp cl-harness-next.asd
git commit -m "feat(next): invariant oracle with hardened source reader"
```

---

### Task 4: Verification oracle

**Files:**
- Create: `next/tests/verification-oracle-test.lisp`
- Create: `next/src/verification-oracle.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/verification-oracle-test.lisp`:

```lisp
;;;; next/tests/verification-oracle-test.lisp
;;;;
;;;; Tests for next/src/verification-oracle.lisp: kill→load→test driven
;;;; THROUGH the L1 environment with a tool-aware scripted transport,
;;;; including the cross-layer coherence check (the produced event
;;;; trail is what SP3 derives clean-verify from).

(defpackage #:cl-harness-next/tests/verification-oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/world-model
                #:build-world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:consult
                #:verdict-pass-p
                #:verdict-reason
                #:verdict-oracle)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle))

(in-package #:cl-harness-next/tests/verification-oracle-test)

(defmacro with-log-path ((path) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(defclass tool-scripted-transport (mcp-transport)
  ((responses :initarg :responses :reader tool-responses
              :documentation "Alist tool-name → result JSON object text.")
   (calls :initform nil :accessor tool-calls)))

(defmethod transport-send-request ((transport tool-scripted-transport)
                                   body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"tools\":[~{{\"name\":\"~A\"}~^,~}]}}"
               id (mapcar #'car (tool-responses transport))))
      ((equal method "tools/call")
       (let* ((tool (gethash "name" (gethash "params" parsed)))
              (entry (assoc tool (tool-responses transport)
                            :test #'string=)))
         (push tool (tool-calls transport))
         (unless entry (error "no canned response for tool ~S" tool))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}"
                 id (cdr entry))))
      (t (error "unexpected method ~S" method)))))

(defparameter *green-responses*
  (list (cons "pool-kill-worker" "{\"content\":[]}")
        (cons "load-system" "{\"content\":[]}")
        (cons "run-tests" "{\"passed\":5,\"failed\":0}")))

(defun %env (responses &key (condition :runtime-native) event-log)
  (make-cl-mcp-environment
   :client (make-mcp-client (make-instance 'tool-scripted-transport
                                           :responses responses))
   :condition condition
   :event-log event-log))

(defun %oracle (&key (mode :clean))
  (make-instance 'verification-oracle
                 :system "s" :test-system "s/tests" :mode mode))

(deftest clean-mode-green-passes
  (let ((verdict (evaluate (%oracle) (%env *green-responses*))))
    (ok (verdict-pass-p verdict))
    (ok (eq :clean-verification (verdict-oracle verdict)))))

(deftest clean-consultation-makes-world-model-clean
  ;; The oracle drives the env, the env records events, SP3 derives
  ;; clean-verify from exactly that sequence — cross-layer coherence.
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (environment (%env *green-responses* :event-log log)))
      (ok (verdict-pass-p (consult (%oracle) environment :event-log log)))
      (let ((world-model (build-world-model path)))
        (ok (clean-verified-p
             (world-model-projection world-model :verification)))))))

(deftest failing-tests-fail-the-verdict
  (let* ((responses (list* (cons "run-tests" "{\"passed\":4,\"failed\":1}")
                           (remove "run-tests" *green-responses*
                                   :key #'car :test #'string=)))
         (verdict (evaluate (%oracle) (%env responses))))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "1/5" (verdict-reason verdict)))))

(deftest iserror-load-fails-the-verdict
  (let* ((responses
           (list* (cons "load-system"
                        (concatenate 'string
                                     "{\"isError\":true,\"content\":"
                                     "[{\"type\":\"text\",\"text\":\"compile error\"}]}"))
                  (remove "load-system" *green-responses*
                          :key #'car :test #'string=)))
         (verdict (evaluate (%oracle) (%env responses))))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "load-system failed" (verdict-reason verdict)))))

(deftest incremental-mode-does-not-kill
  (let* ((transport (make-instance 'tool-scripted-transport
                                   :responses *green-responses*))
         (environment (make-cl-mcp-environment
                       :client (make-mcp-client transport)
                       :condition :runtime-native)))
    (ok (verdict-pass-p (evaluate (%oracle :mode :incremental)
                                  environment)))
    (ok (not (member "pool-kill-worker" (tool-calls transport)
                     :test #'string=)))))

(deftest denied-action-yields-failed-verdict
  (let ((verdict (evaluate (%oracle)
                           (%env *green-responses*
                                 :condition :file-only))))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "verification error" (verdict-reason verdict)))))
```

Create `next/src/verification-oracle.lisp`:

```lisp
;;;; next/src/verification-oracle.lisp
;;;;
;;;; Deterministic verification oracle (spec §7): runs load/test —
;;;; optionally from a fresh worker (:clean) — THROUGH the L1
;;;; environment, so the kill→load→test event trail it produces is the
;;;; same one the SP3 verification-ledger independently derives
;;;; clean-verify from. Clean verification is the only final truth all
;;;; dial levels must pass (spec §7).

(defpackage #:cl-harness-next/src/verification-oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:import-from #:cl-harness-next/src/environment
                #:perform-action)
  (:export #:verification-oracle
           #:oracle-system
           #:oracle-test-system
           #:oracle-mode))

(in-package #:cl-harness-next/src/verification-oracle)

(defclass verification-oracle (oracle)
  ((system :initarg :system :reader oracle-system)
   (test-system :initarg :test-system :reader oracle-test-system)
   (mode :initarg :mode :initform :incremental :reader oracle-mode
         :documentation ":incremental (load+test) or :clean
(kill+load+test). The subject of EVALUATE is an L1 environment whose
action space must permit these tools (:runtime-native)."))
  (:documentation "Load/test verification through the L1 environment."))

(defmethod oracle-name ((oracle verification-oracle))
  (if (eq :clean (oracle-mode oracle))
      :clean-verification
      :verification))

(defun %args (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %result-error-p (result)
  (and (hash-table-p result)
       (multiple-value-bind (value present-p) (gethash "isError" result)
         (and present-p value t))))

(defun %result-int (result key)
  (when (hash-table-p result)
    (multiple-value-bind (value present-p) (gethash key result)
      (when (and present-p (integerp value)) value))))

(defun %result-text (result)
  (when (hash-table-p result)
    (multiple-value-bind (content present-p) (gethash "content" result)
      (when (and present-p (consp content))
        (let ((first-element (first content)))
          (when (hash-table-p first-element)
            (gethash "text" first-element)))))))

(defmethod evaluate ((oracle verification-oracle) environment)
  (handler-case
      (progn
        (when (eq :clean (oracle-mode oracle))
          (perform-action environment "pool-kill-worker" (%args)))
        (let ((load-result
                (perform-action environment "load-system"
                                (%args "system" (oracle-system oracle)))))
          (when (%result-error-p load-result)
            (return-from evaluate
              (make-verdict :oracle (oracle-name oracle) :pass-p nil
                            :reason (format nil "load-system failed: ~A"
                                            (or (%result-text load-result)
                                                "(no detail)"))))))
        (let* ((test-result
                 (perform-action environment "run-tests"
                                 (%args "system"
                                        (oracle-test-system oracle))))
               (failed (%result-int test-result "failed"))
               (passed (%result-int test-result "passed")))
          (cond
            ((%result-error-p test-result)
             (make-verdict :oracle (oracle-name oracle) :pass-p nil
                           :reason (format nil "run-tests failed: ~A"
                                           (or (%result-text test-result)
                                               "(no detail)"))))
            ((and failed (plusp failed))
             (make-verdict :oracle (oracle-name oracle) :pass-p nil
                           :reason (format nil "~A/~A tests failed"
                                           failed
                                           (+ failed (or passed 0)))))
            ((eql failed 0)
             (make-verdict :oracle (oracle-name oracle) :pass-p t
                           :reason (format nil "~A tests passed~@[ (clean image)~]"
                                           (or passed "?")
                                           (eq :clean (oracle-mode oracle)))))
            (t
             (make-verdict :oracle (oracle-name oracle) :pass-p nil
                           :reason "run-tests returned no structured counts")))))
    (error (condition)
      (make-verdict :oracle (oracle-name oracle) :pass-p nil
                    :reason (format nil "verification error: ~A"
                                    condition)))))
```

Add `"cl-harness-next/tests/verification-oracle-test"` to the tests
system.

- [ ] **Step 2: Red** → **Step 3: Green** — expect 125 / 0.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/verification-oracle.lisp next/tests/verification-oracle-test.lisp
git add next/src/verification-oracle.lisp next/tests/verification-oracle-test.lisp cl-harness-next.asd
git commit -m "feat(next): verification oracle driving the L1 environment"
```

---

### Task 5: Review oracle (injected judge + pack profiles)

**Files:**
- Create: `next/tests/review-oracle-test.lisp`
- Create: `next/src/review-oracle.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/review-oracle-test.lisp`:

```lisp
;;;; next/tests/review-oracle-test.lisp
;;;;
;;;; Tests for next/src/review-oracle.lisp: stage-aware strictness as
;;;; policy-pack data (PRD §19 soft/strict/strictest), injected judge
;;;; (LLM provider arrives in SP5), fail-closed parsing.

(defpackage #:cl-harness-next/tests/review-oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason
                #:verdict-oracle)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-oracle-profile)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle))

(in-package #:cl-harness-next/tests/review-oracle-test)

(defun %canned-judge (response &optional capture)
  (lambda (prompt)
    (when capture (setf (car capture) prompt))
    response))

(deftest approve-passes
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :review-plan
                                            :strictness :soft)
                                 :judge-fn (%canned-judge
                                            "APPROVE solid plan"))
                  "the plan")))
    (ok (verdict-pass-p verdict))
    (ok (eq :review-plan (verdict-oracle verdict)))))

(deftest reject-carries-feedback
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :review-tests
                                            :strictness :strict)
                                 :judge-fn (%canned-judge
                                            "REJECT: missing edge case"))
                  "the tests")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "missing edge case" (verdict-reason verdict)))))

(deftest unparseable-fails-closed
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :r :strictness :soft)
                                 :judge-fn (%canned-judge "well, maybe"))
                  "x")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "unparseable" (verdict-reason verdict)))))

(deftest judge-errors-fail-closed
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :r)
                                 :judge-fn (lambda (prompt)
                                             (declare (ignore prompt))
                                             (error "api down")))
                  "x")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "judge error" (verdict-reason verdict)))))

(deftest prompt-carries-strictness-instructions-and-subject
  (let ((capture (list nil)))
    (evaluate (make-instance 'review-oracle
                             :profile '(:id :review-test-change
                                        :strictness :strictest
                                        :instructions "Additive only.")
                             :judge-fn (%canned-judge "APPROVE" capture))
              "the diff")
    (let ((prompt (car capture)))
      (ok (search "strictest" prompt))
      (ok (search "Additive only." prompt))
      (ok (search "the diff" prompt)))))

(deftest profile-from-policy-pack
  (uiop:with-temporary-file (:pathname path :type "sexp")
    (with-open-file (out path :direction :output :if-exists :supersede
                              :external-format :utf-8)
      (write-string "(:name \"p\" :version \"0.1.0\"
                      :oracle-profiles ((:id :review-tests
                                         :strictness :strict
                                         :instructions \"No skip.\")))"
                    out))
    (let* ((pack (load-policy-pack path))
           (oracle (make-instance 'review-oracle
                                  :profile (pack-oracle-profile
                                            pack :review-tests)
                                  :judge-fn (%canned-judge "REJECT: no"))))
      (ok (eq :review-tests (verdict-oracle (evaluate oracle "tests")))))))
```

Create `next/src/review-oracle.lisp`:

```lisp
;;;; next/src/review-oracle.lisp
;;;;
;;;; LLM review oracle (spec §7): stage-aware strictness lives in a
;;;; policy-pack :oracle-profiles entry (原則4 — the PRD §19
;;;; soft/strict/strictest table as data, mutable by L5). The judge is
;;;; an injected function (prompt-string → response-string); the LLM
;;;; provider arrives with the kernel (SP5). Parsing fails closed:
;;;; an unparseable or erroring judge is a rejection.

(defpackage #:cl-harness-next/src/review-oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:export #:review-oracle
           #:oracle-profile
           #:oracle-judge-fn))

(in-package #:cl-harness-next/src/review-oracle)

(defclass review-oracle (oracle)
  ((profile :initarg :profile :initform nil :reader oracle-profile
            :documentation "Plist, typically a policy-pack
:oracle-profiles entry: (:id keyword :strictness :soft|:strict|:strictest
:instructions string).")
   (judge-fn :initarg :judge-fn :reader oracle-judge-fn
             :documentation "Function prompt-string → response-string."))
  (:documentation "Profile-driven LLM judge with injected transport."))

(defmethod oracle-name ((oracle review-oracle))
  (or (getf (oracle-profile oracle) :id) :review))

(defun %strictness-preamble (strictness)
  (ecase (or strictness :soft)
    (:soft
     "You are a pragmatic reviewer. Approve unless something is clearly wrong.")
    (:strict
     "You are a strict reviewer. Approve only when every stated requirement is met.")
    (:strictest
     "You are the strictest reviewer. Reject on any doubt; the subject guards a source of truth.")))

(defun %review-prompt (oracle subject)
  (let ((profile (oracle-profile oracle)))
    (format nil
            "~A~@[~%~%Additional instructions:~%~A~]~%~%~
Review the following. Answer on the first line with APPROVE or ~
REJECT: <feedback>.~%~%---~%~A"
            (%strictness-preamble (getf profile :strictness))
            (getf profile :instructions)
            subject)))

(defun %parse-judgement (response)
  "Return (values pass-p feedback). The earlier of APPROVE/REJECT
(case-insensitive) wins; anything else fails closed."
  (let* ((text (or response ""))
         (upcased (string-upcase text))
         (approve (search "APPROVE" upcased))
         (reject (search "REJECT" upcased)))
    (cond
      ((and approve (or (null reject) (< approve reject)))
       (values t text))
      (reject (values nil text))
      (t (values nil (format nil "unparseable review response: ~S"
                             text))))))

(defmethod evaluate ((oracle review-oracle) (subject string))
  (handler-case
      (multiple-value-bind (pass-p feedback)
          (%parse-judgement (funcall (oracle-judge-fn oracle)
                                     (%review-prompt oracle subject)))
        (make-verdict :oracle (oracle-name oracle)
                      :pass-p pass-p :reason feedback))
    (error (condition)
      (make-verdict :oracle (oracle-name oracle) :pass-p nil
                    :reason (format nil "judge error: ~A" condition)))))
```

Add `"cl-harness-next/tests/review-oracle-test"` to the tests system.

- [ ] **Step 2: Red** → **Step 3: Green** — expect 131 / 0.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/review-oracle.lisp next/tests/review-oracle-test.lisp
git add next/src/review-oracle.lisp next/tests/review-oracle-test.lisp cl-harness-next.asd
git commit -m "feat(next): review oracle with pack profiles and injected judge"
```

---

### Task 6: Governor (progress projection + oracle)

**Files:**
- Create: `next/tests/governor-test.lisp`
- Create: `next/src/governor.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/governor-test.lisp`:

```lisp
;;;; next/tests/governor-test.lisp
;;;;
;;;; Tests for next/src/governor.lisp: progress counters folded from
;;;; interactions (legacy budgets generalized, spec §7 progress
;;;; oracle), threshold breaches, and (Task 7) condition/restart
;;;; interventions (spec §11).

(defpackage #:cl-harness-next/tests/governor-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-action-count
                #:governor-patch-count
                #:governor-consecutive-failed-patches
                #:governor-stalled-verify-cycles))

(in-package #:cl-harness-next/tests/governor-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %interaction (tool &key result error (seq 2))
  (make-instance 'interaction
                 :tool tool
                 :result result
                 :error-message error
                 :action-seq (1- seq)
                 :observation-seq seq))

(deftest counters-accumulate
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "lisp-read-file" :seq 1))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 2))
    (ok (= 2 (governor-action-count governor)))
    (ok (= 1 (governor-patch-count governor)))))

(deftest consecutive-failed-patches-track-and-reset
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 1
                                              :result (%hash "isError" t)))
    (apply-interaction governor (%interaction "lisp-patch-form" :seq 2
                                              :error "transport"))
    (ok (= 2 (governor-consecutive-failed-patches governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 3))
    (ok (zerop (governor-consecutive-failed-patches governor)))))

(deftest stalled-verify-counts-only-without-patch
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "run-tests" :seq 1
                                              :result (%hash "failed" 1)))
    (apply-interaction governor (%interaction "run-tests" :seq 2
                                              :result (%hash "failed" 1)))
    (ok (= 2 (governor-stalled-verify-cycles governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 3))
    (apply-interaction governor (%interaction "run-tests" :seq 4
                                              :result (%hash "failed" 1)))
    (ok (zerop (governor-stalled-verify-cycles governor)))))

(deftest green-run-resets-stall
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "run-tests" :seq 1
                                              :result (%hash "failed" 1)))
    (apply-interaction governor (%interaction "run-tests" :seq 2
                                              :result (%hash "failed" 0)))
    (ok (zerop (governor-stalled-verify-cycles governor)))))

(deftest evaluate-reports-breaches
  (let ((governor (make-instance 'governor
                                 :max-actions 2
                                 :max-consecutive-failed-patches 2)))
    (ok (verdict-pass-p (evaluate governor nil)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 1
                                              :result (%hash "isError" t)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 2
                                              :result (%hash "isError" t)))
    (let ((verdict (evaluate governor nil)))
      (ok (not (verdict-pass-p verdict)))
      (ok (search "actions" (verdict-reason verdict)))
      (ok (search "consecutive failed patches" (verdict-reason verdict))))))
```

Create `next/src/governor.lisp`:

```lisp
;;;; next/src/governor.lisp
;;;;
;;;; Governor: the progress oracle (spec §7) and its condition/restart
;;;; interventions (spec §11). It is BOTH a projection (counters are
;;;; folded from interactions, so a rebuilt world model restores them)
;;;; AND an oracle (EVALUATE reports threshold breaches). Thresholds
;;;; generalize the legacy budgets (max-patches,
;;;; max-consecutive-failed-patches, max-stalled-verify-cycles —
;;;; spec §12); wire pack budgets in via the initargs
;;;; (e.g. :max-actions (pack-budget pack :max-actions)).

(defpackage #:cl-harness-next/src/governor
  (:use #:cl)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-interaction
                #:interaction-tool
                #:interaction-succeeded-p
                #:interaction-result
                #:+patch-tool-names+)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:export #:governor
           #:governor-action-count
           #:governor-patch-count
           #:governor-consecutive-failed-patches
           #:governor-stalled-verify-cycles
           #:governor-breaches
           #:check-governor
           #:governor-intervention
           #:progress-stalled
           #:budget-exhausted
           #:oracle-conflict
           #:intervention-governor
           #:intervention-reason))

(in-package #:cl-harness-next/src/governor)

(defclass governor (projection oracle)
  ((max-actions :initarg :max-actions :initform nil
                :reader governor-max-actions)
   (max-patches :initarg :max-patches :initform nil
                :reader governor-max-patches)
   (max-consecutive-failed-patches
    :initarg :max-consecutive-failed-patches :initform 3
    :reader governor-max-consecutive-failed-patches)
   (max-stalled-verify-cycles
    :initarg :max-stalled-verify-cycles :initform 3
    :reader governor-max-stalled-verify-cycles)
   (action-count :initform 0 :accessor governor-action-count)
   (patch-count :initform 0 :accessor governor-patch-count)
   (consecutive-failed-patches
    :initform 0 :accessor governor-consecutive-failed-patches)
   (stalled-verify-cycles
    :initform 0 :accessor governor-stalled-verify-cycles
    :documentation "Failing run-tests with no patch attempt since the
previous run-tests. The initial observe-phase red verify counts as the
first cycle; the default threshold (3) accounts for that.")
   (patched-since-last-verify
    :initform nil :accessor %patched-since-last-verify))
  (:documentation "Progress oracle + budget governor (spec §7/§11)."))

(defmethod oracle-name ((governor governor)) :governor)

(defun %result-int (result key)
  (when (hash-table-p result)
    (multiple-value-bind (value present-p) (gethash key result)
      (when (and present-p (integerp value)) value))))

(defmethod apply-interaction ((governor governor) interaction)
  (incf (governor-action-count governor))
  (let ((tool (interaction-tool interaction)))
    (cond
      ((member tool +patch-tool-names+ :test #'string=)
       (incf (governor-patch-count governor))
       (setf (%patched-since-last-verify governor) t)
       (if (interaction-succeeded-p interaction)
           (setf (governor-consecutive-failed-patches governor) 0)
           (incf (governor-consecutive-failed-patches governor))))
      ((string= tool "run-tests")
       (let ((failed (%result-int (interaction-result interaction)
                                  "failed")))
         (cond
           ((and failed (plusp failed))
            (if (%patched-since-last-verify governor)
                (setf (governor-stalled-verify-cycles governor) 0)
                (incf (governor-stalled-verify-cycles governor))))
           ((eql failed 0)
            (setf (governor-stalled-verify-cycles governor) 0))))
       (setf (%patched-since-last-verify governor) nil))))
  governor)

(defun governor-breaches (governor)
  "List of (category . description) threshold breaches, or NIL.
Categories: :budget (resource counts) and :progress (stall signals)."
  (let ((breaches '()))
    (flet ((breach (category limit value label)
             (when (and limit (>= value limit))
               (push (cons category
                           (format nil "~A: ~A >= ~A" label value limit))
                     breaches))))
      (breach :budget (governor-max-actions governor)
              (governor-action-count governor) "actions")
      (breach :budget (governor-max-patches governor)
              (governor-patch-count governor) "patches")
      (breach :progress (governor-max-consecutive-failed-patches governor)
              (governor-consecutive-failed-patches governor)
              "consecutive failed patches")
      (breach :progress (governor-max-stalled-verify-cycles governor)
              (governor-stalled-verify-cycles governor)
              "stalled verify cycles"))
    (nreverse breaches)))

(defmethod evaluate ((governor governor) subject)
  (declare (ignore subject))
  (let ((breaches (governor-breaches governor)))
    (if breaches
        (make-verdict :oracle :governor :pass-p nil
                      :reason (format nil "~{~A~^; ~}"
                                      (mapcar #'cdr breaches)))
        (make-verdict :oracle :governor :pass-p t :reason nil))))
```

Add `"cl-harness-next/tests/governor-test"` to the tests system.

- [ ] **Step 2: Red** → **Step 3: Green** — expect 136 / 0.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/governor.lisp next/tests/governor-test.lisp
git add next/src/governor.lisp next/tests/governor-test.lisp cl-harness-next.asd
git commit -m "feat(next): governor progress oracle with budget thresholds"
```

---

### Task 7: Governor interventions (conditions + restarts)

**Files:**
- Modify: `next/src/governor.lisp`
- Modify: `next/tests/governor-test.lisp`

- [ ] **Step 1: Write the failing tests**

Extend the test package's governor `:import-from` with
`#:check-governor #:progress-stalled #:budget-exhausted`
`#:oracle-conflict #:governor-intervention #:intervention-reason`,
then append:

```lisp
(deftest no-breach-continues
  (ok (eq :continue (check-governor (make-instance 'governor)))))

(deftest unhandled-signal-continues
  (let ((governor (make-instance 'governor :max-actions 1)))
    (apply-interaction governor (%interaction "lisp-read-file" :seq 1))
    (ok (eq :continue (check-governor governor)))))

(deftest handler-chooses-replan-on-stall
  (let ((governor (make-instance 'governor :max-stalled-verify-cycles 1)))
    (apply-interaction governor (%interaction "run-tests" :seq 1
                                              :result (%hash "failed" 1)))
    (ok (eq :replan
            (handler-bind ((progress-stalled
                             (lambda (condition)
                               (declare (ignore condition))
                               (invoke-restart :replan))))
              (check-governor governor))))))

(deftest budget-breach-signals-budget-exhausted
  (let ((governor (make-instance 'governor :max-actions 1))
        (caught nil))
    (apply-interaction governor (%interaction "repl-eval" :seq 1))
    (ok (eq :abort-run
            (handler-bind ((budget-exhausted
                             (lambda (condition)
                               (setf caught (intervention-reason condition))
                               (invoke-restart :abort-run))))
              (check-governor governor))))
    (ok (search "actions" caught))))

(deftest intervention-conditions-print-bare
  (dolist (type '(governor-intervention progress-stalled
                  budget-exhausted oracle-conflict))
    (ok (stringp (princ-to-string (make-condition type))))))
```

- [ ] **Step 2: Red** — `check-governor` undefined; 136 existing pass.

- [ ] **Step 3: Implement**

Append to `next/src/governor.lisp`:

```lisp
(define-condition governor-intervention (condition)
  ((governor :initarg :governor :initform nil
             :reader intervention-governor)
   (reason :initarg :reason :initform "(no reason)"
           :reader intervention-reason))
  (:report (lambda (condition stream)
             (format stream "Governor intervention: ~A"
                     (intervention-reason condition))))
  (:documentation "Base for governor interventions (spec §11). Plain
CONDITION, not ERROR — unhandled signals fall through and the run
continues; handlers choose an intervention by invoking one of the
keyword-named restarts (:demote-dial :replan :park-mission :ask-human
:abort-run)."))

(define-condition progress-stalled (governor-intervention)
  ()
  (:documentation "Stall thresholds breached (oscillating patches or
verify-without-progress)."))

(define-condition budget-exhausted (governor-intervention)
  ()
  (:documentation "Resource budget thresholds breached (actions,
patches)."))

(define-condition oracle-conflict (governor-intervention)
  ()
  (:documentation "Consulted oracles disagree. Defined as part of the
spec §11 intervention vocabulary; detection wiring arrives with the
kernel (SP5), which is the first place multiple verdicts meet."))

(defun check-governor (governor)
  "Check thresholds and signal interventions (spec §11). Restart names
are KEYWORDS so cross-package handlers can simply
(invoke-restart :replan) — the project's documented restart-name
lesson. Returns the chosen intervention keyword, or :continue when
nothing breached or no handler chose a restart."
  (dolist (breach (governor-breaches governor) :continue)
    (destructuring-bind (category . reason) breach
      (let ((outcome
              (restart-case
                  (progn (signal (ecase category
                                   (:budget 'budget-exhausted)
                                   (:progress 'progress-stalled))
                                 :governor governor :reason reason)
                         :continue)
                (:demote-dial () :demote-dial)
                (:replan () :replan)
                (:park-mission () :park-mission)
                (:ask-human () :ask-human)
                (:abort-run () :abort-run))))
        (unless (eq :continue outcome)
          (return-from check-governor outcome))))))
```

- [ ] **Step 4: Green** — expect 141 / 0.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/governor.lisp next/tests/governor-test.lisp
git add next/src/governor.lisp next/tests/governor-test.lisp
git commit -m "feat(next): governor interventions via conditions and keyword restarts"
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
(defclass %sp4-tool-transport (cl-harness-next:mcp-transport)
  ()
  (:documentation "Tool-aware canned transport for the SP4 acceptance
test (facade symbols only)."))

(defmethod cl-harness-next:transport-send-request
    ((transport %sp4-tool-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id
               (concatenate 'string
                            "\"result\":{\"tools\":["
                            "{\"name\":\"pool-kill-worker\"},"
                            "{\"name\":\"load-system\"},"
                            "{\"name\":\"run-tests\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (if (equal tool "run-tests")
                     "{\"passed\":3,\"failed\":0}"
                     "{\"content\":[]}"))))
      (t (error "unexpected method ~S" method)))))

(deftest sp4-oracles-acceptance
  ;; SP4 acceptance: clean verification through the environment, the
  ;; consultation on the record, SP3 agreeing on cleanliness, the
  ;; invariant gate rejecting a skip, and a governor intervention
  ;; round-trip — all through the facade (spec §7/§11).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (cl-harness-next:open-event-log log-path))
           (environment (cl-harness-next:make-cl-mcp-environment
                         :client (cl-harness-next:make-mcp-client
                                  (make-instance '%sp4-tool-transport))
                         :condition :runtime-native
                         :event-log log))
           (oracle (make-instance 'cl-harness-next:verification-oracle
                                  :system "s" :test-system "s/tests"
                                  :mode :clean)))
      (ok (cl-harness-next:verdict-pass-p
           (cl-harness-next:consult oracle environment :event-log log)))
      (let ((world-model (cl-harness-next:build-world-model log-path)))
        (ok (cl-harness-next:clean-verified-p
             (cl-harness-next:world-model-projection world-model
                                                     :verification))))
      (ok (find :oracle-result
                (cl-harness-next:read-events log-path)
                :key #'cl-harness-next:event-type))
      (ok (not (cl-harness-next:verdict-pass-p
                (cl-harness-next:evaluate
                 (make-instance 'cl-harness-next:invariant-oracle)
                 "(deftest a (skip \"later\"))"))))
      (let ((governor (make-instance 'cl-harness-next:governor
                                     :max-actions 2)))
        (cl-harness-next:build-world-model
         log-path
         :world-model (cl-harness-next:make-world-model
                       :projections (list :governor governor)))
        (ok (eq :ask-human
                (handler-bind ((cl-harness-next:budget-exhausted
                                 (lambda (condition)
                                   (declare (ignore condition))
                                   (invoke-restart :ask-human))))
                  (cl-harness-next:check-governor governor))))))))
```

- [ ] **Step 2: Red** — load failure (`cl-harness-next:verification-oracle`
etc. not exported).

- [ ] **Step 3: Extend the facade**

In `next/src/main.lisp`'s defpackage (lisp-edit-form replace, preserving
all existing clauses):

Extend the existing projection... there is no projection clause yet —
add these `:import-from` clauses after the context-compiler one:

```lisp
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:result-error-p
                #:interaction-succeeded-p)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:consult
                #:verdict
                #:make-verdict
                #:verdict-oracle
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/invariant-oracle
                #:invariant-oracle
                #:oracle-invariants)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle
                #:oracle-system
                #:oracle-test-system
                #:oracle-mode)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle
                #:oracle-profile
                #:oracle-judge-fn)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-action-count
                #:governor-patch-count
                #:governor-consecutive-failed-patches
                #:governor-stalled-verify-cycles
                #:governor-breaches
                #:check-governor
                #:governor-intervention
                #:progress-stalled
                #:budget-exhausted
                #:oracle-conflict
                #:intervention-governor
                #:intervention-reason)
```

Add to the `:export` list:

```lisp
           ;; projection protocol (SP4 additions)
           #:projection
           #:apply-event
           #:apply-interaction
           #:result-error-p
           #:interaction-succeeded-p
           ;; oracles
           #:oracle
           #:oracle-name
           #:evaluate
           #:consult
           #:verdict
           #:make-verdict
           #:verdict-oracle
           #:verdict-pass-p
           #:verdict-reason
           #:invariant-oracle
           #:oracle-invariants
           #:verification-oracle
           #:oracle-system
           #:oracle-test-system
           #:oracle-mode
           #:review-oracle
           #:oracle-profile
           #:oracle-judge-fn
           ;; governor
           #:governor
           #:governor-action-count
           #:governor-patch-count
           #:governor-consecutive-failed-patches
           #:governor-stalled-verify-cycles
           #:governor-breaches
           #:check-governor
           #:governor-intervention
           #:progress-stalled
           #:budget-exhausted
           #:oracle-conflict
           #:intervention-governor
           #:intervention-reason
```

- [ ] **Step 4: Green** — expect 142 / 0.

- [ ] **Step 5: Full force-compile** — repl-eval
`(asdf:compile-system :cl-harness-next :force t)`; no warnings from
next/ sources. Column check over all next/ files: expect no output.

- [ ] **Step 6: Document** — in `README.md`'s next/ subsection, change
the SP1–SP3 sentence's ending from "...and the token-budgeted context
compiler. It does not affect the `cl-harness` CLI." to:

```markdown
...and the token-budgeted context compiler; SP4 adds the L2 oracles
(verification through the environment, AST invariants, pack-profiled
LLM review with injected judge) and the governor with
condition/restart interventions. It does not affect the `cl-harness`
CLI.
```

- [ ] **Step 7: Lint everything and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP4 oracles/governor acceptance test"
```

---

## Verification checklist (whole sub-project)

- Clean image: `pool-kill-worker` → load-asd → `load-system
  cl-harness-next` (no warnings from next/ sources) → `run-tests
  cl-harness-next/tests` 142/0.
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (later sub-projects — do NOT build now)

- LLM provider for the review oracle's judge-fn (SP5 kernel).
- Oracle-conflict DETECTION (condition type ships now; the kernel is
  the first place multiple verdicts meet, SP5).
- Advisory-vs-blocking oracle wiring per dial (SP5/SP6 control
  policies; SP4 oracles are mechanism, not policy).
- Governor wall-clock / token budgets (need the provider's usage
  accounting, SP5).
- Review-oracle structured (JSON) verdicts and per-profile parse
  stances — revisit with real LLM traffic (SP5/L5).
- Wiring pack `:budgets` into governor construction sugar (one-liner
  for the kernel; the initargs exist).
- Review-verdict parsing is substring-based and fails open on negated
  approvals ("cannot APPROVE"); revisit with structured verdicts
  (final review Minor #2, SP5).
- "judge error" conflates profile config errors with transport errors;
  invariant-oracle conversely errors loudly on unknown invariants —
  unify the config-error stance when the kernel consumes both (SP5).
- Failing consults serialize "pass": null (yason NIL); normalize to
  false for the L5 transcript miner.
