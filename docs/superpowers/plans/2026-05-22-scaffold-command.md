# Scaffold Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a deterministic, LLM-free `cl-harness scaffold` subcommand that emits a 4-file ASDF + rove skeleton matching the `develop-benchmarks/100-greet/fixture/` layout, so users can bootstrap a project shell before invoking `cl-harness develop`.

**Architecture:** New self-contained module `src/scaffold.lisp` holds templates, validation, detection, and a single `scaffold` entry function returning a `scaffold-result`. The facade in `src/main.lisp` re-exports the public surface, `src/cli-main.lisp` adds a clingon subcommand, and `cl-harness.asd` picks up the new file via the package-inferred-system dependency graph.

**Tech Stack:** SBCL + ASDF (package-inferred-system), `uiop` for file IO and string ops, `cl-ppcre` (already transitively available via existing deps) is NOT used — we hand-roll a tiny regex check to keep deps minimal. Tests via `rove`. CLI dispatch via `clingon`.

**Spec:** `docs/superpowers/specs/2026-05-22-scaffold-command-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/scaffold.lisp` | Create | Templates, validation, detection, `scaffold` entry function, conditions |
| `tests/scaffold-test.lisp` | Create | 10 deftests covering happy/refuse/force/override paths (LLM-free) |
| `cl-harness.asd` | Modify (L29-53) | Append `cl-harness/tests/scaffold-test` to the test-system `:depends-on` list |
| `src/main.lisp` | Modify (L9-54, L240-280) | `:import-from` + `:export` for the public scaffold surface |
| `src/cli-main.lisp` | Modify (L295-310) | New `scaffold-options` / `scaffold-handler` / `scaffold-command` + register under `top-command`'s `:sub-commands` |
| `README.md` | Modify (Quick start) | New "Scaffold a new project" subsection before "Fix one project" |
| `docs/cl-harness-prd.md` | Modify (append) | New `§19 Scaffold subcommand` section |

The library system `cl-harness/src/main` picks up `cl-harness/src/scaffold` automatically because we add an `:import-from` clause to `src/main.lisp`'s `defpackage`. No explicit `.asd` change is needed for the library system — only the test-system needs the new test file registered.

---

## Task 1: Bootstrap empty scaffold module + test stub

**Files:**
- Create: `src/scaffold.lisp`
- Create: `tests/scaffold-test.lisp`
- Modify: `cl-harness.asd` (test-system `:depends-on`)

- [ ] **Step 1: Create the empty source package**

Write `src/scaffold.lisp`:

```lisp
;;;; src/scaffold.lisp
;;;;
;;;; LLM-free, deterministic ASDF + rove scaffold generator.
;;;; Spec: docs/superpowers/specs/2026-05-22-scaffold-command-design.md

(defpackage #:cl-harness/src/scaffold
  (:use #:cl)
  (:export #:scaffold
           #:scaffold-result
           #:scaffold-result-status
           #:scaffold-result-paths-written
           #:scaffold-result-conflicts
           #:scaffold-error
           #:scaffold-error-message
           #:scaffold-bad-system-name
           #:scaffold-bad-system-name-name
           #:scaffold-partial-state
           #:scaffold-partial-state-existing
           #:scaffold-partial-state-missing))

(in-package #:cl-harness/src/scaffold)
```

- [ ] **Step 2: Create the empty test package**

Write `tests/scaffold-test.lisp`:

```lisp
;;;; tests/scaffold-test.lisp
;;;;
;;;; rove deftests for cl-harness/src/scaffold. All tests run against
;;;; uiop:with-temporary-directory tmpdirs and never touch the network
;;;; or an LLM provider.

(defpackage #:cl-harness/tests/scaffold-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/scaffold
                #:scaffold
                #:scaffold-result
                #:scaffold-result-status
                #:scaffold-result-paths-written
                #:scaffold-result-conflicts
                #:scaffold-bad-system-name
                #:scaffold-partial-state
                #:scaffold-partial-state-existing
                #:scaffold-partial-state-missing))

(in-package #:cl-harness/tests/scaffold-test)
```

- [ ] **Step 3: Register the test file with the test-system**

Modify `cl-harness.asd` — append `"cl-harness/tests/scaffold-test"` to the test-system `:depends-on` list (right before the closing paren on line 53, after `"cl-harness/tests/review-test"`):

```lisp
               "cl-harness/tests/review-test"
               "cl-harness/tests/scaffold-test")
```

- [ ] **Step 4: Verify the system compiles cleanly**

Run via cl-mcp `load-system`:
```
{"system": "cl-harness", "force": true}
```
Expected: `success: true`, no `:STYLE-WARNING` from `:CL-HARNESS/SRC/SCAFFOLD`.

Then load tests:
```
{"system": "cl-harness/tests", "force": true}
```
Expected: `success: true`.

- [ ] **Step 5: Commit**

