;;;; next/src/event.lisp
;;;;
;;;; Event representation for the L0 event-sourcing substrate (spec
;;;; §8.1). Events are the only persisted truth; everything else is a
;;;; projection. The type vocabulary is deliberately coarse and fixed;
;;;; extend +EVENT-TYPES+ in code only when an upper layer's need
;;;; cannot be expressed as the payload of an existing type.

(defpackage #:cl-harness-next/src/event
  (:use #:cl)
  (:import-from #:cl-harness-next/src/json
                #:parse-json)
  (:export #:+event-types+
           #:unknown-event-type
           #:unknown-event-type-name
           #:event-type-name
           #:event-type-keyword
           #:harness-event
           #:make-harness-event
           #:event-seq
           #:event-type
           #:event-timestamp
           #:event-schema-version
           #:event-payload
           #:event->json-string
           #:json-string->event))

(in-package #:cl-harness-next/src/event)

(alexandria:define-constant +event-types+
    '(:run-start :run-end :observation :action :decision
      :oracle-result :metric :checkpoint :note)
  :test #'equal
  :documentation
  "Fixed coarse event vocabulary (spec §8.1). Upper layers express
detail in payloads, not new types: a patch is an :action, a clean
verification verdict is an :oracle-result, etc.")

(define-condition unknown-event-type (error)
  ((name :initarg :name :initform nil :reader unknown-event-type-name))
  (:report (lambda (condition stream)
             (format stream "Unknown event type ~S (known: ~{~S~^ ~})."
                     (unknown-event-type-name condition)
                     +event-types+)))
  (:documentation "Signaled for an event type outside +EVENT-TYPES+."))

(defun %wire-name (keyword)
  (substitute #\_ #\- (string-downcase (symbol-name keyword))))

(defun event-type-name (keyword)
  "Return the JSON wire name for event-type KEYWORD, e.g. :RUN-START
=> \"run_start\". Signals UNKNOWN-EVENT-TYPE for unknown keywords."
  (unless (member keyword +event-types+)
    (error 'unknown-event-type :name keyword))
  (%wire-name keyword))

(defun event-type-keyword (name)
  "Return the event-type keyword for wire NAME, e.g. \"run_start\"
=> :RUN-START. Signals UNKNOWN-EVENT-TYPE for unknown names."
  (or (find name +event-types+ :key #'%wire-name :test #'string=)
      (error 'unknown-event-type :name name)))

(defclass harness-event ()
  ((seq :initarg :seq :reader event-seq
        :documentation "Monotonic sequence number within one log, from 1.")
   (event-type :initarg :event-type :reader event-type
               :documentation "Member of +EVENT-TYPES+.")
   (timestamp :initarg :timestamp :reader event-timestamp
              :documentation "ISO-8601 timestamp string.")
   (schema-version :initarg :schema-version :initform 1
                   :reader event-schema-version)
   (payload :initarg :payload :initform nil :reader event-payload
            :documentation "Hash-table with string keys, or NIL."))
  (:documentation "One immutable entry in the append-only event log."))

(defun make-harness-event (type payload &key (seq 0) timestamp (schema-version 1))
  "Construct a HARNESS-EVENT of TYPE carrying PAYLOAD (a hash-table
with string keys, or NIL). TIMESTAMP defaults to now. Signals
UNKNOWN-EVENT-TYPE when TYPE is not in +EVENT-TYPES+."
  (event-type-name type)
  (make-instance 'harness-event
                 :seq seq
                 :event-type type
                 :timestamp (or timestamp
                                (local-time:format-timestring
                                 nil (local-time:now)))
                 :schema-version schema-version
                 :payload payload))

(defun event->json-string (event)
  "Serialize EVENT to a single-line JSON string (the JSONL wire format)."
  (with-output-to-string (out)
    (yason:with-output (out)
      (yason:with-object ()
        (yason:encode-object-element "seq" (event-seq event))
        (yason:encode-object-element "type" (event-type-name (event-type event)))
        (yason:encode-object-element "timestamp" (event-timestamp event))
        (yason:encode-object-element "schema_version" (event-schema-version event))
        (yason:encode-object-element
         "payload" (or (event-payload event)
                       (make-hash-table :test #'equal)))))))

(defun json-string->event (line)
  "Parse one JSONL LINE back into a HARNESS-EVENT. An empty payload
object decodes as NIL. Signals UNKNOWN-EVENT-TYPE on unknown types."
  (let ((object (parse-json line)))
    (make-instance 'harness-event
                   :seq (gethash "seq" object)
                   :event-type (event-type-keyword (gethash "type" object))
                   :timestamp (gethash "timestamp" object)
                   :schema-version (gethash "schema_version" object 1)
                   :payload (let ((payload (gethash "payload" object)))
                              (if (and (hash-table-p payload)
                                       (zerop (hash-table-count payload)))
                                  nil
                                  payload)))))
