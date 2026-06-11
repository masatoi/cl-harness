;;;; next/src/judge.lisp
;;;;
;;;; Bridge from an LLM provider to the review oracle's judge-fn
;;;; contract (closes SP4's deferred item): the oracle stays
;;;; provider-agnostic, the provider stays oracle-agnostic.

(defpackage #:cl-harness-next/src/judge
  (:use #:cl)
  (:import-from #:cl-harness-next/src/model
                #:complete-chat
                #:make-chat-message
                #:chat-response-content)
  (:export #:make-judge-fn))

(in-package #:cl-harness-next/src/judge)

(defun make-judge-fn (provider &key system-prompt)
  "Return a judge function (prompt-string → response-string) backed by
PROVIDER. SYSTEM-PROMPT, when supplied, is prepended as a system
message. MODEL-ERRORs propagate — the review oracle's evaluate already
fails closed on judge errors."
  (lambda (prompt)
    (let ((messages (append (when system-prompt
                              (list (make-chat-message "system"
                                                       system-prompt)))
                            (list (make-chat-message "user" prompt)))))
      (chat-response-content (complete-chat provider messages)))))
