;;;; tests/scaffold-test.lisp
;;;;
;;;; rove deftests for cl-harness/src/scaffold. All tests run against
;;;; uiop:with-temporary-directory tmpdirs and never touch the network
;;;; or an LLM provider.

(defpackage #:cl-harness/tests/scaffold-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/scaffold
                #:scaffold
                #:scaffold-result
                #:scaffold-result-status
                #:scaffold-result-paths-written
                #:scaffold-result-conflicts
                #:scaffold-bad-system-name
                #:scaffold-partial-state
                #:scaffold-partial-state-existing
                #:scaffold-partial-state-missing))

(in-package #:cl-harness/tests/scaffold-test)
