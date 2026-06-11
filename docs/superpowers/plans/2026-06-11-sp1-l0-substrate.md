# SP1: L0 Substrate (event log + policy pack) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L0 substrate of the autonomous-harness redesign — an append-only JSONL event log (event sourcing) and a versioned, fingerprinted policy pack store — as a new greenfield ASDF system `cl-harness-next` that coexists with the current `cl-harness` without touching it.

**Architecture:** New `:package-inferred-system` rooted at `next/` (`.asd` at repo root for Roswell discovery). Three modules: `event` (immutable event objects + JSON wire format with a fixed coarse type vocabulary), `event-log` (durable append/read/replay over JSONL), `policy-pack` (hardened sexp reader + schema validation + SHA-256 content fingerprint + semver). A facade package `cl-harness-next` re-exports the public API. Spec: `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md` §8.1 (event sourcing), §10.1 (artifact store / policy pack), 原則3「すべての実行は実験である」, 原則4「プロンプト・ポリシー・budget はデータである」.

**Tech Stack:** SBCL, ASDF package-inferred-system, rove, yason (JSON), local-time (timestamps), alexandria, ironclad (SHA-256; **new dependency**), uiop.

**Sub-project context:** This is SP1 of 8 (SP2: L1 environment wrapper, SP3: world model + context compiler, SP4: oracles + governor, SP5: kernel + scripted policy, SP6: guided/self-directed + adaptive dial, SP7: mission layer, SP8: self-improvement loop). Everything later builds on these two primitives, so durability and roundtrip fidelity matter more than features here. YAGNI applies hard: no metrics aggregation, no projections beyond a fold helper, no pack mutation API yet.

**Project conventions that bind this plan** (from `CLAUDE.md`):
- 2-space indent, ≤100 columns, blank line between top-level forms, docstrings on public functions, file starts with `(in-package ...)` right after its `defpackage`.
- **No `:local-nicknames`** (UIOP 3.3.1 ECASE restriction). Use fully-qualified names (`yason:encode`, `local-time:now`) — third-party deps are listed in the `.asd` `:depends-on` *before* the src systems, mirroring `cl-harness.asd`.
- Lisp file edits via cl-mcp tools (`lisp-edit-form`, `fs-write-file` for brand-new files, `lisp-check-parens` to verify). Never shell `cat`/`sed` against Lisp source.
- Lint with `mallet next/src/*.lisp` and `mallet next/tests/*.lisp` before each commit.
- Tests via the cl-mcp `run-tests` tool: `{"system": "cl-harness-next/tests"}` (it force-reloads the test system, so file edits are picked up). Shell fallback: `ros run --non-interactive -e '(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")' -e '(ql:quickload :cl-harness-next/tests :silent t)' -e '(asdf:test-system "cl-harness-next")'`.
- First cl-mcp action of a session: `fs-set-project-root` on the repo root.

---

## File Structure

```text
cl-harness-next.asd          NEW  primary + tests systems, :pathname "next"
next/src/event.lisp          NEW  event objects, type vocabulary, JSON wire format
next/src/event-log.lisp      NEW  append-only JSONL log: open/emit/read/replay
next/src/policy-pack.lisp    NEW  hardened sexp load, schema validation,
                                  fingerprint, semver
next/src/main.lisp           NEW  facade package (nickname cl-harness-next),
                                  :import-from + :export re-exports
next/tests/event-test.lisp        NEW
next/tests/event-log-test.lisp    NEW
next/tests/policy-pack-test.lisp  NEW
next/tests/main-test.lisp         NEW  facade smoke + cross-module integration
README.md                    MODIFY  one paragraph pointing at next/
CLAUDE.md                    MODIFY  repository-structure note for next/
```

Each `next/src/<name>.lisp` defines package `cl-harness-next/src/<name>`; tests mirror as `cl-harness-next/tests/<name>-test`. `event-log` depends on `event`; `policy-pack` is independent of both; `main` imports all three.

---

### Task 1: ASDF system skeleton

**Files:**
- Create: `cl-harness-next.asd`
- Create: `next/src/main.lisp`
- Create: `next/tests/main-test.lisp`

- [ ] **Step 1: Write `cl-harness-next.asd`**

Create the file at the repo root with exactly:

```lisp
;;;; cl-harness-next.asd
;;;;
;;;; Greenfield redesign substrate (spec:
;;;; docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md).
;;;; Coexists with the legacy "cl-harness" system; sources live under next/.

(asdf:defsystem "cl-harness-next"
  :class :package-inferred-system
  :pathname "next"
  :description "L0 substrate for the autonomous cl-harness redesign."
  :author "cl-harness contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria"
               "yason"
               "local-time"
               "ironclad"
               "cl-harness-next/src/main")
  :in-order-to ((test-op (test-op "cl-harness-next/tests"))))

(asdf:defsystem "cl-harness-next/tests"
  :class :package-inferred-system
  :pathname "next"
  :depends-on ("rove"
               "cl-harness-next"
               "cl-harness-next/tests/main-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cl-harness-next/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
```

Note: secondary systems of a package-inferred-system resolve relative to the primary system's `:pathname`, so `cl-harness-next/src/main` → `next/src/main.lisp`.

- [ ] **Step 2: Write the facade stub `next/src/main.lisp`**

```lisp
;;;; next/src/main.lisp
;;;;
;;;; Public facade for cl-harness-next. Re-exports the user-facing API
;;;; via :import-from + :export (shared symbol identity). Populated as
;;;; modules land; starts as a stub so the system skeleton loads.

(defpackage #:cl-harness-next/src/main
  (:nicknames #:cl-harness-next)
  (:use #:cl)
  (:export #:substrate-version))

(in-package #:cl-harness-next/src/main)

(defun substrate-version ()
  "Return the cl-harness-next system version string."
  (asdf:component-version (asdf:find-system "cl-harness-next")))
```

