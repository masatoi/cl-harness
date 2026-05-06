;;;; src/develop-bench.lisp
;;;;
;;;; v0.4 Phase 7 of the development harness extension. Greenfield
;;;; benchmark suite for cl-harness:develop, mirroring src/bench.lisp's
;;;; shape but loading develop-task.json (not task.json) and using the
;;;; orchestrator's DEVELOP entry point instead of RUN-AGENT directly.
;;;;
;;;; Each task in develop-benchmarks/ is a tiny ASDF project whose
;;;; source is intentionally empty (only defpackage + in-package and
;;;; the target API symbols pre-exported). The task's goal lives in
;;;; develop-task.json, and the agent's job is to fill the source in
;;;; until planner-authored deftest forms pass.
;;;;
;;;; This module provides:
;;;;   - DEVELOP-TASK class — parsed develop-task.json + paths
;;;;   - LOAD-DEVELOP-TASK / DISCOVER-DEVELOP-TASKS — filesystem loader
;;;;   - PREPARE-DEVELOP-TASK-SANDBOX — copy fixture/ to a tmpdir so
;;;;     re-runs do not pollute the in-repo fixture
;;;;
;;;; The actual benchmark runner that calls cl-harness/src/cli:develop
;;;; per-task with multiple models lives in scripts/, not here — this
;;;; file stays pure-Lisp and side-effect-free so unit tests can
;;;; exercise it without an LLM endpoint.

