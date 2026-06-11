;;;; next/src/projection.lisp
;;;;
;;;; Projection protocol for the L2 world model (spec §8.2). A
;;;; projection is an in-memory derivation of the event log; the log
;;;; stays the only persisted truth and projections are rebuilt by
;;;; replay. Tool round-trips arrive pre-paired as INTERACTIONs — the
;;;; world model pairs an :action with its following :observation
;;;; exactly once, so projections never re-implement pairing.

(defpackage #:cl-harness-next/src/projection
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-seq
                #:event-payload)
  (:export #:projection
           #:apply-event
           #:apply-interaction
           #:interaction
           #:make-interaction
           #:interaction-tool
           #:interaction-arguments
           #:interaction-result
           #:interaction-error-message
           #:interaction-action-seq
           #:interaction-observation-seq
           #:interaction-ok-p
           #:argument-string
           #:result-text
           #:result-error-p
           #:interaction-succeeded-p
           #:+patch-tool-names+))

(in-package #:cl-harness-next/src/projection)

(alexandria:define-constant +patch-tool-names+
    '("lisp-edit-form" "lisp-patch-form" "fs-write-file")
  :test #'equal
  :documentation
  "Tools whose successful use changes source files. Shared convention
for the ledgers (staleness, patch history, clean-verify derivation).")

(defclass projection ()
  ()
  (:documentation "Abstract base for world-model projections (spec
§8.2). Subclasses accumulate state from events and interactions; they
are in-memory only and rebuilt by replaying the event log."))

(defgeneric apply-event (projection event)
  (:documentation "Fold one raw EVENT into PROJECTION. Default no-op.
Returns PROJECTION.")
  (:method ((projection projection) event)
    (declare (ignore event))
    projection))

(defgeneric apply-interaction (projection interaction)
  (:documentation "Fold one paired tool INTERACTION into PROJECTION.
Default no-op. Returns PROJECTION.")
  (:method ((projection projection) interaction)
    (declare (ignore interaction))
    projection))

(defclass interaction ()
  ((tool :initarg :tool :reader interaction-tool)
   (arguments :initarg :arguments :initform nil
              :reader interaction-arguments
              :documentation "Hash-table or NIL.")
   (result :initarg :result :initform nil :reader interaction-result
           :documentation "tools/call result hash-table, or NIL.")
   (error-message :initarg :error-message :initform nil
                  :reader interaction-error-message)
   (action-seq :initarg :action-seq :reader interaction-action-seq)
   (observation-seq :initarg :observation-seq
                    :reader interaction-observation-seq))
  (:documentation "One paired tool round-trip: an :action event and
its matching :observation, per SP2's payload conventions."))

(defun make-interaction (action-event observation-event)
  "Pair ACTION-EVENT with OBSERVATION-EVENT into an INTERACTION,
reading SP2's payload conventions ({\"tool\",\"arguments\"} /
{\"tool\",\"result\"|\"error\"})."
  (let ((action-payload (event-payload action-event))
        (observation-payload (event-payload observation-event)))
    (make-instance 'interaction
                   :tool (gethash "tool" action-payload)
                   :arguments (gethash "arguments" action-payload)
                   :result (gethash "result" observation-payload)
                   :error-message (gethash "error" observation-payload)
                   :action-seq (event-seq action-event)
                   :observation-seq (event-seq observation-event))))

(defun interaction-ok-p (interaction)
  "True when the tool round-trip completed without an MCP error."
  (null (interaction-error-message interaction)))

(defun argument-string (interaction key)
  "Return the string argument KEY of INTERACTION, or NIL."
  (let ((arguments (interaction-arguments interaction)))
    (when (hash-table-p arguments)
      (let ((value (gethash key arguments)))
        (when (stringp value) value)))))

(defun result-text (interaction &key (limit 200))
  "Best-effort summary of INTERACTION's result: the first content
element's \"text\", truncated to LIMIT characters. Returns NIL when
the shape is absent (lesson: check key presence, never guess shapes)."
  (let ((result (interaction-result interaction)))
    (when (hash-table-p result)
      (multiple-value-bind (content present-p) (gethash "content" result)
        (when (and present-p (consp content))
          (let ((first-element (first content)))
            (when (hash-table-p first-element)
              (let ((text (gethash "text" first-element)))
                (when (stringp text)
                  (if (> (length text) limit)
                      (concatenate 'string (subseq text 0 limit)
                                   " …[truncated]")
                      text))))))))))

(defun result-error-p (interaction)
  "True when the TOOL itself reported failure (MCP result \"isError\")
— distinct from transport-level failure (INTERACTION-OK-P)."
  (let ((result (interaction-result interaction)))
    (and (hash-table-p result)
         (multiple-value-bind (value present-p) (gethash "isError" result)
           (and present-p value t)))))

(defun interaction-succeeded-p (interaction)
  "True when the round-trip completed AND the tool reported success."
  (and (interaction-ok-p interaction)
       (not (result-error-p interaction))))
