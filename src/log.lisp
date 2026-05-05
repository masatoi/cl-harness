;;;; src/log.lisp
;;;;
;;;; PRD §8.10 logging skeleton: append JSONL events to a single transcript file.
;;;; Phase 0 implements OPEN/CLOSE/LOG-EVENT only; richer event schemas land in
;;;; later phases together with the agent loop and verifier.

(defpackage #:cl-harness/src/log
  (:use #:cl)
  (:export #:run-logger
           #:open-run-logger
           #:close-run-logger
           #:log-event
           #:with-run-logger
           #:run-logger-path))

(in-package #:cl-harness/src/log)

(defclass run-logger ()
  ((path :initarg :path :reader run-logger-path)
   (stream :initarg :stream :accessor %run-logger-stream))
  (:documentation "JSONL transcript writer (PRD §8.10 REQ-LOG-001)."))

(defun open-run-logger (path)
  "Open PATH for appending JSONL events and return a RUN-LOGGER."
  (let ((stream (open path
                      :direction :output
                      :if-exists :append
                      :if-does-not-exist :create
                      :element-type 'character)))
    (make-instance 'run-logger :path path :stream stream)))

(defun close-run-logger (logger)
  "Flush and close LOGGER's underlying stream."
  (let ((stream (%run-logger-stream logger)))
    (when (and stream (open-stream-p stream))
      (finish-output stream)
      (close stream)))
  (setf (%run-logger-stream logger) nil)
  (values))

(defun log-event (logger event-type payload)
  "Append a single JSONL line of {ts, type, ...payload} to LOGGER.

EVENT-TYPE is a keyword (e.g. :run-start, :tool-call, :patch). PAYLOAD must
be an alist or hash-table that yason can serialize."
  (check-type event-type keyword)
  (let ((stream (%run-logger-stream logger))
        (table (make-hash-table :test 'equal)))
    (setf (gethash "ts" table)
          (local-time:format-rfc3339-timestring nil (local-time:now)))
    (setf (gethash "type" table) (string-downcase (symbol-name event-type)))
    (etypecase payload
      (hash-table (maphash (lambda (k v) (setf (gethash k table) v)) payload))
      (list (dolist (cell payload)
              (setf (gethash (string (car cell)) table) (cdr cell)))))
    (yason:encode table stream)
    (terpri stream)
    (finish-output stream)
    (values)))

(defmacro with-run-logger ((var path) &body body)
  "Open a RUN-LOGGER bound to VAR for BODY and close it on exit."
  `(let ((,var (open-run-logger ,path)))
     (unwind-protect (progn ,@body)
       (close-run-logger ,var))))
