;;;; src/policy.lisp
;;;;
;;;; PRD §8.5 — tool policy. The agent loop consults a TOOL-POLICY to
;;;; decide whether a tool name proposed by the LLM may actually be
;;;; invoked. Three modes mirror the benchmark conditions in
;;;; RUN-CONFIG-CONDITION:
;;;;   :file-only      — no cl-mcp tools (baseline; Phase 4+ benchmark only)
;;;;   :generic-mcp    — file edit + verification tools (Phase 2 fix loop)
;;;;   :runtime-native — adds runtime probes (Phase 3+)

(defpackage #:cl-harness/src/policy
  (:use #:cl)
  (:export #:tool-policy
           #:make-tool-policy
           #:policy-mode
           #:policy-allowed-tools
           #:allowed-tool-p))

(in-package #:cl-harness/src/policy)

(defparameter +file-only-tools+
  '("fs-list-directory"
    "fs-read-file"
    "fs-write-file"
    "load-system"
    "run-tests")
  "FILE-ONLY mode (PRD §8.5 REQ-POLICY-001) is the benchmark baseline:
the agent edits source files via plain fs-write-file, with no Lisp-aware
patching tools. Verification still uses cl-mcp's load-system + run-tests
so all conditions share the same verify path; only the *editing* surface
differs. Matches the typical \"file-system + shell\" agent baseline.")

(defparameter +generic-mcp-tools+
  '("fs-set-project-root"
    "fs-list-directory"
    "fs-read-file"
    "load-system"
    "run-tests"
    "lisp-read-file"
    "lisp-edit-form"
    "lisp-patch-form"
    "lisp-check-parens"
    "clgrep-search")
  "Tools the basic fix loop needs (PRD §8.5 REQ-POLICY-002).")

(defparameter +runtime-native-extra-tools+
  '("repl-eval"
    "inspect-object"
    "code-find"
    "code-describe"
    "code-find-references"
    "pool-status"
    "pool-kill-worker")
  "Runtime probing tools layered on top of GENERIC-MCP for the
runtime-native loop (PRD §8.5 REQ-POLICY-003).")

(defparameter +runtime-native-tools+
  (append +generic-mcp-tools+ +runtime-native-extra-tools+))

(defclass tool-policy ()
  ((mode :initarg :mode :reader policy-mode))
  (:documentation
   "Allow-list policy for cl-mcp tool invocation (PRD §10.2 tool-policy)."))

(defun make-tool-policy (mode)
  "Construct a TOOL-POLICY for one of the three benchmark modes."
  (check-type mode (member :file-only :generic-mcp :runtime-native))
  (make-instance 'tool-policy :mode mode))

(defun policy-allowed-tools (policy)
  "Return the list of tool names POLICY permits (string list)."
  (ecase (policy-mode policy)
    (:file-only +file-only-tools+)
    (:generic-mcp +generic-mcp-tools+)
    (:runtime-native +runtime-native-tools+)))

(defgeneric allowed-tool-p (policy tool-name)
  (:documentation
   "Return non-NIL when POLICY permits TOOL-NAME (PRD §10.3 allowed-tool-p)."))

(defmethod allowed-tool-p ((policy tool-policy) tool-name)
  (check-type tool-name string)
  (and (member tool-name (policy-allowed-tools policy) :test #'equal) t))
