;;;; next/tests/event-log-test.lisp
;;;;
;;;; Unit tests for next/src/event-log.lisp: durable append, ordered
;;;; read, seq resume after reopen (spec §8.1 / §9 — suspend/resume
;;;; rebuilds from the log alone), replay fold, parse-error reporting.

(defpackage #:cl-harness-next/tests/event-log-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-seq
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:event-log-next-seq
                #:emit-event
                #:read-events
                #:replay-events
                #:event-log-parse-error
                #:event-log-parse-error-line-number))

(in-package #:cl-harness-next/tests/event-log-test)

(defmacro with-log-path ((path) &body body)
  "Run BODY with PATH bound to a fresh temporary .jsonl path that does
not exist yet and is deleted afterwards."
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(deftest emit-and-read-roundtrip
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start
                  (alexandria:plist-hash-table (list "pack" "abc")
                                               :test #'equal))
      (emit-event log :action nil)
      (emit-event log :run-end nil)
      (let ((events (read-events path)))
        (ok (= 3 (length events)))
        (ok (equal '(1 2 3) (mapcar #'event-seq events)))
        (ok (equal '(:run-start :action :run-end)
                   (mapcar #'event-type events)))
        (ok (equal "abc" (gethash "pack" (event-payload (first events)))))))))

(deftest seq-resumes-after-reopen
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start nil)
      (emit-event log :note nil))
    (let* ((reopened (open-event-log path))
           (event (emit-event reopened :run-end nil)))
      (ok (= 3 (event-seq event)))
      (ok (= 3 (length (read-events path)))))))

(deftest fresh-log-starts-at-one
  (with-log-path (path)
    (ok (= 1 (event-log-next-seq (open-event-log path))))))

(deftest replay-events-folds-in-order
  (with-log-path (path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start nil)
      (emit-event log :action nil)
      (emit-event log :run-end nil))
    (let ((seqs (replay-events path
                               (lambda (acc ev)
                                 (append acc (list (event-seq ev))))
                               nil)))
      (ok (equal '(1 2 3) seqs)))))

(deftest read-events-signals-parse-error-on-garbage
  (with-log-path (path)
    ;; Write a valid event followed by a corrupt line.
    (let ((log (open-event-log path)))
      (emit-event log :note nil))
    (with-open-file (out path :direction :output :if-exists :append)
      (write-line "not-valid-json{{{" out))
    (let ((err (handler-case (read-events path)
                 (event-log-parse-error (e) e))))
      (ok (typep err 'event-log-parse-error))
      (ok (= 2 (event-log-parse-error-line-number err))))))
