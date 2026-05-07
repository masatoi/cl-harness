;;;; src/runtime-vocabulary.lisp
;;;;
;;;; Phase G of the context-management refactor
;;;; (docs/context-management.md §3.4). One runtime-vocab-fact records
;;;; that the agent (or the orchestrator) probed a particular runtime
;;;; vocabulary item — a function, class, package, ASDF system, etc. —
;;;; at a particular point in time. Captures :PROBED-AT so later
;;;; verification can detect that the underlying source has shifted
;;;; since the probe (Phase F's render-time staleness pattern,
;;;; extended to runtime introspection).
;;;;
;;;; Phase G only RECORDS runtime-vocab-facts. Phase H may consume
;;;; them as the source of truth for "what packages exist"; Phase I
;;;; may aggregate them into project-summary text.

(defpackage #:cl-harness/src/runtime-vocabulary
  (:use #:cl)
  (:export #:runtime-vocab-fact
           #:make-runtime-vocab-fact
           #:runtime-vocab-fact-kind
           #:runtime-vocab-fact-name
           #:runtime-vocab-fact-package
           #:runtime-vocab-fact-source-file
           #:runtime-vocab-fact-summary
           #:runtime-vocab-fact-via-tool
           #:runtime-vocab-fact-probed-at
           #:runtime-vocab-fact-related-step-index
           #:runtime-vocab-fact-stale-p
           #:+supported-runtime-vocab-kinds+))

(in-package #:cl-harness/src/runtime-vocabulary)

(defparameter +supported-runtime-vocab-kinds+
  '(:package :symbol :function :generic-function :method
    :class :macro :condition :asdf-system)
  "Kinds of runtime vocabulary items a fact can describe. Mirrors the
list in docs/context-management.md §3.4. :SYMBOL is the catch-all
for plain bound symbols (parameters, constants, etc.) that aren't
function-shaped. :ASDF-SYSTEM covers both primary and test systems.")

(defclass runtime-vocab-fact ()
  ((kind :initarg :kind :reader runtime-vocab-fact-kind
         :documentation "One of +SUPPORTED-RUNTIME-VOCAB-KINDS+.")
   (name :initarg :name :reader runtime-vocab-fact-name
         :documentation "The vocabulary item's name as a string. For
:METHOD this is typically the generic-function name plus
specializers, e.g. \"print-object ((x my-class) stream)\". Required,
non-empty.")
   (package :initarg :package :reader runtime-vocab-fact-package
            :initform nil
            :documentation "Package name string, when applicable. NIL
for :ASDF-SYSTEM and for items the probe didn't resolve a package
for.")
   (source-file :initarg :source-file
                :reader runtime-vocab-fact-source-file
                :initform nil
                :documentation "Pathname of the file the runtime
attributes the definition to (e.g. via SOURCE-LOCATION /
SB-INTROSPECT:FIND-DEFINITION-SOURCE), or NIL when the runtime
declined to report a source. Used by RUNTIME-VOCAB-FACT-STALE-P.")
   (summary :initarg :summary :reader runtime-vocab-fact-summary
            :initform nil
            :documentation "A short description string captured from
the probe — typically the first line of (describe ...) output, the
class precedence list, or the function's lambda-list signature.
Optional; the formatter is defensive against NIL.")
   (via-tool :initarg :via-tool :reader runtime-vocab-fact-via-tool
             :documentation "Name of the cl-mcp tool that produced the
probe data (e.g. \"code-find\", \"code-describe\",
\"code-find-references\", \"repl-eval\"). Required, non-empty.")
   (probed-at :initarg :probed-at :reader runtime-vocab-fact-probed-at
              :documentation "GET-UNIVERSAL-TIME at the moment of
record. Always populated by MAKE-RUNTIME-VOCAB-FACT.")
   (related-step-index :initarg :related-step-index
                       :reader runtime-vocab-fact-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the active
step, or NIL outside a develop run."))
  (:documentation
   "One observation that a particular runtime vocabulary item was
probed at a particular time, with the source file (when known)
captured for staleness checks."))

(defun make-runtime-vocab-fact (&key kind name via-tool
                                  package source-file summary
                                  related-step-index
                                  (probed-at (get-universal-time)))
  "Construct a RUNTIME-VOCAB-FACT. KIND must be a member of
+SUPPORTED-RUNTIME-VOCAB-KINDS+. NAME and VIA-TOOL must be non-empty
strings. SOURCE-FILE is coerced from string to pathname when supplied.
PACKAGE / SUMMARY default to NIL and are validated when supplied."
  (unless (member kind +supported-runtime-vocab-kinds+)
    (error "runtime-vocab-fact: unsupported :kind ~S; expected one of ~S"
           kind +supported-runtime-vocab-kinds+))
  (unless (and (stringp name) (plusp (length name)))
    (error "runtime-vocab-fact: :name must be a non-empty string, got ~S"
           name))
  (unless (and (stringp via-tool) (plusp (length via-tool)))
    (error "runtime-vocab-fact: :via-tool must be a non-empty string, got ~S"
           via-tool))
  (when package (check-type package string))
  (when summary (check-type summary string))
  (when related-step-index (check-type related-step-index integer))
  (let ((coerced-source-file
          (cond
            ((null source-file) nil)
            ((pathnamep source-file) source-file)
            ((stringp source-file) (pathname source-file))
            (t (error "runtime-vocab-fact: :source-file must be a ~
pathname, string, or NIL; got ~S" source-file)))))
    (make-instance 'runtime-vocab-fact
                   :kind kind
                   :name name
                   :package package
                   :source-file coerced-source-file
                   :summary summary
                   :via-tool via-tool
                   :probed-at probed-at
                   :related-step-index related-step-index)))

(defun runtime-vocab-fact-stale-p (fact)
  "Return T when FACT's recorded source-file has been modified since
the probe (i.e. (file-write-date source-file) > probed-at). Returns
NIL when the fact has no recorded source-file, when the file no
longer exists, or when the file's mtime equals or precedes
probed-at. Mirrors the SOURCE-FACT-STALE-P predicate (Phase E/F)."
  (let ((source-file (runtime-vocab-fact-source-file fact))
        (probed-at (runtime-vocab-fact-probed-at fact)))
    (and source-file probed-at
         (let ((current (handler-case (file-write-date source-file)
                          (error () nil))))
           (and current (> current probed-at))))))
