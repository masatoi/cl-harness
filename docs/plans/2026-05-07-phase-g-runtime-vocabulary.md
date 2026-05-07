# Phase G — Runtime Vocabulary Ledger Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Capture Common Lisp runtime vocabulary (packages, exported / internal symbols, functions, generic functions / methods, classes, macros, conditions, ASDF systems) as a structured ledger on `develop-state`, with a `:probed-at` baseline for staleness, and surface a per-step slice through the existing `make-context-view` so `:exploration` (and `:planning` in inventory mode) views can ground the LLM in the live image rather than a re-parsed text inventory.

**Architecture:**
- **New module** `src/runtime-vocabulary.lisp`: a record class `runtime-vocab-fact` (analogous to `source-fact`) plus `make-runtime-vocab-fact` and a `runtime-vocab-fact-stale-p` predicate. No `defclass` per-symbol-kind — one flat record covers all kinds.
- **New slot** `runtime-vocabulary` on `develop-state` carrying a list of `runtime-vocab-fact` instances. Recorder helper mirrors `develop-state-record-source-fact`.
- **No new tools.** Recording happens at the agent loop, not inside cl-mcp. The agent-loop side hooks into `cl-mcp` tool results (`code-find`, `code-describe`, `code-find-references`, plus `repl-eval` outputs that reveal vocabulary) the same way Phase B hooked source reads.
- **Render-time staleness** (Phase F pattern): `make-context-view` does not filter; `context-view->string` annotates stale facts with `[STALE]` in the same `:exploration` formatter that already prints source-facts.
- **`:planning` view** gains an opt-in **runtime-vocab summary** when `:project-inventory` is `nil` and the runtime-vocabulary slot has facts; the existing project-inventory text block is kept untouched and remains the default planner input.

**Tech Stack:** SBCL / ASDF `:package-inferred-system` / Rove tests / alexandria / `:import-from` + `:export` only (no `:local-nicknames`).

---

## Why this phase

`docs/context-management.md` §3.4 (Runtime Vocabulary Context) and §14 row "B (runtime-vocabulary): not started" are the largest remaining gap. Today the planner gets a **text inventory** built from disk by `inventory.lisp`. That works for cold starts but doesn't carry symbol-level resolution data and goes stale the moment a patch lands. A structured ledger lets:

- The agent **reuse runtime introspection** rather than re-grep on each turn.
- The view **distinguish what's defined in source vs. what's only live in the REPL** (Source State vs. Runtime State separation per §7).
- Phase F's render-time staleness pattern extend cleanly: `runtime-vocab-fact-stale-p` flags facts whose `:probed-at` predates the latest `load-system` / patch on the underlying file.

Phase G keeps the surface minimal. We record vocab facts at the agent-loop layer when cl-mcp tools that reveal vocabulary return successfully — no proactive image-walking, no parallel scanner. The constructor is **opt-in**: a fact is recorded when the agent's `code-find` / `code-describe` / `code-find-references` / `repl-eval` (with `(describe ...)` / `(find-class ...)` / `(asdf:registered-systems)` style probes) call returns shape-matching data. Anything past that — proactive symbol enumeration — is deferred to a later phase.

---

## Design contract (do not deviate without confirming)

1. **One flat record class** (`runtime-vocab-fact`). Distinguished by `:kind` (a keyword from `+supported-kinds+`). This avoids 9 subclasses and matches `failure-record`'s shape.
2. **Recording is best-effort.** A malformed tool result must NOT raise — the recorder swallows shape mismatches and logs nothing rather than crashing the agent loop.
3. **Staleness is render-time.** No filtering in `make-context-view`. The `:exploration` formatter calls `runtime-vocab-fact-stale-p` while emitting bullets, prefixing `[STALE] ` exactly like Phase F does for source-facts.
4. **Backward compatibility.** Existing planner / explore / agent code paths must keep working when no `develop-state` is threaded (the `nil` `develop-state` branch already exists in `agent.lisp`). Do not introduce a hard requirement.
5. **No re-export from `src/main`** until the surface stabilises across at least one downstream consumer. Phase G keeps everything internal to `cl-harness/src/runtime-vocabulary` and `cl-harness/src/state`. Phase H or J can promote symbols if needed.
6. **No new cl-mcp tool calls.** The recorder reads from existing tool results that the agent loop already processes.
7. **`:planning` view does NOT replace `project-inventory`.** It augments. When both are present, project-inventory comes first (cold-start summary), runtime-vocab summary comes second (warm observations). When the runtime-vocabulary slot is empty, the planner output is byte-identical to today.

---

## Files touched

