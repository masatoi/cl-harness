;;;; src/action.lisp
;;;;
;;;; PRD §8.4 REQ-AGENT-002 — parse the JSON action emitted by the LLM
;;;; into a structured AGENT-ACTION the agent loop can dispatch on.
;;;;
;;;; Action schema (Phase 2):
;;;;   {"type":"tool_call","tool":"<name>","arguments":{...},"thought":"..."}
;;;;   {"type":"finish","status":"fixed"|"give_up","summary":"..."}
;;;; Markdown code fences (```...```) emitted by chat models are stripped
;;;; transparently before JSON decoding.
;;;;
;;;; Tool-call payloads also accept a flat layout (every key other than
;;;; the envelope fields counted as an implicit argument) — Qwen3 MoE
;;;; models occasionally emit that shape even at temperature 0; see
;;;; docs/notes/2026-05-06-qwen-smoke.md. Explicit "arguments" wins
;;;; when both forms are present.

(defpackage #:cl-harness/src/action
  (:use #:cl)
  (:export #:agent-action
           #:agent-action-type
           #:agent-action-tool
           #:agent-action-arguments
           #:agent-action-status
           #:agent-action-summary
           #:agent-action-thought
           #:agent-action-raw
           #:agent-action-hypothesis
           #:agent-action-probe
           #:agent-action-finding
           #:agent-action-decision
           #:agent-action-criteria
           #:agent-action-rationale
           #:agent-action-test-source
           #:parse-action
           #:action-parse-error
           #:action-parse-error-message
           #:action-parse-error-raw))

(in-package #:cl-harness/src/action)

(define-condition action-parse-error (error)
  ((message :initarg :message :reader action-parse-error-message)
   (raw :initarg :raw :initform nil :reader action-parse-error-raw))
  (:documentation "Signaled when the LLM's action payload cannot be decoded.")
  (:report (lambda (c stream)
             (format stream "action-parse-error: ~A"
                     (action-parse-error-message c)))))

(defclass agent-action ()
  ((type :initarg :type :reader agent-action-type)
   (tool :initarg :tool :initform nil :reader agent-action-tool)
   (arguments :initarg :arguments :initform nil :reader agent-action-arguments)
   (status :initarg :status :initform nil :reader agent-action-status)
   (summary :initarg :summary :initform nil :reader agent-action-summary)
   (thought :initarg :thought :initform nil :reader agent-action-thought)
   (raw :initarg :raw :initform nil :reader agent-action-raw)
   (hypothesis :initarg :hypothesis :initform nil
               :reader agent-action-hypothesis
               :documentation "For :FINDING actions, the conjecture
under test (non-empty string). NIL for other action types.")
   (probe :initarg :probe :initform nil
          :reader agent-action-probe
          :documentation "For :FINDING actions, the description of
the REPL probe used. NIL for other action types.")
   (finding :initarg :finding :initform nil
            :reader agent-action-finding
            :documentation "For :FINDING actions, the observed result
of the probe (non-empty string). NIL for other action types.")
   (decision :initarg :decision :initform nil
             :reader agent-action-decision
             :documentation "For :FINDING actions, the design decision
the finding drives (non-empty string). NIL for other action types.")
   (criteria :initarg :criteria :initform nil
             :reader agent-action-criteria
             :documentation "For :TEST-CHANGE-REQUEST actions, a list
of acceptance-criteria identifiers or descriptions affected by the
request.")
   (rationale :initarg :rationale :initform nil
              :reader agent-action-rationale
              :documentation "For :TEST-CHANGE-REQUEST actions, why the
test needs additive coverage.")
   (test-source :initarg :test-source :initform nil
                :reader agent-action-test-source
                :documentation "For :TEST-CHANGE-REQUEST actions, the
proposed additive rove test source."))
  (:documentation "Parsed LLM action; TYPE is :TOOL-CALL, :FINISH,
:FINDING, or :TEST-CHANGE-REQUEST."))

;; --- Stubs ---------------------------------------------------------------
;; Intentionally wrong return values so the failing tests surface
;; meaningful assertion errors before the real implementation lands.

(defun strip-code-fence (text)
  "Return the JSON payload from TEXT, stripping a single ```...``` fence
when present. The opening fence's optional language tag (e.g. ```json)
is also dropped. TEXT without fences is returned unchanged."
  (let ((open (search "```" text)))
    (if (null open)
        text
        (let* ((after-open (+ open 3))
               (close (search "```" text :start2 after-open))
               (inner (if close
                          (subseq text after-open close)
                          (subseq text after-open)))
               (nl (position #\Newline inner))
               (lang (and nl (string-trim '(#\Space #\Tab)
                                          (subseq inner 0 nl)))))
          (if (and lang
                   (plusp (length lang))
                   (every #'alpha-char-p lang))
              (subseq inner (1+ nl))
              inner)))))

(defparameter +envelope-keys+
  '("type" "tool" "thought" "arguments" "status" "summary"
    "hypothesis" "probe" "finding" "decision"
    "criteria" "rationale" "test_source")
  "Top-level action-envelope keys that must NOT be treated as implicit
arguments when the LLM emits a flat tool_call payload (no nested
\"arguments\" object). Phase H added the four :FINDING sub-fields.")

(defun %extract-flat-arguments (parsed)
  "Return a fresh hash-table of every PARSED key not in +ENVELOPE-KEYS+.
Used when the LLM emits the tool's parameters at the same JSON level
as type/tool/thought instead of nesting them under \"arguments\"."
  (let ((args (make-hash-table :test 'equal)))
    (maphash (lambda (k v)
               (unless (member k +envelope-keys+ :test #'equal)
                 (setf (gethash k args) v)))
             parsed)
    args))

(defun parse-action (text)
  "Parse TEXT (raw or fenced JSON) into an AGENT-ACTION.

Signals ACTION-PARSE-ERROR if TEXT is not valid JSON, is not an object,
declares an unknown TYPE, or is missing a required field for its variant."
  (check-type text string)
  (let* ((stripped (strip-code-fence text))
         (parsed
          (handler-case (yason:parse stripped)
            (error (c)
              (error 'action-parse-error
                     :message (format nil "JSON decode failed: ~A" c)
                     :raw text)))))
    (unless (hash-table-p parsed)
      (error 'action-parse-error
             :message "top-level JSON value must be an object"
             :raw text))
    (let ((type (gethash "type" parsed))
          (thought (gethash "thought" parsed)))
      (cond
        ((equal type "tool_call")
         (let ((tool (gethash "tool" parsed))
               (args (gethash "arguments" parsed)))
           (unless (and (stringp tool) (plusp (length tool)))
             (error 'action-parse-error
                    :message "tool_call action requires a non-empty 'tool' string"
                    :raw parsed))
           (make-instance 'agent-action
                          :type :tool-call
                          :tool tool
                          :arguments (or args (%extract-flat-arguments parsed))
                          :thought (and (stringp thought) thought)
                          :raw parsed)))
        ((equal type "finish")
         (let ((status (gethash "status" parsed)))
           (unless (member status '("fixed" "give_up") :test #'equal)
             (error 'action-parse-error
                    :message
                    "finish action requires 'status' of \"fixed\" or \"give_up\""
                    :raw parsed))
           (make-instance 'agent-action
                          :type :finish
                          :status (if (equal status "fixed") :fixed :give-up)
                          :summary (gethash "summary" parsed)
                          :thought (and (stringp thought) thought)
                          :raw parsed)))
        ((equal type "finding")
         (let ((hypothesis (gethash "hypothesis" parsed))
               (probe (gethash "probe" parsed))
               (finding (gethash "finding" parsed))
               (decision (gethash "decision" parsed)))
           (dolist (pair (list (cons "hypothesis" hypothesis)
                               (cons "probe" probe)
                               (cons "finding" finding)
                               (cons "decision" decision)))
             (let ((field (car pair))
                   (value (cdr pair)))
               (unless (and (stringp value) (plusp (length value)))
                 (error 'action-parse-error
                        :message (format nil "finding action requires non-empty '~A'"
                                         field)
                        :raw parsed))))
           (make-instance 'agent-action
                          :type :finding
                          :hypothesis hypothesis
                          :probe probe
                          :finding finding
                          :decision decision
                          :thought (and (stringp thought) thought)
                          :raw parsed)))
        ((equal type "test_change_request")
         (let ((criteria (gethash "criteria" parsed))
               (rationale (gethash "rationale" parsed))
               (test-source (gethash "test_source" parsed)))
           (unless (or (null criteria) (vectorp criteria) (listp criteria))
             (error 'action-parse-error
                    :message "test_change_request 'criteria' must be an array"
                    :raw parsed))
           (let ((criteria-list (cond
                                  ((null criteria) nil)
                                  ((vectorp criteria) (coerce criteria 'list))
                                  (t criteria))))
             (dolist (item criteria-list)
               (unless (stringp item)
                 (error 'action-parse-error
                        :message "test_change_request criteria entries must be strings"
                        :raw parsed)))
             (unless (and (stringp rationale) (plusp (length rationale)))
               (error 'action-parse-error
                      :message "test_change_request requires non-empty 'rationale'"
                      :raw parsed))
             (unless (and (stringp test-source) (plusp (length test-source)))
               (error 'action-parse-error
                      :message "test_change_request requires non-empty 'test_source'"
                      :raw parsed))
             (make-instance 'agent-action
                            :type :test-change-request
                            :criteria criteria-list
                            :rationale rationale
                            :test-source test-source
                            :thought (and (stringp thought) thought)
                            :raw parsed))))
        (t (error 'action-parse-error
                  :message (format nil "unknown action type: ~A"
                                   (or type "<missing>"))
                  :raw parsed))))))
