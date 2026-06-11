;;;; next/src/change-ledger.lisp
;;;;
;;;; Patch context (§3.8) and source context (§3.5): every patch
;;;; attempt (including failures), and which files/forms were read.
;;;; Source facts go stale when a later successful patch touches the
;;;; same file (§9, annotate-not-filter).

(defpackage #:cl-harness-next/src/change-ledger
  (:use #:cl)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-interaction
                #:interaction-tool
                #:interaction-succeeded-p
                #:interaction-observation-seq
                #:argument-string
                #:+patch-tool-names+)
  (:export #:change-ledger
           #:patches
           #:source-facts
           #:patch-entry-file
           #:patch-entry-form-type
           #:patch-entry-form-name
           #:patch-entry-operation
           #:patch-entry-ok-p
           #:patch-entry-seq
           #:source-fact-file
           #:source-fact-detail
           #:source-fact-seq
           #:source-fact-stale-p))

(in-package #:cl-harness-next/src/change-ledger)

(alexandria:define-constant +read-tool-names+
    '("lisp-read-file" "fs-read-file" "clgrep-search")
  :test #'equal
  :documentation "Tools whose successful use establishes a source fact.")

(defstruct (patch-entry (:conc-name patch-entry-))
  file form-type form-name operation ok-p seq)

(defstruct (source-fact (:conc-name source-fact-))
  file detail seq)

(defclass change-ledger (projection)
  ((patches :initform nil :accessor patches
            :documentation "PATCH-ENTRY structs, newest first. Failed
attempts are recorded too (ok-p NIL) — patch oscillation is a signal.")
   (source-facts :initform nil :accessor source-facts
                 :documentation "SOURCE-FACT structs, newest first."))
  (:documentation "Source (§3.5) + patch (§3.8) context."))

(defun %interaction-file (interaction)
  (or (argument-string interaction "file_path")
      (argument-string interaction "path")))

(defmethod apply-interaction ((ledger change-ledger) interaction)
  (let ((tool (interaction-tool interaction)))
    (cond
      ((member tool +patch-tool-names+ :test #'string=)
       (push (make-patch-entry
              :file (%interaction-file interaction)
              :form-type (argument-string interaction "form_type")
              :form-name (argument-string interaction "form_name")
              :operation (or (argument-string interaction "operation") tool)
              :ok-p (interaction-succeeded-p interaction)
              :seq (interaction-observation-seq interaction))
             (patches ledger)))
      ((and (interaction-succeeded-p interaction)
            (member tool +read-tool-names+ :test #'string=))
       (push (make-source-fact
              :file (%interaction-file interaction)
              :detail (or (argument-string interaction "name_pattern")
                          (argument-string interaction "pattern"))
              :seq (interaction-observation-seq interaction))
             (source-facts ledger)))))
  ledger)

(defun source-fact-stale-p (fact ledger)
  "True when a later successful patch touched FACT's file (§9).
Render-time predicate (annotate, don't filter)."
  (let ((file (source-fact-file fact)))
    (and file
         (some (lambda (patch)
                 (and (patch-entry-ok-p patch)
                      (equal file (patch-entry-file patch))
                      (> (patch-entry-seq patch) (source-fact-seq fact))))
               (patches ledger))
         t)))
