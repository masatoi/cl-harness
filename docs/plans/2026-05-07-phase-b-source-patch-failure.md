# Phase B: source-fact / patch-record / failure-ledger Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add three structured ledgers to `develop-state` — `source-fact`s (which file/form was read, when, with what mtime), `patch-record`s (which file/form was modified, by which tool, with what diff summary, with what verify outcome), and a `failure-ledger` (active vs resolved test/load failures, linked back to the patches that introduced or fixed them) — so later phases can derive context views, staleness signals, and structured reports from these instead of from raw conversation history.

**Architecture:** Three new files (`src/source-fact.lisp`, `src/patch-record.lisp`, `src/failure-ledger.lisp`) each define one CLOS class plus pure helper functions (constructor, mutators, query). `src/state.lisp` gains three new slots (`source-facts`, `patch-records`, `failure-ledger`) following Phase A's reverse-on-read pattern for the list-shaped slots. Two existing call sites are instrumented: `src/agent.lisp` records source-facts at the cl-mcp file-read tool path and patch-records at the existing `:patch` JSONL emission point; `src/verify.lisp` (or, more accurately, the orchestrator's verify-result consumer) extracts `failed_tests` from the MCP `run-tests` response into `failure-record` instances. Phase B *records* these facts; Phase C is what *consumes* them in context-view generation. No public API breaks; `develop-result` gains three optional accessor methods that read through to state.

**Tech stack:** Common Lisp (SBCL), ASDF `:package-inferred-system`, rove tests, alexandria, local-time (already a dependency — used for timestamps). Project conventions in `CLAUDE.md` apply: 2-space indent, ≤100 columns, lower-case lisp-case, docstrings on public symbols, no `:local-nicknames`, cl-mcp tools for Lisp source modifications.

