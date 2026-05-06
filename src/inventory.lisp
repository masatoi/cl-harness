;;;; src/inventory.lisp
;;;;
;;;; v0.4 Phase 2: project inventory snapshot
;;;; (docs/notes/2026-05-06-v0.4-development-harness.md).
;;;;
;;;; Build a human/LLM-readable text block describing the existing
;;;; project's vocabulary — ASDF systems, defpackage forms, defun
;;;; signatures — so that PLAN-DEVELOPMENT can ground its plan in
;;;; what's already there instead of inventing parallel structure.
;;;;
;;;; The current implementation reads files directly via UIOP rather
;;;; than going through cl-mcp. The justification: this is a
;;;; pre-planning, read-only step that runs once before any LLM call;
;;;; it doesn't need to share a worker with anything else, and the
;;;; cl-mcp round-trip is gratuitous overhead. If a future caller
;;;; needs to inventory a project that's only reachable through
;;;; cl-mcp (e.g. a remote ASDF tree), an MCP-backed alternative
;;;; gather can be added alongside.

(defpackage #:cl-harness/src/inventory
  (:use #:cl)
  (:export #:gather-project-inventory
           #:+default-inventory-byte-budget+))

(in-package #:cl-harness/src/inventory)

(defparameter +default-inventory-byte-budget+ 5000
  "Upper bound (in characters, approximate proxy for tokens) on the
inventory string PLAN-DEVELOPMENT injects into the planner's user
prompt. Beyond ~5kB the planner's context window starts to bite for
small-window models. Tunable per call.")

(defparameter +per-file-snippet-budget+ 480
  "Maximum characters captured per individual source/test file. Gives
the planner enough head-of-file context to see defpackage / in-package
declarations without flooding the prompt with implementation bodies.")

(defun %read-file-snippet (path budget)
  "Return the first BUDGET characters of PATH as a string, with a
truncation marker appended when the file is larger. Errors are
swallowed and reported inline so an unreadable file does not abort
the whole inventory."
  (handler-case
      (let* ((content (uiop:read-file-string path))
             (len (length content)))
        (if (> len budget)
            (concatenate 'string
                         (subseq content 0 budget)
                         (format nil "~%;; ... [~D bytes truncated]" (- len budget)))
            content))
    (error (c)
      (format nil "[unreadable: ~A]" c))))

(defun %list-lisp-files (dir)
  "Return a sorted list of pathnames for *.lisp files directly under
DIR. Recursion is intentionally one level — package-inferred-system
projects keep src/ flat enough that a plain glob is enough; deeper
trees (rare in this layer) get a `... +K more files` summary."
  (when (uiop:directory-exists-p dir)
    (sort (copy-list
           (directory (merge-pathnames "*.lisp" dir)))
          #'string< :key #'namestring)))

(defun %relative-namestring (root path)
  "Return PATH expressed relative to ROOT, falling back to the
absolute namestring on error."
  (handler-case
      (let ((root-ns (namestring (uiop:ensure-directory-pathname root)))
            (path-ns (namestring path)))
        (if (and (>= (length path-ns) (length root-ns))
                 (string= path-ns root-ns :end1 (length root-ns)))
            (subseq path-ns (length root-ns))
            path-ns))
    (error () (namestring path))))

(defun %emit-section-header (stream title)
  (format stream "~%~A~%" title)
  (format stream "~A~%" (make-string (length title) :initial-element #\-)))

(defun %emit-asd-files (stream root)
  (let ((asds (sort (copy-list
                     (directory
                      (merge-pathnames "*.asd"
                                       (uiop:ensure-directory-pathname root))))
                    #'string< :key #'namestring)))
    (when asds
      (%emit-section-header stream "ASDF systems (.asd)")
      (dolist (asd asds)
        (format stream "~%~A:~%~A~%"
                (%relative-namestring root asd)
                (%read-file-snippet asd +per-file-snippet-budget+))))))

(defun %emit-lisp-tree (stream root subdir label)
  (let* ((dir (merge-pathnames subdir
                               (uiop:ensure-directory-pathname root)))
         (files (%list-lisp-files dir)))
    (when files
      (%emit-section-header stream label)
      (dolist (file files)
        (format stream "~%~A:~%~A~%"
                (%relative-namestring root file)
                (%read-file-snippet file +per-file-snippet-budget+))))))

(defun %trim-to-budget (text budget)
  "If TEXT exceeds BUDGET characters, truncate and append a footer
that reports how much was dropped. Otherwise return TEXT unchanged."
  (if (> (length text) budget)
      (concatenate 'string
                   (subseq text 0 budget)
                   (format nil "~%~%;; --- inventory truncated (~D / ~D bytes kept) ---"
                           budget (length text)))
      text))

(defun gather-project-inventory (&key project-root system test-system
                                      (byte-budget +default-inventory-byte-budget+))
  "Return a multi-section text block describing PROJECT-ROOT's
existing structure, suitable for prepending to a PLAN-DEVELOPMENT
user prompt.

Sections (each appears only when non-empty):
  - Header (project-root / system / test-system)
  - ASDF systems (.asd files, head-of-file content)
  - Source files (src/*.lisp, head-of-file content)
  - Test files (tests/*.lisp, head-of-file content)

The combined output is hard-capped at BYTE-BUDGET characters; the
sections are emitted in importance order (asd before src before
tests), so the truncation cuts test-side detail first."
  (check-type project-root (or string pathname))
  (check-type byte-budget (integer 1))
  (let* ((root (uiop:ensure-directory-pathname project-root))
         (raw (with-output-to-string (s)
                (format s "Project Inventory")
                (format s "~%=================~%")
                (format s "Project root: ~A~%" root)
                (when system (format s "System: ~A~%" system))
                (when test-system (format s "Test system: ~A~%" test-system))
                (%emit-asd-files s root)
                (%emit-lisp-tree s root "src/" "Source files (src/*.lisp)")
                (%emit-lisp-tree s root "tests/" "Test files (tests/*.lisp)"))))
    (%trim-to-budget raw byte-budget)))
