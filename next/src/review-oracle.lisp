;;;; next/src/review-oracle.lisp
;;;;
;;;; LLM review oracle (spec §7): stage-aware strictness lives in a
;;;; policy-pack :oracle-profiles entry (原則4 — the PRD §19
;;;; soft/strict/strictest table as data, mutable by L5). The judge is
;;;; an injected function (prompt-string → response-string); the LLM
;;;; provider arrives with the kernel (SP5). Parsing fails closed:
;;;; an unparseable or erroring judge is a rejection.

(defpackage #:cl-harness-next/src/review-oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:export #:review-oracle
           #:oracle-profile
           #:oracle-judge-fn))

(in-package #:cl-harness-next/src/review-oracle)

(defclass review-oracle (oracle)
  ((profile :initarg :profile :initform nil :reader oracle-profile
            :documentation "Plist, typically a policy-pack
:oracle-profiles entry: (:id keyword :strictness :soft|:strict|:strictest
:instructions string).")
   (judge-fn :initarg :judge-fn :reader oracle-judge-fn
             :documentation "Function prompt-string → response-string."))
  (:documentation "Profile-driven LLM judge with injected transport."))

(defmethod oracle-name ((oracle review-oracle))
  (or (getf (oracle-profile oracle) :id) :review))

(defun %strictness-preamble (strictness)
  (ecase (or strictness :soft)
    (:soft
     "You are a pragmatic reviewer. Approve unless something is clearly wrong.")
    (:strict
     "You are a strict reviewer. Approve only when every stated requirement is met.")
    (:strictest
     "You are the strictest reviewer. Reject on any doubt; the subject guards a source of truth.")))

(defun %review-prompt (oracle subject)
  (let ((profile (oracle-profile oracle)))
    (format nil
            "~A~@[~%~%Additional instructions:~%~A~]~%~%~
Review the following. Answer on the first line with APPROVE or ~
REJECT: <feedback>.~%~%---~%~A"
            (%strictness-preamble (getf profile :strictness))
            (getf profile :instructions)
            subject)))

(defun %first-content-line (text)
  "The first non-blank line of TEXT, trimmed of surrounding whitespace, or
the empty string when TEXT is entirely blank."
  (with-input-from-string (in text)
    (loop for line = (read-line in nil nil)
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return #\Page) line)
          when (plusp (length trimmed)) return trimmed
          finally (return ""))))

(defun %starts-with (prefix string)
  "True when STRING begins with PREFIX (exact, case-sensitive)."
  (let ((n (length prefix)))
    (and (>= (length string) n) (string= prefix string :end2 n))))

(defun %leading-alpha (string)
  "STRING with leading non-alphabetic characters removed, so a verdict wrapped
in markdown / list / quote decoration (**APPROVE**, \"> APPROVE\", \"1. APPROVE\")
still exposes its leading token. Returns \"\" when STRING has no letters."
  (let ((start (position-if #'alpha-char-p string)))
    (if start (subseq string start) "")))

(defun %parse-judgement (response)
  "Return (values pass-p feedback). The verdict is the leading alphabetic
token of the first non-blank line — APPROVE or REJECT (case-insensitive),
with leading markdown/list/quote decoration skipped. Anything else fails
closed. Matching the leading token, rather than searching the whole text,
keeps a REJECT whose prose merely mentions \"approve\" from being read as a
pass."
  (let* ((text (or response ""))
         (head (string-upcase (%leading-alpha (%first-content-line text)))))
    (cond ((%starts-with "APPROVE" head) (values t text))
          ((%starts-with "REJECT" head) (values nil text))
          (t
           (values nil (format nil "unparseable review response: ~S" text))))))

(defmethod evaluate ((oracle review-oracle) (subject string))
  (handler-case
      (multiple-value-bind (pass-p feedback)
          (%parse-judgement (funcall (oracle-judge-fn oracle)
                                     (%review-prompt oracle subject)))
        (make-verdict :oracle (oracle-name oracle)
                      :pass-p pass-p :reason feedback))
    (error (condition)
      (make-verdict :oracle (oracle-name oracle) :pass-p nil
                    :reason (format nil "judge error: ~A" condition)))))