(defpackage #:cl-harness/src/develop-bench
  (:use #:cl)
  (:export #:develop-task
           #:develop-task-id
           #:develop-task-goal
           #:develop-task-system
           #:develop-task-test-system
           #:develop-task-test-file
           #:develop-task-path
           #:develop-task-fixture-path
           #:develop-task-error
           #:develop-task-error-message
           #:load-develop-task
           #:discover-develop-tasks
           #:prepare-develop-task-sandbox))

(in-package #:cl-harness/src/develop-bench)

(define-condition develop-task-error (error)
  ((message :initarg :message :reader develop-task-error-message)
   (path :initarg :path :initform nil :reader develop-task-error-path))
  (:report (lambda (c s)
             (format s "develop-task error: ~A~@[ (~A)~]"
                     (develop-task-error-message c)
                     (develop-task-error-path c)))))

(defclass develop-task ()
  ((id :initarg :id :reader develop-task-id)
   (goal :initarg :goal :reader develop-task-goal)
   (system :initarg :system :reader develop-task-system)
   (test-system :initarg :test-system :reader develop-task-test-system)
   (test-file :initarg :test-file :reader develop-task-test-file)
   (path :initarg :path :reader develop-task-path)
   (fixture-path :initarg :fixture-path :reader develop-task-fixture-path))
  (:documentation
   "One greenfield task in a develop-benchmarks/ suite. ID is the
canonical task name (also the directory name). GOAL is the
natural-language statement the planner sees. SYSTEM /
TEST-SYSTEM are the ASDF system names. TEST-FILE is the relative
path inside the sandbox where planner-authored deftest forms get
appended. PATH is the absolute path to the task directory (parent
of develop-task.json). FIXTURE-PATH is the absolute path to the
fixture/ subdirectory that gets copied to a sandbox before each
run."))

(defun %require-string (table key path)
  (let ((v (gethash key table)))
    (unless (and (stringp v) (plusp (length v)))
      (error 'develop-task-error
             :message (format nil "develop-task.json missing or empty string field ~S" key)
             :path path))
    v))

(defun load-develop-task (path)
  "Parse develop-task.json at PATH (or directory containing one) into
a DEVELOP-TASK. Signals DEVELOP-TASK-ERROR on missing required
fields."
  (let ((json-path
         (cond
           ((uiop:directory-pathname-p path)
            (merge-pathnames "develop-task.json" path))
           ((string-equal "json" (pathname-type path))
            path)
           (t (merge-pathnames "develop-task.json"
                               (uiop:ensure-directory-pathname path))))))
    (unless (probe-file json-path)
      (error 'develop-task-error
             :message "develop-task.json not found"
             :path json-path))
    (let* ((task-dir (uiop:pathname-directory-pathname json-path))
           (table (with-open-file (in json-path :direction :input)
                    (yason:parse in)))
           (id (%require-string table "id" json-path))
           (goal (%require-string table "goal" json-path))
           (system (%require-string table "system" json-path))
           (test-system (%require-string table "test-system" json-path))
           (test-file (%require-string table "test-file" json-path))
           (fixture-dir-rel
            (or (gethash "fixture-dir" table) "fixture"))
           (fixture-path (uiop:ensure-directory-pathname
                          (merge-pathnames fixture-dir-rel task-dir))))
      (unless (uiop:directory-exists-p fixture-path)
        (error 'develop-task-error
               :message (format nil "fixture-dir ~A does not exist" fixture-dir-rel)
               :path fixture-path))
      (make-instance 'develop-task
                     :id id
                     :goal goal
                     :system system
                     :test-system test-system
                     :test-file test-file
                     :path task-dir
                     :fixture-path fixture-path))))

(defun discover-develop-tasks (suite-dir)
  "Walk SUITE-DIR for direct child directories that contain a
develop-task.json and return the parsed DEVELOP-TASK list, sorted
by id. Subdirectories without a develop-task.json are silently
skipped — the README.md in the suite root is the canonical
example."
  (check-type suite-dir (or string pathname))
  (let* ((root (uiop:ensure-directory-pathname suite-dir))
         (children (uiop:subdirectories root))
         (tasks (loop for d in children
                      for json = (merge-pathnames "develop-task.json" d)
                      when (probe-file json)
                        collect (load-develop-task json))))
    (sort tasks #'string< :key #'develop-task-id)))

(defun %copy-tree (source dest)
  "Recursively copy SOURCE's contents into DEST, creating DEST's
parents as needed. SOURCE and DEST must be directory pathnames."
  (let ((source-dir (uiop:ensure-directory-pathname source))
        (dest-dir (uiop:ensure-directory-pathname dest)))
    (ensure-directories-exist dest-dir)
    (dolist (file (uiop:directory-files source-dir))
      (let ((target (merge-pathnames (file-namestring file) dest-dir)))
        (uiop:copy-file file target)))
    (dolist (sub (uiop:subdirectories source-dir))
      (let* ((sub-name (car (last (pathname-directory sub))))
             (target-sub (uiop:ensure-directory-pathname
                          (merge-pathnames sub-name dest-dir))))
        (%copy-tree sub target-sub)))))

(defvar *sandbox-counter* 0
  "Monotonically incrementing counter so concurrent
PREPARE-DEVELOP-TASK-SANDBOX calls within the same nanosecond still
get distinct paths. GET-INTERNAL-REAL-TIME alone is too coarse on
fast machines.")

(defun prepare-develop-task-sandbox (task &key into)
  "Copy TASK's fixture/ tree into a fresh sandbox directory and return
the sandbox's absolute pathname. INTO, when supplied, is the
parent directory; otherwise UIOP:TEMPORARY-DIRECTORY is used. The
sandbox is unique per call (epoch+counter-suffixed) so concurrent
benchmark runs do not collide.

Callers are responsible for cleaning up the sandbox after the
benchmark finishes (typically with UIOP:DELETE-DIRECTORY-TREE)."
  (check-type task develop-task)
  (let* ((parent (uiop:ensure-directory-pathname
                  (or into (uiop:temporary-directory))))
         (suffix (incf *sandbox-counter*))
         (sandbox (uiop:ensure-directory-pathname
                   (merge-pathnames
                    (format nil "develop-bench-~A-~A-~A/"
                            (develop-task-id task)
                            (get-internal-real-time)
                            suffix)
                    parent))))
    (%copy-tree (develop-task-fixture-path task) sandbox)
    sandbox))
