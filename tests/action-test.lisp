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
                #:agent-action-hypothesis
                #:agent-action-probe
                #:agent-action-finding
                #:agent-action-decision
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

(deftest parse-action-tool-call-tolerates-flat-args
  ;; Qwen3.6 occasionally emits the call payload at the top level
  ;; instead of nesting it under "arguments". Without tolerance every
  ;; such call lands at cl-mcp with an empty argument hash and trips
  ;; "path is required". Treat any envelope key other than
  ;; type/tool/thought/arguments as an implicit argument.
  (let ((a (parse-action
            "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"path\":\"/tmp/foo\",\"collapsed\":true,\"name_pattern\":\"^add\"}")))
    (ok (eq :tool-call (agent-action-type a)))
    (ok (equal "lisp-read-file" (agent-action-tool a)))
    (let ((args (agent-action-arguments a)))
      (ok (hash-table-p args))
      (ok (= 3 (hash-table-count args)))
      (ok (equal "/tmp/foo" (gethash "path" args)))
      (ok (eq t (gethash "collapsed" args)))
      (ok (equal "^add" (gethash "name_pattern" args))))))

(deftest parse-action-tool-call-flat-args-preserves-envelope-fields
  ;; Envelope fields (type / tool / thought) must NOT leak into the
  ;; argument hash even though they sit at the same JSON level.
  (let ((a (parse-action
            "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"thought\":\"reading the source\",\"path\":\"/x\"}")))
    (let ((args (agent-action-arguments a)))
      (ok (= 1 (hash-table-count args)))
      (ok (equal "/x" (gethash "path" args)))
      (ok (null (gethash "type" args)))
      (ok (null (gethash "tool" args)))
      (ok (null (gethash "thought" args))))
    (ok (equal "reading the source" (agent-action-thought a)))))

(deftest parse-action-tool-call-explicit-arguments-beats-flat
  ;; If both shapes are present the explicit nested object wins; flat
  ;; siblings are ignored. (No real model sends both, but the rule
  ;; keeps the schema unambiguous.)
  (let ((a (parse-action
            "{\"type\":\"tool_call\",\"tool\":\"lisp-read-file\",\"arguments\":{\"path\":\"/from-nested\"},\"path\":\"/from-flat\"}")))
    (let ((args (agent-action-arguments a)))
      (ok (equal "/from-nested" (gethash "path" args)))
      (ok (= 1 (hash-table-count args))))))

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

(deftest parse-action-recognises-finding-shape
  (let ((a (parse-action
            "{\"type\":\"finding\",\"hypothesis\":\"h\",\"probe\":\"p\",\"finding\":\"f\",\"decision\":\"d\"}")))
    (ok (typep a 'agent-action))
    (ok (eq :finding (agent-action-type a)))
    (ok (string= "h" (agent-action-hypothesis a)))
    (ok (string= "p" (agent-action-probe a)))
    (ok (string= "f" (agent-action-finding a)))
    (ok (string= "d" (agent-action-decision a)))))

(deftest parse-action-rejects-finding-with-missing-fields
  (ok (handler-case
          (progn
            (parse-action
             "{\"type\":\"finding\",\"hypothesis\":\"h\"}")
            nil)
        (action-parse-error () t))))

(deftest parse-action-rejects-finding-with-empty-string
  (ok (handler-case
          (progn
            (parse-action
             "{\"type\":\"finding\",\"hypothesis\":\"\",\"probe\":\"p\",\"finding\":\"f\",\"decision\":\"d\"}")
            nil)
        (action-parse-error () t))))
