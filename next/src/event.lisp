;;;; next/src/event.lisp
;;;;
;;;; Event representation for the L0 event-sourcing substrate (spec
;;;; §8.1). Events are the only persisted truth; everything else is a
;;;; projection. The type vocabulary is deliberately coarse and fixed;
;;;; extend +EVENT-TYPES+ in code only when an upper layer's need
;;;; cannot be expressed as the payload of an existing type.

(defpackage #:cl-harness-next/src/event
  (:use #:cl)
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
  ((name :initarg :name :reader unknown-event-type-name))
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
