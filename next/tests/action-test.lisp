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
