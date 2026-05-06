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

(defun parse-condition (s)
  "Map a CLI string to the corresponding TOOL-POLICY mode keyword."
  (cond
    ((or (null s) (equal s "generic-mcp")) :generic-mcp)
    ((equal s "file-only") :file-only)
    ((equal s "runtime-native") :runtime-native)
    (t (error "unknown condition: ~A (expected file-only / generic-mcp / runtime-native)"
              s))))

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
                        :description "max_tokens per LLM call (default 1024)"
                        :initial-value 1024 :key :max-tokens)
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
                        :description "max_tokens per LLM call (default 2048)"
                        :initial-value 2048 :key :max-tokens)
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
  (let* ((result (develop
                  :goal (clingon:getopt cmd :goal)
                  :project-root (clingon:getopt cmd :project-root)
                  :system (clingon:getopt cmd :system)
                  :test-system (clingon:getopt cmd :test-system)
                  :test-file (clingon:getopt cmd :test-file)
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
                  :max-replans (clingon:getopt cmd :max-replans)
                  :log-path (clingon:getopt cmd :log-path)))
         (status (develop-result-status result)))
    (uiop:quit (develop-status-to-exit-code status))))

(defun develop-options ()
  (list
   (clingon:make-option :string :description "natural-language goal for the planner"
                        :short-name #\g :long-name "goal"
                        :required t :key :goal)
   (clingon:make-option :string :description "absolute path to the ASDF project"
                        :short-name #\p :long-name "project-root"
                        :required t :key :project-root)
   (clingon:make-option :string :description "ASDF system name"
                        :short-name #\s :long-name "system"
                        :required t :key :system)
   (clingon:make-option :string :description "ASDF test-system name"
                        :short-name #\t :long-name "test-system"
                        :required t :key :test-system)
   (clingon:make-option :string :description "rove file the planner-authored deftest forms get appended to"
                        :short-name #\f :long-name "test-file"
                        :required t :key :test-file)
   (clingon:make-option :string :description "tool-policy mode (file-only|generic-mcp|runtime-native)"
                        :long-name "condition"
                        :initial-value "generic-mcp" :key :condition)
   (clingon:make-option :string :long-name "mcp-url"
                        :description "talk to a remote cl-mcp HTTP endpoint instead of spawning one (env: $CL_HARNESS_MCP_URL)"
                        :key :mcp-url)
   (clingon:make-option :flag :long-name "mcp-stdio"
                        :description "force the built-in stdio launch command (default behaviour)"
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
                        :description "max_tokens per LLM call (default 4096)"
                        :initial-value 4096 :key :max-tokens)
   (clingon:make-option :string :long-name "temperature"
                        :description "LLM temperature as a string (default 0.0)"
                        :initial-value "0.0" :key :temperature)
   (clingon:make-option :string :long-name "reasoning-effort"
                        :description "low|medium|high (only for reasoning models)"
                        :key :reasoning-effort)
   (clingon:make-option :integer :long-name "max-replans"
                        :description "maximum replan rounds before :limit-exhausted (default 3)"
                        :initial-value 3 :key :max-replans)
   (clingon:make-option :string :long-name "log-path"
                        :description "develop-level JSONL transcript path (default tmpdir)"
                        :key :log-path)))

(defun develop-command ()
  (clingon:make-command
   :name "develop"
   :description "Plan, execute, and replan-on-failure to drive a high-level goal to a green test suite."
   :options (develop-options)
   :handler #'develop-handler))

(defun top-command ()
  "Top-level clingon command: subcommands fix, bench, and develop."
  (clingon:make-command
   :name "cl-harness"
   :description "Runtime-native coding agent harness for Common Lisp."
   :version "0.3.0"
   :sub-commands (list (fix-command)
                       (bench-command)
                       (develop-command))))

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