| Path | Action |
|---|---|
| `src/runtime-vocabulary.lisp` | **Create** — record class, constructor, staleness predicate, kind helper |
| `src/state.lisp` | Modify — add `runtime-vocabulary` slot + recorder + reader |
| `src/context-view.lisp` | Modify — `:import-from` runtime-vocab readers; new view slot + filter; `:exploration` and `:planning` formatters wire annotated bullets |
| `src/agent.lisp` | Modify — recorder hooks for `code-find` / `code-describe` / `code-find-references` tool results |
| `cl-harness.asd` | Modify — extend `cl-harness/tests` deps with `runtime-vocabulary-test` |
| `tests/runtime-vocabulary-test.lisp` | **Create** — unit tests for the new module |
| `tests/state-test.lisp` | Modify — add tests for the new slot + recorder |
| `tests/context-view-test.lisp` | Modify — add tests for `:exploration` + `:planning` rendering of runtime-vocab |
| `tests/agent-test.lisp` | Modify — add tests for recorder hooks (using mock tool results) |

---

## Task 1: `runtime-vocab-fact` data module (new file)

**Files:**
- Create: `src/runtime-vocabulary.lisp`
- Create: `tests/runtime-vocabulary-test.lisp`
- Modify: `cl-harness.asd` (add `cl-harness/tests/runtime-vocabulary-test` to test deps)

### Step 1: Write the failing test file

Create `tests/runtime-vocabulary-test.lisp`:

```lisp
;;;; tests/runtime-vocabulary-test.lisp

(defpackage #:cl-harness/tests/runtime-vocabulary-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:runtime-vocab-fact
                #:make-runtime-vocab-fact
                #:runtime-vocab-fact-kind
                #:runtime-vocab-fact-name
                #:runtime-vocab-fact-package
                #:runtime-vocab-fact-source-file
                #:runtime-vocab-fact-summary
                #:runtime-vocab-fact-via-tool
                #:runtime-vocab-fact-probed-at
                #:runtime-vocab-fact-related-step-index
                #:runtime-vocab-fact-stale-p
                #:+supported-runtime-vocab-kinds+))

(in-package #:cl-harness/tests/runtime-vocabulary-test)

(deftest make-runtime-vocab-fact-records-required-fields
  (let ((fact (make-runtime-vocab-fact
               :kind :function :name "foo" :package "CL-USER"
               :via-tool "code-describe")))
    (ok (typep fact 'runtime-vocab-fact))
    (ok (eq :function (runtime-vocab-fact-kind fact)))
    (ok (string= "foo" (runtime-vocab-fact-name fact)))
    (ok (string= "CL-USER" (runtime-vocab-fact-package fact)))
    (ok (string= "code-describe" (runtime-vocab-fact-via-tool fact)))
    (ok (integerp (runtime-vocab-fact-probed-at fact)))))

(deftest make-runtime-vocab-fact-rejects-unknown-kind
  (ok (handler-case
          (progn
            (make-runtime-vocab-fact :kind :goblin :name "x" :via-tool "t")
            nil)
        (error () t))))

(deftest make-runtime-vocab-fact-rejects-empty-name
  (ok (handler-case
          (progn
            (make-runtime-vocab-fact :kind :function :name "" :via-tool "t")
            nil)
        (error () t))))

(deftest make-runtime-vocab-fact-rejects-empty-via-tool
  (ok (handler-case
          (progn
            (make-runtime-vocab-fact :kind :function :name "x" :via-tool "")
            nil)
        (error () t))))

(deftest supported-kinds-cover-spec
  ;; docs/context-management.md §3.4: package, exported/internal symbols,
  ;; functions, generic functions, methods, classes, macros, conditions,
  ;; ASDF systems, test systems. We collapse to a flat keyword set.
  (dolist (k '(:package :symbol :function :generic-function :method
               :class :macro :condition :asdf-system))
    (ok (member k +supported-runtime-vocab-kinds+) (format nil "~A" k))))

(deftest stale-p-returns-nil-when-no-source-file
  (let ((fact (make-runtime-vocab-fact
               :kind :function :name "foo" :via-tool "code-describe")))
    (ok (null (runtime-vocab-fact-stale-p fact)))))

(deftest stale-p-returns-t-when-source-file-mtime-exceeds-probed-at
  (let* ((path (uiop:tmpize-pathname
                (merge-pathnames "rv-stale-test.lisp"
                                 (uiop:default-temporary-directory))))
         (fact nil))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output
                                   :if-does-not-exist :create
                                   :if-exists :supersede)
             (format s ";; placeholder~%"))
           (setf fact (make-runtime-vocab-fact
                       :kind :function :name "foo"
                       :source-file path
                       :probed-at 100
                       :via-tool "code-describe"))
           (ok (runtime-vocab-fact-stale-p fact)))
      (when (probe-file path) (delete-file path)))))

(deftest stale-p-returns-nil-when-source-file-mtime-is-fresh
  (let* ((path (uiop:tmpize-pathname
                (merge-pathnames "rv-fresh-test.lisp"
                                 (uiop:default-temporary-directory))))
         (fact nil))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output
                                   :if-does-not-exist :create
                                   :if-exists :supersede)
             (format s ";; placeholder~%"))
           (setf fact (make-runtime-vocab-fact
                       :kind :function :name "foo"
                       :source-file path
                       :probed-at (file-write-date path)
                       :via-tool "code-describe"))
           (ok (null (runtime-vocab-fact-stale-p fact))))
      (when (probe-file path) (delete-file path)))))
```

