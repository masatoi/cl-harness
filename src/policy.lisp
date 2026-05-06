;;;; src/policy.lisp
;;;;
;;;; PRD §8.5 — tool policy. The agent loop consults a TOOL-POLICY to
;;;; decide whether a tool name proposed by the LLM may actually be
;;;; invoked. Three modes mirror the benchmark conditions in
;;;; RUN-CONFIG-CONDITION:
;;;;   :file-only      — no cl-mcp tools (baseline; Phase 4+ benchmark only)
;;;;   :generic-mcp    — file edit + verification tools (Phase 2 fix loop)
;;;;   :runtime-native — adds runtime probes (Phase 3+)
;;;;
;;;; Tier 4 C-1 refactor: the per-condition rule set is now data
;;;; (+CONDITION-ALLOW-RULES+) instead of three handwritten flat lists.
;;;; Rules are glob-style — a literal name matches exactly, a `prefix*'
;;;; pattern matches any tool whose name starts with PREFIX. New cl-mcp
;;;; tools shipped under an existing family (e.g. a future
;;;; `lisp-format-form') automatically flow into :generic-mcp /
;;;; :runtime-native without a cl-harness release.
;;;;
;;;; Optional :AVAILABLE-TOOLS on MAKE-TOOL-POLICY is the live list
;;;; from cl-mcp's tools/list call: when supplied, POLICY-ALLOWED-TOOLS
;;;; is the intersection of (live-list, rule-matched). When omitted,
;;;; POLICY-ALLOWED-TOOLS materialises the rules against the historical
;;;; +KNOWN-TOOL-NAMES+ set so existing call sites keep their old
;;;; output bit-for-bit.

