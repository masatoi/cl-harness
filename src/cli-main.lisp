;;;; src/cli-main.lisp
;;;;
;;;; Shell entry point. ASDF:MAKE on cl-harness/binary produces an
;;;; executable that dispatches `cl-harness fix ...` or
;;;; `cl-harness bench ...` to the underlying programmatic FIX / BENCH
;;;; functions. Exit code:
;;;;   0  :passed
;;;;   1  :give-up / :limit-exhausted / :dirty-only / bench had a non-pass cell
;;;;   2  unhandled error (CLI parse failure, MCP/HTTP exception, etc.)

(defpackage #:cl-harness/src/cli-main
  (:use #:cl)
  (:import-from #:cl-harness/src/cli
                #:fix
                #:bench
                #:develop)
  (:import-from #:cl-harness/src/agent
                #:agent-state-status)
  (:import-from #:cl-harness/src/bench
                #:bench-result-status)
  (:import-from #:cl-harness/src/orchestrator
                #:develop-result-status)
  (:export #:main
           #:top-command))

(in-package #:cl-harness/src/cli-main)

(defun %maybe-warn-log-llm-requests (flag)
  "Emit a one-line WARNING to *ERROR-OUTPUT* when FLAG is truthy.
Called from each CLI handler head once the opt-in source is resolved
(kwarg / --log-llm-requests / CL_HARNESS_LOG_LLM_REQUESTS)."
  (when flag
    (format *error-output*
            "WARNING: --log-llm-requests is enabled. LLM message history (including~%~
             source code, file paths, and any other context the agent reads) will be~%~
             written verbatim to the JSONL transcript. Do NOT share the transcript~%~
             without review.~%")))

(defun parse-condition (s)
  "Map a CLI string to the corresponding TOOL-POLICY mode keyword."
  (cond
    ((or (null s) (equal s "generic-mcp")) :generic-mcp)
    ((equal s "file-only") :file-only)
    ((equal s "runtime-native") :runtime-native)
    (t (error "unknown condition: ~A (expected file-only / generic-mcp / runtime-native)"
              s))))

(defun parse-mode (s)
  "Map a CLI string to a develop MODE keyword. Accepts top-down /
bottom-up / mixed (case-insensitive). Errors otherwise."
  (let ((d (string-downcase (or s "mixed"))))
    (cond
      ((string= d "top-down") :top-down)
      ((string= d "bottom-up") :bottom-up)
      ((string= d "mixed") :mixed)
      (t (error "unknown mode ~S; expected top-down|bottom-up|mixed" s)))))

(defun parse-conditions (s)
  "Split a comma-separated CLI string into a list of condition keywords.
NIL or empty string defaults to (:generic-mcp)."
  (if (or (null s) (equal s ""))
      '(:generic-mcp)
      (mapcar #'parse-condition
              (uiop:split-string s :separator #(#\,)))))

(defun status-to-exit-code (status)
  "Map a final AGENT-STATE-STATUS keyword to a shell exit code."
  (case status
    (:passed 0)
    ((:give-up :limit-exhausted :dirty-only) 1)
    (otherwise 2)))

(defun fix-handler (cmd)
  (let* ((state (fix
                 :project-root (clingon:getopt cmd :project-root)
                 :system (clingon:getopt cmd :system)
                 :test-system (clingon:getopt cmd :test-system)
                 :issue (clingon:getopt cmd :issue)
                 :condition (parse-condition (clingon:getopt cmd :condition))
                 :mcp-url (clingon:getopt cmd :mcp-url)
                 :mcp-stdio (clingon:getopt cmd :mcp-stdio)
                 :mcp-command (clingon:getopt cmd :mcp-command)
                 :base-url (clingon:getopt cmd :base-url)
                 :api-key (clingon:getopt cmd :api-key)
                 :model (clingon:getopt cmd :model)
                 :temperature (clingon:getopt cmd :temperature)
                 :max-tokens (clingon:getopt cmd :max-tokens)
                 :reasoning-effort (clingon:getopt cmd :reasoning-effort)
                 :dry-run-p (clingon:getopt cmd :dry-run)
                 :log-path (clingon:getopt cmd :log-path)))
         (status (agent-state-status state)))
    (uiop:quit (status-to-exit-code status))))

(defun bench-handler (cmd)
  (let* ((results (bench
                   :suite (clingon:getopt cmd :suite)
                   :conditions (parse-conditions
                                (clingon:getopt cmd :conditions))
                   :mcp-url (clingon:getopt cmd :mcp-url)
                   :mcp-stdio (clingon:getopt cmd :mcp-stdio)
                   :mcp-command (clingon:getopt cmd :mcp-command)
                   :base-url (clingon:getopt cmd :base-url)
                   :api-key (clingon:getopt cmd :api-key)
                   :model (clingon:getopt cmd :model)
                   :temperature (clingon:getopt cmd :temperature)
                   :max-tokens (clingon:getopt cmd :max-tokens)
                   :reasoning-effort (clingon:getopt cmd :reasoning-effort)
                   :log-dir (clingon:getopt cmd :log-dir)))
         (failed (count-if-not (lambda (r) (eq :passed (bench-result-status r)))
                               results)))
    (uiop:quit (if (zerop failed) 0 1))))

(defun fix-options ()
  (list
   (clingon:make-option :string :description "absolute path to the ASDF project"
                        :short-name #\p :long-name "project-root"
                        :required t :key :project-root)
   (clingon:make-option :string :description "ASDF system name"
                        :short-name #\s :long-name "system"
                        :required t :key :system)
   (clingon:make-option :string :description "ASDF test-system name"
                        :short-name #\t :long-name "test-system"
                        :required t :key :test-system)
   (clingon:make-option :string :description "human-readable issue / failure summary"
                        :short-name #\i :long-name "issue"
                        :required t :key :issue)
   (clingon:make-option :string :description "tool-policy mode (file-only|generic-mcp|runtime-native)"
                        :long-name "condition"
                        :initial-value "generic-mcp" :key :condition)
   (clingon:make-option :string :long-name "mcp-url"
                        :description "talk to a remote cl-mcp HTTP endpoint instead of spawning a local one (env: $CL_HARNESS_MCP_URL)"
                        :key :mcp-url)
   (clingon:make-option :flag :long-name "mcp-stdio"
                        :description "force the built-in stdio launch command (default behaviour when nothing else is set)"
                        :key :mcp-stdio)
   (clingon:make-option :string :long-name "mcp-command"
                        :description "explicit shell-style command to spawn cl-mcp on stdio (env: $CL_HARNESS_MCP_COMMAND)"
                        :key :mcp-command)
   (clingon:make-option :string :long-name "base-url"
                        :description "LLM endpoint (default $CL_HARNESS_LLM_BASE_URL)"
                        :key :base-url)
   (clingon:make-option :string :long-name "api-key"
                        :description "LLM API key (default $CL_HARNESS_LLM_API_KEY)"
                        :key :api-key)
   (clingon:make-option :string :long-name "model"
                        :description "LLM model name (default $CL_HARNESS_LLM_MODEL)"
                        :key :model)
   (clingon:make-option :integer :long-name "max-tokens"
                        :description "max_tokens per LLM call (default: API default; omitted unless specified)"
                        :key :max-tokens)
   (clingon:make-option :string :long-name "temperature"
                        :description "LLM temperature as a string (default 0.0)"
                        :initial-value "0.0" :key :temperature)
   (clingon:make-option :string :long-name "reasoning-effort"
                        :description "low|medium|high (only for reasoning models)"
                        :key :reasoning-effort)
   (clingon:make-option :flag :long-name "dry-run"
                        :description "exercise the LLM but skip every MCP tool call"
                        :key :dry-run)
   (clingon:make-option :string :long-name "log-path"
                        :description "JSONL transcript path (default tmpdir)"
                        :key :log-path)))

(defun fix-command ()
  (clingon:make-command
   :name "fix"
   :description "Run the agent loop on a single failing-test project."
   :options (fix-options)
   :handler #'fix-handler))

(defun bench-options ()
  (list
   (clingon:make-option :string :short-name #\s :long-name "suite"
                        :description "directory containing per-task subdirs"
                        :required t :key :suite)
   (clingon:make-option :string :long-name "conditions"
                        :description "comma-separated condition list (default generic-mcp)"
                        :initial-value "generic-mcp" :key :conditions)
   (clingon:make-option :string :long-name "mcp-url"
                        :description "talk to a remote cl-mcp HTTP endpoint instead of spawning a local one (env: $CL_HARNESS_MCP_URL)"
                        :key :mcp-url)
   (clingon:make-option :flag :long-name "mcp-stdio"
                        :description "force the built-in stdio launch command (default behaviour when nothing else is set)"
                        :key :mcp-stdio)
   (clingon:make-option :string :long-name "mcp-command"
                        :description "explicit shell-style command to spawn cl-mcp on stdio (env: $CL_HARNESS_MCP_COMMAND)"
                        :key :mcp-command)
   (clingon:make-option :string :long-name "base-url"
                        :description "LLM endpoint (default $CL_HARNESS_LLM_BASE_URL)"
                        :key :base-url)
   (clingon:make-option :string :long-name "api-key"
                        :description "LLM API key (default $CL_HARNESS_LLM_API_KEY)"
                        :key :api-key)
   (clingon:make-option :string :long-name "model"
                        :description "LLM model name (default $CL_HARNESS_LLM_MODEL)"
                        :key :model)
   (clingon:make-option :integer :long-name "max-tokens"
                        :description "max_tokens per LLM call (default: API default; omitted unless specified)"
                        :key :max-tokens)
   (clingon:make-option :string :long-name "temperature"
                        :description "LLM temperature as a string (default 0.0)"
                        :initial-value "0.0" :key :temperature)
   (clingon:make-option :string :long-name "reasoning-effort"
                        :description "low|medium|high (only for reasoning models)"
                        :key :reasoning-effort)
   (clingon:make-option :string :long-name "log-dir"
                        :description "directory to write per-(task × condition) JSONL transcripts"
                        :key :log-dir)))

(defun bench-command ()
  (clingon:make-command
   :name "bench"
   :description "Run the benchmark suite across one or more conditions."
   :options (bench-options)
   :handler #'bench-handler))

;; --- develop --------------------------------------------------------------

(defun develop-status-to-exit-code (status)
  "Map a DEVELOP-RESULT status to a shell exit code."
  (case status
    (:passed 0)
    ((:give-up :limit-exhausted :stuck :dirty-only) 1)
    (otherwise 2)))

(defun develop-handler (cmd)
  (let* ((result
          (develop :goal (clingon:getopt cmd :goal) :project-root
           (clingon:getopt cmd :project-root) :system (clingon:getopt cmd :system) :test-system
           (clingon:getopt cmd :test-system) :test-file (clingon:getopt cmd :test-file)
           :condition (parse-condition (clingon:getopt cmd :condition)) :mcp-url
           (clingon:getopt cmd :mcp-url) :mcp-stdio (clingon:getopt cmd :mcp-stdio)
           :mcp-command (clingon:getopt cmd :mcp-command) :base-url
           (clingon:getopt cmd :base-url) :api-key (clingon:getopt cmd :api-key) :model
           (clingon:getopt cmd :model) :temperature (clingon:getopt cmd :temperature)
           :max-tokens (clingon:getopt cmd :max-tokens) :reasoning-effort
           (clingon:getopt cmd :reasoning-effort) :max-replans
           (clingon:getopt cmd :max-replans) :max-impl-review-revisions
           (clingon:getopt cmd :max-impl-review-revisions) :mode
           (parse-mode (clingon:getopt cmd :mode)) :log-path (clingon:getopt cmd :log-path)))
         (status (develop-result-status result)))
    (uiop/image:quit (develop-status-to-exit-code status))))

(defun develop-options ()
  (list
   (clingon:make-option :string :description "natural-language goal for the planner"
    :short-name #\g :long-name "goal" :required t :key :goal)
   (clingon:make-option :string :description "absolute path to the ASDF project"
    :short-name #\p :long-name "project-root" :required t :key :project-root)
   (clingon:make-option :string :description "ASDF system name" :short-name #\s
    :long-name "system" :required t :key :system)
   (clingon:make-option :string :description "ASDF test-system name" :short-name #\t
    :long-name "test-system" :required t :key :test-system)
   (clingon:make-option :string :description
    "rove file the planner-authored deftest forms get appended to" :short-name
    #\f :long-name "test-file" :required t :key :test-file)
   (clingon:make-option :string :description
    "tool-policy mode (file-only|generic-mcp|runtime-native)" :long-name
    "condition" :initial-value "generic-mcp" :key :condition)
   (clingon:make-option :string :long-name "mcp-url" :description
    "talk to a remote cl-mcp HTTP endpoint instead of spawning one (env: $CL_HARNESS_MCP_URL)"
    :key :mcp-url)
   (clingon:make-option :flag :long-name "mcp-stdio" :description
    "force the built-in stdio launch command (default behaviour)" :key
    :mcp-stdio)
   (clingon:make-option :string :long-name "mcp-command" :description
    "explicit shell-style command to spawn cl-mcp on stdio (env: $CL_HARNESS_MCP_COMMAND)"
    :key :mcp-command)
   (clingon:make-option :string :long-name "base-url" :description
    "LLM endpoint (default $CL_HARNESS_LLM_BASE_URL)" :key :base-url)
   (clingon:make-option :string :long-name "api-key" :description
    "LLM API key (default $CL_HARNESS_LLM_API_KEY)" :key :api-key)
   (clingon:make-option :string :long-name "model" :description
    "LLM model name (default $CL_HARNESS_LLM_MODEL)" :key :model)
   (clingon:make-option :integer :long-name "max-tokens" :description
    "max_tokens per LLM call (default: API default; omitted unless specified)"
    :key :max-tokens)
   (clingon:make-option :string :long-name "temperature" :description
    "LLM temperature as a string (default 0.0)" :initial-value "0.0" :key
    :temperature)
   (clingon:make-option :string :long-name "reasoning-effort" :description
    "low|medium|high (only for reasoning models)" :key :reasoning-effort)
   (clingon:make-option :integer :long-name "max-replans" :description
    "maximum replan rounds before :limit-exhausted (default 3)" :initial-value
    3 :key :max-replans)
   (clingon:make-option :integer :long-name "max-impl-review-revisions" :description
    "maximum implementation-review retry rounds before :review-rejected (default 2)"
    :initial-value 2 :key :max-impl-review-revisions)
   (clingon:make-option :string :long-name "mode" :description
    "development mode (top-down|bottom-up|mixed) — implement-first, explore-first, or planner-driven (default mixed)"
    :initial-value "mixed" :key :mode)
   (clingon:make-option :string :long-name "log-path" :description
    "develop-level JSONL transcript path (default tmpdir)" :key :log-path)))

(defun develop-command ()
  (clingon:make-command
   :name "develop"
   :description "Plan, execute, and replan-on-failure to drive a high-level goal to a green test suite."
   :options (develop-options)
   :handler #'develop-handler))

;; --- scaffold -------------------------------------------------------------

(defun scaffold-handler (cmd)
  "Clingon handler for the `scaffold` subcommand."
  (when (clingon:getopt cmd :force)
    (format *error-output*
            "warning: --force will overwrite existing files without backup~%"))
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
           (uiop:quit 0))
          (otherwise
           (format *error-output* "scaffold: unexpected status ~S~%" status)
           (uiop:quit 2))))
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
  "Clingon options for the `scaffold` subcommand."
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
   (clingon:make-option :string :description "rove test file (default <project-root>/tests/main-test.lisp)"
                        :short-name #\f :long-name "test-file"
                        :key :test-file)
   (clingon:make-option :flag :long-name "force"
                        :description "overwrite partially-existing scaffold (NO BACKUP)"
                        :key :force)))

(defun scaffold-command ()
  "Clingon command object for the `scaffold` subcommand."
  (clingon:make-command
   :name "scaffold"
   :description "Emit a 4-file ASDF + rove project skeleton."
   :options (scaffold-options)
   :handler #'scaffold-handler))

(defun top-command ()
  "Top-level clingon command: subcommands fix, bench, develop, and scaffold."
  (clingon:make-command
   :name "cl-harness"
   :description "Runtime-native coding agent harness for Common Lisp."
   :version "0.5.2"
   :sub-commands (list (fix-command)
                       (bench-command)
                       (develop-command)
                       (scaffold-command))))

(defun main ()
  "Shell entry point. Parses argv via clingon and dispatches to fix / bench.

Errors propagate up to a top-level HANDLER-CASE that prints a one-line
diagnostic to *ERROR-OUTPUT* and exits 2, so a crash in the harness does
not look like a successful run from a CI script's point of view."
  (handler-case
      (clingon:run (top-command))
    (error (c)
      (format *error-output* "cl-harness: ~A~%" c)
      (uiop:quit 2))))
