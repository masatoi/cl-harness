;;;; next/src/action-space.lisp
;;;;
;;;; Action-space restriction for the L1 environment (spec §5): the
;;;; tool-policy conditions (file-only / generic-mcp / runtime-native)
;;;; defined as data-driven allow rules over cl-mcp tool names.
;;;; Adapted from legacy src/policy.lisp; rule semantics unchanged
;;;; (exact string, or trailing-* prefix glob). Rules may also come
;;;; from a policy pack's :tool-policies section (原則4).

(defpackage #:cl-harness-next/src/action-space
  (:use #:cl)
  (:export #:+known-tool-names+
           #:+condition-allow-rules+
           #:condition-rules
           #:action-space
           #:make-action-space
           #:action-space-mode
           #:action-space-rules
           #:action-space-available-tools
           #:allowed-tools
           #:action-allowed-p))

(in-package #:cl-harness-next/src/action-space)

(alexandria:define-constant +known-tool-names+
    '("fs-list-directory" "fs-read-file" "fs-write-file"
      "fs-set-project-root" "fs-get-project-info"
      "load-system" "run-tests"
      "lisp-read-file" "lisp-edit-form" "lisp-patch-form" "lisp-check-parens"
      "clgrep-search" "clhs-lookup"
      "repl-eval" "inspect-object"
      "code-find" "code-describe" "code-find-references"
      "pool-status" "pool-kill-worker" "project-scaffold")
  :test #'equal
  :documentation
  "Snapshot of the cl-mcp tools the harness was developed against.
Fallback enumeration source for ALLOWED-TOOLS when no live tool list is
supplied; ACTION-ALLOWED-P matches against rules, not this list.")

(alexandria:define-constant +condition-allow-rules+
    '((:file-only      ("fs-list-directory" "fs-read-file" "fs-write-file"
                        "load-system" "run-tests"))
      (:generic-mcp    ("fs-*" "load-system" "run-tests"
                        "lisp-*" "clgrep-*" "clhs-*"))
      (:runtime-native ("fs-*" "load-system" "run-tests"
                        "lisp-*" "clgrep-*" "clhs-*"
                        "code-*" "repl-*" "inspect-*" "pool-*")))
  :test #'equal
  :documentation
  "Built-in allow rules for the three spec conditions (PRD §8.5,
spec §5). A rule is a literal tool name (exact match) or a trailing-*
prefix glob. A policy pack's :tool-policies section can supply
alternative rules per run via MAKE-ACTION-SPACE's :RULES.")

(defun condition-rules (mode)
  "Return the built-in allow rules for MODE, or signal an ERROR."
  (or (cadr (assoc mode +condition-allow-rules+))
      (error "action-space: no allow rules registered for mode ~S" mode)))

(defun %match-rule (tool-name rule)
  "True when TOOL-NAME satisfies RULE — a literal name (exact match) or
a `prefix*' glob. Only a trailing * is supported; anything else errors."
  (let ((star (position #\* rule)))
    (cond
      ((null star) (string= tool-name rule))
      ((= star (1- (length rule)))
       (let ((prefix (subseq rule 0 star)))
         (and (>= (length tool-name) (length prefix))
              (string= tool-name prefix :end1 (length prefix)))))
      (t (error "action-space: only trailing-* globs are supported, got ~S"
                rule)))))

(defun %matches-any-rule-p (tool-name rules)
  (some (lambda (rule) (%match-rule tool-name rule)) rules))

(defclass action-space ()
  ((mode :initarg :mode :initform nil :reader action-space-mode
         :documentation "Reporting label (:file-only etc.), or NIL.")
   (rules :initarg :rules :reader action-space-rules)
   (available-tools :initarg :available-tools :initform nil
                    :reader action-space-available-tools))
  (:documentation
   "Allow-list restriction of the L1 action space (spec §5).
AVAILABLE-TOOLS, when set, is the live tools/list catalog;
ALLOWED-TOOLS filters it through RULES. ACTION-ALLOWED-P consults
RULES directly, so new cl-mcp tools matching a glob still pass."))

(defun make-action-space (mode &key rules available-tools)
  "Build an ACTION-SPACE for MODE (one of the three conditions).
Explicit RULES (e.g. a policy pack's :tool-policies entry) override the
built-in rules for MODE; MODE may be NIL when RULES are supplied."
  (when available-tools
    (assert (listp available-tools) (available-tools)
            "action-space: :available-tools must be a list of tool names"))
  (let ((effective (or rules (condition-rules mode))))
    (make-instance 'action-space :mode mode :rules effective
                                 :available-tools available-tools)))

(defun allowed-tools (space)
  "Tool names SPACE permits: the live catalog (or +KNOWN-TOOL-NAMES+)
filtered by the allow rules, in source order."
  (let ((source (or (action-space-available-tools space)
                    +known-tool-names+)))
    (remove-if-not (lambda (name)
                     (%matches-any-rule-p name (action-space-rules space)))
                   source)))

(defun action-allowed-p (space tool-name)
  "True when SPACE's rules permit TOOL-NAME."
  (check-type tool-name string)
  (and (%matches-any-rule-p tool-name (action-space-rules space)) t))
