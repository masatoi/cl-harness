;;;; next/src/action.lisp
;;;;
;;;; LLM action parser, adapt-copied from legacy src/action.lisp.
;;;; Schema: {"type":"tool_call","tool":...,"arguments":{...}} /
;;;; {"type":"finish","status":"fixed"|"give_up"} /
;;;; {"type":"finding",...} — with markdown-fence stripping and the
;;;; flat-arguments fallback (Qwen-class models emit it). The legacy
;;;; test-change-request variant is dropped (develop-loop detail;
;;;; returns with a scripted develop policy if ever needed).

(defpackage #:cl-harness-next/src/action
  (:use #:cl)
  (:import-from #:cl-harness-next/src/json
                #:parse-json)
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
           #:parse-action
           #:obtain-action
           #:strip-code-fence
           #:action-parse-error
           #:action-parse-error-message
           #:action-parse-error-raw))

(in-package #:cl-harness-next/src/action)

(define-condition action-parse-error (error)
  ((message :initarg :message :initform "(no message)" :reader action-parse-error-message)
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
the finding drives (non-empty string). NIL for other action types."))
  (:documentation "Parsed LLM action; TYPE is :TOOL-CALL, :FINISH, or :FINDING."))

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
    "hypothesis" "probe" "finding" "decision")
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
          (handler-case (parse-json stripped)
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
        ((and (stringp (gethash "tool" parsed))
              (plusp (length (gethash "tool" parsed))))
         ;; Lenient: the model declared an unknown TYPE but a non-empty
         ;; 'tool' is present (small models put the tool name in 'type'
         ;; instead of the literal "tool_call"). Treat it as a tool_call —
         ;; same family as the fence-stripping and flat-arguments fallbacks.
         (let ((tool (gethash "tool" parsed))
               (args (gethash "arguments" parsed)))
           (make-instance 'agent-action
                          :type :tool-call
                          :tool tool
                          :arguments (or args (%extract-flat-arguments parsed))
                          :thought (and (stringp thought) thought)
                          :raw parsed)))
        (t (error 'action-parse-error
                  :message (format nil "unknown action type: ~A"
                                   (or type "<missing>"))
                  :raw parsed))))))

(defun obtain-action (fn prompt &key (max-tries 3))
  "Call FN (a function of one prompt string returning a raw LLM response)
and PARSE-ACTION the result, retrying up to MAX-TRIES.

On a parse failure (or an error raised by FN itself, e.g. a transport
error) the failure is appended to the ORIGINAL PROMPT — the view is
retained, the note does not compound across retries — so the next sample
can self-correct. Returns (values ACTION NIL) on the first parseable
reply, or (values NIL ERROR-MESSAGE) once MAX-TRIES is exhausted.

This makes the policies tolerant of the intermittently-malformed action
JSON that small local models emit, instead of failing the whole mission
on the first bad reply."
  (let ((current prompt)
        (last-error "(no attempt)"))
    (dotimes (i max-tries (values nil last-error))
      (handler-case
          (return (values (parse-action (funcall fn current)) nil))
        (error (condition)
          (setf last-error (princ-to-string condition))
          (setf current
                (format nil "~A~2%IMPORTANT: your previous reply was not a ~
valid action (~A). Reply with EXACTLY ONE valid JSON object and nothing else."
                        prompt last-error)))))))
