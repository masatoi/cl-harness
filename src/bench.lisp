;;;; src/bench.lisp
;;;;
;;;; PRD §8.11, §16 — benchmark runner. Loads task specs from a suite
;;;; directory, runs each task across one or more conditions
;;;; (file-only / generic-mcp / runtime-native), captures metrics into
;;;; BENCH-RESULT records, and aggregates the results for reporting.
;;;;
;;;; Layout:
;;;;   benchmarks/
;;;;     <task-id>/
;;;;       task.json     # spec (id / system / test-system / issue / fixture-dir)
;;;;       fixture/      # ASDF system + failing test, deliberately broken
;;;;
;;;; Each RUN-BENCHMARK-TASK call copies the fixture to a tmpdir before
;;;; invoking RUN-AGENT, so the in-repo fixture stays pristine and is
;;;; safe to re-run repeatedly.

(defpackage #:cl-harness/src/bench
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/config
                #:make-run-config)
  (:import-from #:cl-harness/src/log
                #:open-run-logger
                #:close-run-logger)
  (:import-from #:cl-harness/src/mcp
                #:call-tool)
  (:import-from #:cl-harness/src/policy
                #:make-tool-policy)
  (:import-from #:cl-harness/src/agent
                #:run-agent
                #:agent-state-status
                #:agent-state-turn
                #:agent-state-patch-count
                #:agent-state-patch-attempts
                #:agent-state-token-total)
  (:export #:bench-task
           #:bench-task-id
           #:bench-task-description
           #:bench-task-system
           #:bench-task-test-system
           #:bench-task-issue
           #:bench-task-path
           #:bench-task-fixture-path
           #:bench-result
           #:bench-result-task
           #:bench-result-condition
           #:bench-result-status
           #:bench-result-success-p
           #:bench-result-turns
           #:bench-result-patches
           #:bench-result-patch-attempts
           #:bench-result-tokens
           #:bench-result-elapsed-ms
           #:bench-result-transcript-path
           #:bench-result-error
           #:load-bench-task
           #:discover-tasks
           #:run-benchmark-task
           #:run-benchmark-task-trials
           #:run-benchmark-suite
           #:aggregate-results
           #:format-suite-report
           #:format-suite-report-markdown))

(in-package #:cl-harness/src/bench)

(defclass bench-task ()
  ((id :initarg :id :reader bench-task-id)
   (description :initarg :description :initform "" :reader bench-task-description)
   (system :initarg :system :reader bench-task-system)
   (test-system :initarg :test-system :reader bench-task-test-system)
   (issue :initarg :issue :reader bench-task-issue)
   (path :initarg :path :reader bench-task-path)
   (fixture-path :initarg :fixture-path :reader bench-task-fixture-path))
  (:documentation
   "Specification for one benchmark task (PRD §8.11 REQ-BENCH-001).
PATH is the directory containing task.json; FIXTURE-PATH is the
sub-directory that holds the ASDF system + failing test."))

(defclass bench-result ()
  ((task :initarg :task :reader bench-result-task)
   (condition :initarg :condition :reader bench-result-condition)
   (status :initarg :status :reader bench-result-status)
   (turns :initarg :turns :reader bench-result-turns)
   (patches :initarg :patches :reader bench-result-patches)
   (patch-attempts :initarg :patch-attempts :reader bench-result-patch-attempts)
   (tokens :initarg :tokens :reader bench-result-tokens)
   (elapsed-ms :initarg :elapsed-ms :reader bench-result-elapsed-ms)
   (transcript-path :initarg :transcript-path :reader bench-result-transcript-path)
   (error :initarg :error :initform nil :reader bench-result-error))
  (:documentation
   "Per-task / per-condition outcome captured by the benchmark runner."))

(defun bench-result-success-p (result)
  "Return non-NIL when STATUS is :PASSED."
  (eq (bench-result-status result) :passed))

;; --- Stubs ---------------------------------------------------------------

(defun load-bench-task (task-dir)
  "Read TASK-DIR/task.json and construct a BENCH-TASK.

The fixture directory defaults to TASK-DIR/fixture/ when the JSON does
not specify a 'fixture-dir' key. PATH and FIXTURE-PATH are returned as
absolute pathnames."
  (let* ((dir (uiop:ensure-directory-pathname task-dir))
         (json-path (merge-pathnames "task.json" dir))
         (parsed (with-open-file (s json-path) (yason:parse s)))
         (fixture-name (or (gethash "fixture-dir" parsed) "fixture"))
         (fixture-dir (uiop:ensure-directory-pathname
                       (merge-pathnames fixture-name dir))))
    (make-instance 'bench-task
                   :id (gethash "id" parsed)
                   :description (or (gethash "description" parsed) "")
                   :system (gethash "system" parsed)
                   :test-system (gethash "test-system" parsed)
                   :issue (gethash "issue" parsed)
                   :path dir
                   :fixture-path fixture-dir)))

(defun discover-tasks (suite-dir)
  "Return a list of BENCH-TASK objects for every immediate sub-directory
of SUITE-DIR that contains a task.json. Sub-directories without a
task.json are silently skipped."
  (let ((dir (uiop:ensure-directory-pathname suite-dir))
        (results '()))
    (dolist (entry (uiop:subdirectories dir))
      (when (probe-file (merge-pathnames "task.json" entry))
        (push (load-bench-task entry) results)))
    (nreverse results)))

(defun %mean (numbers)
  (if (null numbers)
      0
      (/ (reduce #'+ numbers) (length numbers))))

(defun %sandbox-fixture (fixture-path tmp-prefix)
  "Recursively copy FIXTURE-PATH to a fresh tmpdir and return its
absolute pathname. Used so each benchmark task starts from a pristine
fixture and concurrent / repeated runs cannot stomp each other."
  (let ((src (uiop:ensure-directory-pathname fixture-path))
        (dst (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "~A-~A/" tmp-prefix
                       (random 1000000000))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dst)
    (uiop:run-program (list "cp" "-a"
                            (concatenate 'string (namestring src) ".")
                            (namestring dst))
                      :output :string :error-output :string)
    dst))

(defun %scope-asdf-to-sandbox (mcp-client sandbox system-name test-system-name)
  "Restrict the agent worker's ASDF source-registry to SANDBOX only via
repl-eval, then clear the named systems so cl-mcp's `load-system :force t'
re-discovers them from inside the sandbox.

Without this, ASDF's recursive scan of ~/.roswell/local-projects/ keeps
returning the original (un-patched) benchmark fixture even though the
agent has been told to operate against the sandbox copy."
  (call-tool
   mcp-client "repl-eval"
   (alist-hash-table
    `(("code"
       . ,(format nil
                  "(progn (asdf:initialize-source-registry '(:source-registry (:tree ~S) :ignore-inherited-configuration)) (asdf:clear-system :~A) (asdf:clear-system :~A) :ok)"
                  (namestring sandbox)
                  system-name
                  test-system-name)))
    :test 'equal)))

(defun run-benchmark-task (task provider mcp-client condition
                           &key (log-dir (uiop:temporary-directory)))
  "Run one BENCH-TASK against PROVIDER + MCP-CLIENT under CONDITION.

Copies the task's fixture to a fresh sandbox tmpdir, kills the agent's
cl-mcp worker so left-over package bindings from a previous task cannot
mask the broken state, registers the sandbox <system>.asd with the new
worker (so ASDF reads the patched copy rather than the registry-discovered
original), invokes RUN-AGENT with clean-verify disabled (a worker reset
mid-run would lose the registration), and captures the outcome into a
BENCH-RESULT. Errors during the run are caught and returned as a :ERROR
status so a single broken task does not abort the whole suite (PRD §8.11)."
  (let* ((sandbox (%sandbox-fixture (bench-task-fixture-path task)
                                    (format nil "cl-harness-bench-~A"
                                            (bench-task-id task))))
         (transcript (merge-pathnames
                      (format nil "bench-~A-~A-~A.jsonl"
                              (bench-task-id task)
                              (string-downcase (symbol-name condition))
                              (get-internal-real-time))
                      log-dir))
         (config (make-run-config
                  :project-root sandbox
                  :system (bench-task-system task)
                  :test-system (bench-task-test-system task)
                  :issue (bench-task-issue task)
                  :condition condition))
         (policy (make-tool-policy condition))
         (start-time (get-internal-real-time)))
    (handler-case
        (let ((logger (open-run-logger transcript)))
          (unwind-protect
               (progn
                 (call-tool mcp-client "pool-kill-worker"
                            (alist-hash-table '(("reset" . t))
                                              :test 'equal))
                 (%scope-asdf-to-sandbox mcp-client sandbox
                                         (bench-task-system task)
                                         (bench-task-test-system task))
                 (let ((state (run-agent config provider mcp-client policy
                                         logger
                                         :clean-verify-p nil)))
                   (make-instance 'bench-result
                                  :task task
                                  :condition condition
                                  :status (agent-state-status state)
                                  :turns (agent-state-turn state)
                                  :patches (agent-state-patch-count state)
                                  :patch-attempts (agent-state-patch-attempts state)
                                  :tokens (agent-state-token-total state)
                                  :elapsed-ms
                                  (* 1000.0
                                     (/ (- (get-internal-real-time) start-time)
                                        internal-time-units-per-second))
                                  :transcript-path transcript)))
            (close-run-logger logger)))
      (error (c)
        (make-instance 'bench-result
                       :task task
                       :condition condition
                       :status :error
                       :turns 0 :patches 0 :patch-attempts 0 :tokens 0
                       :elapsed-ms
                       (* 1000.0
                          (/ (- (get-internal-real-time) start-time)
                             internal-time-units-per-second))
                       :transcript-path transcript
                       :error (princ-to-string c))))))

(defun run-benchmark-task-trials (task provider mcp-client condition trials
                                  &key (log-dir (uiop:temporary-directory)))
  "Run RUN-BENCHMARK-TASK TRIALS times and return the list of BENCH-RESULTs.

Each trial gets its own sandbox tmpdir and transcript path because
RUN-BENCHMARK-TASK is the unit of isolation. Used to estimate variance
across repeated runs of the same (task, condition) pair."
  (check-type trials (integer 1))
  (loop repeat trials
        collect (run-benchmark-task task provider mcp-client condition
                                    :log-dir log-dir)))

(defun aggregate-results (results)
  "Return a hash-table summarising RESULTS:
total / passed / pass-rate / mean-turns / mean-tokens / mean-patches /
mean-elapsed-ms. An empty list yields zeros for every field so callers
do not need to special-case it."
  (let ((tbl (make-hash-table :test 'equal))
        (total (length results))
        (passed (count :passed results :key #'bench-result-status)))
    (setf (gethash "total" tbl) total
          (gethash "passed" tbl) passed
          (gethash "pass-rate" tbl)
          (if (zerop total) 0 (/ passed total))
          (gethash "mean-turns" tbl)
          (%mean (mapcar #'bench-result-turns results))
          (gethash "mean-tokens" tbl)
          (%mean (mapcar #'bench-result-tokens results))
          (gethash "mean-patches" tbl)
          (%mean (mapcar #'bench-result-patches results))
          (gethash "mean-elapsed-ms" tbl)
          (%mean (mapcar #'bench-result-elapsed-ms results)))
    tbl))

(defun run-benchmark-suite (suite-dir provider mcp-client
                            &key (conditions '(:generic-mcp))
                                 (log-dir (uiop:temporary-directory)))
  "Run every task discovered under SUITE-DIR across each CONDITION.

Returns the flat list of BENCH-RESULTs, one per (task × condition)
combination, in (task-1 × cond-1) (task-1 × cond-2) ... (task-N × cond-K)
order. PRD §8.11 REQ-BENCH-002."
  (let ((tasks (discover-tasks suite-dir))
        (results '()))
    (dolist (task tasks (nreverse results))
      (dolist (run-condition conditions)
        (push (run-benchmark-task task provider mcp-client run-condition
                                  :log-dir log-dir)
              results)))))

(defun format-suite-report (results)
  "Return a human-readable, multi-line summary of RESULTS plus an
aggregate footer (pass-rate, mean turns / tokens / patches, mean wall
clock). Fed to *STANDARD-OUTPUT* by the bench CLI."
  (with-output-to-string (s)
    (format s "== cl-harness benchmark suite report ==~%")
    (dolist (r results)
      (format s "  [~A] ~A (cond=~A): turns=~A tokens=~A patches=~A/~A elapsed=~Dms~@[ err=~A~]~%"
              (string-downcase (symbol-name (bench-result-status r)))
              (bench-task-id (bench-result-task r))
              (string-downcase
               (symbol-name (bench-result-condition r)))
              (bench-result-turns r)
              (bench-result-tokens r)
              (bench-result-patches r)
              (bench-result-patch-attempts r)
              (round (bench-result-elapsed-ms r))
              (bench-result-error r)))
    (let ((agg (aggregate-results results)))
      (format s "~%Total task×conditions: ~A~%" (gethash "total" agg))
      (format s "Passed:                ~A (~,1F%)~%"
              (gethash "passed" agg)
              (* 100 (coerce (gethash "pass-rate" agg) 'float)))
      (format s "Mean turns:            ~,1F~%"
              (coerce (gethash "mean-turns" agg) 'float))
      (format s "Mean tokens:           ~,0F~%"
              (coerce (gethash "mean-tokens" agg) 'float))
      (format s "Mean patches applied:  ~,1F~%"
              (coerce (gethash "mean-patches" agg) 'float))
      (format s "Mean wall clock:       ~,0F ms~%"
              (coerce (gethash "mean-elapsed-ms" agg) 'float)))))

(defun format-suite-report-markdown (results &key (heading "Benchmark Results"))
  "Render RESULTS as a Markdown report suitable for docs/benchmarks/.

Produces a heading, a per-task table grouped by condition, and a
summary footer with pass-rate / mean turns / mean tokens / mean wall
clock per condition. Used by the suite runner to persist
machine-readable results next to the JSONL transcripts."
  (with-output-to-string (s)
    (format s "# ~A~%~%" heading)
    (format s "Generated: ~A~%~%" (local-time:now))
    (let ((conditions (remove-duplicates
                       (mapcar #'bench-result-condition results)
                       :test #'eq))
          (tasks (remove-duplicates
                  (mapcar (lambda (r) (bench-task-id (bench-result-task r)))
                          results)
                  :test #'equal)))
      (format s "## Per-task results~%~%")
      (format s "| Task | Condition | Status | Turns | Patches (applied/attempted) | Tokens | Wall (ms) |~%")
      (format s "| ---- | --------- | ------ | -----:| --------------------------:| ------:| ---------:|~%")
      (dolist (task-id tasks)
        (dolist (run-condition conditions)
          (let ((r (find-if (lambda (r)
                              (and (equal task-id (bench-task-id (bench-result-task r)))
                                   (eq run-condition (bench-result-condition r))))
                            results)))
            (when r
              (format s "| ~A | ~A | `~A` | ~A | ~A/~A | ~A | ~D |~%"
                      task-id
                      (string-downcase (symbol-name run-condition))
                      (string-downcase (symbol-name (bench-result-status r)))
                      (bench-result-turns r)
                      (bench-result-patches r)
                      (bench-result-patch-attempts r)
                      (bench-result-tokens r)
                      (round (bench-result-elapsed-ms r)))))))
      (format s "~%## Per-condition aggregate~%~%")
      (format s "| Condition | Total | Passed | Pass-rate | Mean turns | Mean tokens | Mean ms |~%")
      (format s "| --------- | -----:| ------:| ---------:| ----------:| -----------:| -------:|~%")
      (dolist (run-condition conditions)
        (let* ((subset (remove-if-not
                        (lambda (r) (eq run-condition (bench-result-condition r)))
                        results))
               (agg (aggregate-results subset)))
          (format s "| `~A` | ~A | ~A | ~,1F% | ~,1F | ~,0F | ~,0F |~%"
                  (string-downcase (symbol-name run-condition))
                  (gethash "total" agg)
                  (gethash "passed" agg)
                  (* 100 (coerce (gethash "pass-rate" agg) 'float))
                  (coerce (gethash "mean-turns" agg) 'float)
                  (coerce (gethash "mean-tokens" agg) 'float)
                  (coerce (gethash "mean-elapsed-ms" agg) 'float)))))))
