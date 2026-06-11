;;;; next/tests/action-space-test.lisp
;;;;
;;;; Unit tests for next/src/action-space.lisp: rule matching (exact +
;;;; trailing-* glob), the three spec conditions, live-catalog
;;;; filtering, custom rule override (spec §5 / PRD §8.5).

(defpackage #:cl-harness-next/tests/action-space-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/action-space
                #:make-action-space
                #:allowed-tools
                #:action-allowed-p))

(in-package #:cl-harness-next/tests/action-space-test)

(deftest rule-matching
  (let ((exact (make-action-space nil :rules '("run-tests")))
        (glob (make-action-space nil :rules '("fs-*"))))
    (ok (action-allowed-p exact "run-tests"))
    (ok (not (action-allowed-p exact "run-tests-fast")))
    (ok (action-allowed-p glob "fs-read-file"))
    (ok (not (action-allowed-p glob "lisp-read-file")))
    (ok (handler-case
            (progn (action-allowed-p
                    (make-action-space nil :rules '("f*s")) "fs")
                   nil)
          (error () t)))))

(deftest file-only-condition
  (let ((space (make-action-space :file-only)))
    (ok (action-allowed-p space "fs-read-file"))
    (ok (action-allowed-p space "run-tests"))
    (ok (not (action-allowed-p space "repl-eval")))
    (ok (not (action-allowed-p space "lisp-edit-form")))
    (ok (not (action-allowed-p space "code-find")))))

(deftest generic-mcp-condition
  (let ((space (make-action-space :generic-mcp)))
    (ok (action-allowed-p space "lisp-edit-form"))
    (ok (action-allowed-p space "clgrep-search"))
    (ok (not (action-allowed-p space "repl-eval")))
    (ok (not (action-allowed-p space "code-find")))))

(deftest runtime-native-condition
  (let ((space (make-action-space :runtime-native)))
    (ok (action-allowed-p space "repl-eval"))
    (ok (action-allowed-p space "inspect-object"))
    (ok (action-allowed-p space "pool-kill-worker"))
    (ok (action-allowed-p space "lisp-patch-form"))))

(deftest unknown-mode-errors
  (ok (handler-case (progn (make-action-space :bogus) nil)
        (error () t))))

(deftest allowed-tools-uses-known-snapshot
  (ok (equal '("fs-list-directory" "fs-read-file" "fs-write-file"
               "load-system" "run-tests")
             (allowed-tools (make-action-space :file-only)))))

(deftest allowed-tools-filters-live-catalog
  (let ((space (make-action-space
                :runtime-native
                :available-tools '("repl-eval" "new-tool" "run-tests"))))
    (ok (equal '("repl-eval" "run-tests") (allowed-tools space)))))

(deftest custom-rules-override-mode
  (let ((space (make-action-space :runtime-native :rules '("run-tests"))))
    (ok (action-allowed-p space "run-tests"))
    (ok (not (action-allowed-p space "repl-eval")))))