```bash
git add src/scaffold.lisp tests/scaffold-test.lisp cl-harness.asd
git commit -m "scaffold: bootstrap empty src/scaffold.lisp + test stub

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: System name validation + bad-name condition

**Files:**
- Modify: `src/scaffold.lisp` (add conditions + `%validate-system-name`)
- Modify: `tests/scaffold-test.lisp` (add `system-name-validation` deftest)

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest system-name-validation
  (testing "valid system names pass"
    (ok (cl-harness/src/scaffold::%validate-system-name "demo"))
    (ok (cl-harness/src/scaffold::%validate-system-name "foo-bar"))
    (ok (cl-harness/src/scaffold::%validate-system-name "a1")))
  (testing "invalid system names raise scaffold-bad-system-name"
    (dolist (bad '("Demo" "foo_bar" "" "0name" "-leading" "trailing-"))
      (ok (handler-case
              (progn (cl-harness/src/scaffold::%validate-system-name bad) nil)
            (scaffold-bad-system-name () t))
          (format nil "~S should be rejected" bad)))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run via cl-mcp `run-tests`:
```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::system-name-validation"}
```
Expected: failure with "undefined function" or "symbol not found" for `%validate-system-name`.

- [ ] **Step 3: Implement conditions + validator**

Append to `src/scaffold.lisp` (after `(in-package ...)`):

```lisp
(define-condition scaffold-error (error)
  ((message :initarg :message :reader scaffold-error-message))
  (:report (lambda (c s) (write-string (scaffold-error-message c) s))))

(define-condition scaffold-bad-system-name (scaffold-error)
  ((name :initarg :name :reader scaffold-bad-system-name-name)))

(define-condition scaffold-partial-state (scaffold-error)
  ((existing :initarg :existing :reader scaffold-partial-state-existing)
   (missing  :initarg :missing  :reader scaffold-partial-state-missing)))