### Step 2: Wire test system

Edit `cl-harness.asd`:

```lisp
;; In the cl-harness/tests :depends-on list, add (alphabetic order
;; suggested but not enforced; place near other context-management tests):
"cl-harness/tests/runtime-vocabulary-test"
```

### Step 3: Run tests — expect FAIL with package-not-found

Run via cl-mcp `run-tests` `{"system": "cl-harness/tests"}`. Expected: failure noting `cl-harness/src/runtime-vocabulary` package does not exist.

### Step 4: Implement `src/runtime-vocabulary.lisp`

```lisp
;;;; src/runtime-vocabulary.lisp
;;;;
;;;; Phase G of the context-management refactor
;;;; (docs/context-management.md §3.4). One runtime-vocab-fact records
;;;; that the agent (or the orchestrator) probed a particular runtime
;;;; vocabulary item — a function, class, package, ASDF system, etc. —
;;;; at a particular point in time. Captures :PROBED-AT so later
;;;; verification can detect that the underlying source has shifted
;;;; since the probe (Phase F's render-time staleness pattern,
;;;; extended to runtime introspection).
;;;;
;;;; Phase G only RECORDS runtime-vocab-facts. Phase H may consume
;;;; them as the source of truth for "what packages exist"; Phase I
;;;; may aggregate them into project-summary text.

(defpackage #:cl-harness/src/runtime-vocabulary
  (:use #:cl)
  (:export #:runtime-vocab-fact
           #:make-runtime-vocab-fact
           #:runtime-vocab-fact-kind
           #:runtime-vocab-fact-name
           #:runtime-vocab-fact-package
           #:runtime-vocab-fact-source-file
           #:runtime-vocab-fact-summary
           #:runtime-vocab-fact-via-tool
           #:runtime-vocab-fact-probed-at
           #:runtime-vocab-fact-related-step-index
           #:runtime-vocab-fact-stale-p
           #:+supported-runtime-vocab-kinds+))

(in-package #:cl-harness/src/runtime-vocabulary)

(defparameter +supported-runtime-vocab-kinds+
  '(:package :symbol :function :generic-function :method
    :class :macro :condition :asdf-system)
  "Kinds of runtime vocabulary items a fact can describe. Mirrors the
list in docs/context-management.md §3.4. :SYMBOL is the catch-all
for plain bound symbols (parameters, constants, etc.) that aren't
function-shaped. :ASDF-SYSTEM covers both primary and test systems.")

(defclass runtime-vocab-fact ()
  ((kind :initarg :kind :reader runtime-vocab-fact-kind
         :documentation "One of +SUPPORTED-RUNTIME-VOCAB-KINDS+.")
   (name :initarg :name :reader runtime-vocab-fact-name
         :documentation "The vocabulary item's name as a string. For
:METHOD this is typically the generic-function name plus
specializers, e.g. \"print-object ((x my-class) stream)\". Required,
non-empty.")
   (package :initarg :package :reader runtime-vocab-fact-package
            :initform nil
            :documentation "Package name string, when applicable. NIL
for :ASDF-SYSTEM and for items the probe didn't resolve a package
for.")
   (source-file :initarg :source-file
                :reader runtime-vocab-fact-source-file
                :initform nil
                :documentation "Pathname of the file the runtime
attributes the definition to (e.g. via SOURCE-LOCATION /
SB-INTROSPECT:FIND-DEFINITION-SOURCE), or NIL when the runtime
declined to report a source. Used by RUNTIME-VOCAB-FACT-STALE-P.")
   (summary :initarg :summary :reader runtime-vocab-fact-summary
            :initform nil
            :documentation "A short description string captured from
the probe — typically the first line of (describe ...) output, the
class precedence list, or the function's lambda-list signature.
Optional; the formatter is defensive against NIL.")
   (via-tool :initarg :via-tool :reader runtime-vocab-fact-via-tool
             :documentation "Name of the cl-mcp tool that produced the
probe data (e.g. \"code-find\", \"code-describe\",
\"code-find-references\", \"repl-eval\"). Required, non-empty.")
   (probed-at :initarg :probed-at :reader runtime-vocab-fact-probed-at
              :documentation "GET-UNIVERSAL-TIME at the moment of
record. Always populated by MAKE-RUNTIME-VOCAB-FACT.")
   (related-step-index :initarg :related-step-index
                       :reader runtime-vocab-fact-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the active
step, or NIL outside a develop run."))
  (:documentation
   "One observation that a particular runtime vocabulary item was
probed at a particular time, with the source file (when known)
captured for staleness checks."))

(defun make-runtime-vocab-fact (&key kind name via-tool
                                  package source-file summary
                                  related-step-index
                                  (probed-at (get-universal-time)))
  "Construct a RUNTIME-VOCAB-FACT. KIND must be a member of
+SUPPORTED-RUNTIME-VOCAB-KINDS+. NAME and VIA-TOOL must be non-empty
strings. SOURCE-FILE is coerced from string to pathname when supplied.
PACKAGE / SUMMARY default to NIL and are validated when supplied."
  (unless (member kind +supported-runtime-vocab-kinds+)
    (error "runtime-vocab-fact: unsupported :kind ~S; expected one of ~S"
           kind +supported-runtime-vocab-kinds+))
  (unless (and (stringp name) (plusp (length name)))
    (error "runtime-vocab-fact: :name must be a non-empty string, got ~S"
           name))
  (unless (and (stringp via-tool) (plusp (length via-tool)))
    (error "runtime-vocab-fact: :via-tool must be a non-empty string, got ~S"
           via-tool))
  (when package (check-type package string))
  (when summary (check-type summary string))
  (when related-step-index (check-type related-step-index integer))
  (let ((coerced-source-file
          (cond
            ((null source-file) nil)
            ((pathnamep source-file) source-file)
            ((stringp source-file) (pathname source-file))
            (t (error "runtime-vocab-fact: :source-file must be a ~
pathname, string, or NIL; got ~S" source-file)))))
    (make-instance 'runtime-vocab-fact
                   :kind kind
                   :name name
                   :package package
                   :source-file coerced-source-file
                   :summary summary
                   :via-tool via-tool
                   :probed-at probed-at
                   :related-step-index related-step-index)))

(defun runtime-vocab-fact-stale-p (fact)
  "Return T when FACT's recorded source-file has been modified since
the probe (i.e. (file-write-date source-file) > probed-at). Returns
NIL when the fact has no recorded source-file, when the file no
longer exists, or when the file's mtime equals or precedes
probed-at. Mirrors the SOURCE-FACT-STALE-P predicate (Phase E/F)."
  (let ((source-file (runtime-vocab-fact-source-file fact))
        (probed-at (runtime-vocab-fact-probed-at fact)))
    (and source-file probed-at
         (let ((current (handler-case (file-write-date source-file)
                          (error () nil))))
           (and current (> current probed-at))))))
```

