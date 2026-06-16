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
           #:repair-edit-action
           #:action-error-hint
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

(defun full-definition-form-p (text)
  "True when TEXT reads as exactly one complete (defXXX ...) form with
nothing but whitespace after it. Used to decide whether a patch's
new_text is a whole replacement form (so it can be routed to an
edit-form replace, sidestepping a brittle old_text). Reads with
*READ-EVAL* nil into a throwaway package that is deleted afterwards, so
the form's symbols never pollute a long-lived package. A read error or a
trailing form yields NIL."
  (let ((scratch (make-package (gensym "ACTION-READ-SCRATCH-") :use nil)))
    (unwind-protect
        (handler-case
            (let ((*read-eval* nil)
                  (*package* scratch))
              (with-input-from-string (stream text)
                (let ((form (read stream nil nil)))
                  (and (consp form)
                       (symbolp (first form))
                       (let ((name (symbol-name (first form))))
                         (and (>= (length name) 3)
                              (string-equal (subseq name 0 3) "DEF")))
                       (null (read stream nil nil))))))
          (error () nil))
      (delete-package scratch))))

(defun %copy-arguments (table)
  "Shallow copy of an EQUAL-keyed arguments hash-table, so a repair can
build a fresh action without mutating the parsed original (and the
ORIGINAL it aliases via the action's :raw slot)."
  (let ((copy (make-hash-table :test 'equal
                               :size (max 1 (hash-table-count table)))))
    (maphash (lambda (k v) (setf (gethash k copy) v)) table)
    copy))

(defun repair-edit-action (action)
  "Repair the common malformed tool-call arguments a weak local model
emits for the cl-mcp editing tools, so a semantically-correct edit still
dispatches. Returns ACTION unchanged unless it is a :TOOL-CALL for
lisp-edit-form / lisp-patch-form with a repairable argument; this is a
no-op for well-formed edits and for every non-editing tool. The original
ACTION (and the parsed object it aliases via :raw) is never mutated — a
repair builds a fresh action over a copied arguments table.

Repairs: form_type \"function\" -> \"defun\"; an invalid operation that is
NOT insert-like (overwrite / edit / delete-and-replace / ...) -> \"replace\"
(an insert-shaped operation keeps its positional intent); a form_name
carrying a leading form_type token (\"defmethod bark\" -> \"bark\"), plus —
only for a bare symbol token — a leading package qualifier
(\"pkg::user\" -> \"user\", while \"(setf pkg::x)\" and specializer lists
are left intact); and a lisp-patch-form whose new_text is a COMPLETE
definition form -> a lisp-edit-form replace with that form as content,
dropping the brittle whitespace-sensitive old_text (the dominant
high-agency failure: a correct fix the model cannot land because old_text
will not match)."
  (let ((tool (agent-action-tool action))
        (source (agent-action-arguments action)))
    (unless (and (eq :tool-call (agent-action-type action))
                 (hash-table-p source)
                 (member tool '("lisp-edit-form" "lisp-patch-form")
                         :test #'string=))
      (return-from repair-edit-action action))
    (let ((args (%copy-arguments source))
          (new-tool tool)
          (changed nil))
      ;; form_type: "function" is not a form type; the model means "defun".
      (when (equal (gethash "form_type" args) "function")
        (setf (gethash "form_type" args) "defun" changed t))
      ;; operation: an invalid value that is NOT insert-shaped is the
      ;; model's word for "replace this form" (overwrite / edit / ...).
      ;; An insert-shaped value keeps its positional intent (do not force
      ;; a replace).
      (let ((op (gethash "operation" args)))
        (when (and (stringp op)
                   (not (member op '("replace" "insert_before" "insert_after")
                                :test #'string=))
                   (not (search "insert" (string-downcase op))))
          (setf (gethash "operation" args) "replace" changed t)))
      ;; form_name: strip a leading "<form_type> " token; then, only for a
      ;; bare symbol token (no paren or space, so (setf pkg::x) and
      ;; specializer lists stay intact), strip a leading package qualifier.
      (let ((form-name (gethash "form_name" args))
            (form-type (gethash "form_type" args)))
        (when (stringp form-name)
          (let ((bare form-name))
            (when (and (stringp form-type)
                       (> (length bare) (1+ (length form-type)))
                       (string-equal (subseq bare 0 (length form-type)) form-type)
                       (char= (char bare (length form-type)) #\Space))
              (setf bare (string-left-trim " " (subseq bare (length form-type)))))
            (when (and (not (find #\( bare))
                       (not (find #\Space bare)))
              (let ((sep (search "::" bare)))
                (when sep (setf bare (subseq bare (+ sep 2))))))
            (unless (equal bare form-name)
              (setf (gethash "form_name" args) bare changed t)))))
      ;; A patch whose new_text is a whole definition form: route to an
      ;; edit-form replace and drop old_text.
      (when (and (string= tool "lisp-patch-form")
                 (stringp (gethash "new_text" args))
                 (full-definition-form-p (gethash "new_text" args)))
        (setf (gethash "content" args) (gethash "new_text" args)
              (gethash "operation" args) "replace"
              new-tool "lisp-edit-form"
              changed t)
        (remhash "new_text" args)
        (remhash "old_text" args))
      (if changed
          (make-instance 'agent-action
                         :type :tool-call
                         :tool new-tool
                         :arguments args
                         :thought (agent-action-thought action)
                         :raw (agent-action-raw action))
          action))))

(defun action-error-hint (error-text)
  "Given a cl-mcp tool-error string ERROR-TEXT (e.g. the kernel's
last-action-error), return a short actionable hint steering a weak model
out of a known dead-end on its next step, or NIL when no hint applies.

The dominant high-agency dead-end is a lisp-patch-form whose old_text
will not whitespace-match: the model has the right fix but keeps
re-trying an unmatchable old_text. The hint redirects it to re-emit the
WHOLE form via a lisp-edit-form replace, which REPAIR-EDIT-ACTION then
routes cleanly. A form-locate failure gets a form_name hint, matched on
cl-mcp's distinctive \"Form <type> <name> not found in <path>\" shape
(both \"Form \" and \"not found in\"), so the sibling \"Symbol ... not
found in <package>\" / \"Section ... not found in ...\" errors do NOT
mis-fire into a form_name hint."
  (when (stringp error-text)
    (cond
      ((search "old_text not found" error-text)
       "Hint: stop retrying old_text -- it must match the source text exactly, including whitespace. Instead re-emit the COMPLETE corrected form using lisp-edit-form with operation \"replace\" and the whole (def...) form in \"content\" (no old_text).")
      ((and (search "Form " error-text)
            (search "not found in" error-text))
       "Hint: the form_name did not resolve. Use the bare symbol for a defun/defmacro, the full specializer list for a defmethod (e.g. \"area ((s square))\"), and the package name for a defpackage.")
      (t nil))))

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
          (return (values (repair-edit-action
                           (parse-action (funcall fn current)))
                          nil))
        (error (condition)
          (setf last-error (princ-to-string condition))
          (setf current
                (format nil "~A~2%IMPORTANT: your previous reply was not a ~
valid action (~A). Reply with EXACTLY ONE valid JSON object and nothing ~
else -- no markdown fences, no prose. Escape every newline inside a ~
string value as \\n. For a tool call, \"type\" must be \"tool_call\" and ~
the tool's arguments go under \"arguments\"."
                        prompt last-error)))))))
