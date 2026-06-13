;;;; next/src/template-policy.lisp
;;;;
;;;; The lowest dial rung (spec docs/superpowers/specs/2026-06-13-template-fix-policy-design.md):
;;;; the harness FSM owns all agency; the LLM is reduced to a stateless
;;;; code-generation oracle that emits only a method body for a fully
;;;; specified hole. This file is built increment by increment; it
;;;; starts with the reader-based body extractor.

(defpackage #:cl-harness-next/src/template-policy
  (:use #:cl)
  (:import-from #:cl-harness-next/src/action
                #:strip-code-fence)
  (:export #:extract-method-body))

(in-package #:cl-harness-next/src/template-policy)

;;; --- Reader-based body extraction -----------------------------------------
;;; The policy runs in the worker, so we parse the LLM reply with the real
;;; Lisp reader (*read-eval* nil): it handles strings, comments, char
;;; literals, and nesting that a hand-written char scanner would botch.

(defparameter +whitespace+ '(#\Space #\Tab #\Newline #\Return #\Page))

(defun %strip (raw)
  "Trim whitespace and one markdown fence off RAW."
  (string-trim +whitespace+ (strip-code-fence raw)))

(defun %definition-form-p (form)
  "True when FORM is a top-level definition (defmethod/defun/...)."
  (and (consp form)
       (symbolp (first form))
       (member (symbol-name (first form))
               '("DEFMETHOD" "DEFUN" "DEFGENERIC" "DEFCLASS" "DEFMACRO")
               :test #'string=)))

(defun %read-body-forms (text package)
  "Read every top-level form from TEXT under *read-eval* nil in PACKAGE.
Returns (values forms end-position error-string); ERROR-STRING non-NIL
means TEXT was unbalanced/unreadable."
  (let ((*package* package)
        (*read-eval* nil)
        (forms '())
        (end 0))
    (handler-case
        (with-input-from-string (stream text)
          (loop
            (let ((form (read stream nil stream)))
              (when (eq form stream) (return))
              (push form forms)
              (setf end (file-position stream)))))
      (error (condition)
        (return-from %read-body-forms
          (values (nreverse forms) end (princ-to-string condition)))))
    (values (nreverse forms) end nil)))

(defun %extract-definition-body (form)
  "Body forms of a whole (defmethod ...)/(defun ...) FORM; header discarded."
  (let ((rest (cddr form)))
    ;; skip method qualifiers (non-list atoms) before the lambda-list
    (loop while (and rest (not (listp (first rest)))) do (pop rest))
    ;; drop the lambda-list; the rest is the body
    (rest rest)))

(defun %degenerate-body-p (forms)
  "True when FORMS is a stub-equivalent body (constant / declare-only)."
  (or (null forms)
      (and (= 1 (length forms))
           (let ((f (first forms)))
             (or (null f) (eq f t) (eql f 0))))
      (every (lambda (f)
               (and (consp f) (symbolp (first f))
                    (string= (symbol-name (first f)) "DECLARE")))
             forms)))

(defun extract-method-body (raw &key head (form-type "defmethod")
                                     (package (find-package :cl-user)))
  "Extract a method BODY from RAW (the LLM reply) and re-wrap it under the
FSM-owned HEAD (e.g. \"observe ((h histogram) key)\") and FORM-TYPE,
using the Lisp reader for all lexical parsing. A whole-definition reply
has its model-supplied header discarded (never trust its specializers).
Returns the full form string, or (values NIL reason-keyword feedback)."
  (let ((text (%strip raw)))
    (when (zerop (length text))
      (return-from extract-method-body
        (values nil :empty "your reply was empty; emit the method body")))
    (let ((start (position #\( text)))
      (unless start
        (return-from extract-method-body
          (values nil :degenerate "emit a parenthesized body s-expression")))
      (let ((sub (subseq text start)))
        (multiple-value-bind (forms end err) (%read-body-forms sub package)
          (when err
            (return-from extract-method-body
              (values nil :malformed (format nil "unbalanced/unreadable reply: ~A" err))))
          (when (null forms)
            (return-from extract-method-body
              (values nil :degenerate "emit a method body")))
          (let (body-forms body-text)
            (cond
              ((and (= 1 (length forms)) (%definition-form-p (first forms)))
               (setf body-forms (%extract-definition-body (first forms)))
               (when (null body-forms)
                 (return-from extract-method-body
                   (values nil :degenerate "the method body is empty")))
               (let ((*package* package)
                     (*print-case* :downcase)
                     (*print-right-margin* nil))
                 (setf body-text (format nil "~{~S~^~%  ~}" body-forms))))
              (t
               (setf body-forms forms)
               (setf body-text (string-right-trim +whitespace+
                                                  (subseq sub 0 end)))))
            (when (some #'%definition-form-p body-forms)
              (return-from extract-method-body
                (values nil :nested-definition
                        "reply must be ONLY the method body, not a definition")))
            (when (%degenerate-body-p body-forms)
              (return-from extract-method-body
                (values nil :degenerate
                        "the body must implement the method, not return a constant")))
            (let ((candidate (format nil "(~A ~A~%  ~A)" form-type head body-text)))
              (multiple-value-bind (forms2 e2 err2) (%read-body-forms candidate package)
                (declare (ignore e2))
                (when (or err2
                          (/= 1 (length forms2))
                          (not (%definition-form-p (first forms2))))
                  (return-from extract-method-body
                    (values nil :malformed "assembled form did not re-read cleanly")))
                (values candidate nil nil)))))))))