### Step 5: Re-run tests — expect PASS

Via cl-mcp `run-tests` `{"system": "cl-harness/tests"}`. The 8 new deftests should pass; existing suite remains green (no regressions).

### Step 6: Commit

```
git add src/runtime-vocabulary.lisp \
        tests/runtime-vocabulary-test.lisp \
        cl-harness.asd
git commit -m "feat: runtime-vocab-fact record class (Phase G)"
```

---

## Task 2: `runtime-vocabulary` slot on `develop-state`

**Files:**
- Modify: `src/state.lisp`
- Modify: `tests/state-test.lisp`

### Step 1: Add failing tests in `tests/state-test.lisp`

Append:

```lisp
(deftest develop-state-records-runtime-vocab-facts-in-order
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (f1 (cl-harness/src/runtime-vocabulary:make-runtime-vocab-fact
             :kind :function :name "f1" :via-tool "code-describe"))
        (f2 (cl-harness/src/runtime-vocabulary:make-runtime-vocab-fact
             :kind :function :name "f2" :via-tool "code-describe")))
    (cl-harness/src/state:develop-state-record-runtime-vocab-fact s f1)
    (cl-harness/src/state:develop-state-record-runtime-vocab-fact s f2)
    (let ((facts (cl-harness/src/state:develop-state-runtime-vocabulary s)))
      (ok (= 2 (length facts)))
      (ok (string= "f1"
                   (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-name
                    (first facts))))
      (ok (string= "f2"
                   (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-name
                    (second facts)))))))

(deftest develop-state-runtime-vocabulary-defaults-to-empty
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests")))
    (ok (null (cl-harness/src/state:develop-state-runtime-vocabulary s)))))
```

Add the corresponding `:import-from #:cl-harness/src/runtime-vocabulary` clause if the test package doesn't already import it. (Check: tests run in their own packages; the test package may need `make-runtime-vocab-fact` and `runtime-vocab-fact-name` accessible.)

### Step 2: Run — expect FAIL on `develop-state-record-runtime-vocab-fact` undefined

### Step 3: Extend `src/state.lisp`

In the `defpackage` `:export` list (state.lisp:17), append:

```lisp
#:develop-state-runtime-vocabulary
#:develop-state-record-runtime-vocab-fact
```

In the `defclass develop-state` slots block, after the `failure-ledger` slot (state.lisp:127-131), add:

```lisp
   (runtime-vocabulary :initform nil :accessor %runtime-vocabulary
                       :documentation "Reverse-chronological list of
RUNTIME-VOCAB-FACT instances captured by the agent loop's runtime
introspection probes (cl-mcp code-find / code-describe /
code-find-references results). Internal; public reader is
DEVELOP-STATE-RUNTIME-VOCABULARY.")
```

After `develop-state-record-failure` (around state.lisp:220), add:

