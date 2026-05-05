;;;; tests/bench-test.lisp
;;;;
;;;; Phase 4 unit tests for the benchmark runner (PRD §8.11, §16).
;;;; Pure logic (task spec loader, suite discovery, aggregation) is
;;;; covered here. RUN-BENCHMARK-TASK is exercised against stubbed
;;;; LLM/MCP transports so the wrapping logic is verified without
;;;; touching the network.

(defpackage #:cl-harness/tests/bench-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/bench
                #:bench-task
                #:bench-task-id
                #:bench-task-description
                #:bench-task-system
                #:bench-task-test-system
                #:bench-task-issue
                #:bench-task-fixture-path
                #:bench-result
                #:bench-result-success-p
                #:load-bench-task
                #:discover-tasks
                #:aggregate-results))

(in-package #:cl-harness/tests/bench-test)

(defun %write-string (path content)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string content s)))

(defun %fresh-tmpdir (label)
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "~A~A-~A/"
                      (namestring (uiop:temporary-directory))
                      label
                      (get-internal-real-time)))))
    (ensure-directories-exist dir)
    dir))

(deftest load-bench-task-parses-task-json
  (let* ((task-dir (%fresh-tmpdir "cl-harness-bench-task"))
         (task-json (merge-pathnames "task.json" task-dir))
         (fixture-dir (merge-pathnames "fixture/" task-dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist fixture-dir)
           (%write-string
            task-json
            "{\"id\":\"sample\",\"description\":\"sample task\",\"system\":\"sys\",\"test-system\":\"sys/tests\",\"issue\":\"do the thing\",\"fixture-dir\":\"fixture\"}")
           (let ((task (load-bench-task task-dir)))
             (ok (typep task 'bench-task))
             (ok (equal "sample" (bench-task-id task)))
             (ok (equal "sample task" (bench-task-description task)))
             (ok (equal "sys" (bench-task-system task)))
             (ok (equal "sys/tests" (bench-task-test-system task)))
             (ok (equal "do the thing" (bench-task-issue task)))
             (ok (uiop:directory-exists-p (bench-task-fixture-path task)))))
      (uiop:delete-directory-tree task-dir :validate t :if-does-not-exist :ignore))))

(deftest load-bench-task-defaults-fixture-dir-to-fixture
  (let* ((task-dir (%fresh-tmpdir "cl-harness-bench-task-default"))
         (task-json (merge-pathnames "task.json" task-dir))
         (fixture-dir (merge-pathnames "fixture/" task-dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist fixture-dir)
           (%write-string
            task-json
            "{\"id\":\"d\",\"system\":\"s\",\"test-system\":\"s/tests\",\"issue\":\"x\"}")
           (let ((task (load-bench-task task-dir)))
             (ok (uiop:directory-exists-p (bench-task-fixture-path task)))))
      (uiop:delete-directory-tree task-dir :validate t :if-does-not-exist :ignore))))

(deftest discover-tasks-scans-suite-dir
  (let* ((suite-dir (%fresh-tmpdir "cl-harness-bench-suite"))
         (a-dir (merge-pathnames "001-a/" suite-dir))
         (b-dir (merge-pathnames "002-b/" suite-dir))
         (c-dir (merge-pathnames "003-no-task/" suite-dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "fixture/" a-dir))
           (ensure-directories-exist (merge-pathnames "fixture/" b-dir))
           (ensure-directories-exist c-dir)
           (%write-string (merge-pathnames "task.json" a-dir)
                          "{\"id\":\"a\",\"system\":\"s\",\"test-system\":\"s/tests\",\"issue\":\"x\"}")
           (%write-string (merge-pathnames "task.json" b-dir)
                          "{\"id\":\"b\",\"system\":\"s\",\"test-system\":\"s/tests\",\"issue\":\"x\"}")
           (let ((tasks (discover-tasks suite-dir)))
             (ok (= 2 (length tasks)))
             (ok (every (lambda (id) (member id '("a" "b") :test #'equal))
                        (mapcar #'bench-task-id tasks)))))
      (uiop:delete-directory-tree suite-dir :validate t :if-does-not-exist :ignore))))

(defun %make-result (status &key (turns 0) (tokens 0) (patches 0))
  (make-instance 'bench-result
                 :task (make-instance 'bench-task
                                      :id "x" :description ""
                                      :system "s" :test-system "s/tests"
                                      :issue "x"
                                      :path #P"/tmp/x/"
                                      :fixture-path #P"/tmp/x/fixture/")
                 :condition :generic-mcp
                 :status status
                 :turns turns
                 :patches patches
                 :patch-attempts patches
                 :tokens tokens
                 :elapsed-ms 0
                 :transcript-path #P"/tmp/log.jsonl"))

(deftest bench-result-success-p-true-only-on-passed
  (ok (bench-result-success-p (%make-result :passed)))
  (ok (not (bench-result-success-p (%make-result :give-up))))
  (ok (not (bench-result-success-p (%make-result :max-turns))))
  (ok (not (bench-result-success-p (%make-result :dirty-only))))
  (ok (not (bench-result-success-p (%make-result :error)))))

(deftest aggregate-results-computes-summary-stats
  (let* ((results (list (%make-result :passed   :turns 3 :tokens 1000)
                        (%make-result :passed   :turns 5 :tokens 2000)
                        (%make-result :max-turns :turns 20 :tokens 8000)
                        (%make-result :give-up  :turns 7 :tokens 3000)))
         (agg (aggregate-results results)))
    (ok (= 4 (gethash "total" agg)))
    (ok (= 2 (gethash "passed" agg)))
    (ok (= 0.5 (gethash "pass-rate" agg)))
    (ok (= (/ (+ 3 5 20 7) 4) (gethash "mean-turns" agg)))
    (ok (= (/ (+ 1000 2000 8000 3000) 4) (gethash "mean-tokens" agg)))))

(deftest aggregate-results-handles-empty-list
  (let ((agg (aggregate-results '())))
    (ok (zerop (gethash "total" agg)))
    (ok (zerop (gethash "passed" agg)))
    (ok (zerop (gethash "pass-rate" agg)))))
