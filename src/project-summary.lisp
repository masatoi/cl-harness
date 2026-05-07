;;;; src/project-summary.lisp
;;;;
;;;; Phase I of the context-management refactor
;;;; (docs/context-management.md §3.3). One project-summary captures
;;;; the cold-start project context — ASDF systems, source files,
;;;; test files — as a structured record with a dirty flag for
;;;; staleness invalidation.
;;;;
;;;; Phase I wraps the existing GATHER-PROJECT-INVENTORY text builder
;;;; into a record. The reader path stays UIOP-only; the new slot
;;;; gives the planner a place to see staleness (when patches touch
;;;; .asd or defpackage forms).

(defpackage #:cl-harness/src/project-summary
  (:use #:cl)
  (:import-from #:cl-harness/src/inventory
                #:gather-project-inventory)
  (:export #:project-summary
           #:make-project-summary
           #:project-summary-project-root
           #:project-summary-system
           #:project-summary-test-system
           #:project-summary-asd-files
           #:project-summary-source-files
           #:project-summary-test-files
           #:project-summary-text
           #:project-summary-gathered-at
           #:project-summary-dirty-p
           #:project-summary-mark-dirty
           #:gather-project-summary))

(in-package #:cl-harness/src/project-summary)

(defclass project-summary ()
  ((project-root :initarg :project-root
                 :reader project-summary-project-root)
   (system :initarg :system :reader project-summary-system)
   (test-system :initarg :test-system :reader project-summary-test-system)
   (asd-files :initarg :asd-files :initform nil
              :reader project-summary-asd-files
              :documentation "List of relative pathname strings for
*.asd files at PROJECT-ROOT.")
   (source-files :initarg :source-files :initform nil
                 :reader project-summary-source-files
                 :documentation "List of relative pathname strings
for src/*.lisp.")
   (test-files :initarg :test-files :initform nil
               :reader project-summary-test-files
               :documentation "List of relative pathname strings for
tests/*.lisp.")
   (text :initarg :text :initform ""
         :reader project-summary-text
         :documentation "The free-text inventory string from
GATHER-PROJECT-INVENTORY, kept verbatim for the planner's
:project-inventory fallback path.")
   (gathered-at :initarg :gathered-at
                :reader project-summary-gathered-at
                :documentation "GET-UNIVERSAL-TIME at the moment of
gather.")
   (dirty-p :initform nil :reader project-summary-dirty-p
            :documentation "T after a patch has touched a .asd or
defpackage form since the gather. NIL until then. Flipped via
PROJECT-SUMMARY-MARK-DIRTY."))
  (:documentation
   "Structured cold-start project context. Replaces (does not
remove) the free-text :project-inventory slot for callers that need
staleness tracking and per-file lists."))

(defun make-project-summary (&key project-root system test-system
                               asd-files source-files test-files
                               (text "")
                               (gathered-at (get-universal-time)))
  "Construct a PROJECT-SUMMARY. PROJECT-ROOT is coerced to a pathname.
SYSTEM and TEST-SYSTEM are required strings. The three file lists
default to NIL and must be lists of strings when non-NIL."
  (check-type system string)
  (check-type test-system string)
  (check-type text string)
  (let ((coerced-root (cond
                        ((pathnamep project-root) project-root)
                        ((stringp project-root)
                         (uiop:ensure-directory-pathname project-root))
                        (t (error "project-summary: :project-root must be ~
a pathname or string, got ~S" project-root)))))
    (dolist (entry asd-files) (check-type entry string))
    (dolist (entry source-files) (check-type entry string))
    (dolist (entry test-files) (check-type entry string))
    (make-instance 'project-summary
                   :project-root coerced-root
                   :system system
                   :test-system test-system
                   :asd-files asd-files
                   :source-files source-files
                   :test-files test-files
                   :text text
                   :gathered-at gathered-at)))

(defun project-summary-mark-dirty (summary)
  "Set SUMMARY's dirty-p flag to T. Idempotent. Returns SUMMARY."
  (setf (slot-value summary 'dirty-p) t)
  summary)

(defun %list-relative (root subdir extension)
  (let ((dir (merge-pathnames subdir
                              (uiop:ensure-directory-pathname root))))
    (when (uiop:directory-exists-p dir)
      (sort (loop for path in (directory (merge-pathnames extension dir))
                  collect (let ((root-ns (namestring
                                          (uiop:ensure-directory-pathname
                                           root)))
                                (path-ns (namestring path)))
                            (if (and (>= (length path-ns) (length root-ns))
                                     (string= path-ns root-ns
                                              :end1 (length root-ns)))
                                (subseq path-ns (length root-ns))
                                path-ns)))
            #'string<))))

(defun gather-project-summary (&key project-root system test-system)
  "Build a PROJECT-SUMMARY by enumerating .asd / src / tests files
under PROJECT-ROOT and capturing the existing GATHER-PROJECT-INVENTORY
text. Reader path stays UIOP-only."
  (let ((root (uiop:ensure-directory-pathname project-root)))
    (make-project-summary
     :project-root root
     :system system
     :test-system test-system
     :asd-files (%list-relative root "" "*.asd")
     :source-files (%list-relative root "src/" "*.lisp")
     :test-files (%list-relative root "tests/" "*.lisp")
     :text (gather-project-inventory
            :project-root root :system system :test-system test-system))))
