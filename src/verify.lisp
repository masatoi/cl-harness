;;;; src/verify.lisp
;;;;
;;;; PRD §8.9 — verifier. The agent loop calls VERIFY-TASK to confirm
;;;; whether the project under test now loads cleanly and its test
;;;; system reports zero failures. Phase 2 implements REQ-VERIFY-001
;;;; (incremental verification) only; the clean-rebuild variant
;;;; (REQ-VERIFY-002) is a Phase 3 follow-up.

(defpackage #:cl-harness/src/verify
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/config
                #:run-config-system
                #:run-config-test-system)
  (:import-from #:cl-harness/src/mcp
                #:call-tool)
  (:export #:verify-result
           #:verify-result-status
           #:verify-result-passed
           #:verify-result-failed
           #:verify-result-load
           #:verify-result-test
           #:verify-result-success-p
           #:parse-verify-result
           #:verify-task
           #:clean-verify-task
           #:scope-asdf-to-project
           #:build-scope-asdf-code))

(in-package #:cl-harness/src/verify)

(defclass verify-result ()
  ((status :initarg :status :reader verify-result-status)
   (passed :initarg :passed :initform nil :reader verify-result-passed)
   (failed :initarg :failed :initform nil :reader verify-result-failed)
   (load-result :initarg :load-result :initform nil :reader verify-result-load)
   (test-result :initarg :test-result :initform nil :reader verify-result-test))
  (:documentation
   "Outcome of one VERIFY-TASK call. STATUS is :PASSED, :TEST-FAILED, or
:LOAD-FAILED."))

(defun verify-result-success-p (result)
  "Return non-NIL when load and tests both reported success."
  (eq (verify-result-status result) :passed))

(defun %is-error (tool-result)
  "Return non-NIL when an MCP tools/call RESULT signals isError=true.

YASON parses JSON booleans as :TRUE / :FALSE, strings, or T/NIL depending
on configuration; treat T or :TRUE as the error sentinel."
  (let ((flag (gethash "isError" tool-result)))
    (or (eq flag t) (eq flag :true))))

(defun parse-verify-result (load-result test-result)
  "Construct a VERIFY-RESULT from raw call-tool RESULT hash-tables.

LOAD-RESULT is the load-system tools/call result. TEST-RESULT is the
run-tests tools/call result, or NIL when load failed and tests were
skipped. Missing pass/fail counts in TEST-RESULT are treated as a
failure so a confused test runner cannot silently pass."
  (cond
    ((or (null load-result) (%is-error load-result))
     (make-instance 'verify-result
                    :status :load-failed
                    :load-result load-result))
    ((null test-result)
     (make-instance 'verify-result
                    :status :load-failed
                    :load-result load-result))
    (t
     (let ((failed (gethash "failed" test-result))
           (passed (gethash "passed" test-result)))
       (make-instance 'verify-result
                      :status (if (and (numberp failed) (zerop failed))
                                  :passed
                                  :test-failed)
                      :passed passed
                      :failed failed
                      :load-result load-result
                      :test-result test-result)))))

(defun verify-task (client config)
  "Run an incremental load-system + run-tests via CLIENT (PRD §8.9
REQ-VERIFY-001). Returns a VERIFY-RESULT.

When load-system reports isError=true, run-tests is skipped to avoid
masking the underlying failure."
  (let* ((load-args (alist-hash-table
                     `(("system" . ,(run-config-system config)))
                     :test 'equal))
         (load-result (call-tool client "load-system" load-args)))
    (if (%is-error load-result)
        (parse-verify-result load-result nil)
        (let* ((test-args (alist-hash-table
                           `(("system" . ,(run-config-test-system config)))
                           :test 'equal))
               (test-result (call-tool client "run-tests" test-args)))
          (parse-verify-result load-result test-result)))))

(defun build-scope-asdf-code (project-root system-name test-system-name)
  "Return the repl-eval body string for SCOPE-ASDF-TO-PROJECT.

Three steps, in order:
  1. Narrow asdf's source-registry to PROJECT-ROOT (with
     :ignore-inherited-configuration so ~/.roswell/local-projects/ no
     longer shadows the sandbox).
  2. Forget every registered ASDF system whose name is SYSTEM-NAME,
     TEST-SYSTEM-NAME, or starts with `<system-name>/' /
     `<test-system-name>/'. This catches the package-inferred-system
     subsystems (e.g. `<sys>/src/main') that the top-level CLEAR-SYSTEM
     misses; without this asdf:load-system :force t skips re-running
     LOAD-OP on subsystems whose mtime check passes.
  3. Delete every package whose name matches the same prefix set, so a
     defun the prior cell's source had — but this cell's source lacks —
     does not linger as a stale FBOUNDP and let an unrelated test pass
     (cf. anomaly #64 in docs/notes/2026-05-06-qwen-anomaly.md).

Exposed for unit testing; SCOPE-ASDF-TO-PROJECT wraps the call-tool
plumbing around this code string."
  (format nil
          "(progn ~
            (asdf:initialize-source-registry '(:source-registry (:tree ~S) :ignore-inherited-configuration)) ~
            (let ((sys-slash ~S) (test-slash ~S)) ~
              (dolist (s (asdf:registered-systems)) ~
                (when (or (string= s ~S) (string= s ~S) ~
                          (and (> (length s) (length sys-slash)) ~
                               (string= s sys-slash :end1 (length sys-slash))) ~
                          (and (> (length s) (length test-slash)) ~
                               (string= s test-slash :end1 (length test-slash)))) ~
                  (asdf:clear-system s)))) ~
            (let ((sys-up ~S) (test-up ~S) ~
                  (sys-up-slash ~S) (test-up-slash ~S)) ~
              (dolist (p (list-all-packages)) ~
                (let ((name (package-name p))) ~
                  (when (or (string-equal name sys-up) (string-equal name test-up) ~
                            (and (>= (length name) (length sys-up-slash)) ~
                                 (string-equal (subseq name 0 (length sys-up-slash)) sys-up-slash)) ~
                            (and (>= (length name) (length test-up-slash)) ~
                                 (string-equal (subseq name 0 (length test-up-slash)) test-up-slash))) ~
                    (handler-case (delete-package p) (error () nil)))))) ~
            :ok)"
          (namestring project-root)
          (concatenate 'string system-name "/")
          (concatenate 'string test-system-name "/")
          system-name
          test-system-name
          (string-upcase system-name)
          (string-upcase test-system-name)
          (concatenate 'string (string-upcase system-name) "/")
          (concatenate 'string (string-upcase test-system-name) "/")))

(defun scope-asdf-to-project (client project-root system-name test-system-name)
  "Restrict the cl-mcp worker's ASDF source-registry to PROJECT-ROOT,
clear every cached subsystem under SYSTEM-NAME / TEST-SYSTEM-NAME, and
delete every package matching their hierarchy.

The default ASDF registry recursively scans ~/.roswell/local-projects/
and will happily return a same-named .asd from a previous benchmark
sandbox or fixture copy, masking edits the agent has just made under
PROJECT-ROOT. Both `cl-harness:fix' (via run-agent's :isolate-asdf-p)
and `cl-harness:bench' (via the per-task setup and the clean-verify
rescope callback) lean on this to keep the verification path honest.

The package-deletion step is the fix for the anomaly observed in the
2026-05-06 Qwen sweep: when pool-kill-worker raced and the worker was
reused across cells, the previous cell's patched source had bound a
function (e.g. typo-defun:greet) that the new cell's bug-bearing
source no longer defines. ASDF's force-reload only re-runs DEFUN
forms present in the current source — leftover bindings from the
prior cell's source survive and silently make the test pass. Wiping
the system's packages first makes the next load-system rebuild from
zero."
  (call-tool
   client "repl-eval"
   (alist-hash-table
    `(("code" . ,(build-scope-asdf-code project-root
                                        system-name
                                        test-system-name)))
    :test 'equal)))

(defun clean-verify-task (client config &key before-load-fn)
  "Run verification on a freshly spawned cl-mcp worker (PRD §8.9
REQ-VERIFY-002).

Calls pool-kill-worker (reset=true) before delegating to VERIFY-TASK so
the verification image carries no left-over REPL state from the agent's
probing turns.

BEFORE-LOAD-FN, when supplied, is invoked with CLIENT after pool-kill
but before VERIFY-TASK runs. It is the hook the benchmark runner uses
to re-scope the new worker's ASDF source-registry to the sandbox tree
that disappears together with the previous worker (cf. v0.2 Tier 3:
clean-verify in bench)."
  (call-tool client "pool-kill-worker"
             (alist-hash-table '(("reset" . t)) :test 'equal))
  (when before-load-fn
    (funcall before-load-fn client))
  (verify-task client config))
