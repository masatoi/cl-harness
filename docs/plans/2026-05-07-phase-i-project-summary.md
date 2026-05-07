# Phase I — Project Summary Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Promote the cold-start project inventory to a **structured `project-summary` slot** on `develop-state` that the planner consumes through the existing `:planning` context view, **with explicit invalidation** when patches touch `.asd` or `defpackage` forms. The slot can be updated mid-run rather than being baked in at construction time.

**Architecture:**
- **New module** `src/project-summary.lisp`: a record class `project-summary` carrying the structured equivalents of the four sections `gather-project-inventory` builds today (header, ASDF systems, source files, test files) plus a `:gathered-at` timestamp and a `:dirty-p` flag.
- **New slot** `project-summary` on `develop-state` (separate from the existing free-text `project-inventory` slot). Recorder helper plus a `develop-state-mark-project-summary-dirty` flipper.
- **Helper** `gather-project-summary` in the same package as `project-summary` that wraps the existing `gather-project-inventory` text into a `project-summary` instance — Phase I keeps the reader path identical (UIOP, no MCP) but replaces the consumer-facing data shape with a record.
- **Orchestrator hook**: when a patch lands whose path matches `*.asd` or whose form-type is `defpackage`, the post-patch hook flips the slot's `:dirty-p` flag. A subsequent planner round (replan) calls `gather-project-summary` to refresh.
- **`:planning` view** shows the structured summary (with a `[STALE]` annotation when `:dirty-p` is T) **alongside** the existing `project-inventory` text. Both can be present; the formatter emits whichever is non-empty. When both are present, the structured summary appears first.

**Tech Stack:** SBCL / ASDF `:package-inferred-system` / Rove tests / alexandria / `:import-from` + `:export` only (no `:local-nicknames`).

---

## Why this phase

`docs/context-management.md` §3.3 (Project Context) requires:
- One-time investigation summary that's reusable.
- Update on patch.
- Stale detection / re-investigation.

Today's `inventory.lisp` provides only point (1) — a one-shot text block. Phases B and F gave us the staleness pattern (mtime-based predicates, `[STALE]` render-time annotation); Phase I generalises it for the project-level summary so the planner sees an aged-out summary as aged-out instead of planning against silent staleness.

This phase is deliberately small: it's a single new slot + a structural wrapping of an existing text builder + an invalidation hook. No re-architecture of `inventory.lisp`. No new tool. No new model calls.

---

## Design contract

1. **Two slots, not a replacement.** `project-inventory` (free text, today's behaviour) keeps its semantics for the cold-start path; `project-summary` (structured, Phase I) is the new layer. Callers can populate either or both.
2. **Reader path stays UIOP-only.** `gather-project-summary` calls into `gather-project-inventory` for the text fragments and wraps them. We do NOT promote it to MCP-driven reads.
3. **Dirty flag is a one-way flip.** `mark-project-summary-dirty` sets `:dirty-p` to T; refresh is a fresh `gather-project-summary` call that replaces the slot. We don't track partial dirtiness per file.
4. **Orchestrator hook is conservative.** The hook fires only on patches whose `:path` matches `*.asd` (case-insensitive) **or** whose `:form-type` is `"defpackage"`. Other patches don't invalidate the summary (they may invalidate source-facts via Phase F, but that's unrelated).
5. **No re-export from `src/main`** until at least one external caller asks for it.
6. **`gather-project-inventory` remains backward-compatible.** Phase I does not modify its signature or behaviour. The wrapping happens in the new module.

---

## Files touched

| Path | Action |
|---|---|
| `src/project-summary.lisp` | **Create** — record class, constructor, `gather-project-summary` wrapper |
| `src/state.lisp` | Modify — `project-summary` slot + recorder + dirty flipper |
| `src/orchestrator.lisp` | Modify — post-patch hook flips dirty flag on `.asd` / `defpackage` patches |
| `src/context-view.lisp` | Modify — view slot + `:planning` formatter renders structured summary alongside text inventory |
| `cl-harness.asd` | Modify — extend `cl-harness/tests` deps with `project-summary-test` |
| `tests/project-summary-test.lisp` | **Create** |
| `tests/state-test.lisp` | Modify |
| `tests/orchestrator-test.lisp` | Modify |
| `tests/context-view-test.lisp` | Modify |

---

## Task 1: `project-summary` data module

