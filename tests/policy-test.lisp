;;;; tests/policy-test.lisp
;;;;
;;;; Phase 2 unit tests for tool-policy (PRD §8.5).
;;;;
;;;; The agent loop consults a tool-policy to decide whether the LLM is
;;;; allowed to invoke a given cl-mcp tool. Phase 2 needs the
;;;; :generic-mcp mode to ship a working basic fix loop; :file-only and
;;;; :runtime-native are wired in for forward compatibility.

(defpackage #:cl-harness/tests/policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/policy
                #:tool-policy
                #:make-tool-policy
                #:policy-mode
                #:policy-allowed-tools
                #:policy-available-tools
                #:allowed-tool-p))

(in-package #:cl-harness/tests/policy-test)

(deftest make-tool-policy-validates-mode
  (testing "accepts known modes"
    (ok (typep (make-tool-policy :file-only) 'tool-policy))
    (ok (typep (make-tool-policy :generic-mcp) 'tool-policy))
    (ok (typep (make-tool-policy :runtime-native) 'tool-policy))
    (ok (eq :generic-mcp (policy-mode (make-tool-policy :generic-mcp)))))
  (testing "rejects unknown modes"
    (ok (handler-case (progn (make-tool-policy :nonsense) nil)
          (error () t)))))

(deftest file-only-allows-fs-baseline-only
  (let ((p (make-tool-policy :file-only)))
    (testing "fs / load / test tools are allowed"
      (ok (allowed-tool-p p "fs-list-directory"))
      (ok (allowed-tool-p p "fs-read-file"))
      (ok (allowed-tool-p p "fs-write-file"))
      (ok (allowed-tool-p p "load-system"))
      (ok (allowed-tool-p p "run-tests")))
    (testing "Lisp-aware editing tools are NOT allowed"
      (ok (not (allowed-tool-p p "lisp-patch-form")))
      (ok (not (allowed-tool-p p "lisp-edit-form")))
      (ok (not (allowed-tool-p p "lisp-read-file"))))
    (testing "runtime probes are NOT allowed"
      (ok (not (allowed-tool-p p "repl-eval")))
      (ok (not (allowed-tool-p p "code-find"))))))

(deftest generic-mcp-allows-basic-fix-loop-tools
  (let ((p (make-tool-policy :generic-mcp)))
    (testing "tools required by the Phase 2 fix loop are allowed"
      (ok (allowed-tool-p p "fs-set-project-root"))
      (ok (allowed-tool-p p "load-system"))
      (ok (allowed-tool-p p "run-tests"))
      (ok (allowed-tool-p p "lisp-read-file"))
      (ok (allowed-tool-p p "lisp-patch-form"))
      (ok (allowed-tool-p p "lisp-edit-form")))
    (testing "runtime-only tools remain disallowed"
      (ok (not (allowed-tool-p p "repl-eval")))
      (ok (not (allowed-tool-p p "inspect-object")))
      (ok (not (allowed-tool-p p "pool-kill-worker"))))))

(deftest runtime-native-is-superset-of-generic-mcp
  (let ((g (make-tool-policy :generic-mcp))
        (r (make-tool-policy :runtime-native)))
    (dolist (tool (policy-allowed-tools g))
      (ok (allowed-tool-p r tool)))
    (testing "runtime-native adds runtime probes"
      (ok (allowed-tool-p r "repl-eval"))
      (ok (allowed-tool-p r "inspect-object"))
      (ok (allowed-tool-p r "code-find"))
      (ok (allowed-tool-p r "code-describe"))
      (ok (allowed-tool-p r "pool-kill-worker")))))

(deftest allowed-tool-p-rejects-non-string
  (let ((p (make-tool-policy :generic-mcp)))
    (ok (handler-case (progn (allowed-tool-p p :load-system) nil)
          (type-error () t)))))

;; --- Tier 4 C-1: dynamic tool schema -----------------------------------

(deftest allowed-tool-p-accepts-future-lisp-tool-via-prefix-rule
  ;; A hypothetical cl-mcp tool the harness has never seen ("lisp-format-form")
  ;; matches the lisp-* glob in :generic-mcp's allow rules and must
  ;; therefore satisfy ALLOWED-TOOL-P, even though it is not in
  ;; +KNOWN-TOOL-NAMES+. Ensures the policy continues to work when
  ;; cl-mcp ships a new lisp-aware tool without a cl-harness release.
  (let ((p (make-tool-policy :generic-mcp)))
    (ok (allowed-tool-p p "lisp-format-form"))))

(deftest allowed-tool-p-still-denies-non-matching-future-tool
  ;; Negative case: a future tool whose name doesn't match any glob
  ;; must remain denied. (e.g. cl-mcp adds a `process-spawn` tool —
  ;; cl-harness can't auto-trust it.)
  (let ((p (make-tool-policy :generic-mcp)))
    (ok (not (allowed-tool-p p "process-spawn")))
    (ok (not (allowed-tool-p p "shell-exec")))))

(deftest policy-available-tools-narrows-allowed-list
  ;; When :available-tools is supplied, POLICY-ALLOWED-TOOLS is the
  ;; intersection of the live catalog with the rule matches — so a
  ;; cl-mcp instance that doesn't expose `pool-status` won't have it
  ;; in the policy's display list, even though the rules permit it.
  (let* ((live '("fs-read-file" "lisp-patch-form" "code-find"))
         (p (make-tool-policy :runtime-native :available-tools live)))
    (ok (equal live (policy-available-tools p)))
    (let ((allowed (policy-allowed-tools p)))
      (ok (= 3 (length allowed)))
      (ok (every (lambda (n) (member n allowed :test #'equal)) live))
      (ok (not (member "pool-status" allowed :test #'equal))
          "pool-status is rule-permitted but absent from the live catalog"))))

(deftest policy-allowed-tools-static-fallback-matches-v0.2-shape
  ;; Without :available-tools, POLICY-ALLOWED-TOOLS materialises against
  ;; +KNOWN-TOOL-NAMES+. The :generic-mcp output must include the same
  ;; tools v0.2 used to expose.
  (let* ((p (make-tool-policy :generic-mcp))
         (a (policy-allowed-tools p)))
    (dolist (must '("fs-set-project-root" "load-system" "run-tests"
                    "lisp-read-file" "lisp-patch-form" "lisp-edit-form"
                    "lisp-check-parens" "clgrep-search"))
      (ok (member must a :test #'equal)))
    (dolist (must-not '("repl-eval" "inspect-object" "code-find"
                        "pool-kill-worker"))
      (ok (not (member must-not a :test #'equal))))))

;; --- v0.4 Phase 3: :explore mode -----------------------------------------

(deftest explore-mode-allows-read-and-probe-tools
  (let ((p (make-tool-policy :explore)))
    (dolist (must '("fs-read-file" "fs-list-directory" "lisp-read-file"
                    "lisp-check-parens" "repl-eval" "inspect-object"
                    "code-find" "code-describe" "code-find-references"
                    "clgrep-search" "load-system" "run-tests"))
      (ok (allowed-tool-p p must)
          (format nil "explore allows ~A" must)))))

(deftest explore-mode-denies-write-tools
  ;; Read-only invariant: edit tools must be rejected so an
  ;; LLM that accidentally proposes one is caught at the policy
  ;; gate, not after the file is mutated.
  (let ((p (make-tool-policy :explore)))
    (dolist (must-not '("lisp-patch-form" "lisp-edit-form"
                        "fs-write-file" "pool-kill-worker"))
      (ok (not (allowed-tool-p p must-not))
          (format nil "explore denies ~A" must-not)))))

(deftest make-tool-policy-accepts-explore-mode
  (ok (typep (make-tool-policy :explore) 'tool-policy))
  (ok (eq :explore (policy-mode (make-tool-policy :explore)))))
