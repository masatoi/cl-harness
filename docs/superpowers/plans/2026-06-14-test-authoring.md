# Test Authoring (`authoring-policy`, `:mode :tdd` MVP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a goal-driven test-authoring dial to `cl-harness-next` — `authoring-policy :mode :tdd` writes failing tests from a goal, gates them (RED-first + LLM review), then delegates to `template-fix` to implement to clean-green.

**Architecture:** A new in-kernel FSM `control-policy` (mirroring `template-fix-policy`). Phases: `:init` (read source, derive SUT package/surface) → `:author` (LLM emits `deftest` forms; harness validates + writes them) → `:author-verify` (RED-first: authored tests must load and fail) → `:author-review` (`:consult` the existing `review-oracle`) → `:fix` (delegate to an injected inner fix policy, exactly as `adaptive-policy` delegates). Oracle integrity by **phase separation**: the fix phase only patches `src/`, so it cannot weaken the gated tests.

**Tech Stack:** SBCL, ASDF `package-inferred-system`, `rove`, the `cl-harness-next` kernel/oracle/environment, `cl-mcp` tools (`fs-read-file`, `fs-write-file`, `load-system`, `run-tests`, `pool-kill-worker`). Reuses `extract-method-body`'s reader approach, `discover-targets`, and `review-oracle`.

**Design spec:** `docs/superpowers/specs/2026-06-14-test-authoring-design.md`. **Branch:** `feat/next-test-authoring`.

---

## Reference contracts (read once before starting)

- **Policy/kernel** (`next/src/kernel.lisp`): `(defclass control-policy () ())`;
  `(defgeneric decide (policy kernel))`; `(make-decision :kind :act|:consult|:record|:finish|:give-up :tool … :arguments <hash> :oracle … :subject … :reason …)`; `decision-kind`; kernel accessors `kernel-last-result` (last tool result hash), `kernel-last-action-error` (string or NIL — set from an `isError` result too), `kernel-last-verdict` (last `:consult` verdict), `kernel-environment`. A `:consult` calls `(consult oracle (or subject environment) :event-log …)` and stores the verdict in `kernel-last-verdict`.
- **Oracle** (`next/src/oracle.lisp`): `(defstruct verdict oracle pass-p reason)`, `verdict-pass-p`. `review-oracle` (`next/src/review-oracle.lisp`): `(make-instance 'review-oracle :judge-fn <fn> :profile (list :id :tests-review :strictness :strict :instructions "…"))`; its `evaluate` takes a **string** subject, calls the judge, parses `APPROVE`/`REJECT` (fails closed). Reuse it directly — no new oracle class.
- **Delegation** (`next/src/adaptive-policy.lisp`): `decide` returns `(decide (%current-level policy) kernel)`. We do the same in `:fix`.
- **Template precedent** (`next/src/template-policy.lisp`): the FSM shape, `extract-method-body` (reader with `*read-eval* nil`), `discover-targets (source file) → (values targets class-text sut-package)`, `strip-code-fence` (imported from `cl-harness-next/src/action`), per-form `load-system`/`run-tests`/`pool-kill-worker`, `%mentions` (case-insensitive substring).
- **Test harness** (`next/tests/template-policy-test.lisp`): a `mcp-transport` subclass implementing `transport-send-request`, wired via `(make-cl-mcp-environment :client (make-mcp-client transport) :condition :runtime-native :event-log log)`, `make-kernel`, `run-kernel`.

---

## File structure

