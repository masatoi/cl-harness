;;;; cl-harness.asd

(asdf:defsystem "cl-harness"
  :class :package-inferred-system
  :description "Runtime-native coding agent harness for Common Lisp."
  :author "cl-harness contributors"
  :license "MIT"
  :version "0.4.0"
  :depends-on ("alexandria"
               "yason"
               "local-time"
               "dexador"
               "bordeaux-threads"
               "clingon"
               "cl-harness/src/main")
  :in-order-to ((test-op (test-op "cl-harness/tests"))))

(asdf:defsystem "cl-harness/tests"
  :class :package-inferred-system
  :depends-on ("rove"
               "cl-harness"
               "cl-harness/tests/main-test"
               "cl-harness/tests/mcp-test"
               "cl-harness/tests/mcp-stdio-test"
               "cl-harness/tests/mcp-resolve-test"
               "cl-harness/tests/model-test"
               "cl-harness/tests/action-test"
               "cl-harness/tests/policy-test"
               "cl-harness/tests/verify-test"
               "cl-harness/tests/agent-test"
               "cl-harness/tests/bench-test"
               "cl-harness/tests/planner-test"
               "cl-harness/tests/orchestrator-test"
               "cl-harness/tests/explore-test"
               "cl-harness/tests/compact-test"
               "cl-harness/tests/inventory-test"
               "cl-harness/tests/abstraction-test"
               "cl-harness/tests/integration-test"
               "cl-harness/tests/mode-selector-test"
               "cl-harness/tests/develop-bench-test"
               "cl-harness/tests/state-test"
               "cl-harness/tests/runtime-vocabulary-test"
               "cl-harness/tests/source-fact-test"
               "cl-harness/tests/patch-record-test"
               "cl-harness/tests/project-summary-test"
               "cl-harness/tests/repl-finding-test"
               "cl-harness/tests/subtask-summary-test"
               "cl-harness/tests/failure-ledger-test"
               "cl-harness/tests/context-view-test"
               "cl-harness/tests/report-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let ((test-packages
                           (remove-if-not
                            (lambda (dep)
                              (and (stringp dep)
                                   (uiop:string-prefix-p "cl-harness/tests/" dep)))
                            (asdf:system-depends-on c))))
                      (uiop:symbol-call :rove :run test-packages))))

(asdf:defsystem "cl-harness/binary"
  :description "Build target that produces a `cl-harness` executable.
ASDF:MAKE on this system invokes program-op with the cli-main entry
point. The library system stays pure; this is just a thin wrapper so
`cl-harness fix --project ...` and `cl-harness bench --suite ...` work
from a shell."
  :depends-on ("cl-harness")
  :build-operation "program-op"
  :build-pathname "cl-harness"
  :entry-point "cl-harness/src/cli-main:main")