**Files:**
- Create: `src/project-summary.lisp`
- Create: `tests/project-summary-test.lisp`
- Modify: `cl-harness.asd`

### Step 1: Failing tests

```lisp
;;;; tests/project-summary-test.lisp

(defpackage #:cl-harness/tests/project-summary-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/project-summary
                #:project-summary
                #:make-project-summary
                #:project-summary-project-root
                #:project-summary-system
                #:project-summary-test-system
                #:project-summary-asd-files
                #:project-summary-source-files
                #:project-summary-test-files
                #:project-summary-text
                #:project-summary-gathered-at
                #:project-summary-dirty-p
                #:project-summary-mark-dirty
                #:gather-project-summary))

(in-package #:cl-harness/tests/project-summary-test)

(deftest make-project-summary-records-fields
  (let ((s (make-project-summary
            :project-root "/tmp/p/"
            :system "x"
            :test-system "x/tests"
            :asd-files (list "x.asd")
            :source-files (list "src/main.lisp")
            :test-files (list "tests/main-test.lisp")
            :text "raw inventory text")))
    (ok (typep s 'project-summary))
    (ok (string= "x" (project-summary-system s)))
    (ok (equal '("x.asd") (project-summary-asd-files s)))
    (ok (string= "raw inventory text" (project-summary-text s)))
    (ok (null (project-summary-dirty-p s)))
    (ok (integerp (project-summary-gathered-at s)))))

(deftest mark-dirty-flips-flag
  (let ((s (make-project-summary
            :project-root "/tmp/p/" :system "x" :test-system "x/tests")))
    (ok (null (project-summary-dirty-p s)))
    (project-summary-mark-dirty s)
    (ok (eq t (project-summary-dirty-p s)))))

(deftest mark-dirty-is-idempotent
  (let ((s (make-project-summary
            :project-root "/tmp/p/" :system "x" :test-system "x/tests")))
    (project-summary-mark-dirty s)
    (project-summary-mark-dirty s)
    (ok (eq t (project-summary-dirty-p s)))))

(deftest gather-project-summary-builds-from-real-tree
  ;; Smoke test: run gather-project-summary against the cl-harness
  ;; project itself (we know it has at least one .asd, src/main.lisp,
  ;; and tests/main-test.lisp).
  (let* ((this-root
           (asdf:system-relative-pathname :cl-harness ""))
         (s (gather-project-summary
             :project-root this-root
             :system "cl-harness"
             :test-system "cl-harness/tests")))
    (ok (typep s 'project-summary))
    (ok (member "cl-harness.asd" (project-summary-asd-files s)
                :test #'string=))
    (ok (member "src/main.lisp" (project-summary-source-files s)
                :test #'string=))
    (ok (member "tests/main-test.lisp" (project-summary-test-files s)
                :test #'string=))
    (ok (and (stringp (project-summary-text s))
             (plusp (length (project-summary-text s)))))))
```

Update `cl-harness.asd` test deps with `"cl-harness/tests/project-summary-test"`.

### Step 2: Run — expect FAIL

### Step 3: Implement `src/project-summary.lisp`

