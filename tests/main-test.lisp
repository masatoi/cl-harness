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
                #:run-limits-max-patches)
  (:import-from #:cl-harness/src/cli
                #:fix
                #:bench
                #:not-implemented-error)
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
      (ok (= 3 (run-limits-max-patches (run-config-limits c)))))))

(deftest cli-stubs-signal-not-implemented
  (testing "fix signals not-implemented-error after building config"
    (ok (handler-case
            (progn
              (fix :project-root "/tmp/proj"
                   :system "demo"
                   :test-system "demo/tests"
                   :issue "stub")
              nil)
          (not-implemented-error () t))))
  (testing "bench signals not-implemented-error"
    (ok (handler-case
            (progn (bench) nil)
          (not-implemented-error () t)))))

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