(defun %valid-system-name-char-p (c first-p)
  (or (and first-p (char<= #\a c #\z))
      (and (not first-p)
           (or (char<= #\a c #\z)
               (char<= #\0 c #\9)
               (char= c #\-)))))

(defun %validate-system-name (name)
  "Return T if NAME matches ^[a-z][a-z0-9-]*$ and does not end with -.
Raise SCAFFOLD-BAD-SYSTEM-NAME otherwise."
  (let ((reject (lambda ()
                  (error 'scaffold-bad-system-name
                         :name name
                         :message
                         (format nil "invalid system name ~S — must match ^[a-z][a-z0-9-]*$ and not end with '-'"
                                 name)))))
    (unless (and (stringp name) (plusp (length name)))
      (funcall reject))
    (loop for i from 0 below (length name)
          for ch = (char name i)
          unless (%valid-system-name-char-p ch (zerop i))
          do (funcall reject))
    (when (char= (char name (1- (length name))) #\-)
      (funcall reject))
    t))
```

- [ ] **Step 4: Run the test to verify it passes**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::system-name-validation"}
```
Expected: 1 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add src/scaffold.lisp tests/scaffold-test.lisp
git commit -m "scaffold: %validate-system-name + condition hierarchy

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Path derivation helpers

**Files:**
- Modify: `src/scaffold.lisp`
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest path-derivation
  (let ((root #P"/tmp/demo/"))
    (testing "asd path"
      (ok (equal #P"/tmp/demo/demo.asd"
                 (cl-harness/src/scaffold::%asd-path root "demo"))))
    (testing "src/main.lisp path"
      (ok (equal #P"/tmp/demo/src/main.lisp"
                 (cl-harness/src/scaffold::%src-main-path root))))
    (testing "tests/main-test.lisp default path"
      (ok (equal #P"/tmp/demo/tests/main-test.lisp"
                 (cl-harness/src/scaffold::%default-test-file-path root))))
    (testing ".gitignore path"
      (ok (equal #P"/tmp/demo/.gitignore"
                 (cl-harness/src/scaffold::%gitignore-path root))))
    (testing "default test-system from system"
      (ok (equal "demo/tests"
                 (cl-harness/src/scaffold::%default-test-system "demo"))))))
```

- [ ] **Step 2: Run to verify failure**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::path-derivation"}
```
Expected: undefined function failures.

- [ ] **Step 3: Implement path helpers**

Append to `src/scaffold.lisp`:

```lisp
(defun %ensure-pathname (root)
  "Coerce ROOT to a directory pathname (trailing slash enforced)."
  (uiop:ensure-directory-pathname root))

(defun %asd-path (root system)
  (merge-pathnames (format nil "~A.asd" system) (%ensure-pathname root)))

(defun %src-main-path (root)
  (merge-pathnames "src/main.lisp" (%ensure-pathname root)))

(defun %default-test-file-path (root)
  (merge-pathnames "tests/main-test.lisp" (%ensure-pathname root)))

(defun %gitignore-path (root)
  (merge-pathnames ".gitignore" (%ensure-pathname root)))

(defun %default-test-system (system)
  (format nil "~A/tests" system))
```

- [ ] **Step 4: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::path-derivation"}
```
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add src/scaffold.lisp tests/scaffold-test.lisp
git commit -m "scaffold: path derivation helpers (%asd-path, %src-main-path, etc.)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Template rendering functions

**Files:**
- Modify: `src/scaffold.lisp`
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest template-rendering
  (let ((asd (cl-harness/src/scaffold::%render-asd "demo" "demo/tests"))
        (src (cl-harness/src/scaffold::%render-src-main "demo"))
        (tst (cl-harness/src/scaffold::%render-tests-main "demo/tests"))
        (ign (cl-harness/src/scaffold::%render-gitignore)))
    (testing "asd template"
      (ok (search ":class :package-inferred-system" asd))
      (ok (search "(asdf:defsystem \"demo\"" asd))
      (ok (search "(asdf:defsystem \"demo/tests\"" asd))
      (ok (search "uiop:string-prefix-p \"demo/tests/\"" asd))
      (ok (search "uiop:symbol-call :rove :run" asd)))
    (testing "src/main.lisp template"
      (ok (search "(defpackage #:demo/src/main" src))
      (ok (search "(:nicknames #:demo)" src))
      (ok (search "(:use #:cl)" src))
      (ok (search "(:export)" src))
      (ok (search "(in-package #:demo/src/main)" src))
      (ok (search "Generated by cl-harness scaffold" src)))
    (testing "tests/main-test.lisp template"
      (ok (search "(defpackage #:demo/tests/main-test" tst))
      (ok (search "(:use #:cl #:rove)" tst))
      (ok (search "(in-package #:demo/tests/main-test)" tst)))
    (testing ".gitignore template"
      (ok (search "*.fasl" ign))
      (ok (search "*.fasl-tmp" ign))
      (ok (search ".cache/" ign)))))
```

- [ ] **Step 2: Run to verify failure**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::template-rendering"}
```
Expected: undefined function errors.

- [ ] **Step 3: Implement templates**

Append to `src/scaffold.lisp`:

```lisp
(defun %render-asd (system test-system)
  (format nil "~
(asdf:defsystem \"~A\"
  :class :package-inferred-system
  :description \"TODO: short description\"
  :license \"MIT\"
  :version \"0.0.1\"
  :depends-on (\"~A/src/main\")
  :in-order-to ((test-op (test-op \"~A\"))))

(asdf:defsystem \"~A\"
  :class :package-inferred-system
  :depends-on (\"rove\"
               \"~A\"
               \"~A/main-test\")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p \"~A/\" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))
"
          system system test-system
          test-system
          system test-system
          test-system))

(defun %render-src-main (system)
  (format nil "~
;;;; src/main.lisp
;;;;
;;;; Generated by cl-harness scaffold.

(defpackage #:~A/src/main
  (:nicknames #:~A)
  (:use #:cl)
  (:export))

(in-package #:~A/src/main)
"
          system system system))

(defun %render-tests-main (test-system)
  (format nil "~
;;;; tests/main-test.lisp
;;;;
;;;; Generated by cl-harness scaffold.

(defpackage #:~A/main-test
  (:use #:cl #:rove))

(in-package #:~A/main-test)
"
          test-system test-system))

(defun %render-gitignore ()
  "*.fasl
*.fasl-tmp
.cache/
")
```

- [ ] **Step 4: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::template-rendering"}
```
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add src/scaffold.lisp tests/scaffold-test.lisp
git commit -m "scaffold: render-asd / render-src-main / render-tests-main / render-gitignore

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Detection helper (which scaffold files exist)

**Files:**
- Modify: `src/scaffold.lisp`
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest detect-state
  (uiop:with-temporary-directory (:pathname tmp)
    (let ((asd  (cl-harness/src/scaffold::%asd-path tmp "demo"))
          (src  (cl-harness/src/scaffold::%src-main-path tmp))
          (test (cl-harness/src/scaffold::%default-test-file-path tmp)))
      (testing ":fresh when nothing exists"
        (multiple-value-bind (state existing missing)
            (cl-harness/src/scaffold::%detect-state tmp "demo" test)
          (ok (eq :fresh state))
          (ok (null existing))
          (ok (= 3 (length missing)))))
      (testing ":partial when some exist"
        (ensure-directories-exist asd)
        (with-open-file (s asd :direction :output) (write-string "dummy" s))
        (multiple-value-bind (state existing missing)
            (cl-harness/src/scaffold::%detect-state tmp "demo" test)
          (ok (eq :partial state))
          (ok (= 1 (length existing)))
          (ok (= 2 (length missing)))))
      (testing ":complete when all 3 exist"
        (ensure-directories-exist src)
        (ensure-directories-exist test)
        (with-open-file (s src :direction :output) (write-string "dummy" s))
        (with-open-file (s test :direction :output) (write-string "dummy" s))
        (multiple-value-bind (state existing missing)
            (cl-harness/src/scaffold::%detect-state tmp "demo" test)
          (ok (eq :complete state))
          (ok (= 3 (length existing)))
          (ok (null missing)))))))
```

- [ ] **Step 2: Run to verify failure**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::detect-state"}
```
Expected: undefined function.

- [ ] **Step 3: Implement detection**

Append to `src/scaffold.lisp`:

```lisp
(defun %detect-state (project-root system test-file-path)
  "Return (values STATE EXISTING MISSING).
STATE is one of :fresh / :partial / :complete.
EXISTING and MISSING are lists of pathnames (subsets of the 3
scaffold-tracked files). The .gitignore file is NOT tracked."
  (let* ((tracked (list (%asd-path project-root system)
                        (%src-main-path project-root)
                        test-file-path))
         (existing (remove-if-not #'probe-file tracked))
         (missing  (remove-if     #'probe-file tracked))
         (state (cond ((null existing) :fresh)
                      ((null missing)  :complete)
                      (t               :partial))))
    (values state existing missing)))
```

- [ ] **Step 4: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::detect-state"}
```
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add src/scaffold.lisp tests/scaffold-test.lisp
git commit -m "scaffold: %detect-state classifier (:fresh / :partial / :complete)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: scaffold-result class + scaffold entry function (happy path only)

**Files:**
- Modify: `src/scaffold.lisp`
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(defun %file-content (path)
  (with-open-file (in path) (read-line in nil "")))

(defun %file-full-content (path)
  (with-output-to-string (out)
    (with-open-file (in path)
      (loop for line = (read-line in nil) while line
            do (write-line line out)))))

(deftest fresh-scaffold-writes-four-files
  (uiop:with-temporary-directory (:pathname tmp)
    (let ((result (scaffold :project-root tmp :system "demo")))
      (testing "status is :written"
        (ok (eq :written (scaffold-result-status result))))
      (testing "4 files appear on disk"
        (ok (probe-file (merge-pathnames "demo.asd" tmp)))
        (ok (probe-file (merge-pathnames "src/main.lisp" tmp)))
        (ok (probe-file (merge-pathnames "tests/main-test.lisp" tmp)))
        (ok (probe-file (merge-pathnames ".gitignore" tmp))))
      (testing "paths-written lists 4 entries"
        (ok (= 4 (length (scaffold-result-paths-written result)))))
      (testing "conflicts is NIL on fresh"
        (ok (null (scaffold-result-conflicts result))))
      (testing "asd content references package-inferred-system"
        (let ((asd (%file-full-content (merge-pathnames "demo.asd" tmp))))
          (ok (search ":class :package-inferred-system" asd))))
      (testing "src defpackage has :nicknames #:demo"
        (let ((src (%file-full-content (merge-pathnames "src/main.lisp" tmp))))
          (ok (search "(:nicknames #:demo)" src)))))))
```

- [ ] **Step 2: Run to verify failure**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::fresh-scaffold-writes-four-files"}
```
Expected: undefined function `SCAFFOLD`.

- [ ] **Step 3: Implement scaffold-result + entry**

Append to `src/scaffold.lisp`:

```lisp
(defclass scaffold-result ()
  ((status :initarg :status :reader scaffold-result-status)
   (paths-written :initarg :paths-written :initform nil
                  :reader scaffold-result-paths-written)
   (conflicts :initarg :conflicts :initform nil
              :reader scaffold-result-conflicts))
  (:documentation
   "Return value of SCAFFOLD. STATUS is one of :WRITTEN, :ALREADY-PRESENT,
or :REFUSED. PATHS-WRITTEN is the list of files actually written; NIL
for :ALREADY-PRESENT and :REFUSED. CONFLICTS is the list of pre-existing
files that triggered a :REFUSED; NIL otherwise."))

(defun %write-file (path content)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string content out))
  path)

(defun %write-all-scaffold-files (project-root system test-system test-file-path)
  (let* ((asd-path  (%asd-path project-root system))
         (src-path  (%src-main-path project-root))
         (gitignore (%gitignore-path project-root)))
    (list (%write-file asd-path  (%render-asd system test-system))
          (%write-file src-path  (%render-src-main system))
          (%write-file test-file-path (%render-tests-main test-system))
          (%write-file gitignore (%render-gitignore)))))

(defun scaffold (&key project-root system test-system test-file force)
  "Emit a 4-file ASDF + rove project skeleton under PROJECT-ROOT.

Required: PROJECT-ROOT (pathname designator) and SYSTEM (string).
Optional: TEST-SYSTEM (defaults to \"<system>/tests\"),
TEST-FILE (defaults to <project-root>/tests/main-test.lisp),
FORCE (override the partial-state refuse and overwrite all files).

Return a SCAFFOLD-RESULT. See spec
docs/superpowers/specs/2026-05-22-scaffold-command-design.md."
  (%validate-system-name system)
  (let* ((root (uiop:ensure-directory-pathname project-root))
         (ts   (or test-system (%default-test-system system)))
         (tf   (or (and test-file (pathname test-file))
                   (%default-test-file-path root))))
    (ensure-directories-exist root)
    (multiple-value-bind (state existing missing)
        (%detect-state root system tf)
      (declare (ignore missing))
      (cond
        ((eq state :complete)
         (make-instance 'scaffold-result :status :already-present))
        ((or (eq state :fresh) force)
         (make-instance 'scaffold-result
                        :status :written
                        :paths-written
                        (%write-all-scaffold-files root system ts tf)))
        (t
         (error 'scaffold-partial-state
                :existing existing
                :missing missing
                :message
                (format nil "refusing to scaffold ~A: ~D file(s) already exist; pass :FORCE T to overwrite"
                        root (length existing))))))))
```

- [ ] **Step 4: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::fresh-scaffold-writes-four-files"}
```
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add src/scaffold.lisp tests/scaffold-test.lisp
git commit -m "scaffold: scaffold-result + scaffold entry (happy path)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Idempotency on already-scaffolded projects

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest idempotent-on-already-scaffolded
  (uiop:with-temporary-directory (:pathname tmp)
    (scaffold :project-root tmp :system "demo")
    (let ((mtime-before (file-write-date
                         (merge-pathnames "demo.asd" tmp)))
          (result (scaffold :project-root tmp :system "demo")))
      (testing "second invocation returns :already-present"
        (ok (eq :already-present (scaffold-result-status result))))
      (testing "paths-written is NIL on :already-present"
        (ok (null (scaffold-result-paths-written result))))
      (testing "file mtime unchanged"
        (ok (= mtime-before
               (file-write-date (merge-pathnames "demo.asd" tmp))))))))
```

- [ ] **Step 2: Run to verify pass (no impl change expected; behavior already coded in Task 6's `:complete` branch)**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::idempotent-on-already-scaffolded"}
```
Expected: 1 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: idempotency test (:already-present on second invocation)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Partial-state refusal

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest refuses-partial-state
  (uiop:with-temporary-directory (:pathname tmp)
    (let ((asd-path (merge-pathnames "demo.asd" tmp)))
      ;; Write only the asd file by hand.
      (ensure-directories-exist asd-path)
      (with-open-file (s asd-path :direction :output) (write-string "stub" s))
      (testing "scaffold-partial-state raised"
        (let ((raised
               (handler-case (progn (scaffold :project-root tmp :system "demo") nil)
                 (scaffold-partial-state (c) c))))
          (ok raised "condition was raised")
          (ok (= 1 (length (scaffold-partial-state-existing raised)))
              "1 existing file")
          (ok (= 2 (length (scaffold-partial-state-missing raised)))
              "2 missing files"))))))
```

- [ ] **Step 2: Run to verify pass (behavior already coded; the `t` branch raises)**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::refuses-partial-state"}
```
Expected: 1 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: partial-state refuse test (scaffold-partial-state raised)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `--force` override

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest force-overrides-partial-state
  (uiop:with-temporary-directory (:pathname tmp)
    (let ((asd-path (merge-pathnames "demo.asd" tmp)))
      (ensure-directories-exist asd-path)
      (with-open-file (s asd-path :direction :output) (write-string "stub" s))
      (let ((result (scaffold :project-root tmp :system "demo" :force t)))
        (testing ":written status with force"
          (ok (eq :written (scaffold-result-status result))))
        (testing "asd content was overwritten"
          (let ((asd (%file-full-content asd-path)))
            (ok (search ":class :package-inferred-system" asd))
            (ok (not (search "stub" asd)))))))))
```

- [ ] **Step 2: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::force-overrides-partial-state"}
```
Expected: 1 passed (Task 6's `(or fresh force)` branch handles this).

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: --force test (overrides partial state, overwrites)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Auto-creation of missing `--project-root`

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest creates-project-root-if-missing
  (uiop:with-temporary-directory (:pathname tmp)
    (let* ((deep (merge-pathnames "deeply/nested/dir/" tmp))
           (result (scaffold :project-root deep :system "demo")))
      (testing ":written status"
        (ok (eq :written (scaffold-result-status result))))
      (testing "deep dir exists"
        (ok (uiop:directory-exists-p deep)))
      (testing "asd file at correct path"
        (ok (probe-file (merge-pathnames "demo.asd" deep)))))))
```

- [ ] **Step 2: Run to verify pass (already handled by `ensure-directories-exist` in scaffold entry)**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::creates-project-root-if-missing"}
```
Expected: 1 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: mkdir behavior test (deep project-root created)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Generated .asd loads cleanly via ASDF

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest generated-asd-loads-via-asdf
  (uiop:with-temporary-directory (:pathname tmp)
    (scaffold :project-root tmp :system "scaffolddemoasd")
    (testing "asdf:load-asd succeeds"
      (ok (handler-case
              (progn
                (asdf:load-asd
                 (merge-pathnames "scaffolddemoasd.asd" tmp))
                t)
            (error (c)
              (format *error-output* "asd load failed: ~A~%" c)
              nil))))
    (testing "main system is registered"
      (ok (asdf:find-system "scaffolddemoasd" nil)))
    (testing "test system is registered"
      (ok (asdf:find-system "scaffolddemoasd/tests" nil)))))
```

(Use a unique system name `scaffolddemoasd` so this test does not collide with other tests' `demo` or with any actually-installed `demo` system in the local Quicklisp tree.)

- [ ] **Step 2: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::generated-asd-loads-via-asdf"}
```
Expected: 1 passed.

If the test fails, the most likely cause is a typo in the `%render-asd` template — re-read Task 4 step 3 and verify the `format` arg count.

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: generated asd loads via asdf:load-asd (template sanity)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Generated defpackage forms parse

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(defun %read-all-forms (path)
  "Read every top-level form from PATH; return them as a list."
  (with-open-file (in path)
    (loop for form = (read in nil :eof)
          until (eq form :eof)
          collect form)))

(deftest generated-defpackage-forms-parse
  (uiop:with-temporary-directory (:pathname tmp)
    (scaffold :project-root tmp :system "demo")
    (testing "src/main.lisp parses to 2 forms (defpackage + in-package)"
      (let ((forms (%read-all-forms (merge-pathnames "src/main.lisp" tmp))))
        (ok (= 2 (length forms)))
        (ok (eq 'defpackage (caar forms)))
        (ok (eq 'in-package (caadr forms)))))
    (testing "tests/main-test.lisp parses to 2 forms"
      (let ((forms (%read-all-forms
                    (merge-pathnames "tests/main-test.lisp" tmp))))
        (ok (= 2 (length forms)))
        (ok (eq 'defpackage (caar forms)))
        (ok (eq 'in-package (caadr forms)))))
    (testing "asd parses to 2 defsystem forms"
      (let ((forms (%read-all-forms (merge-pathnames "demo.asd" tmp))))
        (ok (= 2 (length forms)))
        (ok (equal '(asdf:defsystem "demo") (subseq (first forms) 0 2)))
        (ok (equal '(asdf:defsystem "demo/tests")
                   (subseq (second forms) 0 2)))))))
```

- [ ] **Step 2: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::generated-defpackage-forms-parse"}
```
Expected: 1 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: read-all-forms sanity test on generated lisp files

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: `--test-system` and `--test-file` overrides

**Files:**
- Modify: `tests/scaffold-test.lisp`

- [ ] **Step 1: Write the failing test**

Append to `tests/scaffold-test.lisp`:

```lisp
(deftest test-system-and-test-file-overrides
  (uiop:with-temporary-directory (:pathname tmp)
    (let* ((custom-test-file (merge-pathnames "altdir/integration.lisp" tmp))
           (result (scaffold :project-root tmp
                             :system "demo"
                             :test-system "demo/integration"
                             :test-file custom-test-file)))
      (testing ":written status"
        (ok (eq :written (scaffold-result-status result))))
      (testing "custom test file used"
        (ok (probe-file custom-test-file))
        (ok (not (probe-file (merge-pathnames "tests/main-test.lisp" tmp)))))
      (testing "asd references custom test-system"
        (let ((asd (%file-full-content (merge-pathnames "demo.asd" tmp))))
          (ok (search "(asdf:defsystem \"demo/integration\"" asd))
          (ok (search "\"demo/integration/main-test\"" asd))))
      (testing "tests defpackage uses custom test-system"
        (let ((tst (%file-full-content custom-test-file)))
          (ok (search "(defpackage #:demo/integration/main-test" tst)))))))
```

- [ ] **Step 2: Run to verify pass**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::test-system-and-test-file-overrides"}
```
Expected: 1 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/scaffold-test.lisp
git commit -m "scaffold: --test-system / --test-file override test

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Facade re-exports

**Files:**
- Modify: `src/main.lisp` (`:import-from` block + `:export` block)

- [ ] **Step 1: Write the failing test**

Add a deftest to `tests/scaffold-test.lisp` that confirms the facade symbols resolve:

```lisp
(deftest facade-re-exports
  (testing "cl-harness:scaffold is exported"
    (ok (eq 'cl-harness/src/scaffold:scaffold
            (find-symbol "SCAFFOLD" :cl-harness))))
  (testing "cl-harness:scaffold-result-status is exported"
    (ok (eq 'cl-harness/src/scaffold:scaffold-result-status
            (find-symbol "SCAFFOLD-RESULT-STATUS" :cl-harness))))
  (testing "cl-harness:scaffold-bad-system-name is exported"
    (ok (eq 'cl-harness/src/scaffold:scaffold-bad-system-name
            (find-symbol "SCAFFOLD-BAD-SYSTEM-NAME" :cl-harness)))))
```

- [ ] **Step 2: Run to verify failure**

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::facade-re-exports"}
```
Expected: failures because the facade has not re-exported yet (`find-symbol` returns NIL).

- [ ] **Step 3: Add `:import-from` to facade**

Modify `src/main.lisp`. After the existing `:import-from #:cl-harness/src/cli-main` clause (around L53-54), insert:

```lisp
  (:import-from #:cl-harness/src/scaffold
                #:scaffold
                #:scaffold-result
                #:scaffold-result-status
                #:scaffold-result-paths-written
                #:scaffold-result-conflicts
                #:scaffold-error
                #:scaffold-error-message
                #:scaffold-bad-system-name
                #:scaffold-bad-system-name-name
                #:scaffold-partial-state
                #:scaffold-partial-state-existing
                #:scaffold-partial-state-missing)
```

- [ ] **Step 4: Add to the `:export` block**

Still in `src/main.lisp`, find the `(:export` clause (around L235-280) and append before the closing paren:

```lisp
           #:scaffold
           #:scaffold-result
           #:scaffold-result-status
           #:scaffold-result-paths-written
           #:scaffold-result-conflicts
           #:scaffold-error
           #:scaffold-error-message
           #:scaffold-bad-system-name
           #:scaffold-bad-system-name-name
           #:scaffold-partial-state
           #:scaffold-partial-state-existing
           #:scaffold-partial-state-missing
```

- [ ] **Step 5: Run to verify pass**

```
{"system": "cl-harness", "force": true}
```
Expected: load success.

```
{"system": "cl-harness/tests", "test": "cl-harness/tests/scaffold-test::facade-re-exports"}
```
Expected: 1 passed.

- [ ] **Step 6: Commit**

```bash
git add src/main.lisp tests/scaffold-test.lisp
git commit -m "scaffold: facade re-exports cl-harness:scaffold and friends

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: CLI subcommand wiring

**Files:**
- Modify: `src/cli-main.lisp` (new `scaffold-options` / `scaffold-handler` / `scaffold-command`, register under `top-command`)

- [ ] **Step 1: Add the CLI handler block**

Modify `src/cli-main.lisp`. Right before the `(defun top-command ...)` definition (around L302), insert:

```lisp
;; --- scaffold -------------------------------------------------------------

(defun scaffold-handler (cmd)
  (handler-case
      (let* ((result (cl-harness/src/scaffold:scaffold
                      :project-root (clingon:getopt cmd :project-root)
                      :system (clingon:getopt cmd :system)
                      :test-system (clingon:getopt cmd :test-system)
                      :test-file (clingon:getopt cmd :test-file)
                      :force (clingon:getopt cmd :force)))
             (status (cl-harness/src/scaffold:scaffold-result-status result)))
        (case status
          (:written
           (format t "scaffolded:~%")
           (dolist (p (cl-harness/src/scaffold:scaffold-result-paths-written
                       result))
             (format t "  ~A~%" p))
           (uiop:quit 0))
          (:already-present
           (format t "already scaffolded — no changes~%")
           (uiop:quit 0))))
    (cl-harness/src/scaffold:scaffold-bad-system-name (c)
      (format *error-output* "~A~%" c)
      (uiop:quit 2))
    (cl-harness/src/scaffold:scaffold-partial-state (c)
      (format *error-output* "~A~%" c)
      (format *error-output* "  existing:~%")
      (dolist (p (cl-harness/src/scaffold:scaffold-partial-state-existing c))
        (format *error-output* "    ~A~%" p))
      (format *error-output* "  missing:~%")
      (dolist (p (cl-harness/src/scaffold:scaffold-partial-state-missing c))
        (format *error-output* "    ~A~%" p))
      (uiop:quit 1))
    (error (c)
      (format *error-output* "scaffold failed: ~A~%" c)
      (uiop:quit 2))))

(defun scaffold-options ()
  (list
   (clingon:make-option :string :description "target project directory (created if missing)"
                        :short-name #\p :long-name "project-root"
                        :required t :key :project-root)
   (clingon:make-option :string :description "ASDF system name (also package nickname)"
                        :short-name #\s :long-name "system"
                        :required t :key :system)
   (clingon:make-option :string :description "ASDF test-system name (default <system>/tests)"
                        :short-name #\t :long-name "test-system"
                        :key :test-system)
   (clingon:make-option :string :description "rove test file path (default <project-root>/tests/main-test.lisp)"
                        :short-name #\f :long-name "test-file"
                        :key :test-file)
   (clingon:make-option :flag :long-name "force"
                        :description "overwrite partially-existing scaffold (NO BACKUP)"
                        :key :force)))

(defun scaffold-command ()
  (clingon:make-command
   :name "scaffold"
   :description "Emit a 4-file ASDF + rove project skeleton."
   :options (scaffold-options)
   :handler #'scaffold-handler))
```

- [ ] **Step 2: Register `scaffold-command` under `top-command`**

Modify `top-command` (currently around L302-310). Change:

```lisp
   :sub-commands (list (fix-command)
                       (bench-command)
                       (develop-command))))
```

to:

```lisp
   :sub-commands (list (fix-command)
                       (bench-command)
                       (develop-command)
                       (scaffold-command))))
```

- [ ] **Step 3: Update the version string in `top-command`**

Same `defun top-command`. The current `:version "0.5.2"` line should remain as-is — the version bump for this feature is decided at release time, not in this PR.

- [ ] **Step 4: Verify the system compiles cleanly**

```
{"system": "cl-harness", "force": true}
```
Expected: success, no style-warnings on `cli-main`.

- [ ] **Step 5: Manual smoke check (optional, only if a clean SBCL is available)**

From a fresh shell (NOT cl-mcp, since we want to exercise the binary path):

```bash
sbcl --non-interactive \
  --eval "(asdf:load-asd \"/home/wiz/.roswell/local-projects/cl-harness/cl-harness.asd\")" \
  --eval "(ql:quickload :cl-harness)" \
  --eval "(cl-harness/src/cli-main:main)" \
  -- scaffold --project-root /tmp/clh-scaffold-smoke --system demo
ls -la /tmp/clh-scaffold-smoke
rm -rf /tmp/clh-scaffold-smoke
```
Expected: directory contains `demo.asd`, `src/main.lisp`, `tests/main-test.lisp`, `.gitignore`.

(This step is optional because it requires building the binary path; if skipped, document so in the commit message.)

- [ ] **Step 6: Commit**

```bash
git add src/cli-main.lisp
git commit -m "scaffold: clingon subcommand (cl-harness scaffold --project-root ...)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: README + PRD documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/cl-harness-prd.md`

- [ ] **Step 1: Add scaffold section to README Quick start**

Modify `README.md`. Find the line `### Fix one project — shell` (around L188) and insert immediately before it:

```markdown
### Scaffold a new project

```bash
cl-harness scaffold --project-root /tmp/demo --system demo
# → demo.asd, src/main.lisp, tests/main-test.lisp, .gitignore
```

Emits a deterministic 4-file skeleton (package-inferred-system + rove
test discovery) ready for `cl-harness develop`. LLM-free. Refuses to
write if some skeleton files already exist; pass `--force` to overwrite
unconditionally (no backup).

```
```

- [ ] **Step 2: Add scaffold note to develop section**

In the same `README.md`, find `### Develop a feature from a goal — \`cl-harness develop\`` (around L266). Right after the `\`develop\` goes one level higher...` paragraph, add:

```markdown
`develop` assumes the project skeleton is already in place. If you are
starting from an empty directory, run `cl-harness scaffold` first (see
above).
```

- [ ] **Step 3: Add §19 to the PRD**

Append to `docs/cl-harness-prd.md` (at the end of the file):

```markdown

## §19 Scaffold subcommand

`cl-harness scaffold` is a post-MVP addition that emits the minimal
ASDF + rove project skeleton needed by `cl-harness develop`. It is
deterministic, LLM-free, and intentionally separate from the
`develop` command's contract — see
`docs/superpowers/specs/2026-05-22-scaffold-command-design.md` for
the design rationale and behavior matrix.

### §19.1 Files emitted

- `<project-root>/<system>.asd` — main + test ASDF systems, both
  `:class :package-inferred-system`, with rove auto-discovery in
  the test-system's `:perform (test-op ...)` clause.
- `<project-root>/src/main.lisp` — `(defpackage #:<system>/src/main
  (:nicknames #:<system>) (:use #:cl) (:export))` + `(in-package …)`.
- `<project-root>/tests/main-test.lisp` — rove defpackage stub.
- `<project-root>/.gitignore` — `*.fasl`, `*.fasl-tmp`, `.cache/`.

### §19.2 Behavior

- All 3 tracked files (asd + src + tests; `.gitignore` is
  untracked) absent → write all 4 files, return `:written`.
- All 3 present → no-op, return `:already-present`.
- Partial → refuse with `scaffold-partial-state` (exit 1); `--force`
  overrides and overwrites.
- Invalid system name (must match `^[a-z][a-z0-9-]*$` and not end
  with `-`) → exit 2.

### §19.3 Out of scope (intentional)

- `:export` symbol inference (handled by planner, separate spec).
- Auto-chaining from `develop` (kept separate by design).
- Multi-file src layouts.
- Backups on `--force`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/cl-harness-prd.md
git commit -m "docs: README scaffold quick-start + PRD §19 scaffold subcommand

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: Final integration check

**Files:**
- (none modified — verification only)

- [ ] **Step 1: Force-compile the entire system to surface warnings**

Run via cl-mcp `repl-eval`:
```
{"code": "(asdf:compile-system :cl-harness :force t)"}
```
Expected: result `T`, no `:STYLE-WARNING` or `:WARNING` on the new `scaffold` file in stdout/stderr.

If warnings appear: fix them in `src/scaffold.lisp` and re-run.

- [ ] **Step 2: Run the full test suite**

Run via cl-mcp `run-tests`:
```
{"system": "cl-harness/tests"}
```
Expected: all tests pass, the v0.5.2 baseline of **397 tests** is now **410-ish** (10 new scaffold tests + 3 facade-export tests).

If any non-scaffold test newly fails: that is a regression; bisect by reverting individual scaffold-related commits.

- [ ] **Step 3: Lint with mallet**

From a clean shell (not cl-mcp):
```bash
cd /home/wiz/.roswell/local-projects/cl-harness
mallet src/scaffold.lisp tests/scaffold-test.lisp src/main.lisp src/cli-main.lisp
```
Expected: no output (mallet clean).

If mallet flags issues: fix in place, run mallet again. Common nits:
- trailing whitespace
- line >100 chars (the `format` template strings in `%render-asd` may need re-flowing if long)
- missing docstring on a public function (every `:export`ed symbol's defun needs one)

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git status
# if changes:
git add src/scaffold.lisp tests/scaffold-test.lisp src/main.lisp src/cli-main.lisp
git commit -m "scaffold: mallet + compile-warning cleanup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Print summary**

```bash
git log --oneline main..HEAD
```
Expected output: 16 commits (or fewer if some tasks merged), all prefixed with `scaffold:` or `docs:`.

This marks the scaffold feature as ready for merge. Release-note authoring is a separate step (deferred per spec §8.3).

---

## Self-Review (verified by author)

**Spec coverage check** (every requirement in `docs/superpowers/specs/2026-05-22-scaffold-command-design.md`):

| Spec section | Implemented in |
|---|---|
| §2.1 `--project-root` / `--system` required, regex on system name | Task 2, Task 15 |
| §2.2 `--test-system` / `--test-file` defaults | Task 3, Task 6, Task 13, Task 15 |
| §2.2 `--force` | Task 6, Task 9, Task 15 |
| §2.3 Programmatic API + scaffold-result | Task 6 |
| §3.1 .asd template (package-inferred-system + rove perform) | Task 4 |
| §3.2 src/main.lisp template (nickname + empty :export) | Task 4 |
| §3.3 tests/main-test.lisp template | Task 4 |
| §3.4 .gitignore template | Task 4 |
| §3.5 README/LICENSE intentionally absent | Task 4 (templates only emit 4 files) |
| §4 Behavior matrix (fresh/complete/partial/force) | Task 6, 7, 8, 9, 10 |
| §5.1 src/scaffold.lisp creation | Task 1 |
| §5.1 tests/scaffold-test.lisp creation | Task 1 |
| §5.2 src/main.lisp facade | Task 14 |
| §5.2 src/cli-main.lisp clingon | Task 15 |
| §5.2 cl-harness.asd test entry | Task 1 |
| §5.3 No new deps | All tasks (uiop only) |
| §6.1 Condition hierarchy | Task 2, Task 6 |
| §6.2 CLI exit codes | Task 15 |
| §6.3 Raise (don't swallow) on programmatic | Task 2, Task 6 |
| §7 Test 1 fresh-scaffold-writes-four-files | Task 6 |
| §7 Test 2 idempotent-on-already-scaffolded | Task 7 |
| §7 Test 3 refuses-partial-state-asd-only | Task 8 |
| §7 Test 4 force-overrides-partial-state | Task 9 |
| §7 Test 5 bad-system-name-rejected | Task 2 |
| §7 Test 6 creates-project-root-if-missing | Task 10 |
| §7 Test 7 generated-asd-loads-via-asdf | Task 11 |
| §7 Test 8 generated-defpackage-forms-parse | Task 12 |
| §7 Test 9 test-system-override-honored | Task 13 |
| §7 Test 10 system-name-as-nickname | Task 6 (asserted in fresh test) |
| §8.1 README updates | Task 16 |
| §8.2 PRD §19 | Task 16 |
| §9 Out-of-scope items | Not implemented (correct) |
| §10 Risks (`--force` warning) | Task 15 (scaffold-options description includes "NO BACKUP") |
| §11 Implementation order | Tasks 1–17 follow the spec's order |

**Placeholder scan:** No TBD/TODO outside of the intentional template placeholder (`:description "TODO: short description"` inside `%render-asd`'s output, which IS the literal string the user will edit later). No "implement later" or "add appropriate error handling" comments.

**Type consistency:**
- `scaffold-result-status` returns `:written` / `:already-present` / `:refused` consistently (Task 6 defines, Tasks 7/8/9/13 assert, Task 15 dispatches).
- `%detect-state` returns `(values state existing missing)` consistently (Task 5 defines, Task 6 consumes).
- `%validate-system-name` raises `scaffold-bad-system-name` (Task 2), caught in Task 15 CLI handler. Slot name `name` consistent in both.
- All file paths derived via the helpers in Task 3 (no ad-hoc `merge-pathnames` outside helpers in scaffold.lisp; tests use `merge-pathnames` to construct expected paths, which is fine).

No issues found. Plan ready.