```lisp
;;;; src/project-summary.lisp
;;;;
;;;; Phase I of the context-management refactor
;;;; (docs/context-management.md §3.3). One project-summary captures
;;;; the cold-start project context — ASDF systems, source files,
;;;; test files — as a structured record with a dirty flag for
;;;; staleness invalidation.
;;;;
;;;; Phase I wraps the existing GATHER-PROJECT-INVENTORY text builder
;;;; into a record. The reader path stays UIOP-only; the new slot
;;;; gives the planner a place to see staleness (when patches touch
;;;; .asd or defpackage forms).

(defpackage #:cl-harness/src/project-summary
  (:use #:cl)
  (:import-from #:cl-harness/src/inventory
                #:gather-project-inventory)
  (:export #:project-summary
           #:make-project-summary
           #:project-summary-project-root
           #:project-summary-system
           #:project-summary-test-system
           #:project-summary-asd-files
           #:project-summary-source-files
           #:project-summary-test-files
           #:project-summary-text
           #:project-summary-gathered-at
           #:project-summary-dirty-p
           #:project-summary-mark-dirty
           #:gather-project-summary))

(in-package #:cl-harness/src/project-summary)

(defclass project-summary ()
  ((project-root :initarg :project-root
                 :reader project-summary-project-root)
   (system :initarg :system :reader project-summary-system)
   (test-system :initarg :test-system :reader project-summary-test-system)
   (asd-files :initarg :asd-files :initform nil
              :reader project-summary-asd-files
              :documentation "List of relative pathname strings for
*.asd files at PROJECT-ROOT.")
   (source-files :initarg :source-files :initform nil
                 :reader project-summary-source-files
                 :documentation "List of relative pathname strings
for src/*.lisp.")
   (test-files :initarg :test-files :initform nil
               :reader project-summary-test-files
               :documentation "List of relative pathname strings for
tests/*.lisp.")
   (text :initarg :text :initform ""
         :reader project-summary-text
         :documentation "The free-text inventory string from
GATHER-PROJECT-INVENTORY, kept verbatim for the planner's
:project-inventory fallback path.")
   (gathered-at :initarg :gathered-at
                :reader project-summary-gathered-at
                :documentation "GET-UNIVERSAL-TIME at the moment of
gather.")
   (dirty-p :initform nil :reader project-summary-dirty-p
            :documentation "T after a patch has touched a .asd or
defpackage form since the gather. NIL until then. Flipped via
PROJECT-SUMMARY-MARK-DIRTY."))
  (:documentation
   "Structured cold-start project context. Replaces (does not
remove) the free-text :project-inventory slot for callers that need
staleness tracking and per-file lists."))

(defun make-project-summary (&key project-root system test-system
                               asd-files source-files test-files
                               (text "")
                               (gathered-at (get-universal-time)))
  "Construct a PROJECT-SUMMARY. PROJECT-ROOT is coerced to a pathname.
SYSTEM and TEST-SYSTEM are required strings. The three file lists
default to NIL and must be lists of strings when non-NIL."
  (check-type system string)
  (check-type test-system string)
  (check-type text string)
  (let ((coerced-root (cond
                        ((pathnamep project-root) project-root)
                        ((stringp project-root)
                         (uiop:ensure-directory-pathname project-root))
                        (t (error "project-summary: :project-root must be ~
a pathname or string, got ~S" project-root)))))
    (dolist (entry asd-files) (check-type entry string))
    (dolist (entry source-files) (check-type entry string))
    (dolist (entry test-files) (check-type entry string))
    (make-instance 'project-summary
                   :project-root coerced-root
                   :system system
                   :test-system test-system
                   :asd-files asd-files
                   :source-files source-files
                   :test-files test-files
                   :text text
                   :gathered-at gathered-at)))

(defun project-summary-mark-dirty (summary)
  "Set SUMMARY's dirty-p flag to T. Idempotent. Returns SUMMARY."
  (setf (slot-value summary 'dirty-p) t)
  summary)

(defun %list-relative (root subdir extension)
  (let ((dir (merge-pathnames subdir
                              (uiop:ensure-directory-pathname root))))
    (when (uiop:directory-exists-p dir)
      (sort (loop for path in (directory (merge-pathnames extension dir))
                  collect (let* ((root-ns (namestring
                                           (uiop:ensure-directory-pathname
                                            root)))
                                 (path-ns (namestring path)))
                            (if (and (>= (length path-ns) (length root-ns))
                                     (string= path-ns root-ns
                                              :end1 (length root-ns)))
                                (subseq path-ns (length root-ns))
                                path-ns)))
            #'string<))))

(defun gather-project-summary (&key project-root system test-system)
  "Build a PROJECT-SUMMARY by enumerating .asd / src / tests files
under PROJECT-ROOT and capturing the existing GATHER-PROJECT-INVENTORY
text. Reader path stays UIOP-only."
  (let ((root (uiop:ensure-directory-pathname project-root)))
    (make-project-summary
     :project-root root
     :system system
     :test-system test-system
     :asd-files (%list-relative root "" "*.asd")
     :source-files (%list-relative root "src/" "*.lisp")
     :test-files (%list-relative root "tests/" "*.lisp")
     :text (gather-project-inventory
            :project-root root :system system :test-system test-system))))
```

### Step 4: Run — expect PASS

### Step 5: Commit

```
git add src/project-summary.lisp tests/project-summary-test.lisp cl-harness.asd
git commit -m "feat: project-summary record + gather-project-summary (Phase I)"
```

---

## Task 2: `project-summary` slot on `develop-state`

**Files:**
- Modify: `src/state.lisp`
- Modify: `tests/state-test.lisp`

### Step 1: Failing tests

