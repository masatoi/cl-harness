;;;; src/integration.lisp
;;;;
;;;; v0.4 Phase 5 of the development harness extension. Static
;;;; integration check: after all develop steps pass, walk every
;;;; .lisp file under the project root, parse the defpackage forms
;;;; into a package graph, and flag inconsistencies in the
;;;; export / import surface so a passing per-step verify cannot
;;;; mask a project-wide structural problem (requirement 4.9).
;;;;
;;;; Two issue kinds for v0.4:
;;;;   :unknown-package    — a defpackage's :import-from clause
;;;;                          names a package whose name shares an
;;;;                          in-project prefix but is not defined
;;;;                          anywhere in the graph.
;;;;   :unexported-symbol  — a defpackage's :import-from imports a
;;;;                          symbol the source package's own
;;;;                          defpackage does NOT list under :export.
;;;;
;;;; Imports from out-of-project packages (alexandria, rove, ...) are
;;;; never flagged — the parser only knows about defpackage forms it
;;;; can read on disk.

(defpackage #:cl-harness/src/integration
  (:use #:cl)
  (:export #:package-info
           #:package-info-name
           #:package-info-nicknames
           #:package-info-exports
           #:package-info-imports
           #:package-info-uses
           #:package-info-file
           #:integration-issue
           #:integration-issue-kind
           #:integration-issue-file
           #:integration-issue-package
           #:integration-issue-description
           #:gather-package-graph
           #:find-integration-issues
           #:format-integration-issues-markdown))

(in-package #:cl-harness/src/integration)

(defclass package-info ()
  ((name :initarg :name :reader package-info-name)
   (nicknames :initarg :nicknames :initform nil
              :reader package-info-nicknames)
   (exports :initarg :exports :initform nil :reader package-info-exports)
   (imports :initarg :imports :initform nil :reader package-info-imports)
   (uses :initarg :uses :initform nil :reader package-info-uses)
   (file :initarg :file :initform nil :reader package-info-file))
  (:documentation
   "Captured shape of one DEFPACKAGE form. NAME and NICKNAMES are
upper-cased strings (case-insensitive comparison surface). EXPORTS
is a list of symbol-name strings. IMPORTS is a list of (FROM-PKG
SYMBOL-NAME ...) cells. USES is a list of package designators in
:USE clauses."))

(defclass integration-issue ()
  ((kind :initarg :kind :reader integration-issue-kind)
   (file :initarg :file :initform nil :reader integration-issue-file)
   (package :initarg :package :initform nil :reader integration-issue-package)
   (description :initarg :description :reader integration-issue-description))
  (:documentation
   "One static inconsistency surfaced by FIND-INTEGRATION-ISSUES.
KIND is :UNKNOWN-PACKAGE or :UNEXPORTED-SYMBOL. FILE is the source
file the issue was discovered in. PACKAGE is the importing
package's name. DESCRIPTION is a one-line human summary."))

(defun %sd-string (designator)
  "Normalise a defpackage string designator (string, symbol, keyword)
to its uppercase string-name."
  (cond
    ((stringp designator) (string-upcase designator))
    ((symbolp designator) (string-upcase (symbol-name designator)))
    (t (format nil "~A" designator))))

(defun %defpackage-form-p (form)
  (and (consp form)
       (symbolp (car form))
       (or (eq (car form) 'defpackage)
           (string-equal (symbol-name (car form)) "DEFPACKAGE")
           (string-equal (symbol-name (car form)) "DEFINE-PACKAGE"))))

(defun %parse-defpackage-form (form file)
  (when (%defpackage-form-p form)
    (let ((name (%sd-string (second form)))
          (options (cddr form))
          (nicknames nil)
          (exports nil)
          (imports nil)
          (uses nil))
      (dolist (option options)
        (when (consp option)
          (let ((tag (car option)))
            (cond
              ((or (eq tag :nicknames)
                   (and (symbolp tag)
                        (string-equal (symbol-name tag) "NICKNAMES")))
               (setf nicknames
                     (append nicknames (mapcar #'%sd-string (cdr option)))))
              ((or (eq tag :export)
                   (and (symbolp tag)
                        (string-equal (symbol-name tag) "EXPORT")))
               (setf exports
                     (append exports (mapcar #'%sd-string (cdr option)))))
              ((or (eq tag :import-from)
                   (and (symbolp tag)
                        (string-equal (symbol-name tag) "IMPORT-FROM")))
               (let ((from (%sd-string (second option)))
                     (syms (mapcar #'%sd-string (cddr option))))
                 (push (cons from syms) imports)))
              ((or (eq tag :use)
                   (and (symbolp tag)
                        (string-equal (symbol-name tag) "USE")))
               (setf uses
                     (append uses (mapcar #'%sd-string (cdr option)))))))))
      (make-instance 'package-info
                     :name name
                     :nicknames nicknames
                     :exports exports
                     :imports (nreverse imports)
                     :uses uses
                     :file file))))

(defun %read-all-forms-from-file (path)
  "Read all top-level forms from PATH; returns a list. Errors yield NIL.
*READ-EVAL* is bound to NIL so #. injection cannot trigger any
side-effect during defpackage gathering."
  (handler-case
      (with-open-file (in path :direction :input)
        (let ((*read-eval* nil)
              (*package* (find-package :cl-harness/src/integration)))
          (loop for form = (handler-case (read in nil :eof)
                             (error () :eof))
                until (eq form :eof)
                collect form)))
    (error () nil)))

(defun %lisp-files-in-tree (root)
  (when (uiop:directory-exists-p root)
    (sort
     (copy-list
      (directory
       (merge-pathnames "**/*.lisp"
                        (uiop:ensure-directory-pathname root))))
     #'string< :key #'namestring)))

(defun gather-package-graph (project-root)
  "Walk every *.lisp file under PROJECT-ROOT (recursively) and return
a list of PACKAGE-INFO, one per defpackage form encountered. Files
that don't parse cleanly are skipped silently — the goal here is a
best-effort static snapshot, not a strict compile."
  (check-type project-root (or string pathname))
  (let ((graph nil))
    (dolist (file (%lisp-files-in-tree project-root))
      (dolist (form (%read-all-forms-from-file file))
        (let ((info (%parse-defpackage-form form file)))
          (when info (push info graph)))))
    (nreverse graph)))

(defun %find-package-by-name (graph name)
  (find-if (lambda (info)
             (or (string-equal (package-info-name info) name)
                 (find name (package-info-nicknames info)
                       :test #'string-equal)))
           graph))

(defun %any-in-project-prefix-shared-p (graph name)
  "Return T when NAME starts with `<prefix>/' for some package in
GRAPH whose name shares the same first segment. Heuristic to
avoid flagging out-of-project imports (alexandria, rove, ...)."
  (let ((slash (position #\/ name)))
    (when slash
      (let ((root (subseq name 0 slash)))
        (some (lambda (info)
                (or (string-equal (package-info-name info) root)
                    (let ((info-slash (position #\/ (package-info-name info))))
                      (and info-slash
                           (string-equal
                            (subseq (package-info-name info) 0 info-slash)
                            root)))))
              graph)))))

(defun find-integration-issues (graph)
  "Walk GRAPH and return a list of INTEGRATION-ISSUEs. v0.4 detects:
  - :UNKNOWN-PACKAGE — :IMPORT-FROM names a package that shares an
    in-project prefix but is not defined anywhere in GRAPH (ignores
    out-of-project deps like alexandria).
  - :UNEXPORTED-SYMBOL — :IMPORT-FROM imports a symbol the source
    package's defpackage does not list under :EXPORT."
  (let ((issues nil))
    (dolist (pkg graph)
      (dolist (import-pair (package-info-imports pkg))
        (let* ((from-name (car import-pair))
               (syms (cdr import-pair))
               (from-pkg (%find-package-by-name graph from-name)))
          (cond
            ((null from-pkg)
             (when (%any-in-project-prefix-shared-p graph from-name)
               (push (make-instance
                      'integration-issue
                      :kind :unknown-package
                      :file (package-info-file pkg)
                      :package (package-info-name pkg)
                      :description
                      (format nil
                              "package ~A imports from ~A which is not defined in the project"
                              (package-info-name pkg) from-name))
                     issues)))
            (t
             (dolist (sym syms)
               (unless (find sym (package-info-exports from-pkg)
                             :test #'string-equal)
                 (push (make-instance
                        'integration-issue
                        :kind :unexported-symbol
                        :file (package-info-file pkg)
                        :package (package-info-name pkg)
                        :description
                        (format nil
                                "package ~A imports ~A from ~A but ~A does not export ~A"
                                (package-info-name pkg)
                                sym from-name from-name sym))
                       issues))))))))
    (nreverse issues)))

(defun format-integration-issues-markdown (issues &key (header-level 2))
  "Render ISSUES as a markdown section. With no issues, emit a
single \"all consistent\" line so the section still appears in the
report (a clean integration check is itself a useful signal)."
  (with-output-to-string (s)
    (let ((header (make-string header-level :initial-element #\#)))
      (cond
        ((null issues)
         (format s "~%~A Integration check~%- All package exports / imports consistent.~%"
                 header))
        (t
         (format s "~%~A Integration issues (~D)~%" header (length issues))
         (dolist (issue issues)
           (format s "- [~A] ~A~A~%"
                   (string-downcase
                    (symbol-name (integration-issue-kind issue)))
                   (integration-issue-description issue)
                   (let ((file (integration-issue-file issue)))
                     (if file
                         (format nil " (~A)"
                                 (file-namestring file))
                         "")))))))))
