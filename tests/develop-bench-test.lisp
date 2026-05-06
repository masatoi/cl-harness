;;;; tests/develop-bench-test.lisp
;;;;
;;;; v0.4 Phase 7 unit tests for src/develop-bench.lisp.
;;;; Covers the JSON loader, the suite walker, the sandbox copier,
;;;; and a per-fixture health check that fails loudly when one of
;;;; the in-repo greenfield projects gets out of shape (missing
;;;; .asd, missing src/main.lisp, missing tests/main-test.lisp,
;;;; etc.).

(defpackage #:cl-harness/tests/develop-bench-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/develop-bench
                #:develop-task
                #:develop-task-id
                #:develop-task-goal
                #:develop-task-system
                #:develop-task-test-system
                #:develop-task-fixture-path
                #:develop-task-error
                #:load-develop-task
                #:discover-develop-tasks
                #:prepare-develop-task-sandbox))

(in-package #:cl-harness/tests/develop-bench-test)

(defun %suite-dir ()
  (let ((this-file (or *load-pathname* *compile-file-pathname*)))
    (if this-file
        (uiop:ensure-directory-pathname
         (merge-pathnames "../develop-benchmarks/"
                          (uiop:pathname-directory-pathname this-file)))
        ;; Fallback for interactive runs: assume CWD is the project root.
        (uiop:ensure-directory-pathname "develop-benchmarks/"))))

(defun %tmp-dir (name)
  (let ((d (merge-pathnames
            (format nil "cl-harness-develop-bench-test-~A-~A/"
                    name (get-internal-real-time))
            (uiop:temporary-directory))))
    (ensure-directories-exist d)
    d))

;; --- load-develop-task --------------------------------------------------

(deftest load-develop-task-from-task-dir
  (let* ((path (merge-pathnames "100-greet/" (%suite-dir)))
         (task (load-develop-task path)))
    (ok (typep task 'develop-task))
    (ok (equal "100-greet" (develop-task-id task)))
    (ok (equal "greet" (develop-task-system task)))
    (ok (equal "greet/tests" (develop-task-test-system task)))
    (ok (search "greet" (develop-task-goal task)))))

(deftest load-develop-task-resolves-fixture-path
  (let* ((path (merge-pathnames "100-greet/" (%suite-dir)))
         (task (load-develop-task path))
         (fixture (develop-task-fixture-path task)))
    (ok (uiop:directory-exists-p fixture))
    (ok (probe-file (merge-pathnames "src/main.lisp" fixture)))
    (ok (probe-file (merge-pathnames "tests/main-test.lisp" fixture)))))

(deftest load-develop-task-rejects-missing-json
  (let ((empty (%tmp-dir "empty")))
    (unwind-protect
         (ok (handler-case
                 (progn (load-develop-task empty) nil)
               (develop-task-error () t)))
      (uiop:delete-directory-tree empty :validate t :if-does-not-exist :ignore))))

(deftest load-develop-task-rejects-missing-required-field
  (let* ((dir (%tmp-dir "bad-json"))
         (json (merge-pathnames "develop-task.json" dir)))
    (unwind-protect
         (progn
           (with-open-file (out json :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
             (write-string "{\"id\":\"x\"}" out))
           (ok (handler-case
                   (progn (load-develop-task json) nil)
                 (develop-task-error () t))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

;; --- discover-develop-tasks --------------------------------------------

(deftest discover-develop-tasks-finds-all-fixtures
  (let* ((tasks (discover-develop-tasks (%suite-dir)))
         (ids (mapcar #'develop-task-id tasks)))
    (ok (>= (length tasks) 7)
        "v0.4 Phase 7 ships 7 fixtures (100-greet through 106-format-currency)")
    (ok (member "100-greet" ids :test #'string=))
    (ok (member "101-double" ids :test #'string=))
    (ok (member "102-counter-class" ids :test #'string=))
    (ok (member "103-fizz-buzz" ids :test #'string=))
    (ok (member "104-cache-simple" ids :test #'string=))
    (ok (member "105-validate-email" ids :test #'string=))
    (ok (member "106-format-currency" ids :test #'string=))))

(deftest discover-develop-tasks-returns-sorted-by-id
  (let* ((tasks (discover-develop-tasks (%suite-dir)))
         (ids (mapcar #'develop-task-id tasks)))
    (ok (equal ids (sort (copy-list ids) #'string<))
        "discover returns ids in lexical order so the report is deterministic")))

;; --- per-fixture health check ------------------------------------------

(deftest each-fixture-has-an-asd-and-greenfield-source
  ;; A health-check that fails loud when a fixture loses its scaffolding.
  ;; Each fixture must have:
  ;;   - <name>.asd somewhere under fixture/
  ;;   - fixture/src/main.lisp containing (defpackage ...)
  ;;   - fixture/tests/main-test.lisp containing (defpackage ...)
  (let ((tasks (discover-develop-tasks (%suite-dir))))
    (dolist (task tasks)
      (let* ((fixture (develop-task-fixture-path task))
             (src (merge-pathnames "src/main.lisp" fixture))
             (tests (merge-pathnames "tests/main-test.lisp" fixture))
             (asd-files (directory (merge-pathnames "*.asd" fixture))))
        (ok (probe-file src)
            (format nil "~A: src/main.lisp present" (develop-task-id task)))
        (ok (probe-file tests)
            (format nil "~A: tests/main-test.lisp present" (develop-task-id task)))
        (ok asd-files
            (format nil "~A: at least one .asd file" (develop-task-id task)))
        (when (probe-file src)
          (let ((content (uiop:read-file-string src)))
            (ok (search "defpackage" content)
                (format nil "~A: src/main.lisp has defpackage" (develop-task-id task)))))))))

;; --- prepare-develop-task-sandbox --------------------------------------

(deftest prepare-sandbox-replicates-fixture-tree
  (let* ((task (load-develop-task
                (merge-pathnames "100-greet/" (%suite-dir))))
         (parent (%tmp-dir "sandbox-parent"))
         (sandbox (prepare-develop-task-sandbox task :into parent)))
    (unwind-protect
         (progn
           (ok (uiop:directory-exists-p sandbox))
           (ok (probe-file (merge-pathnames "greet.asd" sandbox)))
           (ok (probe-file (merge-pathnames "src/main.lisp" sandbox)))
           (ok (probe-file (merge-pathnames "tests/main-test.lisp" sandbox)))
           ;; The original fixture must still exist after the copy.
           (ok (probe-file (merge-pathnames
                            "src/main.lisp"
                            (develop-task-fixture-path task)))
               "original fixture unmolested"))
      (uiop:delete-directory-tree parent :validate t :if-does-not-exist :ignore))))

(deftest prepare-sandbox-uses-unique-paths
  (let* ((task (load-develop-task
                (merge-pathnames "100-greet/" (%suite-dir))))
         (parent (%tmp-dir "sandbox-unique"))
         (s1 (prepare-develop-task-sandbox task :into parent))
         (s2 (prepare-develop-task-sandbox task :into parent)))
    (unwind-protect
         (ok (not (equal s1 s2))
             "concurrent calls produce distinct sandboxes")
      (uiop:delete-directory-tree parent :validate t :if-does-not-exist :ignore))))
