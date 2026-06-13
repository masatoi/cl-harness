;;;; next/src/authoring-policy.lisp
;;;;
;;;; The test-authoring dial (spec docs/superpowers/specs/2026-06-14-test-authoring-design.md):
;;;; a goal-driven FSM that writes failing tests, gates them (RED-first +
;;;; LLM review), then delegates to an inner fix dial to implement to green.

(defpackage #:cl-harness-next/src/authoring-policy
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
                #:verdict-pass-p
                #:verdict-reason)
  (:import-from #:cl-harness-next/src/template-policy
                #:discover-targets
                #:target-head)
  (:export #:extract-deftest-forms
           #:+test-author-system-prompt+
           #:authoring-policy
           #:policy-state
           #:policy-mode
           #:policy-goal
           #:policy-test-file
           #:policy-authored-names
           #:policy-fix-policy
           #:policy-reviewer))

(in-package #:cl-harness-next/src/authoring-policy)

(defparameter +ws+ '(#\Space #\Tab #\Newline #\Return #\Page))

(defun %read-forms (text)
  "Read all top-level forms from TEXT under *read-eval* nil in CL-USER.
Returns (values forms error-string)."
  (let ((*package* (find-package :cl-user))
        (*read-eval* nil)
        (forms '()))
    (handler-case
        (with-input-from-string (s text)
          (loop for form = (read s nil s)
                until (eq form s)
                do (push form forms)))
      (error (c)
        (return-from %read-forms
          (values (nreverse forms) (princ-to-string c)))))
    (values (nreverse forms) nil)))

(defun %deftest-form-p (form)
  "True when FORM is a proper (deftest NAME ...) list with a symbol name."
  (and (alexandria:proper-list-p form)
       (symbolp (first form))
       (string= (symbol-name (first form)) "DEFTEST")
       (symbolp (second form))))

(defun extract-deftest-forms (raw)
  "Validate RAW (an LLM reply) as one-or-more rove DEFTEST forms, parsed
with the Lisp reader (*read-eval* nil). Returns (values TEXT NAMES) on
success — TEXT the verbatim trimmed/de-fenced reply, NAMES the upcased
deftest-name strings — or (values NIL REASON) for the regenerate loop."
  (let ((text (string-trim +ws+ (strip-code-fence raw))))
    (when (zerop (length text))
      (return-from extract-deftest-forms
        (values nil "reply was empty; emit rove deftest form(s)")))
    (multiple-value-bind (forms err) (%read-forms text)
      (cond
        (err (values nil (format nil "unbalanced/unreadable reply: ~A" err)))
        ((null forms) (values nil "no forms; emit rove deftest form(s)"))
        ((not (every #'%deftest-form-p forms))
         (values nil "reply must be ONLY rove deftest form(s), nothing else"))
        (t (values text
                   (mapcar (lambda (f) (symbol-name (second f))) forms)))))))