- **Create** `next/src/authoring-policy.lisp` — package `cl-harness-next/src/authoring-policy`. Holds `extract-deftest-forms`, `+test-author-system-prompt+`, `authoring-policy` + FSM. One responsibility: the authoring dial.
- **Create** `next/tests/authoring-policy-test.lisp` — Rove suite (pure unit + canned-transport integration).
- **Create** `tools/run-tdd.lisp` — standalone e2e runner (TDD bootstrap on a stub-`add` project).
- **Modify** `next/src/main.lisp` — facade: import + re-export the user-facing authoring symbols.
- **Modify** `cl-harness-next.asd` — add `cl-harness-next/tests/authoring-policy-test` to the tests system. (`src/authoring-policy` loads transitively via `main`'s `:import-from`.)
- **Modify** `next/README.md` — add `authoring-policy` to §8 once the MVP lands.

---

## Task 1: `extract-deftest-forms` (pure, reader-based)

**Files:**
- Create: `next/src/authoring-policy.lisp`
- Test: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Create the source file with the package and a stub**

```lisp
;;;; next/src/authoring-policy.lisp
;;;;
;;;; The test-authoring dial (spec docs/superpowers/specs/2026-06-14-test-authoring-design.md):
;;;; a goal-driven FSM that writes failing tests, gates them (RED-first +
;;;; LLM review), then delegates to an inner fix dial to implement to green.

(defpackage #:cl-harness-next/src/authoring-policy
  (:use #:cl)
  (:import-from #:cl-harness-next/src/action
                #:strip-code-fence)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:kernel-last-result
                #:kernel-last-action-error
                #:kernel-last-verdict)
  (:import-from #:cl-harness-next/src/oracle
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/template-policy
                #:discover-targets
                #:target-head)
  (:export #:extract-deftest-forms
           #:+test-author-system-prompt+
           #:authoring-policy
           #:policy-state
           #:policy-mode
           #:policy-goal
           #:policy-test-file
           #:policy-authored-names
           #:policy-fix-policy
           #:policy-reviewer))

(in-package #:cl-harness-next/src/authoring-policy)

(defparameter +ws+ '(#\Space #\Tab #\Newline #\Return #\Page))

(defun extract-deftest-forms (raw)
  "Stub — implemented in Task 1."
  (declare (ignore raw))
  nil)
```

- [ ] **Step 2: Write the failing tests**

```lisp
;;;; next/tests/authoring-policy-test.lisp

(defpackage #:cl-harness-next/tests/authoring-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/authoring-policy
                #:extract-deftest-forms
                #:authoring-policy
                #:policy-state
                #:policy-authored-names)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:run-kernel
                #:control-policy
                #:decide
                #:make-decision)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-queue
                #:enqueue-mission)
  (:import-from #:cl-harness-next/src/mission-runner
                #:run-mission)
  (:import-from #:cl-harness-next/src/governor
                #:governor))

(in-package #:cl-harness-next/tests/authoring-policy-test)

(deftest extract-deftest-accepts-one-form
  (multiple-value-bind (text names)
      (extract-deftest-forms "(deftest add-adds (ok (= 5 (add 2 3))))")
    (ok (stringp text))
    (ok (search "deftest" text))
    (ok (equal '("ADD-ADDS") names))))

(deftest extract-deftest-accepts-multiple-forms
  (multiple-value-bind (text names)
      (extract-deftest-forms
       "(deftest a (ok t))
(deftest b (ok t))")
    (ok (stringp text))
    (ok (equal '("A" "B") names))))

(deftest extract-deftest-strips-fence-and-trims
  (multiple-value-bind (text names)
      (extract-deftest-forms
       (format nil "```lisp~%(deftest c (ok (= 1 (f))))~%```"))
    (ok (search "deftest" text))
    (ok (equal '("C") names))))

(deftest extract-deftest-rejects-non-deftest
  (multiple-value-bind (text reason)
      (extract-deftest-forms "(defun add (a b) (+ a b))")
    (ok (null text))
    (ok (and (stringp reason) (search "deftest" reason)))))

(deftest extract-deftest-rejects-empty-and-prose
  (ok (null (extract-deftest-forms "   ")))
  (ok (null (extract-deftest-forms "I cannot help with that"))))

(deftest extract-deftest-rejects-unbalanced
  (ok (null (extract-deftest-forms "(deftest oops (ok (= 1 1))"))))
```

- [ ] **Step 3: Run the tests, verify they FAIL**

Run: `rove next/tests/authoring-policy-test.lisp` (or, once wired, `run-tests {"system":"cl-harness-next/tests","test":"…::extract-deftest-accepts-one-form"}`).
Expected: FAIL — `extract-deftest-forms` returns `nil` (stub).

- [ ] **Step 4: Implement `extract-deftest-forms`**

Replace the stub with:

```lisp
(defun %read-forms (text)
  "Read all top-level forms from TEXT under *read-eval* nil in CL-USER.
Returns (values forms error-string)."
  (let ((*package* (find-package :cl-user))
        (*read-eval* nil)
        (forms '()))
    (handler-case
        (with-input-from-string (s text)
          (loop for form = (read s nil s)
                until (eq form s)
                do (push form forms)))
      (error (c)
        (return-from %read-forms
          (values (nreverse forms) (princ-to-string c)))))
    (values (nreverse forms) nil)))

(defun %deftest-form-p (form)
  (and (consp form) (symbolp (first form))
       (string= (symbol-name (first form)) "DEFTEST")
       (symbolp (second form))))

(defun extract-deftest-forms (raw)
  "Validate RAW (an LLM reply) as one-or-more rove DEFTEST forms, parsed
with the Lisp reader (*read-eval* nil). Returns (values TEXT NAMES) on
success — TEXT the verbatim trimmed/de-fenced reply, NAMES the upcased
deftest-name strings — or (values NIL REASON) for the regenerate loop."
  (let ((text (string-trim +ws+ (strip-code-fence raw))))
    (when (zerop (length text))
      (return-from extract-deftest-forms
        (values nil "reply was empty; emit rove deftest form(s)")))
    (multiple-value-bind (forms err) (%read-forms text)
      (cond
        (err (values nil (format nil "unbalanced/unreadable reply: ~A" err)))
        ((null forms) (values nil "no forms; emit rove deftest form(s)"))
        ((not (every #'%deftest-form-p forms))
         (values nil "reply must be ONLY rove deftest form(s), nothing else"))
        (t (values text
                   (mapcar (lambda (f) (symbol-name (second f))) forms)))))))
```

- [ ] **Step 5: Run the tests, verify they PASS**

Expected: all six `extract-deftest-*` tests PASS.

- [ ] **Step 6: Commit**

```bash
git add next/src/authoring-policy.lisp next/tests/authoring-policy-test.lisp
git commit -m "feat(next): extract-deftest-forms (reader-based deftest validation)"
```

---

## Task 2: Author prompt (`+test-author-system-prompt+` + `%author-prompt`)

**Files:**
- Modify: `next/src/authoring-policy.lisp`
- Test: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest author-prompt-includes-goal-and-surface
  (let ((p (make-instance 'cl-harness-next/src/authoring-policy::authoring-policy
                          :goal "add must return a+b"
                          :system "s" :test-system "s/tests"
                          :test-file "tests/main-test.lisp"
                          :test-package "s/tests/main-test"
                          :author-fn (lambda (x) (declare (ignore x)) "")
                          :reviewer nil :fix-policy nil)))
    (setf (cl-harness-next/src/authoring-policy::policy-sut-package p) "S/SRC/MAIN"
          (cl-harness-next/src/authoring-policy::policy-sut-surface p)
          "(defun add (a b) 0)")
    (let ((prompt (cl-harness-next/src/authoring-policy::%author-prompt p)))
      (ok (search "add must return a+b" prompt))
      (ok (search "S/SRC/MAIN" prompt))
      (ok (search "(defun add (a b) 0)" prompt)))))