```lisp
(defun develop-state-record-runtime-vocab-fact (state fact)
  "Push FACT onto STATE's runtime-vocabulary list. Returns STATE."
  (push fact (%runtime-vocabulary state))
  state)

(defun develop-state-runtime-vocabulary (state)
  "Return STATE's recorded runtime-vocab-facts in observation order
(oldest first)."
  (reverse (%runtime-vocabulary state)))
```

### Step 4: Run — expect PASS

Via cl-mcp `run-tests`. State tests should pass; full suite stays green.

### Step 5: Commit

```
git add src/state.lisp tests/state-test.lisp
git commit -m "feat: develop-state runtime-vocabulary slot (Phase G)"
```

---

## Task 3: Context-view consumes runtime-vocabulary

**Files:**
- Modify: `src/context-view.lisp`
- Modify: `tests/context-view-test.lisp`

### Step 1: Failing tests in `tests/context-view-test.lisp`

Append three deftests:

```lisp
(deftest exploration-formatter-renders-runtime-vocab-bullet
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/p"
             :system "x" :test-system "x/tests"))
         (step (cl-harness/src/planner:make-plan-step
                :index 0 :test-name "t" :test-source "(deftest t)"
                :issue "explore the failure mode")))
    (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
    (setf (cl-harness/src/state:develop-state-current-step-index s) 0)
    (cl-harness/src/state:develop-state-record-runtime-vocab-fact
     s (cl-harness/src/runtime-vocabulary:make-runtime-vocab-fact
        :kind :function :name "foo" :package "CL-USER"
        :via-tool "code-describe"
        :related-step-index 0))
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :exploration :step step))
           (str (cl-harness/src/context-view:context-view->string
                 view :exploration)))
      (ok (search "Runtime vocabulary probed in this step" str))
      (ok (search "[function] CL-USER:foo" str)))))

(deftest exploration-formatter-marks-stale-runtime-vocab-fact
  (let* ((path (uiop:tmpize-pathname
                (merge-pathnames "rv-cv-stale.lisp"
                                 (uiop:default-temporary-directory))))
         (s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/p"
             :system "x" :test-system "x/tests"))
         (step (cl-harness/src/planner:make-plan-step
                :index 0 :test-name "t" :test-source "(deftest t)"
                :issue "explore")))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output
                                     :if-does-not-exist :create
                                     :if-exists :supersede)
             (format out ";; placeholder~%"))
           (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
           (setf (cl-harness/src/state:develop-state-current-step-index s) 0)
           (cl-harness/src/state:develop-state-record-runtime-vocab-fact
            s (cl-harness/src/runtime-vocabulary:make-runtime-vocab-fact
               :kind :function :name "foo"
               :source-file path :probed-at 100
               :via-tool "code-describe"
               :related-step-index 0))
           (let* ((view (cl-harness/src/context-view:make-context-view
                         s :phase :exploration :step step))
                  (str (cl-harness/src/context-view:context-view->string
                        view :exploration)))
             (ok (search "[STALE]" str))))
      (when (probe-file path) (delete-file path)))))

(deftest planning-formatter-emits-runtime-vocab-summary-when-non-empty
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests")))
    (cl-harness/src/state:develop-state-record-runtime-vocab-fact
     s (cl-harness/src/runtime-vocabulary:make-runtime-vocab-fact
        :kind :package :name "CL-USER" :via-tool "code-find"))
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :planning))
           (str (cl-harness/src/context-view:context-view->string
                 view :planning)))
      (ok (search "Runtime vocabulary observed so far" str))
      (ok (search "[package] CL-USER" str)))))

(deftest planning-formatter-omits-runtime-vocab-section-when-empty
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/p"
             :system "x" :test-system "x/tests"))
         (view (cl-harness/src/context-view:make-context-view
                s :phase :planning))
         (str (cl-harness/src/context-view:context-view->string
               view :planning)))
    (ok (null (search "Runtime vocabulary observed so far" str)))))
```

### Step 2: Run — expect FAIL

### Step 3: Extend `src/context-view.lisp`

In the `defpackage`'s `:import-from #:cl-harness/src/state` clause (lines 16-23), append:

```lisp
#:develop-state-runtime-vocabulary
```

Add a new `:import-from` clause:

```lisp
(:import-from #:cl-harness/src/runtime-vocabulary
              #:runtime-vocab-fact-kind
              #:runtime-vocab-fact-name
              #:runtime-vocab-fact-package
              #:runtime-vocab-fact-related-step-index
              #:runtime-vocab-fact-stale-p)
```

In `:export`, append:

```lisp
#:context-view-relevant-runtime-vocab
#:context-view-runtime-vocab
```

Add two new slots to `defclass context-view` (after `active-failures`):

