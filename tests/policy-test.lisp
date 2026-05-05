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

(deftest file-only-disallows-mcp-tools
  (let ((p (make-tool-policy :file-only)))
    (ok (not (allowed-tool-p p "load-system")))
    (ok (not (allowed-tool-p p "lisp-patch-form")))
    (ok (null (policy-allowed-tools p)))))

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
