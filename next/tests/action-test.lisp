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
