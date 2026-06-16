;;;; next/tests/action-test.lisp
;;;;
;;;; Tests for next/src/action.lisp (adapt-copy of legacy
;;;; src/action.lisp): tool_call (nested + flat arguments), finish,
;;;; finding, fence stripping, parse errors. The legacy
;;;; test-change-request variant is dropped (develop-loop detail).

(defpackage #:cl-harness-next/tests/action-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:repair-edit-action
                #:obtain-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-thought
                #:agent-action-hypothesis
                #:agent-action-decision
                #:action-parse-error))

(in-package #:cl-harness-next/tests/action-test)

(defun %parsed (json)
  "Parse JSON through OBTAIN-ACTION so the argument-repair pass — which
lives in OBTAIN-ACTION, the way every policy obtains an action — is
applied. Returns the (repaired) AGENT-ACTION."
  (nth-value 0 (obtain-action (constantly json) "view")))

(deftest tool-call-with-nested-arguments
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"tool_call\",\"tool\":\"run-tests\","
                              "\"arguments\":{\"system\":\"s\"},"
                              "\"thought\":\"verify\"}"))))
    (ok (eq :tool-call (agent-action-type action)))
    (ok (equal "run-tests" (agent-action-tool action)))
    (ok (equal "s" (gethash "system" (agent-action-arguments action))))
    (ok (equal "verify" (agent-action-thought action)))))

(deftest flat-arguments-are-promoted
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"tool_call\",\"tool\":\"repl-eval\","
                              "\"code\":\"(+ 1 2)\"}"))))
    (ok (equal "(+ 1 2)" (gethash "code" (agent-action-arguments action))))
    ;; Envelope keys never leak into arguments.
    (ok (null (gethash "type" (agent-action-arguments action))))))

(deftest code-fences-are-stripped
  (let ((action (parse-action
                 (format nil "```json~%{\"type\":\"finish\",~
\"status\":\"fixed\",\"summary\":\"done\"}~%```"))))
    (ok (eq :finish (agent-action-type action)))
    (ok (eq :fixed (agent-action-status action)))
    (ok (equal "done" (agent-action-summary action)))))

(deftest finish-statuses
  (ok (eq :give-up
          (agent-action-status
           (parse-action "{\"type\":\"finish\",\"status\":\"give_up\"}"))))
  (ok (handler-case
          (progn (parse-action "{\"type\":\"finish\",\"status\":\"meh\"}")
                 nil)
        (action-parse-error () t))))

(deftest finding-roundtrip
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"finding\",\"hypothesis\":\"h\","
                              "\"probe\":\"p\",\"finding\":\"f\","
                              "\"decision\":\"d\"}"))))
    (ok (eq :finding (agent-action-type action)))
    (ok (equal "h" (agent-action-hypothesis action)))
    (ok (equal "d" (agent-action-decision action)))))

(deftest finding-requires-all-four-fields
  (ok (handler-case
          (progn (parse-action
                  "{\"type\":\"finding\",\"hypothesis\":\"h\"}")
                 nil)
        (action-parse-error () t))))

(deftest invalid-inputs-signal-parse-errors
  (dolist (bad '("not json" "[1,2]" "{\"type\":\"warp\"}"
                 "{\"type\":\"test_change_request\",\"test_source\":\"x\"}"))
    (ok (handler-case (progn (parse-action bad) nil)
          (action-parse-error () t))
        (format nil "~S should not parse" bad))))

(deftest unknown-type-with-tool-is-treated-as-tool-call
  ;; Small models sometimes put the tool name in "type" instead of the
  ;; literal "tool_call". Be lenient when a non-empty "tool" is present.
  (let ((action (parse-action
                 (concatenate 'string
                              "{\"type\":\"lisp-edit-form\",\"tool\":\"lisp-edit-form\","
                              "\"arguments\":{\"file_path\":\"a.lisp\"}}"))))
    (ok (eq :tool-call (agent-action-type action)))
    (ok (equal "lisp-edit-form" (agent-action-tool action)))
    (ok (equal "a.lisp" (gethash "file_path" (agent-action-arguments action))))))