(defpackage #:cl-harness/src/policy
  (:use #:cl)
  (:export #:tool-policy
           #:make-tool-policy
           #:policy-mode
           #:policy-allowed-tools
           #:policy-available-tools
           #:allowed-tool-p))

(in-package #:cl-harness/src/policy)

(defparameter +known-tool-names+
  '("fs-list-directory"
    "fs-read-file"
    "fs-write-file"
    "fs-set-project-root"
    "fs-get-project-info"
    "load-system"
    "run-tests"
    "lisp-read-file"
    "lisp-edit-form"
    "lisp-patch-form"
    "lisp-check-parens"
    "clgrep-search"
    "clhs-lookup"
    "repl-eval"
    "inspect-object"
    "code-find"
    "code-describe"
    "code-find-references"
    "pool-status"
    "pool-kill-worker"
    "project-scaffold")
  "Snapshot of the cl-mcp tools cl-harness was developed against.
Used as the materialisation source for POLICY-ALLOWED-TOOLS when no
live :AVAILABLE-TOOLS is supplied. New cl-mcp tools that the harness
hasn't seen yet still pass ALLOWED-TOOL-P at runtime via the rule
match — this list only affects what gets enumerated in the system
prompt.")

(defparameter +condition-allow-rules+
  '((:file-only      ("fs-list-directory"
                      "fs-read-file"
                      "fs-write-file"
                      "load-system"
                      "run-tests"))
    (:generic-mcp    ("fs-*"
                      "load-system"
                      "run-tests"
                      "lisp-*"
                      "clgrep-*"
                      "clhs-*"))
    (:runtime-native ("fs-*"
                      "load-system"
                      "run-tests"
                      "lisp-*"
                      "clgrep-*"
                      "clhs-*"
                      "code-*"
                      "repl-*"
                      "inspect-*"
                      "pool-*"))
    ;; v0.4 Phase 3: read-only exploration policy. Strict subset of
    ;; runtime-native — same probe and read tools, no write/edit.
    ;; Used by RUN-EXPLORE-AGENT before the implement step when a
    ;; plan-step requests exploration.
    (:explore        ("fs-list-directory"
                      "fs-read-file"
                      "fs-set-project-root"
                      "fs-get-project-info"
                      "load-system"
                      "run-tests"
                      "lisp-read-file"
                      "lisp-check-parens"
                      "clgrep-*"
                      "clhs-*"
                      "code-*"
                      "repl-*"
                      "inspect-*"
                      "pool-status")))
  "Per-condition allow rules. Each entry is (MODE RULE-LIST). A rule
is either:
  - a literal tool-name string (matched exactly), or
  - a `prefix*' pattern (matches any tool-name starting with PREFIX).

Rules collected here are the SOLE source of truth for what
ALLOWED-TOOL-P returns; +KNOWN-TOOL-NAMES+ above only affects the
display list when AVAILABLE-TOOLS isn't supplied.")

(defun %condition-rules (mode)
  (or (cadr (assoc mode +condition-allow-rules+))
      (error "policy: no allow rules registered for mode ~A" mode)))

(defun %match-rule (tool-name rule)
  "Return non-NIL when TOOL-NAME satisfies a single allow rule. RULE
is either a literal tool-name string (exact match) or a `prefix*'
glob (TOOL-NAME starts with PREFIX)."
  (let ((star (position #\* rule)))
    (cond
      ((null star) (string= tool-name rule))
      ;; Only a trailing `*' is supported; the simpler shape covers
      ;; every cl-mcp tool family without giving the rule writer a
      ;; tool to mis-aim. If a future case needs more, generalise.
      ((= star (1- (length rule)))
       (let ((prefix (subseq rule 0 star)))
         (and (>= (length tool-name) (length prefix))
              (string= tool-name prefix
                       :end1 (length prefix)))))
      (t (error "policy: only trailing-* glob patterns are supported, got ~S"
                rule)))))

(defun %matches-any-rule-p (tool-name rules)
  (some (lambda (r) (%match-rule tool-name r)) rules))

(defclass tool-policy ()
  ((mode :initarg :mode :reader policy-mode)
   (available-tools :initarg :available-tools
                    :initform nil
                    :reader policy-available-tools))
  (:documentation
   "Allow-list policy for cl-mcp tool invocation (PRD §10.2 tool-policy).
AVAILABLE-TOOLS, when set, is the live list of tool names returned by
cl-mcp's tools/list — the policy filters that list by the condition's
allow rules. When NIL, the policy materialises against
+KNOWN-TOOL-NAMES+ for backward compatibility."))

(defun make-tool-policy (mode &key available-tools)
  "Construct a TOOL-POLICY for one of the three benchmark modes.
AVAILABLE-TOOLS, when supplied, is a list of tool-name strings (the
live cl-mcp catalog at session start); otherwise the policy uses
the historical static list."
  (check-type mode (member :file-only :generic-mcp :runtime-native :explore))
  (when available-tools
    (assert (listp available-tools) (available-tools)
            "policy: :available-tools must be a list of tool-name strings, got ~A"
            available-tools))
  (make-instance 'tool-policy
                 :mode mode
                 :available-tools available-tools))

(defun policy-allowed-tools (policy)
  "Return the list of tool names POLICY permits.

When POLICY was built with :AVAILABLE-TOOLS, the result is the
intersection of that live catalog and the condition's allow rules.
Otherwise the result is +KNOWN-TOOL-NAMES+ filtered by the rules,
which reproduces the v0.2 hardcoded list for each mode."
  (let ((rules (%condition-rules (policy-mode policy)))
        (source (or (policy-available-tools policy) +known-tool-names+)))
    (remove-if-not (lambda (n) (%matches-any-rule-p n rules)) source)))

(defgeneric allowed-tool-p (policy tool-name)
  (:documentation
   "Return non-NIL when POLICY permits TOOL-NAME (PRD §10.3 allowed-tool-p)."))

(defmethod allowed-tool-p ((policy tool-policy) tool-name)
  (check-type tool-name string)
  (and (%matches-any-rule-p tool-name
                            (%condition-rules (policy-mode policy)))
       t))
