;;;; next/src/event-log.lisp
;;;;
;;;; Append-only JSONL event log — the single source of truth at L0
;;;; (spec §8.1). Durability over speed: each emit opens, appends,
;;;; and closes the file, so a process crash never loses an acknowledged
;;;; event (no fsync: OS/power failure may tear the final line).
;;;; Projections are built by folding with REPLAY-EVENTS.

(defpackage #:cl-harness-next/src/event-log
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event
                #:event-seq
                #:event->json-string
                #:json-string->event)
  (:export #:event-log
           #:open-event-log
           #:event-log-path
           #:event-log-next-seq
           #:emit-event
           #:read-events
           #:replay-events
           #:event-log-parse-error
           #:event-log-parse-error-path
           #:event-log-parse-error-line-number
           #:event-log-parse-error-cause))

(in-package #:cl-harness-next/src/event-log)

(define-condition event-log-parse-error (error)
  ((path :initarg :path :initform nil :reader event-log-parse-error-path)
   (line-number :initarg :line-number :initform nil
                :reader event-log-parse-error-line-number)
   (cause :initarg :cause :initform nil :reader event-log-parse-error-cause))
  (:report (lambda (condition stream)
             (format stream "Malformed event at ~A line ~A: ~A"
                     (event-log-parse-error-path condition)
                     (event-log-parse-error-line-number condition)
                     (event-log-parse-error-cause condition))))
  (:documentation "Signaled by READ-EVENTS on an unparseable line."))

(defclass event-log ()
  ((path :initarg :path :reader event-log-path)
   (next-seq :initarg :next-seq :accessor event-log-next-seq))
  (:documentation "Handle on an append-only JSONL event log."))

(defun open-event-log (path)
  "Open (or create on first emit) the event log at PATH. When the file
already holds events, the sequence counter resumes after the highest
recorded seq, so suspend/resume needs nothing but the log file."
  (let ((next 1))
    (when (probe-file path)
      (dolist (event (read-events path))
        (setf next (max next (1+ (event-seq event))))))
    (make-instance 'event-log :path (pathname path) :next-seq next)))

(defun emit-event (log type payload)
  "Append a TYPE event carrying PAYLOAD to LOG and return it. The
line is flushed to the OS (file closed) before this function returns;
survives process crash, not necessarily power loss."
  (let ((event (make-harness-event type payload
                                   :seq (event-log-next-seq log))))
    (with-open-file (out (event-log-path log)
                         :direction :output
                         :if-exists :append
                         :if-does-not-exist :create
                         :external-format :utf-8)
      (write-line (event->json-string event) out))
    (incf (event-log-next-seq log))
    event))

(defun read-events (path)
  "Read all events from the JSONL file at PATH, in file order. Blank
lines are skipped. Signals EVENT-LOG-PARSE-ERROR on a malformed line."
  (with-open-file (in path :direction :input :external-format :utf-8)
    (loop for line = (read-line in nil nil)
          for line-number from 1
          while line
          unless (string= "" (string-trim '(#\Space #\Tab) line))
            collect (handler-case (json-string->event line)
                      (error (e)
                        (error 'event-log-parse-error
                               :path path
                               :line-number line-number
                               :cause e))))))

(defun replay-events (path reducer initial)
  "Fold REDUCER over the events at PATH in order, as
\(funcall REDUCER accumulator event), starting from INITIAL. Returns
the final accumulator. This is how L2 projections are built."
  (reduce reducer (read-events path) :initial-value initial))
