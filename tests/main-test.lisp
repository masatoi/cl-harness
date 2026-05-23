;;;; tests/main-test.lisp
;;;;
;;;; Phase 0 smoke tests. Verifies the package-inferred-system layout loads,
;;;; the public symbols are exported, and the CLI stubs honor the
;;;; "not implemented yet" contract documented in src/cli.lisp.

(defpackage #:cl-harness/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/config
                #:make-run-config
                #:run-config
                #:run-config-system
                #:run-config-condition
                #:run-config-limits
                #:run-limits
                #:run-limits-max-patches
                #:run-limits-max-context-tokens
                #:make-default-limits)
  (:import-from #:cl-harness/src/log
                #:with-run-logger
                #:log-event))

(in-package #:cl-harness/tests/main-test)

(deftest package-layout
  (testing "facade package is present and aliased"
    (ok (find-package :cl-harness/src/main))
    (ok (find-package :cl-harness)))
  (testing "subsystem packages load"
    (ok (find-package :cl-harness/src/config))
    (ok (find-package :cl-harness/src/log))
    (ok (find-package :cl-harness/src/cli))))

(deftest config-construction
  (testing "make-run-config builds a populated run-config"
    (let ((c (make-run-config :project-root "/tmp/proj"
                              :system "demo"
                              :test-system "demo/tests"
                              :issue "stub"
                              :condition :runtime-native)))
      (ok (typep c 'run-config))
      (ok (equal "demo" (run-config-system c)))
      (ok (eq :runtime-native (run-config-condition c)))
      (ok (typep (run-config-limits c) 'run-limits))
      (ok (= 5 (run-limits-max-patches (run-config-limits c)))))))

(deftest run-limits-default-max-context-tokens
  (ok (= 50000
         (cl-harness/src/config:run-limits-max-context-tokens
          (cl-harness/src/config:make-default-limits)))))

(deftest run-limits-accepts-custom-max-context-tokens
  (let ((l (make-instance 'cl-harness/src/config:run-limits
                          :max-turns 1 :max-tool-calls 1
                          :max-patches 1 :max-read-files 1
                          :max-repl-evals 1 :max-wall-clock-seconds 1
                          :max-action-parse-errors 1
                          :max-context-tokens 12345)))
    (ok (= 12345 (cl-harness/src/config:run-limits-max-context-tokens l)))))

(deftest log-roundtrip
  (testing "log-event writes one JSON line per call"
    (let ((path (merge-pathnames
                 (format nil "cl-harness-log-~A.jsonl" (get-universal-time))
                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (with-run-logger (l path)
               (log-event l :run-start '(("note" . "smoke"))))
             (let ((line (with-open-file (in path) (read-line in nil nil))))
               (ok (stringp line))
               (ok (search "\"type\":\"run-start\"" line))
               (ok (search "\"note\":\"smoke\"" line))))
        (when (probe-file path) (delete-file path))))))
