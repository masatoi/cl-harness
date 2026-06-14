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

(defparameter +authored-test-name+ "cl-harness-authored-tests"
  "The single deftest name the authoring dial manages via lisp-edit-form
replace, so re-authoring overwrites rather than accumulating and
fs-write-file (which cannot overwrite an existing .lisp) is avoided.")

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
deftest-name strings — or (values NIL REASON) for the regenerate loop.

Standalone reader-based validator. The authoring FSM's live author path
uses %NORMALIZE-AUTHORED (which validates AND re-wraps the bodies into the
single fixed-name deftest the write mechanism replaces); this function is
retained as a reusable deftest checker."
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

(defun %normalize-authored (raw)
  "Read RAW (the LLM reply) as one-or-more rove deftest forms, collect
their assertion bodies, and re-emit them as ONE deftest named
+AUTHORED-TEST-NAME+. Bodies are printed bare in CL-USER so their symbols
re-read in the test package (which :uses the SUT package). Returns
(values TEXT NIL) or (values NIL REASON) for the regenerate loop."
  (let ((text (string-trim +ws+ (strip-code-fence raw))))
    (when (zerop (length text))
      (return-from %normalize-authored
        (values nil "reply was empty; emit a rove deftest")))
    (multiple-value-bind (forms err) (%read-forms text)
      (cond
        (err (values nil (format nil "unreadable reply (use BARE symbol names, \
no package: prefixes): ~A" err)))
        ((null forms) (values nil "no forms; emit a rove deftest"))
        ((not (every #'%deftest-form-p forms))
         (values nil "reply must be ONLY rove deftest form(s)"))
        (t
         (let ((bodies (loop for f in forms append (cddr f))))
           (if (null bodies)
               (values nil "the deftest has no assertions")
               (let ((*package* (find-package :cl-user))
                     (*print-case* :downcase)
                     (*print-right-margin* nil)
                     (*print-pretty* t))
                 (values (format nil "(deftest ~A~%~{  ~S~^~%~})"
                                 +authored-test-name+ bodies)
                         nil)))))))))

(defparameter +test-author-system-prompt+
  "You are a Common Lisp test author. Given a GOAL and the code under
test, reply with ONLY one or more rove DEFTEST forms exercising the
goal — no defpackage, no in-package, no prose, no markdown, no code
fence. Shape: (deftest NAME (ok EXPR) (ok EXPR) ...). Reference the code
under test by the symbols shown. The tests MUST fail against the current
(unimplemented/stub) code and pass once the goal is met. Use BARE symbol
names exactly as shown (e.g. add) — never package-qualified (no colon
prefixes). The deftest name does not matter."
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
   (authored-names :initform nil :accessor policy-authored-names)
   (last-attempt-text :initform "" :accessor %last-attempt-text)
   (authored-written-p :initform nil :accessor policy-authored-written-p))
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

(defun %result-text (result)
  "Text payload of an MCP content-style RESULT, or NIL."
  (when (hash-table-p result)
    (let ((content (gethash "content" result)))
      (when (and content (plusp (length content)))
        (let ((entry (elt content 0)))
          (when (hash-table-p entry) (gethash "text" entry)))))))

(defun %skeleton (policy)
  "A fresh test file: defpackage (use cl + rove + the SUT package) + in-package.
Package names are emitted lower-case so the file reads like hand-written source."
  (let ((test-pkg (string-downcase (policy-test-package policy))))
    (format nil "(defpackage #:~A~%  (:use #:cl #:rove #:~A))~%~%(in-package #:~A)~%"
            test-pkg
            (string-downcase (policy-sut-package policy))
            test-pkg)))

(defun %act (tool args reason)
  "Build an :act decision for TOOL with ARGS (a plist) and a human REASON."
  (make-decision :kind :act :tool tool
                 :arguments (alexandria:plist-hash-table args :test #'equal)
                 :reason reason))

(defun %read-source (policy)
  "Emit the read of the SUT source file; next state parses its surface."
  (setf (policy-state policy) :parse-source)
  (%act "fs-read-file" (list "path" (policy-source-file policy))
        "read source for SUT surface"))

(defun %parse-source (policy kernel)
  "Derive the SUT package and surface from the source read, then emit the
read of the test file to decide whether a skeleton is needed."
  (let ((src (%result-text (kernel-last-result kernel))))
    (when (stringp src)
      (multiple-value-bind (targets class-text sut-package)
          (discover-targets src (policy-source-file policy))
        (when sut-package (setf (policy-sut-package policy) sut-package))
        (setf (policy-sut-surface policy)
              (format nil "~@[~A~2%~]~{~A~%~}"
                      (when (plusp (length class-text)) class-text)
                      (mapcar #'target-head targets))))))
  (setf (policy-state policy) :ensure-skeleton)
  (%act "fs-read-file" (list "path" (policy-test-file policy))
        "read test file"))

(defun %ensure-skeleton (policy kernel)
  (let ((existing (or (%result-text (kernel-last-result kernel)) "")))
    (if (search "(in-package" existing)
        (progn
          ;; A prior run may have left the fixed-name deftest; replace it on the
          ;; first write rather than inserting a duplicate.
          (when (search +authored-test-name+ existing)
            (setf (policy-authored-written-p policy) t))
          (%author policy))
        (progn
          (setf (policy-state policy) :author-skeleton-written)
          (%act "fs-write-file"
                (list "path" (policy-test-file policy)
                      "content" (%skeleton policy))
                "write test-file defpackage skeleton")))))

(defun %skeleton-written (policy kernel)
  "After the skeleton fs-write-file: a tool error means the test file
exists but has no (in-package …) form (cl-mcp refuses to overwrite an
existing .lisp, and there is no anchor to insert after). Give up with a
clear reason rather than looping on failed authored edits."
  (if (kernel-last-action-error kernel)
      (make-decision
       :kind :give-up
       :reason (format nil "could not create the test-file skeleton (~A); the \
test file must be absent or already contain a defpackage + (in-package …)"
                       (kernel-last-action-error kernel)))
      (%author policy)))

(defun %regenerate (policy reason)
  "Record feedback and re-author within K, else give up."
  (incf (policy-attempts policy))
  (setf (policy-feedback policy) reason)
  (if (< (policy-attempts policy) (policy-k policy))
      (%author policy)
      (make-decision :kind :give-up
                     :reason (format nil "could not author acceptable tests: ~A"
                                     reason))))

(defun %author (policy)
  "Sample deftest form(s), normalize to the fixed-name deftest, and emit
the test-file edit (insert on the first write, replace thereafter)."
  (let ((raw (handler-case (funcall (policy-author-fn policy)
                                    (%author-prompt policy))
               (error (c) (setf (policy-feedback policy)
                                (format nil "author call error: ~A" c))
                 nil))))
    (if (null raw)
        (%regenerate policy (policy-feedback policy))
        (multiple-value-bind (text reason) (%normalize-authored raw)
          (if (null text)
              (%regenerate policy reason)
              (progn
                (setf (policy-authored-names policy)
                        (list (string-upcase +authored-test-name+))
                      (%last-attempt-text policy) text
                      (policy-state policy) :author-written)
                (%edit-authored policy text)))))))

(defun %edit-authored (policy text)
  "Emit the lisp-edit-form for the authored deftest: insert it after the
in-package form on the first write, replace it by name thereafter."
  (if (policy-authored-written-p policy)
      (%act "lisp-edit-form"
            (list "file_path" (policy-test-file policy)
                  "form_type" "deftest"
                  "form_name" +authored-test-name+
                  "operation" "replace"
                  "content" text)
            "replace authored tests")
      (%act "lisp-edit-form"
            (list "file_path" (policy-test-file policy)
                  "form_type" "in-package"
                  "form_name" (policy-test-package policy)
                  "operation" "insert_after"
                  "content" text)
            "insert authored tests")))

(defun %author-written (policy kernel)
  (if (kernel-last-action-error kernel)
      (%regenerate policy (format nil "writing tests failed: ~A"
                                  (kernel-last-action-error kernel)))
      (progn
        (setf (policy-authored-written-p policy) t
              (policy-state policy) :author-loaded)
        (%act "load-system"
              (append (list "system" (policy-test-system policy))
                      (when (%clear-fasls-p policy) (list "clear_fasls" t)))
              "load the authored test system"))))

(defun %author-loaded (policy kernel)
  "After loading the authored tests: on a load error regenerate; else run
them to confirm they fail (RED-first) against the unfixed code."
  (if (kernel-last-action-error kernel)
      (%regenerate policy (format nil "authored tests did not load: ~A"
                                  (kernel-last-action-error kernel)))
      (progn
        (setf (policy-state policy) :author-verify)
        (%act "run-tests" (list "system" (policy-test-system policy))
              "RED-first: authored tests must fail"))))

(defun %mentions (needle text)
  "True when TEXT is a string containing NEEDLE (case-insensitive)."
  (and (stringp text) (search needle text :test #'char-equal) t))

(defun %name-in-failures-p (name failed)
  "True when an authored test NAME appears in the FAILED entries' test_name."
  (some (lambda (entry)
          (and (hash-table-p entry)
               (%mentions name (gethash "test_name" entry))))
        (coerce (or failed #()) 'list)))

(defun %authored-tests-red-p (policy result)
  "True only on positive evidence the authored tests fail: a clean load
gave a failed_tests array and EVERY authored name appears in it."
  (and (hash-table-p result)
       (not (gethash "isError" result))
       (let ((failed (gethash "failed_tests" result)))
         (and failed (plusp (length failed))
              (every (lambda (n) (%name-in-failures-p n failed))
                     (policy-authored-names policy))))))

(defun %review-subject (policy)
  "The review prompt: the goal, acceptance criteria, and the authored tests,
asking the reviewer to reject tautologies / dodges."
  (format nil "GOAL:~%~A~@[~2%ACCEPTANCE CRITERIA:~%~{- ~A~%~}~]~2%~
Do these rove tests faithfully and non-trivially encode the goal? \
Reject tautologies / empty tests / tests that dodge the goal.~2%~
AUTHORED TESTS:~%~A"
          (policy-goal policy) (policy-criteria policy)
          (%last-attempt-text policy)))

(defun %emit-review (policy)
  "Emit the :consult that asks the reviewer oracle to judge the tests."
  (setf (policy-state policy) :author-reviewed)
  (make-decision :kind :consult :oracle (policy-reviewer policy)
                 :subject (%review-subject policy)
                 :reason "review authored tests against the goal"))

(defun %author-verify (policy kernel)
  "After RED-first run-tests: if the authored tests fail against the unfixed
code, send them to review; otherwise they are vacuous — regenerate."
  (if (%authored-tests-red-p policy (kernel-last-result kernel))
      (%emit-review policy)
      (%regenerate policy
                   "your tests passed on the unfixed code (vacuous or already \
met); assert the goal so they fail until it is implemented")))

(defun %author-reviewed (policy kernel)
  "After the review verdict: on PASS advance to the inner fix dial (same
step, mirroring the adaptive dial); on a reject regenerate."
  (let ((verdict (kernel-last-verdict kernel)))
    (if (and verdict (verdict-pass-p verdict))
        (progn (setf (policy-state policy) :fix)
               (decide (policy-fix-policy policy) kernel))
        (%regenerate policy
                     (format nil "review rejected the tests: ~A"
                             (and verdict (verdict-reason verdict)))))))

(defmethod decide ((policy authoring-policy) kernel)
  "The test-authoring FSM (spec 2026-06-14): read source → ensure skeleton →
author → RED-first verify → review → delegate to the inner fix dial.
One decision per step; :fix hands off to FIX-POLICY's own DECIDE."
  (ecase (policy-state policy)
    (:init (%read-source policy))
    (:parse-source (%parse-source policy kernel))
    (:ensure-skeleton (%ensure-skeleton policy kernel))
    (:author-skeleton-written (%skeleton-written policy kernel))
    (:author (%author policy))
    (:author-written (%author-written policy kernel))
    (:author-loaded (%author-loaded policy kernel))
    (:author-verify (%author-verify policy kernel))
    (:author-reviewed (%author-reviewed policy kernel))
    (:fix (decide (policy-fix-policy policy) kernel))))