```lisp
(relevant-runtime-vocab :initarg :relevant-runtime-vocab :initform nil
                        :reader context-view-relevant-runtime-vocab
                        :documentation "RUNTIME-VOCAB-FACTs filtered
to the current step. Populated for :EXPLORATION.")
(runtime-vocab :initarg :runtime-vocab :initform nil
               :reader context-view-runtime-vocab
               :documentation "Full RUNTIME-VOCAB-FACT list — all
observations across the run, oldest-first. Populated for :PLANNING
so the planner sees what the agent has already probed (warm-start
context). NIL when the develop-state has no runtime-vocabulary.")
```

Add a filter helper after `%filter-patch-records`:

```lisp
(defun %filter-runtime-vocab (state step-index)
  (and step-index
       (remove-if-not
        (lambda (f) (%related-to-step-p
                     f step-index #'runtime-vocab-fact-related-step-index))
        (develop-state-runtime-vocabulary state))))
```

In `make-context-view`'s `:planning` branch, add:

```lisp
:runtime-vocab (and state (develop-state-runtime-vocabulary state))
```

In the `:exploration` branch, add:

```lisp
:relevant-runtime-vocab (%filter-runtime-vocab state step-index)
```

In the `:exploration` formatter (after the source-facts bullet block), append:

```lisp
(let ((vocab (context-view-relevant-runtime-vocab view)))
  (when vocab
    (format s "~%## Runtime vocabulary probed in this step~%")
    (dolist (fact vocab)
      (format s "- ~A[~(~A~)] ~A~A~%"
              (if (runtime-vocab-fact-stale-p fact) "[STALE] " "")
              (runtime-vocab-fact-kind fact)
              (if (runtime-vocab-fact-package fact)
                  (format nil "~A:" (runtime-vocab-fact-package fact))
                  "")
              (runtime-vocab-fact-name fact)))))
```

In the `:planning` formatter, after the existing failure-context block, append:

```lisp
(let ((vocab (context-view-runtime-vocab view)))
  (when vocab
    (format s "~%## Runtime vocabulary observed so far~%")
    (dolist (fact vocab)
      (format s "- [~(~A~)] ~A~A~%"
              (runtime-vocab-fact-kind fact)
              (if (runtime-vocab-fact-package fact)
                  (format nil "~A:" (runtime-vocab-fact-package fact))
                  "")
              (runtime-vocab-fact-name fact)))))
```

### Step 4: Run — expect PASS (4 new context-view tests + existing tests stay green)

### Step 5: Commit

```
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "feat: runtime-vocab in :exploration / :planning context views (Phase G)"
```

---

## Task 4: Agent-loop recorder hooks

**Files:**
- Modify: `src/agent.lisp`
- Modify: `tests/agent-test.lisp`

The agent loop already records source-facts on successful read tools (agent.lisp:870-891) and patch-records on successful write tools (agent.lisp:902-931). Phase G adds a third hook for runtime-introspection tools whose results contain enough shape to extract a vocabulary fact: `code-find`, `code-describe`, `code-find-references`. (The `repl-eval` hook is intentionally **deferred** — its output is freeform Lisp text that needs an `(describe ...)`-aware parser; we'll add it in a Phase G follow-up if usage shows it's necessary.)

### Step 1: Failing tests in `tests/agent-test.lisp`

Add the following deftests (find a section near the existing source-fact recorder tests for placement; look for patterns like `agent-records-source-fact-on-...`):

```lisp
(deftest agent-records-runtime-vocab-fact-on-code-describe-success
  ;; This test runs the recorder logic in isolation by simulating the
  ;; tool-result handling path. It does not require a live MCP client.
  (let* ((state (cl-harness/src/state:make-develop-state
                 :goal "g" :project-root "/tmp/p"
                 :system "x" :test-system "x/tests"))
         (result (alexandria:plist-hash-table
                  (list "kind" "function"
                        "name" "foo"
                        "package" "CL-USER"
                        "summary" "(foo x) -> integer")
                  :test 'equal))
         (fact (cl-harness/src/agent::%vocab-fact-from-tool-result
                "code-describe" result :related-step-index 3)))
    (ok (typep fact 'cl-harness/src/runtime-vocabulary:runtime-vocab-fact))
    (ok (eq :function
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind fact)))
    (ok (string= "foo"
                 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-name
                  fact)))
    (ok (string= "CL-USER"
                 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-package
                  fact)))
    (ok (eql 3 (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-related-step-index
                fact)))
    (declare (ignore state))))

(deftest agent-records-runtime-vocab-fact-skips-on-isError
  (let* ((result (alexandria:plist-hash-table
                  (list "isError" t "kind" "function" "name" "foo")
                  :test 'equal))
         (fact (cl-harness/src/agent::%vocab-fact-from-tool-result
                "code-describe" result)))
    (ok (null fact))))

(deftest agent-records-runtime-vocab-fact-skips-on-missing-name
  (let* ((result (alexandria:plist-hash-table
                  (list "kind" "function") :test 'equal))
         (fact (cl-harness/src/agent::%vocab-fact-from-tool-result
                "code-describe" result)))
    (ok (null fact))))

(deftest agent-records-runtime-vocab-fact-on-code-find-list-result
  ;; code-find returns a list-shaped result with multiple entries;
  ;; the helper should record one fact per entry.
  (let* ((result (alexandria:plist-hash-table
                  (list "results"
                        (list (alexandria:plist-hash-table
                               (list "kind" "function" "name" "f1"
                                     "package" "P")
                               :test 'equal)
                              (alexandria:plist-hash-table
                               (list "kind" "class" "name" "C1"
                                     "package" "P")
                               :test 'equal)))
                  :test 'equal))
         (facts (cl-harness/src/agent::%vocab-facts-from-tool-result
                 "code-find" result)))
    (ok (= 2 (length facts)))
    (ok (eq :function
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind
             (first facts))))
    (ok (eq :class
            (cl-harness/src/runtime-vocabulary:runtime-vocab-fact-kind
             (second facts))))))
```