(deftest obtain-action-retries-until-parseable
  ;; FN returns an unparseable reply first, a valid tool_call second.
  ;; OBTAIN-ACTION re-samples and returns the parsed action.
  (let* ((calls 0)
         (fn (lambda (prompt)
               (declare (ignore prompt))
               (incf calls)
               (if (= calls 1)
                   "not json at all"
                   "{\"type\":\"tool_call\",\"tool\":\"run-tests\",\"arguments\":{}}"))))
    (multiple-value-bind (action err) (obtain-action fn "view" :max-tries 3)
      (ok (null err))
      (ok (eq :tool-call (agent-action-type action)))
      (ok (= 2 calls)))))

(deftest obtain-action-gives-up-after-max-tries
  ;; All replies unparseable → (values nil error-message) after MAX-TRIES.
  (let* ((calls 0)
         (fn (lambda (prompt)
               (declare (ignore prompt))
               (incf calls)
               "garbage")))
    (multiple-value-bind (action err) (obtain-action fn "view" :max-tries 2)
      (ok (null action))
      (ok (stringp err))
      (ok (= 2 calls)))))

(deftest obtain-action-feeds-error-back-and-keeps-view
  ;; On retry the prompt still carries the original view and a corrective note.
  (let* ((prompts '())
         (calls 0)
         (fn (lambda (prompt)
               (push prompt prompts)
               (incf calls)
               (if (= calls 1)
                   "garbage"
                   "{\"type\":\"tool_call\",\"tool\":\"x\",\"arguments\":{}}"))))
    (obtain-action fn "MY-UNIQUE-VIEW" :max-tries 3)
    (let ((retry-prompt (first prompts)))  ; most recent push = 2nd call's prompt
      (ok (search "MY-UNIQUE-VIEW" retry-prompt))
      (ok (search "valid" retry-prompt)))))

(deftest repair-coerces-invalid-operation-to-replace
  ;; A weak model emits operation:"overwrite" (or edit/delete-and-replace/…);
  ;; the repair coerces any non-{replace,insert_before,insert_after} to replace.
  (let ((args (agent-action-arguments
               (%parsed
                (concatenate 'string
                 "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                 "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defun\","
                 "\"form_name\":\"f\",\"operation\":\"overwrite\","
                 "\"content\":\"(defun f () 1)\"}}")))))
    (ok (equal "replace" (gethash "operation" args)))))

(deftest repair-coerces-form-type-function-to-defun
  (let ((args (agent-action-arguments
               (%parsed
                (concatenate 'string
                 "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                 "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"function\","
                 "\"form_name\":\"f\",\"operation\":\"replace\","
                 "\"content\":\"(defun f () 1)\"}}")))))
    (ok (equal "defun" (gethash "form_type" args)))))

(deftest repair-strips-form-name-prefix-and-package-qualifier
  ;; form_name "defmethod bark" (a leaked form_type token) -> "bark";
  ;; "pkg::user" (a package qualifier) -> "user".
  (let ((pre (agent-action-arguments
              (%parsed
               (concatenate 'string
                "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defmethod\","
                "\"form_name\":\"defmethod bark\",\"operation\":\"replace\","
                "\"content\":\"c\"}}"))))
        (qual (agent-action-arguments
               (%parsed
                (concatenate 'string
                 "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                 "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defclass\","
                 "\"form_name\":\"pkg::user\",\"operation\":\"replace\","
                 "\"content\":\"c\"}}")))))
    (ok (equal "bark" (gethash "form_name" pre)))
    (ok (equal "user" (gethash "form_name" qual)))))

(deftest repair-routes-patch-full-form-new-text-to-edit-replace
  ;; A lisp-patch-form whose new_text is a complete definition form is routed
  ;; to a lisp-edit-form replace, dropping the brittle whitespace-sensitive
  ;; old_text (the dominant guided failure: correct fix, unmatchable old_text).
  (let ((action (%parsed
                 (concatenate 'string
                  "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\","
                  "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defun\","
                  "\"form_name\":\"gret\",\"old_text\":\"(defun gret (n)\","
                  "\"new_text\":\"(defun greet (n) (format nil \\\"Hi\\\"))\"}}"))))
    (ok (equal "lisp-edit-form" (agent-action-tool action)))
    (let ((args (agent-action-arguments action)))
      (ok (equal "replace" (gethash "operation" args)))
      (ok (search "greet" (gethash "content" args)))
      (ok (null (gethash "old_text" args)))
      (ok (null (gethash "new_text" args))))))

(deftest repair-leaves-snippet-patch-as-patch
  ;; new_text is a snippet, not a whole form -> stays a lisp-patch-form (old_text
  ;; matching is still the right tool for a sub-form edit).
  (let ((action (%parsed
                 (concatenate 'string
                  "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\","
                  "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defun\","
                  "\"form_name\":\"f\",\"old_text\":\"(- a b)\","
                  "\"new_text\":\"(+ a b)\"}}"))))
    (ok (equal "lisp-patch-form" (agent-action-tool action)))
    (ok (equal "(+ a b)" (gethash "new_text" (agent-action-arguments action))))))

(deftest repair-is-a-no-op-on-wellformed-and-non-edit-actions
  ;; A valid edit operation is preserved; a non-editing tool (run-tests) is left
  ;; entirely alone even if it carries a stray edit-shaped key.
  (let ((edit (agent-action-arguments
               (%parsed
                (concatenate 'string
                 "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                 "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defun\","
                 "\"form_name\":\"f\",\"operation\":\"insert_after\","
                 "\"content\":\"c\"}}"))))
        (run (agent-action-arguments
              (%parsed
               (concatenate 'string
                "{\"type\":\"tool_call\",\"tool\":\"run-tests\","
                "\"arguments\":{\"system\":\"s\",\"form_type\":\"function\"}}")))))
    (ok (equal "insert_after" (gethash "operation" edit)))
    (ok (equal "function" (gethash "form_type" run)))))

(deftest repair-leaves-complex-form-names-intact
  ;; The package-qualifier strip applies ONLY to a bare symbol token: a
  ;; (setf …) accessor and a specialized defmethod head — both of which carry
  ;; parens/spaces — must NOT be mangled by the "::" de-qualification.
  (let ((setf-name
          (gethash "form_name"
                   (agent-action-arguments
                    (%parsed
                     (concatenate 'string
                      "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                      "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defun\","
                      "\"form_name\":\"(setf pkg::field)\",\"operation\":\"replace\","
                      "\"content\":\"c\"}}")))))
        (method-name
          (gethash "form_name"
                   (agent-action-arguments
                    (%parsed
                     (concatenate 'string
                      "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                      "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defmethod\","
                      "\"form_name\":\"area ((s pkg::square))\",\"operation\":\"replace\","
                      "\"content\":\"c\"}}"))))))
    (ok (equal "(setf pkg::field)" setf-name))
    (ok (equal "area ((s pkg::square))" method-name))))

(deftest repair-keeps-insert-shaped-operations
  ;; An insert-shaped (but invalid) operation keeps its positional intent — it
  ;; is NOT silently forced to replace (better to fail/feed back than to turn
  ;; an insert into a replace).
  (let ((args (agent-action-arguments
               (%parsed
                (concatenate 'string
                 "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
                 "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"defun\","
                 "\"form_name\":\"f\",\"operation\":\"insert\","
                 "\"content\":\"c\"}}")))))
    (ok (equal "insert" (gethash "operation" args)))))

(deftest repair-does-not-mutate-the-original-action
  ;; repair-edit-action is non-destructive: the parsed action it is handed (and
  ;; the arguments table it shares with the action's :raw slot) is left
  ;; untouched; the repair is built over a copy.
  (let* ((original (parse-action
                    (concatenate 'string
                     "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\","
                     "\"arguments\":{\"file_path\":\"x\",\"form_type\":\"function\","
                     "\"form_name\":\"f\",\"old_text\":\"o\","
                     "\"new_text\":\"(defun f () 1)\"}}")))
         (orig-args (agent-action-arguments original))
         (repaired (repair-edit-action original)))
    ;; original: still a patch-form with its function/old_text intact
    (ok (equal "lisp-patch-form" (agent-action-tool original)))
    (ok (equal "function" (gethash "form_type" orig-args)))
    (ok (equal "o" (gethash "old_text" orig-args)))
    ;; repaired (a distinct object): routed to an edit-form replace
    (ok (equal "lisp-edit-form" (agent-action-tool repaired)))
    (ok (equal "defun" (gethash "form_type" (agent-action-arguments repaired))))
    (ok (null (gethash "old_text" (agent-action-arguments repaired))))))
