;;;; next/tests/improver-test.lisp
;;;;
;;;; Tests for next/src/improver.lisp (spec §10.2 stage 5 + §10.3
;;;; authority boundary + §10.4 audit): the improve-once cycle.

(defpackage #:cl-harness-next/tests/improver-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event
                #:read-events)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-version
                #:pack-budget
                #:pack-fingerprint
                #:policy-pack)
  (:import-from #:cl-harness-next/src/bench
                #:make-trial)
  (:import-from #:cl-harness-next/src/improver
                #:improve-once))

(in-package #:cl-harness-next/tests/improver-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defparameter *budget-variant-json*
  (concatenate 'string
               "{\"kind\":\"budget\",\"target\":\"max-actions\","
               "\"value\":40,\"hypothesis\":\"more room to verify\"}"))

(defmacro with-improver-fixtures ((champion transcript audit-log
                                   pack-directory)
                                  &body body)
  `(uiop:with-temporary-file (:pathname pack-path :type "sexp")
     (uiop:with-temporary-file (:pathname transcript-path :type "jsonl")
       (uiop:with-temporary-file (:pathname audit-path :type "jsonl")
         (uiop:delete-file-if-exists transcript-path)
         (uiop:delete-file-if-exists audit-path)
         (with-open-file (out pack-path :direction :output
                                        :if-exists :supersede
                                        :external-format :utf-8)
           (write-string
            "(:name \"p\" :version \"1.0.0\"
              :budgets ((:id :max-actions :value 20)))"
            out))
         (let ((,champion (load-policy-pack pack-path))
               (,transcript transcript-path)
               (,audit-log (open-event-log audit-path))
               (,pack-directory
                 (uiop:pathname-directory-pathname pack-path)))
           ;; One synthetic failure in the transcript.
           (let ((log (open-event-log transcript-path)))
             (emit-event log :action (%hash "tool" "lisp-edit-form"
                                            "arguments" (%hash)))
             (emit-event log :observation
                         (%hash "tool" "lisp-edit-form"
                                "result" (%hash "isError" t))))
           ,@body)))))

(defun %trial-fn (champion-successes challenger-successes
                  &optional calls-box)
  (lambda (pack index)
    (when calls-box (push pack (car calls-box)))
    (let ((successes (if (equal (pack-version pack) "1.0.0")
                         champion-successes
                         challenger-successes)))
      (make-trial :index index
                  :pack-fingerprint (pack-fingerprint pack)
                  :success-p (elt successes index)
                  :actions 10))))

(deftest improve-once-promotes-a-winning-budget-variant
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (multiple-value-bind (outcome detail)
        (improve-once :champion champion
                      :transcripts (list transcript)
                      :propose-fn (lambda (prompt)
                                    (declare (ignore prompt))
                                    *budget-variant-json*)
                      :trial-fn (%trial-fn '(nil nil nil) '(t t t))
                      :pack-directory pack-directory
                      :audit-log audit-log
                      :trials 3)
      (ok (eq :promoted outcome))
      (ok (typep detail 'policy-pack))
      (ok (= 40 (pack-budget detail :max-actions)))
      (ok (equal "1.0.1" (pack-version detail)))
      ;; audit-path is captured anaphorically by the fixture macro.
      (let ((promotion (find-if
                        (lambda (event)
                          (and (eq :decision (event-type event))
                               (equal "promotion"
                                      (gethash "kind"
                                               (event-payload event)))))
                        (read-events audit-path))))
        (ok promotion)
        (ok (equal (pack-fingerprint detail)
                   (gethash "to" (event-payload promotion))))))))

(deftest improve-once-rejects-a-losing-variant
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (multiple-value-bind (outcome detail)
        (improve-once :champion champion
                      :transcripts (list transcript)
                      :propose-fn (lambda (prompt)
                                    (declare (ignore prompt))
                                    *budget-variant-json*)
                      :trial-fn (%trial-fn '(t t t) '(nil nil nil))
                      :pack-directory pack-directory
                      :audit-log audit-log
                      :trials 3)
      (ok (eq :rejected outcome))
      (ok (stringp detail)))))

(deftest improve-once-handles-unparseable-proposals
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (multiple-value-bind (outcome detail)
        (improve-once :champion champion
                      :transcripts (list transcript)
                      :propose-fn (lambda (prompt)
                                    (declare (ignore prompt))
                                    "no idea")
                      :trial-fn (%trial-fn '(t) '(t))
                      :pack-directory pack-directory
                      :audit-log audit-log)
      (ok (eq :no-variant outcome))
      (ok (stringp detail)))))

(deftest code-variants-become-dossiers-without-trials
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (let ((calls (list nil)))
      (multiple-value-bind (outcome detail)
          (improve-once :champion champion
                        :transcripts (list transcript)
                        :propose-fn
                        (lambda (prompt)
                          (declare (ignore prompt))
                          (concatenate 'string
                                       "{\"kind\":\"code\","
                                       "\"hypothesis\":\"needs a new"
                                       " oracle\"}"))
                        :trial-fn (%trial-fn '(t) '(t) calls)
                        :pack-directory pack-directory
                        :audit-log audit-log)
        (ok (eq :proposal outcome))
        (ok (search "human approval" detail))
        (ok (search "needs a new oracle" detail))
        ;; The authority boundary: no trials were run for code changes.
        (ok (null (car calls)))))))