```lisp
(deftest develop-state-stores-and-flips-project-summary-dirty
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x" :test-system "x/tests")))
    (cl-harness/src/state:develop-state-set-project-summary s sum)
    (ok (eq sum (cl-harness/src/state:develop-state-project-summary s)))
    (ok (null (cl-harness/src/project-summary:project-summary-dirty-p sum)))
    (cl-harness/src/state:develop-state-mark-project-summary-dirty s)
    (ok (eq t (cl-harness/src/project-summary:project-summary-dirty-p sum)))))

(deftest develop-state-mark-project-summary-dirty-handles-nil-slot
  ;; If the slot is NIL (caller never gathered a summary) the helper
  ;; is a no-op rather than raising.
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests")))
    (cl-harness/src/state:develop-state-mark-project-summary-dirty s)
    (ok (null (cl-harness/src/state:develop-state-project-summary s)))))
```

### Step 2: Implement

In `src/state.lisp`:
- Append `#:develop-state-project-summary`, `#:develop-state-set-project-summary`, `#:develop-state-mark-project-summary-dirty` to `:export`.
- Add slot `(project-summary :initform nil :accessor develop-state-project-summary :documentation "...")` to `defclass`.
- Add helpers:

```lisp
(defun develop-state-set-project-summary (state summary)
  "Replace STATE's project-summary slot with SUMMARY (a
PROJECT-SUMMARY instance, or NIL to clear). Returns STATE."
  (setf (slot-value state 'project-summary) summary)
  state)

(defun develop-state-mark-project-summary-dirty (state)
  "Flip STATE's project-summary dirty flag to T. No-op when the slot
is NIL. Returns STATE."
  (let ((sum (develop-state-project-summary state)))
    (when sum
      (cl-harness/src/project-summary:project-summary-mark-dirty sum)))
  state)
```

(Add the corresponding `:import-from #:cl-harness/src/project-summary` clause.)

### Step 3: Commit

```
git add src/state.lisp tests/state-test.lisp
git commit -m "feat: develop-state project-summary slot + dirty flipper (Phase I)"
```

---

## Task 3: Orchestrator post-patch hook

**Files:**
- Modify: `src/orchestrator.lisp`
- Modify: `tests/orchestrator-test.lisp`

### Step 1: Read the orchestrator's post-patch site