### Step 2: Run — expect FAIL on `%vocab-fact-from-tool-result` / `%vocab-facts-from-tool-result` undefined

### Step 3: Add the recorder helpers + integrate

In `src/agent.lisp`'s `defpackage` (find the `:import-from` block near top), add:

```lisp
(:import-from #:cl-harness/src/runtime-vocabulary
              #:make-runtime-vocab-fact
              #:runtime-vocab-fact)
```

And extend the existing `:import-from #:cl-harness/src/state` clause with `#:develop-state-record-runtime-vocab-fact`.

Add two private helpers (place them near the existing `%read-file-safely` / `%compute-unified-diff` helpers — search for those and add adjacently):

```lisp
(defun %vocab-kind-from-string (kind-string)
  "Coerce a string like \"function\" into a keyword from
+SUPPORTED-RUNTIME-VOCAB-KINDS+, or NIL when the string isn't a
recognised kind. Defensive: tool results from cl-mcp are JSON-shaped,
so kinds arrive as lower-case strings."
  (let ((normalized
          (and (stringp kind-string)
               (intern (string-upcase
                        (substitute #\- #\_ kind-string))
                       :keyword))))
    (when (member normalized
                  cl-harness/src/runtime-vocabulary:+supported-runtime-vocab-kinds+)
      normalized)))

(defun %vocab-fact-from-tool-result (tool result &key related-step-index)
  "Try to extract a single RUNTIME-VOCAB-FACT from a tool RESULT
hash-table (cl-mcp's structured output). Returns NIL when the result
shape doesn't match (missing name, error flag set, unknown kind).
Best-effort: never raises."
  (when (and (hash-table-p result)
             (not (gethash \"isError\" result)))
    (let ((kind-string (gethash \"kind\" result))
          (name (gethash \"name\" result))
          (package (gethash \"package\" result))
          (source-file (gethash \"source_file\" result))
          (summary (gethash \"summary\" result)))
      (let ((kind (%vocab-kind-from-string kind-string)))
        (when (and kind (stringp name) (plusp (length name)))
          (handler-case
              (make-runtime-vocab-fact
               :kind kind
               :name name
               :package (and (stringp package) package)
               :source-file (and (stringp source-file) source-file)
               :summary (and (stringp summary) summary)
               :via-tool tool
               :related-step-index related-step-index)
            (error () nil)))))))

(defun %vocab-facts-from-tool-result (tool result &key related-step-index)
  "List variant: code-find returns a {\"results\": [...]} shape.
Returns a list of facts (possibly empty); never raises. Falls back to
%VOCAB-FACT-FROM-TOOL-RESULT when the result has no list section."
  (when (and (hash-table-p result)
             (not (gethash \"isError\" result)))
    (let ((entries (gethash \"results\" result)))
      (cond
        ((listp entries)
         (loop for entry in entries
               for fact = (and (hash-table-p entry)
                               (%vocab-fact-from-tool-result
                                tool entry
                                :related-step-index related-step-index))
               when fact collect fact))
        (t
         (let ((single (%vocab-fact-from-tool-result
                        tool result
                        :related-step-index related-step-index)))
           (and single (list single))))))))
```

> **Note on string escaping:** the `\"isError\"` literals above are how the doc renders quotes inside a fenced block. In the actual `.lisp` file write `"isError"` (no backslash). Same for every other quoted string in this snippet.

In the agent loop's tool-call result handling (agent.lisp around line 870), after the existing source-fact recorder block but before the `cond` for source-mutating tools, add:

```lisp
(when (and (agent-state-develop-state state)
           (not (and (gethash "isError" result) t))
           (member tool '("code-describe" "code-find"
                          "code-find-references")
                   :test #'string=))
  (let ((facts (%vocab-facts-from-tool-result
                tool result :related-step-index nil)))
    (dolist (fact facts)
      (develop-state-record-runtime-vocab-fact
       (agent-state-develop-state state) fact))))
```

(`:related-step-index nil` mirrors the source-fact recorder for now; orchestrator-side step-index threading is a known gap shared with source-fact / patch-record and tracked separately.)

### Step 4: Run — expect PASS

### Step 5: Commit