- [ ] **Step 3: Write the smoke test `next/tests/main-test.lisp`**

```lisp
;;;; next/tests/main-test.lisp
;;;;
;;;; Facade smoke tests + cross-module integration tests for
;;;; cl-harness-next (SP1: L0 substrate).

(defpackage #:cl-harness-next/tests/main-test
  (:use #:cl #:rove))

(in-package #:cl-harness-next/tests/main-test)

(deftest facade-package-exists
  (ok (find-package '#:cl-harness-next))
  (ok (equal "0.1.0" (cl-harness-next:substrate-version))))
```

- [ ] **Step 4: Register the new `.asd` and load the system**

Via cl-mcp `repl-eval`:

```lisp
(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")
```

then cl-mcp `load-system` with `{"system": "cl-harness-next"}`.
Expected: loads without errors or warnings.

- [ ] **Step 5: Run the test suite**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: 1 test, 2 assertions, 0 failures.

- [ ] **Step 6: Lint and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add cl-harness-next.asd next/
git commit -m "feat(next): SP1 skeleton — cl-harness-next ASDF system under next/"
```

---

### Task 2: Event type vocabulary and wire names

**Files:**
- Create: `next/src/event.lisp`
- Create: `next/tests/event-test.lisp`
- Modify: `cl-harness-next.asd` (add test file to tests system)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/event-test.lisp`:

```lisp
;;;; next/tests/event-test.lisp
;;;;
;;;; Unit tests for next/src/event.lisp: type vocabulary, wire-name
;;;; conversion, JSON roundtrip (spec §8.1 — coarse, versioned schema).

(defpackage #:cl-harness-next/tests/event-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:+event-types+
                #:event-type-name
                #:event-type-keyword
                #:unknown-event-type))

(in-package #:cl-harness-next/tests/event-test)

(deftest wire-name-conversion
  (ok (equal "run_start" (event-type-name :run-start)))
  (ok (equal "oracle_result" (event-type-name :oracle-result)))
  (ok (eq :run-start (event-type-keyword "run_start")))
  (ok (eq :note (event-type-keyword "note"))))

(deftest unknown-types-signal
  (ok (handler-case (progn (event-type-name :no-such-type) nil)
        (unknown-event-type () t)))
  (ok (handler-case (progn (event-type-keyword "no_such_type") nil)
        (unknown-event-type () t))))

(deftest vocabulary-is-coarse
  ;; Spec §8.1: keep the vocabulary deliberately small. If this test
  ;; starts failing because the list grew past 12, stop and check the
  ;; new type really cannot be expressed as a payload of an existing one.
  (ok (<= (length +event-types+) 12)))
```

Create `next/src/event.lisp` with just the package definition (so the
test file's `:import-from` can resolve after implementation — the test
must fail on *missing functions*, not a reader error):

```lisp
;;;; next/src/event.lisp
;;;;
;;;; Event representation for the L0 event-sourcing substrate (spec
;;;; §8.1). Events are the only persisted truth; everything else is a
;;;; projection. The type vocabulary is deliberately coarse and fixed;
;;;; extend +EVENT-TYPES+ in code only when an upper layer's need
;;;; cannot be expressed as the payload of an existing type.

(defpackage #:cl-harness-next/src/event
  (:use #:cl)
  (:export #:+event-types+
           #:unknown-event-type
           #:unknown-event-type-name
           #:event-type-name
           #:event-type-keyword
           #:harness-event
           #:make-harness-event
           #:event-seq
           #:event-type
           #:event-timestamp
           #:event-schema-version
           #:event-payload
           #:event->json-string
           #:json-string->event))

(in-package #:cl-harness-next/src/event)
```

Add `"cl-harness-next/tests/event-test"` to the `:depends-on` list of
the `cl-harness-next/tests` system in `cl-harness-next.asd` (after
`"cl-harness-next/tests/main-test"`).

- [ ] **Step 2: Run tests to verify they fail**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `event-type-name` undefined (the package loads, the
functions do not exist yet).

- [ ] **Step 3: Implement the vocabulary and conversions**

Append to `next/src/event.lisp` (after `(in-package ...)`), via
`lisp-edit-form` `insert_after` on the `in-package` form or
`fs-write-file` of the whole file:

```lisp
(alexandria:define-constant +event-types+
    '(:run-start :run-end :observation :action :decision
      :oracle-result :metric :checkpoint :note)
  :test #'equal
  :documentation
  "Fixed coarse event vocabulary (spec §8.1). Upper layers express
detail in payloads, not new types: a patch is an :action, a clean
verification verdict is an :oracle-result, etc.")

(define-condition unknown-event-type (error)
  ((name :initarg :name :reader unknown-event-type-name))
  (:report (lambda (condition stream)
             (format stream "Unknown event type ~S (known: ~{~S~^ ~})."
                     (unknown-event-type-name condition)
                     +event-types+)))
  (:documentation "Signaled for an event type outside +EVENT-TYPES+."))

(defun %wire-name (keyword)
  (substitute #\_ #\- (string-downcase (symbol-name keyword))))

(defun event-type-name (keyword)
  "Return the JSON wire name for event-type KEYWORD, e.g. :RUN-START
=> \"run_start\". Signals UNKNOWN-EVENT-TYPE for unknown keywords."
  (unless (member keyword +event-types+)
    (error 'unknown-event-type :name keyword))
  (%wire-name keyword))

(defun event-type-keyword (name)
  "Return the event-type keyword for wire NAME, e.g. \"run_start\"
=> :RUN-START. Signals UNKNOWN-EVENT-TYPE for unknown names."
  (or (find name +event-types+ :key #'%wire-name :test #'string=)
      (error 'unknown-event-type :name name)))
```