```

- [ ] **Step 2: Run it, verify it FAILS**

Expected: FAIL — `authoring-policy` class and `%author-prompt` not yet defined.

- [ ] **Step 3: Add the defclass and the prompt builder**

Append to `next/src/authoring-policy.lisp`:

```lisp
(defparameter +test-author-system-prompt+
  "You are a Common Lisp test author. Given a GOAL and the code under
test, reply with ONLY one or more rove DEFTEST forms exercising the
goal — no defpackage, no in-package, no prose, no markdown, no code
fence. Shape: (deftest NAME (ok EXPR) (ok EXPR) ...). Reference the code
under test by the symbols shown. The tests MUST fail against the current
(unimplemented/stub) code and pass once the goal is met."
  "System prompt for the test-author oracle; pair with MAKE-JUDGE-FN.")

(defclass authoring-policy (control-policy)
  ((mode :initarg :mode :initform :tdd :reader policy-mode)
   (goal :initarg :goal :reader policy-goal)
   (criteria :initarg :criteria :initform nil :reader policy-criteria)
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (source-file :initarg :source-file :initform "src/main.lisp"
                :reader policy-source-file)
   (test-file :initarg :test-file :reader policy-test-file)
   (test-package :initarg :test-package :reader policy-test-package)
   (author-fn :initarg :author-fn :reader policy-author-fn)
   (reviewer :initarg :reviewer :reader policy-reviewer)
   (fix-policy :initarg :fix-policy :reader policy-fix-policy)
   (clear-fasls-p :initarg :clear-fasls :initform t :reader %clear-fasls-p)
   (k :initarg :k :initform 3 :reader policy-k)
   (state :initform :init :accessor policy-state)
   (attempts :initform 0 :accessor policy-attempts)
   (feedback :initform nil :accessor policy-feedback)
   (sut-package :initform "CL-USER" :accessor policy-sut-package)
   (sut-surface :initform "" :accessor policy-sut-surface)
   (base-content :initform nil :accessor policy-base-content)
   (authored-names :initform nil :accessor policy-authored-names)
   (last-attempt-text :initform "" :accessor %last-attempt-text))
  (:documentation "Test-authoring dial (spec 2026-06-14). MVP mode :tdd:
author failing tests, gate them (RED-first + review), then delegate the
fix to FIX-POLICY. The fix dial patches src/ only, so it cannot weaken
the gated tests."))

(defun %author-prompt (policy)
  (format nil
          "GOAL:~%~A~@[~2%ACCEPTANCE CRITERIA:~%~{- ~A~%~}~]~2%~
CODE UNDER TEST (package ~A):~%~A~@[~2%PREVIOUS ATTEMPT REJECTED:~%~A~]~2%~
Reply with ONLY rove deftest form(s)."
          (policy-goal policy)
          (policy-criteria policy)
          (policy-sut-package policy)
          (policy-sut-surface policy)
          (policy-feedback policy)))
```

- [ ] **Step 4: Run it, verify it PASSES**

- [ ] **Step 5: Commit**

```bash
git add next/src/authoring-policy.lisp next/tests/authoring-policy-test.lisp
git commit -m "feat(next): authoring-policy class + author prompt"
```

---

## Task 3: Canned-transport test harness + a test-double inner fix policy

This task builds the integration-test scaffolding the FSM tasks (4–8) drive
against. No production code changes.

**Files:**
- Modify: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Add the canned transport and helpers**

Append to the test file:

```lisp
;;; --- canned cl-mcp transport -------------------------------------------
;;; Models a stub-`add` project: src has (defun add (a b) 0); the test
;;; file accumulates whatever the policy writes. run-tests reports the
;;; authored deftests RED until `impl-done-p' is flipped (the inner fix
;;; policy flips it), then GREEN.

(defclass tdd-transport (mcp-transport)
  ((src :initarg :src :reader tt-src)
   (test-content :initform "" :accessor tt-test-content)
   (impl-done-p :initform nil :accessor tt-impl-done-p)
   (load-bad-p :initform nil :accessor tt-load-bad-p)
   (test-edits :initform 0 :accessor tt-test-edits)
   (kill-count :initform 0 :accessor tt-kill-count)))

(defun %h (&rest plist) (alexandria:plist-hash-table plist :test 'equal))

(defun %enc (id result) ; JSON-RPC envelope
  (with-output-to-string (s)
    (yason:encode (%h "jsonrpc" "2.0" "id" id "result" result) s)))

(defun %text-result (text)
  (%h "content" (list (%h "type" "text" "text" text))))

(defun %ok () (%h "content" nil))

(defun %err (text)
  (%h "isError" t "content" (list (%h "type" "text" "text" text))))

;; run-tests result keyed off transport state. The authored deftest is
;; "ADD-ADDS"; while impl is not done it is RED with detail.
(defun %tdd-tests-result (transport)
  (if (tt-impl-done-p transport)
      (%h "passed" 1 "failed" 0)
      (%h "passed" 0 "failed" 1
          "failed_tests"
          (list (%h "test_name" "ADD-ADDS"
                    "form" "(= 5 (ADD 2 3))" "reason" "stub")))))

(defmethod transport-send-request ((tr tdd-transport) body)
  (let* ((p (yason:parse body)) (id (gethash "id" p))
         (method (gethash "method" p)))
    (cond
      ((null id) "")
      ((equal method "initialize") (%enc id (%h)))
      ((equal method "tools/list")
       (%enc id (%h "tools"
                    (mapcar (lambda (n) (%h "name" n))
                            '("fs-read-file" "fs-write-file" "lisp-edit-form"
                              "load-system" "run-tests" "pool-kill-worker")))))
      ((equal method "tools/call")
       (let* ((params (gethash "params" p))
              (tool (gethash "name" params))
              (args (gethash "arguments" params))
              (path (and (hash-table-p args) (gethash "path" args)))
              (fpath (and (hash-table-p args) (gethash "file_path" args))))
         (cond
           ((equal tool "fs-read-file")
            (%enc id (%text-result
                      (if (search "src" (or path ""))
                          (tt-src tr) (tt-test-content tr)))))
           ((member tool '("fs-write-file" "lisp-edit-form") :test #'equal)
            (when (search "test" (or fpath path ""))
              (incf (tt-test-edits tr))
              (setf (tt-test-content tr)
                    (or (gethash "content" args) (tt-test-content tr))))
            (%enc id (%ok)))
           ((equal tool "pool-kill-worker")
            (incf (tt-kill-count tr)) (%enc id (%ok)))
           ((equal tool "load-system")
            (if (tt-load-bad-p tr)
                (%enc id (%err "compile error")) (%enc id (%ok))))
           ((equal tool "run-tests")
            (if (tt-load-bad-p tr)
                (%enc id (%err "test system failed to load"))
                (%enc id (%tdd-tests-result tr))))
           (t (%enc id (%ok))))))
      (t (error "unexpected method ~S" method)))))
```

- [ ] **Step 2: Add a test-double inner fix policy + kernel builder + canned author/reviewer**

```lisp
;;; A trivial inner fix policy: flips the transport to "impl done", runs
;;; a clean-verify (kill→load→test), finishes. Records whether it ever
;;; edited the test file (it must not).
(defclass fake-fix-policy (control-policy)
  ((transport :initarg :transport :reader ff-transport)
   (state :initform :go :accessor ff-state)))

(defmethod decide ((policy fake-fix-policy) kernel)
  (declare (ignore kernel))
  (ecase (ff-state policy)
    (:go
     (setf (tt-impl-done-p (ff-transport policy)) t  ; "implemented"
           (ff-state policy) :verified)
     (make-decision :kind :act :tool "run-tests"
                    :arguments (%h "system" "s/tests")
                    :reason "fake fix: verify"))
    (:verified
     (make-decision :kind :finish :reason "clean verification green"))))

(defparameter *tdd-test-package* "S/TESTS/MAIN-TEST")

(defun approve-judge (prompt) (declare (ignore prompt)) "APPROVE: looks good")
(defun reject-judge  (prompt) (declare (ignore prompt)) "REJECT: too weak")

(defmacro with-tdd-kernel ((kernel &key author-fn (judge #'approve-judge)
                                        (src "(defpackage #:s/src/main (:use #:cl) (:export #:add))
(in-package #:s/src/main)
(defun add (a b) (declare (ignore a b)) 0)")
                                        transport-var)
                           &body body)
  (let ((tr (or transport-var (gensym "TR"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,tr (make-instance 'tdd-transport :src ,src))
              (log (open-event-log log-path))
              (env (make-cl-mcp-environment
                    :client (make-mcp-client ,tr)
                    :condition :runtime-native :event-log log))
              (reviewer (make-instance 'review-oracle :judge-fn ,judge
                                       :profile (list :id :tests-review
                                                      :strictness :strict)))
              (,kernel (make-kernel
                        :environment env :event-log log
                        :policy (make-instance 'authoring-policy
                                               :goal "add must return a+b"
                                               :system "s" :test-system "s/tests"
                                               :test-file "tests/main-test.lisp"
                                               :test-package *tdd-test-package*
                                               :author-fn ,author-fn
                                               :reviewer reviewer
                                               :fix-policy
                                               (make-instance 'fake-fix-policy
                                                              :transport ,tr)
                                               :clear-fasls t :k 3))))
         (declare (ignorable ,tr))
         ,@body))))

(defparameter *good-deftest*
  "(deftest add-adds (ok (= 5 (add 2 3))) (ok (= 0 (add 0 0))))")
```

- [ ] **Step 3: Commit (harness only; no behavior yet)**

```bash
git add next/tests/authoring-policy-test.lisp
git commit -m "test(next): canned transport + fake inner fix policy for authoring-policy"
```

---

## Task 4: FSM `:init` → source discovery → `:author` entry

Builds `decide` for `:init`/`:parse-source`/`:ensure-skeleton`. The act
sequence (one act per step): `fs-read-file(source)` → parse via
`discover-targets` → `fs-read-file(test-file)` → write skeleton if absent →
enter `:author`.

**Files:**
- Modify: `next/src/authoring-policy.lisp`
- Test: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest init-derives-sut-package-and-reaches-author
  (with-tdd-kernel (kernel :author-fn (lambda (p) (declare (ignore p))
                                         *good-deftest*)
                           :transport-var tr)
    ;; step the kernel a few times; it should pass :init/:parse/:skeleton
    ;; and write the skeleton + first authored deftest.
    (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
      (dotimes (_ 6) (cl-harness-next/src/kernel::kernel-step kernel))
      (ok (equal "S/SRC/MAIN" (cl-harness-next/src/authoring-policy::policy-sut-package policy)))
      (ok (search "(in-package #:s/tests/main-test)" (tt-test-content tr)))
      (ok (search "deftest add-adds" (tt-test-content tr))))))
```

(`kernel-step` / `kernel-policy` are reached with `::` internal access, so no
import is needed.)

- [ ] **Step 2: Run it, verify it FAILS** (no `decide` method yet → error/abort).

- [ ] **Step 3: Implement the init sub-FSM + helpers**

Append to `next/src/authoring-policy.lisp`:

```lisp
(defun %result-text (result)
  (when (hash-table-p result)
    (let ((content (gethash "content" result)))
      (when (and content (plusp (length content)))
        (let ((entry (elt content 0)))
          (when (hash-table-p entry) (gethash "text" entry)))))))

(defun %skeleton (policy)
  (format nil "(defpackage #:~A~%  (:use #:cl #:rove #:~A))~%~%(in-package #:~A)~%"
          (policy-test-package policy)
          (string-downcase (policy-sut-package policy))
          (policy-test-package policy)))

(defun %act (tool args reason)
  (make-decision :kind :act :tool tool
                 :arguments (alexandria:plist-hash-table args :test #'equal)
                 :reason reason))

(defun %read-source (policy)
  (setf (policy-state policy) :parse-source)
  (%act "fs-read-file" (list "path" (policy-source-file policy))
        "read source for SUT surface"))

(defun %parse-source (policy kernel)
  (let ((src (%result-text (kernel-last-result kernel))))
    (when (stringp src)
      (multiple-value-bind (targets class-text sut-package)
          (discover-targets src (policy-source-file policy))
        (when sut-package (setf (policy-sut-package policy) sut-package))
        (setf (policy-sut-surface policy)
              (format nil "~@[~A~2%~]~{~A~%~}"
                      (when (plusp (length class-text)) class-text)
                      (mapcar #'target-head targets))))))
  (setf (policy-state policy) :ensure-skeleton)
  (%act "fs-read-file" (list "path" (policy-test-file policy))
        "read test file"))

(defun %ensure-skeleton (policy kernel)
  (let ((existing (or (%result-text (kernel-last-result kernel)) "")))
    (if (search "(in-package" existing)
        (progn (setf (policy-base-content policy) existing)
               (%author policy))   ; emits the first author act
        (progn
          (setf (policy-base-content policy) (%skeleton policy)
                (policy-state policy) :author-skeleton-written)
          (%act "fs-write-file"
                (list "file_path" (policy-test-file policy)
                      "content" (%skeleton policy))
                "write test-file defpackage skeleton")))))
```

(`%author` is added in Task 5; for this task's test to pass, stub `%author`
to write the deftest and stop — but cleaner: implement Task 5 next and run
both tests. If executing strictly task-by-task, temporarily stub `%author`
to `(progn (setf (policy-state policy) :done-stub) (make-decision :kind :give-up :reason "author not yet"))` and assert only the skeleton+sut-package in Step 1; replace in Task 5.)

- [ ] **Step 4: Add the `decide` method skeleton (states filled across Tasks 4–8)**

```lisp
(defmethod decide ((policy authoring-policy) kernel)
  (ecase (policy-state policy)
    (:init (%read-source policy))
    (:parse-source (%parse-source policy kernel))
    (:ensure-skeleton (%ensure-skeleton policy kernel))
    (:author-skeleton-written (%author policy))
    (:author (%author policy))
    (:author-written (%author-written policy kernel))
    (:author-loaded (%author-loaded policy kernel))
    (:author-verify (%author-verify policy kernel))
    (:author-reviewed (%author-reviewed policy kernel))
    (:fix (decide (policy-fix-policy policy) kernel))))
```

- [ ] **Step 5: Run the test, verify it PASSES** (with Task 5's `%author` in place, the skeleton + first deftest are written and `sut-package` is `"S/SRC/MAIN"`).

- [ ] **Step 6: Commit**

```bash
git add next/src/authoring-policy.lisp next/tests/authoring-policy-test.lisp
git commit -m "feat(next): authoring-policy :init source discovery + skeleton"
```

---

## Task 5: FSM `:author` → write → load

`:author` builds the prompt, calls `author-fn`, validates via
`extract-deftest-forms`, writes `base-content + attempt`, then loads.

**Files:**
- Modify: `next/src/authoring-policy.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest author-writes-validated-deftests-then-loads
  (let ((calls 0))
    (with-tdd-kernel (kernel
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*)
                      :transport-var tr)
      (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
        (dotimes (_ 9) (cl-harness-next/src/kernel::kernel-step kernel))
        (ok (>= calls 1))
        (ok (equal '("ADD-ADDS") (policy-authored-names policy)))
        (ok (search "deftest add-adds" (tt-test-content tr)))
        ;; base skeleton retained, deftest appended after it
        (ok (search "(in-package" (tt-test-content tr)))))))
```

- [ ] **Step 2: Run it, verify it FAILS** (no `%author`/`%author-written`/`%author-loaded`).

- [ ] **Step 3: Implement `%author`, `%author-written`, `%author-loaded`, `%regenerate`**

```lisp
(defun %regenerate (policy reason)
  "Record feedback and re-author within K, else give up."
  (incf (policy-attempts policy))
  (setf (policy-feedback policy) reason)
  (if (< (policy-attempts policy) (policy-k policy))
      (%author policy)
      (make-decision :kind :give-up
                     :reason (format nil "could not author acceptable tests: ~A"
                                     reason))))

(defun %author (policy)
  "Sample deftest form(s), validate, and emit the test-file write."
  (let ((raw (handler-case (funcall (policy-author-fn policy)
                                    (%author-prompt policy))
               (error (c) (setf (policy-feedback policy)
                                (format nil "author call error: ~A" c))
                 nil))))
    (if (null raw)
        (%regenerate policy (policy-feedback policy))
        (multiple-value-bind (text names) (extract-deftest-forms raw)
          (if (null text)
              (%regenerate policy names)   ; names holds the reason here
              (progn
                (setf (policy-authored-names policy) names
                      (%last-attempt-text policy) text
                      (policy-state policy) :author-written)
                (%act "fs-write-file"
                      (list "file_path" (policy-test-file policy)
                            "content" (format nil "~A~%~%~A~%"
                                              (policy-base-content policy) text))
                      "write authored tests")))))))

(defun %author-written (policy kernel)
  (if (kernel-last-action-error kernel)
      (%regenerate policy (format nil "writing tests failed: ~A"
                                  (kernel-last-action-error kernel)))
      (progn
        (setf (policy-state policy) :author-loaded)
        (%act "load-system"
              (append (list "system" (policy-test-system policy))
                      (when (%clear-fasls-p policy) (list "clear_fasls" t)))
              "load the authored test system"))))

(defun %author-loaded (policy kernel)
  (if (kernel-last-action-error kernel)
      ;; the authored deftest did not compile — malformed, regenerate.
      (%regenerate policy (format nil "authored tests did not load: ~A"
                                  (kernel-last-action-error kernel)))
      (progn
        (setf (policy-state policy) :author-verify)
        (%act "run-tests" (list "system" (policy-test-system policy))
              "RED-first: authored tests must fail"))))
```

- [ ] **Step 4: Run the test, verify it PASSES**

- [ ] **Step 5: Commit**

```bash
git add next/src/authoring-policy.lisp next/tests/authoring-policy-test.lisp
git commit -m "feat(next): authoring-policy :author write+load with regenerate loop"
```

---

## Task 6: FSM `:author-verify` (RED-first)

The authored tests must all appear in `failed_tests` (red) on a clean load.
Green-already (vacuous / already-met) or a non-compiling test → regenerate.

**Files:**
- Modify: `next/src/authoring-policy.lisp`
- Test: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Write the failing tests**

```lisp
(deftest red-first-vacuous-test-is-regenerated
  ;; author-fn returns a tautology first (which the transport reports
  ;; green because impl-done starts NIL but the test asserts nothing real)
  ;; — emulate "green already" by flipping impl-done before verify.
  (let ((calls 0))
    (with-tdd-kernel (kernel :transport-var tr
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls)
                                   (when (= calls 1) (setf (tt-impl-done-p tr) t))
                                   *good-deftest*))
      ;; first attempt: tests come back green → must regenerate (≥2 calls).
      (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
        (declare (ignore policy))
        (dotimes (_ 12) (cl-harness-next/src/kernel::kernel-step kernel))
        (ok (>= calls 2))))))
```

(The red→review→fix path is exercised in Task 7, where `%author-reviewed`
exists; Task 6 only locks the RED-first **rejection** of a green/vacuous
authored set.)

- [ ] **Step 2: Run, verify FAILS** (`%author-verify` undefined).

- [ ] **Step 3: Implement `%author-verify` + RED-first helper + review emission**

```lisp
(defun %mentions (needle text)
  (and (stringp text) (search needle text :test #'char-equal) t))

(defun %name-in-failures-p (name failed)
  (some (lambda (entry)
          (and (hash-table-p entry)
               (%mentions name (gethash "test_name" entry))))
        (coerce (or failed #()) 'list)))

(defun %authored-tests-red-p (policy result)
  "True only on positive evidence the authored tests fail: a clean load
gave a failed_tests array and EVERY authored name appears in it."
  (and (hash-table-p result)
       (not (gethash "isError" result))
       (let ((failed (gethash "failed_tests" result)))
         (and failed (plusp (length failed))
              (every (lambda (n) (%name-in-failures-p n failed))
                     (policy-authored-names policy))))))

(defun %review-subject (policy)
  ;; %LAST-ATTEMPT-TEXT holds the just-authored deftest text (set in %author);
  ;; VERDICT-REASON is imported in the defpackage (Task 1).
  (format nil "GOAL:~%~A~@[~2%ACCEPTANCE CRITERIA:~%~{- ~A~%~}~]~2%~
Do these rove tests faithfully and non-trivially encode the goal? \
Reject tautologies / empty tests / tests that dodge the goal.~2%~
AUTHORED TESTS:~%~A"
          (policy-goal policy) (policy-criteria policy)
          (%last-attempt-text policy)))

(defun %emit-review (policy)
  (setf (policy-state policy) :author-reviewed)
  (make-decision :kind :consult :oracle (policy-reviewer policy)
                 :subject (%review-subject policy)
                 :reason "review authored tests against the goal"))

(defun %author-verify (policy kernel)
  (if (%authored-tests-red-p policy (kernel-last-result kernel))
      (%emit-review policy)
      (%regenerate policy
                   "your tests passed on the unfixed code (vacuous or already \
met); assert the goal so they fail until it is implemented")))
```

- [ ] **Step 4: Run, verify PASSES**

- [ ] **Step 5: Commit**

```bash
git add next/src/authoring-policy.lisp next/tests/authoring-policy-test.lisp
git commit -m "feat(next): authoring-policy RED-first gate (:author-verify)"
```

---

## Task 7: FSM `:author-review` (consult the review oracle)

After RED-first, `:consult` the injected `review-oracle` with a subject
string (goal + criteria + authored tests). Approve → `:fix`; reject →
regenerate with the judge feedback.

**Files:**
- Modify: `next/src/authoring-policy.lisp`
- Test: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Write the failing tests**

```lisp
(deftest review-reject-regenerates-then-gives-up
  (let ((calls 0))
    (with-tdd-kernel (kernel :judge #'reject-judge
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
        (ok (eq :given-up status))
        (ok (and (stringp reason) (search "author" reason))))
      (ok (>= calls 3)))))               ; K attempts, each judge-rejected

(deftest review-approve-advances-to-fix
  (with-tdd-kernel (kernel :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*))
    (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
      (dotimes (_ 12) (cl-harness-next/src/kernel::kernel-step kernel))
      (ok (eq :fix (policy-state policy))))))
```

- [ ] **Step 2: Run, verify FAILS** (`%author-reviewed` undefined; the
  `:author-reviewed` ecase clause has nothing to call).

- [ ] **Step 3: Implement `%author-reviewed`** (`%emit-review` / `%review-subject`
  were added in Task 6)

```lisp
(defun %author-reviewed (policy kernel)
  (let ((verdict (kernel-last-verdict kernel)))
    (if (and verdict (verdict-pass-p verdict))
        (progn (setf (policy-state policy) :fix)
               (decide (policy-fix-policy policy) kernel))
        (%regenerate policy
                     (format nil "review rejected the tests: ~A"
                             (and verdict (verdict-reason verdict)))))))
```

- [ ] **Step 4: Run, verify PASSES**

- [ ] **Step 5: Commit**

```bash
git add next/src/authoring-policy.lisp next/tests/authoring-policy-test.lisp
git commit -m "feat(next): authoring-policy review gate (:author-review)"
```

---

## Task 8: `:fix` delegation + happy path + phase-separation

`:fix` is already wired in `decide` (Task 4). Add the end-to-end happy-path
and the integrity (phase-separation) tests.

**Files:**
- Test: `next/tests/authoring-policy-test.lisp`

- [ ] **Step 1: Write the failing/【will pass】 tests**

```lisp
(deftest authoring-happy-path-reaches-done
  (with-tdd-kernel (kernel :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :transport-var tr)
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))))

(deftest fix-phase-never-edits-the-test-file
  ;; phase separation: after the gate, the (fake) fix dial must issue no
  ;; further test-file writes. Capture the edit count at the moment the
  ;; gate passes vs. at :done.
  (with-tdd-kernel (kernel :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :transport-var tr)
    (run-kernel kernel :max-steps 60)
    ;; exactly one accepted authoring write (skeleton write + one author
    ;; write = 2 test-file writes total for a first-try success); the fake
    ;; fix policy adds none.
    (ok (= 2 (tt-test-edits tr)))))
```

- [ ] **Step 2: Run, verify PASS** (the FSM is complete; the fake fix policy
  flips `impl-done` and finishes; clean-verify is modeled by the transport
  returning green once `impl-done`).

- [ ] **Step 3: Commit**

```bash
git add next/tests/authoring-policy-test.lisp
git commit -m "test(next): authoring-policy happy path + phase-separation"
```

---

## Task 9: ASDF wiring + facade re-export

**Files:**
- Modify: `cl-harness-next.asd`
- Modify: `next/src/main.lisp`

- [ ] **Step 1: Add the test system component**

In `cl-harness-next.asd`, in the `"cl-harness-next/tests"` `:depends-on` list,
add after `"cl-harness-next/tests/template-policy-test"`:

```lisp
               "cl-harness-next/tests/authoring-policy-test"
```

- [ ] **Step 2: Re-export from the facade**

In `next/src/main.lisp`, add an `:import-from` block (near the other policy
imports) and the names to the `:export` list:

```lisp
  (:import-from #:cl-harness-next/src/authoring-policy
                #:authoring-policy
                #:+test-author-system-prompt+)
```

and in `:export`:

```lisp
           #:authoring-policy
           #:+test-author-system-prompt+
```

- [ ] **Step 3: Compile the whole system to surface warnings**

Run (REPL or `repl-eval`): `(asdf:compile-system :cl-harness-next :force t)`
Expected: no warnings beyond the benign ASDF `test-op` PERFORM redefinition.

- [ ] **Step 4: Run the full suite**

Run: `run-tests {"system":"cl-harness-next/tests"}`
Expected: all green (existing + the new `authoring-policy-test`).

- [ ] **Step 5: Lint**

Run: `mallet next/src/authoring-policy.lisp`
Expected: `✓ No problems found.` (fix `let*`→`let`, unused vars, etc. if flagged).

- [ ] **Step 6: Commit**

```bash
git add cl-harness-next.asd next/src/main.lisp
git commit -m "feat(next): wire authoring-policy into asd + facade re-export"
```

---

## Task 10: End-to-end runner (`tools/run-tdd.lisp`)

A standalone runner mirroring `tools/run-template.lisp`, driving a TDD
bootstrap on a **stub-`add`** project (no tests yet) with the real LLM.

**Files:**
- Create: `tools/run-tdd.lisp`

- [ ] **Step 1: Write the runner**

```lisp
;;;; run-tdd.lisp — TDD bootstrap with cl-harness-next authoring-policy.
;;;; The LLM authors failing tests (gated RED-first + review); template-fix
;;;; fills the stub. Needs CL_HARNESS_LLM_* + MCP_PROJECT_ROOT(=stub project).
;;;;   ros run --load run-tdd.lisp

(require :asdf)
(asdf:load-system :cl-harness-next)
(asdf:load-system "cl-harness-next/src/template-policy")

(defpackage #:run-tdd (:use #:cl #:cl-harness-next))
(in-package #:run-tdd)

(defun env (n) (or (uiop:getenv n) (error "missing ~A" n)))

(defun thinking-off ()
  (let ((ctk (make-hash-table :test 'equal)) (top (make-hash-table :test 'equal)))
    (setf (gethash "enable_thinking" ctk) 'yason:false
          (gethash "chat_template_kwargs" top) ctk)
    top))

(defparameter *provider*
  (make-openai-provider :base-url (env "CL_HARNESS_LLM_BASE_URL")
                        :api-key (env "CL_HARNESS_LLM_API_KEY")
                        :model (env "CL_HARNESS_LLM_MODEL")
                        :max-tokens 2048 :extra-body (thinking-off)))

(defparameter *system* "clh-demo")
(defparameter *test-system* "clh-demo/tests")

(defun env-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment :condition :runtime-native :event-log log))

(defun policy-factory (mission)
  (make-instance 'cl-harness-next/src/authoring-policy:authoring-policy
   :mode :tdd
   :goal (cl-harness-next:mission-goal mission)
   :system *system* :test-system *test-system*
   :source-file "src/main.lisp"
   :test-file "tests/main-test.lisp"
   :test-package "clh-demo/tests/main-test"
   :author-fn (make-judge-fn
               *provider*
               :system-prompt
               cl-harness-next/src/authoring-policy:+test-author-system-prompt+)
   :reviewer (make-instance 'cl-harness-next/src/review-oracle:review-oracle
              :judge-fn (make-judge-fn *provider*)
              :profile (list :id :tests-review :strictness :strict
                             :instructions
                             "Approve only rove tests that genuinely assert the goal."))
   :fix-policy (make-instance 'cl-harness-next/src/template-policy:template-fix-policy
                :system *system* :test-system *test-system*
                :snippet-fn (make-judge-fn
                             *provider*
                             :system-prompt
                             cl-harness-next/src/template-policy:+template-snippet-system-prompt+)
                :source-files (list "src/main.lisp") :clear-fasls t :k 3)
   :clear-fasls t :k 3))

(defun governor-factory (mission)
  (declare (ignore mission))
  (make-instance 'governor :max-actions 300
                 :max-consecutive-failed-patches nil
                 :max-stalled-verify-cycles nil
                 :max-consecutive-identical-actions nil))

(defun main ()
  (let* ((log-path (merge-pathnames (format nil "tdd-~A.jsonl" (get-universal-time))
                                    (uiop:temporary-directory)))
         (mission (make-instance 'mission :id "tdd-add"
                    :goal "Implement (add a b) to return the sum a+b, with tests."
                    :acceptance-criteria (list "clh-demo/tests is green")
                    :log-path log-path))
         (queue (make-instance 'mission-queue)))
    (enqueue-mission queue mission)
    (format t "~&;;; tdd log: ~A~%" log-path) (finish-output)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'env-factory
                     :policy-factory #'policy-factory
                     :governor-factory #'governor-factory
                     :max-steps 300)
      (format t "~&;;; STATUS: ~A~%;;; REASON: ~A~%" status reason)
      (finish-output)
      (uiop:quit (if (eq status :done) 0 1)))))

(main)
```

- [ ] **Step 2: Prepare the stub fixture (one-time, manual)**

Create `~/.roswell/local-projects/clh-demo/` as in README §3 **but** with a
**stub** `src/main.lisp` and **no** `tests/main-test.lisp`:

```lisp
(defpackage #:clh-demo/src/main (:use #:cl) (:export #:add))
(in-package #:clh-demo/src/main)
(defun add (a b) (declare (ignore a b)) 0)   ; stub
```

(The `clh-demo/tests` system's `:depends-on` should reference
`clh-demo/tests/main-test`; the file is created by the run. If ASDF requires
the file to exist to load the system, seed an empty
`tests/main-test.lisp` with just the defpackage skeleton.)

- [ ] **Step 3: Run end-to-end (real LLM)**

```bash
CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1 \
CL_HARNESS_LLM_API_KEY=dummy \
CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B \
MCP_PROJECT_ROOT=$HOME/.roswell/local-projects/clh-demo \
ros run --load tools/run-tdd.lisp
```
Expected: `;;; STATUS: DONE`. Inspect the log; confirm an authored `deftest`
was written, RED-first verified, review APPROVED, then template-fix filled the
`add` stub to clean-green. Record the outcome in
`docs/notes/2026-06-14-tdd-authoring-experiment.md` (status, log path, the
authored test, any retries).

- [ ] **Step 4: Commit**

```bash
git add tools/run-tdd.lisp docs/notes/2026-06-14-tdd-authoring-experiment.md
git commit -m "feat(next): TDD bootstrap e2e runner + experiment note"
```

---

## Task 11: README §8 — document `authoring-policy`

**Files:**
- Modify: `next/README.md`

- [ ] **Step 1: Add an `authoring-policy` subsection to §8**

Add after the dial subsections a short block: `authoring-policy` is a **mode
above the fix dials** (not a fix dial) — it authors failing tests from the
goal, gates them RED-first + LLM review, then delegates to an inner fix dial
(default `template-fix`). Note it is **stub-fill TDD bootstrap** in the MVP,
the inner fix dial is injected via `:fix-policy`, and the reviewer is a
`review-oracle`. Point to `tools/run-tdd.lisp` and the spec.

- [ ] **Step 2: Commit**

```bash
git add next/README.md
git commit -m "docs(next): document authoring-policy (TDD bootstrap) in README §8"
```

---

## Self-review checklist (run by the implementer before opening the PR)

- [ ] Spec §3–§8 (FSM phases, integrity, components) each map to a task.
- [ ] No placeholder steps; every code step shows real code.
- [ ] Names consistent: `policy-sut-package`, `%authored-tests-red-p`,
  `%author`, `%emit-review`, `policy-fix-policy`, `%last-attempt-text`,
  `extract-deftest-forms`, `+test-author-system-prompt+` used identically across
  tasks.
- [ ] `verdict-reason` imported in the policy package (used in Task 7).
- [ ] `mission-goal` is exported from the facade (used in `tools/run-tdd.lisp`);
  if not, import from `cl-harness-next/src/mission`.
- [ ] Full suite green, `mallet` clean, `compile-system :force t` warning-free.
- [ ] Scope held to `:mode :tdd`; `:spec-change` / `:coverage` not built (spec §9).
```