```
git add src/agent.lisp tests/agent-test.lisp
git commit -m "feat: agent loop records runtime-vocab-facts from code-* tool results (Phase G)"
```

---

## Task 5: Lint + force-compile + regression sweep

### Step 1: Mallet on the new + modified files

```bash
mallet src/runtime-vocabulary.lisp src/state.lisp src/context-view.lisp src/agent.lisp \
       tests/runtime-vocabulary-test.lisp tests/state-test.lisp \
       tests/context-view-test.lisp tests/agent-test.lisp
```

Address warnings (typically `needless-let*` from single-binding `let*` blocks). Demote to `let`. If anything else fires, fix at the root rather than suppressing.

### Step 2: Force-compile via cl-mcp

`repl-eval` `(asdf:compile-system :cl-harness :force t)`. Expected: 0 errors, 0 warnings beyond the pre-existing baseline.

### Step 3: Full test sweep

`run-tests` `{"system": "cl-harness/tests"}`. Expected: existing count (286) + new tests (8 in runtime-vocabulary-test, 2 in state-test, 4 in context-view-test, 4 in agent-test = 18 new) → **304 total, 0 failures** (modulo the 5 develop-bench-test failures that are pre-existing on main and unrelated).

Shell `rove cl-harness.asd` should match.

### Step 4: Commit any lint fixups

```
git add -p   # only the lint hits, no behavioural drift
git commit -m "style: address mallet feedback on Phase G files"
```

---

## Task 6: Docs annotation + final review + merge

### Step 1: Update `docs/context-management.md` §14

Mark Phase G landed. The §14 table currently has Phase F as the last entry. Append:

```markdown
| G | runtime-vocabulary ledger (`runtime-vocab-fact` + `develop-state-runtime-vocabulary`) wired into `:exploration` and `:planning` views; agent loop records facts from `code-find` / `code-describe` / `code-find-references` results | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-g-runtime-vocabulary.md` |
```

Update the trailing prose: §3.4 (Runtime Vocabulary) is now addressed for the symbol-level facts the agent observes via cl-mcp introspection tools. The B' row from §14 should be removed (Phase G subsumes it). Image-walking / proactive enumeration remains deferred.

### Step 2: Final code review

Dispatch `superpowers:code-reviewer` over the entire `phase-g-runtime-vocabulary` branch. Checklist:
- Constructor / record class match `source-fact` / `patch-record` shape (consistency).
- No `:local-nicknames` anywhere.
- Recorder helpers are best-effort (never raise on malformed tool input).
- Test fixtures use `unwind-protect` for temp-file cleanup.
- `:planning` view formatter is byte-identical when runtime-vocab is empty.
- mallet clean, force-compile clean.
- No new symbols re-exported from `src/main` (Phase G keeps them internal).

### Step 3: Merge to main

`superpowers:finishing-a-development-branch`, `--no-ff` merge with summary highlighting:
- New `runtime-vocab-fact` record + `develop-state` slot + recorder.
- Agent-loop hooks for `code-find` / `code-describe` / `code-find-references`.
- `:exploration` view bullets with `[STALE]` annotation (Phase F pattern extended).
- `:planning` view warm-start summary alongside (not replacing) project-inventory.
- `repl-eval` parser + image-walking deferred.

---

## Verification checklist (before opening a PR)

- [ ] `make-runtime-vocab-fact` validates `:kind`, `:name`, `:via-tool` strictly.
- [ ] `runtime-vocab-fact-stale-p` returns NIL when no `:source-file`, T when mtime exceeds `:probed-at`, NIL when fresh.
- [ ] `develop-state-runtime-vocabulary` returns oldest-first.
- [ ] `:exploration` view shows `[kind] PKG:name` bullets, prefixed `[STALE] ` when stale.
- [ ] `:planning` view shows runtime-vocab summary block ONLY when slot is non-empty.
- [ ] `:planning` byte-identical to current behaviour when slot is empty.
- [ ] Agent loop recorder skips on `isError`, missing name, unknown kind.
- [ ] `code-find` list-shaped results produce one fact per entry.
- [ ] No regression in existing 286 deftests.
- [ ] mallet clean on touched files.
- [ ] force-compile clean.
- [ ] No new `:local-nicknames`.
- [ ] No new re-exports from `src/main`.
- [ ] §14 docs updated.

---

## Acceptance criteria

Phase G is complete when:

1. `runtime-vocab-fact` + recorder + slot land and are consumed by `:exploration` view.
2. `:planning` view augments (does not replace) the existing project-inventory text block.
3. The agent loop captures vocab facts opportunistically from existing cl-mcp tool calls without adding new tool calls.
4. `[STALE]` annotation works on runtime-vocab facts via `runtime-vocab-fact-stale-p` (Phase F pattern).
5. Test count grows by 18 (`run-tests cl-harness/tests` reports 304 / 0 failures).
6. mallet and force-compile are clean on all touched files.
7. `docs/context-management.md` §14 marks Phase G landed.
