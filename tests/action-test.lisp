;;;; tests/action-test.lisp
;;;;
;;;; Phase 2 unit tests for the LLM action JSON parser (PRD §8.4
;;;; REQ-AGENT-002). Validates the schema accepted by the agent loop:
;;;;   {"type":"tool_call","tool":"X","arguments":{...},"thought":"..."}
;;;;   {"type":"finish","status":"fixed"|"give_up","summary":"..."}
;;;; plus tolerant handling of LLM markdown code fences.

(defpackage #:cl-harness/tests/action-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/action
                #:agent-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-thought
                #:parse-action
                #:action-parse-error
                #:action-parse-error-message))

(in-package #:cl-harness/tests/action-test)

(deftest parse-action-tool-call
  (let ((a (parse-action
            "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\",\"arguments\":{\"file_path\":\"foo\"},\"thought\":\"trying X\"}")))
    (ok (typep a 'agent-action))
    (ok (eq :tool-call (agent-action-type a)))
    (ok (equal "lisp-patch-form" (agent-action-tool a)))
    (ok (equal "foo" (gethash "file_path" (agent-action-arguments a))))
    (ok (equal "trying X" (agent-action-thought a)))))

(deftest parse-action-tool-call-defaults-empty-arguments
  (let ((a (parse-action
            "{\"type\":\"tool_call\",\"tool\":\"run-tests\"}")))
    (ok (eq :tool-call (agent-action-type a)))
    (ok (hash-table-p (agent-action-arguments a)))
    (ok (zerop (hash-table-count (agent-action-arguments a))))))

(deftest parse-action-finish-fixed
  (let ((a (parse-action
            "{\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"green\"}")))
    (ok (eq :finish (agent-action-type a)))
    (ok (eq :fixed (agent-action-status a)))
    (ok (equal "green" (agent-action-summary a)))))

(deftest parse-action-finish-give-up
  (let ((a (parse-action
            "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"stuck\"}")))
    (ok (eq :finish (agent-action-type a)))
    (ok (eq :give-up (agent-action-status a)))
    (ok (equal "stuck" (agent-action-summary a)))))

(deftest parse-action-strips-json-code-fence
  (let ((a (parse-action
            (format nil "Sure, here you go:~%```json~%{\"type\":\"finish\",\"status\":\"fixed\"}~%```~%That's it."))))
    (ok (eq :finish (agent-action-type a)))
    (ok (eq :fixed (agent-action-status a)))))

(deftest parse-action-strips-bare-code-fence
  (let ((a (parse-action
            (format nil "```~%{\"type\":\"finish\",\"status\":\"fixed\"}~%```"))))
    (ok (eq :finish (agent-action-type a)))))

(deftest parse-action-rejects-non-json
  (ok (handler-case (progn (parse-action "not json at all") nil)
        (action-parse-error (c)
          (search "JSON" (action-parse-error-message c))))))

(deftest parse-action-rejects-non-object
  (ok (handler-case (progn (parse-action "[1,2,3]") nil)
        (action-parse-error () t))))

(deftest parse-action-rejects-unknown-type
  (ok (handler-case (progn (parse-action "{\"type\":\"banana\"}") nil)
        (action-parse-error (c)
          (search "banana" (action-parse-error-message c))))))

(deftest parse-action-rejects-tool-call-missing-tool
  (ok (handler-case (progn (parse-action
                            "{\"type\":\"tool_call\",\"arguments\":{}}") nil)
        (action-parse-error () t))))

(deftest parse-action-rejects-finish-bad-status
  (ok (handler-case (progn (parse-action
                            "{\"type\":\"finish\",\"status\":\"maybe\"}") nil)
        (action-parse-error () t))))
