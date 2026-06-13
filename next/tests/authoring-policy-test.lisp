;;;; next/tests/authoring-policy-test.lisp

(defpackage #:cl-harness-next/tests/authoring-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/authoring-policy
                #:extract-deftest-forms
                #:authoring-policy
                #:policy-state
                #:policy-authored-names)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:run-kernel
                #:control-policy
                #:decide
                #:make-decision)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-queue
                #:enqueue-mission)
  (:import-from #:cl-harness-next/src/mission-runner
                #:run-mission)
  (:import-from #:cl-harness-next/src/governor
                #:governor))

(in-package #:cl-harness-next/tests/authoring-policy-test)

(deftest extract-deftest-accepts-one-form
  (multiple-value-bind (text names)
      (extract-deftest-forms "(deftest add-adds (ok (= 5 (add 2 3))))")
    (ok (stringp text))
    (ok (search "deftest" text))
    (ok (equal '("ADD-ADDS") names))))

(deftest extract-deftest-accepts-multiple-forms
  (multiple-value-bind (text names)
      (extract-deftest-forms
       "(deftest a (ok t))
(deftest b (ok t))")
    (ok (stringp text))
    (ok (equal '("A" "B") names))))

(deftest extract-deftest-strips-fence-and-trims
  (multiple-value-bind (text names)
      (extract-deftest-forms
       (format nil "```lisp~%(deftest c (ok (= 1 (f))))~%```"))
    (ok (search "deftest" text))
    (ok (equal '("C") names))))

(deftest extract-deftest-rejects-non-deftest
  (multiple-value-bind (text reason)
      (extract-deftest-forms "(defun add (a b) (+ a b))")
    (ok (null text))
    (ok (and (stringp reason) (search "deftest" reason)))))

(deftest extract-deftest-rejects-empty-and-prose
  (ok (null (extract-deftest-forms "   ")))
  (ok (null (extract-deftest-forms "I cannot help with that"))))

(deftest extract-deftest-rejects-unbalanced
  (ok (null (extract-deftest-forms "(deftest oops (ok (= 1 1))"))))

(deftest author-prompt-includes-goal-and-surface
  (let ((p (make-instance 'cl-harness-next/src/authoring-policy::authoring-policy
                          :goal "add must return a+b"
                          :system "s" :test-system "s/tests"
                          :test-file "tests/main-test.lisp"
                          :test-package "s/tests/main-test"
                          :author-fn (lambda (x) (declare (ignore x)) "")
                          :reviewer nil :fix-policy nil)))
    (setf (cl-harness-next/src/authoring-policy::policy-sut-package p) "S/SRC/MAIN"
          (cl-harness-next/src/authoring-policy::policy-sut-surface p)
          "(defun add (a b) 0)")
    (let ((prompt (cl-harness-next/src/authoring-policy::%author-prompt p)))
      (ok (search "add must return a+b" prompt))
      (ok (search "S/SRC/MAIN" prompt))
      (ok (search "(defun add (a b) 0)" prompt)))))