**Out of scope (deferred):**
- `runtime-vocabulary` (Phase B's fourth originally-planned concern — the structured-packages/exports/classes ledger). Gets its own focused plan because it requires design decisions about which symbol kinds to materialise and a `repl-eval`-driven introspection path that doesn't exist anywhere in cl-harness today.
- Context-view generation that *consumes* the new ledgers (Phase C).
- Tool-result compression / REPL-transcript finding-ization (Phase D).
- Staleness invalidation (e.g. patching a file invalidates source-facts for it; Phase E).
- Structured reporting that re-derives the final report from `develop-state` (Phase E).
- Modifying the JSONL transcript event shape. The existing `:patch` event keeps its current four fields. New events (`:source-read`, `:failure-recorded`) are additive and gated so legacy log readers keep working.

**Acceptance criteria:**
1. `src/source-fact.lisp` exports `source-fact`, `make-source-fact`, accessors, validation. Tests in `tests/source-fact-test.lisp`.
2. `src/patch-record.lisp` exports `patch-record`, `make-patch-record`, accessors, the `:pending`/`:passed`/`:failed` transition helper, validation. Tests in `tests/patch-record-test.lisp`.
3. `src/failure-ledger.lisp` exports `failure-record`, `failure-ledger`, `make-failure-record`, `make-failure-ledger`, helpers `record-failure`, `mark-resolved-by`, `failure-ledger-active`, `failure-ledger-resolved`, plus a parser `parse-failure-records-from-test-result` that turns the MCP `run-tests` `failed_tests` array into `failure-record`s. Tests in `tests/failure-ledger-test.lisp`.
4. `src/state.lisp` gains three slots: `source-facts`, `patch-records`, `failure-ledger`. Three new public defun readers (`develop-state-source-facts`, `develop-state-patch-records`, `develop-state-failure-ledger`) and three recorder helpers (`develop-state-record-source-fact`, `develop-state-record-patch-record`, `develop-state-record-failure`). Internal slot accessors `%source-facts` / `%patch-records` follow Phase A's reverse-on-read pattern.
5. `src/agent.lisp` instrumentation: at the existing `:patch` JSONL event emission, also call `develop-state-record-patch-record` when an `agent-state` carries a back-reference to a `develop-state`. At the file-read MCP tool dispatch (`lisp-read-file`, `fs-read-file`), record a `source-fact` with the same conditional. The back-reference is added as a new optional slot on `agent-state` (see Task 7).
6. `src/orchestrator.lisp` instrumentation: after each `verify-result` returned by `execute-plan`, call `develop-state-record-failure` for each entry in the result's `failed_tests`. When a subsequent verify shows the failure no longer present, mark the prior `failure-record` resolved by the most recent patch-record on the same file (or by `nil` if no patch landed in that file).
7. `cl-harness.asd` registers the three new test systems in `cl-harness/tests` `:depends-on`.
8. Full `cl-harness/tests` rove suite passes — same pre-Phase-B pass count plus the new tests; zero behavioral regression in `orchestrator-test`, `planner-test`, `develop-bench-test`, or `agent-test`.
9. `mallet src/source-fact.lisp src/patch-record.lisp src/failure-ledger.lisp src/state.lisp src/agent.lisp src/orchestrator.lisp tests/source-fact-test.lisp tests/patch-record-test.lisp tests/failure-ledger-test.lisp` reports no new warnings on Phase B files.
10. `(asdf:compile-system :cl-harness :force t)` is clean.
11. `docs/context-management.md` §14 (Implementation Status) is updated: Phases B's 3-of-4 concerns mark `landed`; runtime-vocabulary stays `not started` with a forward pointer to its future plan.

**Risks & mitigations:**

- **R1: `agent-state` and `develop-state` are currently independent objects.** `develop` constructs both but they don't reference each other. Phase B needs the agent loop to record into the develop-state's ledgers without breaking `run-agent`'s standalone invariants (it has to keep working when called by `cl-harness:fix` outside any develop run). → Add an optional slot `develop-state` to `agent-state` (default `nil`). Recorder calls become `(when (agent-state-develop-state s) (develop-state-record-... ...))`. Standalone `run-agent` callers see no behavior change.

- **R2: clean-verify is run on a fresh worker, so verify-result.test-result's hash-table layout is identical to incremental verify but the timing semantics differ.** The current code uses both `verify-task` (incremental) and `clean-verify-task` (fresh worker). → Failure-ledger records both, distinguished by a slot `verify-source` (`:incremental` / `:clean`). Active failures from incremental verifies are demoted (not deleted) when a subsequent clean verify shows the suite green; active failures from a clean verify are the authoritative truth.

- **R3: rove's `failed_tests` array shape is non-trivial.** The Phase A survey showed each entry is a hash-table with keys `test_name`, `description`, `form`, `values`, `reason`, `source` (the last is itself a `{file, line}` hash-table). Yason's parsing of nested objects depends on the parser config in cl-mcp. → The parser `parse-failure-records-from-test-result` defends against missing keys (treats absent values as `nil`); tests cover the shape we actually receive (use a fixture captured from a real run).

- **R4: `develop-state-record-source-fact` could explode in size during long agent loops.** A 20-turn run could touch dozens of files. → No deduplication in Phase B; the `source-facts` list grows monotonically and the public reader returns oldest-first. Phase E's staleness work decides on dedup/eviction policy. Phase B's plan-level test confirms a 200-element list works without performance issues; that's the only bound we commit to here.

- **R5: linking `failure-record.resolved-by-patch` requires a temporal join.** When a verify shows previously-active failures absent, we attribute resolution to "the most recent patch-record on the same file". → If no patch-record matches (e.g. the failure was on a config file we didn't patch, but a code change elsewhere fixed it), set `resolved-by-patch` to `nil`. Don't try to be clever in Phase B; Phase E can refine.

- **R6: backwards compatibility with `develop-result`'s slot set.** `develop-result` currently has `status / final-plan / step-results / replan-count / limit-hit / integration-issues`. Phase B doesn't add new slots there — instead it adds three accessor methods (`develop-result-source-facts`, `develop-result-patch-records`, `develop-result-failure-ledger`) that read through to a back-reference on the `develop-state`. The back-ref slot on `develop-result` is initform `nil` and the readers gracefully return `nil` when missing. Existing callers see no change.

**Working agreement:**
- Use cl-mcp tools (`lisp-edit-form`, `lisp-patch-form`, `lisp-read-file`, `repl-eval`, `run-tests`) per `prompts/repl-driven-development.md`. Generic shell `grep`/`sed`/`cat` against Lisp source is forbidden.
- First action of every implementation session: cl-mcp `fs-set-project-root` on the repo root.
- Commit after each green TDD cycle. Use feature branch `phase-b-ledgers` (do not amend; new commits each task).
- Phase A's lessons that apply: keep the new state files dependency-free of `orchestrator` (state owns no smart helpers); the duplicated supported-* lists pattern is acceptable; `:type` slot declarations are advisory — `make-X` constructors do the actual validation.

---

## Task 1: source-fact data structure (red → green)

**Files:**
- Create: `tests/source-fact-test.lisp`
- Create: `src/source-fact.lisp`
- Modify: `cl-harness.asd` (add `cl-harness/tests/source-fact-test` to `cl-harness/tests` `:depends-on`)

### Step 1.1: Write failing tests

Create `tests/source-fact-test.lisp`:

```lisp
;;;; tests/source-fact-test.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.5, docs/plans/2026-05-07-phase-b-source-patch-failure.md).
;;;; Covers SOURCE-FACT construction, defaults, and validation. The
;;;; develop-state-side recording semantics are tested in
;;;; tests/state-test.lisp once Task 4 lands the slot wiring.

(defpackage #:cl-harness/tests/source-fact-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/source-fact
                #:source-fact
                #:make-source-fact
                #:source-fact-path
                #:source-fact-form-type
                #:source-fact-form-name
                #:source-fact-read-at
                #:source-fact-mtime-at-read
                #:source-fact-related-step-index
                #:source-fact-via-tool))

(in-package #:cl-harness/tests/source-fact-test)

(defun %make (&rest overrides)
  (apply #'make-source-fact
         :path #P"/tmp/demo/src/greet.lisp"
         :via-tool "lisp-read-file"
         overrides))

(deftest make-source-fact-accepts-required-args
  (let ((s (%make)))
    (ok (typep s 'source-fact))
    (ok (equal #P"/tmp/demo/src/greet.lisp" (source-fact-path s)))
    (ok (string= "lisp-read-file" (source-fact-via-tool s)))))

(deftest make-source-fact-defaults
  (let ((s (%make)))
    (ok (null (source-fact-form-type s)))
    (ok (null (source-fact-form-name s)))
    (ok (null (source-fact-related-step-index s)))
    (ok (numberp (source-fact-read-at s)))
    (ok (or (null (source-fact-mtime-at-read s))
            (numberp (source-fact-mtime-at-read s))))))

(deftest make-source-fact-with-form-targeting
  (let ((s (%make :form-type "defun"
                  :form-name "greet"
                  :related-step-index 2)))
    (ok (string= "defun" (source-fact-form-type s)))
    (ok (string= "greet" (source-fact-form-name s)))
    (ok (= 2 (source-fact-related-step-index s)))))

(deftest make-source-fact-rejects-non-pathname-path
  (ok (handler-case
          (progn (make-source-fact :path 42 :via-tool "lisp-read-file")
                 nil)
        (error () t))))

(deftest make-source-fact-rejects-blank-via-tool
  (ok (handler-case
          (progn (make-source-fact :path #P"/tmp/x.lisp" :via-tool "")
                 nil)
        (error () t))))

(deftest make-source-fact-coerces-string-path-to-pathname
  (let ((s (make-source-fact :path "/tmp/demo/src/greet.lisp"
                             :via-tool "lisp-read-file")))
    (ok (pathnamep (source-fact-path s)))
    (ok (equal #P"/tmp/demo/src/greet.lisp" (source-fact-path s)))))
```

### Step 1.2: Register the test system

Use cl-mcp `lisp-patch-form` on `cl-harness.asd`'s `defsystem "cl-harness/tests"`:
- `old_text`: `"cl-harness/tests/state-test")`
- `new_text`: `"cl-harness/tests/state-test"\n               "cl-harness/tests/source-fact-test")`

Verify the indent matches sibling entries (15 spaces).

### Step 1.3: Run failing test

```json
{"system": "cl-harness/tests"}
```
Expected: compilation fails because `cl-harness/src/source-fact` does not exist. This is the red.

### Step 1.4: Implement `src/source-fact.lisp`

```lisp
;;;; src/source-fact.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.5). One source-fact records that
;;;; the agent (or the orchestrator) read a particular file (and
;;;; optionally a particular form within it) at a particular point
;;;; in time, with the file's mtime at the moment of read.
;;;;
;;;; Phase B only RECORDS source-facts. Phase C consumes them in
;;;; context-view generation; Phase E uses them for staleness
;;;; invalidation. This file therefore stays a pure data container
;;;; with zero inbound deps on other cl-harness packages.

(defpackage #:cl-harness/src/source-fact
  (:use #:cl)
  (:export #:source-fact
           #:make-source-fact
           #:source-fact-path
           #:source-fact-form-type
           #:source-fact-form-name
           #:source-fact-read-at
           #:source-fact-mtime-at-read
           #:source-fact-related-step-index
           #:source-fact-via-tool))

(in-package #:cl-harness/src/source-fact)

(defclass source-fact ()
  ((path :initarg :path :reader source-fact-path
         :documentation "Pathname of the file that was read. Always a
PATHNAME after MAKE-SOURCE-FACT (string inputs are coerced).")
   (form-type :initarg :form-type :reader source-fact-form-type
              :initform nil
              :documentation "When the read targeted a specific
top-level form, the form-type string (e.g. \"defun\", \"defclass\").
NIL when the read was whole-file or pattern-driven.")
   (form-name :initarg :form-name :reader source-fact-form-name
              :initform nil
              :documentation "Name of the targeted form, when
applicable. NIL otherwise.")
   (read-at :initarg :read-at :reader source-fact-read-at
            :documentation "GET-UNIVERSAL-TIME at the moment of
record. Always populated by MAKE-SOURCE-FACT.")
   (mtime-at-read :initarg :mtime-at-read
                  :reader source-fact-mtime-at-read
                  :initform nil
                  :documentation "FILE-WRITE-DATE of PATH at the
moment of read, or NIL when the file did not exist (or the call
site declined to stat it).")
   (related-step-index :initarg :related-step-index
                       :reader source-fact-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the step
active when the read happened, or NIL outside a develop run.")
   (via-tool :initarg :via-tool :reader source-fact-via-tool
             :documentation "Name of the cl-mcp tool that performed
the read (e.g. \"lisp-read-file\", \"fs-read-file\",
\"clgrep-search\"). Required, non-empty."))
  (:documentation
   "One observation that a particular file/form was read at a
particular time, with the file's mtime at that moment captured for
later staleness checks. Phase B records source-facts; Phase E uses
them for invalidation."))

(defun make-source-fact (&key path via-tool form-type form-name
                           related-step-index
                           (read-at (get-universal-time))
                           (mtime-at-read nil mtime-supplied-p))
  "Construct a SOURCE-FACT. PATH must be a pathname or string (string
is coerced to pathname). VIA-TOOL must be a non-empty string.
MTIME-AT-READ defaults to the file's FILE-WRITE-DATE when PATH
exists; pass an explicit value (including NIL) to override the
auto-stat."
  (let ((coerced-path (cond
                        ((pathnamep path) path)
                        ((stringp path) (pathname path))
                        (t (error "source-fact: :path must be a ~
pathname or string, got ~S" path)))))
    (unless (and (stringp via-tool) (plusp (length via-tool)))
      (error "source-fact: :via-tool must be a non-empty string, got ~S"
             via-tool))
    (when form-type (check-type form-type string))
    (when form-name (check-type form-name string))
    (when related-step-index (check-type related-step-index integer))
    (let ((effective-mtime
            (if mtime-supplied-p
                mtime-at-read
                (handler-case (file-write-date coerced-path)
                  (error () nil)))))
      (make-instance 'source-fact
                     :path coerced-path
                     :form-type form-type
                     :form-name form-name
                     :read-at read-at
                     :mtime-at-read effective-mtime
                     :related-step-index related-step-index
                     :via-tool via-tool))))
```

### Step 1.5: Verify green

cl-mcp `load-system` `{"system": "cl-harness", "force": true}` — clean.
cl-mcp `run-tests` `{"system": "cl-harness/tests/source-fact-test"}` — 6/6 pass.

### Step 1.6: Commit

```bash
git checkout -b phase-b-ledgers
git add tests/source-fact-test.lisp src/source-fact.lisp cl-harness.asd
git commit -m "$(cat <<'EOF'
feat: source-fact data structure (Phase B.1)

Adds src/source-fact.lisp with the SOURCE-FACT CLOS class, its
keyword constructor, and accessors. A source-fact captures one
file/form read event for later staleness checks (Phase E) and
context-view generation (Phase C). Phase B only records facts;
no consumer wires up here.

The class is a pure data container with zero inbound deps on
other cl-harness packages. Path inputs accept pathname or string
(string is coerced); via-tool is required non-empty; mtime is
auto-stat'd at construction unless explicitly supplied. Tests in
tests/source-fact-test.lisp cover construction, defaults,
form-targeted reads, and validation rejection paths.

Phase B of the context-management refactor
(docs/plans/2026-05-07-phase-b-source-patch-failure.md).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: patch-record data structure (red → green)

**Files:**
- Create: `tests/patch-record-test.lisp`
- Create: `src/patch-record.lisp`
- Modify: `cl-harness.asd` (add `cl-harness/tests/patch-record-test`)

### Step 2.1: Write failing tests

Create `tests/patch-record-test.lisp`:

```lisp
;;;; tests/patch-record-test.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.8, docs/plans/2026-05-07-phase-b-source-patch-failure.md).
;;;; Covers PATCH-RECORD construction, defaults, validation, and
;;;; the verify-status state machine.

(defpackage #:cl-harness/tests/patch-record-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/patch-record
                #:patch-record
                #:make-patch-record
                #:patch-record-path
                #:patch-record-form-type
                #:patch-record-form-name
                #:patch-record-via-tool
                #:patch-record-operation
                #:patch-record-diff-summary
                #:patch-record-applied-at
                #:patch-record-related-step-index
                #:patch-record-turn
                #:patch-record-verify-status
                #:patch-record-verify-source
                #:patch-record-set-verify-status))

(in-package #:cl-harness/tests/patch-record-test)

(defun %make (&rest overrides)
  (apply #'make-patch-record
         :path #P"/tmp/demo/src/greet.lisp"
         :via-tool "lisp-edit-form"
         :turn 5
         overrides))

(deftest make-patch-record-accepts-required-args
  (let ((p (%make)))
    (ok (typep p 'patch-record))
    (ok (equal #P"/tmp/demo/src/greet.lisp" (patch-record-path p)))
    (ok (string= "lisp-edit-form" (patch-record-via-tool p)))
    (ok (= 5 (patch-record-turn p)))))

(deftest make-patch-record-defaults
  (let ((p (%make)))
    (ok (null (patch-record-form-type p)))
    (ok (null (patch-record-form-name p)))
    (ok (null (patch-record-operation p)))
    (ok (or (null (patch-record-diff-summary p))
            (stringp (patch-record-diff-summary p))))
    (ok (null (patch-record-related-step-index p)))
    (ok (eq :pending (patch-record-verify-status p)))
    (ok (null (patch-record-verify-source p)))
    (ok (numberp (patch-record-applied-at p)))))

(deftest make-patch-record-with-full-detail
  (let ((p (%make :form-type "defun"
                  :form-name "greet"
                  :operation "replace"
                  :diff-summary "+1/-1"
                  :related-step-index 0)))
    (ok (string= "defun" (patch-record-form-type p)))
    (ok (string= "greet" (patch-record-form-name p)))
    (ok (string= "replace" (patch-record-operation p)))
    (ok (string= "+1/-1" (patch-record-diff-summary p)))
    (ok (= 0 (patch-record-related-step-index p)))))

(deftest make-patch-record-rejects-bad-via-tool
  (ok (handler-case
          (progn (make-patch-record :path #P"/tmp/x.lisp"
                                    :via-tool ""
                                    :turn 1)
                 nil)
        (error () t))))

(deftest patch-record-set-verify-status-pending-to-passed
  (let ((p (%make)))
    (patch-record-set-verify-status p :passed :incremental)
    (ok (eq :passed (patch-record-verify-status p)))
    (ok (eq :incremental (patch-record-verify-source p)))))

(deftest patch-record-set-verify-status-rejects-bad-status
  (let ((p (%make)))
    (ok (handler-case
            (progn (patch-record-set-verify-status p :bogus :incremental)
                   nil)
          (error () t)))
    (ok (eq :pending (patch-record-verify-status p)))))

(deftest patch-record-set-verify-status-rejects-bad-source
  (let ((p (%make)))
    (ok (handler-case
            (progn (patch-record-set-verify-status p :passed :elsewhere)
                   nil)
          (error () t)))))

(deftest patch-record-set-verify-status-allows-clean-overrides-incremental
  ;; A clean verify after an incremental verify is the authoritative
  ;; truth; the helper accepts the transition.
  (let ((p (%make)))
    (patch-record-set-verify-status p :passed :incremental)
    (patch-record-set-verify-status p :failed :clean)
    (ok (eq :failed (patch-record-verify-status p)))
    (ok (eq :clean (patch-record-verify-source p)))))
```

### Step 2.2: Register the test system

cl-mcp `lisp-patch-form`:
- `old_text`: `"cl-harness/tests/source-fact-test")`
- `new_text`: `"cl-harness/tests/source-fact-test"\n               "cl-harness/tests/patch-record-test")`

### Step 2.3: Run failing test

Expected: missing `cl-harness/src/patch-record` package.

### Step 2.4: Implement `src/patch-record.lisp`

```lisp
;;;; src/patch-record.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.8). One patch-record captures
;;;; one source-mutating tool invocation that succeeded — the file,
;;;; the form (when known), the tool used, the diff summary, the
;;;; current verify outcome attributable to it, and the turn /
;;;; plan-step in which it landed.
;;;;
;;;; Phase B only RECORDS patch-records. Phase C surfaces them in
;;;; context views; Phase E links them to staleness invalidation.

(defpackage #:cl-harness/src/patch-record
  (:use #:cl)
  (:export #:patch-record
           #:make-patch-record
           #:patch-record-path
           #:patch-record-form-type
           #:patch-record-form-name
           #:patch-record-via-tool
           #:patch-record-operation
           #:patch-record-diff-summary
           #:patch-record-applied-at
           #:patch-record-related-step-index
           #:patch-record-turn
           #:patch-record-verify-status
           #:patch-record-verify-source
           #:patch-record-set-verify-status
           #:+supported-verify-statuses+
           #:+supported-verify-sources+))

(in-package #:cl-harness/src/patch-record)

(defparameter +supported-verify-statuses+
  '(:pending :passed :failed)
  "Verify-status keywords accepted by PATCH-RECORD-SET-VERIFY-STATUS.
:PENDING is the initial state; :PASSED / :FAILED are set by the
recorder once a verify-result arrives.")

(defparameter +supported-verify-sources+
  '(:incremental :clean)
  "Verify-source keywords. :INCREMENTAL is the auto-verify after
each source-mutating tool call; :CLEAN is the fresh-worker verify
that runs at run end. Mirror of the distinction
src/verify.lisp:verify-task vs clean-verify-task makes.")

(defclass patch-record ()
  ((path :initarg :path :reader patch-record-path
         :documentation "Pathname of the file the patch modified.")
   (form-type :initarg :form-type :reader patch-record-form-type
              :initform nil
              :documentation "Form-type string (e.g. \"defun\")
when the patch tool targeted a named form, NIL otherwise.")
   (form-name :initarg :form-name :reader patch-record-form-name
              :initform nil
              :documentation "Name of the targeted form, when
applicable.")
   (via-tool :initarg :via-tool :reader patch-record-via-tool
             :documentation "cl-mcp tool name that applied the
patch (e.g. \"lisp-edit-form\", \"lisp-patch-form\",
\"fs-write-file\"). Required, non-empty.")
   (operation :initarg :operation :reader patch-record-operation
              :initform nil
              :documentation "For lisp-edit-form: \"replace\",
\"insert_before\", \"insert_after\". NIL for tools without an
operation argument.")
   (diff-summary :initarg :diff-summary
                 :reader patch-record-diff-summary
                 :initform nil
                 :documentation "First ~500 chars of the unified
diff, or a short summary like \"+1/-1\". NIL when the diff was
unavailable (tool returned no before/after content).")
   (applied-at :initarg :applied-at :reader patch-record-applied-at
               :documentation "GET-UNIVERSAL-TIME at the moment the
patch landed.")
   (related-step-index :initarg :related-step-index
                       :reader patch-record-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the
active step, or NIL outside a develop run.")
   (turn :initarg :turn :reader patch-record-turn
         :documentation "Agent loop turn at which the patch landed.
Useful for ordering when multiple patches share an applied-at
second.")
   (verify-status :initform :pending
                  :reader patch-record-verify-status
                  :documentation "Current verify outcome
attributable to this patch. Updated via
PATCH-RECORD-SET-VERIFY-STATUS once a verify-result arrives.")
   (verify-source :initform nil
                  :reader patch-record-verify-source
                  :documentation "Whether the verify-status came
from an :INCREMENTAL or :CLEAN verify. NIL while
verify-status is :PENDING."))
  (:documentation
   "One source-mutating tool invocation that succeeded, plus the
verify outcome we attribute to it. Phase B records; Phase C/E
consume."))

(defun make-patch-record (&key path via-tool turn
                            form-type form-name operation diff-summary
                            related-step-index
                            (applied-at (get-universal-time)))
  "Construct a PATCH-RECORD. PATH must be a pathname or string;
VIA-TOOL non-empty string; TURN integer."
  (let ((coerced-path (cond
                        ((pathnamep path) path)
                        ((stringp path) (pathname path))
                        (t (error "patch-record: :path must be a ~
pathname or string, got ~S" path)))))
    (unless (and (stringp via-tool) (plusp (length via-tool)))
      (error "patch-record: :via-tool must be a non-empty string, got ~S"
             via-tool))
    (check-type turn integer)
    (when form-type (check-type form-type string))
    (when form-name (check-type form-name string))
    (when operation (check-type operation string))
    (when diff-summary (check-type diff-summary string))
    (when related-step-index (check-type related-step-index integer))
    (make-instance 'patch-record
                   :path coerced-path
                   :form-type form-type
                   :form-name form-name
                   :via-tool via-tool
                   :operation operation
                   :diff-summary diff-summary
                   :applied-at applied-at
                   :related-step-index related-step-index
                   :turn turn)))

(defun patch-record-set-verify-status (record status source)
  "Transition RECORD's verify-status. STATUS must be one of
+SUPPORTED-VERIFY-STATUSES+; SOURCE must be one of
+SUPPORTED-VERIFY-SOURCES+. The transition rule is permissive: a
later setter call (e.g. :CLEAN after :INCREMENTAL) overrides the
prior value, mirroring the original verify-result semantics where
clean-verify is the authoritative truth.

Returns RECORD."
  (unless (member status +supported-verify-statuses+)
    (error "patch-record-set-verify-status: unsupported status ~S; ~
expected one of ~S" status +supported-verify-statuses+))
  (unless (member source +supported-verify-sources+)
    (error "patch-record-set-verify-status: unsupported source ~S; ~
expected one of ~S" source +supported-verify-sources+))
  (setf (slot-value record 'verify-status) status
        (slot-value record 'verify-source) source)
  record)
```

### Step 2.5: Verify green

cl-mcp `load-system` clean; `run-tests cl-harness/tests/patch-record-test` — 8/8 pass.

### Step 2.6: Commit

```bash
git add tests/patch-record-test.lisp src/patch-record.lisp cl-harness.asd
git commit -m "$(cat <<'EOF'
feat: patch-record data structure (Phase B.2)

Adds src/patch-record.lisp with the PATCH-RECORD CLOS class, its
keyword constructor, and the verify-status state-machine helper.
A patch-record captures one source-mutating tool invocation that
succeeded — file, form (when known), tool, operation, diff
summary, the turn / plan-step it landed in, and the verify
outcome we attribute to it.

Verify-status starts :PENDING and is transitioned to :PASSED or
:FAILED by PATCH-RECORD-SET-VERIFY-STATUS once a verify-result
arrives. The transition records whether the verify was
:INCREMENTAL or :CLEAN, mirroring src/verify.lisp's
verify-task / clean-verify-task split. A later :CLEAN setter
overrides an earlier :INCREMENTAL value (clean is authoritative).

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: failure-record + failure-ledger data structures (red → green)

**Files:**
- Create: `tests/failure-ledger-test.lisp`
- Create: `src/failure-ledger.lisp`
- Modify: `cl-harness.asd`

### Step 3.1: Write failing tests

Create `tests/failure-ledger-test.lisp`:

```lisp
;;;; tests/failure-ledger-test.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.9 + §8, docs/plans/2026-05-07-phase-b-source-patch-failure.md).

(defpackage #:cl-harness/tests/failure-ledger-test
  (:use #:cl #:rove)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-record
                #:make-failure-record
                #:failure-record-kind
                #:failure-record-description
                #:failure-record-test-name
                #:failure-record-reason
                #:failure-record-related-step-index
                #:failure-record-related-patch
                #:failure-record-status
                #:failure-record-resolved-at
                #:failure-record-resolved-by-patch
                #:failure-record-verify-source
                #:failure-ledger
                #:make-failure-ledger
                #:failure-ledger-active
                #:failure-ledger-resolved
                #:record-failure
                #:mark-resolved-by
                #:parse-failure-records-from-test-result))

(in-package #:cl-harness/tests/failure-ledger-test)

(defun %fr (&rest overrides)
  (apply #'make-failure-record
         :kind :test-failed
         :description "greet returns wrong value"
         :test-name "greet-returns-hello-name"
         :verify-source :incremental
         overrides))

(deftest make-failure-record-accepts-required-args
  (let ((f (%fr)))
    (ok (typep f 'failure-record))
    (ok (eq :test-failed (failure-record-kind f)))
    (ok (string= "greet returns wrong value"
                 (failure-record-description f)))
    (ok (string= "greet-returns-hello-name"
                 (failure-record-test-name f)))
    (ok (eq :incremental (failure-record-verify-source f)))))

(deftest make-failure-record-defaults
  (let ((f (%fr)))
    (ok (null (failure-record-reason f)))
    (ok (null (failure-record-related-step-index f)))
    (ok (null (failure-record-related-patch f)))
    (ok (eq :active (failure-record-status f)))
    (ok (null (failure-record-resolved-at f)))
    (ok (null (failure-record-resolved-by-patch f)))))

(deftest make-failure-record-rejects-bad-kind
  (ok (handler-case
          (progn (make-failure-record :kind :nonsense
                                      :description "x"
                                      :verify-source :incremental)
                 nil)
        (error () t))))

(deftest make-failure-record-rejects-bad-verify-source
  (ok (handler-case
          (progn (make-failure-record :kind :test-failed
                                      :description "x"
                                      :verify-source :elsewhere)
                 nil)
        (error () t))))

(deftest make-failure-ledger-empty
  (let ((l (make-failure-ledger)))
    (ok (null (failure-ledger-active l)))
    (ok (null (failure-ledger-resolved l)))))

(deftest record-failure-appends-to-active
  (let ((l (make-failure-ledger))
        (f1 (%fr :test-name "a"))
        (f2 (%fr :test-name "b")))
    (record-failure l f1)
    (record-failure l f2)
    (let ((active (failure-ledger-active l)))
      (ok (= 2 (length active)))
      (ok (string= "a" (failure-record-test-name (first active))))
      (ok (string= "b" (failure-record-test-name (second active))))
      (ok (null (failure-ledger-resolved l))))))

(deftest mark-resolved-by-moves-from-active-to-resolved
  (let ((l (make-failure-ledger))
        (f (%fr :test-name "broken")))
    (record-failure l f)
    (mark-resolved-by l f :patch :sentinel-patch)
    (ok (null (failure-ledger-active l)))
    (let ((resolved (failure-ledger-resolved l)))
      (ok (= 1 (length resolved)))
      (let ((entry (first resolved)))
        (ok (eq :resolved (failure-record-status entry)))
        (ok (eq :sentinel-patch
                (failure-record-resolved-by-patch entry)))
        (ok (numberp (failure-record-resolved-at entry)))))))

(deftest mark-resolved-by-with-no-patch-is-allowed
  ;; A failure can be resolved without a clear-cut patch attribution
  ;; (e.g. a test-only fix elsewhere). resolved-by-patch then stays NIL.
  (let ((l (make-failure-ledger))
        (f (%fr :test-name "transient")))
    (record-failure l f)
    (mark-resolved-by l f :patch nil)
    (ok (null (failure-ledger-active l)))
    (let ((entry (first (failure-ledger-resolved l))))
      (ok (eq :resolved (failure-record-status entry)))
      (ok (null (failure-record-resolved-by-patch entry))))))

(deftest parse-failure-records-from-test-result-handles-empty
  ;; A clean run-tests returns an empty failed_tests array (or no key).
  (let ((tr (alist-hash-table
             '(("passed" . 5) ("failed" . 0))
             :test 'equal)))
    (ok (null (parse-failure-records-from-test-result
               tr :verify-source :incremental)))))

(deftest parse-failure-records-from-test-result-extracts-known-fields
  ;; Shape mirrors what cl-mcp's run-tests emits per failed assertion.
  (let* ((source-h (alist-hash-table
                    '(("file" . "/tmp/demo/tests/greet-test.lisp")
                      ("line" . 12))
                    :test 'equal))
         (entry-h (alist-hash-table
                   `(("test_name" . "greet-returns-hello-name")
                     ("description" . "greet returns Hello, NAME!")
                     ("form" . "(string= ...)")
                     ("reason" . "expected \"Hello, Alice\"")
                     ("source" . ,source-h))
                   :test 'equal))
         (tr (alist-hash-table
              `(("passed" . 0)
                ("failed" . 1)
                ("failed_tests" . #(,entry-h)))
              :test 'equal)))
    (let ((records (parse-failure-records-from-test-result
                    tr :verify-source :incremental
                    :related-step-index 1)))
      (ok (= 1 (length records)))
      (let ((r (first records)))
        (ok (eq :test-failed (failure-record-kind r)))
        (ok (string= "greet-returns-hello-name"
                     (failure-record-test-name r)))
        (ok (string= "greet returns Hello, NAME!"
                     (failure-record-description r)))
        (ok (string= "expected \"Hello, Alice\""
                     (failure-record-reason r)))
        (ok (= 1 (failure-record-related-step-index r)))
        (ok (eq :incremental (failure-record-verify-source r)))))))

(deftest parse-failure-records-handles-missing-keys-gracefully
  ;; A degenerate failed_tests entry missing reason / source — we should
  ;; not crash; missing fields stay NIL on the record.
  (let* ((entry-h (alist-hash-table
                   '(("test_name" . "x")
                     ("description" . "y"))
                   :test 'equal))
         (tr (alist-hash-table
              `(("failed_tests" . #(,entry-h)))
              :test 'equal)))
    (let ((records (parse-failure-records-from-test-result
                    tr :verify-source :incremental)))
      (ok (= 1 (length records)))
      (let ((r (first records)))
        (ok (string= "x" (failure-record-test-name r)))
        (ok (null (failure-record-reason r)))))))
```

### Step 3.2: Register the test system

cl-mcp `lisp-patch-form`:
- `old_text`: `"cl-harness/tests/patch-record-test")`
- `new_text`: `"cl-harness/tests/patch-record-test"\n               "cl-harness/tests/failure-ledger-test")`

### Step 3.3: Run failing test → red

### Step 3.4: Implement `src/failure-ledger.lisp`

```lisp
;;;; src/failure-ledger.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.9 + §8). Captures load/test
;;;; failures observed during a develop run. Maintains an active
;;;; vs resolved partition so context views and final reports can
;;;; distinguish "currently broken" from "fixed earlier in the run".
;;;;
;;;; Sourced from VERIFY-RESULT.test-result hash-tables via
;;;; PARSE-FAILURE-RECORDS-FROM-TEST-RESULT. Phase B only RECORDS
;;;; failures; Phase C surfaces them in failure-analysis context
;;;; views (docs/context-management.md §8).

(defpackage #:cl-harness/src/failure-ledger
  (:use #:cl)
  (:export #:failure-record
           #:make-failure-record
           #:failure-record-kind
           #:failure-record-description
           #:failure-record-test-name
           #:failure-record-assertion-form
           #:failure-record-reason
           #:failure-record-source-file
           #:failure-record-source-line
           #:failure-record-related-step-index
           #:failure-record-related-patch
           #:failure-record-observed-at
           #:failure-record-status
           #:failure-record-resolved-at
           #:failure-record-resolved-by-patch
           #:failure-record-verify-source
           #:failure-ledger
           #:make-failure-ledger
           #:failure-ledger-active
           #:failure-ledger-resolved
           #:record-failure
           #:mark-resolved-by
           #:parse-failure-records-from-test-result
           #:+supported-failure-kinds+
           #:+supported-failure-statuses+
           #:+supported-verify-sources+))

(in-package #:cl-harness/src/failure-ledger)

(defparameter +supported-failure-kinds+
  '(:load-failed :test-failed :parse-error :other)
  "Kinds of failure a record can describe. :LOAD-FAILED corresponds
to verify-result :LOAD-FAILED; :TEST-FAILED to a single rove
deftest's failure within :TEST-FAILED. :PARSE-ERROR is reserved
for action-parse / test-source validation failures Phase B doesn't
yet wire. :OTHER is the catch-all.")

(defparameter +supported-failure-statuses+
  '(:active :resolved)
  "Lifecycle of a single failure record.")

(defparameter +supported-verify-sources+
  '(:incremental :clean)
  "Which verify pass observed the failure. Mirrors
src/patch-record.lisp:+supported-verify-sources+.")

(defclass failure-record ()
  ((kind :initarg :kind :reader failure-record-kind
         :documentation "One of +SUPPORTED-FAILURE-KINDS+.")
   (description :initarg :description
                :reader failure-record-description
                :documentation "Short one-line summary suitable
for a context-view header.")
   (test-name :initarg :test-name :initform nil
              :reader failure-record-test-name
              :documentation "For :TEST-FAILED, the rove deftest
name. NIL for other kinds.")
   (assertion-form :initarg :assertion-form :initform nil
                   :reader failure-record-assertion-form
                   :documentation "The failing assertion source as
captured by rove (the \"form\" key in failed_tests entries). NIL
when unavailable.")
   (reason :initarg :reason :initform nil
           :reader failure-record-reason
           :documentation "Error condition message or rove's
\"reason\" field. NIL when unavailable.")
   (source-file :initarg :source-file :initform nil
                :reader failure-record-source-file
                :documentation "Pathname (when extractable) of the
file rove blamed for the failure.")
   (source-line :initarg :source-line :initform nil
                :reader failure-record-source-line
                :documentation "Line number reported by rove, when
available.")
   (related-step-index :initarg :related-step-index
                       :initform nil
                       :reader failure-record-related-step-index
                       :documentation "PLAN-STEP-INDEX of the step
active when the failure was observed.")
   (related-patch :initarg :related-patch :initform nil
                  :reader failure-record-related-patch
                  :documentation "PATCH-RECORD active around the
time of the failure (the most recent patch on the same file at
record time), when known. NIL when no patch context applies.")
   (observed-at :initarg :observed-at
                :reader failure-record-observed-at
                :documentation "GET-UNIVERSAL-TIME at record
time.")
   (status :initform :active :reader failure-record-status
           :documentation "One of +SUPPORTED-FAILURE-STATUSES+.")
   (resolved-at :initform nil
                :reader failure-record-resolved-at
                :documentation "GET-UNIVERSAL-TIME of resolution,
or NIL while :ACTIVE.")
   (resolved-by-patch :initform nil
                      :reader failure-record-resolved-by-patch
                      :documentation "PATCH-RECORD attributed for
the resolution, or NIL when no clear-cut attribution.")
   (verify-source :initarg :verify-source
                  :reader failure-record-verify-source
                  :documentation "Which verify pass observed this
failure: :INCREMENTAL or :CLEAN."))
  (:documentation
   "One observation of a load- or test-time failure during a
develop run. Lifecycle: :ACTIVE on record; :RESOLVED via
MARK-RESOLVED-BY, with optional patch attribution."))

(defun make-failure-record (&key kind description verify-source
                              test-name assertion-form reason
                              source-file source-line
                              related-step-index related-patch
                              (observed-at (get-universal-time)))
  "Construct a FAILURE-RECORD. KIND, DESCRIPTION, VERIFY-SOURCE
required."
  (unless (member kind +supported-failure-kinds+)
    (error "failure-record: unsupported :kind ~S; expected one of ~S"
           kind +supported-failure-kinds+))
  (check-type description string)
  (unless (member verify-source +supported-verify-sources+)
    (error "failure-record: unsupported :verify-source ~S; expected ~S"
           verify-source +supported-verify-sources+))
  (when test-name (check-type test-name string))
  (when assertion-form (check-type assertion-form string))
  (when reason (check-type reason string))
  (when source-line (check-type source-line integer))
  (when related-step-index (check-type related-step-index integer))
  (let ((coerced-source-file
          (cond
            ((null source-file) nil)
            ((pathnamep source-file) source-file)
            ((stringp source-file) (pathname source-file))
            (t (error "failure-record: :source-file must be a ~
pathname, string, or NIL")))))
    (make-instance 'failure-record
                   :kind kind
                   :description description
                   :test-name test-name
                   :assertion-form assertion-form
                   :reason reason
                   :source-file coerced-source-file
                   :source-line source-line
                   :related-step-index related-step-index
                   :related-patch related-patch
                   :observed-at observed-at
                   :verify-source verify-source)))

(defclass failure-ledger ()
  ((%active :initform nil :accessor %active-internal
            :documentation "Reverse-chronological list. Public
accessor FAILURE-LEDGER-ACTIVE reverses on read.")
   (%resolved :initform nil :accessor %resolved-internal
              :documentation "Reverse-chronological list of
resolved records."))
  (:documentation
   "Active vs resolved partition over FAILURE-RECORD instances for
one develop run."))

(defun make-failure-ledger ()
  "Construct an empty FAILURE-LEDGER."
  (make-instance 'failure-ledger))

(defun failure-ledger-active (ledger)
  "Return active failures in observed order (oldest first)."
  (reverse (%active-internal ledger)))

(defun failure-ledger-resolved (ledger)
  "Return resolved failures in resolved-order (oldest resolved
first)."
  (reverse (%resolved-internal ledger)))

(defun record-failure (ledger record)
  "Push RECORD onto LEDGER's active list. Returns LEDGER."
  (push record (%active-internal ledger))
  ledger)

(defun mark-resolved-by (ledger record &key patch)
  "Move RECORD from active to resolved on LEDGER. Sets
record's status, resolved-at, resolved-by-patch (PATCH may be NIL).
Idempotent for records already absent from active. Returns LEDGER."
  (setf (%active-internal ledger)
        (remove record (%active-internal ledger) :test #'eq))
  (setf (slot-value record 'status) :resolved
        (slot-value record 'resolved-at) (get-universal-time)
        (slot-value record 'resolved-by-patch) patch)
  (push record (%resolved-internal ledger))
  ledger)

(defun %extract (h key)
  "Read KEY from hash-table H or return NIL if absent. Mirrors the
defensive pattern PARSE-VERIFY-RESULT uses for missing fields."
  (and (hash-table-p h) (gethash key h)))

(defun %coerce-failed-tests (raw)
  "Yason emits arrays as either VECTOR or LIST depending on parser
config; normalize to a list."
  (cond
    ((null raw) nil)
    ((listp raw) raw)
    ((vectorp raw) (coerce raw 'list))
    (t (error "failure-ledger: unexpected failed_tests shape ~S" raw))))

(defun parse-failure-records-from-test-result
    (test-result &key verify-source related-step-index)
  "Parse cl-mcp's run-tests TEST-RESULT hash-table into a list of
FAILURE-RECORDs. Returns NIL when TEST-RESULT is NIL, has no
failed_tests entry, or the entry is empty.

Each entry contributes one :TEST-FAILED record. Missing fields
become NIL on the record; the parser does not raise on shape drift
beyond the outermost (which is verified by yason's parser)."
  (unless (member verify-source +supported-verify-sources+)
    (error "parse-failure-records-from-test-result: bad ~
:verify-source ~S" verify-source))
  (let ((entries (%coerce-failed-tests
                  (%extract test-result "failed_tests"))))
    (loop for entry in entries
          for source-h = (%extract entry "source")
          collect
          (make-failure-record
           :kind :test-failed
           :description (or (%extract entry "description")
                            (%extract entry "test_name")
                            "unknown failure")
           :test-name (%extract entry "test_name")
           :assertion-form (%extract entry "form")
           :reason (%extract entry "reason")
           :source-file (%extract source-h "file")
           :source-line (let ((l (%extract source-h "line")))
                          (and (integerp l) l))
           :related-step-index related-step-index
           :verify-source verify-source))))
```

### Step 3.5: Verify green

`run-tests cl-harness/tests/failure-ledger-test` — 10/10 pass.

### Step 3.6: Commit

```bash
git add tests/failure-ledger-test.lisp src/failure-ledger.lisp cl-harness.asd
git commit -m "$(cat <<'EOF'
feat: failure-ledger data structures (Phase B.3)

Adds src/failure-ledger.lisp with FAILURE-RECORD (one observation
of a load/test failure), FAILURE-LEDGER (active vs resolved
partition with reverse-on-read public accessors), and
PARSE-FAILURE-RECORDS-FROM-TEST-RESULT (turns the cl-mcp
run-tests failed_tests array into a list of failure-records).

Records have status :ACTIVE on construction, transition to
:RESOLVED via MARK-RESOLVED-BY which records a resolved-at
timestamp and an optional resolved-by-patch attribution. NIL is a
valid attribution for failures that resolved without a clear-cut
patch link.

The parser is defensive against missing keys (yason shape drift
between worker versions); only failed_tests' outermost shape is
required. Tests in tests/failure-ledger-test.lisp cover record
construction, active/resolved transitions, and the parser against
both empty and minimal failed_tests fixtures.

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Extend `develop-state` with the three new slots (red → green)

**Files:**
- Modify: `tests/state-test.lisp` (add 6 deftests for the new slots)
- Modify: `src/state.lisp` (add 3 slots + 3 recorder helpers + 2 public list readers)

### Step 4.1: Append failing tests to `tests/state-test.lisp`

Add these deftests after the existing `develop-state-mutators-are-writable` test, and add the new symbols to the `:import-from #:cl-harness/src/state` clause at the top of the test file.

New `:import-from` additions:

```
                #:develop-state-source-facts
                #:develop-state-record-source-fact
                #:develop-state-patch-records
                #:develop-state-record-patch-record
                #:develop-state-failure-ledger
                #:develop-state-record-failure
```

New deftests at the end of the file:

```lisp
(deftest develop-state-source-facts-default-empty
  (let ((s (%make)))
    (ok (null (develop-state-source-facts s)))))

(deftest develop-state-record-source-fact-preserves-order
  (let ((s (%make)))
    (develop-state-record-source-fact s :first-fact)
    (develop-state-record-source-fact s :second-fact)
    (develop-state-record-source-fact s :third-fact)
    (ok (equal '(:first-fact :second-fact :third-fact)
               (develop-state-source-facts s)))))

(deftest develop-state-patch-records-default-empty
  (let ((s (%make)))
    (ok (null (develop-state-patch-records s)))))

(deftest develop-state-record-patch-record-preserves-order
  (let ((s (%make)))
    (develop-state-record-patch-record s :first-patch)
    (develop-state-record-patch-record s :second-patch)
    (ok (equal '(:first-patch :second-patch)
               (develop-state-patch-records s)))))

(deftest develop-state-failure-ledger-is-auto-initialized
  ;; Unlike source-facts and patch-records (lists),
  ;; failure-ledger is an object that develop-state owns from
  ;; construction. We expect a non-NIL ledger right out of the box.
  (let ((s (%make)))
    (ok (not (null (develop-state-failure-ledger s))))))

(deftest develop-state-record-failure-routes-to-ledger
  (let* ((s (%make))
         (l (develop-state-failure-ledger s)))
    (develop-state-record-failure s :a-failure-record)
    (ok (equal '(:a-failure-record)
               (cl-harness/src/failure-ledger:failure-ledger-active l)))))
```

The last test imports from `cl-harness/src/failure-ledger`. Add to the test file's `defpackage`:
```
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger-active)
```

### Step 4.2: Run failing tests → red (slots/helpers don't exist yet).

### Step 4.3: Modify `src/state.lisp`

Add the new dependency to the `defpackage`:

```
(defpackage #:cl-harness/src/state
  (:use #:cl)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-ledger
                #:make-failure-ledger
                #:record-failure)
  (:export #:develop-state
           ...
           #:develop-state-source-facts
           #:develop-state-record-source-fact
           #:develop-state-patch-records
           #:develop-state-record-patch-record
           #:develop-state-failure-ledger
           #:develop-state-record-failure))
```

Add three slots to the `develop-state` defclass (after `integration-issues`):

```lisp
   (source-facts :initform nil :accessor %source-facts
                 :documentation "Reverse-chronological list of
SOURCE-FACT instances. Internal; public reader is
DEVELOP-STATE-SOURCE-FACTS.")
   (patch-records :initform nil :accessor %patch-records
                  :documentation "Reverse-chronological list of
PATCH-RECORD instances. Internal; public reader is
DEVELOP-STATE-PATCH-RECORDS.")
   (failure-ledger :reader develop-state-failure-ledger
                   :documentation "FAILURE-LEDGER owned by this
state. Auto-initialised in INITIALIZE-INSTANCE :AFTER below; no
:initform because we don't want to share one ledger across
instances.")
```

Add the auto-init method and the three helper defuns at the bottom of the file:

```lisp
(defmethod initialize-instance :after ((s develop-state) &key)
  "Allocate a fresh FAILURE-LEDGER for each new DEVELOP-STATE.
Using :AFTER instead of an :initform so each instance gets its
own ledger (an :initform expression evaluated at class-init time
would share one ledger between every instance)."
  (setf (slot-value s 'failure-ledger) (make-failure-ledger)))

(defun develop-state-record-source-fact (state fact)
  "Push FACT onto STATE's source-facts list. Returns STATE."
  (push fact (%source-facts state))
  state)

(defun develop-state-source-facts (state)
  "Return STATE's recorded source-facts in observation order
(oldest first)."
  (reverse (%source-facts state)))

(defun develop-state-record-patch-record (state record)
  "Push RECORD onto STATE's patch-records list. Returns STATE."
  (push record (%patch-records state))
  state)

(defun develop-state-patch-records (state)
  "Return STATE's recorded patch-records in observation order
(oldest first)."
  (reverse (%patch-records state)))

(defun develop-state-record-failure (state failure-record)
  "Append FAILURE-RECORD to STATE's failure-ledger active list.
Thin wrapper around RECORD-FAILURE on the ledger; provided so
callers don't need to know the ledger lives inside develop-state.
Returns STATE."
  (record-failure (develop-state-failure-ledger state) failure-record)
  state)
```

### Step 4.4: Verify green

`run-tests cl-harness/tests/state-test` — 12/12 pass (6 original + 6 new).
`run-tests cl-harness/tests` — full suite green (no regressions).

### Step 4.5: Commit

```bash
git add src/state.lisp tests/state-test.lisp
git commit -m "$(cat <<'EOF'
feat: extend develop-state with B-level ledger slots (Phase B.4)

Adds three new slots to DEVELOP-STATE:
- source-facts (list of SOURCE-FACT, reverse-on-read public reader)
- patch-records (list of PATCH-RECORD, reverse-on-read)
- failure-ledger (FAILURE-LEDGER, auto-initialised per instance
  via :AFTER method to avoid shared mutable state across DEVELOP
  invocations)

Plus three thin recorder helpers
(develop-state-record-source-fact / -record-patch-record /
-record-failure) that push onto the appropriate slot. Phase B
records facts; Phase C consumes them.

The class still has zero inbound deps on orchestrator/agent. The
:import-from clause now pulls failure-ledger so the slot type is
expressible without circular references.

Tests in tests/state-test.lisp now cover the three new slots'
defaults, ordering invariants, and the failure-ledger
per-instance allocation.

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire `agent-state` to the develop-state back-reference (red → green)

**Files:**
- Modify: `tests/agent-test.lisp` (add deftest for the back-ref slot)
- Modify: `src/agent.lisp` (add slot + initarg)

### Step 5.1: Add the failing test

Append to `tests/agent-test.lisp`. Find the existing helper that constructs an `agent-state` and add a deftest verifying the new slot accepts a develop-state back-reference and defaults to NIL.

```lisp
(deftest agent-state-develop-state-defaults-to-nil
  (let ((s (cl-harness/src/agent::%make-agent-state-for-tests)))
    (ok (null (cl-harness/src/agent:agent-state-develop-state s)))))

(deftest agent-state-develop-state-accepts-back-ref
  (let* ((ds (cl-harness/src/state:make-develop-state
              :goal "g" :project-root "/tmp/"
              :system "s" :test-system "s/tests"))
         (s (cl-harness/src/agent::%make-agent-state-for-tests
             :develop-state ds)))
    (ok (eq ds (cl-harness/src/agent:agent-state-develop-state s)))))
```

(If `%make-agent-state-for-tests` doesn't exist, add a private helper in agent.lisp that wraps `make-instance 'agent-state` with sensible test defaults; do NOT export it.)

### Step 5.2: Add the slot

Modify `src/agent.lisp`'s `agent-state` defclass to add (at the end of its slot list):

```lisp
   (develop-state :initarg :develop-state
                  :reader agent-state-develop-state
                  :initform nil
                  :documentation "When this agent loop is being
driven from inside a DEVELOP run, the back-reference to the
caller's DEVELOP-STATE so RUN-AGENT can record source-facts,
patch-records, and failures into the develop-level ledgers.
NIL when run-agent is invoked standalone (cl-harness:fix path).")
```

Export `agent-state-develop-state` in the existing `:export` clause of agent.lisp's defpackage.

### Step 5.3: Verify green

`run-tests cl-harness/tests/agent-test` — same count as before plus 2 new passing tests.

### Step 5.4: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: agent-state.develop-state back-reference (Phase B.5)

Adds an optional :develop-state slot on AGENT-STATE so RUN-AGENT
can record into the develop-level ledgers when driven from inside
a DEVELOP run. The slot is :initform NIL so cl-harness:fix's
standalone RUN-AGENT path is unaffected.

This is the wiring substrate Tasks 6 and 7 use to record source
reads and patch applications without coupling agent.lisp to
state.lisp at the symbol level (the back-ref is type-untyped at
the slot level — runtime predicate calls handle the optional).

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Record patch-records at the agent's `:patch` JSONL emission point

**Files:**
- Modify: `tests/agent-test.lisp` (add an integration test using the existing MCP/LLM stub harness — see Phase A's reference notes on `agent-test.lisp` patterns)
- Modify: `src/agent.lisp` (instrument the existing `(log-event logger :patch ...)` call site)

### Step 6.1: Add the failing integration test

The pattern: stub MCP transport to accept a `lisp-edit-form` call and return success; stub LLM to emit one tool call then a `finish` action; run `run-agent` with a `develop-state` back-reference; assert that exactly one `patch-record` lands in the develop-state's ledger with the expected file path and via-tool.

Reference the existing harness in `tests/agent-test.lisp` (the survey identified `*mcp-handler*` and `*llm-responses*` style stubs). Add this test after the existing happy-path agent test:

```lisp
(deftest run-agent-records-patch-into-develop-state
  ;; Drive run-agent with a develop-state back-ref and a single
  ;; lisp-edit-form tool call; verify exactly one patch-record
  ;; lands in the ledger.
  (let* ((ds (cl-harness/src/state:make-develop-state
              :goal "g" :project-root "/tmp/cl-harness-b-test/"
              :system "demo" :test-system "demo/tests"))
         ;; -- Stub harness setup is project-specific; mirror
         ;; the existing happy-path test's pattern. The key
         ;; mutations relative to that test:
         ;;   1) Pass :develop-state ds when constructing the
         ;;      agent-state (or via run-agent's kwargs once
         ;;      Task 7 adds the threading).
         ;;   2) Have the stub LLM emit one lisp-edit-form
         ;;      action against /tmp/cl-harness-b-test/foo.lisp
         ;;      followed by a finish action.
         ;;   3) Have the stub MCP transport return
         ;;      isError=false for the lisp-edit-form call.
         ;; -- end stub block
         )
    ;; -- After running, assert: --
    (let ((records (cl-harness/src/state:develop-state-patch-records
                    ds)))
      (ok (= 1 (length records)))
      (let ((p (first records)))
        (ok (search "foo.lisp"
                    (namestring
                     (cl-harness/src/patch-record:patch-record-path p))))
        (ok (string= "lisp-edit-form"
                     (cl-harness/src/patch-record:patch-record-via-tool p)))
        (ok (eq :pending
                (cl-harness/src/patch-record:patch-record-verify-status p)))))))
```

The test stub block is left as a sketch because the existing `agent-test.lisp` harness is the authoritative pattern; the implementer subagent should look at the existing happy-path test and copy-mutate. If the existing harness doesn't expose a clean injection point for `:develop-state`, add one as a new `run-agent` keyword argument in Task 7's wiring step (the test then becomes straightforward).

### Step 6.2: Run failing test → red

### Step 6.3: Instrument `src/agent.lisp`

The Phase A survey identified the patch event emission around lines 770-780. Adjust the call so when the surrounding `agent-state` carries a non-NIL `develop-state`, a `patch-record` is also recorded. Sketch:

```lisp
;; -- Around the existing (log-event logger :patch ...) call: --
(when (agent-state-develop-state agent-state)
  (cl-harness/src/state:develop-state-record-patch-record
   (agent-state-develop-state agent-state)
   (cl-harness/src/patch-record:make-patch-record
    :path (pathname target)
    :via-tool tool
    :form-type (or (and arguments (gethash "form_type" arguments)) nil)
    :form-name (or (and arguments (gethash "form_name" arguments)) nil)
    :operation (or (and arguments (gethash "operation" arguments)) nil)
    :diff-summary (when (and diff (plusp (length diff)))
                    (subseq diff 0 (min 500 (length diff))))
    :related-step-index (agent-state-step-index agent-state)
    :turn turn)))
```

(`agent-state-step-index` may need to be added in Task 7 if not already present; for now, pass NIL if unavailable.)

Add `:import-from`s at the top of `src/agent.lisp` for:
- `cl-harness/src/state` → `develop-state-record-patch-record`
- `cl-harness/src/patch-record` → `make-patch-record`

Also export `agent-state-step-index` if Task 7 introduces it.

### Step 6.4: Verify green

Run the new test plus the full suite. Specifically verify `run-tests cl-harness/tests/agent-test` is green (the existing happy-path tests do NOT pass a `:develop-state`, so the `(when ...)` guard ensures they keep working).

### Step 6.5: Commit

```bash
git add src/agent.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: record patch-records into develop-state from agent loop (Phase B.6)

Instruments the existing :patch JSONL emission point in
src/agent.lisp so that, when AGENT-STATE carries a non-NIL
:develop-state back-reference, each successful source-mutating
tool call also produces a PATCH-RECORD on the develop-state's
ledger. The record captures the file, the cl-mcp tool name, the
form-type / form-name / operation arguments (when present), the
first 500 chars of the unified diff, the agent turn, and the
related plan-step index.

Standalone RUN-AGENT (cl-harness:fix path with no develop-state)
is unaffected: the (when (agent-state-develop-state ...)) guard
keeps the new path inert. Verified by running the existing
agent-test happy-path suite alongside the new
run-agent-records-patch-into-develop-state test.

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Record source-facts at the agent's file-read tool dispatch

**Files:**
- Modify: `tests/agent-test.lisp` (one new integration test mirroring Task 6's pattern)
- Modify: `src/agent.lisp` (intercept the file-read tool dispatch)

### Step 7.1: Add the failing test

Mirror Task 6: drive `run-agent` with a develop-state back-ref + a stub LLM that emits one `lisp-read-file` call against `/tmp/cl-harness-b-test/bar.lisp` followed by `finish`. Assert exactly one `source-fact` lands with the expected path and `via-tool="lisp-read-file"`.

### Step 7.2: Find the file-read dispatch point

cl-mcp's read-style tools are `lisp-read-file`, `fs-read-file`, `clgrep-search` (the last is a search but reads file content). The agent dispatches them in `handle-tool-call` (or equivalent — the survey will have surfaced it). Identify the exact call site that handles a `read-file-count` increment; that's where to instrument.

### Step 7.3: Instrument

```lisp
;; -- In the read-file-tool branch of handle-tool-call: --
(let ((target (and arguments (gethash "path" arguments))))
  (when (and (agent-state-develop-state agent-state) target)
    (cl-harness/src/state:develop-state-record-source-fact
     (agent-state-develop-state agent-state)
     (cl-harness/src/source-fact:make-source-fact
      :path target
      :via-tool tool
      :form-type (and arguments (gethash "form_type" arguments))
      :form-name (and arguments (gethash "form_name" arguments))
      :related-step-index (agent-state-step-index agent-state)))))
```

Add `:import-from`s for `develop-state-record-source-fact` and `make-source-fact`.

### Step 7.4: Wire `run-agent`'s `:develop-state` keyword (if not done in Task 6)

`run-agent` should accept `:develop-state state` as a kwarg and stash it on the agent-state it constructs internally. Existing callers (`cl-harness:fix` etc.) don't pass it, so the default NIL keeps them working. Update the orchestrator's `execute-plan`'s `run-fn` invocation so it threads the develop-state back-ref:

In `src/orchestrator.lisp`'s `%execute-step`, add `:develop-state state` to the `(funcall run-fn rc provider mcp-client policy step-logger)` call. This requires `%execute-step` to receive `state` as a parameter; thread it through from `execute-plan` and from `develop`. Since Phase A already constructs `develop-state` in `develop`, this is a straightforward parameter addition.

### Step 7.5: Verify green

Full suite + the new test + Task 6's test.

### Step 7.6: Commit

```bash
git add src/agent.lisp src/orchestrator.lisp tests/agent-test.lisp
git commit -m "$(cat <<'EOF'
feat: record source-facts + thread develop-state into run-agent (Phase B.7)

Two coupled changes:

1. RUN-AGENT now accepts an optional :develop-state keyword; when
   supplied, it is stashed on the constructed AGENT-STATE so
   downstream tool dispatchers can record into the develop-state
   ledgers.

2. The file-read tool branch in handle-tool-call (lisp-read-file,
   fs-read-file, clgrep-search) records a SOURCE-FACT on the
   develop-state when the back-ref is non-NIL. The fact captures
   path, tool name, optional form-type / form-name (when the LLM
   passed them), and the active plan-step index.

The orchestrator's execute-plan / develop now threads the
develop-state back-ref through to run-agent. cl-harness:fix's
standalone path is unaffected (no develop-state is constructed
there, so the back-ref stays NIL).

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Record failure-records and resolve them across verifies

**Files:**
- Modify: `tests/orchestrator-test.lisp` (add a deftest using the existing stub run-fn pattern)
- Modify: `src/orchestrator.lisp` (after each step, parse failed_tests + record; on subsequent green verifies, mark prior failures resolved)

### Step 8.1: Add the failing test

Use the existing orchestrator-test stub pattern. The test:

1. Construct a develop-state.
2. Run `execute-plan` with a stub `run-fn` that returns a verify-result containing `:test-failed` with one entry in `failed_tests`.
3. After the call, assert: develop-state's failure-ledger has 1 active failure with the expected test-name.
4. Run a second step whose stub returns `:passed`.
5. Assert: failure-ledger now has 0 active and 1 resolved.

```lisp
(deftest execute-plan-records-failures-and-resolves-on-pass
  ;; Sketch — uses existing orchestrator-test stub pattern.
  ;; Step 1's stub returns a verify-result with one failed_tests entry.
  ;; Step 2's stub returns :passed, which resolves the prior failure.
  ;; -- Implementer fills in stub bodies mirroring existing tests. --
  ...)
```

### Step 8.2: Instrument `src/orchestrator.lisp`

After each `verify-result` arrives in `%execute-step` (or wherever the orchestrator inspects it), call:

```lisp
(let ((records (cl-harness/src/failure-ledger:parse-failure-records-from-test-result
                (cl-harness/src/verify:verify-result-test verify-result)
                :verify-source :incremental
                :related-step-index (plan-step-index step))))
  (dolist (r records)
    (cl-harness/src/state:develop-state-record-failure state r)))
```

When a subsequent verify shows previously-active failures absent, attribute resolution. Naive policy for Phase B: at the start of each `%execute-step`, before recording new failures, take the snapshot of currently-active failures; after the step's verify completes, any that are no longer present in the new failed_tests get marked resolved by the most recent patch-record on the same file (or NIL if no match).

The "most recent patch-record on the same file" lookup:

```lisp
(defun %most-recent-patch-on-file (state path)
  (find-if (lambda (p)
             (equal (cl-harness/src/patch-record:patch-record-path p)
                    path))
           (reverse (cl-harness/src/state:develop-state-patch-records state))))
```

(`reverse` so we walk from newest to oldest.)

### Step 8.3: Verify green

`run-tests cl-harness/tests/orchestrator-test` and `run-tests cl-harness/tests` — full suite green.

### Step 8.4: Commit

```bash
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "$(cat <<'EOF'
feat: record + resolve failures in develop-state ledger (Phase B.8)

execute-plan now parses each verify-result's failed_tests via
PARSE-FAILURE-RECORDS-FROM-TEST-RESULT and records the entries on
the develop-state's failure-ledger. When a subsequent step's
verify shows a previously-active failure absent, the prior record
is moved to :RESOLVED via MARK-RESOLVED-BY, with attribution to
the most recent patch-record on the same source file (or NIL when
no patch matches).

The attribution heuristic is intentionally simple for Phase B;
Phase E will refine resolution semantics once context views are
consuming the ledger.

Phase B of the context-management refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Lint + force-compile + regression sweep

Mirrors Phase A Task 4. No new feature work.

### Steps

1. `mallet src/source-fact.lisp src/patch-record.lisp src/failure-ledger.lisp src/state.lisp src/agent.lisp src/orchestrator.lisp tests/source-fact-test.lisp tests/patch-record-test.lisp tests/failure-ledger-test.lisp tests/state-test.lisp tests/agent-test.lisp tests/orchestrator-test.lisp` — fix any new warnings on Phase B files; pre-existing warnings are out of scope.
2. `(asdf:compile-system :cl-harness :force t)` via cl-mcp `repl-eval` — clean.
3. cl-mcp `run-tests` `{"system": "cl-harness/tests"}` — must show pre-Phase-B count + new Phase B tests, all passing.
4. `rove cl-harness.asd` from a clean shell (or the `ros run` fallback used in Phase A) — same pre-existing 5-failure set in `develop-bench-test`, no new failures.
5. Commit only if mallet required fixes.

---

## Task 10: Final code review + docs annotation

### Step 10.1: Update `docs/context-management.md` §14

Edit the implementation-status table to mark Phase B's three concerns as `landed` and add a forward pointer to the runtime-vocabulary plan (file: `docs/plans/2026-05-XX-phase-b-runtime-vocabulary.md` — to be created later).

```markdown
| Phase | 内容 | 状態 | 関連 plan |
|---|---|---|---|
| A | 中央 `develop-state` クラスの導入と `develop` の thread 化 | landed (2026-05-06) | `docs/plans/2026-05-06-phase-a-develop-state.md` |
| B (source/patch/failure) | source-fact / patch-record / failure-ledger の追加とインストルメント | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-b-source-patch-failure.md` |
| B (runtime-vocabulary) | 構造化 packages / exports / classes / generic functions / conditions / ASDF systems | not started | TBD |
| C | `make-context-view` による phase/subtask ごとの圧縮 view 生成 | not started | TBD |
| D | tool 結果圧縮、REPL transcript の finding 化 | not started | TBD |
| E | staleness 管理、構造化 reporting | not started | TBD |
```

Commit:

```bash
git add docs/context-management.md
git commit -m "docs: annotate Phase B (source/patch/failure) landing"
```

### Step 10.2: Dispatch final code review

Run a `superpowers:code-reviewer` over the entire `phase-b-ledgers` branch (base = post-Phase-A merge SHA on main; head = current branch tip). Specifically ask the reviewer to validate:

- Three new data files have zero inbound deps on orchestrator/agent.
- `develop-state`'s slot count is now 19 (16 original + 3 new); the `:after` initialize-instance method is correctly per-instance.
- `agent.lisp`'s instrumentation is gated behind `(when (agent-state-develop-state ...))` so `cl-harness:fix` standalone path is unaffected.
- `orchestrator.lisp`'s failure-ledger wiring uses the parser correctly and the resolution heuristic doesn't double-resolve.
- Test counts: source-fact-test 6, patch-record-test 8, failure-ledger-test 10, state-test +6, agent-test +2, orchestrator-test +1, total +33 deftests.
- mallet clean on Phase B files.
- No `:local-nicknames`.

If the reviewer finds blocking issues, route fixes back to a fresh implementer subagent before merging.

### Step 10.3: Merge to main

Per `superpowers:finishing-a-development-branch`: `--no-ff` merge with a summary commit message that calls out one observable improvement (failures are now structured in `develop-state` and accessible from any callers walking the result graph), and confirms no public API breaks.

---

## Verification checklist (run before opening a PR)

- [ ] `src/source-fact.lisp` exists and exports the documented symbols
- [ ] `src/patch-record.lisp` exists and exports the documented symbols
- [ ] `src/failure-ledger.lisp` exists and exports the documented symbols
- [ ] `cl-harness.asd` lists the three new test systems
- [ ] `develop-state` has 19 slots (16 + 3); failure-ledger initialises per-instance
- [ ] `agent-state` has the optional `develop-state` back-reference
- [ ] `run-agent` accepts `:develop-state` and threads it onto agent-state
- [ ] Patch instrumentation in agent.lisp records via `develop-state-record-patch-record`
- [ ] File-read instrumentation in agent.lisp records via `develop-state-record-source-fact`
- [ ] Orchestrator records failures from each verify-result and resolves them on subsequent green verifies
- [ ] Standalone `cl-harness:fix` path is unaffected (verified by running the existing `agent-test` happy-path tests with no regressions)
- [ ] mallet clean on Phase B files
- [ ] `(asdf:compile-system :cl-harness :force t)` clean
- [ ] Full `cl-harness/tests` rove suite green
- [ ] `docs/context-management.md` §14 updated

## Rollback plan

If the branch surfaces a blocking regression that cannot be diagnosed quickly:

1. `git checkout main -- src/agent.lisp src/orchestrator.lisp src/state.lisp` — restore the wiring layer.
2. Keep `src/source-fact.lisp`, `src/patch-record.lisp`, `src/failure-ledger.lisp`, and their tests (additive; safe to keep).
3. Open an issue describing the regression and re-attempt the wiring in isolation.

The split into data-structure tasks (1-3) vs. state-extension (4) vs. wiring (5-8) keeps the rollback boundary clean: data structures are independently useful, state extension is a single-file change, and wiring is two-file change.
