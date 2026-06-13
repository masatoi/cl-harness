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
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:kernel-last-result
                #:kernel-last-action-error
                #:kernel-last-verdict)
  (:import-from #:cl-harness-next/src/oracle
                #:verdict-pass-p)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle)
  (:export #:extract-method-body
           #:template-fix-policy
           #:fix-target
           #:make-fix-target
           #:policy-state
           #:policy-system
           #:policy-test-system
           #:policy-parked
           #:+template-snippet-system-prompt+))

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

;;; --- The template-fix FSM -------------------------------------------------
;;; The harness owns 100% of agency; the LLM only fills a body. The kernel
;;; is one-decision-per-step (kernel.lisp), so each read/edit/verify is its
;;; own state; the LLM round-trip happens inside DECIDE at :gen (it is NOT a
;;; kernel :consult, which needs an oracle returning a verdict). DISCOVER is
;;; injected here (the :targets initarg); deriving targets from source is a
;;; later increment.

(defparameter +template-snippet-system-prompt+
  "You are a Common Lisp method-body oracle. You are given one method's
signature, its contract, and the class it operates on. Reply with ONLY
the body of the method as Common Lisp s-expressions — no defmethod
wrapper, no markdown, no prose, no explanation. Use ONLY the accessors
and slots shown."
  "System prompt for the snippet oracle; pair with MAKE-JUDGE-FN.")

(defstruct (fix-target (:conc-name target-))
  "One hole to fill: SYMBOL is the upcased operator name (string), FILE
the source path, FORM-TYPE \"defmethod\"/\"defun\", FORM-NAME the
lisp-edit-form matcher, HEAD the text re-wrapped around the body
(name + specialized lambda list), CONTRACT the defgeneric docstring,
ORIGINAL-BODY the stub text (revert payload)."
  symbol file (form-type "defmethod") form-name head contract original-body)

(defclass template-fix-policy (control-policy)
  ((snippet-fn :initarg :snippet-fn :reader policy-snippet-fn
               :documentation "Function (prompt-string → raw-LLM-string).")
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (sut-package :initarg :sut-package :initform "CL-USER"
                :reader policy-sut-package)
   (clear-fasls-p :initarg :clear-fasls :initform t :reader %clear-fasls-p)
   (k :initarg :k :initform 3 :reader policy-k
      :documentation "Per-form attempt cap (malformed re-samples and
clean-but-wrong retries).")
   (targets :initarg :targets :initform nil :reader policy-targets)
   (class-text :initarg :class-text :initform "" :reader policy-class-text)
   (state :initform :init :accessor policy-state)
   (queue :initform nil :accessor policy-queue)
   (current :initform nil :accessor policy-current)
   (attempts :initform 0 :accessor policy-attempts)
   (feedback :initform nil :accessor policy-feedback)
   (parked :initform nil :accessor policy-parked)
   (clean-oracle :accessor %clean-oracle))
  (:documentation "The lowest dial rung: the FSM owns all agency; the
LLM only fills a method body for the current injected target."))

(defun %build-prompt (policy)
  "The per-form user prompt: class + method head with a hole + contract +
any feedback from a failed attempt."
  (let ((tgt (policy-current policy)))
    (format nil
            "CLASS (use these slots/accessors only):~%~A~2%~
METHOD TO IMPLEMENT:~%(~A ~A <YOUR BODY HERE>)~2%~
CONTRACT: ~A~@[~2%PREVIOUS ATTEMPT FAILED: ~A~]~2%~
Reply with ONLY the body s-expression(s)."
            (policy-class-text policy)
            (target-form-type tgt)
            (target-head tgt)
            (or (target-contract tgt) "(none)")
            (policy-feedback policy))))

(defun %make-edit-decision (policy candidate)
  (let ((tgt (policy-current policy)))
    (setf (policy-state policy) :await-edit)
    (make-decision
     :kind :act :tool "lisp-edit-form"
     :arguments (alexandria:plist-hash-table
                 (list "file_path" (target-file tgt)
                       "form_type" (target-form-type tgt)
                       "form_name" (target-form-name tgt)
                       "operation" "replace"
                       "content" candidate)
                 :test #'equal)
     :reason (format nil "template-fix: ~A" (target-symbol tgt)))))

(defun %clean-consult (policy)
  (setf (policy-state policy) :final)
  (make-decision :kind :consult :oracle (%clean-oracle policy)
                 :reason "final clean verification"))

(defun %park-current (policy reason)
  (when (policy-current policy)
    (push (cons (target-symbol (policy-current policy)) reason)
          (policy-parked policy))))

(defun %advance (policy)
  "Move to the next target and return its first decision."
  (setf (policy-current policy) (pop (policy-queue policy))
        (policy-attempts policy) 0
        (policy-feedback policy) nil)
  (if (policy-current policy)
      (%gen policy)
      (%clean-consult policy)))

(defun %gen (policy)
  "Sample a valid body (≤ K in-decide re-samples, feeding errors back)
and emit the edit, or park the current form and advance."
  (dotimes (attempt (policy-k policy))
    (declare (ignorable attempt))
    (let ((raw (handler-case (funcall (policy-snippet-fn policy)
                                      (%build-prompt policy))
                 (error (condition)
                   (setf (policy-feedback policy)
                         (format nil "snippet call error: ~A" condition))
                   nil))))
      (when raw
        (multiple-value-bind (candidate reason feedback)
            (extract-method-body
             raw
             :head (target-head (policy-current policy))
             :form-type (target-form-type (policy-current policy))
             :package (find-package (policy-sut-package policy)))
          (declare (ignore reason))
          (if candidate
              (return-from %gen (%make-edit-decision policy candidate))
              (setf (policy-feedback policy) feedback))))))
  (%park-current policy "could not produce a valid body")
  (%advance policy))

(defun %await-edit (policy kernel)
  (if (kernel-last-action-error kernel)
      (progn
        (setf (policy-feedback policy)
              (format nil "the edit failed: ~A" (kernel-last-action-error kernel)))
        (incf (policy-attempts policy))
        (if (< (policy-attempts policy) (policy-k policy))
            (%gen policy)
            (progn (%park-current policy "edit kept failing")
                   (%advance policy))))
      (progn
        (setf (policy-state policy) :verify)
        (make-decision
         :kind :act :tool "load-system"
         :arguments (alexandria:plist-hash-table
                     (append (list "system" (policy-system policy))
                             (when (%clear-fasls-p policy) (list "clear_fasls" t)))
                     :test #'equal)
         :reason "reload patched source"))))

(defun %verify (policy)
  (setf (policy-state policy) :check)
  (make-decision
   :kind :act :tool "run-tests"
   :arguments (alexandria:plist-hash-table
               (list "system" (policy-test-system policy))
               :test #'equal)
   :reason "verify the patched form"))

(defun %mentions (sym-name text)
  (and (stringp text) (search sym-name text :test #'char-equal) t))

(defun %form-resolved-p (policy result)
  "True when the current target's symbol no longer appears in the raw
run-tests RESULT's failed_tests."
  (let ((failed (and (hash-table-p result) (gethash "failed_tests" result)))
        (sym (target-symbol (policy-current policy))))
    (notany (lambda (entry)
              (and (hash-table-p entry)
                   (or (%mentions sym (gethash "form" entry))
                       (%mentions sym (gethash "description" entry))
                       (%mentions sym (gethash "test_name" entry)))))
            (coerce (or failed #()) 'list))))

(defun %check (policy kernel)
  (if (%form-resolved-p policy (kernel-last-result kernel))
      (%advance policy)
      (progn
        (incf (policy-attempts policy))
        (setf (policy-feedback policy)
              "the tests still fail for this method; the body is wrong")
        (if (< (policy-attempts policy) (policy-k policy))
            (%gen policy)
            (progn (%park-current policy "wrong body after retries")
                   (%advance policy))))))

(defun %final (policy kernel)
  (let ((verdict (kernel-last-verdict kernel)))
    (if (and verdict (verdict-pass-p verdict))
        (make-decision :kind :finish :reason "clean verification green")
        (make-decision
         :kind :give-up
         :reason (format nil "template-fix exhausted; unresolved: ~{~A~^, ~}"
                         (or (mapcar #'car (policy-parked policy))
                             (list "suite still red")))))))

(defun %init (policy)
  (setf (policy-queue policy) (copy-list (policy-targets policy))
        (policy-current policy) (pop (policy-queue policy))
        (policy-attempts policy) 0
        (policy-feedback policy) nil))

(defmethod decide ((policy template-fix-policy) kernel)
  (ecase (policy-state policy)
    (:init (%init policy)
           (if (policy-current policy)
               (%gen policy)
               (%clean-consult policy)))
    (:await-edit (%await-edit policy kernel))
    (:verify (%verify policy))
    (:check (%check policy kernel))
    (:final (%final policy kernel))))

(defmethod initialize-instance :after ((policy template-fix-policy) &key)
  (setf (%clean-oracle policy)
        (make-instance 'verification-oracle
                       :system (policy-system policy)
                       :test-system (policy-test-system policy)
                       :mode :clean
                       :clear-fasls (%clear-fasls-p policy))))
