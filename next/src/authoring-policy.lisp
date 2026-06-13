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

(defparameter +test-author-system-prompt+
  "You are a Common Lisp test author. Given a GOAL and the code under
test, reply with ONLY one or more rove DEFTEST forms exercising the
goal — no defpackage, no in-package, no prose, no markdown, no code
fence. Shape: (deftest NAME (ok EXPR) (ok EXPR) ...). Reference the code
under test by the symbols shown. The tests MUST fail against the current
(unimplemented/stub) code and pass once the goal is met."
  "System prompt for the test-author oracle; pair with MAKE-JUDGE-FN.")

(defclass authoring-policy (control-policy)
  ((mode :initarg :mode :initform :tdd :reader policy-mode)
   (goal :initarg :goal :reader policy-goal)
   (criteria :initarg :criteria :initform nil :reader policy-criteria)
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (source-file :initarg :source-file :initform "src/main.lisp"
                :reader policy-source-file)
   (test-file :initarg :test-file :reader policy-test-file)
   (test-package :initarg :test-package :reader policy-test-package)
   (author-fn :initarg :author-fn :reader policy-author-fn)
   (reviewer :initarg :reviewer :reader policy-reviewer)
   (fix-policy :initarg :fix-policy :reader policy-fix-policy)
   (clear-fasls-p :initarg :clear-fasls :initform t :reader %clear-fasls-p)
   (k :initarg :k :initform 3 :reader policy-k)
   (state :initform :init :accessor policy-state)
   (attempts :initform 0 :accessor policy-attempts)
   (feedback :initform nil :accessor policy-feedback)
   (sut-package :initform "CL-USER" :accessor policy-sut-package)
   (sut-surface :initform "" :accessor policy-sut-surface)
   (base-content :initform nil :accessor policy-base-content)
   (authored-names :initform nil :accessor policy-authored-names)
   (last-attempt-text :initform "" :accessor %last-attempt-text))
  (:documentation "Test-authoring dial (spec 2026-06-14). MVP mode :tdd:
author failing tests, gate them (RED-first + review), then delegate the
fix to FIX-POLICY. The fix dial patches src/ only, so it cannot weaken
the gated tests."))

(defun %author-prompt (policy)
  "The per-attempt author prompt: goal + acceptance criteria + the SUT
surface (package, class, stub signatures), plus feedback from a rejected
attempt."
  (format nil
          "GOAL:~%~A~@[~2%ACCEPTANCE CRITERIA:~%~{- ~A~%~}~]~2%~
CODE UNDER TEST (package ~A):~%~A~@[~2%PREVIOUS ATTEMPT REJECTED:~%~A~]~2%~
Reply with ONLY rove deftest form(s)."
          (policy-goal policy)
          (policy-criteria policy)
          (policy-sut-package policy)
          (policy-sut-surface policy)
          (policy-feedback policy)))
