;;;; src/cli.lisp
;;;;
;;;; PRD §8.1 CLI skeleton. Phase 0 ships only entrypoints that parse a tiny
;;;; argv subset into a RUN-CONFIG and report "not implemented" for the agent
;;;; loop itself. A real argument parser (clingon/unix-opts) lands in Phase 1.

(defpackage #:cl-harness/src/cli
  (:use #:cl)
  (:import-from #:cl-harness/src/config
                #:make-run-config)
  (:import-from #:cl-harness/src/log
                #:open-run-logger
                #:close-run-logger)
  (:import-from #:cl-harness/src/mcp
                #:make-mcp-client
                #:initialize-mcp)
  (:import-from #:cl-harness/src/model
                #:make-openai-provider)
  (:import-from #:cl-harness/src/policy
                #:make-tool-policy)
  (:import-from #:cl-harness/src/agent
                #:run-agent)
  (:export #:fix
           #:bench
           #:not-implemented-error))

(in-package #:cl-harness/src/cli)

(define-condition not-implemented-error (error)
  ((command :initarg :command :reader not-implemented-error-command))
  (:report (lambda (c stream)
             (format stream "cl-harness ~A: not implemented yet (Phase 0 skeleton)."
                     (not-implemented-error-command c)))))

(defun fix (&key project-root system test-system issue
                 (condition :generic-mcp)
                 mcp-url
                 base-url api-key model
                 (temperature 0.0) (max-tokens 1024)
                 log-path)
  "Run the Phase 2 basic fix loop.

Required keyword arguments mirror PRD §11.1: PROJECT-ROOT, SYSTEM,
TEST-SYSTEM, ISSUE. The LLM endpoint is taken from the keyword args or
the CL_HARNESS_LLM_BASE_URL / CL_HARNESS_LLM_API_KEY / CL_HARNESS_LLM_MODEL
environment variables. The cl-mcp HTTP URL defaults to
http://127.0.0.1:3001/mcp (override via :MCP-URL or CL_HARNESS_MCP_URL).

Returns the populated AGENT-STATE."
  (let* ((config (make-run-config :project-root project-root
                                  :system system
                                  :test-system test-system
                                  :issue issue
                                  :condition condition))
         (effective-base-url
          (or base-url
              (uiop:getenv "CL_HARNESS_LLM_BASE_URL")
              (error "fix: :base-url or CL_HARNESS_LLM_BASE_URL is required")))
         (effective-api-key
          (or api-key
              (uiop:getenv "CL_HARNESS_LLM_API_KEY")
              (error "fix: :api-key or CL_HARNESS_LLM_API_KEY is required")))
         (effective-model
          (or model
              (uiop:getenv "CL_HARNESS_LLM_MODEL")
              (error "fix: :model or CL_HARNESS_LLM_MODEL is required")))
         (provider (make-openai-provider
                    :base-url effective-base-url
                    :api-key effective-api-key
                    :model effective-model
                    :temperature temperature
                    :max-tokens max-tokens))
         (client (make-mcp-client
                  (or mcp-url
                      (uiop:getenv "CL_HARNESS_MCP_URL")
                      "http://127.0.0.1:3001/mcp")))
         (policy (make-tool-policy condition))
         (path (or log-path
                   (merge-pathnames
                    (format nil "cl-harness-fix-~A.jsonl"
                            (get-universal-time))
                    (uiop:temporary-directory)))))
    (initialize-mcp client
                    :client-name "cl-harness"
                    :client-version "0.0.1")
    (let ((logger (open-run-logger path)))
      (unwind-protect
           (run-agent config provider client policy logger)
        (close-run-logger logger)))))

(defun bench (&key suite condition model base-url mcp-url)
  "Entry point for the `cl-harness bench' command (PRD §8.1 REQ-CLI-002).

Phase 0 validates inputs and signals NOT-IMPLEMENTED-ERROR."
  (declare (ignore suite condition model base-url mcp-url))
  (error 'not-implemented-error :command "bench"))