- [ ] **Step 4: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS (4 tests total including Task 1's).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/event.lisp next/tests/event-test.lisp
git add next/src/event.lisp next/tests/event-test.lisp cl-harness-next.asd
git commit -m "feat(next): event type vocabulary with JSON wire names"
```

---

### Task 3: Event objects and JSON roundtrip

**Files:**
- Modify: `next/src/event.lisp`
- Modify: `next/tests/event-test.lisp`

- [ ] **Step 1: Write the failing tests**

Append to `next/tests/event-test.lisp` — first extend the test
package's `:import-from` to also import `#:make-harness-event`,
`#:event-seq`, `#:event-type`, `#:event-timestamp`,
`#:event-schema-version`, `#:event-payload`, `#:event->json-string`,
`#:json-string->event`, then add:

```lisp
(deftest event-json-roundtrip
  (let* ((payload (let ((h (make-hash-table :test #'equal)))
                    (setf (gethash "tool" h) "run-tests"
                          (gethash "ok" h) t
                          (gethash "count" h) 3)
                    h))
         (event (make-harness-event :action payload :seq 7))
         (line (event->json-string event))
         (back (json-string->event line)))
    (ok (not (find #\Newline line)))
    (ok (= 7 (event-seq back)))
    (ok (eq :action (event-type back)))
    (ok (equal (event-timestamp event) (event-timestamp back)))
    (ok (= 1 (event-schema-version back)))
    (ok (equal "run-tests" (gethash "tool" (event-payload back))))
    (ok (eq t (gethash "ok" (event-payload back))))
    (ok (= 3 (gethash "count" (event-payload back))))))

(deftest nil-payload-roundtrip
  (let ((back (json-string->event
               (event->json-string (make-harness-event :note nil :seq 1)))))
    (ok (null (event-payload back)))))

(deftest timestamp-defaults-to-now
  (let ((event (make-harness-event :note nil :seq 1)))
    (ok (stringp (event-timestamp event)))
    (ok (plusp (length (event-timestamp event))))))

(deftest make-event-validates-type
  (ok (handler-case (progn (make-harness-event :bogus nil :seq 1) nil)
        (unknown-event-type () t))))
```

- [ ] **Step 2: Run tests to verify they fail**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `make-harness-event` undefined.

- [ ] **Step 3: Implement event class and JSON (de)serialization**

Append to `next/src/event.lisp`:

```lisp
(defclass harness-event ()
  ((seq :initarg :seq :reader event-seq
        :documentation "Monotonic sequence number within one log, from 1.")
   (event-type :initarg :event-type :reader event-type
               :documentation "Member of +EVENT-TYPES+.")
   (timestamp :initarg :timestamp :reader event-timestamp
              :documentation "ISO-8601 timestamp string.")
   (schema-version :initarg :schema-version :initform 1
                   :reader event-schema-version)
   (payload :initarg :payload :initform nil :reader event-payload
            :documentation "Hash-table with string keys, or NIL."))
  (:documentation "One immutable entry in the append-only event log."))

(defun make-harness-event (type payload &key (seq 0) timestamp (schema-version 1))
  "Construct a HARNESS-EVENT of TYPE carrying PAYLOAD (a hash-table
with string keys, or NIL). TIMESTAMP defaults to now. Signals
UNKNOWN-EVENT-TYPE when TYPE is not in +EVENT-TYPES+."
  (event-type-name type)
  (make-instance 'harness-event
                 :seq seq
                 :event-type type
                 :timestamp (or timestamp
                                (local-time:format-timestring
                                 nil (local-time:now)))
                 :schema-version schema-version
                 :payload payload))

(defun event->json-string (event)
  "Serialize EVENT to a single-line JSON string (the JSONL wire format)."
  (with-output-to-string (out)
    (yason:with-output (out)
      (yason:with-object ()
        (yason:encode-object-element "seq" (event-seq event))
        (yason:encode-object-element "type" (event-type-name (event-type event)))
        (yason:encode-object-element "timestamp" (event-timestamp event))
        (yason:encode-object-element "schema_version" (event-schema-version event))
        (yason:encode-object-element
         "payload" (or (event-payload event)
                       (make-hash-table :test #'equal)))))))

(defun json-string->event (line)
  "Parse one JSONL LINE back into a HARNESS-EVENT. An empty payload
object decodes as NIL. Signals UNKNOWN-EVENT-TYPE on unknown types."
  (let ((object (yason:parse line)))
    (make-instance 'harness-event
                   :seq (gethash "seq" object)
                   :event-type (event-type-keyword (gethash "type" object))
                   :timestamp (gethash "timestamp" object)
                   :schema-version (gethash "schema_version" object 1)
                   :payload (let ((payload (gethash "payload" object)))
                              (if (and (hash-table-p payload)
                                       (zerop (hash-table-count payload)))
                                  nil
                                  payload)))))
```

- [ ] **Step 4: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/event.lisp next/tests/event-test.lisp
git add next/src/event.lisp next/tests/event-test.lisp
git commit -m "feat(next): harness-event objects with JSONL roundtrip"
```

---

### Task 4: Append-only event log with resume

**Files:**
- Create: `next/src/event-log.lisp`
- Create: `next/tests/event-log-test.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/event-log-test.lisp`:

```lisp
;;;; next/tests/event-log-test.lisp
;;;;
;;;; Unit tests for next/src/event-log.lisp: durable append, ordered
;;;; read, seq resume after reopen (spec §8.1 / §9 — suspend/resume
;;;; rebuilds from the log alone), replay fold, parse-error reporting.

(defpackage #:cl-harness-next/tests/event-log-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-seq
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:event-log-next-seq
                #:emit-event
                #:read-events
                #:replay-events
                #:event-log-parse-error
                #:event-log-parse-error-line-number))

(in-package #:cl-harness-next/tests/event-log-test)

(defmacro with-log-path ((path) &body body)
  "Run BODY with PATH bound to a fresh temporary .jsonl path that does
not exist yet and is deleted afterwards."
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(deftest emit-and-read-roundtrip
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start
                  (alexandria:plist-hash-table (list "pack" "abc")
                                               :test #'equal))
      (emit-event log :action nil)
      (emit-event log :run-end nil)
      (let ((events (read-events path)))
        (ok (= 3 (length events)))
        (ok (equal '(1 2 3) (mapcar #'event-seq events)))
        (ok (equal '(:run-start :action :run-end)
                   (mapcar #'event-type events)))
        (ok (equal "abc" (gethash "pack" (event-payload (first events)))))))))

(deftest seq-resumes-after-reopen
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start nil)
      (emit-event log :note nil))
    (let* ((reopened (open-event-log path))
           (event (emit-event reopened :run-end nil)))
      (ok (= 3 (event-seq event)))
      (ok (= 3 (length (read-events path)))))))

(deftest fresh-log-starts-at-one
  (with-log-path (path)
    (ok (= 1 (event-log-next-seq (open-event-log path))))))
```

- [ ] **Step 2: Register and run tests to verify they fail**

Add `"cl-harness-next/tests/event-log-test"` to the tests system's
`:depends-on` in `cl-harness-next.asd`. Run cl-mcp `run-tests`
with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — package `cl-harness-next/src/event-log` does not exist
(load error). That is the expected red state for a brand-new module.

- [ ] **Step 3: Implement the event log**

Create `next/src/event-log.lisp`:

```lisp
;;;; next/src/event-log.lisp
;;;;
;;;; Append-only JSONL event log — the single source of truth at L0
;;;; (spec §8.1). Durability over speed: each emit opens, appends,
;;;; and closes the file, so a crash never loses an acknowledged
;;;; event. Projections are built by folding with REPLAY-EVENTS.

(defpackage #:cl-harness-next/src/event-log
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event
                #:event-seq
                #:event->json-string
                #:json-string->event)
  (:export #:event-log
           #:open-event-log
           #:event-log-path
           #:event-log-next-seq
           #:emit-event
           #:read-events
           #:replay-events
           #:event-log-parse-error
           #:event-log-parse-error-path
           #:event-log-parse-error-line-number
           #:event-log-parse-error-cause))

(in-package #:cl-harness-next/src/event-log)

(define-condition event-log-parse-error (error)
  ((path :initarg :path :reader event-log-parse-error-path)
   (line-number :initarg :line-number
                :reader event-log-parse-error-line-number)
   (cause :initarg :cause :reader event-log-parse-error-cause))
  (:report (lambda (condition stream)
             (format stream "Malformed event at ~A line ~D: ~A"
                     (event-log-parse-error-path condition)
                     (event-log-parse-error-line-number condition)
                     (event-log-parse-error-cause condition))))
  (:documentation "Signaled by READ-EVENTS on an unparseable line."))

(defclass event-log ()
  ((path :initarg :path :reader event-log-path)
   (next-seq :initarg :next-seq :accessor event-log-next-seq))
  (:documentation "Handle on an append-only JSONL event log."))

(defun open-event-log (path)
  "Open (or create on first emit) the event log at PATH. When the file
already holds events, the sequence counter resumes after the highest
recorded seq, so suspend/resume needs nothing but the log file."
  (let ((next 1))
    (when (probe-file path)
      (dolist (event (read-events path))
        (setf next (max next (1+ (event-seq event))))))
    (make-instance 'event-log :path (pathname path) :next-seq next)))

(defun emit-event (log type payload)
  "Append a TYPE event carrying PAYLOAD to LOG and return it. The line
is durably on disk (file closed) before this function returns."
  (let ((event (make-harness-event type payload
                                   :seq (event-log-next-seq log))))
    (with-open-file (out (event-log-path log)
                         :direction :output
                         :if-exists :append
                         :if-does-not-exist :create
                         :external-format :utf-8)
      (write-line (event->json-string event) out))
    (incf (event-log-next-seq log))
    event))

(defun read-events (path)
  "Read all events from the JSONL file at PATH, in file order. Blank
lines are skipped. Signals EVENT-LOG-PARSE-ERROR on a malformed line."
  (with-open-file (in path :direction :input :external-format :utf-8)
    (loop for line = (read-line in nil nil)
          for line-number from 1
          while line
          unless (string= "" (string-trim '(#\Space #\Tab) line))
            collect (handler-case (json-string->event line)
                      (error (e)
                        (error 'event-log-parse-error
                               :path path
                               :line-number line-number
                               :cause e))))))

(defun replay-events (path reducer initial)
  "Fold REDUCER over the events at PATH in order, as
\(funcall REDUCER accumulator event), starting from INITIAL. Returns
the final accumulator. This is how L2 projections are built."
  (reduce reducer (read-events path) :initial-value initial))
```

- [ ] **Step 4: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/event-log.lisp next/tests/event-log-test.lisp
git add next/src/event-log.lisp next/tests/event-log-test.lisp cl-harness-next.asd
git commit -m "feat(next): append-only JSONL event log with seq resume"
```

---

### Task 5: Replay fold and parse-error reporting

**Files:**
- Modify: `next/tests/event-log-test.lisp`

(The implementation already landed in Task 4 — `replay-events` and the
condition are small enough that splitting their *code* out would leave
Task 4 unloadable. This task adds their behavioral tests, which is
where the contract actually gets pinned.)

- [ ] **Step 1: Write the tests**

Append to `next/tests/event-log-test.lisp`:

```lisp
(deftest replay-folds-a-projection
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :action nil)
      (emit-event log :action nil)
      (emit-event log :note nil))
    (ok (= 2 (replay-events path
                            (lambda (count event)
                              (if (eq :action (event-type event))
                                  (1+ count)
                                  count))
                            0)))))

(deftest malformed-line-reports-position
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :note nil))
    (with-open-file (out path :direction :output :if-exists :append)
      (write-line "{this is not json" out))
    (ok (handler-case (progn (read-events path) nil)
          (event-log-parse-error (e)
            (= 2 (event-log-parse-error-line-number e)))))))

(deftest unknown-type-line-signals-parse-error
  (with-log-path (path)
    (with-open-file (out path :direction :output :if-does-not-exist :create)
      (write-line
       (concatenate 'string
                    "{\"seq\":1,\"type\":\"weird_type\",\"timestamp\":\"t\","
                    "\"schema_version\":1,\"payload\":{}}")
       out))
    (ok (handler-case (progn (read-events path) nil)
          (event-log-parse-error () t)))))
```

- [ ] **Step 2: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS (these pin behavior already implemented in Task 4; if
any fails, fix `event-log.lisp` before proceeding).

- [ ] **Step 3: Lint and commit**

```bash
mallet next/tests/event-log-test.lisp
git add next/tests/event-log-test.lisp
git commit -m "test(next): pin replay fold and parse-error contracts"
```

---

### Task 6: Semver parsing and comparison

**Files:**
- Create: `next/src/policy-pack.lisp`
- Create: `next/tests/policy-pack-test.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/policy-pack-test.lisp`:

```lisp
;;;; next/tests/policy-pack-test.lisp
;;;;
;;;; Unit tests for next/src/policy-pack.lisp: semver, hardened sexp
;;;; loading, schema validation, accessors, content fingerprint
;;;; (spec §10.1 — policy pack as versioned, fingerprinted data).

(defpackage #:cl-harness-next/tests/policy-pack-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/policy-pack
                #:parse-semver
                #:semver<))

(in-package #:cl-harness-next/tests/policy-pack-test)

(deftest semver-parses-to-integer-triple
  (ok (equal '(1 2 3) (parse-semver "1.2.3")))
  (ok (equal '(0 1 0) (parse-semver "0.1.0"))))

(deftest semver-rejects-non-semver
  (dolist (bad '("1.2" "1.2.3.4" "1.2.x" "" "v1.2.3"))
    (ok (handler-case (progn (parse-semver bad) nil)
          (error () t))
        (format nil "~S should not parse" bad))))

(deftest semver-comparison
  (ok (semver< "0.9.9" "0.10.0"))
  (ok (semver< "1.0.0" "2.0.0"))
  (ok (semver< "1.0.0" "1.0.1"))
  (ok (not (semver< "1.0.0" "1.0.0")))
  (ok (not (semver< "2.0.0" "1.9.9"))))
```

Create `next/src/policy-pack.lisp` with the package definition only:

```lisp
;;;; next/src/policy-pack.lisp
;;;;
;;;; Policy pack: the versioned artifact bundle of the redesign
;;;; (spec §10.1). Prompts, budgets, oracle profiles, and dial rules
;;;; live here as *data*, never code: packs are read with a hardened
;;;; reader (*READ-EVAL* nil, symbols confined to keywords) and
;;;; identified by a SHA-256 fingerprint of their canonical form, so
;;;; every run can record exactly which pack produced its metrics.

(defpackage #:cl-harness-next/src/policy-pack
  (:use #:cl)
  (:export #:parse-semver
           #:semver<
           #:policy-pack
           #:load-policy-pack
           #:policy-pack-invalid
           #:policy-pack-invalid-message
           #:policy-pack-invalid-path
           #:pack-name
           #:pack-version
           #:pack-source-path
           #:pack-fingerprint
           #:pack-prompts
           #:pack-budgets
           #:pack-oracle-profiles
           #:pack-dial-rules
           #:pack-prompt
           #:pack-budget
           #:pack-oracle-profile
           #:pack-dial-rule))

(in-package #:cl-harness-next/src/policy-pack)
```

Add `"cl-harness-next/tests/policy-pack-test"` to the tests system's
`:depends-on` in `cl-harness-next.asd`.

- [ ] **Step 2: Run tests to verify they fail**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `parse-semver` undefined.

- [ ] **Step 3: Implement semver**

Append to `next/src/policy-pack.lisp`:

```lisp
(defun parse-semver (string)
  "Parse a strict \"MAJOR.MINOR.PATCH\" STRING into a list of three
non-negative integers. Signals an ERROR on anything else."
  (let ((parts (uiop:split-string string :separator ".")))
    (unless (= 3 (length parts))
      (error "Not a MAJOR.MINOR.PATCH semver string: ~S" string))
    (mapcar (lambda (part) (parse-integer part)) parts)))

(defun semver< (a b)
  "True when semver string A denotes a strictly older version than B."
  (loop for x in (parse-semver a)
        for y in (parse-semver b)
        when (< x y) return t
        when (> x y) return nil
        finally (return nil)))
```

- [ ] **Step 4: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git add next/src/policy-pack.lisp next/tests/policy-pack-test.lisp cl-harness-next.asd
git commit -m "feat(next): strict semver parse and compare"
```

---

### Task 7: Hardened pack reading and schema validation

**Files:**
- Modify: `next/src/policy-pack.lisp`
- Modify: `next/tests/policy-pack-test.lisp`

- [ ] **Step 1: Write the failing tests**

Extend the test package's `:import-from` (same
`cl-harness-next/src/policy-pack` clause) with `#:load-policy-pack`,
`#:policy-pack-invalid`, `#:pack-name`, `#:pack-version`,
`#:pack-prompts`, then append:

```lisp
(defparameter *valid-pack-text*
  "(:name \"default\"
    :version \"0.1.0\"
    :prompts ((:id :agent-system :text \"You are the agent.\"))
    :budgets ((:id :max-turns :value 20))
    :oracle-profiles ((:id :review-tests :strictness :strict))
    :dial-rules ((:id :default-dial :value :scripted)))")

(defun write-pack-file (path text)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (write-string text out)))

(defmacro with-pack-file ((path text) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "sexp")
     (write-pack-file ,path ,text)
     ,@body))

(deftest valid-pack-loads
  (with-pack-file (path *valid-pack-text*)
    (let ((pack (load-policy-pack path)))
      (ok (equal "default" (pack-name pack)))
      (ok (equal "0.1.0" (pack-version pack)))
      (ok (= 1 (length (pack-prompts pack)))))))

(deftest minimal-pack-loads
  ;; Sections are optional; only :name and :version are required.
  (with-pack-file (path "(:name \"tiny\" :version \"0.1.0\")")
    (let ((pack (load-policy-pack path)))
      (ok (equal "tiny" (pack-name pack)))
      (ok (null (pack-prompts pack))))))

(deftest missing-version-is-invalid
  (with-pack-file (path "(:name \"x\")")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest non-semver-version-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"1.2\")")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest unknown-top-level-key-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\" :surprise 1)")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest entry-without-id-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\"
                          :budgets ((:value 20)))")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest read-eval-is-rejected
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\"
                          :budgets ((:id :n :value #.(+ 1 2))))")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest trailing-form-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\") (:extra)")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))
```

- [ ] **Step 2: Run tests to verify they fail**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `load-policy-pack` undefined.

- [ ] **Step 3: Implement hardened read + validation + class**

Append to `next/src/policy-pack.lisp`:

```lisp
(alexandria:define-constant +section-keys+
    '(:prompts :budgets :oracle-profiles :dial-rules)
  :test #'equal
  :documentation "Optional pack sections; each is a list of plists
carrying a keyword :id.")

(define-condition policy-pack-invalid (error)
  ((message :initarg :message :reader policy-pack-invalid-message)
   (path :initarg :path :initform nil :reader policy-pack-invalid-path))
  (:report (lambda (condition stream)
             (format stream "Invalid policy pack~@[ at ~A~]: ~A"
                     (policy-pack-invalid-path condition)
                     (policy-pack-invalid-message condition))))
  (:documentation "Signaled by LOAD-POLICY-PACK on unreadable or
schema-violating pack files."))

(defclass policy-pack ()
  ((name :initarg :name :reader pack-name)
   (version :initarg :version :reader pack-version
            :documentation "Semver string.")
   (prompts :initarg :prompts :initform nil :reader pack-prompts)
   (budgets :initarg :budgets :initform nil :reader pack-budgets)
   (oracle-profiles :initarg :oracle-profiles :initform nil
                    :reader pack-oracle-profiles)
   (dial-rules :initarg :dial-rules :initform nil :reader pack-dial-rules)
   (source-path :initarg :source-path :initform nil
                :reader pack-source-path)
   (fingerprint :initarg :fingerprint :reader pack-fingerprint
                :documentation "SHA-256 hex of the canonical form."))
  (:documentation "An immutable, validated policy pack (spec §10.1)."))

(defun %read-pack-form (path)
  "Read exactly one top-level form from PATH with a hardened reader:
*READ-EVAL* is NIL (so #. signals at read time) and *PACKAGE* is the
KEYWORD package, so every unqualified symbol in the file reads as a
keyword and nothing is interned into code packages. Wraps any reader
failure in POLICY-PACK-INVALID."
  (handler-case
      (with-standard-io-syntax
        (let ((*read-eval* nil)
              (*package* (find-package :keyword)))
          (with-open-file (in path :direction :input
                                   :external-format :utf-8)
            (let ((form (read in)))
              (when (read in nil nil)
                (error "pack file must contain exactly one top-level form"))
              form))))
    (error (e)
      (error 'policy-pack-invalid :path path
             :message (format nil "unreadable pack file: ~A" e)))))

(defun %validate-pack-form (form path)
  "Check FORM against the SP1 pack schema and return it. Required:
:name (string), :version (semver string). Optional: +SECTION-KEYS+,
each a list of plists with a keyword :id. Unknown top-level keys are
rejected to catch typos early."
  (flet ((invalid (control &rest arguments)
           (error 'policy-pack-invalid :path path
                  :message (apply #'format nil control arguments))))
    (unless (and (listp form) (evenp (length form)))
      (invalid "top-level form must be a plist"))
    (loop for (key nil) on form by #'cddr
          unless (member key (list* :name :version +section-keys+))
            do (invalid "unknown top-level key ~S" key))
    (let ((name (getf form :name))
          (version (getf form :version)))
      (unless (stringp name)
        (invalid ":name must be a string"))
      (unless (stringp version)
        (invalid ":version must be a string"))
      (handler-case (parse-semver version)
        (error () (invalid ":version ~S is not MAJOR.MINOR.PATCH" version))))
    (dolist (section +section-keys+)
      (dolist (entry (getf form section))
        (unless (and (listp entry) (keywordp (getf entry :id)))
          (invalid "every ~S entry needs a keyword :id, got ~S"
                   section entry))))
    form))

(defun load-policy-pack (path)
  "Load, validate, and fingerprint the policy pack at PATH. Returns a
POLICY-PACK. Signals POLICY-PACK-INVALID on read or schema failure."
  (let ((form (%validate-pack-form (%read-pack-form path) path)))
    (make-instance 'policy-pack
                   :name (getf form :name)
                   :version (getf form :version)
                   :prompts (getf form :prompts)
                   :budgets (getf form :budgets)
                   :oracle-profiles (getf form :oracle-profiles)
                   :dial-rules (getf form :dial-rules)
                   :source-path (pathname path)
                   :fingerprint (%fingerprint form))))
```

`%fingerprint` does not exist yet — define a stub so this task stays
loadable, immediately above `load-policy-pack` (Task 8 replaces it):

```lisp
(defun %fingerprint (form)
  "Placeholder until Task 8: canonical-print FORM without hashing."
  (with-standard-io-syntax
    (let ((*print-pretty* nil))
      (prin1-to-string form))))
```

- [ ] **Step 4: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git add next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git commit -m "feat(next): hardened policy-pack reader with schema validation"
```

---

### Task 8: Pack accessors and SHA-256 fingerprint

**Files:**
- Modify: `next/src/policy-pack.lisp`
- Modify: `next/tests/policy-pack-test.lisp`

- [ ] **Step 1: Write the failing tests**

Extend the test package's `:import-from` with `#:pack-prompt`,
`#:pack-budget`, `#:pack-oracle-profile`, `#:pack-dial-rule`,
`#:pack-fingerprint`, then append:

```lisp
(deftest accessors-find-entries-by-id
  (with-pack-file (path *valid-pack-text*)
    (let ((pack (load-policy-pack path)))
      (ok (equal "You are the agent." (pack-prompt pack :agent-system)))
      (ok (= 20 (pack-budget pack :max-turns)))
      (ok (eq :strict (getf (pack-oracle-profile pack :review-tests)
                            :strictness)))
      (ok (eq :scripted (getf (pack-dial-rule pack :default-dial) :value)))
      (ok (null (pack-prompt pack :no-such-prompt)))
      (ok (null (pack-budget pack :no-such-budget))))))

(deftest fingerprint-is-sha256-hex
  (with-pack-file (path *valid-pack-text*)
    (let ((fingerprint (pack-fingerprint (load-policy-pack path))))
      (ok (= 64 (length fingerprint)))
      (ok (every (lambda (c) (digit-char-p c 16)) fingerprint)))))

(deftest fingerprint-stable-across-files
  (with-pack-file (path-a *valid-pack-text*)
    (uiop:with-temporary-file (:pathname path-b :type "sexp")
      (write-pack-file path-b *valid-pack-text*)
      (ok (equal (pack-fingerprint (load-policy-pack path-a))
                 (pack-fingerprint (load-policy-pack path-b)))))))

(deftest fingerprint-tracks-content
  (with-pack-file (path-a *valid-pack-text*)
    (uiop:with-temporary-file (:pathname path-b :type "sexp")
      (write-pack-file
       path-b
       "(:name \"default\"
         :version \"0.1.0\"
         :prompts ((:id :agent-system :text \"You are the agent.\"))
         :budgets ((:id :max-turns :value 21))
         :oracle-profiles ((:id :review-tests :strictness :strict))
         :dial-rules ((:id :default-dial :value :scripted)))")
      (ok (not (equal (pack-fingerprint (load-policy-pack path-a))
                      (pack-fingerprint (load-policy-pack path-b))))))))
```

- [ ] **Step 2: Run tests to verify they fail**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `pack-prompt` undefined, and
`fingerprint-is-sha256-hex` fails against the Task 7 placeholder.

- [ ] **Step 3: Implement accessors and real fingerprint**

Replace the `%fingerprint` stub (via `lisp-edit-form` `replace` on
`defun %fingerprint`) with:

```lisp
(defun %fingerprint (form)
  "SHA-256 hex digest of FORM's canonical printed representation.
Canonical means WITH-STANDARD-IO-SYNTAX, no pretty printing — the
same parsed content always prints, and therefore hashes, identically.
SBCL-only via SB-EXT:STRING-TO-OCTETS (project targets SBCL, PRD §9.4)."
  (let ((canonical (with-standard-io-syntax
                     (let ((*print-pretty* nil))
                       (prin1-to-string form)))))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence
      :sha256
      (sb-ext:string-to-octets canonical :external-format :utf-8)))))
```

Append the accessors:

```lisp
(defun %section-entry (entries id)
  (find id entries :key (lambda (entry) (getf entry :id))))

(defun pack-prompt (pack id)
  "Return the :text of prompt ID in PACK, or NIL when absent."
  (getf (%section-entry (pack-prompts pack) id) :text))

(defun pack-budget (pack id)
  "Return the :value of budget ID in PACK, or NIL when absent."
  (getf (%section-entry (pack-budgets pack) id) :value))

(defun pack-oracle-profile (pack id)
  "Return the full plist of oracle profile ID in PACK, or NIL."
  (%section-entry (pack-oracle-profiles pack) id))

(defun pack-dial-rule (pack id)
  "Return the full plist of dial rule ID in PACK, or NIL."
  (%section-entry (pack-dial-rules pack) id))
```

- [ ] **Step 4: Run tests to verify they pass**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git add next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git commit -m "feat(next): pack accessors and SHA-256 content fingerprint"
```

---

### Task 9: Facade, integration test, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write the failing integration test**

Append to `next/tests/main-test.lisp` (note: this deliberately goes
through the **facade** package to prove the re-exports work):

```lisp
(deftest run-start-records-pack-fingerprint
  ;; SP1 acceptance: a run can durably record which policy pack it
  ;; used (spec 原則3「すべての実行は実験である」).
  (uiop:with-temporary-file (:pathname pack-path :type "sexp")
    (with-open-file (out pack-path :direction :output
                                   :if-exists :supersede
                                   :external-format :utf-8)
      (write-string "(:name \"default\" :version \"0.1.0\")" out))
    (uiop:with-temporary-file (:pathname log-path :type "jsonl")
      (uiop:delete-file-if-exists log-path)
      (let ((pack (cl-harness-next:load-policy-pack pack-path))
            (log (cl-harness-next:open-event-log log-path)))
        (cl-harness-next:emit-event
         log :run-start
         (alexandria:plist-hash-table
          (list "pack_name" (cl-harness-next:pack-name pack)
                "pack_fingerprint" (cl-harness-next:pack-fingerprint pack))
          :test #'equal))
        (let ((event (first (cl-harness-next:read-events log-path))))
          (ok (eq :run-start (cl-harness-next:event-type event)))
          (ok (equal (cl-harness-next:pack-fingerprint pack)
                     (gethash "pack_fingerprint"
                              (cl-harness-next:event-payload event)))))))))
```

- [ ] **Step 2: Run tests to verify it fails**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `cl-harness-next:load-policy-pack` is not exported
from the facade yet.

- [ ] **Step 3: Fill in the facade**

Replace the `defpackage` in `next/src/main.lisp` (via `lisp-edit-form`
`replace` on `defpackage cl-harness-next/src/main`) with:

```lisp
(defpackage #:cl-harness-next/src/main
  (:nicknames #:cl-harness-next)
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:+event-types+
                #:unknown-event-type
                #:unknown-event-type-name
                #:harness-event
                #:make-harness-event
                #:event-seq
                #:event-type
                #:event-timestamp
                #:event-schema-version
                #:event-payload
                #:event->json-string
                #:json-string->event)
  (:import-from #:cl-harness-next/src/event-log
                #:event-log
                #:open-event-log
                #:event-log-path
                #:event-log-next-seq
                #:emit-event
                #:read-events
                #:replay-events
                #:event-log-parse-error
                #:event-log-parse-error-path
                #:event-log-parse-error-line-number
                #:event-log-parse-error-cause)
  (:import-from #:cl-harness-next/src/policy-pack
                #:parse-semver
                #:semver<
                #:policy-pack
                #:load-policy-pack
                #:policy-pack-invalid
                #:policy-pack-invalid-message
                #:policy-pack-invalid-path
                #:pack-name
                #:pack-version
                #:pack-source-path
                #:pack-fingerprint
                #:pack-prompts
                #:pack-budgets
                #:pack-oracle-profiles
                #:pack-dial-rules
                #:pack-prompt
                #:pack-budget
                #:pack-oracle-profile
                #:pack-dial-rule)
  (:export #:substrate-version
           ;; event
           #:+event-types+
           #:unknown-event-type
           #:unknown-event-type-name
           #:harness-event
           #:make-harness-event
           #:event-seq
           #:event-type
           #:event-timestamp
           #:event-schema-version
           #:event-payload
           #:event->json-string
           #:json-string->event
           ;; event-log
           #:event-log
           #:open-event-log
           #:event-log-path
           #:event-log-next-seq
           #:emit-event
           #:read-events
           #:replay-events
           #:event-log-parse-error
           #:event-log-parse-error-path
           #:event-log-parse-error-line-number
           #:event-log-parse-error-cause
           ;; policy-pack
           #:parse-semver
           #:semver<
           #:policy-pack
           #:load-policy-pack
           #:policy-pack-invalid
           #:policy-pack-invalid-message
           #:policy-pack-invalid-path
           #:pack-name
           #:pack-version
           #:pack-source-path
           #:pack-fingerprint
           #:pack-prompts
           #:pack-budgets
           #:pack-oracle-profiles
           #:pack-dial-rules
           #:pack-prompt
           #:pack-budget
           #:pack-oracle-profile
           #:pack-dial-rule))
```

- [ ] **Step 4: Run tests to verify everything passes**

cl-mcp `run-tests` with `{"system": "cl-harness-next/tests"}`.
Expected: PASS — all SP1 tests green.

- [ ] **Step 5: Full force-compile (pre-PR check from CLAUDE.md)**

Via cl-mcp `repl-eval`:

```lisp
(asdf:compile-system :cl-harness-next :force t)
```

Expected: no warnings. Fix any that appear before continuing.

- [ ] **Step 6: Document the new tree**

In `README.md`, after the `## Status` paragraph, add:

```markdown
### next/ — autonomous-harness redesign (experimental)

`cl-harness-next` (sources under `next/`) is the greenfield redesign
substrate from
`docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md`.
SP1 ships the L0 event log (JSONL event sourcing) and policy pack
(versioned, fingerprinted prompt/config bundles). It does not affect
the `cl-harness` CLI.
```

In `CLAUDE.md`, in the "Repository Structure" code block, add a line
after `src/`:

```text
next/             Greenfield redesign (system cl-harness-next; spec 2026-06-11)
```

- [ ] **Step 7: Lint everything and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md CLAUDE.md
git commit -m "feat(next): facade re-exports + pack-fingerprint integration test"
```

---

## Verification checklist (whole sub-project)

- `(asdf:test-system "cl-harness-next")` green from a clean image
  (use cl-mcp `pool-kill-worker` then `load-system` + `run-tests` to
  confirm — the project's own clean-verification principle applies to
  itself).
- `(asdf:compile-system :cl-harness-next :force t)` emits no warnings.
- `mallet next/src/*.lisp next/tests/*.lisp` clean.
- Legacy system untouched: `git status` shows no changes under `src/`
  or `tests/`; `run-tests` on `{"system": "cl-harness/tests"}` still
  green.

## Deferred (later sub-projects — do NOT build now)

- Projections beyond the `replay-events` fold (SP3 world model).
- Pack mutation / promotion API and champion-challenger bookkeeping (SP8).
- Metrics aggregation across logs (SP8); a `:metric` event type exists,
  aggregation does not.
- Event-log file locking for concurrent writers (single-writer per run
  is the SP1 contract; revisit in SP7 mission layer).