Find where the orchestrator (or the agent loop's post-patch path that flows back into orchestrator state — re-read `src/agent.lisp:902-931` and `src/orchestrator.lisp` step-end) updates the develop-state after a patch lands. The hook needs the patch-record's `:path` and `:form-type`.

### Step 2: Failing tests

```lisp
(deftest orchestrator-marks-summary-dirty-on-asd-patch
  ;; Build develop-state with a project-summary, simulate a patch
  ;; landing whose path is "foo.asd", call the post-patch hook,
  ;; assert summary is marked dirty.
  )

(deftest orchestrator-marks-summary-dirty-on-defpackage-patch
  ;; Patch with form-type "defpackage" -> dirty.
  )

(deftest orchestrator-leaves-summary-clean-on-defun-patch
  ;; Patch with form-type "defun" on an unrelated file -> clean.
  )
```

### Step 3: Implement

Add a helper `%maybe-mark-summary-dirty (state patch-record)` near the orchestrator's post-step section:

```lisp
(defun %asd-path-p (path)
  (let ((ns (and path (namestring path))))
    (and ns (>= (length ns) 4)
         (string-equal ns ".asd" :start1 (- (length ns) 4)))))

(defun %maybe-mark-summary-dirty (state patch-record)
  "Flip STATE's project-summary dirty flag when PATCH-RECORD targets
a .asd file or a defpackage form. Best-effort; never raises.
Returns STATE."
  (when (or (%asd-path-p (patch-record-path patch-record))
            (and (patch-record-form-type patch-record)
                 (string-equal (patch-record-form-type patch-record)
                               "defpackage")))
    (develop-state-mark-project-summary-dirty state))
  state)
```

Wire `%maybe-mark-summary-dirty` into the post-patch path at the same site that already calls `mark-resolved-by` for failures.

### Step 4: Commit

```
git add src/orchestrator.lisp tests/orchestrator-test.lisp
git commit -m "feat: orchestrator marks project-summary dirty on .asd / defpackage patches (Phase I)"
```

---

## Task 4: Context-view consumes project-summary

**Files:**
- Modify: `src/context-view.lisp`
- Modify: `tests/context-view-test.lisp`

### Step 1: Failing tests

```lisp
(deftest planning-formatter-renders-project-summary-when-present
  ;; develop-state with project-summary set -> :planning view shows
  ;; "## Project summary" header and lists asd / source / test files.
  )

(deftest planning-formatter-marks-dirty-summary-as-stale
  ;; Mark summary dirty -> :planning view prefixes header with [STALE].
  )

(deftest planning-formatter-emits-both-summary-and-text-inventory
  ;; develop-state with project-summary AND project-inventory text
  ;; both populated -> structured summary first, then text inventory.
  )

(deftest planning-formatter-omits-summary-section-when-absent
  ;; develop-state with no project-summary -> no "## Project summary"
  ;; section (existing project-inventory rendering unaffected).
  )
```

### Step 2: Implement

In `src/context-view.lisp`:
- Add `:import-from #:cl-harness/src/state #:develop-state-project-summary` and `:import-from #:cl-harness/src/project-summary #:project-summary-asd-files #:project-summary-source-files #:project-summary-test-files #:project-summary-dirty-p`.
- Add slot `project-summary` to `context-view`.
- Populate it in the `:planning` branch of `make-context-view`.
- In the `:planning` formatter, emit a `## Project summary` block before the existing `## Project inventory` block, prefixed `[STALE] ` when `:dirty-p` is T.

### Step 3: Commit

```
git add src/context-view.lisp tests/context-view-test.lisp
git commit -m "feat: project-summary in :planning context view with [STALE] (Phase I)"
```

---

## Task 5: Lint + force-compile + regression sweep

```bash
mallet src/project-summary.lisp src/state.lisp src/orchestrator.lisp \
       src/context-view.lisp \
       tests/project-summary-test.lisp tests/state-test.lisp \
       tests/orchestrator-test.lisp tests/context-view-test.lisp
```

Address warnings, force-compile, full test sweep. Test count grows by ~12-14.

```
git commit -m "style: address mallet feedback on Phase I files"
```

---

## Task 6: Docs annotation + final review + merge

### Step 1: Update §14

```markdown
| I | structured `project-summary` slot on develop-state (`gather-project-summary` wraps the existing inventory builder) wired into `:planning` view; orchestrator marks dirty on `.asd` / defpackage patches; `[STALE]` annotation when dirty | landed (2026-05-XX) | `docs/plans/2026-05-07-phase-i-project-summary.md` |
```

Update trailing prose: §3.3 (Project) is now addressed for the cold-start summary + invalidation. The free-text `project-inventory` slot remains for callers that don't want the structured shape.

### Step 2: Final review + merge

`superpowers:code-reviewer` over the branch. Checklist:
- `gather-project-summary` keeps reader path UIOP-only.
- Dirty hook fires only on `.asd` / `defpackage` patches.
- `:planning` view byte-identical to current behaviour when slot is NIL.
- `:planning` view emits structured summary + text inventory in the right order when both are set.
- mallet clean, force-compile clean.
- No `:local-nicknames`, no new `src/main` re-exports.

`superpowers:finishing-a-development-branch` → `--no-ff` merge.

---

## Verification checklist

- [ ] `make-project-summary` validates types; `gather-project-summary` returns a populated record on the cl-harness tree itself.
- [ ] `project-summary-mark-dirty` is idempotent.
- [ ] `develop-state-mark-project-summary-dirty` is a no-op when slot is NIL.
- [ ] Orchestrator hook fires on `.asd` / `defpackage`, doesn't fire on `defun` etc.
- [ ] `:planning` view renders `## Project summary` only when slot is non-NIL.
- [ ] `[STALE]` prefix on the header when `:dirty-p` is T.
- [ ] Existing `## Project inventory` text rendering still works alongside.
- [ ] No regression in pre-Phase-I test count.
- [ ] mallet clean, force-compile clean.
- [ ] §14 updated.

---

## Acceptance criteria

Phase I is complete when:

1. `project-summary` record + `gather-project-summary` wrapper land.
2. `develop-state` has the new slot + dirty flipper.
3. Orchestrator hook flips dirty on `.asd` / `defpackage` patches.
4. `:planning` view renders structured summary with `[STALE]` annotation when dirty.
5. Free-text `project-inventory` rendering is unchanged.
6. mallet and force-compile clean.
7. §14 marks Phase I landed.
