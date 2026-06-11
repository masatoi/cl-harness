;;;; next/tests/projection-test.lisp
;;;;
;;;; Unit tests for next/src/projection.lisp: protocol defaults,
;;;; interaction pairing, payload helpers (spec §8.2).

(defpackage #:cl-harness-next/tests/projection-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction
                #:interaction
                #:make-interaction
                #:interaction-tool
                #:interaction-result
                #:interaction-error-message
                #:interaction-action-seq
                #:interaction-observation-seq
                #:interaction-ok-p
                #:argument-string
                #:result-text
                #:result-error-p
                #:interaction-succeeded-p))

(in-package #:cl-harness-next/tests/projection-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(deftest default-methods-are-no-ops
  (let ((projection (make-instance 'projection)))
    (ok (eq projection (apply-event projection :anything)))
    (ok (eq projection (apply-interaction projection :anything)))))

(deftest interaction-pairs-two-events
  (let* ((action (make-harness-event
                  :action (%hash "tool" "repl-eval"
                                 "arguments" (%hash "code" "(+ 1 2)"))
                  :seq 4))
         (observation (make-harness-event
                       :observation (%hash "tool" "repl-eval"
                                           "result" (%hash "x" 1))
                       :seq 5))
         (interaction (make-interaction action observation)))
    (ok (equal "repl-eval" (interaction-tool interaction)))
    (ok (equal "(+ 1 2)" (argument-string interaction "code")))
    (ok (hash-table-p (interaction-result interaction)))
    (ok (= 4 (interaction-action-seq interaction)))
    (ok (= 5 (interaction-observation-seq interaction)))
    (ok (interaction-ok-p interaction))))

(deftest error-observation-is-not-ok
  (let* ((action (make-harness-event
                  :action (%hash "tool" "run-tests") :seq 1))
         (observation (make-harness-event
                       :observation (%hash "tool" "run-tests"
                                           "error" "boom")
                       :seq 2))
         (interaction (make-interaction action observation)))
    (ok (not (interaction-ok-p interaction)))
    (ok (equal "boom" (interaction-error-message interaction)))))

(deftest result-text-extracts-and-truncates
  (let ((interaction
          (make-instance 'interaction
                         :tool "repl-eval"
                         :result (%hash "content"
                                        (list (%hash "type" "text"
                                                     "text" (make-string 300
                                                                         :initial-element #\x))))
                         :action-seq 1 :observation-seq 2)))
    (let ((text (result-text interaction)))
      (ok (stringp text))
      (ok (< (length text) 300))
      (ok (search "[truncated]" text)))))

(deftest result-text-nil-on-absent-shape
  (let ((no-result (make-instance 'interaction :tool "x"
                                  :action-seq 1 :observation-seq 2))
        (no-content (make-instance 'interaction :tool "x"
                                   :result (%hash "passed" 3)
                                   :action-seq 1 :observation-seq 2)))
    (ok (null (result-text no-result)))
    (ok (null (result-text no-content)))))

(deftest result-error-p-reads-iserror
  (let ((errorful (make-instance 'interaction :tool "x"
                                 :result (%hash "isError" t)
                                 :action-seq 1 :observation-seq 2))
        (fine (make-instance 'interaction :tool "x"
                             :result (%hash "isError" nil)
                             :action-seq 1 :observation-seq 2))
        (absent (make-instance 'interaction :tool "x"
                               :result (%hash "passed" 3)
                               :action-seq 1 :observation-seq 2)))
    (ok (result-error-p errorful))
    (ok (not (result-error-p fine)))
    (ok (not (result-error-p absent)))))

(deftest succeeded-requires-transport-and-tool-success
  (let ((tool-failed (make-instance 'interaction :tool "x"
                                    :result (%hash "isError" t)
                                    :action-seq 1 :observation-seq 2))
        (transport-failed (make-instance 'interaction :tool "x"
                                         :error-message "boom"
                                         :action-seq 1 :observation-seq 2))
        (fine (make-instance 'interaction :tool "x"
                             :result (%hash "ok" t)
                             :action-seq 1 :observation-seq 2)))
    (ok (not (interaction-succeeded-p tool-failed)))
    (ok (not (interaction-succeeded-p transport-failed)))
    (ok (interaction-succeeded-p fine))))
